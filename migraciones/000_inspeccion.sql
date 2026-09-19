-- =====================================================================
-- 000_inspeccion.sql — SOLO LECTURA. No crea, modifica ni borra nada.
-- Correr en el SQL Editor de Supabase (proyecto alxdjcdfpdayucassfub).
--
-- Es UNA sola consulta (UNION ALL) porque el SQL Editor muestra solo el
-- resultado de la última sentencia. Devuelve filas (seccion, orden, objeto, detalle).
-- Pegame el resultado completo (botón "Copy" / "Export CSV").
--
-- Secciones:
--  01 funciones es_fundador / rol_actual / tiene_acceso (definición completa)
--  02 columnas de crm_clients, crm_members, crm_asignaciones
--  03 filas de crm_clients (solo id y nombre)
--  04 valores distintos de rol en crm_members (con cantidad)
--  05 extensiones pg_cron y pg_net (disponible / instalada)
--  06 tablas y vistas en public
--  07 objetos cs_* existentes (debería decir "ninguno")
--  08 versión de Postgres y soporte de security_invoker (>= 15)
--  09 RLS activado en tablas crm_*            (extra, para replicar en Fase 1)
--  10 políticas RLS de tablas crm_*           (extra, para replicar en Fase 1)
--  11 tablas en la publicación supabase_realtime (extra, para state.js)
-- =====================================================================

with
s01 as (
  select '01_funcion'::text as seccion, 0 as orden,
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as objeto,
         'security_definer=' || p.prosecdef::text || E'\n' || pg_get_functiondef(p.oid) as detalle
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('es_fundador', 'rol_actual', 'tiene_acceso')
),
s02 as (
  select '02_columna', c.ordinal_position::int,
         c.table_name || '.' || c.column_name,
         c.data_type
           || case when c.is_nullable = 'NO' then ' not null' else '' end
           || coalesce(' default ' || c.column_default, '')
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name in ('crm_clients', 'crm_members', 'crm_asignaciones')
),
s03 as (
  -- to_jsonb evita fallar si la columna se llama "nombre" o "name".
  select '03_crm_client', 0,
         to_jsonb(c) ->> 'id',
         coalesce(to_jsonb(c) ->> 'nombre', to_jsonb(c) ->> 'name', '(sin columna nombre/name)')
  from public.crm_clients c
),
s04 as (
  select '04_rol', 0,
         coalesce(to_jsonb(m) ->> 'rol', to_jsonb(m) ->> 'role', '(sin columna rol/role)'),
         'cantidad=' || count(*)::text
  from public.crm_members m
  group by 3
),
s05 as (
  select '05_extension', 0,
         e.name::text,
         'disponible=' || coalesce(e.default_version, '-') || ' | instalada=' || coalesce(e.installed_version, 'NO')
  from pg_available_extensions e
  where e.name in ('pg_cron', 'pg_net')
  union all
  select '05_extension', 0, x.name, 'NO disponible en este proyecto'
  from (values ('pg_cron'), ('pg_net')) as x(name)
  where not exists (select 1 from pg_available_extensions e where e.name = x.name)
),
s06 as (
  select '06_tabla_public', 0, t.table_name::text, t.table_type::text
  from information_schema.tables t
  where t.table_schema = 'public'
),
s07 as (
  select '07_objeto_cs', 0, n.nspname || '.' || c.relname, 'relkind=' || c.relkind::text
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relname like 'cs\_%'
    and n.nspname not in ('pg_catalog', 'information_schema')
  union all
  select '07_objeto_cs', 0, n.nspname || '.' || p.proname || '()', 'funcion'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where p.proname like 'cs\_%'
    and n.nspname not in ('pg_catalog', 'information_schema')
  union all
  select '07_objeto_cs', 0, 'ninguno', 'OK: no existe ningún objeto cs_*'
  where not exists (
          select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where c.relname like 'cs\_%' and n.nspname not in ('pg_catalog', 'information_schema'))
    and not exists (
          select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where p.proname like 'cs\_%' and n.nspname not in ('pg_catalog', 'information_schema'))
),
s08 as (
  select '08_version', 0,
         current_setting('server_version'),
         'security_invoker_soportado=' || (current_setting('server_version_num')::int >= 150000)::text
           || ' | ' || version()
),
s09 as (
  select '09_rls', 0, c.relname::text,
         'rls=' || c.relrowsecurity::text || ' | forced=' || c.relforcerowsecurity::text
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'crm\_%'
),
s10 as (
  select '10_policy', 0,
         p.tablename || ' / ' || p.policyname,
         'cmd=' || p.cmd || ' | permissive=' || p.permissive || ' | roles=' || array_to_string(p.roles, ',')
           || ' | using=' || coalesce(p.qual, '-') || ' | check=' || coalesce(p.with_check, '-')
  from pg_policies p
  where p.schemaname = 'public' and p.tablename like 'crm\_%'
),
s11 as (
  select '11_realtime', 0, pt.schemaname || '.' || pt.tablename, 'en supabase_realtime'
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime'
  union all
  select '11_realtime', 0, '(ninguna)', 'la publicación no tiene tablas o no existe'
  where not exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime')
)
select * from s01
union all select * from s02
union all select * from s03
union all select * from s04
union all select * from s05
union all select * from s06
union all select * from s07
union all select * from s08
union all select * from s09
union all select * from s10
union all select * from s11
order by seccion, orden, objeto;

-- QUERY DE CONTROL: esta migración es de solo lectura; la consulta de arriba es
-- en sí misma el control. Verificá que aparezcan filas en todas las secciones
-- 01 a 08 (las 3 funciones en 01, y "ninguno" en 07).
