-- =====================================================================
-- 079-producto-accesos-checks-corte.sql  ·  PRODUCTO: accesos por usuario,
-- checks por paso en el Maestro y corte del Maestro de liam
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), DESPUÉS
-- de la 075 de Finanzas (que da de alta a los 6 usuarios en crm_members y
-- crm_asignaciones). Los usuarios ya tienen que existir en Authentication:
--   fundador@agencia.dystopia   producto@liam.dystopia   cliente@liam.dystopia
--   ventas@, finanzas@ y contenido@ liam.dystopia (no entran a Producto).
-- Si falta alguno, no falla: ese usuario simplemente no queda dado de alta
-- (el control 02 lo muestra).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
-- Evitar :00, :15, :30 y :45 y las 9:00.
--
-- Qué hace:
--   1. cs_accesos: qué usuario entra a qué programa de Producto y con qué
--      nivel ('lectura' o 'edicion'). Fundador (crm_members.rol) no necesita
--      fila: ve y edita todo. Es la única tabla nueva.
--   2. cs_puede_ver(programa) pasa a leer cs_accesos (antes: rol 'cliente' de
--      crm_members + crm_asignaciones). Eso corta a cualquier usuario de otra
--      área que otra app haya dejado como 'cliente' de liam.
--      cs_puede_editar(programa) es nueva: fundador o nivel 'edicion'.
--   3. Toda política de escritura (insert/update) de las tablas cs_* que usaba
--      cs_puede_ver pasa a cs_puede_editar. Borrar sigue siendo solo fundador
--      (cs_puede_borrar). Las dos funciones security definer que escriben
--      (cs_crear_cliente_desde_pago y cs_descartar_alta) se parchean igual.
--      Las funciones security invoker (cs_registrar_contacto,
--      cs_guardar_campo_extra) escriben por las políticas, no necesitan parche.
--   4. Altas en cs_accesos: cliente@liam = lectura, producto@liam = edicion;
--      ventas@, finanzas@ y contenido@ sin fila. No escribe en crm_members:
--      el rol de área de cada usuario lo da la 075 (corre ANTES).
--   5. Checks por paso del Maestro de liam: columnas "casilla" (071) que
--      tilda el CSM. Las editan fundador y producto (cs_guardar_campo_extra
--      pasa por la política de cs_clientes). Cambiar la estructura de
--      columnas sigue siendo solo fundador.
--   6. Corte: cs_programas.maestro_cortado_en de liam = ahora (si no estaba).
--      Producto no tiene sync con Sheets (FASE0 §1): el "corte" es esta marca,
--      que usa 070 para las altas desde Finanzas. Desde ya, el Maestro de la
--      app es la fuente de liam.
--
-- No toca: datos de clientes, accionables, renovaciones, otros programas.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Locks juntos al principio (las políticas y funciones se reemplazan).
do $$
declare
  v_tablas text;
begin
  select string_agg(distinct format('public.%I', p.tablename), ', ') into v_tablas
  from pg_policies p
  where p.schemaname = 'public' and p.tablename like 'cs\_%' and p.cmd in ('INSERT', 'UPDATE')
    and (coalesce(p.qual, '') like '%cs_puede_ver%' or coalesce(p.with_check, '') like '%cs_puede_ver%');
  if v_tablas is not null then
    execute 'lock table ' || v_tablas || ' in access exclusive mode';
  end if;
end $$;


-- =====================================================================
-- 1. cs_accesos
-- =====================================================================
create table if not exists public.cs_accesos (
  user_id      uuid not null references auth.users(id) on delete cascade,
  programa_id  text not null references public.cs_programas(id) on delete cascade,
  nivel        text not null check (nivel in ('lectura', 'edicion')),
  created_at   timestamptz not null default now(),
  primary key (user_id, programa_id)
);
comment on table public.cs_accesos is
  'Acceso de un usuario a un programa de Producto (079). lectura = ve todo y no escribe; edicion = ve y edita. El fundador (crm_members) no necesita fila. Se administra desde el SQL Editor.';

alter table public.cs_accesos enable row level security;
revoke all on table public.cs_accesos from anon;
revoke all on table public.cs_accesos from authenticated;
grant select on table public.cs_accesos to authenticated;
drop policy if exists cs_accesos_ver on public.cs_accesos;
create policy cs_accesos_ver on public.cs_accesos
  for select to authenticated
  using (user_id = auth.uid() or coalesce(public.es_fundador(), false));
-- Sin políticas de escritura: nadie escribe desde la app.


-- =====================================================================
-- 2. FUNCIONES DE ACCESO
-- =====================================================================
-- 'edicion' | 'lectura' | null (sin acceso).
create or replace function public.cs_nivel_programa(p_programa text)
returns text
language sql stable security definer set search_path = public
as $$
  select case
           when coalesce(public.es_fundador(), false) then 'edicion'
           else (select a.nivel from public.cs_accesos a
                 where a.user_id = auth.uid() and a.programa_id = p_programa)
         end
$$;

create or replace function public.cs_puede_ver(p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.cs_nivel_programa(p_programa) is not null
$$;

create or replace function public.cs_puede_editar(p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.cs_nivel_programa(p_programa) = 'edicion', false)
$$;

revoke all on function public.cs_nivel_programa(text) from public, anon;
revoke all on function public.cs_puede_ver(text) from public, anon;
revoke all on function public.cs_puede_editar(text) from public, anon;
grant execute on function public.cs_nivel_programa(text) to authenticated;
grant execute on function public.cs_puede_ver(text) to authenticated;
grant execute on function public.cs_puede_editar(text) to authenticated;


-- =====================================================================
-- 3. POLÍTICAS DE ESCRITURA: cs_puede_ver -> cs_puede_editar
-- =====================================================================
-- Solo INSERT y UPDATE. Las de lectura (SELECT) y borrado no se tocan.
do $$
declare
  r record;
begin
  for r in
    select p.tablename, p.policyname, p.qual, p.with_check
    from pg_policies p
    where p.schemaname = 'public' and p.tablename like 'cs\_%' and p.cmd in ('INSERT', 'UPDATE')
      and (coalesce(p.qual, '') like '%cs_puede_ver%' or coalesce(p.with_check, '') like '%cs_puede_ver%')
  loop
    execute format('alter policy %I on public.%I %s', r.policyname, r.tablename,
      concat_ws(' ',
        case when r.qual is not null then
          'using (' || replace(r.qual, 'cs_puede_ver', 'cs_puede_editar') || ')' end,
        case when r.with_check is not null then
          'with check (' || replace(r.with_check, 'cs_puede_ver', 'cs_puede_editar') || ')' end));
  end loop;
end $$;

-- Funciones security definer que escriben (070): chequean escritura, no lectura.
do $$
declare
  v_firma text;
  v_def   text;
begin
  foreach v_firma in array array[
    'public.cs_crear_cliente_desde_pago(text, text, uuid, text)',
    'public.cs_descartar_alta(text, text, text)'
  ] loop
    if to_regprocedure(v_firma) is null then
      raise notice 'No existe %, se omite (falta 070).', v_firma;
      continue;
    end if;
    v_def := pg_get_functiondef(to_regprocedure(v_firma));
    if v_def like '%cs_puede_ver%' then
      execute replace(v_def, 'cs_puede_ver', 'cs_puede_editar');
    end if;
  end loop;
end $$;


-- =====================================================================
-- 4. ALTAS DE USUARIOS (por mail; si no existe, no hace nada)
-- =====================================================================
-- crm_members NO se toca acá: la 075 (Finanzas) da de alta a los 6 usuarios con
-- su rol de área (fundador, cliente, finanzas, ventas, producto, contenido).
-- Producto solo decide el acceso por cs_accesos.
-- Liam y el equipo de producto: acceso a Producto por programa.
insert into public.cs_accesos (user_id, programa_id, nivel)
select u.id, 'liam', v.nivel
from (values ('cliente@liam.dystopia', 'lectura'),
             ('producto@liam.dystopia', 'edicion')) as v(email, nivel)
join auth.users u on lower(u.email) = v.email
where exists (select 1 from public.cs_programas where id = 'liam')
on conflict (user_id, programa_id) do update set nivel = excluded.nivel;

-- Las otras áreas no entran a Producto.
delete from public.cs_accesos
where user_id in (select u.id from auth.users u
                  where lower(u.email) in ('ventas@liam.dystopia', 'finanzas@liam.dystopia', 'contenido@liam.dystopia'));


-- =====================================================================
-- 5. CHECKS POR PASO DEL MAESTRO DE LIAM
-- =====================================================================
-- Columnas "casilla" (071). El valor va a cs_clientes.campos_extra[clave].
-- Claves fijas (no x_<nombre>_<hex> como las que crea la app) para que la
-- importación de datos las pueda llenar. Quedan al final del Maestro.
-- Se pueden renombrar, mover u ocultar desde "Columnas" (fundador).
-- Los pasos que ya son accionables de la plantilla (sacar de Skool / WPP,
-- referidos, FUP) NO se duplican acá: viven en Accionables.
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, tipo)
select 'liam', v.clave, false, v.etiqueta,
       coalesce((select max(c.orden) from public.cs_maestro_columnas c where c.programa_id = 'liam'), 1000) + v.pos,
       'casilla'
from (values
  (1, 'x_unio_school',  'Se unió a la School'),
  (2, 'x_saque_app',    '¿Lo saqué de la App?')
) as v(pos, clave, etiqueta)
where exists (select 1 from public.cs_programas where id = 'liam')
on conflict (programa_id, clave) do nothing;


-- =====================================================================
-- 6. CORTE DEL MAESTRO DE LIAM
-- =====================================================================
update public.cs_programas
   set maestro_cortado_en = now()
 where id = 'liam' and maestro_cortado_en is null;

commit;


-- =====================================================================
-- 7. QUERY DE CONTROL (ok = true / false; null = informativo)
-- =====================================================================
select '01 tabla cs_accesos' as control, 'existe con RLS' as objeto, 'true' as esperado,
       coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.cs_accesos')), false)::text as obtenido,
       coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.cs_accesos')), false) as ok
union all
select '02 usuarios', u.email, 'creado',
       case when au.id is null then 'FALTA crearlo en Auth' else 'existe' end,
       au.id is not null
from (values ('fundador@agencia.dystopia'), ('cliente@liam.dystopia'), ('producto@liam.dystopia'),
             ('ventas@liam.dystopia'), ('finanzas@liam.dystopia'), ('contenido@liam.dystopia')) as u(email)
left join auth.users au on lower(au.email) = u.email
union all
select '03 acceso a liam', u.email, case when u.email = 'cliente@liam.dystopia' then 'lectura'
                                         when u.email = 'producto@liam.dystopia' then 'edicion'
                                         else 'sin acceso' end,
       coalesce(a.nivel, 'sin acceso'),
       case when au.id is null then null
            else coalesce(a.nivel, 'sin acceso') = case when u.email = 'cliente@liam.dystopia' then 'lectura'
                                                        when u.email = 'producto@liam.dystopia' then 'edicion'
                                                        else 'sin acceso' end end
from (values ('cliente@liam.dystopia'), ('producto@liam.dystopia'),
             ('ventas@liam.dystopia'), ('finanzas@liam.dystopia'), ('contenido@liam.dystopia')) as u(email)
left join auth.users au on lower(au.email) = u.email
left join public.cs_accesos a on a.user_id = au.id and a.programa_id = 'liam'
union all
-- Rol de área que dejó la 075 (contrato común de las 4 apps). Si no coincide, la 075 no corrió.
select '04 rol de area (075)', u.email, u.rol, coalesce(m.rol, 'sin fila en crm_members'),
       case when au.id is null then null else coalesce(m.rol, '') = u.rol end
from (values ('fundador@agencia.dystopia', 'fundador'), ('cliente@liam.dystopia', 'cliente'),
             ('producto@liam.dystopia', 'producto'), ('ventas@liam.dystopia', 'ventas'),
             ('finanzas@liam.dystopia', 'finanzas'), ('contenido@liam.dystopia', 'contenido')) as u(email, rol)
left join auth.users au on lower(au.email) = u.email
left join public.crm_members m on m.user_id = au.id
union all
-- Los roles de otras áreas (ventas, finanzas, contenido) no deben tener fila en cs_accesos.
select '04b area ajena con acceso', count(*)::text, '0', count(*)::text, count(*) = 0
from public.cs_accesos a
join public.crm_members m on m.user_id = a.user_id
where m.rol in ('ventas', 'finanzas', 'contenido')
union all
select '05 politicas de escritura con cs_puede_ver', 'cantidad', '0',
       count(*)::text, count(*) = 0
from pg_policies p
where p.schemaname = 'public' and p.tablename like 'cs\_%' and p.cmd in ('INSERT', 'UPDATE', 'ALL')
  and (coalesce(p.qual, '') like '%cs_puede_ver%' or coalesce(p.with_check, '') like '%cs_puede_ver%')
union all
select '06 funciones de alta/descarte', f.firma, 'usa cs_puede_editar',
       case when to_regprocedure(f.firma) is null then 'no existe'
            when pg_get_functiondef(to_regprocedure(f.firma)) like '%cs_puede_editar%' then 'si' else 'NO' end,
       case when to_regprocedure(f.firma) is null then null
            else pg_get_functiondef(to_regprocedure(f.firma)) like '%cs_puede_editar%' end
from (values ('public.cs_crear_cliente_desde_pago(text, text, uuid, text)'),
             ('public.cs_descartar_alta(text, text, text)')) as f(firma)
union all
select '07 checks de liam', c.clave, 'casilla visible',
       coalesce(c.tipo, '-') || case when c.archivada then ' (archivada)' else '' end,
       c.tipo = 'casilla' and not c.archivada
from public.cs_maestro_columnas c
where c.programa_id = 'liam' and c.clave in ('x_unio_school', 'x_saque_app')
union all
select '08 corte de liam', 'maestro_cortado_en', 'no nulo',
       coalesce(p.maestro_cortado_en::text, 'nulo'), p.maestro_cortado_en is not null
from public.cs_programas p where p.id = 'liam'
union all
-- Informativo: usuarios que antes entraban a Producto como 'cliente' asignado y
-- ahora quedan afuera (no tienen fila en cs_accesos).
select '09 pierden acceso (informativo)', coalesce(au.email, a.user_id::text), 'revisar', 'sin fila en cs_accesos', null
from public.crm_asignaciones a
join public.crm_members m on m.user_id = a.user_id and m.rol = 'cliente'
left join auth.users au on au.id = a.user_id
where a.cliente_id in (select id from public.cs_programas)
  and not exists (select 1 from public.cs_accesos x where x.user_id = a.user_id and x.programa_id = a.cliente_id)
order by 1, 2;
