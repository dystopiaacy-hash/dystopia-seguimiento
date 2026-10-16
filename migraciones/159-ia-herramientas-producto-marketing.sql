-- =====================================================================
-- 159 · DYSTOPITA RESPONDE DE TODO: HERRAMIENTAS DE PRODUCTO Y MARKETING (SOLO LECTURA) + PUERTA PARA TODOS LOS ROLES
-- Numero asignado por el jefe (16/10). SIN CORRER: el agente no pudo correr SQL.
-- Documentacion: docs/dystopita-herramientas.md (en este repo).
--
-- Requiere (en este orden): 157 (cs_v_modalidad), 158 (ia_chat_cliente / ia_chat_periodo), 141 (cs_chat_exigir / cs_chat_programa),
--   Marketing: 037/051 (crm_publicaciones con likes), 081 (crm_rol_mkt), 138 (crm_ia_analisis).
--
-- Que hace
--   0. ia_chat_acceso(): la puerta de ia-preguntar. Devuelve el rol de quien pregunta si es uno de los 9 que tienen usuario
--      (fundador, producto, cliente, ventas, finanzas, closer, setter, contenido, editor); si no, null. NO decide que ve cada
--      uno: eso lo siguen decidiendo las funciones de cada herramienta y la RLS.
--   1. PRODUCTO  ia_chat_alumnos_resumen(cliente, desde, hasta)
--        conteo de alumnos por estado y modalidad (grupal / vip / sin dato) por cliente, mas altas y vencimientos del periodo.
--   2. MARKETING ia_chat_mkt_piezas(cliente, desde, hasta, plataforma)    piezas PUBLICADAS y sus metricas
--                ia_chat_mkt_pendientes(cliente, etapa)                   por grabar / por editar / por publicar
--                ia_chat_mkt_analisis(cliente, semana)                    analisis IA semanal (138)
--
-- DECISION DE DISENO (igual que la 158): SECURITY INVOKER. Cada funcion lee las mismas tablas que la app, con la RLS de quien
--   pregunta, y ademas valida el rol:
--     - Producto: cs_chat_exigir() (fundador, rol producto o rol cliente con programa). El cliente ve solo su programa por RLS.
--     - Marketing: crm_rol_mkt() en fundador / cliente / editor (contenido cuenta como editor). Producto, ventas, finanzas,
--       closer y setter reciben 42501 ("tu rol no ve Marketing"): crm_publicaciones y crm_ia_analisis les dan 0 filas por RLS.
--   Nunca escriben. Nunca devuelven telefonos, emails ni nombres de alumnos. Errores: 42501 sin permiso; 22023 parametro invalido.
-- Fechas: [desde, hasta] inclusive; sin fechas = este mes hasta hoy (zona Argentina). Maximo ~26 meses.
--
-- Sin tablas nuevas ni cambios de datos: solo create or replace de funciones. Una sola ejecucion, fuera de los minutos
-- :00/:15/:30/:45 y de las 9:00. Controles al final, de a uno. Vuelta atras al final.
-- =====================================================================

begin;
set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (si algo falta, aborta sin crear nada)
-- ---------------------------------------------------------------------
do $g$
declare
  f text;
begin
  foreach f in array array['public.cs_clientes', 'public.cs_v_modalidad', 'public.crm_publicaciones', 'public.crm_ia_analisis', 'public.crm_clients'] loop
    if to_regclass(f) is null then
      raise exception '159: falta % (requiere 157, 138 y las tablas de Marketing)', f;
    end if;
  end loop;
  foreach f in array array['cs_chat_exigir()', 'cs_chat_programa(text)', 'ia_chat_cliente(text)', 'ia_chat_periodo(date,date,boolean)',
                           'crm_rol_mkt()', 'rol_actual()'] loop
    if to_regprocedure('public.' || f) is null then
      raise exception '159: falta la funcion % (requiere 141, 158 y 081)', f;
    end if;
  end loop;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'crm_publicaciones'
         and column_name in ('plataforma', 'idea', 'link', 'fecha_publicacion', 'views', 'comments', 'likes', 'guardados', 'enviados',
                             'estado_grabacion', 'estado_edicion', 'estado_publicacion')) <> 12 then
    raise exception '159: crm_publicaciones no tiene todas las columnas esperadas';
  end if;
  raise notice '159 guardas OK';
end
$g$;

-- ---------------------------------------------------------------------
-- 0. PUERTA: rol de quien pregunta, o null si no es uno de los 9 roles con usuario
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_acceso()
returns text
language sql stable
set search_path = public
as $fn$
  select case when auth.uid() is not null
               and public.rol_actual() in ('fundador', 'producto', 'cliente', 'ventas', 'finanzas', 'closer', 'setter', 'contenido', 'editor')
              then public.rol_actual() end
$fn$;

-- ---------------------------------------------------------------------
-- 1. PRODUCTO · alumnos por estado y modalidad
--    vivos = onboarding + activo + en_renovacion (alumnos en curso); activos = solo estado 'activo'.
--    La modalidad sale de cs_v_modalidad (157): grupal | vip | sin_dato (sin dato se trata como 1 a 1). Se cuenta sobre los vivos.
--    altas_en_periodo = fecha_inicio dentro del periodo; vencen_en_periodo = fecha_fin dentro del periodo (cualquier estado).
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_alumnos_resumen(
  p_cliente text default null, p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_prog text;
  v_d date;
  v_h date;
begin
  perform public.cs_chat_exigir();
  if nullif(btrim(coalesce(p_cliente, '')), '') is not null then
    v_prog := public.cs_chat_programa(p_cliente);
    if v_prog is null then
      raise exception 'no encuentro el programa "%" o no tenes acceso', left(btrim(p_cliente), 40) using errcode = '22023';
    end if;
  end if;
  select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, false) p;
  return (
    with a as (
      select c.programa_id, c.estado, c.fecha_inicio, c.fecha_fin,
             coalesce(m.modalidad, 'sin_dato') as modalidad,
             (c.estado in ('onboarding', 'activo', 'en_renovacion')) as vivo
        from public.cs_clientes c
        left join public.cs_v_modalidad m on m.cliente_id = c.id
       where v_prog is null or c.programa_id = v_prog
    ), pp as (
      select programa_id,
             count(*)::int                                                       as alumnos,
             count(*) filter (where vivo)::int                                   as vivos,
             count(*) filter (where estado = 'onboarding')::int                  as onboarding,
             count(*) filter (where estado = 'activo')::int                      as activos,
             count(*) filter (where estado = 'en_renovacion')::int               as en_renovacion,
             count(*) filter (where estado = 'pausado')::int                     as pausados,
             count(*) filter (where estado = 'finalizado')::int                  as finalizados,
             count(*) filter (where estado = 'baja')::int                        as bajas,
             count(*) filter (where vivo and modalidad = 'grupal')::int          as vivos_grupal,
             count(*) filter (where vivo and modalidad = 'vip')::int             as vivos_vip,
             count(*) filter (where vivo and modalidad = 'sin_dato')::int        as vivos_sin_dato,
             count(*) filter (where fecha_inicio between v_d and v_h)::int       as altas_en_periodo,
             count(*) filter (where fecha_fin between v_d and v_h)::int          as vencen_en_periodo
        from a
       group by programa_id
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('desde', v_d, 'hasta', v_h),
      'programa', v_prog,
      'total', (select jsonb_build_object(
                  'alumnos', coalesce(sum(alumnos), 0)::int, 'vivos', coalesce(sum(vivos), 0)::int,
                  'onboarding', coalesce(sum(onboarding), 0)::int, 'activos', coalesce(sum(activos), 0)::int,
                  'en_renovacion', coalesce(sum(en_renovacion), 0)::int, 'pausados', coalesce(sum(pausados), 0)::int,
                  'finalizados', coalesce(sum(finalizados), 0)::int,
                  'bajas', coalesce(sum(bajas), 0)::int, 'vivos_grupal', coalesce(sum(vivos_grupal), 0)::int,
                  'vivos_vip', coalesce(sum(vivos_vip), 0)::int, 'vivos_sin_dato', coalesce(sum(vivos_sin_dato), 0)::int,
                  'altas_en_periodo', coalesce(sum(altas_en_periodo), 0)::int,
                  'vencen_en_periodo', coalesce(sum(vencen_en_periodo), 0)::int)
                from pp),
      'por_programa', coalesce((select jsonb_agg(to_jsonb(pp) order by pp.vivos desc, pp.programa_id) from pp), '[]'::jsonb),
      'nota', 'vivos = onboarding + activos + en_renovacion (los pausados van aparte y no cuentan como vivos); activos = solo estado activo. La modalidad se cuenta sobre los vivos; sin_dato se trata como 1 a 1. Si preguntan por "activos" sin mas, informa activos y vivos.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- MARKETING · helper de rol
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_mkt_rol()
returns text
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text;
begin
  if auth.uid() is null then
    raise exception 'ia_chat: sin sesion' using errcode = '42501';
  end if;
  v_rol := public.crm_rol_mkt();
  if v_rol is null or v_rol not in ('fundador', 'cliente', 'editor') then
    raise exception 'tu rol no ve los datos de Marketing' using errcode = '42501';
  end if;
  return v_rol;
end
$fn$;

-- ---------------------------------------------------------------------
-- 2a. MARKETING · piezas publicadas del periodo y sus metricas
--     Publicada = estado_publicacion 'PUBLICADO' con fecha_publicacion en el periodo (misma regla que el Dashboard).
--     Las metricas son las cargadas a mano o traidas de las redes: pueden faltar (con_metricas cuenta las que tienen vistas).
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_mkt_piezas(
  p_cliente text default null, p_desde date default null, p_hasta date default null, p_plataforma text default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text := public.ia_chat_mkt_rol();
  v_cli text := public.ia_chat_cliente(p_cliente);
  v_plat text := nullif(lower(btrim(coalesce(p_plataforma, ''))), '');
  v_d date;
  v_h date;
begin
  if v_plat is not null and v_plat not in ('instagram', 'tiktok', 'youtube', 'linkedin', 'carrusel') then
    raise exception 'plataforma invalida: usa instagram, tiktok, youtube, linkedin o carrusel' using errcode = '22023';
  end if;
  select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, false) p;
  return (
    with base as (
      select pb.cliente_id, pb.plataforma, to_char(pb.fecha_publicacion, 'YYYY-MM') as mes, pb.views, pb.comments, pb.likes,
             pb.guardados, pb.enviados
        from public.crm_publicaciones pb
       where pb.estado_publicacion = 'PUBLICADO'
         and pb.fecha_publicacion between v_d and v_h
         and (v_cli is null or pb.cliente_id = v_cli)
         and (v_plat is null or pb.plataforma = v_plat)
    ), g as (
      select cliente_id, plataforma, mes, grouping(cliente_id, plataforma, mes) as nivel,
             count(*)::int                                   as piezas,
             count(views)::int                               as con_metricas,
             coalesce(sum(views), 0)::bigint                 as views,
             coalesce(sum(comments), 0)::bigint              as comments,
             coalesce(sum(likes), 0)::bigint                 as likes,
             coalesce(sum(guardados), 0)::bigint             as guardados,
             coalesce(sum(enviados), 0)::bigint              as enviados,
             round(avg(views))::bigint                       as promedio_views
        from base
       group by grouping sets ((), (cliente_id), (plataforma), (mes))
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('desde', v_d, 'hasta', v_h),
      'cliente', v_cli,
      'plataforma', v_plat,
      'total', (select to_jsonb(t) - array['nivel', 'cliente_id', 'plataforma', 'mes'] from g t where t.nivel = 7),
      'por_cliente', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'plataforma', 'mes'] order by t.piezas desc, t.cliente_id)
                                 from g t where t.nivel = 3), '[]'::jsonb),
      'por_plataforma', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'cliente_id', 'mes'] order by t.piezas desc, t.plataforma)
                                    from g t where t.nivel = 5), '[]'::jsonb),
      'por_mes', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'cliente_id', 'plataforma'] order by t.mes)
                             from g t where t.nivel = 6), '[]'::jsonb),
      'top_por_vistas', coalesce((
        select jsonb_agg(jsonb_build_object('fecha', x.fecha_publicacion, 'cliente_id', x.cliente_id, 'plataforma', x.plataforma,
                                            'idea', left(x.idea, 90), 'views', x.views, 'likes', x.likes, 'comments', x.comments,
                                            'guardados', x.guardados, 'enviados', x.enviados) order by x.views desc)
          from (select pb.fecha_publicacion, pb.cliente_id, pb.plataforma, pb.idea, pb.views, pb.likes, pb.comments, pb.guardados, pb.enviados
                  from public.crm_publicaciones pb
                 where pb.estado_publicacion = 'PUBLICADO' and pb.fecha_publicacion between v_d and v_h
                   and pb.views is not null
                   and (v_cli is null or pb.cliente_id = v_cli) and (v_plat is null or pb.plataforma = v_plat)
                 order by pb.views desc limit 5) x), '[]'::jsonb),
      'nota', 'Cuenta solo piezas PUBLICADAS con fecha de publicacion en el periodo. Las metricas pueden faltar en algunas piezas (con_metricas). El rol ' || v_rol || ' ve solo sus clientes.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- 2b. MARKETING · pendientes de produccion (mismas definiciones que crm_dashboard, 054; sin filtro de fecha)
--     por_grabar   = grabacion PENDIENTE o EN PROCESO
--     por_editar   = GRABADO y edicion vacia / PENDIENTE / EN PROCESO
--     por_publicar = edicion EDITADO y publicacion vacia / PENDIENTE / LISTO PARA PUBLICAR / PROGRAMADO
--     p_etapa ('grabar' | 'editar' | 'publicar') suma hasta 15 piezas de esa etapa, las mas viejas primero.
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_mkt_pendientes(p_cliente text default null, p_etapa text default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text := public.ia_chat_mkt_rol();
  v_cli text := public.ia_chat_cliente(p_cliente);
  v_etapa text := nullif(lower(btrim(coalesce(p_etapa, ''))), '');
begin
  if v_etapa is not null and v_etapa not in ('grabar', 'editar', 'publicar') then
    raise exception 'etapa invalida: usa grabar, editar o publicar' using errcode = '22023';
  end if;
  return (
    with base as (
      select pb.id, pb.cliente_id, pb.plataforma, pb.idea, pb.fecha_publicacion,
             (pb.estado_grabacion in ('PENDIENTE', 'EN PROCESO')) as por_grabar,
             (pb.estado_grabacion = 'GRABADO' and coalesce(pb.estado_edicion, 'PENDIENTE') in ('PENDIENTE', 'EN PROCESO')) as por_editar,
             (pb.estado_edicion = 'EDITADO'
                and coalesce(pb.estado_publicacion, 'PENDIENTE') in ('PENDIENTE', 'LISTO PARA PUBLICAR', 'PROGRAMADO')) as por_publicar
        from public.crm_publicaciones pb
       where v_cli is null or pb.cliente_id = v_cli
    ), pc as (
      select cliente_id,
             count(*) filter (where por_grabar)::int   as por_grabar,
             count(*) filter (where por_editar)::int   as por_editar,
             count(*) filter (where por_publicar)::int as por_publicar
        from base
       group by cliente_id
       having bool_or(por_grabar or por_editar or por_publicar)
    )
    select jsonb_build_object(
      'cliente', v_cli,
      'total', jsonb_build_object('por_grabar', coalesce((select sum(por_grabar) from pc), 0)::int,
                                  'por_editar', coalesce((select sum(por_editar) from pc), 0)::int,
                                  'por_publicar', coalesce((select sum(por_publicar) from pc), 0)::int),
      'por_cliente', coalesce((select jsonb_agg(to_jsonb(pc) order by (pc.por_grabar + pc.por_editar + pc.por_publicar) desc, pc.cliente_id) from pc), '[]'::jsonb),
      'etapa', v_etapa,
      'piezas', case when v_etapa is null then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object('cliente_id', x.cliente_id, 'plataforma', x.plataforma, 'idea', left(x.idea, 90),
                                            'fecha_planificada_o_publicacion', x.fecha_publicacion) order by x.id)
          from (select b.* from base b
                 where (v_etapa = 'grabar' and b.por_grabar) or (v_etapa = 'editar' and b.por_editar) or (v_etapa = 'publicar' and b.por_publicar)
                 order by b.id limit 15) x), '[]'::jsonb) end,
      'nota', 'Pendientes de produccion al dia de hoy, sin filtro de fecha. Una pieza cuenta en una sola etapa segun su estado de grabacion, edicion y publicacion.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- 2c. MARKETING · analisis IA semanal (138). Sin semana = el mas reciente de cada cliente; con semana = el de esa semana
--     (lunes a domingo). Hasta 6 clientes, texto recortado a 3000 caracteres.
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_mkt_analisis(p_cliente text default null, p_semana date default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text := public.ia_chat_mkt_rol();
  v_cli text := public.ia_chat_cliente(p_cliente);
  v_sem date := case when p_semana is null then null else date_trunc('week', p_semana::timestamp)::date end;
begin
  return (
    with a as (
      select distinct on (x.cliente_id) x.cliente_id, x.semana, x.estado, x.texto, x.nota
        from public.crm_ia_analisis x
       where (v_cli is null or x.cliente_id = v_cli)
         and (v_sem is null or x.semana = v_sem)
       order by x.cliente_id, x.semana desc
    ), l as (
      select * from a order by a.semana desc, a.cliente_id limit 6
    )
    select jsonb_build_object(
      'cliente', v_cli,
      'semana_pedida', v_sem,
      'analisis', coalesce((select jsonb_agg(jsonb_build_object('cliente_id', l.cliente_id, 'semana', l.semana, 'estado', l.estado,
                                                               'texto', left(l.texto, 3000), 'nota', l.nota)
                                              order by l.semana desc, l.cliente_id) from l), '[]'::jsonb),
      'nota', 'Es el analisis semanal que genero la IA en Marketing (semana = lunes). Si viene vacio no hay analisis de esa semana todavia.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- Permisos: solo usuarios logueados
-- ---------------------------------------------------------------------
revoke all on function public.ia_chat_acceso() from public, anon;
revoke all on function public.ia_chat_alumnos_resumen(text, date, date) from public, anon;
revoke all on function public.ia_chat_mkt_rol() from public, anon;
revoke all on function public.ia_chat_mkt_piezas(text, date, date, text) from public, anon;
revoke all on function public.ia_chat_mkt_pendientes(text, text) from public, anon;
revoke all on function public.ia_chat_mkt_analisis(text, date) from public, anon;
grant execute on function public.ia_chat_acceso() to authenticated, service_role;
grant execute on function public.ia_chat_alumnos_resumen(text, date, date) to authenticated, service_role;
grant execute on function public.ia_chat_mkt_rol() to authenticated, service_role;
grant execute on function public.ia_chat_mkt_piezas(text, date, date, text) to authenticated, service_role;
grant execute on function public.ia_chat_mkt_pendientes(text, text) to authenticated, service_role;
grant execute on function public.ia_chat_mkt_analisis(text, date) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- PRUEBA DE HUMO (se revierte sola; no escribe nada). Simula al fundador y llama a cada herramienta sin parametros.
--   Corre como el dueño del editor (sin RLS): prueba que las funciones compilan y devuelven jsonb; los recortes por rol
--   se prueban en los controles C4 a C9.
-- ---------------------------------------------------------------------
do $humo$
declare
  v_uid uuid;
  v_n   int := 0;
  v_j   jsonb;
begin
  begin
    select m.user_id into v_uid from public.crm_members m where m.rol = 'fundador' limit 1;
    if v_uid is null then
      raise notice '159 humo: no hay fundador en crm_members, se omite.';
    else
      perform set_config('request.jwt.claim.sub', v_uid::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
      if public.ia_chat_acceso() is distinct from 'fundador' then
        raise exception '159 humo: ia_chat_acceso no devolvio fundador';
      end if;
      v_j := public.ia_chat_alumnos_resumen();       v_n := v_n + 1;
      if v_j -> 'total' is null then raise exception '159 humo: alumnos_resumen sin total'; end if;
      v_j := public.ia_chat_mkt_piezas();            v_n := v_n + 1;
      if v_j -> 'periodo' is null then raise exception '159 humo: mkt_piezas sin periodo'; end if;
      v_j := public.ia_chat_mkt_pendientes();        v_n := v_n + 1;
      if v_j -> 'total' is null then raise exception '159 humo: mkt_pendientes sin total'; end if;
      v_j := public.ia_chat_mkt_analisis();          v_n := v_n + 1;
      if v_j -> 'analisis' is null then raise exception '159 humo: mkt_analisis sin analisis'; end if;
      -- parametros invalidos -> 22023
      begin
        perform public.ia_chat_mkt_piezas(null, null, null, 'facebook');
        raise exception '159 humo: dejo pasar una plataforma invalida';
      exception when sqlstate '22023' then null;
      end;
      begin
        perform public.ia_chat_alumnos_resumen('programa_que_no_existe_zzz');
        raise exception '159 humo: dejo pasar un programa inexistente';
      exception when sqlstate '22023' then null;
      end;
    end if;
    -- sin sesion -> 42501
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '', true);
    begin
      perform public.ia_chat_mkt_piezas();
      raise exception '159 humo: dejo pasar a alguien sin sesion';
    exception when sqlstate '42501' then null;
    end;
    raise exception '159_humo_ok';
  exception when others then
    if sqlerrm <> '159_humo_ok' then raise; end if;
  end;
  raise notice '159 humo: OK (% herramientas probadas, nada quedo escrito).', v_n;
end
$humo$;

commit;

-- =====================================================================
-- CONTROLES (correr de a uno; el editor muestra solo el ultimo resultado)
-- Para probar un rol: cada bloque begin ... rollback simula al usuario con request.jwt.claims y el rol 'authenticated'
-- (asi rige la RLS). Reemplazar <UID> por el user_id de un usuario con ese rol (select user_id, rol from crm_members).
-- =====================================================================

-- C1: las 6 funciones existen, son SECURITY INVOKER (definer = false) y fijan search_path. Esperado: 6 filas, definer = false.
-- select p.proname, p.prosecdef as definer, p.proconfig
--   from pg_proc p where p.pronamespace = 'public'::regnamespace
--    and p.proname in ('ia_chat_acceso', 'ia_chat_alumnos_resumen', 'ia_chat_mkt_rol', 'ia_chat_mkt_piezas', 'ia_chat_mkt_pendientes', 'ia_chat_mkt_analisis')
--  order by 1;

-- C2: anon no puede ejecutarlas. Esperado: anon = false y authenticated = true en las 6.
-- select f.proname, has_function_privilege('anon', f.oid, 'execute') as anon, has_function_privilege('authenticated', f.oid, 'execute') as authenticated
--   from pg_proc f where f.pronamespace = 'public'::regnamespace
--    and f.proname in ('ia_chat_acceso', 'ia_chat_alumnos_resumen', 'ia_chat_mkt_rol', 'ia_chat_mkt_piezas', 'ia_chat_mkt_pendientes', 'ia_chat_mkt_analisis')
--  order by 1;

-- C3: puerta por rol. Reemplazar <UID> por cada tipo de usuario. Esperado: devuelve su rol para los 9 roles con usuario;
--     null para cualquier otro.
-- begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', json_build_object('sub', '<UID>', 'role', 'authenticated')::text, true);
--   select public.ia_chat_acceso();
-- rollback;

-- C4 (fundador): alumnos. Esperado: total.vivos = vivos de todos los programas; compara con C5.
-- begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', json_build_object('sub', '<UID_FUNDADOR>', 'role', 'authenticated')::text, true);
--   select public.ia_chat_alumnos_resumen('teo');
-- rollback;

-- C5: el mismo conteo a mano (como postgres, sin RLS). Esperado: igual a total.vivos / activos / vivos_grupal / vivos_vip de C4.
-- select c.estado, coalesce(m.modalidad, 'sin_dato') as modalidad, count(*)
--   from public.cs_clientes c left join public.cs_v_modalidad m on m.cliente_id = c.id
--  where c.programa_id = 'teo' group by 1, 2 order by 1, 2;

-- C6 (rol cliente de agus): ve solo agus. Esperado: pedir 'teo' -> error 22023 "no encuentro el programa"; sin parametro -> solo agus
--     en por_programa; marketing_piezas solo de su cliente.
-- begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', json_build_object('sub', '<UID_CLIENTE_AGUS>', 'role', 'authenticated')::text, true);
--   select public.ia_chat_alumnos_resumen();
--   select public.ia_chat_mkt_piezas();
-- rollback;

-- C7 (rol producto): alumnos si; Marketing 42501 "tu rol no ve los datos de Marketing".
-- begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', json_build_object('sub', '<UID_PRODUCTO>', 'role', 'authenticated')::text, true);
--   select public.ia_chat_alumnos_resumen();
--   select public.ia_chat_mkt_piezas();    -- debe fallar con 42501
-- rollback;

-- C8 (roles ventas, finanzas, closer, setter): alumnos y Marketing dan 42501; ia_chat_acceso() devuelve su rol (pueden usar el chat,
--     pero esas dos familias de herramientas no les contestan).
-- begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', json_build_object('sub', '<UID_VENTAS>', 'role', 'authenticated')::text, true);
--   select public.ia_chat_acceso();
--   select public.ia_chat_alumnos_resumen();   -- 42501
-- rollback;

-- C9 (rol contenido o editor): Marketing si (sus clientes asignados); alumnos 42501.
-- begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', json_build_object('sub', '<UID_CONTENIDO>', 'role', 'authenticated')::text, true);
--   select public.ia_chat_mkt_piezas();
--   select public.ia_chat_mkt_pendientes(null, 'editar');
--   select public.ia_chat_mkt_analisis();
--   select public.ia_chat_alumnos_resumen();   -- 42501
-- rollback;

-- C10: piezas publicadas este mes, a mano. Esperado: igual a total.piezas de ia_chat_mkt_piezas() del fundador sin parametros.
-- select count(*) as piezas, coalesce(sum(views), 0) as views
--   from public.crm_publicaciones
--  where estado_publicacion = 'PUBLICADO'
--    and fecha_publicacion between date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')::date)::date
--                              and (now() at time zone 'America/Argentina/Buenos_Aires')::date;

-- C11: pendientes a mano. Esperado: igual a total de ia_chat_mkt_pendientes() del fundador (y al Pipeline del Dashboard de Marketing).
-- select count(*) filter (where estado_grabacion in ('PENDIENTE', 'EN PROCESO')) as por_grabar,
--        count(*) filter (where estado_grabacion = 'GRABADO' and coalesce(estado_edicion, 'PENDIENTE') in ('PENDIENTE', 'EN PROCESO')) as por_editar,
--        count(*) filter (where estado_edicion = 'EDITADO' and coalesce(estado_publicacion, 'PENDIENTE') in ('PENDIENTE', 'LISTO PARA PUBLICAR', 'PROGRAMADO')) as por_publicar
--   from public.crm_publicaciones;

-- =====================================================================
-- VUELTA ATRAS (solo funciones nuevas; no toca nada mas)
-- begin;
--   drop function if exists public.ia_chat_mkt_analisis(text, date);
--   drop function if exists public.ia_chat_mkt_pendientes(text, text);
--   drop function if exists public.ia_chat_mkt_piezas(text, date, date, text);
--   drop function if exists public.ia_chat_mkt_rol();
--   drop function if exists public.ia_chat_alumnos_resumen(text, date, date);
--   drop function if exists public.ia_chat_acceso();
-- commit;
-- (Si se revierte, ia-preguntar vuelve a usar cs_chat_puede para la puerta: desplegar la version anterior de la funcion.)
-- =====================================================================
