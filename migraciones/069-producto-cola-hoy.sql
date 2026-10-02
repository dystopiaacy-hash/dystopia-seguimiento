-- =====================================================================
-- 069-producto-cola-hoy.sql  ·  PRODUCTO, fase 3 (PLAN-PRODUCTO.md)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
--
-- Qué hace (solo funciones nuevas; no toca tablas ni datos):
--
--   1. cs_cola_hoy(programa, dias_adelante = 3): la cola de trabajo del
--      CSM, calculada EN VIVO (las alertas se recalculan una vez por día;
--      esto cambia apenas se marca algo como hecho). Una fila por tarea:
--        aviso_1 / aviso_2  aviso de renovación sin hacer
--        accionable         accionable del equipo sin completar (incluye
--                           FUP, referidos, onboarding y offboarding)
--        contacto           próximo contacto de un seguimiento
--        renovacion         renovación abierta sin contacto hace 7 días
--                           y sin próximo contacto agendado
--        onboarding         call de onboarding sin agendar
--        devolucion         devolución de Loom pendiente (fecha = SLA)
--      cuando = 'atrasado' | 'hoy' | 'proximo' (hasta dias_adelante).
--      Mismas reglas que cs_generar_alertas (039): un pausado no genera
--      avisos ni renovación, sí el resto. Respeta RLS (security invoker).
--
--   2. cs_registrar_contacto(cliente, canal, resultado, resumen,
--      proximo_contacto): registra el seguimiento y mueve el pipeline de
--      resell según el resultado, todo junto (si algo falla, no queda
--      nada a medias):
--        contesto       solo el seguimiento
--        no_contesta    solo el seguimiento
--        interesado     renovación a 'contactado' (la abre si no hay)
--        call_agendada  renovación a 'call_agendada' (la abre si no hay)
--        no_renueva     renovación a 'no_renovado' con el resumen como
--                       motivo (la crea cerrada si no había)
--      "Renovó" NO va por acá: necesita producto y fecha, y sigue por la
--      ficha como hoy. Producto no escribe caja.
--      Resumen vacío: se guarda el nombre del resultado.
--
-- Se puede correr dos veces (create or replace).
-- =====================================================================

begin;

set local lock_timeout = '8s';


-- =====================================================================
-- 1. COLA DE HOY
-- =====================================================================
create or replace function public.cs_cola_hoy(p_programa text, p_dias_adelante int default 3)
returns table (
  tipo         text,
  cuando       text,
  fecha        date,
  dias_atraso  int,
  cliente_id   uuid,
  cliente      text,
  titulo       text,
  detalle      text,
  ref_id       uuid,
  orden        int
)
language sql
stable
security invoker
set search_path = public
as $fn$
  with prm as (
    select public.cs_hoy() as hoy,
           public.cs_hoy() + greatest(coalesce(p_dias_adelante, 3), 0) as hasta
  ),
  prog as (
    select p.* from public.cs_programas p where p.id = p_programa
  ),
  vivos as (
    select c.*, pr.aviso_1_dias, pr.aviso_2_dias, pr.sla_onboarding_dias, pr.sla_devolucion_horas
    from public.cs_clientes c
    join prog pr on pr.id = c.programa_id
    where c.estado not in ('finalizado', 'baja')
  ),
  ult_seg as (
    select v.id as cliente_id, s.fecha as ult_fecha, s.proximo_contacto
    from vivos v
    left join lateral (
      select x.fecha, x.proximo_contacto
      from public.cs_seguimientos x
      where x.cliente_id = v.id
      order by x.fecha desc, x.created_at desc
      limit 1
    ) s on true
  ),
  tareas as (
    -- aviso 1: entra en la ventana el día fecha_fin - aviso_1_dias
    select 'aviso_1'::text as tipo, v.fecha_fin - v.aviso_1_dias as fecha,
           v.id as cliente_id, v.nombre as cliente,
           format('Aviso de renovación (%s días)', v.aviso_1_dias) as titulo,
           format('Vence el %s', to_char(v.fecha_fin, 'DD/MM')) as detalle,
           v.id as ref_id, 2 as prio
    from vivos v, prm
    where v.estado <> 'pausado'
      and v.aviso_1_at is null
      and v.fecha_fin >= prm.hoy
      and v.fecha_fin - prm.hoy > v.aviso_2_dias
      and v.fecha_fin - v.aviso_1_dias <= prm.hasta

    union all
    select 'aviso_2', v.fecha_fin - v.aviso_2_dias, v.id, v.nombre,
           format('Aviso de renovación (%s días)', v.aviso_2_dias),
           format('Vence el %s', to_char(v.fecha_fin, 'DD/MM')),
           v.id, 1
    from vivos v, prm
    where v.estado <> 'pausado'
      and v.aviso_2_at is null
      and v.fecha_fin >= prm.hoy
      and v.fecha_fin - v.aviso_2_dias <= prm.hasta

    union all
    -- accionables del equipo de clientes vivos
    select 'accionable', a.vence, v.id, v.nombre, a.titulo,
           nullif(a.descripcion, ''), a.id, 3
    from vivos v
    join public.cs_accionables a on a.cliente_id = v.id
    cross join prm
    where a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence is not null
      and a.vence <= prm.hasta

    union all
    -- offboarding de clientes cerrados (ítems de cierre)
    select 'accionable', a.vence, c.id, c.nombre, a.titulo,
           'Offboarding', a.id, 3
    from public.cs_clientes c
    join prog pr on pr.id = c.programa_id
    join public.cs_accionables a on a.cliente_id = c.id
    cross join prm
    where c.estado in ('finalizado', 'baja')
      and a.plantilla_key like 'cierre:%'
      and a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence is not null
      and a.vence <= prm.hasta

    union all
    -- próximo contacto agendado en el último seguimiento
    select 'contacto', u.proximo_contacto, v.id, v.nombre,
           'Contactar', format('Último contacto el %s', to_char(u.ult_fecha, 'DD/MM')),
           v.id, 4
    from vivos v
    join ult_seg u on u.cliente_id = v.id
    cross join prm
    where u.proximo_contacto is not null
      and u.proximo_contacto <= prm.hasta

    union all
    -- renovación abierta sin movimiento: 7 días desde el último contacto
    -- (o desde que se abrió) y sin próximo contacto agendado
    select 'renovacion', greatest(u.ult_fecha, (r.iniciada_at at time zone 'America/Argentina/Buenos_Aires')::date) + 7,
           v.id, v.nombre, 'Mover la renovación',
           format('Etapa: %s', replace(r.estado, '_', ' ')), r.id, 2
    from vivos v
    join ult_seg u on u.cliente_id = v.id
    join public.cs_renovaciones r on r.cliente_id = v.id and public.cs_ren_abierta(r.estado)
    cross join prm
    where v.estado <> 'pausado'
      and u.proximo_contacto is null
      and greatest(u.ult_fecha, (r.iniciada_at at time zone 'America/Argentina/Buenos_Aires')::date) + 7 <= prm.hasta

    union all
    -- call de onboarding sin agendar (la última call de onboarding)
    select 'onboarding', v.fecha_inicio + v.sla_onboarding_dias, v.id, v.nombre,
           'Agendar call de onboarding', null, k.id, 1
    from vivos v
    cross join lateral (
      select x.id, x.estado from public.cs_calls x
      where x.cliente_id = v.id and x.tipo = 'onboarding'
      order by x.created_at desc limit 1
    ) k
    cross join prm
    where k.estado = 'pendiente_agendar'
      and v.fecha_inicio + v.sla_onboarding_dias <= prm.hasta

    union all
    -- devoluciones pendientes, con fecha = vencimiento del SLA
    select 'devolucion',
           ((d.solicitada_at + make_interval(hours => v.sla_devolucion_horas))
              at time zone 'America/Argentina/Buenos_Aires')::date,
           v.id, v.nombre, 'Devolución: ' || d.titulo, null, d.id, 2
    from vivos v
    join public.cs_devoluciones d on d.cliente_id = v.id
    cross join prm
    where d.estado in ('pendiente', 'en_proceso')
      and ((d.solicitada_at + make_interval(hours => v.sla_devolucion_horas))
             at time zone 'America/Argentina/Buenos_Aires')::date <= prm.hasta
  )
  select t.tipo,
         case when t.fecha < prm.hoy then 'atrasado'
              when t.fecha = prm.hoy then 'hoy'
              else 'proximo' end,
         t.fecha,
         greatest(prm.hoy - t.fecha, 0),
         t.cliente_id, t.cliente, t.titulo, t.detalle, t.ref_id,
         (row_number() over (
            order by case when t.fecha < prm.hoy then 0 when t.fecha = prm.hoy then 1 else 2 end,
                     t.fecha, t.prio, t.cliente))::int
  from tareas t cross join prm
  order by 10;
$fn$;

comment on function public.cs_cola_hoy(text, int) is
  'Cola de trabajo del CSM, en vivo: avisos, accionables del equipo, contactos, renovaciones sin movimiento, onboarding y devoluciones. Ver 069.';


-- =====================================================================
-- 2. REGISTRAR CONTACTO (seguimiento + pipeline en un paso)
-- =====================================================================
create or replace function public.cs_registrar_contacto(
  p_cliente   uuid,
  p_canal     text,
  p_resultado text,
  p_resumen   text default null,
  p_proximo   date default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $fn$
declare
  v_cli     record;
  v_ren     record;
  v_seg     uuid;
  v_resumen text;
  v_destino text;
  v_ren_id  uuid;
begin
  if p_resultado not in ('contesto', 'no_contesta', 'interesado', 'call_agendada', 'no_renueva') then
    raise exception 'cs: resultado inválido (%)', p_resultado using errcode = '22023';
  end if;

  select c.id, c.programa_id, c.estado into v_cli
  from public.cs_clientes c where c.id = p_cliente;
  if v_cli.id is null then
    raise exception 'cs: el cliente no existe o no tenés acceso' using errcode = '42501';
  end if;

  v_resumen := coalesce(nullif(btrim(p_resumen), ''),
    case p_resultado
      when 'contesto'      then 'Contestó'
      when 'no_contesta'   then 'No contesta'
      when 'interesado'    then 'Interesado en renovar'
      when 'call_agendada' then 'Call de renovación agendada'
      when 'no_renueva'    then 'No renueva'
    end);

  insert into public.cs_seguimientos (programa_id, cliente_id, canal, resumen, proximo_contacto)
  values (v_cli.programa_id, v_cli.id, p_canal, v_resumen, p_proximo)
  returning id into v_seg;

  v_destino := case p_resultado
                 when 'interesado'    then 'contactado'
                 when 'call_agendada' then 'call_agendada'
                 when 'no_renueva'    then 'no_renovado'
               end;

  if v_destino is not null then
    select r.id, r.estado into v_ren
    from public.cs_renovaciones r
    where r.cliente_id = v_cli.id and public.cs_ren_abierta(r.estado)
    order by r.iniciada_at desc limit 1;

    if v_ren.id is null then
      insert into public.cs_renovaciones (programa_id, cliente_id, estado, motivo)
      values (v_cli.programa_id, v_cli.id, v_destino,
              case when v_destino = 'no_renovado' then v_resumen end)
      returning id into v_ren_id;
    else
      v_ren_id := v_ren.id;
      -- no retrocede: si ya está en una etapa más avanzada, queda ahí
      if v_destino = 'no_renovado'
         or (v_destino = 'contactado'    and v_ren.estado = 'en_proceso')
         or (v_destino = 'call_agendada' and v_ren.estado in ('en_proceso', 'contactado')) then
        update public.cs_renovaciones
           set estado = v_destino,
               motivo = case when v_destino = 'no_renovado' then v_resumen else motivo end
         where id = v_ren.id;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'seguimiento_id', v_seg,
    'renovacion_id', v_ren_id,
    'renovacion_estado', (select estado from public.cs_renovaciones where id = v_ren_id)
  );
end;
$fn$;

comment on function public.cs_registrar_contacto(uuid, text, text, text, date) is
  'Registra un seguimiento y mueve el pipeline de resell según el resultado, en una sola transacción. Ver 069.';


-- =====================================================================
-- 3. PERMISOS
-- =====================================================================
revoke all on function public.cs_cola_hoy(text, int) from public, anon;
grant execute on function public.cs_cola_hoy(text, int) to authenticated;
revoke all on function public.cs_registrar_contacto(uuid, text, text, text, date) from public, anon;
grant execute on function public.cs_registrar_contacto(uuid, text, text, text, date) to authenticated;


-- =====================================================================
-- 4. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
do $humo$
declare
  v_prog text := 'humo069';
  v_a uuid; v_b uuid; v_c uuid;
  v_n int;
  v_j jsonb;
  v_err text;
begin
  begin
    insert into public.cs_programas (id, nombre, activo, aviso_1_dias, aviso_2_dias)
    values (v_prog, '__humo069__', true, 21, 10);

    -- A: vence en 15 días, sin avisos -> aviso_1 atrasado
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'humo A', public.cs_hoy() - 100, public.cs_hoy() + 15, 'activo') returning id into v_a;
    -- B: vence en 8 días, aviso 1 hecho -> aviso_2 atrasado
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado, aviso_1_at)
    values (v_prog, 'humo B', public.cs_hoy() - 100, public.cs_hoy() + 8, 'activo', now()) returning id into v_b;
    -- C: pausado y vence en 8 días -> sin avisos
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'humo C', public.cs_hoy() - 100, public.cs_hoy() + 8, 'pausado') returning id into v_c;

    select count(*) into v_n from public.cs_cola_hoy(v_prog) q where q.tipo = 'aviso_1' and q.cliente_id = v_a and q.cuando = 'atrasado';
    if v_n <> 1 then raise exception 'humo 1: falta el aviso_1 de A (n=%)', v_n; end if;
    select count(*) into v_n from public.cs_cola_hoy(v_prog) q where q.tipo = 'aviso_2' and q.cliente_id = v_b;
    if v_n <> 1 then raise exception 'humo 2: falta el aviso_2 de B (n=%)', v_n; end if;
    select count(*) into v_n from public.cs_cola_hoy(v_prog) q where q.cliente_id = v_c and q.tipo like 'aviso%';
    if v_n <> 0 then raise exception 'humo 3: el pausado tiene avisos (n=%)', v_n; end if;

    -- contacto: interesado abre la renovación en 'contactado'
    v_j := public.cs_registrar_contacto(v_a, 'whatsapp', 'interesado', '', public.cs_hoy() + 2);
    if v_j->>'renovacion_estado' <> 'contactado' then raise exception 'humo 4: %', v_j; end if;
    -- el contacto agendado aparece como próximo y la renovación no se duplica
    select count(*) into v_n from public.cs_cola_hoy(v_prog) q where q.cliente_id = v_a and q.tipo = 'contacto' and q.cuando = 'proximo';
    if v_n <> 1 then raise exception 'humo 5: falta el contacto próximo de A (n=%)', v_n; end if;
    select count(*) into v_n from public.cs_cola_hoy(v_prog) q where q.cliente_id = v_a and q.tipo = 'renovacion';
    if v_n <> 0 then raise exception 'humo 6: renovación duplicada con el contacto (n=%)', v_n; end if;

    -- call agendada avanza; interesado después no retrocede
    v_j := public.cs_registrar_contacto(v_a, 'call', 'call_agendada');
    v_j := public.cs_registrar_contacto(v_a, 'whatsapp', 'interesado');
    if v_j->>'renovacion_estado' <> 'call_agendada' then raise exception 'humo 7: retrocedió (%)', v_j; end if;

    -- no renueva cierra la renovación con motivo
    v_j := public.cs_registrar_contacto(v_a, 'whatsapp', 'no_renueva', 'No le da el presupuesto');
    if v_j->>'renovacion_estado' <> 'no_renovado' then raise exception 'humo 8: %', v_j; end if;
    select count(*) into v_n from public.cs_renovaciones where cliente_id = v_a and motivo = 'No le da el presupuesto';
    if v_n <> 1 then raise exception 'humo 9: motivo no guardado'; end if;

    -- resumen vacío guarda el nombre del resultado; resultado inválido falla
    v_j := public.cs_registrar_contacto(v_b, 'mail', 'no_contesta');
    select count(*) into v_n from public.cs_seguimientos where cliente_id = v_b and resumen = 'No contesta';
    if v_n <> 1 then raise exception 'humo 10: resumen por defecto'; end if;
    begin
      perform public.cs_registrar_contacto(v_b, 'mail', 'renovo');
      raise exception 'humo 11: aceptó un resultado inválido';
    exception when invalid_parameter_value then null;
    end;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '069 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 5. CONTROLES (correr de a uno, después del Success)
-- =====================================================================
-- C1. Las dos funciones existen. Tiene que dar 2 filas.
-- select proname, prosecdef as security_definer
-- from pg_proc where proname in ('cs_cola_hoy', 'cs_registrar_contacto');
--     security_definer tiene que dar false en las dos (respetan RLS).

-- C2. La cola real de liam, resumida. Atrasados y de hoy son el trabajo
--     del día; proximo, lo de los próximos 3 días.
-- select tipo, cuando, count(*) from public.cs_cola_hoy('liam')
-- group by 1, 2 order by 2, 1;

-- C3. Las primeras 15 tareas, como las va a ver el CSM.
-- select orden, cuando, dias_atraso, tipo, titulo, fecha
-- from public.cs_cola_hoy('liam') order by orden limit 15;
