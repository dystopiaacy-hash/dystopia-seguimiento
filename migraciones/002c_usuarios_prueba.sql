-- =====================================================================
-- 002c_usuarios_prueba.sql  —  Dystopia Seguimiento: 2 usuarios de prueba
-- =====================================================================
-- ANTES de correr esto, crear los 2 usuarios en Supabase:
--   Authentication > Users > Add user > Create new user
--     1) cliente.prueba@example.com   (contraseña fuerte, "Auto Confirm User" tildado)
--     2) editor.prueba@example.com    (ídem)
--
-- Qué hace (solo DATOS en crm_members / crm_asignaciones, no toca ningún
-- objeto crm_* ni las funciones de rol):
--   - cliente.prueba -> rol 'cliente', acceso a liam
--   - editor.prueba  -> rol 'editor',  acceso a liam
-- Idempotente: si ya están cargados, no duplica. Si alguno ya existe en
-- crm_members con OTRO rol, aborta sin tocar nada.
--
-- Para sacarlos: 002d_borrar_usuarios_prueba.sql + borrar los usuarios en
-- Authentication > Users.
--
-- ATENCIÓN: mientras existan, estos usuarios también entran a Dystopia (CRM)
-- con acceso REAL a liam (ver el resumen de la fase).
-- =====================================================================

begin;

do $$
declare
  v_cli uuid;
  v_ed  uuid;
begin
  select id into v_cli from auth.users where lower(email) = 'cliente.prueba@example.com';
  select id into v_ed  from auth.users where lower(email) = 'editor.prueba@example.com';

  if v_cli is null or v_ed is null then
    raise exception 'Faltan usuarios en Authentication: %',
      concat_ws(', ', case when v_cli is null then 'cliente.prueba@example.com' end,
                      case when v_ed  is null then 'editor.prueba@example.com' end);
  end if;

  if exists (select 1 from public.crm_members where user_id = v_cli and rol <> 'cliente')
     or exists (select 1 from public.crm_members where user_id = v_ed and rol <> 'editor') then
    raise exception 'Alguno de los usuarios de prueba ya existe en crm_members con otro rol. No se tocó nada.';
  end if;

  insert into public.crm_members (user_id, rol, nombre)
  select v_cli, 'cliente', 'Prueba cliente (liam)'
  where not exists (select 1 from public.crm_members where user_id = v_cli);

  insert into public.crm_members (user_id, rol, nombre)
  select v_ed, 'editor', 'Prueba editor (liam)'
  where not exists (select 1 from public.crm_members where user_id = v_ed);

  insert into public.crm_asignaciones (user_id, cliente_id)
  select u, 'liam' from unnest(array[v_cli, v_ed]) as u
  where not exists (select 1 from public.crm_asignaciones a where a.user_id = u and a.cliente_id = 'liam');
end $$;

commit;


-- =====================================================================
-- QUERY DE CONTROL (todo ok = true)
-- ve_seguimiento replica cs_puede_ver('liam') para ese usuario:
--   fundador, o rol 'cliente' con asignación a liam. El editor NO ve la app.
-- =====================================================================
with u as (
  select x.email, x.rol_esperado, au.id as user_id
  from (values ('cliente.prueba@example.com', 'cliente', true),
               ('editor.prueba@example.com',  'editor',  false)) as x(email, rol_esperado, ve_esperado)
  left join auth.users au on lower(au.email) = x.email
)
select u.email,
       m.rol,
       (select string_agg(a.cliente_id, ', ' order by a.cliente_id)
          from public.crm_asignaciones a where a.user_id = u.user_id) as asignaciones,
       coalesce(m.rol = 'cliente'
                and exists (select 1 from public.crm_asignaciones a
                            where a.user_id = u.user_id and a.cliente_id = 'liam'), false) as ve_seguimiento,
       (u.user_id is not null
        and m.rol = u.rol_esperado
        and exists (select 1 from public.crm_asignaciones a where a.user_id = u.user_id and a.cliente_id = 'liam')
        and (select count(*) from public.crm_asignaciones a where a.user_id = u.user_id) = 1) as ok
from u
left join public.crm_members m on m.user_id = u.user_id

union all
select 'fundadores (sin cambios)', 'fundador', null,
       null,
       (select count(*) from public.crm_members where rol = 'fundador') = 1;
