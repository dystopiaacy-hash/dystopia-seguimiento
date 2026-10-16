-- =====================================================================
-- 167_gonzalez_renovacion.sql  ·  PRODUCTO: llevar la renovación 'renovado' de la ficha cerrada be2a3e68 a la vigente 5955e47d
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), DESPUÉS de la 164. Evitar los minutos :00, :15,
-- :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- Requiere la 164 corrida (cs_trg_20_reglas de cs_renovaciones, campos_extra, aviso_1_at / aviso_2_at). No crea ni
-- cambia funciones, vistas ni crons. NO tiene datos personales: las fichas van solo por el prefijo del uuid. Nada se borra.
--
-- Contexto: la 164 cerró be2a3e68 (duplicada de 5955e47d, marca campos_extra.cierre164) y dejó la renovación 'renovado'
-- de be2a3e68 en la cerrada, porque su nueva_fecha_fin (2027-02-13) pasaba la fecha_fin de la vigente (2026-11-11).
-- Joaquín aprobó (16/10/2026): la vigente tiene que vencer el 2027-02-13.
--
-- Qué hace:
--   1. MUEVE esa renovación (cliente_id de be2a3e68 a 5955e47d). Misma lógica que la 164 para mover renovaciones:
--      cs_trg_20_reglas (prohíbe cambiar de cliente) se apaga SOLO dentro de esta transacción, con la tabla bloqueada,
--      y se vuelve a habilitar antes del COMMIT. Como el UPDATE no toca la columna estado, cs_trg_after_estado y
--      cs_trg_historial (los que cuentan renovaciones_count y recalculan el cliente) NO se disparan.
--   2. fecha_fin de 5955e47d = nueva_fecha_fin de la renovación movida (se lee de la tabla, no está escrita acá) y se
--      limpian aviso_1_at y aviso_2_at, igual que hizo la 164 al corregir fechas (si no, el aviso de los 21 días del
--      ciclo nuevo no saldría). No cambia el estado ni renovaciones_count (la renovación ya se contó en la ficha
--      cerrada cuando se cargó; sumarla otra vez la contaría doble).
--   Efectos: cs_trg_historial deja filas de fecha_fin y avisos en la vigente; el proceso CSM (130) renombra los resell
--   pendientes a la fecha nueva en su próxima corrida; ningún cierre ni offboarding.
--
-- GUARDA (aborta sin tocar nada): la 164 no corrida (be2a3e68 debe estar finalizado con cierre164 apuntando a
-- 5955e47d y con fila 'cerrada' en cs_bak_164_clientes); la vigente no es de liam o está cerrada / de baja; la
-- renovación no existe, no es UNA sola 'renovado' o no da 2027-02-13; la vigente ya tiene una renovación 'renovado' que
-- llega a esa fecha o más, o su fecha_fin ya la alcanza; o la 167 ya se corrió (respaldos con filas).
--
-- Respaldos: cs_bak_167_clientes y cs_bak_167_renovaciones (con RLS, sin políticas). Controles C1 a C6 y vuelta atrás
-- comentados al final.
-- Qué NO toca: otras fichas, otras renovaciones de be2a3e68 (las 'en_proceso' u otras se quedan), la 165, la 166.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- Objetivos (prefijos de uuid)
-- ---------------------------------------------------------------------
create temp table par167_pref (cierra text primary key, queda text not null, esperada date not null) on commit drop;
insert into par167_pref (cierra, queda, esperada) values ('be2a3e68', '5955e47d', date '2027-02-13');


-- ---------------------------------------------------------------------
-- Autochequeo: lo que usa esta migración tiene que existir.
-- ---------------------------------------------------------------------
do $$
declare
  v_falta text;
begin
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_clientes'), ('cs_renovaciones'), ('cs_bak_164_clientes')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 167: faltan tablas (corrió la 164?): %', v_falta;
  end if;

  select string_agg(r.c, ', ') into v_falta
  from (values ('campos_extra'), ('aviso_1_at'), ('aviso_2_at'), ('fecha_fin'), ('fecha_inicio'), ('estado')) as r(c)
  where not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'cs_clientes' and column_name = r.c);
  if v_falta is not null then
    raise exception 'cs 167: faltan columnas en cs_clientes: %', v_falta;
  end if;

  if not exists (select 1 from pg_trigger where tgrelid = 'public.cs_renovaciones'::regclass
                 and tgname = 'cs_trg_20_reglas' and not tgisinternal) then
    raise exception 'cs 167: falta el trigger cs_trg_20_reglas en cs_renovaciones (001 / 039)';
  end if;
end $$;

-- Las tablas que se tocan, juntas y al principio (ya hubo un deadlock por no hacerlo).
-- SHARE ROW EXCLUSIVE también es el lock que pide ALTER TABLE ... DISABLE TRIGGER.
lock table public.cs_clientes, public.cs_renovaciones in share row exclusive mode;


-- ---------------------------------------------------------------------
-- Resolución de ids + GUARDA
-- ---------------------------------------------------------------------
create temp table par167 on commit drop as
select p.cierra as pref_cierra, p.queda as pref_queda, p.esperada,
       cc.id as cierra_id, qq.id as queda_id
from par167_pref p
join public.cs_clientes cc on cc.id::text like p.cierra || '%'
join public.cs_clientes qq on qq.id::text like p.queda  || '%';

do $$
declare
  v_mal text;
  v_n   int;
  p     record;
begin
  -- A. cada prefijo resuelve exactamente UNA ficha
  select string_agg(x.p || ' (' || x.n || ')', ', ') into v_mal
  from (select pc.cierra as p, (select count(*) from public.cs_clientes c where c.id::text like pc.cierra || '%') as n from par167_pref pc
        union all
        select pc.queda,       (select count(*) from public.cs_clientes c where c.id::text like pc.queda  || '%') from par167_pref pc) x
  where x.n <> 1;
  if v_mal is not null then
    raise exception 'cs 167: prefijos que no resuelven exactamente una ficha (prefijo (cantidad)): %', v_mal;
  end if;
  select count(*) into v_n from par167;
  if v_n <> 1 then raise exception 'cs 167: esperaba 1 par, hay %', v_n; end if;

  select * into p from par167;

  -- B. la 164 SE CORRIÓ: la cerrada está 'finalizado' con cierre164 apuntando a la vigente, y quedó su respaldo
  select c.pref into v_mal from (
    select p.pref_cierra as pref from public.cs_clientes c
    where c.id = p.cierra_id
      and (c.estado <> 'finalizado'
           or not (coalesce(c.campos_extra, '{}'::jsonb) ? 'cierre164')
           or (c.campos_extra -> 'cierre164' ->> 'duplicada_de') is distinct from p.queda_id::text)) c;
  if v_mal is not null then
    raise exception 'cs 167: la ficha % no está cerrada por la 164 (finalizado + cierre164 apuntando a la vigente). Correr la 164 antes', v_mal;
  end if;
  if not exists (select 1 from public.cs_bak_164_clientes b where b.id = p.cierra_id and b.motivo = 'cerrada') then
    raise exception 'cs 167: no hay respaldo de la 164 para la ficha % (la 164 no está corrida)', p.pref_cierra;
  end if;

  -- C. la vigente es de liam, está viva y no la cerró la 164
  select count(*) into v_n from public.cs_clientes q join public.cs_clientes c on c.id = p.cierra_id
  where q.id = p.queda_id and q.programa_id = 'liam' and c.programa_id = 'liam'
    and q.estado in ('onboarding', 'activo', 'en_renovacion')
    and not (coalesce(q.campos_extra, '{}'::jsonb) ? 'cierre164');
  if v_n <> 1 then
    raise exception 'cs 167: la vigente % no es de liam, no está en onboarding / activo / en_renovacion, o está cerrada por la 164', p.pref_queda;
  end if;

  -- D. la renovación: UNA sola 'renovado' en la cerrada y da la fecha esperada
  select count(*) into v_n from public.cs_renovaciones r where r.cliente_id = p.cierra_id and r.estado = 'renovado';
  if v_n <> 1 then
    raise exception 'cs 167: la ficha % tiene % renovaciones renovado (debe ser exactamente 1; ambiguo, no se elige). Si es 0 y la vigente ya la tiene, la 167 ya se corrió', p.pref_cierra, v_n;
  end if;
  select string_agg(coalesce(r.nueva_fecha_fin::text, 'null'), ', ') into v_mal
  from public.cs_renovaciones r
  where r.cliente_id = p.cierra_id and r.estado = 'renovado' and r.nueva_fecha_fin is distinct from p.esperada;
  if v_mal is not null then
    raise exception 'cs 167: la nueva_fecha_fin de la renovación dice %, esperada %', v_mal, p.esperada;
  end if;

  -- E. la vigente: su fecha_fin es menor que la de la renovación, y no tiene ya una renovación renovado que llegue ahí
  select count(*) into v_n from public.cs_clientes q
  where q.id = p.queda_id and q.fecha_fin >= p.esperada;
  if v_n > 0 then
    raise exception 'cs 167: la fecha_fin de la vigente % ya está en % o más allá (ya se corrigió?)', p.pref_queda, p.esperada;
  end if;
  select count(*) into v_n from public.cs_renovaciones r
  where r.cliente_id = p.queda_id and r.estado = 'renovado' and r.nueva_fecha_fin >= p.esperada;
  if v_n > 0 then
    raise exception 'cs 167: la vigente % ya tiene % renovaciones renovado que llegan a % o más: ya se movió, o hay que revisar a mano', p.pref_queda, v_n, p.esperada;
  end if;
  select count(*) into v_n from public.cs_clientes q where q.id = p.queda_id and p.esperada < q.fecha_inicio;
  if v_n > 0 then raise exception 'cs 167: la fecha esperada es anterior a fecha_inicio de la vigente'; end if;

  -- F. NO se corrió ya la 167: los respaldos no existen o están vacíos
  if to_regclass('public.cs_bak_167_clientes') is not null then
    execute 'select count(*) from public.cs_bak_167_clientes' into v_n;
    if v_n > 0 then raise exception 'cs 167: ya se corrió (cs_bak_167_clientes tiene % filas). No se repite.', v_n; end if;
  end if;
  if to_regclass('public.cs_bak_167_renovaciones') is not null then
    execute 'select count(*) from public.cs_bak_167_renovaciones' into v_n;
    if v_n > 0 then raise exception 'cs 167: ya se corrió (cs_bak_167_renovaciones tiene % filas). No se repite.', v_n; end if;
  end if;
end $$;

-- La renovación a mover (id) y la fecha que sale de la tabla.
create temp table ren167 on commit drop as
select r.id, r.nueva_fecha_fin, p.cierra_id, p.queda_id
from public.cs_renovaciones r join par167 p on p.cierra_id = r.cliente_id
where r.estado = 'renovado';


-- =====================================================================
-- 0. RESPALDOS (cs_bak_167_*, con RLS)
-- =====================================================================
create table if not exists public.cs_bak_167_clientes (
  id            uuid primary key,
  fila          jsonb not null,          -- to_jsonb(cs_clientes) de la vigente ANTES del cambio
  respaldado_at timestamptz not null default now()
);
create table if not exists public.cs_bak_167_renovaciones (
  id                 uuid primary key,
  fila               jsonb not null,     -- to_jsonb(cs_renovaciones) ANTES de moverla
  cliente_id_antes   uuid not null,
  cliente_id_despues uuid not null,
  respaldado_at      timestamptz not null default now()
);
revoke all on table public.cs_bak_167_clientes, public.cs_bak_167_renovaciones from public, anon, authenticated;
alter table public.cs_bak_167_clientes enable row level security;
alter table public.cs_bak_167_renovaciones enable row level security;

insert into public.cs_bak_167_clientes (id, fila)
select c.id, to_jsonb(c) from public.cs_clientes c join par167 p on p.queda_id = c.id;

insert into public.cs_bak_167_renovaciones (id, fila, cliente_id_antes, cliente_id_despues)
select r.id, to_jsonb(x), r.cierra_id, r.queda_id
from ren167 r join public.cs_renovaciones x on x.id = r.id;


-- =====================================================================
-- 1. MOVER la renovación (cs_trg_20_reglas apagado SOLO acá, dentro de la transacción)
-- =====================================================================
alter table public.cs_renovaciones disable trigger cs_trg_20_reglas;
update public.cs_renovaciones x set cliente_id = r.queda_id
  from ren167 r where x.id = r.id;
alter table public.cs_renovaciones enable trigger cs_trg_20_reglas;


-- =====================================================================
-- 2. fecha_fin de la vigente = nueva_fecha_fin de la renovación movida; avisos limpios (como hizo la 164)
-- =====================================================================
update public.cs_clientes c
   set fecha_fin  = x.nueva_fecha_fin,
       aviso_1_at = null,
       aviso_2_at = null
  from ren167 r
  join public.cs_renovaciones x on x.id = r.id and x.cliente_id = r.queda_id
 where c.id = r.queda_id;


-- =====================================================================
-- VERIFICACIÓN dentro de la transacción: si algo no quedó como se espera, aborta y no se guarda nada
-- =====================================================================
do $$
declare
  v_n int;
begin
  select count(*) into v_n from ren167 r
   join public.cs_renovaciones x on x.id = r.id and x.cliente_id = r.queda_id and x.estado = 'renovado'
   join public.cs_clientes c on c.id = r.queda_id
  where c.fecha_fin = x.nueva_fecha_fin and c.aviso_1_at is null and c.aviso_2_at is null;
  if v_n <> 1 then raise exception 'cs 167: la renovación o la fecha_fin de la vigente no quedaron como se esperaba'; end if;

  -- el estado de la vigente y su cantidad de renovaciones no cambiaron
  select count(*) into v_n from public.cs_bak_167_clientes b
   join public.cs_clientes c on c.id = b.id
  where c.estado = b.fila ->> 'estado' and c.renovaciones_count::text = b.fila ->> 'renovaciones_count';
  if v_n <> 1 then raise exception 'cs 167: cambió el estado o renovaciones_count de la vigente'; end if;

  -- la cerrada sigue cerrada y sin renovación 'renovado'
  select count(*) into v_n from par167 p
   join public.cs_clientes c on c.id = p.cierra_id and c.estado = 'finalizado' and c.campos_extra ? 'cierre164'
  where not exists (select 1 from public.cs_renovaciones x where x.cliente_id = p.cierra_id and x.estado = 'renovado');
  if v_n <> 1 then raise exception 'cs 167: la ficha cerrada no quedó como se esperaba'; end if;

  select count(*) into v_n from public.cs_bak_167_clientes;
  if v_n <> 1 then raise exception 'cs 167: el respaldo de la ficha tiene % filas (esperaba 1)', v_n; end if;
  select count(*) into v_n from public.cs_bak_167_renovaciones;
  if v_n <> 1 then raise exception 'cs 167: el respaldo de la renovación tiene % filas (esperaba 1)', v_n; end if;

  -- el trigger quedó habilitado ('O' = origin)
  select count(*) into v_n from pg_trigger g
   where g.tgrelid = 'public.cs_renovaciones'::regclass and g.tgname = 'cs_trg_20_reglas' and g.tgenabled = 'O';
  if v_n <> 1 then raise exception 'cs 167: cs_trg_20_reglas quedó deshabilitado'; end if;

  select count(*) into v_n from pg_tables
   where schemaname = 'public' and tablename like 'cs\_bak\_167\_%' and not rowsecurity;
  if v_n <> 0 then raise exception 'cs 167: quedan % tablas cs_bak_167_* sin RLS', v_n; end if;
end $$;

commit;


-- =====================================================================
-- CONTROLES (comentados; correr de a uno DESPUÉS del commit; sin nombres de alumnos)
-- =====================================================================
-- C1. La vigente (esperado: 1 fila, fecha_fin = 2027-02-13, avisos limpios, estado igual que antes).
-- select left(c.id::text, 8) as ficha, c.estado, c.fecha_fin, c.aviso_1_at is null as aviso1_limpio,
--        c.aviso_2_at is null as aviso2_limpio, c.renovaciones_count
-- from public.cs_clientes c where c.id::text like '5955e47d%';
--
-- C2. Renovaciones de las dos fichas (esperado: la 'renovado' con 2027-02-13 en 5955e47d y ninguna 'renovado' en be2a3e68).
-- select left(r.cliente_id::text, 8) as ficha, left(r.id::text, 8) as renovacion, r.estado, r.nueva_fecha_fin
-- from public.cs_renovaciones r where r.cliente_id::text like any (array['be2a3e68%', '5955e47d%']) order by 1, 3;
--
-- C3. Respaldos (esperado: 1 fila en cada uno).
-- select (select count(*) from public.cs_bak_167_clientes) as clientes, (select count(*) from public.cs_bak_167_renovaciones) as renovaciones;
--
-- C4. El trigger habilitado (esperado: 1 fila, tgenabled = 'O').
-- select g.tgname, g.tgenabled from pg_trigger g where g.tgrelid = 'public.cs_renovaciones'::regclass and g.tgname = 'cs_trg_20_reglas';
--
-- C5. RLS de los respaldos (esperado: 2 filas con rowsecurity = true; 0 filas en políticas).
-- select tablename, rowsecurity from pg_tables where schemaname = 'public' and tablename like 'cs\_bak\_167\_%';
-- select policyname from pg_policies where schemaname = 'public' and tablename like 'cs\_bak\_167\_%';
--
-- C6. Historial de la vigente (esperado: fecha_fin de 2026-11-11 a 2027-02-13 hoy).
-- select campo, valor_anterior, valor_nuevo, at from public.cs_historial
-- where tabla = 'cs_clientes' and registro_id::text like '5955e47d%' and campo = 'fecha_fin' and at > now() - interval '1 hour' order by at;


-- =====================================================================
-- VUELTA ATRÁS (comentada; correr completa y en una sola transacción, solo si hace falta)
-- =====================================================================
-- begin;
-- set local lock_timeout = '8s';
-- lock table public.cs_clientes, public.cs_renovaciones in share row exclusive mode;
-- -- 1. Devolver la renovación a la ficha cerrada
-- alter table public.cs_renovaciones disable trigger cs_trg_20_reglas;
-- update public.cs_renovaciones t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_167_renovaciones b where t.id = b.id;
-- alter table public.cs_renovaciones enable trigger cs_trg_20_reglas;
-- -- 2. fecha_fin y avisos de la vigente
-- update public.cs_clientes c set fecha_fin = r.fecha_fin, aviso_1_at = r.aviso_1_at, aviso_2_at = r.aviso_2_at
--   from public.cs_bak_167_clientes b, lateral jsonb_populate_record(null::public.cs_clientes, b.fila) r
--  where b.id = c.id;
-- -- 3. Verificar C4 (trigger en 'O'). Los respaldos se dejan (con RLS). Para correr la 167 de nuevo hay que vaciarlos:
-- --   delete from public.cs_bak_167_clientes; delete from public.cs_bak_167_renovaciones;
-- commit;
