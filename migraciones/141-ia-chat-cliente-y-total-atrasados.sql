-- =====================================================================
-- 141 · Chat interno "Dystopita": acceso del rol cliente (solo lectura, solo su programa) + total real de atrasados
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 140 (cs_chat_*), 122 (cs_fathom_gestor), 079 (cs_puede_ver / cs_accesos).
--
-- Qué hace
--   1. cs_chat_puede(): fundador, rol producto (edición en algún programa, cs_fathom_gestor) o rol cliente
--      (crm_members.rol = 'cliente') con al menos un programa en cs_accesos.
--   2. cs_chat_exigir() usa cs_chat_puede() en vez de cs_fathom_gestor(). Las 3 consultas siguen siendo SECURITY INVOKER:
--      lo que ve un cliente lo recorta la RLS (cs_puede_ver(programa_id) en cs_programas, cs_clientes, cs_llamadas,
--      cs_accionables, cs_en_que_esta, cs_servicio_config). Un alumno de otro programa no aparece aunque lo pida por
--      nombre, y un programa ajeno da "no encuentro el programa" (cs_chat_programa lee cs_programas con RLS).
--      - Riesgo de abandono: su RLS es cs_puede_editar, así que al cliente le llega null (no lo ve, igual que en la ficha).
--      - Montos: cs_chat_montos sigue siendo solo fundador; el cliente recibe monto_pendiente = null. Las cuotas atrasadas
--        (cantidad y días) salen sin monto, igual que el bloque "Pagos" de la ficha.
--   3. cs_chat_atrasados: suma la columna total_atrasados (cuántos hay en realidad, antes del tope de 60) para que la
--      respuesta pueda decir "mostrando los primeros 60 de N". Cambia el tipo de retorno: se hace drop + create.
--
-- Correr en una sola ejecución, evitando los minutos :00, :15, :30, :45 y las 9:00.
-- Después: volver a desplegar ia-preguntar (--no-verify-jwt) y ver C1 a C5.
-- =====================================================================

begin;
set local lock_timeout = '8s';

do $chk$
begin
  if to_regprocedure('public.cs_chat_exigir()') is null
     or to_regprocedure('public.cs_chat_atrasados(text)') is null then
    raise exception '141: falta la 140 (cs_chat_exigir / cs_chat_atrasados)';
  end if;
  if to_regprocedure('public.cs_fathom_gestor()') is null then
    raise exception '141: falta cs_fathom_gestor (122)';
  end if;
end
$chk$;


-- 1. Quién puede usar el chat
create or replace function public.cs_chat_puede()
returns boolean
language sql stable security definer set search_path = public
as $fn$
  select coalesce(public.cs_fathom_gestor(), false)
      or exists (select 1
                 from public.crm_members m
                 join public.cs_accesos a on a.user_id = m.user_id
                 where m.user_id = auth.uid() and m.rol = 'cliente')
$fn$;
revoke all on function public.cs_chat_puede() from public, anon;
grant execute on function public.cs_chat_puede() to authenticated;


-- 2. El gate de las 3 consultas
create or replace function public.cs_chat_exigir()
returns void
language plpgsql stable set search_path = public
as $fn$
begin
  if not coalesce(public.cs_chat_puede(), false) then
    raise exception 'cs: el chat interno es solo para el fundador, el rol producto y el rol cliente' using errcode = '42501';
  end if;
end;
$fn$;


-- 3. cs_chat_atrasados con total real (mismo cuerpo que la 140 + total_atrasados)
drop function if exists public.cs_chat_atrasados(text);
create function public.cs_chat_atrasados(p_programa text default null)
returns table (
  alumno_id uuid, programa_id text, nombre text, estado text, ultima_llamada date,
  dias_sin_llamada int, sin_llamada boolean, accionables_vencidos int, motivo text, total_atrasados bigint
)
language plpgsql stable set search_path = public
as $fn$
declare
  v_prog text;
  v_hoy  date := public.cs_hoy();
begin
  perform public.cs_chat_exigir();
  if nullif(btrim(coalesce(p_programa, '')), '') is not null then
    v_prog := public.cs_chat_programa(p_programa);
    if v_prog is null then
      raise exception 'cs: no encuentro el programa "%"', p_programa using errcode = '22023';
    end if;
  end if;
  return query
  select c.id, c.programa_id, c.nombre, c.estado, u.ultima_llamada,
         case when u.ultima_llamada is null then null else greatest(0, v_hoy - u.ultima_llamada) end,
         (u.ultima_llamada is null),
         coalesce(a.n, 0)::int,
         concat_ws(' · ',
           case when u.ultima_llamada is null then 'sin ninguna llamada registrada'
                when v_hoy - u.ultima_llamada >= coalesce(k.llamada_aviso_dias, 7)
                  then 'sin llamada hace ' || (v_hoy - u.ultima_llamada) || ' días' end,
           case when coalesce(a.n, 0) > 0 then a.n || case when a.n = 1 then ' accionable vencido' else ' accionables vencidos' end end),
         count(*) over ()      -- se evalúa antes del limit: es el total real
  from public.cs_clientes c
  left join public.cs_v_ultima_llamada u on u.cliente_id = c.id
  left join public.cs_servicio_config k on k.programa_id = c.programa_id
  left join lateral (select count(*) as n from public.cs_accionables x
                     where x.cliente_id = c.id and x.estado <> 'completado' and x.vence < v_hoy) a on true
  where c.estado in ('onboarding', 'activo', 'en_renovacion')
    and (v_prog is null or c.programa_id = v_prog)
    and (u.ultima_llamada is null
         or v_hoy - u.ultima_llamada >= coalesce(k.llamada_aviso_dias, 7)
         or coalesce(a.n, 0) > 0)
  order by (u.ultima_llamada is null) desc, u.ultima_llamada asc, c.nombre
  limit 60;
end;
$fn$;
revoke all on function public.cs_chat_atrasados(text) from public, anon;
grant execute on function public.cs_chat_atrasados(text) to authenticated;


-- Humo (se revierte solo): sin sesión (SQL Editor) nadie pasa.
do $humo$
begin
  if public.cs_chat_puede() is distinct from false then
    raise exception 'HUMO 141: cs_chat_puede deberia ser false sin sesion';
  end if;
  begin
    perform * from public.cs_chat_atrasados('liam');
    raise exception 'HUMO 141: cs_chat_atrasados dejo pasar a alguien sin permiso';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform * from public.cs_chat_en_que_esta('humo');
    raise exception 'HUMO 141: cs_chat_en_que_esta dejo pasar a alguien sin permiso';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform * from public.cs_chat_renovar_o_deuda('liam', 30);
    raise exception 'HUMO 141: cs_chat_renovar_o_deuda dejo pasar a alguien sin permiso';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'HUMO OK: 141';
end
$humo$;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- C1. Funciones (esperado: cs_chat_puede y cs_chat_atrasados con columna total_atrasados).
--   select proname, pg_get_function_result(oid) from pg_proc
--   where pronamespace = 'public'::regnamespace and proname in ('cs_chat_puede', 'cs_chat_atrasados');
--
-- C2. Quién queda habilitado (esperado: fundador, rol producto y clientes con acceso; nadie más).
--   select m.rol, m.nombre, array_agg(a.programa_id order by a.programa_id) as programas
--   from public.crm_members m left join public.cs_accesos a on a.user_id = m.user_id
--   where m.rol = 'cliente' or a.nivel = 'edicion' or m.rol = 'fundador' group by 1, 2 order by 1, 2;
--
-- C3. Aislamiento (SOLO desde la app, logueado como agustinafriedrichs09@gmail.com o cliente@liam.dystopia):
--   - "¿qué alumnos están atrasados?" -> solo alumnos de SU programa.
--   - "¿en qué está <alumno de otro programa>?" -> no lo encuentra.
--   - "¿qué alumnos de teo están atrasados?" (si no es su programa) -> "no encuentro el programa".
--   - "¿quién debe plata?" -> sin montos (monto_pendiente null); riesgo de abandono vacío.
--
-- C4. Cada pregunta deja una fila en ia_uso (funcion 'chat_interno', user_id del cliente).
--   select creado_en, user_id, modelo, ok from public.ia_uso where funcion = 'chat_interno' order by creado_en desc limit 10;
--
-- C5. Total real vs tope (desde la app como fundador, sin programa): si hay más de 60 atrasados la respuesta dice
--   "Mostrando los primeros 60 de N".

-- =====================================================================
-- VUELTA ATRÁS
-- =====================================================================
--   begin;
--   create or replace function public.cs_chat_exigir() returns void language plpgsql stable set search_path = public
--   as $f$ begin
--     if not coalesce(public.cs_fathom_gestor(), false) then
--       raise exception 'cs: el chat interno es solo para el fundador y el rol producto' using errcode = '42501';
--     end if; end; $f$;
--   drop function if exists public.cs_chat_atrasados(text);
--   -- y volver a correr la sección "1. Atrasados o sin llamada" de la 140 (recrea la versión sin total_atrasados).
--   drop function if exists public.cs_chat_puede();
--   commit;
