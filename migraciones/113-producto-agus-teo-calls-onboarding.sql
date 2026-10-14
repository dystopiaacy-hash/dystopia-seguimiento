-- =====================================================================
-- 113-producto-agus-teo-calls-onboarding.sql  ·  PRODUCTO: programas de Agus y Teo + calls de onboarding
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), primero en el banco de pruebas.
-- Numeración global asignada por el jefe: 113.
-- Evitar :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
--
-- Pedido (revisión visual del 14/10):
--   1. Agus y Teo tienen que aparecer en Producto con su programa, igual que Liam.
--   2. La pantalla Calls está vacía aunque la leyenda dice que la call de onboarding "se crea sola".
--
-- Qué se encontró (por lectura del código y de las migraciones, sin correr nada):
--   - cs_programas ya tiene filas de agus y teo desde la 001 (alta de config "inactivo": el insert
--     de la 001 pone activo = (id = 'liam')). El front las muestra todas las que la RLS deja ver:
--     el fundador ve todas; el resto ve solo las que tienen fila en cs_accesos (079). Quien revisó
--     veía UN solo programa (el título del menú decía "Programa", en singular), o sea, un usuario
--     con acceso solo a liam. Por eso también hace falta decidir los ACCESOS (bloque comentado B).
--   - Calls: la call de onboarding la crea el trigger cs_tg_clientes_after_insert (001/039) SOLO al
--     insertar un cliente con estado = 'onboarding'. Los alumnos de liam se importaron (040/080) como
--     'activo' o 'finalizado' ("si se carga directamente como activo, el onboarding ya se hizo"), por
--     eso no tienen call. La cuenta "115 en onboarding" es de la pestaña Onboarding (onboarding por
--     link, 093/096), que lista a todos los vivos sin link como "sin empezar": otra cosa.
--
-- Qué hace:
--   A. Programas agus y teo: crea la fila si faltara, la ACTIVA y carga, solo si siguen con los
--      valores por defecto (no pisa lo que se haya cambiado a mano): duración por defecto, avisos de
--      renovación (teo 21/10, agus 21/7, de ESTADO-APP Fase 7) y productos (FASE0-PRODUCTO 4.1).
--      Respaldo previo de las dos filas en cs_bak_113_programas.
--   B. Calls: crea la call de onboarding (estado 'pendiente_agendar') a los clientes que HOY están en
--      estado 'onboarding' y no tienen ninguna call de onboarding. Idempotente (not exists). Las
--      creadas llevan notas = 'Creada por la migración 113' (para la vuelta atrás).
--      NO crea calls a los alumnos 'activo' / 'en_renovacion' / 'pausado': serían ~100 filas rojas
--      "sin agendar" de un onboarding que ya pasó.
--
-- No toca: cs_clientes, accionables, vistas, funciones, cron, cs_accesos, cs_onboarding_*.
-- Se puede correr dos veces (on conflict / not exists / update condicionado).
-- [corregida 14/10, banco pglite-113]: respaldos cerrados a anon/authenticated (revoke + RLS), registro de lo creado en
-- cs_bak_113_creados y vuelta atrás que borra solo lo creado por la 113 y no usado. Lo demás, igual al original.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Tablas que lee la app y el cron, bloqueadas juntas y en este orden.
lock table public.cs_programas, public.cs_productos, public.cs_clientes, public.cs_calls
  in share row exclusive mode;

-- Autochequeo: lo que usa esta migración tiene que existir.
do $$
declare
  v_falta text;
begin
  select string_agg(x.t, ', ') into v_falta
  from (values ('cs_programas'), ('cs_productos'), ('cs_clientes'), ('cs_calls')) as x(t)
  where to_regclass('public.' || x.t) is null;
  if v_falta is not null then
    raise exception 'cs 113: faltan tablas: %', v_falta;
  end if;

  select string_agg(x.c, ', ') into v_falta
  from (values ('aviso_1_dias'), ('aviso_2_dias'), ('duracion_default_dias'), ('activo')) as x(c)
  where not exists (select 1 from information_schema.columns k
                     where k.table_schema = 'public' and k.table_name = 'cs_programas' and k.column_name = x.c);
  if v_falta is not null then
    raise exception 'cs 113: faltan columnas de cs_programas (corré la 039 antes): %', v_falta;
  end if;
end $$;


-- =====================================================================
-- A. PROGRAMAS agus y teo
-- =====================================================================

-- Respaldo de cómo estaban (una sola vez: si ya existe no se pisa).
create table if not exists public.cs_bak_113_programas as
  select now() as respaldado_at, p.*
  from public.cs_programas p
  where p.id in ('agus', 'teo');
-- [corregida] Los respaldos no quedan expuestos por la API (los default privileges de Supabase dan ALL a anon y
-- authenticated sobre tablas nuevas de public): igual que cs_bak_106_funciones + RLS sin políticas.
revoke all on table public.cs_bak_113_programas from public, anon, authenticated;
alter table public.cs_bak_113_programas enable row level security;

-- [corregida] Lo que crea ESTA migración (para que la vuelta atrás borre solo eso).
create table if not exists public.cs_bak_113_creados (
  tabla     text not null,
  id        text not null,
  creado_at timestamptz not null default now(),
  primary key (tabla, id)
);
revoke all on table public.cs_bak_113_creados from public, anon, authenticated;
alter table public.cs_bak_113_creados enable row level security;

-- Fila del programa (por si faltara en esta base). El nombre sale de crm_clients si existe.
with ins as (
  insert into public.cs_programas (id, nombre, activo)
  select v.id,
         coalesce((select c.nombre from public.crm_clients c where c.id = v.id), v.nombre),
         true
  from (values ('agus', 'Agus'), ('teo', 'Teo')) as v(id, nombre)
  on conflict (id) do nothing
  returning id
)
insert into public.cs_bak_113_creados (tabla, id) select 'cs_programas', id from ins
on conflict do nothing;

-- Activar. Solo cambia el punto del menú y que el cron los incluya (digest de Discord solo si
-- tienen webhook activo en cs_integraciones: sin eso no se manda nada).
update public.cs_programas
   set activo = true
 where id in ('agus', 'teo') and not activo;

-- Duración por defecto: solo si sigue en el valor de fábrica (90) y el programa es de 120 días.
update public.cs_programas
   set duracion_default_dias = 120
 where id = 'teo' and duracion_default_dias = 90;

-- Avisos de renovación (aviso 1 / aviso 2): solo si siguen en los valores de fábrica (21 / 5).
update public.cs_programas set aviso_2_dias = 10 where id = 'teo'  and aviso_1_dias = 21 and aviso_2_dias = 5;
update public.cs_programas set aviso_2_dias = 7  where id = 'agus' and aviso_1_dias = 21 and aviso_2_dias = 5;

-- Productos (FASE0-PRODUCTO.md 4.1, de las planillas de cada cliente). Los nombres son los de las
-- planillas: se pueden renombrar desde Configuración (fundador). on conflict: no pisa nada.
-- FALTA "Skool" de agus (sin vencimiento): cs_productos.duracion_dias exige > 0 (decisión D6).
with ins as (
insert into public.cs_productos (programa_id, nombre, duracion_dias, orden, activo)
-- 1 mes, 3 meses y 45 días de agus: ya no se venden (Nacho), se crean INACTIVOS (decisión de Joaquín 14/10).
select p.id, x.nombre, x.dias, x.orden, x.nombre not in ('1 mes', '3 meses', '45 días')
from public.cs_programas p
join (values
  ('teo',  'Grupal',    120, 1),
  ('teo',  '1 a 1',     120, 2),
  ('agus', 'Grupal',     90, 1),
  ('agus', '1 a 1',      90, 2),
  ('agus', '1 mes',      30, 3),
  ('agus', '3 meses',    90, 4),
  ('agus', '45 días',    45, 5)
) as x(programa, nombre, dias, orden) on x.programa = p.id
on conflict (programa_id, nombre) do nothing
returning id
)
insert into public.cs_bak_113_creados (tabla, id) select 'cs_productos', id::text from ins
on conflict do nothing;


-- =====================================================================
-- B. ACCESOS (decisión de Joaquín: NO se da ninguno automáticamente)
-- =====================================================================
-- El fundador ya ve todos los programas. Un CSM / producto@ necesita fila en cs_accesos por programa.
-- cliente@liam NO debe ver agus ni teo (es el cliente de Liam). Plantilla, con los mails reales:
--
-- insert into public.cs_accesos (user_id, programa_id, nivel)
-- select u.id, p.programa, 'edicion'
-- from auth.users u
-- cross join (values ('agus'), ('teo')) as p(programa)
-- where lower(u.email) in ('<mail del CSM de agus>')      -- una corrida por programa/mail
--   and p.programa = 'agus'
-- on conflict do nothing;
-- (columnas de cs_accesos: ver 079; revisar con C5 quién tiene acceso hoy)


-- =====================================================================
-- C. CALLS DE ONBOARDING de los clientes que están en onboarding
-- =====================================================================
with ins as (
insert into public.cs_calls (programa_id, cliente_id, tipo, estado, notas, created_by)
select c.programa_id, c.id, 'onboarding', 'pendiente_agendar', 'Creada por la migración 113', c.created_by
from public.cs_clientes c
where c.estado = 'onboarding'
  and not exists (select 1 from public.cs_calls k
                   where k.cliente_id = c.id and k.tipo = 'onboarding')
returning id
)
insert into public.cs_bak_113_creados (tabla, id) select 'cs_calls', id::text from ins
on conflict do nothing;

commit;


-- =====================================================================
-- CONTROLES (correr de a uno; todos son de solo lectura)
-- =====================================================================

-- C1. Programas: agus y teo activos, con duración y avisos. Esperado: 3 filas (liam, agus, teo), activo = true;
--     teo 120 / 21 / 10; agus 90 / 21 / 7 (si no se habían cambiado a mano).
-- select id, nombre, activo, duracion_default_dias, aviso_renovacion_dias, aviso_1_dias, aviso_2_dias, resell_gracia_dias
-- from public.cs_programas order by 1;

-- C2. Productos por programa. Esperado: teo 2, agus 5, liam 5 (+ los que ya tuviera).
-- select programa_id, count(*) as productos, string_agg(nombre || ' (' || duracion_dias || 'd)', ', ' order by orden) as detalle
-- from public.cs_productos group by 1 order by 1;

-- C3. Clientes por programa y estado (informativo: cuántos están realmente en 'onboarding').
-- select programa_id, estado, count(*) from public.cs_clientes group by 1, 2 order by 1, 2;

-- C4. Calls de onboarding: esperado = cantidad de clientes en estado 'onboarding' (C3) y 0 sin call.
-- select
--   (select count(*) from public.cs_clientes where estado = 'onboarding') as clientes_en_onboarding,
--   (select count(*) from public.cs_calls where tipo = 'onboarding') as calls_onboarding,
--   (select count(*) from public.cs_calls where notas = 'Creada por la migración 113') as creadas_por_113,
--   (select count(*) from public.cs_clientes c where c.estado = 'onboarding'
--      and not exists (select 1 from public.cs_calls k where k.cliente_id = c.id and k.tipo = 'onboarding')) as sin_call;

-- C5. Quién tiene acceso a qué programa (para decidir el bloque B).
-- select u.email, a.programa_id, a.nivel
-- from public.cs_accesos a join auth.users u on u.id = a.user_id
-- order by 1, 2;

-- C6. Diagnóstico de "vencido hace N días y sigue Activo" (pantalla Renovaciones y ficha). El cierre diario
--     (cs_cerrar_vencidos, 039) pasa a 'finalizado' a todo cliente con fecha_fin < hoy, SALVO que tenga una
--     renovación 'renovado' con nueva_fecha_fin >= hoy (el cliente no actualizó su fecha_fin: dato inconsistente)
--     o que el cron no esté corriendo. Esta consulta separa los dos casos.
-- select c.programa_id, c.nombre, c.estado, c.fecha_inicio, c.fecha_fin, public.cs_hoy() - c.fecha_fin as dias_vencido,
--        c.renovaciones_count,
--        (select max(r.nueva_fecha_fin) from public.cs_renovaciones r
--          where r.cliente_id = c.id and r.estado = 'renovado') as ultima_nueva_fecha_fin,
--        exists (select 1 from public.cs_renovaciones r
--                 where r.cliente_id = c.id and r.estado = 'renovado'
--                   and r.nueva_fecha_fin >= public.cs_hoy()) as lo_frena_una_renovacion
-- from public.cs_clientes c
-- where c.estado in ('onboarding', 'activo', 'en_renovacion') and c.fecha_fin < public.cs_hoy()
-- order by dias_vencido desc limit 50;

-- C7. ¿Corre el cierre diario? (pg_cron). Esperado: una fila activa con la función del cron de Producto.
-- select jobid, schedule, command, active from cron.job where command ilike '%cs_%' order by jobid;


-- =====================================================================
-- VUELTA ATRÁS (comentada; correr solo si hace falta)
-- =====================================================================
-- begin;
-- -- [corregida] calls creadas por esta migración que nadie tocó (siguen sin agendar y sin fecha)
-- delete from public.cs_calls k
--  using public.cs_bak_113_creados b
--  where b.tabla = 'cs_calls' and b.id = k.id::text
--    and k.estado = 'pendiente_agendar' and k.fecha is null;
-- -- [corregida] productos: SOLO los que creó la 113 y que nadie usa (alumnos, renovaciones, plantilla de onboarding)
-- do $$
-- declare r record;
-- begin
--   for r in select p.id, p.programa_id, p.nombre from public.cs_productos p
--              join public.cs_bak_113_creados b on b.tabla = 'cs_productos' and b.id = p.id::text loop
--     if exists (select 1 from public.cs_clientes c where c.producto_id = r.id)
--        or exists (select 1 from public.cs_renovaciones x where x.producto_id = r.id)
--        or (to_regclass('public.cs_onboarding_plantilla_productos') is not null
--            and exists (select 1 from public.cs_onboarding_plantilla_productos o where o.producto_id = r.id)) then
--       raise notice 'cs 113 vuelta atrás: queda el producto % / % (está en uso)', r.programa_id, r.nombre;
--     else
--       delete from public.cs_productos where id = r.id;
--     end if;
--   end loop;
-- end $$;
-- -- programas: valores de antes
-- update public.cs_programas p
--    set activo = b.activo, duracion_default_dias = b.duracion_default_dias,
--        aviso_1_dias = b.aviso_1_dias, aviso_2_dias = b.aviso_2_dias
--   from public.cs_bak_113_programas b where b.id = p.id;
-- commit;
-- (Las tablas cs_bak_113_programas y cs_bak_113_creados se pueden borrar a mano cuando ya no hagan falta.)
