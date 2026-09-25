-- =====================================================================
-- 036-cron-producto.sql  —  Dystopia Producto: cron diario + Discord
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con Finanzas (mismo proyecto Supabase).
--
-- Qué hace:
--   - Programa en pg_cron el chequeo diario (cs_correr_diario, de 003),
--     que hasta ahora solo corría con el botón de Config.
--   - Agrega las notificaciones a Discord que quedaron pendientes de la
--     Fase 6 del PLAN: digest diario y resumen semanal, por programa,
--     con el webhook de cs_integraciones.
--   - Los mensajes llevan SOLO números agregados y conteos por tipo de
--     alerta: ningún nombre de cliente ni texto de alerta (ver 4).
--
-- Migración ADITIVA sobre objetos cs_*: crea 1 tabla (log de envíos),
-- 4 funciones y 2 jobs de cron. No modifica tablas existentes, ni
-- políticas, ni datos, ni nada crm_* / fin_*. No requiere backup previo.
-- Es idempotente (create or replace / unschedule antes de schedule).
--
-- Requiere pg_cron y pg_net instaladas. En 000_inspeccion no estaban;
-- después Finanzas (004_cron, 007_alertas_discord) las usa en este mismo
-- proyecto. Si faltan, la migración corta al principio sin tocar nada.
--
-- Horarios (pg_cron corre en UTC; ART = UTC-3). Los del PLAN, Fase 6:
--   cs_diario   '0 12 * * *'   todos los días 9:00 ART
--                               cs_correr_diario() y después cs_digest_diario()
--   cs_semanal  '10 12 * * 1'  lunes 9:10 ART (después del diario)
--                               cs_resumen_semanal()
-- Mismo patrón que Finanzas: unschedule por nombre antes de schedule.
-- Además se da de baja cualquier otro job que ya llame a estas funciones
-- (si alguien lo había programado a mano con otro nombre), para que el
-- chequeo no corra dos veces.
--
-- Cómo se manda (igual que fin_alertas_post de 007): net.http_post con
-- ?wait=true (Discord responde 200 y queda en net._http_response) y
-- allowed_mentions vacío (nadie recibe ping aunque el texto traiga
-- @everyone). pg_net es asíncrono y solo envía lo que se commitea: por
-- eso la prueba de humo, que se revierte, no puede mandar nada. Igual
-- la prueba usa p_enviar = false en todo.
--
-- Qué NO hace (queda afuera a propósito):
--   - Reintentos de entrega. Cada envío queda en cs_discord_envios con su
--     request_id para ver la respuesta de Discord (query al final).
--   - Aviso inmediato de satisfaccion_baja (trigger de la Fase 6): esas
--     alertas salen en el digest del día siguiente como cualquier otra.
--   - Conectar el botón "Probar" de Config: cs_probar_discord queda lista
--     en la base, falta el cambio en js/views/config.js.
--
-- Estructura:
--   0. Chequeo previo (pg_cron y pg_net)
--   1. Tabla cs_discord_envios (log, solo fundador)
--   2. cs_discord_post()      -> bigint  (interna)
--   3. cs_probar_discord()    -> jsonb   (fundador)
--   4. cs_digest_diario()     -> jsonb   (cron)
--   5. cs_resumen_semanal()   -> jsonb   (cron)
--   6. Permisos
--   7. Cron
--   8. PRUEBA DE HUMO (crea datos, los verifica y los deshace; no envía)
--   9. QUERY DE CONTROL
-- =====================================================================

begin;

-- =====================================================================
-- 0. CHEQUEO PREVIO
-- =====================================================================
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise exception 'faltan pg_cron y/o pg_net: habilitalas en Database > Extensions y volvé a correr 036';
  end if;
end $$;


-- =====================================================================
-- 1. cs_discord_envios (un registro por mensaje armado)
-- =====================================================================
-- request_id null = no se hizo el POST (p_enviar = false). La respuesta de
-- Discord se ve con join a net._http_response (pg_net la guarda ~6 h).
create table if not exists public.cs_discord_envios (
  id           bigserial primary key,
  programa_id  text not null references public.cs_programas(id) on delete cascade,
  tipo         text not null check (tipo in ('digest','semanal','prueba')),
  contenido    text not null,
  request_id   bigint,
  created_at   timestamptz not null default now()
);
create index if not exists cs_discord_envios_programa_idx on public.cs_discord_envios (programa_id, created_at);

-- Igual que cs_integraciones: solo el fundador lo ve.
alter table public.cs_discord_envios enable row level security;
revoke all on table public.cs_discord_envios from anon;
revoke all on sequence public.cs_discord_envios_id_seq from anon, authenticated;
grant select on table public.cs_discord_envios to authenticated;
revoke insert, update, delete, truncate, references, trigger on table public.cs_discord_envios from authenticated;
drop policy if exists cs_fundador on public.cs_discord_envios;
create policy cs_fundador on public.cs_discord_envios for select to authenticated
  using (public.es_fundador());


-- =====================================================================
-- 2. cs_discord_post(p_programa, p_tipo, p_contenido, p_enviar)
-- =====================================================================
-- Único lugar que habla con Discord. Lee el webhook de cs_integraciones,
-- corta a 1900 caracteres (el límite de Discord es 2000), registra en
-- cs_discord_envios y hace el POST.
-- Sin webhook, o con discord_activo = false, no hace nada y devuelve null.
-- La única excepción es tipo 'prueba': el botón Probar tiene que andar
-- ANTES de activar las notificaciones.
-- Devuelve el id de cs_discord_envios.
create or replace function public.cs_discord_post(
  p_programa  text,
  p_tipo      text,
  p_contenido text,
  p_enviar    boolean default true
)
returns bigint
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_url    text;
  v_activo boolean;
  v_txt    text;
  v_req    bigint;
  v_id     bigint;
begin
  select i.discord_webhook_url, i.discord_activo into v_url, v_activo
  from public.cs_integraciones i
  where i.programa_id = p_programa;

  if v_url is null or (not coalesce(v_activo, false) and p_tipo <> 'prueba') then
    return null;
  end if;

  v_txt := case when length(p_contenido) > 1900 then left(p_contenido, 1899) || '…' else p_contenido end;

  if p_enviar then
    v_req := net.http_post(
      url     := v_url || case when v_url like '%?%' then '&' else '?' end || 'wait=true',
      headers := jsonb_build_object('content-type', 'application/json'),
      body    := jsonb_build_object('username', 'Dystopia Producto', 'content', v_txt,
                                    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)),
      timeout_milliseconds := 10000);
  end if;

  insert into public.cs_discord_envios (programa_id, tipo, contenido, request_id)
  values (p_programa, p_tipo, v_txt, v_req)
  returning id into v_id;
  return v_id;
end;
$fn$;


-- =====================================================================
-- 3. cs_probar_discord(p_programa)
-- =====================================================================
-- Para el botón "Probar" de Config. Mismo criterio de permisos que
-- cs_correr_diario (003): fundador, o llamada sin sesión (SQL Editor).
create or replace function public.cs_probar_discord(p_programa text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_nombre text;
  v_id     bigint;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede probar Discord' using errcode = '42501';
  end if;

  select p.nombre into v_nombre from public.cs_programas p where p.id = p_programa;
  if v_nombre is null then
    raise exception 'cs: programa inexistente: %', p_programa;
  end if;

  v_id := public.cs_discord_post(p_programa, 'prueba',
            format('Prueba de Dystopia Producto · %s — %s. Si ves esto, el webhook anda.',
                   v_nombre, to_char(now() at time zone 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY HH24:MI')));

  return jsonb_build_object('enviado', v_id is not null,
                            'motivo', case when v_id is null then 'sin webhook cargado' end,
                            'envio_id', v_id);
end;
$fn$;


-- =====================================================================
-- 4. cs_digest_diario(p_enviar)
-- =====================================================================
-- Por cada programa activo con Discord activo y webhook, un mensaje:
--   **Producto · <programa>** — <fecha>
--   Activos: X | Rojo: X | Amarillo: X
--   Devoluciones pendientes: X (X%) | Vencidas SLA: X
--   Onboarding pendientes: X
--   Por vencer (<aviso>d): X | Renovaciones en proceso: X
--   Nuevas alertas: 3 devoluciones fuera de SLA, 2 onboarding demorados
-- SIN nombres de clientes ni el texto de las alertas (mismo criterio que
-- Finanzas): los clientes son alumnos con datos personales y el canal lo
-- ve gente que no tiene por qué saber quién está en rojo. cs_alertas.mensaje
-- tampoco sale porque lleva títulos de devoluciones y accionables, que
-- pueden nombrar a alguien. Solo conteos por tipo; el detalle, en la app.
-- Los números salen de cs_v_kpis_programa (los mismos del Resumen de la
-- app). "Nuevas" = abiertas y todavía no notificadas; se marcan todas
-- con notificada_discord_at para que mañana no vuelvan a contarse.
-- Corre después de cs_correr_diario (ver cron): las alertas ya están
-- recalculadas.
-- p_enviar = false: arma, registra y marca igual, pero no hace el POST
-- (solo para la prueba de humo).
create or replace function public.cs_digest_diario(p_enviar boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r        record;
  k        record;
  v_ids    uuid[];
  v_conteo text;
  v_total  int;
  v_txt    text;
  v_id     bigint;
  v_envios jsonb := '[]'::jsonb;
  v_marcadas int := 0;
begin
  for r in
    select p.id, p.nombre, p.aviso_renovacion_dias
    from public.cs_programas p
    join public.cs_integraciones i on i.programa_id = p.id
    where p.activo and i.discord_activo and i.discord_webhook_url is not null
    order by p.id
  loop
    select * into k from public.cs_v_kpis_programa v where v.programa_id = r.id;

    select coalesce(array_agg(a.id), '{}'), count(*)
      into v_ids, v_total
    from public.cs_alertas a
    where a.programa_id = r.id
      and not a.resuelta
      and a.notificada_discord_at is null;

    -- "3 devoluciones fuera de SLA, 2 onboarding demorados": de más a menos.
    select string_agg(
             x.n || ' ' || case x.tipo
               when 'renovacion_proxima'     then 'por vencer sin renovación iniciada'
               when 'programa_vencido'       then case when x.n = 1 then 'programa vencido sin cerrar' else 'programas vencidos sin cerrar' end
               when 'devolucion_vencida'     then case when x.n = 1 then 'devolución fuera de SLA' else 'devoluciones fuera de SLA' end
               when 'onboarding_demorado'    then case when x.n = 1 then 'onboarding demorado' else 'onboarding demorados' end
               when 'accionable_bpf_vencido' then case when x.n = 1 then 'accionable BPF vencido' else 'accionables BPF vencidos' end
               when 'sin_chequeo'            then 'sin chequeo'
               when 'satisfaccion_baja'      then case when x.n = 1 then 'satisfacción baja' else 'satisfacciones bajas' end
               else x.tipo
             end, ', ' order by x.n desc, x.tipo)
      into v_conteo
    from (
      select a.tipo, count(*) as n
      from public.cs_alertas a
      where a.id = any (v_ids)
      group by a.tipo
    ) x;

    v_txt := concat_ws(E'\n',
      format('**Producto · %s** — %s', r.nombre, to_char(public.cs_hoy(), 'DD/MM/YYYY')),
      format('Activos: %s | Rojo: %s | Amarillo: %s',
             coalesce(k.clientes_activos, 0), coalesce(k.clientes_rojo, 0), coalesce(k.clientes_amarillo, 0)),
      format('Devoluciones pendientes: %s (%s%%) | Vencidas SLA: %s',
             coalesce(k.dev_pendientes, 0), coalesce(k.pct_dev_pendientes, 0), coalesce(k.dev_vencidas_sla, 0)),
      format('Onboarding pendientes: %s', coalesce(k.onboarding_pendientes, 0)),
      format('Por vencer (%sd): %s | Renovaciones en proceso: %s',
             r.aviso_renovacion_dias, coalesce(k.por_vencer, 0), coalesce(k.en_renovacion, 0)),
      'Nuevas alertas: ' || coalesce(v_conteo, 'ninguna'));

    v_id := public.cs_discord_post(r.id, 'digest', v_txt, p_enviar);

    if v_id is not null and v_total > 0 then
      update public.cs_alertas set notificada_discord_at = now() where id = any (v_ids);
      v_marcadas := v_marcadas + v_total;
    end if;

    v_envios := v_envios || jsonb_build_object('programa_id', r.id, 'envio_id', v_id, 'alertas', v_total);
  end loop;

  return jsonb_build_object('programas', jsonb_array_length(v_envios),
                            'alertas_notificadas', v_marcadas,
                            'envios', v_envios,
                            'corrido_at', now());
end;
$fn$;


-- =====================================================================
-- 5. cs_resumen_semanal(p_enviar)
-- =====================================================================
-- Lunes. Semana = los últimos 7 días hasta ahora. Por programa activo con
-- Discord activo:
--   **Producto · <programa>** — resumen semanal (dd/mm al dd/mm)
--   Renovación: X% histórica | En la semana: X renovados, X no renovados
--   Satisfacción 90d: X/10 (n respuestas) | NPS 90d: X
--   Devoluciones entregadas en la semana: X | Entrega promedio: X h (SLA X h)
--   Hoy: X activos | Rojo X | Amarillo X
-- Solo agregados del programa, ningún dato de clientes (igual que el digest).
-- Tasa, satisfacción y NPS salen de cs_v_kpis_programa; lo de la semana
-- se cuenta con los mismos criterios que cs_v_metricas_mensuales
-- (resultado_at / entregada_at).
create or replace function public.cs_resumen_semanal(p_enviar boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r        record;
  k        record;
  v_desde  timestamptz := now() - interval '7 days';
  v_ren    int;
  v_noren  int;
  v_dev    int;
  v_horas  numeric;
  v_txt    text;
  v_id     bigint;
  v_envios jsonb := '[]'::jsonb;
begin
  for r in
    select p.id, p.nombre, p.sla_devolucion_horas
    from public.cs_programas p
    join public.cs_integraciones i on i.programa_id = p.id
    where p.activo and i.discord_activo and i.discord_webhook_url is not null
    order by p.id
  loop
    select * into k from public.cs_v_kpis_programa v where v.programa_id = r.id;

    select count(*) filter (where x.estado = 'renovado'),
           count(*) filter (where x.estado = 'no_renovado')
      into v_ren, v_noren
    from public.cs_renovaciones x
    where x.programa_id = r.id and x.resultado_at >= v_desde;

    select count(*), round(avg(extract(epoch from (d.entregada_at - d.solicitada_at)) / 3600.0), 1)
      into v_dev, v_horas
    from public.cs_devoluciones d
    where d.programa_id = r.id and d.estado = 'entregada' and d.entregada_at >= v_desde;

    v_txt := concat_ws(E'\n',
      format('**Producto · %s** — resumen semanal (%s al %s)', r.nombre,
             to_char((v_desde at time zone 'America/Argentina/Buenos_Aires')::date, 'DD/MM'),
             to_char(public.cs_hoy(), 'DD/MM')),
      format('Renovación: %s histórica | En la semana: %s renovados, %s no renovados',
             coalesce(k.tasa_renovacion || '%', '—'), v_ren, v_noren),
      format('Satisfacción 90d: %s (%s respuestas) | NPS 90d: %s',
             coalesce(k.satisfaccion_prom_90d || '/10', '—'), coalesce(k.respuestas_90d, 0),
             coalesce(k.nps_90d::text, '—')),
      format('Devoluciones entregadas en la semana: %s | Entrega promedio: %s (SLA %s h)',
             v_dev, coalesce(v_horas || ' h', '—'), r.sla_devolucion_horas),
      format('Hoy: %s activos | Rojo %s | Amarillo %s',
             coalesce(k.clientes_activos, 0), coalesce(k.clientes_rojo, 0), coalesce(k.clientes_amarillo, 0)));

    v_id := public.cs_discord_post(r.id, 'semanal', v_txt, p_enviar);
    v_envios := v_envios || jsonb_build_object('programa_id', r.id, 'envio_id', v_id);
  end loop;

  return jsonb_build_object('programas', jsonb_array_length(v_envios), 'envios', v_envios, 'corrido_at', now());
end;
$fn$;


-- =====================================================================
-- 6. PERMISOS
-- =====================================================================
-- Nada para public ni anon. authenticated solo ejecuta cs_probar_discord
-- (que valida fundador adentro). El POST, el digest y el semanal solo los
-- corre el cron (postgres).
revoke all on function
  public.cs_discord_post(text, text, text, boolean), public.cs_probar_discord(text),
  public.cs_digest_diario(boolean), public.cs_resumen_semanal(boolean)
from public, anon, authenticated;

grant execute on function public.cs_probar_discord(text) to authenticated;


-- =====================================================================
-- 7. CRON
-- =====================================================================
select cron.unschedule(jobid) from cron.job
where jobname in ('cs_diario', 'cs_semanal')
   or command ~ 'cs_(correr_diario|digest_diario|resumen_semanal)';

-- Un solo job para las dos: el digest tiene que ver las alertas ya
-- recalculadas. Si cs_correr_diario falla, el digest no sale y el error
-- queda en cron.job_run_details.
select cron.schedule('cs_diario', '0 12 * * *',
  $cron$ select public.cs_correr_diario(); select public.cs_digest_diario(); $cron$);

select cron.schedule('cs_semanal', '10 12 * * 1',
  $cron$ select public.cs_resumen_semanal(); $cron$);

commit;


-- =====================================================================
-- 8. PRUEBA DE HUMO (no deja datos, no envía nada)
-- =====================================================================
-- Crea un programa propio (humo036) con un webhook falso, para que los
-- números sean exactos y no dependan de los clientes reales. Todo con
-- p_enviar = false, y al final fuerza un error para deshacer TODO
-- (incluidas las marcas notificada_discord_at que el digest haya puesto
-- en alertas reales de otros programas).
drop table if exists pg_temp.cs_smoke36;
create temp table cs_smoke36 (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res      text[] := '{}';
  v_cli    uuid;
  v_j      jsonb;
  v_id     bigint;
  v_n      int;
  v_txt    text;
  v_state  text;
  v_desde_id bigint;
begin
  begin
    -- ---------- datos ----------
    select coalesce(max(id), 0) into v_desde_id from public.cs_discord_envios;

    insert into public.cs_programas (id, nombre, activo) values ('humo036', '__humo036__', true);
    insert into public.cs_integraciones (programa_id, discord_webhook_url, discord_activo)
    values ('humo036', 'https://discord.com/api/webhooks/0/__humo036__', true);

    -- Nombre y textos con pinta de reales a propósito: es lo que NO tiene que salir.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo036', 'Juana Humodetreintayseis', public.cs_hoy() - 10, public.cs_hoy() + 80, 'activo')
    returning id into v_cli;

    insert into public.cs_alertas (programa_id, cliente_id, tipo, mensaje, clave_dedupe)
    select 'humo036', v_cli, t.tipo, t.mensaje, 'humo036:' || t.o
    from (values
      (1, 'devolucion_vencida',  'Devolución "Portafolio de Juana" fuera del SLA de 72 h'),
      (2, 'devolucion_vencida',  'Devolución "Portafolio de Juana 2" fuera del SLA de 72 h'),
      (3, 'devolucion_vencida',  'Devolución "Portafolio de Juana 3" fuera del SLA de 72 h'),
      (4, 'onboarding_demorado', 'Onboarding sin agendar hace 10 día(s)'),
      (5, 'onboarding_demorado', 'Onboarding sin agendar hace 11 día(s)'),
      (6, 'sin_chequeo',         'Sin chequeo hace 9 día(s)')
    ) as t(o, tipo, mensaje);

    -- ---------- digest ----------
    v_j := public.cs_digest_diario(false);
    select e.contenido, e.request_id into v_txt, v_id
    from public.cs_discord_envios e
    where e.programa_id = 'humo036' and e.tipo = 'digest'
    order by e.id desc limit 1;

    -- 1. arma el mensaje del programa con Discord activo
    res := res || format('digest arma el mensaje del programa|%s|%s',
                         v_txt like '**Producto · \_\_humo036\_\_** — %', replace(left(coalesce(v_txt, '(nada)'), 80), '|', '/'));

    -- 2. números de cs_v_kpis_programa
    res := res || format('digest usa los KPIs del programa|%s|%s',
                         v_txt like '%Activos: 1 | Rojo: %', replace(split_part(v_txt, E'\n', 2), '|', '/'));

    -- 3. conteos por tipo, de más a menos, con singular/plural
    res := res || format('digest cuenta las alertas por tipo|%s|%s',
                         v_txt like '%Nuevas alertas: 3 devoluciones fuera de SLA, 2 onboarding demorados, 1 sin chequeo',
                         replace(coalesce(split_part(v_txt, E'\n', 6), '(nada)'), '|', '/'));

    -- 4. ni el nombre del cliente ni el texto de las alertas
    res := res || format('digest sin nombre del cliente ni texto de alertas|%s|%s',
                         v_txt not like '%Juana%' and v_txt not like '%Humodetreintayseis%'
                           and v_txt not like '%Portafolio%' and v_txt not like '%hace 10 día%',
                         'busca Juana / Humodetreintayseis / Portafolio / hace 10 día');

    -- 5. con p_enviar = false no hay POST
    res := res || format('p_enviar=false no hace el POST|%s|request_id=%s', v_id is null, coalesce(v_id::text, 'null'));

    -- 6. marca las 6 como notificadas
    select count(*) into v_n from public.cs_alertas
    where programa_id = 'humo036' and notificada_discord_at is not null;
    res := res || format('digest marca las 6 alertas|%s|marcadas=%s', v_n = 6, v_n);

    -- 6b. segunda corrida: ya no son nuevas
    perform public.cs_digest_diario(false);
    select e.contenido into v_txt from public.cs_discord_envios e
    where e.programa_id = 'humo036' and e.tipo = 'digest' order by e.id desc limit 1;
    res := res || format('2a corrida: sin alertas nuevas|%s|%s',
                         v_txt like '%Nuevas alertas: ninguna',
                         replace(coalesce(split_part(v_txt, E'\n', 6), '(nada)'), '|', '/'));

    -- 7. con Discord desactivado no arma nada ni marca
    update public.cs_integraciones set discord_activo = false where programa_id = 'humo036';
    insert into public.cs_alertas (programa_id, cliente_id, tipo, mensaje, clave_dedupe)
    values ('humo036', v_cli, 'sin_chequeo', 'alerta de humo 13', 'humo036:13');
    select count(*) into v_n from public.cs_discord_envios where programa_id = 'humo036';
    v_j := public.cs_digest_diario(false);
    select count(*) - v_n into v_n from public.cs_discord_envios where programa_id = 'humo036';
    res := res || format('Discord desactivado: no envía ni marca|%s|envios_nuevos=%s marcada=%s',
                         v_n = 0 and (select notificada_discord_at is null from public.cs_alertas where clave_dedupe = 'humo036:13'),
                         v_n, (select (notificada_discord_at is not null)::text from public.cs_alertas where clave_dedupe = 'humo036:13'));

    -- 8. la prueba sí anda desactivado (para probar antes de activar)
    v_id := public.cs_discord_post('humo036', 'prueba', 'hola', false);
    res := res || format('tipo prueba anda con Discord desactivado|%s|envio_id=%s', v_id is not null, coalesce(v_id::text, 'null'));

    -- 9. corta a 1900 caracteres
    v_id := public.cs_discord_post('humo036', 'prueba', repeat('x', 3000), false);
    select length(contenido) into v_n from public.cs_discord_envios where id = v_id;
    res := res || format('corta el mensaje a 1900 caracteres|%s|largo=%s', v_n = 1900, v_n);

    -- 10. sin webhook no hace nada
    update public.cs_integraciones set discord_webhook_url = null where programa_id = 'humo036';
    v_id := public.cs_discord_post('humo036', 'prueba', 'hola', false);
    res := res || format('sin webhook no hace nada|%s|envio_id=%s', v_id is null, coalesce(v_id::text, 'null'));

    -- ---------- resumen semanal ----------
    update public.cs_integraciones
       set discord_webhook_url = 'https://discord.com/api/webhooks/0/__humo036__', discord_activo = true
     where programa_id = 'humo036';
    -- 2 en la semana (24 h y 48 h -> 36.0 h) y 1 de hace 10 días que no cuenta
    insert into public.cs_devoluciones (cliente_id, titulo, solicitada_at, estado, loom_url, entregada_at) values
      (v_cli, '__humo036_d1__', now() - interval '3 days',  'entregada', 'https://www.loom.com/share/humo036', now() - interval '2 days'),
      (v_cli, '__humo036_d2__', now() - interval '4 days',  'entregada', 'https://www.loom.com/share/humo036', now() - interval '2 days'),
      (v_cli, '__humo036_d3__', now() - interval '11 days', 'entregada', 'https://www.loom.com/share/humo036', now() - interval '10 days');

    perform public.cs_resumen_semanal(false);
    select e.contenido into v_txt from public.cs_discord_envios e
    where e.programa_id = 'humo036' and e.tipo = 'semanal' order by e.id desc limit 1;

    -- 11. cuenta solo lo de los últimos 7 días y promedia bien
    res := res || format('semanal: devoluciones y promedio de la semana|%s|%s',
                         v_txt like '%Devoluciones entregadas en la semana: 2 | Entrega promedio: 36.0 h (SLA 72 h)%',
                         replace(coalesce(split_part(v_txt, E'\n', 4), '(nada)'), '|', '/'));

    -- 12. sin renovaciones ni respuestas muestra "—", no rompe
    res := res || format('semanal: sin datos muestra —|%s|%s',
                         v_txt like '%Renovación: — histórica%' and v_txt like '%Satisfacción 90d: — (0 respuestas)%',
                         replace(coalesce(split_part(v_txt, E'\n', 2), '(nada)'), '|', '/'));

    -- 12b. el semanal tampoco nombra al cliente ni a sus devoluciones
    res := res || format('semanal sin nombre del cliente ni titulos|%s|%s',
                         v_txt not like '%Juana%' and v_txt not like '%Humodetreintayseis%' and v_txt not like '%humo036\_d%',
                         'busca Juana / Humodetreintayseis / __humo036_d');

    -- 12c. ningún mensaje armado en esta prueba (de CUALQUIER programa,
    -- con los clientes reales) contiene el nombre de un cliente suyo.
    select count(*) into v_n
    from public.cs_discord_envios e
    join public.cs_clientes c on c.programa_id = e.programa_id
    where e.id > v_desde_id
      and e.tipo in ('digest', 'semanal')
      and position(btrim(c.nombre) in e.contenido) > 0;
    res := res || format('ningun digest/semanal contiene nombres de clientes (todos los programas)|%s|coincidencias=%s',
                         v_n = 0, v_n);

    -- ---------- permisos ----------
    -- 13. un usuario logueado que no es fundador no puede probar
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000036","role":"authenticated"}', true);
    begin
      perform public.cs_probar_discord('humo036');
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    perform set_config('request.jwt.claims', '', true);
    res := res || format('probar_discord rechaza a un no fundador|%s|sqlstate=%s', v_state = '42501', v_state);

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s (%s)', replace(sqlerrm, '|', '/'), sqlstate);
    end if;
  end;

  insert into cs_smoke36 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 9. QUERY DE CONTROL (una sola tabla de resultados; mirar la columna ok)
-- =====================================================================
with
nuevas as (
  select p.oid,
         p.proname::text as proname,
         p.prosecdef,
         coalesce(array_to_string(p.proconfig, ','), '') as config
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('cs_discord_post', 'cs_probar_discord', 'cs_digest_diario', 'cs_resumen_semanal')
),
jobs as (
  select jobname::text as jobname, schedule::text as schedule, active, command::text as command
  from cron.job
  where jobname in ('cs_diario', 'cs_semanal')
     or command ~ 'cs_(correr_diario|digest_diario|resumen_semanal)'
)
select '01 funciones nuevas' as control, 'cantidad' as objeto, '4' as esperado,
       (select count(*) from nuevas)::text as obtenido, (select count(*) from nuevas) = 4 as ok
union all
select '02 security definer', f.proname, 'true', f.prosecdef::text, f.prosecdef from nuevas f
union all
select '03 search_path', f.proname, 'search_path=public', f.config, f.config ~ 'search_path=public' from nuevas f
union all
select '04 sin execute para anon', f.proname, 'false',
       has_function_privilege('anon', f.oid, 'EXECUTE')::text,
       not has_function_privilege('anon', f.oid, 'EXECUTE')
from nuevas f
union all
select '05 execute para authenticated', f.proname,
       case when f.proname = 'cs_probar_discord' then 'true' else 'false' end,
       has_function_privilege('authenticated', f.oid, 'EXECUTE')::text,
       has_function_privilege('authenticated', f.oid, 'EXECUTE') = (f.proname = 'cs_probar_discord')
from nuevas f
union all
select '06 tabla de envios', 'cs_discord_envios: RLS / anon sin privilegios',
       'rls=true anon=0',
       'rls=' || c.relrowsecurity::text || ' anon='
         || (select count(*) from information_schema.role_table_grants g
             where g.grantee = 'anon' and g.table_schema = 'public' and g.table_name = 'cs_discord_envios')::text,
       c.relrowsecurity
         and (select count(*) from information_schema.role_table_grants g
              where g.grantee = 'anon' and g.table_schema = 'public' and g.table_name = 'cs_discord_envios') = 0
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'cs_discord_envios'
union all
select '07 cron', 'cs_diario', '0 12 * * * activo',
       coalesce((select schedule || case when active then ' activo' else ' INACTIVO' end from jobs where jobname = 'cs_diario'), '(no existe)'),
       coalesce((select schedule = '0 12 * * *' and active from jobs where jobname = 'cs_diario'), false)
union all
select '07 cron', 'cs_semanal', '10 12 * * 1 activo',
       coalesce((select schedule || case when active then ' activo' else ' INACTIVO' end from jobs where jobname = 'cs_semanal'), '(no existe)'),
       coalesce((select schedule = '10 12 * * 1' and active from jobs where jobname = 'cs_semanal'), false)
union all
select '07 cron', 'jobs que llaman a cs_correr_diario', '1',
       (select count(*) from jobs where command ~ 'cs_correr_diario')::text,
       (select count(*) from jobs where command ~ 'cs_correr_diario') = 1
union all
select '08 la prueba de humo no dejo datos', 'programa humo036 / envios', '0',
       ((select count(*) from public.cs_programas where id = 'humo036')
        + (select count(*) from public.cs_discord_envios where programa_id = 'humo036'))::text,
       ((select count(*) from public.cs_programas where id = 'humo036')
        + (select count(*) from public.cs_discord_envios where programa_id = 'humo036')) = 0
union all
select '09 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke36 s
order by 1, 2;


-- =====================================================================
-- DESPUÉS DE CORRER
-- =====================================================================
-- Para no esperar a las 9:00: cargá el webhook en Config > Discord,
-- activalo y corré
--   select public.cs_probar_discord('liam');
-- Tiene que llegar "Prueba de Dystopia Producto · ..." al canal.
--
-- Entrega de cada mensaje (status 200 = llegó):
--   select e.id, e.created_at, e.programa_id, e.tipo, h.status_code, h.timed_out, left(e.contenido, 80)
--   from cs_discord_envios e left join net._http_response h on h.id = e.request_id
--   order by e.id desc limit 10;
--
-- Corridas del cron:
--   select j.jobname, d.status, d.return_message, d.start_time
--   from cron.job_run_details d join cron.job j using (jobid)
--   where j.jobname in ('cs_diario', 'cs_semanal')
--   order by d.start_time desc limit 10;
