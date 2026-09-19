-- =====================================================================
-- 002d_borrar_usuarios_prueba.sql  —  saca los 2 usuarios de prueba
-- =====================================================================
-- Borra SOLO sus filas en crm_asignaciones y crm_members (por email exacto).
-- Después, borrar los usuarios en Authentication > Users (menú ⋯ > Delete user).
-- Lo que hayan cargado en tablas cs_* queda (created_by no es FK): si probaste
-- con datos demo, 002b_borrar_demo.sql se lleva todo lo colgado de clientes demo.
-- Idempotente.
-- =====================================================================

begin;

delete from public.crm_asignaciones
 where user_id in (select id from auth.users
                   where lower(email) in ('cliente.prueba@example.com', 'editor.prueba@example.com'));

delete from public.crm_members
 where user_id in (select id from auth.users
                   where lower(email) in ('cliente.prueba@example.com', 'editor.prueba@example.com'))
   and rol in ('cliente', 'editor');   -- nunca borra un fundador

commit;


-- =====================================================================
-- QUERY DE CONTROL (ok = true). "en_auth" = 1 hasta que los borres en
-- Authentication > Users; eso no afecta el ok.
-- =====================================================================
with u as (
  select id from auth.users
  where lower(email) in ('cliente.prueba@example.com', 'editor.prueba@example.com')
)
select (select count(*) from u)                                                           as en_auth,
       (select count(*) from public.crm_members      where user_id in (select id from u)) as en_crm_members,
       (select count(*) from public.crm_asignaciones where user_id in (select id from u)) as en_crm_asignaciones,
       (select count(*) from public.crm_members where rol = 'fundador')                   as fundadores,
       (select count(*) from public.crm_members      where user_id in (select id from u)) = 0
   and (select count(*) from public.crm_asignaciones where user_id in (select id from u)) = 0
   and (select count(*) from public.crm_members where rol = 'fundador') = 1               as ok;
