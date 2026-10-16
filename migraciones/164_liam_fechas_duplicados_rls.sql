-- =====================================================================
-- 164_liam_fechas_duplicados_rls.sql  ·  PRODUCTO: correcciones de datos de liam + RLS en respaldos
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución). Evitar los minutos :00, :15, :30 y :45
-- (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- Requiere 039 (aviso_1_at / aviso_2_at, cs_trg_after_cierre), 071 (campos_extra), 126 (cs_clientes_mails) y
-- 127 (cs_clientes_alias). Usa fin_cs_vinculo (129) solo si existe. No crea ni cambia crons ni funciones.
-- NO tiene datos personales: las fichas se identifican solo por el prefijo del uuid. Nada se borra.
--
-- Qué hace:
--   1. FECHA DE FIN: 12 fichas de liam (con una renovación 'renovado' cargada) tienen fecha_fin vieja. Se lleva
--      cs_clientes.fecha_fin a cs_renovaciones.nueva_fecha_fin (se toma de la tabla, no está escrita acá; la
--      guarda verifica que dé la fecha esperada). Igual que haría cs_tg_renovaciones_after al renovar, se limpian
--      aviso_1_at y aviso_2_at (si no, el aviso de los 21 días del ciclo nuevo no saldría nunca). No cambia el
--      estado ni renovaciones_count.
--   2. FICHAS DUPLICADAS (3 pares): queda la vigente; la otra se cierra, no se borra. Criterio de la 162: estado
--      'finalizado' + marca en campos_extra (acá cierre164), con cs_trg_after_cierre apagado durante el UPDATE
--      (sin accionables de offboarding) y sin tocar el resto. Antes se mueve a la vigente:
--        - seguimientos (cs_seguimientos), todos
--        - renovaciones CERRADAS (renovado / no_renovado) cuya nueva_fecha_fin no pase de la fecha_fin de la vigente
--          (las 'en_proceso' y las que la pasarían se quedan; ver control C8)
--        - accionables manuales (cs_accionables, origen 'manual'); los de plantilla / sistema pendientes de la
--          cerrada pasan a 'completado' con la nota "Ficha duplicada cerrada (164)" (como hizo la 162)
--        - mails extra (cs_clientes_mails; los que la vigente ya tiene se quedan) y alias (cs_clientes_alias):
--          así fathom-sync asigna las llamadas nuevas a la ficha vigente
--        - vínculo de pagos (fin_cs_vinculo.cs_cliente_id) de los vinculados a la cerrada
--        - cs_clientes.notas: el texto de la cerrada se agrega al final de las de la vigente
--      NO se mueve (queda en la ficha cerrada, que sigue existiendo): llamadas y todo lo que cuelga de ellas
--      (accionables y recursos de llamada, transcripciones, candidatas a duda), wins, envíos de satisfacción,
--      menciones de dudas, onboardings, chequeos, alertas, historial, "En qué está", riesgo, upsell. Las llamadas
--      tienen triggers que prohíben cambiar de alumno y FKs compuestas entre 5 tablas: eso va en una migración
--      aparte (pedir número) para poder probarla sola.
--   3. RLS en todas las cs_bak_* de public (sin políticas: anon / authenticated no leen ni escriben). Dinámico.
--
-- Respaldos: cs_bak_164_clientes, cs_bak_164_accionables, cs_bak_164_hijos (con RLS). Sección de vuelta atrás
-- comentada al final; los controles C1 a C9 también, se corren de a uno.
-- Qué NO toca: Koch, Omar Modotti, otras fichas, otros programas, crons, Fathom, Finanzas, crm, ventas.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- Objetivos (prefijos de uuid)
-- ---------------------------------------------------------------------
create temp table fechas164 (prefijo text primary key, esperada date not null) on commit drop;
insert into fechas164 (prefijo, esperada) values
  ('55085941', date '2026-11-24'),
  ('97434d66', date '2027-03-23'),
  ('5bce0da5', date '2027-01-15'),
  ('6116c9dd', date '2027-04-10'),
  ('f256102b', date '2026-10-30'),
  ('463440b5', date '2026-11-06'),
  ('edcd8e77', date '2027-03-17'),
  ('6c938078', date '2027-01-11'),
  ('7c61fd78', date '2027-04-17'),
  ('c82112ca', date '2027-05-12'),
  ('aa20cfc4', date '2027-03-24'),
  ('b63a9bf2', date '2026-11-19');

create temp table pares164_pref (cierra text primary key, queda text not null) on commit drop;
insert into pares164_pref (cierra, queda) values
  ('e4c8102a', '28d200e3'),
  ('be2a3e68', '5955e47d'),
  ('2375ab58', '17d1c875');


-- ---------------------------------------------------------------------
-- Autochequeo: lo que usa esta migración tiene que existir.
-- ---------------------------------------------------------------------
do $$
declare
  v_falta text;
begin
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_clientes'), ('cs_renovaciones'), ('cs_accionables'), ('cs_seguimientos'),
               ('cs_clientes_mails'), ('cs_clientes_alias')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 164: faltan tablas (corrieron 126 y 127?): %', v_falta;
  end if;

  select string_agg(r.c, ', ') into v_falta
  from (values ('campos_extra'), ('aviso_1_at'), ('aviso_2_at'), ('notas'), ('fecha_fin'), ('estado')) as r(c)
  where not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'cs_clientes' and column_name = r.c);
  if v_falta is not null then
    raise exception 'cs 164: faltan columnas en cs_clientes: % (039 y 071)', v_falta;
  end if;

  if not exists (select 1 from pg_trigger where tgrelid = 'public.cs_clientes'::regclass
                 and tgname = 'cs_trg_after_cierre' and not tgisinternal) then
    raise exception 'cs 164: falta el trigger cs_trg_after_cierre en cs_clientes (039)';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.cs_renovaciones'::regclass
                 and tgname = 'cs_trg_20_reglas' and not tgisinternal) then
    raise exception 'cs 164: falta el trigger cs_trg_20_reglas en cs_renovaciones (001 / 039)';
  end if;
  if to_regprocedure('public.cs_hoy()') is null then
    raise exception 'cs 164: falta cs_hoy()';
  end if;
  if to_regclass('public.fin_cs_vinculo') is null then
    raise notice 'cs 164: no existe fin_cs_vinculo (129): se omite el vínculo de pagos';
  end if;
end $$;

-- Todas las tablas que lee la app o el cron, juntas y al principio (ya hubo un deadlock por no hacerlo).
do $$
begin
  execute 'lock table public.cs_clientes, public.cs_renovaciones, public.cs_accionables, public.cs_seguimientos, '
       || 'public.cs_clientes_mails, public.cs_clientes_alias'
       || case when to_regclass('public.fin_cs_vinculo') is not null then ', public.fin_cs_vinculo' else '' end
       || ' in share row exclusive mode';
end $$;


-- ---------------------------------------------------------------------
-- Resolución de ids + GUARDA (aborta si algo no es lo esperado; no se modifica nada antes de este punto)
-- ---------------------------------------------------------------------
create temp table fichas164 on commit drop as
select f.prefijo, f.esperada, c.id, c.programa_id, c.estado, c.fecha_inicio, c.fecha_fin as fecha_fin_antes,
       (select count(*) from public.cs_renovaciones r where r.cliente_id = c.id and r.estado = 'renovado') as n_renovado,
       (select max(r.nueva_fecha_fin) from public.cs_renovaciones r where r.cliente_id = c.id and r.estado = 'renovado') as nueva_fecha_fin
from fechas164 f
join public.cs_clientes c on c.id::text like f.prefijo || '%';

create temp table pares164 on commit drop as
select pc.cierra as pref_cierra, pc.queda as pref_queda,
       cc.id as cierra_id, qq.id as queda_id,
       cc.programa_id as prog_cierra, qq.programa_id as prog_queda,
       cc.estado as estado_cierra, qq.estado as estado_queda, cc.campos_extra as extra_cierra
from pares164_pref pc
join public.cs_clientes cc on cc.id::text like pc.cierra || '%'
join public.cs_clientes qq on qq.id::text like pc.queda || '%';

do $$
declare
  v_mal text;
  v_n   int;
begin
  -- A. cada prefijo resuelve exactamente UNA ficha
  select string_agg(x.p || ' (' || x.n || ')', ', ') into v_mal
  from (select f.prefijo as p, (select count(*) from public.cs_clientes c where c.id::text like f.prefijo || '%') as n
        from fechas164 f
        union all select pc.cierra, (select count(*) from public.cs_clientes c where c.id::text like pc.cierra || '%') from pares164_pref pc
        union all select pc.queda,  (select count(*) from public.cs_clientes c where c.id::text like pc.queda  || '%') from pares164_pref pc) x
  where x.n <> 1;
  if v_mal is not null then
    raise exception 'cs 164: prefijos que no resuelven exactamente una ficha (prefijo (cantidad)): %', v_mal;
  end if;

  -- B. fechas: las 12 fichas son de liam, vivas, con UNA renovación 'renovado' cuya fecha coincide con la esperada
  select count(*) into v_n from fichas164;
  if v_n <> 12 then raise exception 'cs 164: esperaba 12 fichas de fecha, hay %', v_n; end if;

  select string_agg(prefijo, ', ') into v_mal from fichas164 where programa_id <> 'liam';
  if v_mal is not null then raise exception 'cs 164: fichas que no son de liam: %', v_mal; end if;

  select string_agg(prefijo || ' (estado ' || estado || ')', ', ') into v_mal
  from fichas164 where estado not in ('onboarding', 'activo', 'en_renovacion');
  if v_mal is not null then
    raise exception 'cs 164: fichas en un estado que no es el esperado (onboarding / activo / en_renovacion): %', v_mal;
  end if;

  select string_agg(prefijo || ' (renovaciones renovado: ' || n_renovado || ')', ', ') into v_mal
  from fichas164 where n_renovado <> 1;
  if v_mal is not null then
    raise exception 'cs 164: fichas sin exactamente UNA renovación renovado (ambiguo, no se elige): %', v_mal;
  end if;

  select string_agg(prefijo || ' (renovación dice ' || coalesce(nueva_fecha_fin::text, 'null') || ', esperada ' || esperada || ')', ', ')
    into v_mal
  from fichas164 where nueva_fecha_fin is distinct from esperada;
  if v_mal is not null then
    raise exception 'cs 164: la nueva_fecha_fin de la renovación no coincide con la esperada: %', v_mal;
  end if;

  select string_agg(prefijo || ' (fecha_fin actual ' || fecha_fin_antes || ')', ', ') into v_mal
  from fichas164 where fecha_fin_antes >= esperada;
  if v_mal is not null then
    raise exception 'cs 164: fichas cuya fecha_fin ya está en la fecha esperada o más allá (ya se corrigió?): %', v_mal;
  end if;

  select string_agg(prefijo, ', ') into v_mal from fichas164 where esperada < fecha_inicio;
  if v_mal is not null then raise exception 'cs 164: la fecha esperada es anterior a fecha_inicio: %', v_mal; end if;

  -- C. duplicados: 3 pares completos, mismo programa liam, la que se cierra sigue viva, la que queda no es baja
  select count(*) into v_n from pares164;
  if v_n <> 3 then raise exception 'cs 164: esperaba 3 pares de duplicados, hay %', v_n; end if;

  select string_agg(pref_cierra || '/' || pref_queda, ', ') into v_mal
  from pares164 where prog_cierra <> 'liam' or prog_queda <> 'liam' or cierra_id = queda_id;
  if v_mal is not null then raise exception 'cs 164: pares que no son de liam o repetidos: %', v_mal; end if;

  select string_agg(pref_cierra || ' (estado ' || estado_cierra || ')', ', ') into v_mal
  from pares164 where estado_cierra in ('finalizado', 'baja') or coalesce(extra_cierra, '{}'::jsonb) ? 'cierre164';
  if v_mal is not null then
    raise exception 'cs 164: la ficha a cerrar ya está cerrada o ya se corrió esta migración: %', v_mal;
  end if;

  select string_agg(pref_queda || ' (estado ' || estado_queda || ')', ', ') into v_mal
  from pares164 where estado_queda = 'baja';
  if v_mal is not null then raise exception 'cs 164: la ficha que debía quedar vigente está de baja: %', v_mal; end if;

  select string_agg(p.pref_cierra, ', ') into v_mal
  from pares164 p where p.cierra_id in (select id from fichas164) or p.queda_id in (select id from fichas164);
  if v_mal is not null then raise exception 'cs 164: un par de duplicados se pisa con las 12 fichas de fecha: %', v_mal; end if;

  select string_agg(p.pref_cierra, ', ') into v_mal
  from pares164 p
  where (select count(*) from pares164 p2 where p2.queda_id = p.queda_id) > 1
     or p.cierra_id in (select queda_id from pares164);
  if v_mal is not null then raise exception 'cs 164: una ficha aparece en más de un par: %', v_mal; end if;
end $$;


-- =====================================================================
-- 0. RESPALDOS (cs_bak_164_*, con RLS)
-- =====================================================================
create table if not exists public.cs_bak_164_clientes (
  id            uuid not null,
  motivo        text not null check (motivo in ('fecha_fin', 'cerrada', 'vigente')),
  fila          jsonb not null,          -- to_jsonb(cs_clientes) ANTES del cambio
  respaldado_at timestamptz not null default now(),
  primary key (id, motivo)
);
create table if not exists public.cs_bak_164_accionables (
  id            uuid primary key,
  accion        text not null check (accion in ('cerrado')),
  fila          jsonb not null,          -- to_jsonb(cs_accionables) ANTES del cambio
  respaldado_at timestamptz not null default now()
);
create table if not exists public.cs_bak_164_hijos (
  n                  bigserial primary key,
  tabla              text not null,
  fila               jsonb not null,     -- to_jsonb(fila) ANTES de moverla
  cliente_id_antes   uuid not null,
  cliente_id_despues uuid not null,
  respaldado_at      timestamptz not null default now()
);
revoke all on table public.cs_bak_164_clientes, public.cs_bak_164_accionables, public.cs_bak_164_hijos
  from public, anon, authenticated;
alter table public.cs_bak_164_clientes enable row level security;
alter table public.cs_bak_164_accionables enable row level security;
alter table public.cs_bak_164_hijos enable row level security;


-- =====================================================================
-- 1. FECHA DE FIN de las 12 fichas -> nueva_fecha_fin de su renovación
-- =====================================================================
-- Efectos de este UPDATE (revisados): cs_trg_10_before solo valida fecha_fin >= fecha_inicio (la guarda ya lo
-- verificó); cs_trg_historial deja una fila en cs_historial por ficha (campo fecha_fin, y los avisos); no cambia
-- estado, así que no se dispara ningún cierre ni offboarding. La próxima corrida del proceso CSM (130) renombra
-- los resell PENDIENTES de estas fichas a la fecha nueva y recalcula su vence; los pasos que caigan entre hoy-7 y
-- hoy+7 de la fecha nueva se crean cuando entren en la ventana (nada pasa de golpe).
insert into public.cs_bak_164_clientes (id, motivo, fila)
select c.id, 'fecha_fin', to_jsonb(c)
from public.cs_clientes c join fichas164 f on f.id = c.id
on conflict (id, motivo) do nothing;

update public.cs_clientes c
   set fecha_fin  = f.nueva_fecha_fin,
       aviso_1_at = null,
       aviso_2_at = null
  from fichas164 f
 where f.id = c.id;


-- =====================================================================
-- 2. FICHAS DUPLICADAS: mover lo que se conserva y cerrar la sobrante
-- =====================================================================
insert into public.cs_bak_164_clientes (id, motivo, fila)
select c.id, 'cerrada', to_jsonb(c) from public.cs_clientes c join pares164 p on p.cierra_id = c.id
on conflict (id, motivo) do nothing;
insert into public.cs_bak_164_clientes (id, motivo, fila)
select c.id, 'vigente', to_jsonb(c) from public.cs_clientes c join pares164 p on p.queda_id = c.id
on conflict (id, motivo) do nothing;

-- 2a. seguimientos
insert into public.cs_bak_164_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_seguimientos', to_jsonb(s), p.cierra_id, p.queda_id
from public.cs_seguimientos s join pares164 p on p.cierra_id = s.cliente_id;
update public.cs_seguimientos s set cliente_id = p.queda_id
  from pares164 p where s.cliente_id = p.cierra_id;

-- 2b. renovaciones cerradas que no pasan de la fecha_fin de la vigente. El trigger cs_trg_20_reglas prohíbe
--     cambiar de cliente: se apaga solo durante este UPDATE (misma transacción, tabla bloqueada).
insert into public.cs_bak_164_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_renovaciones', to_jsonb(r), p.cierra_id, p.queda_id
from public.cs_renovaciones r
join pares164 p on p.cierra_id = r.cliente_id
join public.cs_clientes q on q.id = p.queda_id
where r.estado in ('renovado', 'no_renovado')
  and (r.nueva_fecha_fin is null or r.nueva_fecha_fin <= q.fecha_fin);

alter table public.cs_renovaciones disable trigger cs_trg_20_reglas;
update public.cs_renovaciones r set cliente_id = p.queda_id
  from pares164 p, public.cs_clientes q
 where r.cliente_id = p.cierra_id and q.id = p.queda_id
   and r.estado in ('renovado', 'no_renovado')
   and (r.nueva_fecha_fin is null or r.nueva_fecha_fin <= q.fecha_fin);
alter table public.cs_renovaciones enable trigger cs_trg_20_reglas;

-- 2c. accionables manuales (no choca con la unique (cliente_id, plantilla_key) porque no llevan clave)
insert into public.cs_bak_164_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_accionables', to_jsonb(a), p.cierra_id, p.queda_id
from public.cs_accionables a join pares164 p on p.cierra_id = a.cliente_id
where a.origen = 'manual' and a.plantilla_key is null;
update public.cs_accionables a set cliente_id = p.queda_id
  from pares164 p
 where a.cliente_id = p.cierra_id and a.origen = 'manual' and a.plantilla_key is null;

-- Lo pendiente de plantilla / sistema que queda en la cerrada se completa con nota (criterio de la 162), con respaldo.
insert into public.cs_bak_164_accionables (id, accion, fila)
select a.id, 'cerrado', to_jsonb(a)
from public.cs_accionables a join pares164 p on p.cierra_id = a.cliente_id
where a.estado in ('pendiente', 'en_proceso')
on conflict (id) do nothing;
update public.cs_accionables a
   set estado = 'completado',
       descripcion = left(btrim(coalesce(a.descripcion, '') || ' Ficha duplicada cerrada (164).'), 500)
  from pares164 p
 where a.cliente_id = p.cierra_id and a.estado in ('pendiente', 'en_proceso');

-- 2d. mails extra (los que la vigente ya tiene se quedan en la cerrada) y alias (únicos globales)
insert into public.cs_bak_164_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_clientes_mails', to_jsonb(m), p.cierra_id, p.queda_id
from public.cs_clientes_mails m join pares164 p on p.cierra_id = m.cliente_id
where not exists (select 1 from public.cs_clientes_mails m2 where m2.cliente_id = p.queda_id and m2.email = m.email);
update public.cs_clientes_mails m set cliente_id = p.queda_id
  from pares164 p
 where m.cliente_id = p.cierra_id
   and not exists (select 1 from public.cs_clientes_mails m2 where m2.cliente_id = p.queda_id and m2.email = m.email);

insert into public.cs_bak_164_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_clientes_alias', to_jsonb(a), p.cierra_id, p.queda_id
from public.cs_clientes_alias a join pares164 p on p.cierra_id = a.cliente_id;
update public.cs_clientes_alias a set cliente_id = p.queda_id
  from pares164 p where a.cliente_id = p.cierra_id;

-- 2e. vínculo de pagos de Finanzas (solo los vinculados a la cerrada)
do $$
begin
  if to_regclass('public.fin_cs_vinculo') is not null then
    execute $q$
      insert into public.cs_bak_164_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
      select 'fin_cs_vinculo', to_jsonb(v), p.cierra_id, p.queda_id
      from public.fin_cs_vinculo v join pares164 p on p.cierra_id = v.cs_cliente_id
      where v.estado = 'vinculado' $q$;
    execute $q$
      update public.fin_cs_vinculo v set cs_cliente_id = p.queda_id
        from pares164 p
       where v.cs_cliente_id = p.cierra_id and v.estado = 'vinculado' $q$;
  end if;
end $$;

-- 2f. notas de la cerrada al final de las de la vigente (si no están ya) + marca de qué fichas se fusionaron
update public.cs_clientes q
   set notas = btrim(coalesce(q.notas, '') || case when coalesce(q.notas, '') <> '' then E'\n' else '' end
                     || '[Ficha duplicada cerrada, 164] ' || btrim(c.notas)),
       campos_extra = coalesce(q.campos_extra, '{}'::jsonb)
         || jsonb_build_object('fusion164', coalesce(q.campos_extra->'fusion164', '[]'::jsonb) || jsonb_build_array(c.id))
  from pares164 p
  join public.cs_clientes c on c.id = p.cierra_id
 where q.id = p.queda_id
   and btrim(coalesce(c.notas, '')) <> ''
   and position(btrim(c.notas) in coalesce(q.notas, '')) = 0;

-- 2g. cerrar la sobrante: 'finalizado' + marca (criterio 162), sin offboarding
alter table public.cs_clientes disable trigger cs_trg_after_cierre;
update public.cs_clientes c
   set estado = 'finalizado',
       campos_extra = coalesce(c.campos_extra, '{}'::jsonb)
         || jsonb_build_object('cierre164', jsonb_build_object(
              'fecha', public.cs_hoy(), 'estado_antes', c.estado, 'duplicada_de', p.queda_id,
              'motivo', 'ficha duplicada'))
  from pares164 p
 where p.cierra_id = c.id;
alter table public.cs_clientes enable trigger cs_trg_after_cierre;


-- =====================================================================
-- 3. RLS en TODAS las cs_bak_* de public (sin políticas). Dinámico: incluye las 164 y las que se creen antes.
-- =====================================================================
do $$
declare
  t record;
  v_n int := 0;
begin
  for t in
    select schemaname, tablename from pg_tables
    where schemaname = 'public' and tablename like 'cs\_bak\_%' and not rowsecurity
  loop
    execute format('alter table %I.%I enable row level security', t.schemaname, t.tablename);
    v_n := v_n + 1;
  end loop;
  raise notice 'cs 164: RLS activado en % tablas de respaldo', v_n;
end $$;


-- =====================================================================
-- VERIFICACIÓN dentro de la transacción: si algo no quedó como se espera, aborta y no se guarda nada
-- =====================================================================
do $$
declare
  v_n int;
begin
  select count(*) into v_n from fichas164 f join public.cs_clientes c on c.id = f.id
   where c.fecha_fin = f.esperada and c.aviso_1_at is null and c.aviso_2_at is null;
  if v_n <> 12 then raise exception 'cs 164: solo % de 12 fichas quedaron con la fecha esperada', v_n; end if;

  select count(*) into v_n from pares164 p
   join public.cs_clientes c on c.id = p.cierra_id and c.estado = 'finalizado' and c.campos_extra ? 'cierre164';
  if v_n <> 3 then raise exception 'cs 164: solo % de 3 fichas duplicadas quedaron cerradas', v_n; end if;

  select count(*) into v_n from pg_tables
   where schemaname = 'public' and tablename like 'cs\_bak\_%' and not rowsecurity;
  if v_n <> 0 then raise exception 'cs 164: quedan % tablas cs_bak_* sin RLS', v_n; end if;
end $$;

commit;


-- =====================================================================
-- CONTROLES (comentados; correr de a uno DESPUÉS del commit; sin nombres de alumnos)
-- =====================================================================
-- C1. Las 12 fechas (esperado: 12 filas, todas ok = true).
-- select left(c.id::text, 8) as ficha, c.fecha_fin, v.esperada, (c.fecha_fin = v.esperada) as ok,
--        c.aviso_1_at is null as aviso1_limpio, c.aviso_2_at is null as aviso2_limpio, c.estado
-- from (values ('55085941', date '2026-11-24'), ('97434d66', date '2027-03-23'), ('5bce0da5', date '2027-01-15'),
--              ('6116c9dd', date '2027-04-10'), ('f256102b', date '2026-10-30'), ('463440b5', date '2026-11-06'),
--              ('edcd8e77', date '2027-03-17'), ('6c938078', date '2027-01-11'), ('7c61fd78', date '2027-04-17'),
--              ('c82112ca', date '2027-05-12'), ('aa20cfc4', date '2027-03-24'), ('b63a9bf2', date '2026-11-19')) v(p, esperada)
-- join public.cs_clientes c on c.id::text like v.p || '%' order by 1;
--
-- C2. Las 3 cerradas (esperado: 3 filas, estado finalizado, duplicada_de = la vigente).
-- select left(c.id::text, 8) as cerrada, c.estado, left(c.campos_extra->'cierre164'->>'duplicada_de', 8) as duplicada_de,
--        c.campos_extra->'cierre164'->>'estado_antes' as estado_antes
-- from public.cs_clientes c where c.campos_extra ? 'cierre164' order by 1;
--
-- C3. Las 3 vigentes (esperado: 3 filas; estado no finalizado salvo vencimiento real; fusion164 con la cerrada).
-- select left(c.id::text, 8) as vigente, c.estado, c.fecha_fin, c.campos_extra->'fusion164' as fusion164,
--        (select count(*) from public.cs_seguimientos s where s.cliente_id = c.id) as seguimientos,
--        (select count(*) from public.cs_renovaciones r where r.cliente_id = c.id) as renovaciones,
--        (select count(*) from public.cs_accionables a where a.cliente_id = c.id) as accionables,
--        (select count(*) from public.cs_clientes_alias a where a.cliente_id = c.id) as alias
-- from public.cs_clientes c
-- where c.id::text like any (array['28d200e3%', '5955e47d%', '17d1c875%']) order by 1;
--
-- C4. Qué se movió, por tabla (los de cada tabla suman lo respaldado).
-- select tabla, count(*) as filas from public.cs_bak_164_hijos group by 1 order by 1;
--
-- C5. Cuántas cs_bak_* siguen sin RLS (esperado: 0) y cuántas tienen políticas (esperado: 0 filas).
-- select count(*) as sin_rls from pg_tables where schemaname = 'public' and tablename like 'cs\_bak\_%' and not rowsecurity;
-- select schemaname, tablename, policyname from pg_policies where schemaname = 'public' and tablename like 'cs\_bak\_%';
--
-- C6. Lo que quedó colgando de las cerradas (NO se movió a propósito; informativo): llamadas y sus hijas, wins, etc.
-- select left(c.id::text, 8) as cerrada,
--        (select count(*) from public.cs_llamadas x where x.cliente_id = c.id) as llamadas,
--        (select count(*) from public.cs_wins x where x.cliente_id = c.id) as wins,
--        (select count(*) from public.cs_satisf_envios x where x.cliente_id = c.id) as satisfaccion,
--        (select count(*) from public.cs_renovaciones x where x.cliente_id = c.id) as renovaciones_que_quedaron,
--        (select count(*) from public.cs_accionables x where x.cliente_id = c.id) as accionables_que_quedaron
-- from public.cs_clientes c where c.campos_extra ? 'cierre164' order by 1;
--
-- C7. Fichas de las 12 con renovación abierta o estado en_renovacion (informativo: la 164 no cambia estado).
-- select left(c.id::text, 8) as ficha, c.estado,
--        exists (select 1 from public.cs_renovaciones r where r.cliente_id = c.id and public.cs_ren_abierta(r.estado)) as renovacion_abierta
-- from public.cs_clientes c
-- where c.id::text like any (array['55085941%','97434d66%','5bce0da5%','6116c9dd%','f256102b%','463440b5%',
--                                  'edcd8e77%','6c938078%','7c61fd78%','c82112ca%','aa20cfc4%','b63a9bf2%'])
--   and (c.estado = 'en_renovacion' or exists (select 1 from public.cs_renovaciones r where r.cliente_id = c.id and public.cs_ren_abierta(r.estado)));
--
-- C8. Renovaciones 'en_proceso' o que pasan la fecha de la vigente y quedaron en la cerrada (a mirar a mano).
-- select left(r.cliente_id::text, 8) as cerrada, r.estado, r.nueva_fecha_fin
-- from public.cs_renovaciones r join public.cs_clientes c on c.id = r.cliente_id and c.campos_extra ? 'cierre164' order by 1;
--
-- C9. Historial de las 12 fechas (esperado: una fila por ficha con campo fecha_fin de hoy).
-- select left(registro_id::text, 8) as ficha, campo, valor_anterior, valor_nuevo, at from public.cs_historial
-- where tabla = 'cs_clientes' and campo = 'fecha_fin' and at > now() - interval '1 hour' order by at;


-- =====================================================================
-- VUELTA ATRÁS (comentada; correr completa y en una sola transacción, solo si hace falta)
-- =====================================================================
-- begin;
-- set local lock_timeout = '8s';
-- lock table public.cs_clientes, public.cs_renovaciones, public.cs_accionables, public.cs_seguimientos,
--   public.cs_clientes_mails, public.cs_clientes_alias in share row exclusive mode;
-- -- 1. Fechas y avisos de las 12 fichas
-- update public.cs_clientes c set fecha_fin = r.fecha_fin, aviso_1_at = r.aviso_1_at, aviso_2_at = r.aviso_2_at
--   from public.cs_bak_164_clientes b, lateral jsonb_populate_record(null::public.cs_clientes, b.fila) r
--  where b.motivo = 'fecha_fin' and b.id = c.id;
-- -- 2. Reabrir las cerradas (estado y campos_extra; sin disparar offboarding) y restaurar notas de las vigentes
-- alter table public.cs_clientes disable trigger cs_trg_after_cierre;
-- update public.cs_clientes c set estado = r.estado, campos_extra = r.campos_extra
--   from public.cs_bak_164_clientes b, lateral jsonb_populate_record(null::public.cs_clientes, b.fila) r
--  where b.motivo = 'cerrada' and b.id = c.id;
-- update public.cs_clientes c set notas = r.notas, campos_extra = r.campos_extra
--   from public.cs_bak_164_clientes b, lateral jsonb_populate_record(null::public.cs_clientes, b.fila) r
--  where b.motivo = 'vigente' and b.id = c.id;
-- alter table public.cs_clientes enable trigger cs_trg_after_cierre;
-- -- 3. Accionables completados por la 164
-- update public.cs_accionables a set estado = r.estado, descripcion = r.descripcion, completado_at = r.completado_at
--   from public.cs_bak_164_accionables b, lateral jsonb_populate_record(null::public.cs_accionables, b.fila) r
--  where b.id = a.id;
-- -- 4. Devolver lo movido a la cerrada
-- update public.cs_seguimientos t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_164_hijos b where b.tabla = 'cs_seguimientos' and t.id = (b.fila->>'id')::uuid;
-- alter table public.cs_renovaciones disable trigger cs_trg_20_reglas;
-- update public.cs_renovaciones t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_164_hijos b where b.tabla = 'cs_renovaciones' and t.id = (b.fila->>'id')::uuid;
-- alter table public.cs_renovaciones enable trigger cs_trg_20_reglas;
-- update public.cs_accionables t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_164_hijos b where b.tabla = 'cs_accionables' and t.id = (b.fila->>'id')::uuid;
-- update public.cs_clientes_mails t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_164_hijos b where b.tabla = 'cs_clientes_mails' and t.id = (b.fila->>'id')::uuid;
-- update public.cs_clientes_alias t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_164_hijos b where b.tabla = 'cs_clientes_alias' and t.id = (b.fila->>'id')::uuid;
-- -- fin_cs_vinculo (si existe): se identifica por (cliente_id, alumno_norm) de la fila respaldada
-- update public.fin_cs_vinculo v set cs_cliente_id = b.cliente_id_antes
--   from public.cs_bak_164_hijos b
--  where b.tabla = 'fin_cs_vinculo' and v.cliente_id = b.fila->>'cliente_id' and v.alumno_norm = b.fila->>'alumno_norm';
-- -- 5. Respaldos: se dejan (con RLS). Para borrarlos más adelante: drop table public.cs_bak_164_clientes, ...
-- -- La RLS de las cs_bak_* NO se revierte (es lo seguro; no depende de esta migración).
-- commit;
