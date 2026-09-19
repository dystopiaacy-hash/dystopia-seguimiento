-- =====================================================================
-- 002b_borrar_demo.sql  —  Dystopia Seguimiento: borra SOLO los datos demo
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase. Se puede correr varias veces.
--
-- Qué se considera demo:
--   - cs_clientes con email @ejemplo.com, y TODO lo colgado de ellos:
--     accionables, devoluciones, calls, renovaciones, chequeos, alertas,
--     respuestas (incluidas las generadas después por la app o por triggers).
--   - cs_formularios cuyo nombre termina en "(demo)" y sus respuestas
--     (aunque no tengan cliente).
--   - cs_historial de todos esos registros (no tiene FK: no se borra en cascada).
--
-- NO toca: cs_programas (ni la plantilla de liam, que es configuración),
-- cs_integraciones, ni nada crm_*. Alertas sin cliente (a nivel programa) no
-- se pueden atribuir a la demo y quedan.
--
-- Los ids se guardan en una tabla temporal (sin ON COMMIT DROP) para que la
-- query de control, que corre después del commit, pueda verificar el historial.
-- =====================================================================

begin;

drop table if exists pg_temp.cs_demo_ids;
create temp table cs_demo_ids (id uuid primary key, tabla text not null);

insert into cs_demo_ids (id, tabla)
select id, 'cs_clientes' from public.cs_clientes where email ilike '%@ejemplo.com';

insert into cs_demo_ids (id, tabla)
select id, 'cs_formularios' from public.cs_formularios where nombre like '%(demo)';

insert into cs_demo_ids (id, tabla)
          select id, 'cs_accionables'  from public.cs_accionables  where cliente_id in (select id from cs_demo_ids where tabla = 'cs_clientes')
union all select id, 'cs_devoluciones' from public.cs_devoluciones where cliente_id in (select id from cs_demo_ids where tabla = 'cs_clientes')
union all select id, 'cs_calls'        from public.cs_calls        where cliente_id in (select id from cs_demo_ids where tabla = 'cs_clientes')
union all select id, 'cs_renovaciones' from public.cs_renovaciones where cliente_id in (select id from cs_demo_ids where tabla = 'cs_clientes')
union all select id, 'cs_chequeos'     from public.cs_chequeos     where cliente_id in (select id from cs_demo_ids where tabla = 'cs_clientes')
union all select id, 'cs_alertas'      from public.cs_alertas      where cliente_id in (select id from cs_demo_ids where tabla = 'cs_clientes')
union all select id, 'cs_respuestas'   from public.cs_respuestas
          where cliente_id    in (select id from cs_demo_ids where tabla = 'cs_clientes')
             or formulario_id in (select id from cs_demo_ids where tabla = 'cs_formularios');

-- Historial primero (no tiene FK). Cubre clientes, sus hijos y formularios.
delete from public.cs_historial where registro_id in (select id from cs_demo_ids);

-- Hijos explícitos (la mayoría también caería por ON DELETE CASCADE, pero
-- cs_respuestas pasaría a cliente_id = null en vez de borrarse).
delete from public.cs_alertas      where id in (select id from cs_demo_ids where tabla = 'cs_alertas');
delete from public.cs_respuestas   where id in (select id from cs_demo_ids where tabla = 'cs_respuestas');
delete from public.cs_chequeos     where id in (select id from cs_demo_ids where tabla = 'cs_chequeos');
delete from public.cs_calls        where id in (select id from cs_demo_ids where tabla = 'cs_calls');
delete from public.cs_accionables  where id in (select id from cs_demo_ids where tabla = 'cs_accionables');
delete from public.cs_devoluciones where id in (select id from cs_demo_ids where tabla = 'cs_devoluciones');
delete from public.cs_renovaciones where id in (select id from cs_demo_ids where tabla = 'cs_renovaciones');
delete from public.cs_clientes     where id in (select id from cs_demo_ids where tabla = 'cs_clientes');
delete from public.cs_formularios  where id in (select id from cs_demo_ids where tabla = 'cs_formularios');

commit;


-- =====================================================================
-- QUERY DE CONTROL (todo ok = true)
--   "borrados" = cuántos ids demo se encontraron en esta corrida.
--   "quedan"   = filas demo que siguen en la tabla (tiene que ser 0).
-- =====================================================================
with demo_cli as (
  select id from cs_demo_ids where tabla = 'cs_clientes'
)
select * from (
  select 1 as orden, 'cs_clientes' as tabla,
         (select count(*) from cs_demo_ids where tabla = 'cs_clientes') as borrados,
         (select count(*) from public.cs_clientes where email ilike '%@ejemplo.com'
             or id in (select id from demo_cli)) as quedan
  union all select 2, 'cs_accionables',
         (select count(*) from cs_demo_ids where tabla = 'cs_accionables'),
         (select count(*) from public.cs_accionables where cliente_id in (select id from demo_cli)
             or id in (select id from cs_demo_ids))
  union all select 3, 'cs_devoluciones',
         (select count(*) from cs_demo_ids where tabla = 'cs_devoluciones'),
         (select count(*) from public.cs_devoluciones where cliente_id in (select id from demo_cli)
             or id in (select id from cs_demo_ids))
  union all select 4, 'cs_calls',
         (select count(*) from cs_demo_ids where tabla = 'cs_calls'),
         (select count(*) from public.cs_calls where cliente_id in (select id from demo_cli)
             or id in (select id from cs_demo_ids))
  union all select 5, 'cs_renovaciones',
         (select count(*) from cs_demo_ids where tabla = 'cs_renovaciones'),
         (select count(*) from public.cs_renovaciones where cliente_id in (select id from demo_cli)
             or id in (select id from cs_demo_ids))
  union all select 6, 'cs_chequeos',
         (select count(*) from cs_demo_ids where tabla = 'cs_chequeos'),
         (select count(*) from public.cs_chequeos where cliente_id in (select id from demo_cli)
             or id in (select id from cs_demo_ids))
  union all select 7, 'cs_alertas',
         (select count(*) from cs_demo_ids where tabla = 'cs_alertas'),
         (select count(*) from public.cs_alertas where cliente_id in (select id from demo_cli)
             or id in (select id from cs_demo_ids))
  union all select 8, 'cs_respuestas',
         (select count(*) from cs_demo_ids where tabla = 'cs_respuestas'),
         (select count(*) from public.cs_respuestas where cliente_id in (select id from demo_cli)
             or id in (select id from cs_demo_ids))
  union all select 9, 'cs_formularios',
         (select count(*) from cs_demo_ids where tabla = 'cs_formularios'),
         (select count(*) from public.cs_formularios where nombre like '%(demo)')
  union all select 10, 'cs_historial',
         null,
         (select count(*) from public.cs_historial where registro_id in (select id from cs_demo_ids))
) t
cross join lateral (select t.quedan = 0 as ok) k

union all
select 20, 'cs_programas (intactos)',
       null,
       count(*),
       count(*) = 5
         and count(*) filter (where id in ('liam','agus','teo','mauro','lucas')) = 5
from public.cs_programas

order by 1;
