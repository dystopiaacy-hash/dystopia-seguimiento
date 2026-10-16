-- =====================================================================
-- 140 · IA Fase 2 · (3) chat interno "Preguntale a la IA": consultas armadas de antemano (solo lectura)
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 139 (cs_riesgo_abandono), 137 (cs_en_que_esta), 123 (cs_servicio_config, cs_servicio_morosos),
--           102 (cs_v_ultima_llamada), 106 (cs_llamadas.en_que_esta / proximos_pasos), 122 (cs_fathom_gestor).
--           La 132 de Finanzas (cs_estado_pagos_alumno) es OPCIONAL: sin ella "debe plata" viene vacío.
--
-- Qué hace
--   La Edge Function ia-preguntar (Sonnet, tool use) entiende la pregunta, elige UNA de estas 3 consultas y sus
--   parámetros, y las ejecuta con el token del usuario. La IA nunca escribe SQL: solo elige función y parámetros.
--     1. cs_chat_atrasados(programa)            "¿qué alumnos de <cliente> están atrasados o sin llamada?"
--     2. cs_chat_en_que_esta(alumno, programa)  "¿en qué está <alumno>?"
--     3. cs_chat_renovar_o_deuda(programa, dias) "¿quién está por renovar o debe plata?"
--   Todas son SECURITY INVOKER (rigen el RLS y los permisos de quien pregunta), de solo lectura, y exigen ser
--   fundador o rol producto (edición en algún programa: cs_fathom_gestor()). El rol cliente da 42501.
--   Montos: solo los ve el fundador (cs_chat_montos). El resto de los usuarios recibe monto_pendiente = null.
--   Cada pregunta queda en ia_uso (funcion 'chat_interno', con user_id) desde la Edge Function.
--
-- Correr en una sola ejecución, evitando los minutos :00, :15, :30, :45 y las 9:00.
-- Después: desplegar ia-preguntar (--no-verify-jwt) y ver C1 a C5.
-- =====================================================================

begin;
set local lock_timeout = '8s';

do $chk$
declare
  v_falta text;
begin
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_riesgo_abandono'), ('cs_en_que_esta'), ('cs_servicio_config'), ('cs_clientes'),
               ('cs_llamadas'), ('cs_accionables'), ('cs_v_ultima_llamada')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception '140: faltan objetos (139, 137, 123, 102): %', v_falta;
  end if;
  if to_regprocedure('public.cs_fathom_gestor()') is null
     or to_regprocedure('public.cs_servicio_morosos(text,integer,date)') is null
     or to_regprocedure('public.cs_norm_nombre(text)') is null then
    raise exception '140: faltan cs_fathom_gestor (122) / cs_servicio_morosos (123) / cs_norm_nombre';
  end if;
end
$chk$;


-- Solo fundador o rol producto.
create or replace function public.cs_chat_exigir()
returns void
language plpgsql stable set search_path = public
as $fn$
begin
  if not coalesce(public.cs_fathom_gestor(), false) then
    raise exception 'cs: el chat interno es solo para el fundador y el rol producto' using errcode = '42501';
  end if;
end;
$fn$;

-- "liam", "Liam" o el nombre / marca del programa -> id. null si no existe o no lo ve quien pregunta (RLS).
create or replace function public.cs_chat_programa(p_texto text)
returns text
language sql stable set search_path = public
as $fn$
  select pr.id
  from public.cs_programas pr
  where nullif(btrim(coalesce(p_texto, '')), '') is not null
    and (lower(pr.id) = lower(btrim(p_texto))
         or public.cs_norm_nombre(pr.nombre) = public.cs_norm_nombre(p_texto)
         or public.cs_norm_nombre(pr.marca) = public.cs_norm_nombre(p_texto))
  order by pr.id
  limit 1
$fn$;

-- Montos pendientes por alumno: SOLO el fundador. Para el resto devuelve vacío.
create or replace function public.cs_chat_montos(p_programa text)
returns table (cliente_id uuid, pendiente numeric)
language plpgsql stable security definer set search_path = public
as $fn$
begin
  if not coalesce(public.es_fundador(), false) then
    return;
  end if;
  return query
    select m.cliente_id, m.pendiente
    from public.cs_servicio_morosos(p_programa, 0, public.cs_hoy()) m
    where m.cliente_id is not null;
exception when others then
  return;   -- Finanzas no disponible: sin montos
end;
$fn$;


-- ---------------------------------------------------------------------
-- 1. Atrasados o sin llamada
-- ---------------------------------------------------------------------
create or replace function public.cs_chat_atrasados(p_programa text default null)
returns table (
  alumno_id uuid, programa_id text, nombre text, estado text, ultima_llamada date,
  dias_sin_llamada int, sin_llamada boolean, accionables_vencidos int, motivo text
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
           case when coalesce(a.n, 0) > 0 then a.n || case when a.n = 1 then ' accionable vencido' else ' accionables vencidos' end end)
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


-- ---------------------------------------------------------------------
-- 2. En qué está un alumno
-- ---------------------------------------------------------------------
create or replace function public.cs_chat_en_que_esta(p_alumno text, p_programa text default null)
returns table (
  alumno_id uuid, programa_id text, nombre text, estado text,
  en_que_esta text, en_que_esta_actualizado date, proximos_pasos text, ultima_llamada date,
  riesgo text, riesgo_motivo text
)
language plpgsql stable set search_path = public
as $fn$
declare
  v_prog text;
  v_q    text := public.cs_norm_nombre(p_alumno);
begin
  perform public.cs_chat_exigir();
  if v_q is null or btrim(v_q) = '' then
    raise exception 'cs: falta el nombre del alumno' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_programa, '')), '') is not null then
    v_prog := public.cs_chat_programa(p_programa);
    if v_prog is null then
      raise exception 'cs: no encuentro el programa "%"', p_programa using errcode = '22023';
    end if;
  end if;
  return query
  select c.id, c.programa_id, c.nombre, c.estado,
         coalesce(e.texto,
                  (select l.en_que_esta from public.cs_llamadas l
                   where l.cliente_id = c.id and nullif(btrim(l.en_que_esta), '') is not null
                   order by l.fecha desc limit 1)),
         (e.actualizado_en at time zone 'America/Argentina/Buenos_Aires')::date,
         (select l.proximos_pasos from public.cs_llamadas l
          where l.cliente_id = c.id and nullif(btrim(l.proximos_pasos), '') is not null
          order by l.fecha desc limit 1),
         u.ultima_llamada,
         r.nivel, r.motivo
  from public.cs_clientes c
  left join public.cs_en_que_esta e on e.cliente_id = c.id
  left join public.cs_v_ultima_llamada u on u.cliente_id = c.id
  left join public.cs_riesgo_abandono r on r.cliente_id = c.id
  where (v_prog is null or c.programa_id = v_prog)
    and not exists (select 1 from unnest(string_to_array(v_q, ' ')) w
                    where w <> '' and position(w in public.cs_norm_nombre(c.nombre)) = 0)
  order by (public.cs_norm_nombre(c.nombre) = v_q) desc, c.nombre
  limit 5;
end;
$fn$;


-- ---------------------------------------------------------------------
-- 3. Por renovar o con deuda
-- ---------------------------------------------------------------------
-- Por renovar = en renovación, o fecha_fin dentro de p_dias (incluye los ya vencidos). Debe plata = cuotas
-- atrasadas en Finanzas (solo alumnos vinculados, 132). Monto: solo el fundador.
create or replace function public.cs_chat_renovar_o_deuda(p_programa text default null, p_dias int default 30)
returns table (
  alumno_id uuid, programa_id text, nombre text, estado text, fecha_fin date, dias_para_fin int,
  por_renovar boolean, cuotas_atrasadas int, dias_atraso int, monto_pendiente numeric
)
language plpgsql stable set search_path = public
as $fn$
declare
  v_prog  text;
  v_dias  int  := least(greatest(coalesce(p_dias, 30), 1), 180);
  v_hoy   date := public.cs_hoy();
  v_ids   uuid[];
  v_i     int;
  v_pag   jsonb := '[]'::jsonb;
  v_chunk jsonb;
  v_mon   jsonb := '[]'::jsonb;
  v_p     text;
  v_m     jsonb;
begin
  perform public.cs_chat_exigir();
  if nullif(btrim(coalesce(p_programa, '')), '') is not null then
    v_prog := public.cs_chat_programa(p_programa);
    if v_prog is null then
      raise exception 'cs: no encuentro el programa "%"', p_programa using errcode = '22023';
    end if;
  end if;

  select coalesce(array_agg(c.id), '{}') into v_ids
  from public.cs_clientes c
  where c.estado in ('onboarding', 'activo', 'en_renovacion') and (v_prog is null or c.programa_id = v_prog);

  -- Pagos: cs_estado_pagos_alumno(uuid[]) (132, máximo 500 ids por llamada). Sin ella, sin deuda.
  if to_regprocedure('public.cs_estado_pagos_alumno(uuid[])') is not null then
    v_i := 1;
    while v_i <= coalesce(cardinality(v_ids), 0) loop
      begin
        execute 'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.cs_estado_pagos_alumno($1) x'
          into v_chunk using v_ids[v_i : v_i + 499];
        v_pag := v_pag || coalesce(v_chunk, '[]'::jsonb);
      exception when others then
        null;   -- esa tanda sin datos de pagos
      end;
      v_i := v_i + 500;
    end loop;
  end if;

  -- Montos: solo fundador (cs_chat_montos devuelve vacío para el resto).
  if coalesce(public.es_fundador(), false) then
    for v_p in select distinct c.programa_id from public.cs_clientes c
               where c.estado in ('onboarding', 'activo', 'en_renovacion') and (v_prog is null or c.programa_id = v_prog)
    loop
      select coalesce(jsonb_agg(jsonb_build_object('c', m.cliente_id, 'p', m.pendiente)), '[]'::jsonb) into v_m
      from public.cs_chat_montos(v_p) m;
      v_mon := v_mon || v_m;
    end loop;
  end if;

  return query
  select c.id, c.programa_id, c.nombre, c.estado, c.fecha_fin,
         case when c.fecha_fin is null then null else c.fecha_fin - v_hoy end,
         (c.estado = 'en_renovacion' or (c.fecha_fin is not null and c.fecha_fin <= v_hoy + v_dias)),
         coalesce(pg.n, 0), coalesce(pg.d, 0), mo.p
  from public.cs_clientes c
  left join (select (x ->> 'cs_cliente_id')::uuid as cid,
                    coalesce((x ->> 'cuotas_atrasadas')::int, 0) as n,
                    coalesce((x ->> 'max_dias_atraso')::int, (x ->> 'dias_atraso')::int, 0) as d
             from jsonb_array_elements(v_pag) x) pg on pg.cid = c.id
  left join (select (x ->> 'c')::uuid as cid, (x ->> 'p')::numeric as p
             from jsonb_array_elements(v_mon) x) mo on mo.cid = c.id
  where c.estado in ('onboarding', 'activo', 'en_renovacion')
    and (v_prog is null or c.programa_id = v_prog)
    and ((c.estado = 'en_renovacion' or (c.fecha_fin is not null and c.fecha_fin <= v_hoy + v_dias))
         or coalesce(pg.n, 0) > 0)
  order by (coalesce(pg.n, 0) > 0) desc, c.fecha_fin asc nulls last, c.nombre
  limit 80;
end;
$fn$;


revoke all on function public.cs_chat_exigir() from public, anon;
revoke all on function public.cs_chat_programa(text) from public, anon;
revoke all on function public.cs_chat_montos(text) from public, anon;
revoke all on function public.cs_chat_atrasados(text) from public, anon;
revoke all on function public.cs_chat_en_que_esta(text, text) from public, anon;
revoke all on function public.cs_chat_renovar_o_deuda(text, int) from public, anon;
grant execute on function public.cs_chat_exigir() to authenticated;
grant execute on function public.cs_chat_programa(text) to authenticated;
grant execute on function public.cs_chat_montos(text) to authenticated;
grant execute on function public.cs_chat_atrasados(text) to authenticated;
grant execute on function public.cs_chat_en_que_esta(text, text) to authenticated;
grant execute on function public.cs_chat_renovar_o_deuda(text, int) to authenticated;


-- Humo (se revierte solo): sin sesión (SQL Editor) las tres consultas tienen que negarse.
do $humo$
begin
  begin
    perform * from public.cs_chat_atrasados('liam');
    raise exception 'HUMO 140: cs_chat_atrasados dejo pasar a alguien sin permiso';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform * from public.cs_chat_en_que_esta('humo');
    raise exception 'HUMO 140: cs_chat_en_que_esta dejo pasar a alguien sin permiso';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform * from public.cs_chat_renovar_o_deuda('liam', 30);
    raise exception 'HUMO 140: cs_chat_renovar_o_deuda dejo pasar a alguien sin permiso';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'HUMO OK: 140';
end
$humo$;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- C1. Funciones creadas (esperado: 6 filas).
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and proname like 'cs_chat_%' order by 1;
--
-- C2. Permisos (esperado: true, false).
--   select has_function_privilege('authenticated', 'public.cs_chat_atrasados(text)', 'execute') as auth,
--          has_function_privilege('anon', 'public.cs_chat_atrasados(text)', 'execute') as anon;
--
-- C3. Las consultas de verdad (SOLO desde la app logueado como fundador o producto; en el SQL Editor dan 42501).
--   El panel "Preguntale a la IA" de Producto las llama. Para probar a mano con tu sesión: abrir la app y preguntar
--   "¿qué alumnos de liam están atrasados?", "¿en qué está <nombre>?" y "¿quién está por renovar o debe plata?".
--
-- C4. Cada pregunta deja una fila en ia_uso (esperado: user_id con valor, funcion = 'chat_interno').
--   select creado_en, user_id, modelo, tokens_entrada, tokens_salida, costo_usd, ok
--   from public.ia_uso where funcion = 'chat_interno' order by creado_en desc limit 10;
--
-- C5. Un usuario del rol cliente NO puede (esperado: error 42501 al preguntar desde su sesión).

-- =====================================================================
-- VUELTA ATRÁS
-- =====================================================================
--   begin;
--   drop function if exists public.cs_chat_renovar_o_deuda(text, int);
--   drop function if exists public.cs_chat_en_que_esta(text, text);
--   drop function if exists public.cs_chat_atrasados(text);
--   drop function if exists public.cs_chat_montos(text);
--   drop function if exists public.cs_chat_programa(text);
--   drop function if exists public.cs_chat_exigir();
--   commit;
