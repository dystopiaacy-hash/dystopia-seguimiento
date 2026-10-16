-- =====================================================================
-- 168_teo_duplicados.sql  ·  PRODUCTO: cerrar fichas duplicadas de teo (5 fichas)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución). Evitar los minutos :00, :15, :30 y :45
-- (sync de Finanzas), las 9:00 (cron diario de Producto) y una corrida de fathom-sync.
-- Requiere 039 (cs_trg_after_cierre), 071 (campos_extra), 102 / 106 / 122 / 134 / 157 (llamadas y lo que cuelga),
-- 126 (cs_clientes_mails) y 127 (cs_clientes_alias). Usa fin_cs_vinculo (129) solo si existe. No depende de la 164, 165
-- ni 167 (esas son de liam). No crea ni cambia funciones, vistas ni crons.
-- SQL SIN PROBAR (no se pudo correr). NO tiene datos personales: las fichas van por prefijo de uuid. Nada se borra.
--
-- Regla de Joaquín (16/10): en teo se usa UNA FICHA POR CONTRATO. Un par "Grupal finalizada + 1 a 1 activa" de la misma
-- persona NO es duplicado y no se toca. Por eso entran SOLO los pares de abajo; el resto está comentado o afuera.
--
--   cierra     -> queda      motivo
--   7035e559   -> 0eec993e   par 3: mismo teléfono, nombre completo vs sin apellido, las dos Grupal finalizadas
--   19c20b52   -> b9919b53   par 4: misma pareja, las dos Grupal finalizadas
--   90bc7cd1   -> 4cafd013   par 19: mismo teléfono, las dos Grupal (queda la activa)
--   3779d1ba   -> c5d4b039   Sirichilo / Sirichiglio: mismas fechas y producto 1 a 1, la que se cierra no tiene pagos
--   3a115941   -> e9b7d212   Soledad Rivero: mismo teléfono, las dos Grupal activas
--
-- FUERA a propósito (ver las líneas comentadas en pares168_pref): par 7 y los trios Emiliozzi / Mizrahi. Joaquín los
-- nombró, pero son "Grupal finalizada + 1 a 1 activa", justo lo que su regla de una ficha por contrato dice que no
-- se toca. Si confirma que igual se cierran, descomentar las líneas y correr (la guarda no depende de la cantidad).
--
-- "Ya está cerrado" (guarda): la ficha a cerrar no tiene la marca cierre164 / cierre168. El estado 'finalizado' solo NO
-- cuenta: 3 de las 5 ya están finalizadas por vencimiento y siguen siendo duplicados a fusionar. 'baja' sí aborta.
--
-- Qué hace con cada par (patrón 164 + 165):
--   1. MUEVE a la vigente: seguimientos; renovaciones CERRADAS (renovado / no_renovado) que no pasan la fecha_fin de la
--      vigente; accionables manuales; mails extra y alias (fathom-sync asigna a la vigente); vínculo de pagos
--      fin_cs_vinculo; notas (anexadas, marca campos_extra.fusion168). Lo pendiente de plantilla / sistema en la cerrada
--      pasa a 'completado' con nota.
--   2. MUEVE (si hay): llamadas (salvo duplicadas) con accionables, recursos, transcripciones, candidatas a duda y
--      cs_fathom_sin_asignar; wins; envíos de satisfacción; menciones de dudas; onboardings; asistencia a consultorías.
--      Los datos del 16/10 dicen que las fichas a cerrar no tienen nada de esto: queda por si cambió. Triggers de
--      inmutabilidad apagados SOLO dentro de la transacción y vueltos a encender antes del COMMIT (la verificación
--      exige 'O'). Llamadas / wins duplicados NO se mueven ni se borran: quedan en la cerrada y se informan.
--   3. CIERRA la sobrante: estado 'finalizado' + campos_extra.cierre168 (criterio 162; cs_trg_after_cierre apagado
--      durante el UPDATE, sin offboarding).
--   NO mueve (como la 164 / 165): alertas, chequeos, historial, "En qué está", riesgo, upsell, cs_calls, renovaciones
--   'en_proceso', ni el teléfono (ninguno de los 5 pares lo necesita).
--
-- Respaldos con RLS y sin políticas: cs_bak_168_clientes, cs_bak_168_accionables, cs_bak_168_hijos.
-- Controles C1 a C9 y vuelta atrás comentados al final (de a uno).
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- Objetivos (prefijos de uuid)
-- ---------------------------------------------------------------------
create temp table pares168_pref (cierra text primary key, queda text not null) on commit drop;
insert into pares168_pref (cierra, queda) values
  ('7035e559', '0eec993e'),
  ('19c20b52', 'b9919b53'),
  ('90bc7cd1', '4cafd013'),
  ('3779d1ba', 'c5d4b039'),
  ('3a115941', 'e9b7d212');
  -- Pares "Grupal finalizada + 1 a 1 activa" que Joaquín nombró pero la regla de una ficha por contrato deja afuera.
  -- Descomentar SOLO si confirma que se cierran (y pasar la coma al renglón anterior):
  -- ,('292f1982', '1c8e3a88')   -- par 7
  -- ,('1cfdc187', 'dd14d0fa')   -- trío Emiliozzi (Grupal finalizada -> 1 a 1 activa)
  -- ,('e0eb229f', 'dd14d0fa')   -- trío Emiliozzi
  -- ,('345b1abf', '220e7427')   -- trío Mizrahi (Grupal finalizada -> 1 a 1 activa)
  -- ,('8616c138', '220e7427')   -- trío Mizrahi


-- ---------------------------------------------------------------------
-- Autochequeo: lo que usa esta migración tiene que existir y los triggers a apagar estar en 'O'.
-- ---------------------------------------------------------------------
do $$
declare
  v_falta text;
begin
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_clientes'), ('cs_renovaciones'), ('cs_accionables'), ('cs_seguimientos'),
               ('cs_clientes_mails'), ('cs_clientes_alias'), ('cs_llamadas'), ('cs_llamada_accionables'),
               ('cs_llamada_recursos'), ('cs_llamada_transcripciones'), ('cs_duda_candidatas'), ('cs_duda_menciones'),
               ('cs_wins'), ('cs_satisf_envios'), ('cs_onboardings'), ('cs_onboarding_respuestas'),
               ('cs_consultoria_asistentes'), ('cs_fathom_sin_asignar')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 168: faltan tablas (corrieron 102, 106, 122, 126, 127, 134 y 157?): %', v_falta;
  end if;

  select string_agg(r.c, ', ') into v_falta
  from (values ('campos_extra'), ('notas'), ('fecha_fin'), ('estado'), ('programa_id')) as r(c)
  where not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'cs_clientes' and column_name = r.c);
  if v_falta is not null then
    raise exception 'cs 168: faltan columnas en cs_clientes: % (039 y 071)', v_falta;
  end if;

  select string_agg(r.t || '.' || r.n, ', ') into v_falta
  from (values ('cs_clientes', 'cs_trg_after_cierre'), ('cs_renovaciones', 'cs_trg_20_reglas'),
               ('cs_llamadas', 'cs_llamadas_before'), ('cs_llamada_accionables', 'cs_llamada_acc_before'),
               ('cs_llamada_recursos', 'cs_llamada_rec_before'), ('cs_duda_menciones', 'cs_duda_menciones_before'),
               ('cs_wins', 'cs_wins_before')) as r(t, n)
  where not exists (select 1 from pg_trigger g
                    where g.tgrelid = ('public.' || r.t)::regclass and g.tgname = r.n and not g.tgisinternal
                      and g.tgenabled = 'O');
  if v_falta is not null then
    raise exception 'cs 168: faltan triggers o no están habilitados (esta migración los apaga un momento y los vuelve a dejar en O): %', v_falta;
  end if;

  if to_regprocedure('public.cs_hoy()') is null then
    raise exception 'cs 168: falta cs_hoy()';
  end if;
  if to_regclass('public.fin_cs_vinculo') is null then
    raise notice 'cs 168: no existe fin_cs_vinculo (129): se omite el vínculo de pagos';
  end if;
end $$;

-- Todas las tablas que se tocan, juntas y al principio (ya hubo un deadlock por no hacerlo).
-- SHARE ROW EXCLUSIVE también es el lock que pide ALTER TABLE ... DISABLE TRIGGER.
do $$
begin
  execute 'lock table public.cs_clientes, public.cs_renovaciones, public.cs_accionables, public.cs_seguimientos, '
       || 'public.cs_clientes_mails, public.cs_clientes_alias, public.cs_llamadas, public.cs_llamada_accionables, '
       || 'public.cs_llamada_recursos, public.cs_llamada_transcripciones, public.cs_duda_candidatas, '
       || 'public.cs_duda_menciones, public.cs_wins, public.cs_satisf_envios, public.cs_onboardings, '
       || 'public.cs_onboarding_respuestas, public.cs_consultoria_asistentes, public.cs_fathom_sin_asignar'
       || case when to_regclass('public.fin_cs_vinculo') is not null then ', public.fin_cs_vinculo' else '' end
       || ' in share row exclusive mode';
end $$;


-- ---------------------------------------------------------------------
-- Resolución de ids + GUARDA (aborta si algo no es lo esperado; no se modifica nada antes de este punto)
-- ---------------------------------------------------------------------
create temp table pares168 on commit drop as
select pc.cierra as pref_cierra, pc.queda as pref_queda,
       cc.id as cierra_id, qq.id as queda_id,
       cc.programa_id as prog_cierra, qq.programa_id as prog_queda,
       cc.estado as estado_cierra, qq.estado as estado_queda,
       cc.campos_extra as extra_cierra, qq.campos_extra as extra_queda
from pares168_pref pc
join public.cs_clientes cc on cc.id::text like pc.cierra || '%'
join public.cs_clientes qq on qq.id::text like pc.queda || '%';

do $$
declare
  v_mal text;
  v_n   int;
begin
  -- A. cada prefijo resuelve exactamente UNA ficha (si un id no existe, n = 0 y aborta)
  select string_agg(x.p || ' (' || x.n || ')', ', ') into v_mal
  from (select pc.cierra as p, (select count(*) from public.cs_clientes c where c.id::text like pc.cierra || '%') as n from pares168_pref pc
        union all
        select pc.queda, (select count(*) from public.cs_clientes c where c.id::text like pc.queda || '%') from pares168_pref pc) x
  where x.n <> 1;
  if v_mal is not null then
    raise exception 'cs 168: prefijos que no resuelven exactamente una ficha (prefijo (cantidad)): %', v_mal;
  end if;
  select count(*) into v_n from pares168;
  if v_n <> (select count(*) from pares168_pref) then
    raise exception 'cs 168: se resolvieron % pares y se pidieron %', v_n, (select count(*) from pares168_pref);
  end if;

  -- B. todo es de teo y no hay pares repetidos
  select string_agg(pref_cierra || '/' || pref_queda, ', ') into v_mal
  from pares168 where prog_cierra <> 'teo' or prog_queda <> 'teo' or cierra_id = queda_id;
  if v_mal is not null then raise exception 'cs 168: pares que no son de teo o repetidos: %', v_mal; end if;

  -- C. la ficha a cerrar: sin marca de cierre previo (164 / 168) y no de baja
  select string_agg(pref_cierra, ', ') into v_mal
  from pares168
  where coalesce(extra_cierra, '{}'::jsonb) ? 'cierre168' or coalesce(extra_cierra, '{}'::jsonb) ? 'cierre164';
  if v_mal is not null then
    raise exception 'cs 168: la ficha a cerrar ya tiene marca de cierre (ya se corrió esta migración?): %', v_mal;
  end if;
  select string_agg(pref_cierra || ' (estado ' || estado_cierra || ')', ', ') into v_mal
  from pares168 where estado_cierra = 'baja';
  if v_mal is not null then raise exception 'cs 168: la ficha a cerrar está de baja: %', v_mal; end if;

  -- D. la ficha que queda: no de baja ni cerrada como duplicada
  select string_agg(pref_queda || ' (estado ' || estado_queda || ')', ', ') into v_mal
  from pares168 where estado_queda = 'baja';
  if v_mal is not null then raise exception 'cs 168: la ficha que debía quedar vigente está de baja: %', v_mal; end if;
  select string_agg(pref_queda, ', ') into v_mal
  from pares168 where coalesce(extra_queda, '{}'::jsonb) ? 'cierre168' or coalesce(extra_queda, '{}'::jsonb) ? 'cierre164';
  if v_mal is not null then raise exception 'cs 168: la ficha que debía quedar fue cerrada como duplicada: %', v_mal; end if;

  -- E. una ficha no puede ser a la vez la que se cierra y la que queda
  select string_agg(p.pref_cierra, ', ') into v_mal
  from pares168 p where p.cierra_id in (select queda_id from pares168);
  if v_mal is not null then raise exception 'cs 168: una ficha aparece como cerrada y como vigente a la vez: %', v_mal; end if;

  -- F. NO se corrió ya: el respaldo no existe o está vacío
  if to_regclass('public.cs_bak_168_clientes') is not null then
    execute 'select count(*) from public.cs_bak_168_clientes' into v_n;
    if v_n > 0 then
      raise exception 'cs 168: ya se corrió (cs_bak_168_clientes tiene % filas). No se repite.', v_n;
    end if;
  end if;
end $$;


-- =====================================================================
-- 0. RESPALDOS (cs_bak_168_*, con RLS y sin políticas)
-- =====================================================================
create table if not exists public.cs_bak_168_clientes (
  id            uuid not null,
  motivo        text not null check (motivo in ('cerrada', 'vigente')),
  fila          jsonb not null,          -- to_jsonb(cs_clientes) ANTES del cambio
  respaldado_at timestamptz not null default now(),
  primary key (id, motivo)
);
create table if not exists public.cs_bak_168_accionables (
  id            uuid primary key,
  accion        text not null check (accion in ('cerrado')),
  fila          jsonb not null,          -- to_jsonb(cs_accionables) ANTES del cambio
  respaldado_at timestamptz not null default now()
);
create table if not exists public.cs_bak_168_hijos (
  n                  bigserial primary key,
  tabla              text not null,
  fila               jsonb not null,     -- fila ANTES de moverla (sin token ni texto de transcripción)
  cliente_id_antes   uuid,
  cliente_id_despues uuid,
  respaldado_at      timestamptz not null default now()
);
create index if not exists cs_bak_168_hijos_tabla_idx on public.cs_bak_168_hijos (tabla);
revoke all on table public.cs_bak_168_clientes, public.cs_bak_168_accionables, public.cs_bak_168_hijos
  from public, anon, authenticated;
alter table public.cs_bak_168_clientes enable row level security;
alter table public.cs_bak_168_accionables enable row level security;
alter table public.cs_bak_168_hijos enable row level security;

insert into public.cs_bak_168_clientes (id, motivo, fila)
select c.id, 'cerrada', to_jsonb(c) from public.cs_clientes c join pares168 p on p.cierra_id = c.id
on conflict (id, motivo) do nothing;
insert into public.cs_bak_168_clientes (id, motivo, fila)
select c.id, 'vigente', to_jsonb(c) from public.cs_clientes c where c.id in (select queda_id from pares168)
on conflict (id, motivo) do nothing;


-- =====================================================================
-- 1. MOVER a la vigente lo que se conserva (patrón 164)
-- =====================================================================
-- 1a. seguimientos
insert into public.cs_bak_168_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_seguimientos', to_jsonb(s), p.cierra_id, p.queda_id
from public.cs_seguimientos s join pares168 p on p.cierra_id = s.cliente_id;
update public.cs_seguimientos s set cliente_id = p.queda_id
  from pares168 p where s.cliente_id = p.cierra_id;

-- 1b. renovaciones cerradas que no pasan de la fecha_fin de la vigente. cs_trg_20_reglas prohíbe cambiar de cliente:
--     se apaga solo durante este UPDATE (misma transacción, tabla bloqueada).
insert into public.cs_bak_168_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_renovaciones', to_jsonb(r), p.cierra_id, p.queda_id
from public.cs_renovaciones r
join pares168 p on p.cierra_id = r.cliente_id
join public.cs_clientes q on q.id = p.queda_id
where r.estado in ('renovado', 'no_renovado')
  and (r.nueva_fecha_fin is null or r.nueva_fecha_fin <= q.fecha_fin);

alter table public.cs_renovaciones disable trigger cs_trg_20_reglas;
update public.cs_renovaciones r set cliente_id = p.queda_id
  from pares168 p, public.cs_clientes q
 where r.cliente_id = p.cierra_id and q.id = p.queda_id
   and r.estado in ('renovado', 'no_renovado')
   and (r.nueva_fecha_fin is null or r.nueva_fecha_fin <= q.fecha_fin);
alter table public.cs_renovaciones enable trigger cs_trg_20_reglas;

-- 1c. accionables manuales (no chocan con la unique (cliente_id, plantilla_key): no llevan clave)
insert into public.cs_bak_168_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_accionables', to_jsonb(a), p.cierra_id, p.queda_id
from public.cs_accionables a join pares168 p on p.cierra_id = a.cliente_id
where a.origen = 'manual' and a.plantilla_key is null;
update public.cs_accionables a set cliente_id = p.queda_id
  from pares168 p
 where a.cliente_id = p.cierra_id and a.origen = 'manual' and a.plantilla_key is null;

-- Lo pendiente de plantilla / sistema que queda en la cerrada se completa con nota (criterio de la 162), con respaldo.
insert into public.cs_bak_168_accionables (id, accion, fila)
select a.id, 'cerrado', to_jsonb(a)
from public.cs_accionables a join pares168 p on p.cierra_id = a.cliente_id
where a.estado in ('pendiente', 'en_proceso')
on conflict (id) do nothing;
update public.cs_accionables a
   set estado = 'completado',
       descripcion = left(btrim(coalesce(a.descripcion, '') || ' Ficha duplicada cerrada (168).'), 500)
  from pares168 p
 where a.cliente_id = p.cierra_id and a.estado in ('pendiente', 'en_proceso');

-- 1d. mails extra (los que la vigente ya tiene se quedan en la cerrada) y alias (únicos globales)
insert into public.cs_bak_168_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_clientes_mails', to_jsonb(m), p.cierra_id, p.queda_id
from public.cs_clientes_mails m join pares168 p on p.cierra_id = m.cliente_id
where not exists (select 1 from public.cs_clientes_mails m2 where m2.cliente_id = p.queda_id and m2.email = m.email);
update public.cs_clientes_mails m set cliente_id = p.queda_id
  from pares168 p
 where m.cliente_id = p.cierra_id
   and not exists (select 1 from public.cs_clientes_mails m2 where m2.cliente_id = p.queda_id and m2.email = m.email);

insert into public.cs_bak_168_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_clientes_alias', to_jsonb(a), p.cierra_id, p.queda_id
from public.cs_clientes_alias a join pares168 p on p.cierra_id = a.cliente_id;
update public.cs_clientes_alias a set cliente_id = p.queda_id
  from pares168 p where a.cliente_id = p.cierra_id;

-- 1e. vínculo de pagos de Finanzas (solo los vinculados a la cerrada)
do $$
begin
  if to_regclass('public.fin_cs_vinculo') is not null then
    execute $q$
      insert into public.cs_bak_168_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
      select 'fin_cs_vinculo', to_jsonb(v), p.cierra_id, p.queda_id
      from public.fin_cs_vinculo v join pares168 p on p.cierra_id = v.cs_cliente_id
      where v.estado = 'vinculado' $q$;
    execute $q$
      update public.fin_cs_vinculo v set cs_cliente_id = p.queda_id
        from pares168 p
       where v.cs_cliente_id = p.cierra_id and v.estado = 'vinculado' $q$;
  end if;
end $$;

-- 1f. notas de la cerrada al final de las de la vigente (si no están ya) + marca de qué fichas se fusionaron
update public.cs_clientes q
   set notas = btrim(coalesce(q.notas, '') || case when coalesce(q.notas, '') <> '' then E'\n' else '' end
                     || '[Ficha duplicada cerrada, 168] ' || btrim(c.notas)),
       campos_extra = coalesce(q.campos_extra, '{}'::jsonb)
         || jsonb_build_object('fusion168', coalesce(q.campos_extra->'fusion168', '[]'::jsonb) || jsonb_build_array(c.id))
  from pares168 p
  join public.cs_clientes c on c.id = p.cierra_id
 where q.id = p.queda_id
   and btrim(coalesce(c.notas, '')) <> ''
   and position(btrim(c.notas) in coalesce(q.notas, '')) = 0;


-- =====================================================================
-- 2. MOVER llamadas y lo que cuelga de ellas (patrón 165; si no hay nada, no mueve nada)
-- =====================================================================
-- Llamadas de las cerradas, con la marca de duplicada: misma fecha y mismo inicio_at, o misma grabacion_url, o mismo
-- título (sin mayúsculas ni espacios de más) que otra de la vigente. La duplicada NO se mueve ni se borra.
create temp table ll168 on commit drop as
select l.id, p.cierra_id, p.queda_id, l.fecha,
       exists (select 1 from public.cs_llamadas v
               where v.cliente_id = p.queda_id and v.fecha = l.fecha
                 and ((l.inicio_at is not null and v.inicio_at = l.inicio_at)
                   or (l.grabacion_url is not null and v.grabacion_url = l.grabacion_url)
                   or (l.titulo is not null and v.titulo is not null
                       and lower(btrim(l.titulo)) = lower(btrim(v.titulo))))) as dup
from public.cs_llamadas l
join pares168 p on p.cierra_id = l.cliente_id;

create temp table mv_ll168 on commit drop as
select id, cierra_id, queda_id, fecha from ll168 where not dup;

create temp table mv_acc168 on commit drop as
select a.id, l.queda_id from public.cs_llamada_accionables a join mv_ll168 l on l.id = a.llamada_id;

create temp table mv_rec168 on commit drop as
select r.id, p.queda_id
from public.cs_llamada_recursos r
join pares168 p on p.cierra_id = r.cliente_id
left join ll168 l on l.id = r.llamada_id
where r.llamada_id is null or (l.id is not null and not l.dup);

create temp table mv_tr168 on commit drop as
select t.llamada_id, l.queda_id from public.cs_llamada_transcripciones t join mv_ll168 l on l.id = t.llamada_id;

create temp table mv_cand168 on commit drop as
select c.id, l.queda_id from public.cs_duda_candidatas c join mv_ll168 l on l.id = c.llamada_id;

create temp table mv_sin168 on commit drop as
select s.id, l.queda_id from public.cs_fathom_sin_asignar s join mv_ll168 l on l.id = s.llamada_id and s.cliente_id = l.cierra_id;

-- Menciones de duda: las que no chocan en (duda, fecha) con la vigente y no cuelgan de una llamada duplicada.
create temp table mv_men168 on commit drop as
select m.id, p.queda_id
from public.cs_duda_menciones m
join pares168 p on p.cierra_id = m.cliente_id
left join ll168 l on l.id = m.llamada_id
where (m.llamada_id is null or (l.id is not null and not l.dup))
  and not exists (select 1 from public.cs_duda_menciones x
                  where x.cliente_id = p.queda_id and x.duda_id = m.duda_id and x.fecha = m.fecha);

-- Menciones que chocan pero cuelgan de una llamada que se mueve: quedan en la cerrada con llamada_id = null.
create temp table mv_men_null168 on commit drop as
select m.id
from public.cs_duda_menciones m
join pares168 p on p.cierra_id = m.cliente_id
join mv_ll168 l on l.id = m.llamada_id
where exists (select 1 from public.cs_duda_menciones x
              where x.cliente_id = p.queda_id and x.duda_id = m.duda_id and x.fecha = m.fecha);

create temp table mv_win168 on commit drop as
select w.id, p.queda_id
from public.cs_wins w
join pares168 p on p.cierra_id = w.cliente_id
where not exists (select 1 from public.cs_wins x
                  where x.cliente_id = p.queda_id and x.fecha = w.fecha
                    and lower(btrim(x.texto)) = lower(btrim(w.texto)));

create temp table mv_env168 on commit drop as
select e.id, p.queda_id
from public.cs_satisf_envios e
join pares168 p on p.cierra_id = e.cliente_id
where e.momento_id is null
   or not exists (select 1 from public.cs_satisf_envios x where x.cliente_id = p.queda_id and x.momento_id = e.momento_id);

create temp table mv_onb168 on commit drop as
select o.id, p.queda_id
from public.cs_onboardings o
join pares168 p on p.cierra_id = o.cliente_id
where not exists (select 1 from public.cs_onboardings x where x.cliente_id = p.queda_id);

create temp table mv_resp168 on commit drop as
select r.onboarding_id, r.paso_key, o.queda_id
from public.cs_onboarding_respuestas r join mv_onb168 o on o.id = r.onboarding_id;

create temp table mv_asis168 on commit drop as
select a.consultoria_id, p.cierra_id, p.queda_id
from public.cs_consultoria_asistentes a
join pares168 p on p.cierra_id = a.cliente_id
where not exists (select 1 from public.cs_consultoria_asistentes x
                  where x.consultoria_id = a.consultoria_id and x.cliente_id = p.queda_id);

-- Última llamada (vista) de las vigentes ANTES, para comprobar la consistencia después.
create temp table ult168 (queda_id uuid primary key, antes date, mueve date) on commit drop;
insert into ult168 (queda_id, antes, mueve)
select q.queda_id,
       (select max(u.ultima_llamada) from public.cs_v_ultima_llamada u where u.cliente_id = q.queda_id),
       (select max(m.fecha) from mv_ll168 m where m.queda_id = q.queda_id)
from (select distinct queda_id from pares168) q;

-- Conteos por ficha y tabla ANTES.
create temp table cnt168 (momento text, tabla text, ficha uuid, n int) on commit drop;
do $$
declare
  t text;
begin
  foreach t in array array['cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos', 'cs_llamada_transcripciones',
                           'cs_duda_candidatas', 'cs_duda_menciones', 'cs_wins', 'cs_satisf_envios', 'cs_onboardings',
                           'cs_onboarding_respuestas', 'cs_consultoria_asistentes'] loop
    execute format('insert into cnt168 select %L, %L, f.id, (select count(*)::int from public.%I x where x.cliente_id = f.id)
                    from (select cierra_id as id from pares168 union select queda_id from pares168) f',
                   'antes', t, t);
  end loop;
end $$;

-- Resumen de lo que va a pasar (sin nombres).
do $$
declare
  r record;
begin
  for r in
    select p.pref_cierra as cierra, p.pref_queda as queda,
           (select count(*) from ll168 l where l.cierra_id = p.cierra_id) as llamadas,
           (select count(*) from ll168 l where l.cierra_id = p.cierra_id and l.dup) as llamadas_duplicadas,
           (select count(*) from public.cs_wins w where w.cliente_id = p.cierra_id) as wins_total,
           (select count(*) from public.cs_satisf_envios e where e.cliente_id = p.cierra_id) as envios_total,
           (select count(*) from public.cs_onboardings o where o.cliente_id = p.cierra_id) as onboardings_total
    from pares168 p order by 1
  loop
    raise notice 'cs 168: % -> %: llamadas % (duplicadas, se quedan: %), wins %, envios %, onboardings %',
      r.cierra, r.queda, r.llamadas, r.llamadas_duplicadas, r.wins_total, r.envios_total, r.onboardings_total;
  end loop;
end $$;

-- Respaldo de lo que se mueve (sin token ni texto de transcripción: no cambian).
insert into public.cs_bak_168_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_llamadas', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_llamadas x join mv_ll168 m on m.id = x.id
union all
select 'cs_llamada_accionables', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_llamada_accionables x join mv_acc168 m on m.id = x.id
union all
select 'cs_llamada_recursos', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_llamada_recursos x join mv_rec168 m on m.id = x.id
union all
select 'cs_llamada_transcripciones', to_jsonb(x) - 'texto', x.cliente_id, m.queda_id
  from public.cs_llamada_transcripciones x join mv_tr168 m on m.llamada_id = x.llamada_id
union all
select 'cs_duda_candidatas', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_duda_candidatas x join mv_cand168 m on m.id = x.id
union all
select 'cs_fathom_sin_asignar', to_jsonb(x) - 'transcripcion', x.cliente_id, m.queda_id
  from public.cs_fathom_sin_asignar x join mv_sin168 m on m.id = x.id
union all
select 'cs_duda_menciones', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_duda_menciones x join mv_men168 m on m.id = x.id
union all
select 'cs_duda_menciones_llamada_null', to_jsonb(x), x.cliente_id, x.cliente_id
  from public.cs_duda_menciones x join mv_men_null168 m on m.id = x.id
union all
select 'cs_wins', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_wins x join mv_win168 m on m.id = x.id
union all
select 'cs_satisf_envios', to_jsonb(x) - 'token', x.cliente_id, m.queda_id from public.cs_satisf_envios x join mv_env168 m on m.id = x.id
union all
select 'cs_onboardings', to_jsonb(x) - 'token', x.cliente_id, m.queda_id from public.cs_onboardings x join mv_onb168 m on m.id = x.id
union all
select 'cs_onboarding_respuestas', to_jsonb(x), x.cliente_id, m.queda_id
  from public.cs_onboarding_respuestas x join mv_resp168 m on m.onboarding_id = x.onboarding_id and m.paso_key = x.paso_key
union all
select 'cs_consultoria_asistentes', to_jsonb(x) - 'intervenciones', x.cliente_id, m.queda_id
  from public.cs_consultoria_asistentes x join mv_asis168 m on m.consultoria_id = x.consultoria_id and m.cierra_id = x.cliente_id;

-- Triggers de inmutabilidad apagados SOLO acá, dentro de la transacción.
create temp table trg168 (tabla text, trigger text) on commit drop;
insert into trg168 values
  ('cs_llamadas', 'cs_llamadas_before'),
  ('cs_llamada_accionables', 'cs_llamada_acc_before'),
  ('cs_llamada_recursos', 'cs_llamada_rec_before'),
  ('cs_duda_menciones', 'cs_duda_menciones_before'),
  ('cs_wins', 'cs_wins_before');

do $$
declare
  t record;
begin
  for t in select * from trg168 loop
    execute format('alter table public.%I disable trigger %I', t.tabla, t.trigger);
  end loop;
end $$;

-- 2a. Llamadas + todo lo que cuelga de ellas, en UNA sola sentencia (las FK compuestas se chequean al final).
with
  u_ll   as (update public.cs_llamadas x set cliente_id = m.queda_id from mv_ll168 m where x.id = m.id returning x.id),
  u_acc  as (update public.cs_llamada_accionables x set cliente_id = m.queda_id from mv_acc168 m where x.id = m.id returning x.id),
  u_rec  as (update public.cs_llamada_recursos x set cliente_id = m.queda_id from mv_rec168 m where x.id = m.id returning x.id),
  u_tr   as (update public.cs_llamada_transcripciones x set cliente_id = m.queda_id from mv_tr168 m where x.llamada_id = m.llamada_id returning x.llamada_id),
  u_cand as (update public.cs_duda_candidatas x set cliente_id = m.queda_id from mv_cand168 m where x.id = m.id returning x.id),
  u_men  as (update public.cs_duda_menciones x set cliente_id = m.queda_id from mv_men168 m where x.id = m.id returning x.id),
  u_men0 as (update public.cs_duda_menciones x set llamada_id = null from mv_men_null168 m where x.id = m.id returning x.id),
  u_sin  as (update public.cs_fathom_sin_asignar x set cliente_id = m.queda_id from mv_sin168 m where x.id = m.id returning x.id)
select 1;

-- 2b. Wins, envíos de satisfacción, onboardings (con sus respuestas) y asistencia a consultorías.
with
  u_win  as (update public.cs_wins x set cliente_id = m.queda_id from mv_win168 m where x.id = m.id returning x.id),
  u_env  as (update public.cs_satisf_envios x set cliente_id = m.queda_id from mv_env168 m where x.id = m.id returning x.id),
  u_onb  as (update public.cs_onboardings x set cliente_id = m.queda_id from mv_onb168 m where x.id = m.id returning x.id),
  u_resp as (update public.cs_onboarding_respuestas x set cliente_id = m.queda_id from mv_resp168 m
              where x.onboarding_id = m.onboarding_id and x.paso_key = m.paso_key returning x.onboarding_id),
  u_asis as (update public.cs_consultoria_asistentes x set cliente_id = m.queda_id from mv_asis168 m
              where x.consultoria_id = m.consultoria_id and x.cliente_id = m.cierra_id returning x.consultoria_id)
select 1;

-- Triggers de vuelta, siempre.
do $$
declare
  t record;
begin
  for t in select * from trg168 loop
    execute format('alter table public.%I enable trigger %I', t.tabla, t.trigger);
  end loop;
end $$;


-- =====================================================================
-- 3. CERRAR la sobrante: 'finalizado' + marca (criterio 162), sin offboarding
-- =====================================================================
-- Las ya finalizadas por vencimiento quedan finalizadas: solo suman la marca.
alter table public.cs_clientes disable trigger cs_trg_after_cierre;
update public.cs_clientes c
   set estado = 'finalizado',
       campos_extra = coalesce(c.campos_extra, '{}'::jsonb)
         || jsonb_build_object('cierre168', jsonb_build_object(
              'fecha', public.cs_hoy(), 'estado_antes', c.estado, 'duplicada_de', p.queda_id,
              'motivo', 'ficha duplicada'))
  from pares168 p
 where p.cierra_id = c.id;
alter table public.cs_clientes enable trigger cs_trg_after_cierre;


-- =====================================================================
-- VERIFICACIÓN dentro de la transacción: si algo no quedó como se espera, aborta y no se guarda nada
-- =====================================================================
do $$
declare
  t       text;
  v_sale  bigint;
  v_entra bigint;
  v_bak   bigint;
  v_n     bigint;
  v_mal   text;
begin
  -- A. todas las cerradas: finalizado + cierre168 apuntando a su vigente
  select count(*) into v_n from pares168 p
   join public.cs_clientes c on c.id = p.cierra_id and c.estado = 'finalizado'
        and c.campos_extra -> 'cierre168' ->> 'duplicada_de' = p.queda_id::text;
  if v_n <> (select count(*) from pares168) then
    raise exception 'cs 168: solo % de % fichas duplicadas quedaron cerradas', v_n, (select count(*) from pares168);
  end if;

  -- B. las vigentes no cambiaron de estado
  select string_agg(left(b.id::text, 8), ', ') into v_mal
  from public.cs_bak_168_clientes b join public.cs_clientes c on c.id = b.id
  where b.motivo = 'vigente' and (b.fila ->> 'estado') is distinct from c.estado;
  if v_mal is not null then raise exception 'cs 168: una ficha vigente cambió de estado: %', v_mal; end if;

  -- C. no quedó nada movible colgando de las cerradas (164)
  select count(*) into v_n from public.cs_seguimientos s join pares168 p on p.cierra_id = s.cliente_id;
  if v_n > 0 then raise exception 'cs 168: quedaron % seguimientos en las cerradas', v_n; end if;
  select count(*) into v_n from public.cs_clientes_alias a join pares168 p on p.cierra_id = a.cliente_id;
  if v_n > 0 then raise exception 'cs 168: quedaron % alias en las cerradas', v_n; end if;
  select count(*) into v_n from public.cs_accionables a join pares168 p on p.cierra_id = a.cliente_id
   where (a.origen = 'manual' and a.plantilla_key is null) or a.estado in ('pendiente', 'en_proceso');
  if v_n > 0 then raise exception 'cs 168: quedaron % accionables manuales o pendientes en las cerradas', v_n; end if;
  select count(*) into v_n from public.cs_renovaciones r
   join pares168 p on p.cierra_id = r.cliente_id join public.cs_clientes q on q.id = p.queda_id
   where r.estado in ('renovado', 'no_renovado') and (r.nueva_fecha_fin is null or r.nueva_fecha_fin <= q.fecha_fin);
  if v_n > 0 then raise exception 'cs 168: quedaron % renovaciones movibles en las cerradas', v_n; end if;
  select count(*) into v_n from public.cs_clientes_mails m join pares168 p on p.cierra_id = m.cliente_id
   where not exists (select 1 from public.cs_clientes_mails m2 where m2.cliente_id = p.queda_id and m2.email = m.email);
  if v_n > 0 then raise exception 'cs 168: quedaron % mails movibles en las cerradas', v_n; end if;
  if to_regclass('public.fin_cs_vinculo') is not null then
    execute 'select count(*) from public.fin_cs_vinculo v join pares168 p on p.cierra_id = v.cs_cliente_id where v.estado = ''vinculado''' into v_n;
    if v_n > 0 then raise exception 'cs 168: quedaron % vínculos de pagos en las cerradas', v_n; end if;
  end if;

  -- D. llamadas y lo que cuelga: lo que sale de las cerradas = lo que entra a las vigentes = lo respaldado
  foreach t in array array['cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos', 'cs_llamada_transcripciones',
                           'cs_duda_candidatas', 'cs_duda_menciones', 'cs_wins', 'cs_satisf_envios', 'cs_onboardings',
                           'cs_onboarding_respuestas', 'cs_consultoria_asistentes'] loop
    execute format('insert into cnt168 select %L, %L, f.id, (select count(*)::int from public.%I x where x.cliente_id = f.id)
                    from (select cierra_id as id from pares168 union select queda_id from pares168) f',
                   'despues', t, t);

    select coalesce(sum(a.n - d.n), 0) into v_sale
    from cnt168 a join cnt168 d on d.tabla = a.tabla and d.ficha = a.ficha and d.momento = 'despues'
    where a.momento = 'antes' and a.tabla = t and a.ficha in (select cierra_id from pares168);
    select coalesce(sum(d.n - a.n), 0) into v_entra
    from cnt168 a join cnt168 d on d.tabla = a.tabla and d.ficha = a.ficha and d.momento = 'despues'
    where a.momento = 'antes' and a.tabla = t and a.ficha in (select queda_id from pares168);
    select count(*) into v_bak from public.cs_bak_168_hijos b where b.tabla = t;
    if v_sale <> v_entra or v_sale <> v_bak then
      raise exception 'cs 168: % no cuadra: salen % de las cerradas, entran % a las vigentes, respaldadas %', t, v_sale, v_entra, v_bak;
    end if;
  end loop;

  select count(*) into v_n from public.cs_llamadas l join pares168 p on p.cierra_id = l.cliente_id;
  if v_n <> (select count(*) from ll168 where dup) then
    raise exception 'cs 168: quedaron % llamadas en las cerradas y las duplicadas son %', v_n, (select count(*) from ll168 where dup);
  end if;
  select count(*) into v_n from public.cs_llamadas l join mv_ll168 m on m.id = l.id and l.cliente_id = m.queda_id;
  if v_n <> (select count(*) from mv_ll168) then raise exception 'cs 168: no todas las llamadas quedaron en la vigente'; end if;

  select count(*) into v_n from public.cs_llamada_accionables a join public.cs_llamadas l on l.id = a.llamada_id where l.cliente_id <> a.cliente_id;
  if v_n > 0 then raise exception 'cs 168: % accionables de llamada con otro alumno que su llamada', v_n; end if;
  select count(*) into v_n from public.cs_fathom_sin_asignar s join mv_ll168 m on m.id = s.llamada_id where s.cliente_id is distinct from m.queda_id;
  if v_n > 0 then raise exception 'cs 168: % punteros de cs_fathom_sin_asignar sin actualizar', v_n; end if;

  -- última llamada (vista): solo AVISA (para un alumno grupal la vista mide por asistencia a consultorías)
  if to_regclass('public.cs_v_ultima_llamada') is not null then
    select string_agg(left(u.queda_id::text, 8), ', ') into v_mal
    from ult168 u
    where (select max(v.ultima_llamada) from public.cs_v_ultima_llamada v where v.cliente_id = u.queda_id)
          is distinct from greatest(u.antes, u.mueve);
    if v_mal is not null then
      raise notice 'cs 168: la última llamada de la vista no es la esperada para (revisar con C5; puede ser alumno grupal): %', v_mal;
    end if;
  end if;

  -- E. los 7 triggers que se apagaron un momento quedaron habilitados ('O' = origin)
  select string_agg(x.n, ', ') into v_mal
  from (values ('cs_clientes', 'cs_trg_after_cierre'), ('cs_renovaciones', 'cs_trg_20_reglas'),
               ('cs_llamadas', 'cs_llamadas_before'), ('cs_llamada_accionables', 'cs_llamada_acc_before'),
               ('cs_llamada_recursos', 'cs_llamada_rec_before'), ('cs_duda_menciones', 'cs_duda_menciones_before'),
               ('cs_wins', 'cs_wins_before')) as x(t, n)
  where not exists (select 1 from pg_trigger g
                    where g.tgrelid = ('public.' || x.t)::regclass and g.tgname = x.n and g.tgenabled = 'O');
  if v_mal is not null then raise exception 'cs 168: triggers que quedaron deshabilitados: %', v_mal; end if;

  -- F. RLS de los 3 respaldos
  select count(*) into v_n from pg_tables
   where schemaname = 'public' and tablename in ('cs_bak_168_clientes', 'cs_bak_168_accionables', 'cs_bak_168_hijos')
     and rowsecurity;
  if v_n <> 3 then raise exception 'cs 168: los respaldos cs_bak_168_* no tienen todos RLS (% de 3)', v_n; end if;
end $$;

commit;


-- =====================================================================
-- CONTROLES (comentados; correr de a uno DESPUÉS del commit; sin nombres de alumnos)
-- =====================================================================
-- C1. Las cerradas (esperado: 5 filas, estado finalizado, duplicada_de = su vigente).
-- select left(c.id::text, 8) as cerrada, c.estado, left(c.campos_extra->'cierre168'->>'duplicada_de', 8) as duplicada_de,
--        c.campos_extra->'cierre168'->>'estado_antes' as estado_antes
-- from public.cs_clientes c where c.campos_extra ? 'cierre168' order by 1;
--
-- C2. Las vigentes (esperado: 5 filas; estado igual que antes de la 168).
-- select left(c.id::text, 8) as vigente, c.estado, c.fecha_fin, c.campos_extra->'fusion168' as fusion168,
--        (select count(*) from public.cs_seguimientos s where s.cliente_id = c.id) as seguimientos,
--        (select count(*) from public.cs_accionables a where a.cliente_id = c.id) as accionables,
--        (select count(*) from public.cs_clientes_alias a where a.cliente_id = c.id) as alias,
--        (select count(*) from public.cs_llamadas l where l.cliente_id = c.id) as llamadas
-- from public.cs_clientes c
-- where c.id::text like any (array['0eec993e%', 'b9919b53%', '4cafd013%', 'c5d4b039%', 'e9b7d212%']) order by 1;
--
-- C3. Qué se movió, por tabla (suma de lo respaldado).
-- select tabla, count(*) as filas, count(distinct cliente_id_despues) as vigentes from public.cs_bak_168_hijos group by 1 order by 1;
--
-- C4. Pagos: los vínculos de Finanzas ahora apuntan a las vigentes (esperado: 0 vinculados a las cerradas).
-- select left(v.cs_cliente_id::text, 8) as ficha, count(*) as vinculos
-- from public.fin_cs_vinculo v
-- where v.estado = 'vinculado'
--   and v.cs_cliente_id::text like any (array['7035e559%', '19c20b52%', '90bc7cd1%', '3779d1ba%', '3a115941%',
--                                             '0eec993e%', 'b9919b53%', '4cafd013%', 'c5d4b039%', 'e9b7d212%'])
-- group by 1 order by 1;
--
-- C5. Última llamada de las vigentes (la vista; "días sin llamada" sale de acá).
-- select left(u.cliente_id::text, 8) as ficha, u.ultima_llamada, u.fuente, (current_date - u.ultima_llamada) as dias
-- from public.cs_v_ultima_llamada u
-- where u.cliente_id::text like any (array['0eec993e%', 'b9919b53%', '4cafd013%', 'c5d4b039%', 'e9b7d212%']) order by 1;
--
-- C6. Lo que quedó en las cerradas (informativo: llamadas duplicadas, alertas, calls viejas).
-- select left(c.id::text, 8) as cerrada,
--        (select count(*) from public.cs_llamadas x where x.cliente_id = c.id) as llamadas,
--        (select count(*) from public.cs_alertas x where x.cliente_id = c.id and not x.resuelta) as alertas_sin_resolver,
--        (select count(*) from public.cs_calls x where x.cliente_id = c.id) as calls_viejas,
--        (select count(*) from public.cs_wins x where x.cliente_id = c.id) as wins,
--        (select count(*) from public.cs_renovaciones x where x.cliente_id = c.id) as renovaciones
-- from public.cs_clientes c where c.campos_extra ? 'cierre168' order by 1;
--
-- C7. Las fichas que NO se tocaron siguen sin marca (esperado: 0 filas).
-- select left(c.id::text, 8) as ficha from public.cs_clientes c
-- where c.campos_extra ? 'cierre168'
--   and c.id::text like any (array['292f1982%', '1cfdc187%', 'e0eb229f%', '345b1abf%', '8616c138%', '021dcdf6%', '7622f87f%',
--                                   '1ede642b%', '1d46c295%', '6c4b50be%', '87cba207%', 'ff3f84de%', 'b07c4dea%', 'd0ab664b%']);
--
-- C8. Los 7 triggers habilitados (esperado: 7 filas, todas 'O').
-- select c.relname as tabla, g.tgname, g.tgenabled
-- from pg_trigger g join pg_class c on c.oid = g.tgrelid
-- where not g.tgisinternal and c.relnamespace = 'public'::regnamespace
--   and g.tgname in ('cs_trg_after_cierre', 'cs_trg_20_reglas', 'cs_llamadas_before', 'cs_llamada_acc_before',
--                    'cs_llamada_rec_before', 'cs_duda_menciones_before', 'cs_wins_before')
-- order by 1;
--
-- C9. RLS de los respaldos (esperado: 3 filas con rowsecurity = true; 0 filas en políticas).
-- select tablename, rowsecurity from pg_tables where schemaname = 'public' and tablename like 'cs\_bak\_168\_%';
-- select policyname from pg_policies where schemaname = 'public' and tablename like 'cs\_bak\_168\_%';


-- =====================================================================
-- VUELTA ATRÁS (comentada; correr completa y en una sola transacción, solo si hace falta)
-- =====================================================================
-- Reabre las cerradas, devuelve lo movido y restaura notas. Lo cargado DESPUÉS de la 168 en las vigentes (llamadas
-- nuevas de Fathom, etc.) no se toca. Los respaldos se dejan (con RLS). Para correr la 168 de nuevo hay que vaciarlos
-- (delete from public.cs_bak_168_clientes), porque la guarda lo detecta como "ya corrida".
-- begin;
-- set local lock_timeout = '8s';
-- lock table public.cs_clientes, public.cs_renovaciones, public.cs_accionables, public.cs_seguimientos,
--   public.cs_clientes_mails, public.cs_clientes_alias, public.cs_llamadas, public.cs_llamada_accionables,
--   public.cs_llamada_recursos, public.cs_llamada_transcripciones, public.cs_duda_candidatas, public.cs_duda_menciones,
--   public.cs_wins, public.cs_satisf_envios, public.cs_onboardings, public.cs_onboarding_respuestas,
--   public.cs_consultoria_asistentes, public.cs_fathom_sin_asignar, public.fin_cs_vinculo in share row exclusive mode;
-- -- 1. Reabrir las cerradas (estado y campos_extra; sin disparar offboarding) y restaurar notas de las vigentes
-- alter table public.cs_clientes disable trigger cs_trg_after_cierre;
-- update public.cs_clientes c set estado = r.estado, campos_extra = r.campos_extra
--   from public.cs_bak_168_clientes b, lateral jsonb_populate_record(null::public.cs_clientes, b.fila) r
--  where b.motivo = 'cerrada' and b.id = c.id;
-- update public.cs_clientes c set notas = r.notas, campos_extra = r.campos_extra
--   from public.cs_bak_168_clientes b, lateral jsonb_populate_record(null::public.cs_clientes, b.fila) r
--  where b.motivo = 'vigente' and b.id = c.id;
-- alter table public.cs_clientes enable trigger cs_trg_after_cierre;
-- -- 2. Accionables completados por la 168
-- update public.cs_accionables a set estado = r.estado, descripcion = r.descripcion, completado_at = r.completado_at
--   from public.cs_bak_168_accionables b, lateral jsonb_populate_record(null::public.cs_accionables, b.fila) r
--  where b.id = a.id;
-- -- 3. Devolver lo movido en el bloque 1 (patrón 164)
-- update public.cs_seguimientos t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_168_hijos b where b.tabla = 'cs_seguimientos' and t.id = (b.fila->>'id')::uuid;
-- alter table public.cs_renovaciones disable trigger cs_trg_20_reglas;
-- update public.cs_renovaciones t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_168_hijos b where b.tabla = 'cs_renovaciones' and t.id = (b.fila->>'id')::uuid;
-- alter table public.cs_renovaciones enable trigger cs_trg_20_reglas;
-- update public.cs_accionables t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_168_hijos b where b.tabla = 'cs_accionables' and t.id = (b.fila->>'id')::uuid;
-- update public.cs_clientes_mails t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_168_hijos b where b.tabla = 'cs_clientes_mails' and t.id = (b.fila->>'id')::uuid;
-- update public.cs_clientes_alias t set cliente_id = b.cliente_id_antes
--   from public.cs_bak_168_hijos b where b.tabla = 'cs_clientes_alias' and t.id = (b.fila->>'id')::uuid;
-- update public.fin_cs_vinculo v set cs_cliente_id = b.cliente_id_antes
--   from public.cs_bak_168_hijos b
--  where b.tabla = 'fin_cs_vinculo' and v.cliente_id = b.fila->>'cliente_id' and v.alumno_norm = b.fila->>'alumno_norm';
-- -- 4. Devolver llamadas y lo que cuelga (patrón 165): triggers apagados solo acá, una sola sentencia por grupo
-- alter table public.cs_llamadas disable trigger cs_llamadas_before;
-- alter table public.cs_llamada_accionables disable trigger cs_llamada_acc_before;
-- alter table public.cs_llamada_recursos disable trigger cs_llamada_rec_before;
-- alter table public.cs_duda_menciones disable trigger cs_duda_menciones_before;
-- alter table public.cs_wins disable trigger cs_wins_before;
-- with
--   u_ll   as (update public.cs_llamadas x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_llamadas' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_acc  as (update public.cs_llamada_accionables x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_llamada_accionables' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_rec  as (update public.cs_llamada_recursos x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_llamada_recursos' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_tr   as (update public.cs_llamada_transcripciones x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_llamada_transcripciones' and x.llamada_id = (b.fila->>'llamada_id')::uuid returning x.llamada_id),
--   u_cand as (update public.cs_duda_candidatas x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_duda_candidatas' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_men  as (update public.cs_duda_menciones x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_duda_menciones' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_men0 as (update public.cs_duda_menciones x set llamada_id = (b.fila->>'llamada_id')::uuid from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_duda_menciones_llamada_null' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_sin  as (update public.cs_fathom_sin_asignar x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_fathom_sin_asignar' and x.id = (b.fila->>'id')::uuid returning x.id)
-- select 1;
-- with
--   u_win  as (update public.cs_wins x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_wins' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_env  as (update public.cs_satisf_envios x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_satisf_envios' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_onb  as (update public.cs_onboardings x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_onboardings' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_resp as (update public.cs_onboarding_respuestas x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_onboarding_respuestas' and x.onboarding_id = (b.fila->>'onboarding_id')::uuid
--                 and x.paso_key = b.fila->>'paso_key' returning x.onboarding_id),
--   u_asis as (update public.cs_consultoria_asistentes x set cliente_id = b.cliente_id_antes from public.cs_bak_168_hijos b
--               where b.tabla = 'cs_consultoria_asistentes' and x.consultoria_id = (b.fila->>'consultoria_id')::uuid
--                 and x.cliente_id = b.cliente_id_despues returning x.consultoria_id)
-- select 1;
-- alter table public.cs_llamadas enable trigger cs_llamadas_before;
-- alter table public.cs_llamada_accionables enable trigger cs_llamada_acc_before;
-- alter table public.cs_llamada_recursos enable trigger cs_llamada_rec_before;
-- alter table public.cs_duda_menciones enable trigger cs_duda_menciones_before;
-- alter table public.cs_wins enable trigger cs_wins_before;
-- -- Verificar C8 antes de dar por buena la vuelta atrás.
-- commit;
