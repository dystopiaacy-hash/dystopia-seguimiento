-- =====================================================================
-- 106-producto-satisfaccion-wins-estado-dudas.sql
-- PRODUCTO: satisfaccion por etapa, tarjeta del alumno desde la llamada, wins y upsell, dudas frecuentes
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), primero en el banco de pruebas.
-- Numeracion global asignada por el jefe: 106. Requiere la 102 corrida.
-- Evitar :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
--
-- Que hace (todo aditivo: no pisa ni mueve datos existentes):
--   A. Discord por tipo de aviso y por programa:
--        cs_discord_canales (programa, tipo satisfaccion|wins, webhook, activo, incluir_nombre, incluir_monto)
--        cs_discord_avisos  (registro de lo enviado)  +  cs_discord_canal_post(...)
--      Sin webhook cargado (o inactivo) no se envia nada y NO rompe. Mismo mecanismo que cs_discord_post (036).
--   B. Satisfaccion por etapa:
--        cs_satisf_momentos (cuando se pide, por programa), cs_satisf_envios (un link por alumno y momento,
--        una sola respuesta por link). Pagina publica por token: cs_satisf_estado / cs_satisf_responder.
--        Avisos a Discord: puntaje menor a 7, y 9 o 10 con "daria testimonio: si".
--   C. Llamadas ampliadas: cs_llamadas + resumen, en_que_esta, proximos_pasos; cs_llamada_transcripciones
--      (texto largo, solo quien edita). Funciones cs_llamada_crear (front, atomica, con RLS) y
--      cs_llamada_cargar (fundador / service role, resuelve al alumno por nombre).
--   D. Wins (cs_wins, con pendiente "Pedir referido" y aviso a Discord) y marca manual de upsell (cs_upsell_marcas).
--   E. Dudas frecuentes: cs_dudas, cs_duda_menciones, cs_v_dudas, cs_duda_mencion (front),
--      cs_duda_registrar (fundador / service role, en tanda), cs_duda_unir (solo fundador).
--   F. cs_v_alumno_resumen: una fila por alumno con ultimo "en que esta" / "proximos pasos", ultimo puntaje,
--      wins de 30 dias y upsell. Lo leen Clientes, Maestro y la ficha.
--   G. cs_maestro_claves_sistema(): parte de la lista vigente de la 102 (23 claves) y suma 4 al final:
--      en_que_esta, proximos_pasos, satisfaccion_ultima, upsell. Respaldo en cs_bak_106_funciones.
--
-- No se tocan: cs_formularios / cs_respuestas (satisfaccion historica y metricas), cs_integraciones,
-- cs_discord_post, cs_accionables, cs_renovaciones, cs_cola_hoy, cron, alertas, onboarding.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo: lo que usa esta migracion tiene que existir.
do $$
declare
  v_falta text;
  v_def   text[];
  v_102   text[] := array[
    'nombre', 'prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha',
    'nota_csm', 'testimonio', 'renovacion_estado', 'renovacion_producto',
    'aviso_1_at', 'aviso_2_at', 'estado', 'producto', 'etapa', 'dias_restantes',
    'acc', 'dev_pendientes', 'ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
    'proximo_contacto', 'renovaciones_count', 'onb_avance', 'ultima_llamada'];
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'cs 106: hace falta Postgres 15 o mas (security_invoker y ON DELETE SET NULL (col))';
  end if;
  select string_agg(r.f, ', ') into v_falta
  from (values
    ('cs_puede_ver(text)'), ('cs_puede_editar(text)'), ('cs_puede_borrar()'), ('es_fundador()'),
    ('cs_hoy()'), ('cs_tg_updated_at()'), ('cs_norm_nombre(text)'), ('cs_maestro_claves_sistema()'),
    ('cs_discord_post(text,text,text,boolean)')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 106: faltan funciones (corrieron la 001, 036, 070, 071, 079 y 102?): %', v_falta;
  end if;
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_clientes', 'cs_onboardings', 'cs_llamadas',
                    'cs_llamada_accionables', 'cs_llamada_recursos', 'cs_accesos', 'crm_members']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception 'cs 106: faltan tablas (la 102 y la 093 tienen que estar corridas): %', v_falta;
  end if;
  if to_regnamespace('net') is null then
    raise exception 'cs 106: falta la extension pg_net (schema net), la usa Discord desde la 036';
  end if;
  -- La lista de claves vigente tiene que ser exactamente la de la 102: si otra migracion la
  -- redefinio despues, esta la pisaria. Revisar y partir de la definicion vigente.
  v_def := public.cs_maestro_claves_sistema();
  if not (v_def @> v_102 and v_102 @> v_def) then
    if v_def @> array['en_que_esta', 'proximos_pasos', 'satisfaccion_ultima', 'upsell'] then
      raise notice 'cs 106: la lista de claves ya incluye las de la 106 (segunda corrida).';
    else
      raise exception 'cs 106: cs_maestro_claves_sistema() no es la de la 102 (%). Partir de la definicion vigente.', v_def;
    end if;
  end if;
end $$;

-- cs_clientes / cs_llamadas llevan FK desde las tablas nuevas: lock antes de crearlas (regla del deadlock).
lock table public.cs_programas, public.cs_clientes, public.cs_llamadas in share row exclusive mode;


-- =====================================================================
-- A. DISCORD POR TIPO DE AVISO
-- =====================================================================
create table if not exists public.cs_discord_canales (
  programa_id     text not null references public.cs_programas(id) on delete cascade,
  tipo            text not null check (tipo in ('satisfaccion', 'wins')),
  webhook_url     text check (webhook_url is null
                              or webhook_url ~* '^https://((canary|ptb)\.)?(discord|discordapp)\.com/api/webhooks/'),
  activo          boolean not null default false,
  -- false = el aviso dice "un alumno" en vez del nombre (regla vieja de Producto: solo conteos)
  incluir_nombre  boolean not null default true,
  -- el win se avisa sin monto salvo que este parametro lo habilite
  incluir_monto   boolean not null default false,
  updated_at      timestamptz not null default now(),
  primary key (programa_id, tipo)
);
comment on table public.cs_discord_canales is
  'Webhook de Discord por programa y tipo de aviso (106): satisfaccion, wins. Solo fundador (igual que cs_integraciones).';

create table if not exists public.cs_discord_avisos (
  id           bigserial primary key,
  programa_id  text not null,
  tipo         text not null,
  contenido    text not null,
  request_id   bigint,
  created_at   timestamptz not null default now()
);
create index if not exists cs_discord_avisos_programa_idx on public.cs_discord_avisos (programa_id, created_at);

drop trigger if exists cs_discord_canales_updated_at on public.cs_discord_canales;
create trigger cs_discord_canales_updated_at before update on public.cs_discord_canales
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_discord_canales enable row level security;
alter table public.cs_discord_avisos enable row level security;
revoke all on table public.cs_discord_canales from anon, authenticated;
revoke all on table public.cs_discord_avisos from anon, authenticated;
revoke all on sequence public.cs_discord_avisos_id_seq from anon, authenticated;
grant select, insert, update, delete on table public.cs_discord_canales to authenticated;
grant select on table public.cs_discord_avisos to authenticated;
drop policy if exists cs_fundador on public.cs_discord_canales;
create policy cs_fundador on public.cs_discord_canales for all to authenticated
  using (public.es_fundador()) with check (public.es_fundador());
drop policy if exists cs_fundador on public.cs_discord_avisos;
create policy cs_fundador on public.cs_discord_avisos for select to authenticated
  using (public.es_fundador());

-- Unico lugar que habla con Discord para estos avisos. No tira nunca: sin webhook, inactivo o con
-- error de red devuelve null y la operacion que lo llamo sigue. p_forzar = el boton "Probar".
create or replace function public.cs_discord_canal_post(
  p_programa  text,
  p_tipo      text,
  p_contenido text,
  p_forzar    boolean default false
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
  select c.webhook_url, c.activo into v_url, v_activo
  from public.cs_discord_canales c
  where c.programa_id = p_programa and c.tipo = p_tipo;

  if v_url is null or (not coalesce(v_activo, false) and not p_forzar) then
    return null;
  end if;

  v_txt := case when length(p_contenido) > 1900 then left(p_contenido, 1899) || '…' else p_contenido end;

  begin
    v_req := net.http_post(
      url     := v_url || case when v_url like '%?%' then '&' else '?' end || 'wait=true',
      headers := jsonb_build_object('content-type', 'application/json'),
      body    := jsonb_build_object('username', 'Dystopia Producto', 'content', v_txt,
                                    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)),
      timeout_milliseconds := 10000);
  exception when others then
    v_req := null;
  end;

  insert into public.cs_discord_avisos (programa_id, tipo, contenido, request_id)
  values (p_programa, p_tipo, v_txt, v_req)
  returning id into v_id;
  return v_id;
exception when others then
  return null;
end;
$fn$;

-- Boton "Probar" de cada canal (solo fundador, o llamada sin sesion desde el SQL Editor).
create or replace function public.cs_probar_discord_canal(p_programa text, p_tipo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id bigint;
  v_nombre text;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede probar Discord' using errcode = '42501';
  end if;
  select nombre into v_nombre from public.cs_programas where id = p_programa;
  if v_nombre is null then
    raise exception 'cs: programa inexistente' using errcode = '22023';
  end if;
  if p_tipo not in ('satisfaccion', 'wins') then
    raise exception 'cs: tipo de aviso invalido' using errcode = '22023';
  end if;
  v_id := public.cs_discord_canal_post(p_programa, p_tipo,
    'Mensaje de prueba de Dystopia Producto · ' || v_nombre || ' · canal ' || p_tipo, true);
  if v_id is null then
    raise exception 'cs: no hay webhook cargado para este canal' using errcode = 'P0001';
  end if;
  return jsonb_build_object('ok', true, 'envio', v_id);
end;
$fn$;

-- Helpers internos de texto (sin permisos para la app: los usan las funciones definer).
create or replace function public.cs_discord_nombre(p_programa text, p_tipo text, p_nombre text)
returns text
language sql stable security definer set search_path = public
as $$
  select case when coalesce((select c.incluir_nombre from public.cs_discord_canales c
                             where c.programa_id = p_programa and c.tipo = p_tipo), true)
              then coalesce(nullif(btrim(p_nombre), ''), 'Un alumno') else 'Un alumno' end
$$;


-- =====================================================================
-- B. SATISFACCION POR ETAPA
-- =====================================================================
-- B1. Momentos: cuando se pide el formulario. Por programa; lo definen fundador o CSM.
--     tipo                 valor      el momento llega cuando...
--     onboarding_completo  (null)     el onboarding por link (093) esta completado
--     dias_desde_inicio    N dias     pasaron N dias desde fecha_inicio
--     porcentaje_ciclo     1 a 99     paso ese % entre fecha_inicio y fecha_fin (50 = mitad)
--     dias_antes_fin       N dias     faltan N dias o menos para fecha_fin
--     desde = no se piden formularios de hitos anteriores a esa fecha (evita pedirle a todo el historico).
create table if not exists public.cs_satisf_momentos (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id),
  nombre       text not null check (btrim(nombre) <> '' and char_length(nombre) <= 60),
  tipo         text not null check (tipo in ('onboarding_completo', 'dias_desde_inicio', 'porcentaje_ciclo', 'dias_antes_fin')),
  valor        int,
  activo       boolean not null default true,
  orden        int not null default 0,
  desde        date not null default public.cs_hoy(),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  constraint cs_satisf_momentos_valor_chk check (
    (tipo = 'onboarding_completo' and valor is null)
    or (tipo = 'dias_desde_inicio' and valor between 0 and 1000)
    or (tipo = 'porcentaje_ciclo' and valor between 1 and 99)
    or (tipo = 'dias_antes_fin' and valor between 0 and 1000)),
  constraint cs_satisf_momentos_id_programa_uk unique (id, programa_id)
);
create index if not exists cs_satisf_momentos_programa_idx on public.cs_satisf_momentos (programa_id, orden);
comment on table public.cs_satisf_momentos is
  'Momentos en que se pide la satisfaccion (106). Por programa: fin de onboarding, mitad, N dias antes de vencer, etc.';

drop trigger if exists cs_satisf_momentos_updated_at on public.cs_satisf_momentos;
create trigger cs_satisf_momentos_updated_at before update on public.cs_satisf_momentos
  for each row execute function public.cs_tg_updated_at();

-- B2. Envios: un link por alumno y momento. La respuesta vive en la misma fila (una sola por link).
create table if not exists public.cs_satisf_envios (
  id              uuid primary key default gen_random_uuid(),
  programa_id     text not null references public.cs_programas(id),
  cliente_id      uuid not null,
  momento_id      uuid,
  momento_nombre  text not null check (char_length(momento_nombre) <= 60),
  token           text not null unique
                  check (token ~ '^[0-9a-f]{64}$')
                  default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  enviado_at      timestamptz,
  enviado_por     uuid,
  respondido_at   timestamptz,
  puntaje         int check (puntaje is null or puntaje between 1 and 10),
  mejor           text check (mejor is null or char_length(mejor) <= 2000),
  mejorar         text check (mejorar is null or char_length(mejorar) <= 2000),
  testimonio      boolean,
  constraint cs_satisf_envios_resp_chk check (
    (respondido_at is null and puntaje is null)
    or (respondido_at is not null and puntaje is not null and testimonio is not null)),
  constraint cs_satisf_envios_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  -- borrar un momento no borra lo respondido: queda con el nombre que tenia
  constraint cs_satisf_envios_momento_fk foreign key (momento_id, programa_id)
    references public.cs_satisf_momentos (id, programa_id) on delete set null (momento_id)
);
create unique index if not exists cs_satisf_envios_cliente_momento_uk
  on public.cs_satisf_envios (cliente_id, momento_id) where momento_id is not null;
create index if not exists cs_satisf_envios_programa_idx on public.cs_satisf_envios (programa_id, respondido_at);
create index if not exists cs_satisf_envios_cliente_idx on public.cs_satisf_envios (cliente_id, respondido_at);
comment on table public.cs_satisf_envios is
  'Un link de satisfaccion por alumno y momento (106). token = link publico: NO es legible por la app (permiso por columna); se obtiene por cs_satisf_link. La respuesta (una sola) vive en la misma fila.';

-- B3. RLS: ver = cs_puede_ver; el token no se puede leer; escribir solo por las funciones; borrar solo fundador.
do $$
declare
  t text;
begin
  foreach t in array array['cs_satisf_momentos', 'cs_satisf_envios'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('drop policy if exists cs_select on public.%I', t);
    execute format('create policy cs_select on public.%I for select to authenticated
                      using (public.cs_puede_ver(programa_id))', t);
    execute format('drop policy if exists cs_delete on public.%I', t);
    execute format('create policy cs_delete on public.%I for delete to authenticated
                      using (public.cs_puede_borrar())', t);
    execute format('grant delete on table public.%I to authenticated', t);
  end loop;

  -- momentos: la app edita directo (cs_puede_editar)
  grant select, insert, update on table public.cs_satisf_momentos to authenticated;
  drop policy if exists cs_insert on public.cs_satisf_momentos;
  create policy cs_insert on public.cs_satisf_momentos for insert to authenticated
    with check (public.cs_puede_editar(programa_id));
  drop policy if exists cs_update on public.cs_satisf_momentos;
  create policy cs_update on public.cs_satisf_momentos for update to authenticated
    using (public.cs_puede_editar(programa_id)) with check (public.cs_puede_editar(programa_id));

  -- envios: solo lectura por columna (sin token). Las altas y cambios van por funciones definer.
  grant select (id, programa_id, cliente_id, momento_id, momento_nombre, created_at, created_by,
                enviado_at, enviado_por, respondido_at, puntaje, mejor, mejorar, testimonio)
    on table public.cs_satisf_envios to authenticated;
end $$;

-- B4. Quien llego a un momento y todavia no tiene el link enviado.
-- security definer: lee cs_onboardings (la app no tiene permiso de columna sobre todo); chequea cs_puede_ver adentro.
create or replace function public.cs_satisf_pendientes(p_programa text)
returns table (
  cliente_id   uuid,
  nombre       text,
  momento_id   uuid,
  momento      text,
  hito_fecha   date,
  envio_id     uuid,
  tiene_link   boolean
)
language plpgsql stable security definer set search_path = public
as $fn$
begin
  if not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: sin acceso a este programa' using errcode = '42501';
  end if;
  return query
  select c.id, c.nombre, m.id, m.nombre, h.hito, e.id, (e.id is not null)
  from public.cs_satisf_momentos m
  join public.cs_clientes c on c.programa_id = m.programa_id
  left join public.cs_onboardings ob on ob.cliente_id = c.id and ob.estado = 'completado'
  cross join lateral (
    select case m.tipo
             when 'onboarding_completo' then (ob.completado_at at time zone 'America/Argentina/Buenos_Aires')::date
             when 'dias_desde_inicio'   then c.fecha_inicio + m.valor
             when 'porcentaje_ciclo'    then c.fecha_inicio + ((c.fecha_fin - c.fecha_inicio) * m.valor / 100)
             when 'dias_antes_fin'      then c.fecha_fin - m.valor
           end as hito
  ) h
  left join public.cs_satisf_envios e on e.cliente_id = c.id and e.momento_id = m.id
  where m.programa_id = p_programa
    and m.activo
    and c.estado in ('onboarding', 'activo', 'en_renovacion')
    and h.hito is not null
    and h.hito <= public.cs_hoy()
    and h.hito >= m.desde
    and (e.id is null or e.enviado_at is null)
  order by h.hito, c.nombre;
end;
$fn$;

-- B5. Link de un alumno para un momento (lo crea si no existe). Devuelve el token: solo quien edita.
create or replace function public.cs_satisf_link(p_cliente uuid, p_momento uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_prog   text;
  v_mprog  text;
  v_mnom   text;
  e        public.cs_satisf_envios;
begin
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: no se encontro el alumno' using errcode = '22023';
  end if;
  if not coalesce(public.cs_puede_editar(v_prog), false) then
    raise exception 'cs: no tenes permiso para generar el link en este programa' using errcode = '42501';
  end if;
  select m.programa_id, m.nombre into v_mprog, v_mnom from public.cs_satisf_momentos m where m.id = p_momento;
  if v_mprog is distinct from v_prog then
    raise exception 'cs: el momento no es de este programa' using errcode = '22023';
  end if;

  insert into public.cs_satisf_envios (programa_id, cliente_id, momento_id, momento_nombre)
  values (v_prog, p_cliente, p_momento, v_mnom)
  on conflict (cliente_id, momento_id) where momento_id is not null do nothing;

  select * into e from public.cs_satisf_envios where cliente_id = p_cliente and momento_id = p_momento;
  return jsonb_build_object('envio_id', e.id, 'token', e.token, 'enviado_at', e.enviado_at,
                            'respondido_at', e.respondido_at, 'puntaje', e.puntaje);
end;
$fn$;

-- B6. "Marcar como enviado" (el envio al alumno lo hace el CSM a mano por WhatsApp).
create or replace function public.cs_satisf_marcar_enviado(p_envio uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_prog text;
begin
  select programa_id into v_prog from public.cs_satisf_envios where id = p_envio;
  if v_prog is null then
    raise exception 'cs: no se encontro el envio' using errcode = '22023';
  end if;
  if not coalesce(public.cs_puede_editar(v_prog), false) then
    raise exception 'cs: no tenes permiso para marcar el envio en este programa' using errcode = '42501';
  end if;
  update public.cs_satisf_envios
     set enviado_at = coalesce(enviado_at, now()), enviado_por = coalesce(enviado_por, auth.uid())
   where id = p_envio;
end;
$fn$;

-- B7. PAGINA PUBLICA (anon). Solo estas dos funciones; anon no tiene permiso sobre ninguna tabla.
-- Un token invalido y uno inexistente dan la misma respuesta.
create or replace function public.cs_satisf_estado(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  e       public.cs_satisf_envios;
  v_prog  text;
  v_marca text;
  v_nom   text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('valido', false);
  end if;
  select * into e from public.cs_satisf_envios where token = p_token;
  if e.id is null then
    return jsonb_build_object('valido', false);
  end if;
  select p.nombre, p.marca into v_prog, v_marca from public.cs_programas p where p.id = e.programa_id;
  select split_part(btrim(c.nombre), ' ', 1) into v_nom from public.cs_clientes c where c.id = e.cliente_id;
  return jsonb_build_object(
    'valido', true,
    'respondido', e.respondido_at is not null,
    'programa', coalesce(v_marca, v_prog),
    'alumno', v_nom,
    'momento', e.momento_nombre);
end;
$fn$;

create or replace function public.cs_satisf_responder(
  p_token      text,
  p_puntaje    int,
  p_mejor      text,
  p_mejorar    text,
  p_testimonio boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  e        public.cs_satisf_envios;
  v_mejor  text := nullif(btrim(coalesce(p_mejor, '')), '');
  v_mejorar text := nullif(btrim(coalesce(p_mejorar, '')), '');
  v_alumno text;
  v_prog   text;
  v_quien  text;
  v_txt    text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'Link invalido' using errcode = 'P0001';
  end if;
  if p_puntaje is null or p_puntaje < 1 or p_puntaje > 10 then
    raise exception 'Elegi un puntaje de 1 a 10.' using errcode = 'P0001';
  end if;
  if p_testimonio is null then
    raise exception 'Contanos si darias un testimonio.' using errcode = 'P0001';
  end if;
  if char_length(coalesce(v_mejor, '')) > 2000 or char_length(coalesce(v_mejorar, '')) > 2000 then
    raise exception 'El texto es demasiado largo.' using errcode = 'P0001';
  end if;

  -- lock de la fila: dos envios simultaneos del mismo link no se pisan
  select * into e from public.cs_satisf_envios where token = p_token for update;
  if e.id is null then
    raise exception 'Link invalido' using errcode = 'P0001';
  end if;
  if e.respondido_at is not null then
    raise exception 'Este formulario ya fue respondido. Gracias.' using errcode = 'P0001';
  end if;

  update public.cs_satisf_envios
     set respondido_at = now(), puntaje = p_puntaje, mejor = v_mejor, mejorar = v_mejorar,
         testimonio = p_testimonio, enviado_at = coalesce(enviado_at, now())
   where id = e.id;

  -- Avisos a Discord. Nunca rompen la respuesta del alumno.
  begin
    select c.nombre into v_alumno from public.cs_clientes c where c.id = e.cliente_id;
    select coalesce(p.marca, p.nombre) into v_prog from public.cs_programas p where p.id = e.programa_id;
    v_quien := public.cs_discord_nombre(e.programa_id, 'satisfaccion', v_alumno);
    if p_puntaje < 7 then
      v_txt := '⚠️ Satisfaccion baja · ' || coalesce(v_prog, e.programa_id) || E'\n'
            || 'Alumno: ' || v_quien || ' · ' || e.momento_nombre || E'\n'
            || 'Puntaje: ' || p_puntaje || '/10' || E'\n'
            || 'Que mejoraria: ' || coalesce(left(v_mejorar, 600), '(sin respuesta)');
      perform public.cs_discord_canal_post(e.programa_id, 'satisfaccion', v_txt);
    elsif p_puntaje >= 9 and p_testimonio then
      v_txt := '⭐ Puede dar testimonio · ' || coalesce(v_prog, e.programa_id) || E'\n'
            || 'Alumno: ' || v_quien || ' · ' || e.momento_nombre || E'\n'
            || 'Puntaje: ' || p_puntaje || '/10 · dijo que si daria testimonio: pedirselo.';
      perform public.cs_discord_canal_post(e.programa_id, 'satisfaccion', v_txt);
    end if;
  exception when others then
    null;
  end;

  return jsonb_build_object('ok', true);
end;
$fn$;


-- =====================================================================
-- C. LLAMADAS: resumen, en que esta, proximos pasos y transcripcion
-- =====================================================================
alter table public.cs_llamadas
  add column if not exists resumen        text check (resumen is null or char_length(resumen) <= 4000),
  add column if not exists en_que_esta    text check (en_que_esta is null or char_length(en_que_esta) <= 2000),
  add column if not exists proximos_pasos text check (proximos_pasos is null or char_length(proximos_pasos) <= 2000);

-- La transcripcion va aparte: es texto largo y la ficha carga cs_llamadas con select *.
-- Solo la ve quien edita el programa (no cliente@): puede traer comentarios internos del CSM.
create table if not exists public.cs_llamada_transcripciones (
  llamada_id   uuid primary key,
  programa_id  text not null references public.cs_programas(id),
  cliente_id   uuid not null,
  texto        text not null check (btrim(texto) <> '' and char_length(texto) <= 200000),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  constraint cs_llamada_transc_llamada_fk foreign key (llamada_id, cliente_id)
    references public.cs_llamadas (id, cliente_id) on delete cascade,
  constraint cs_llamada_transc_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
comment on table public.cs_llamada_transcripciones is
  'Transcripcion o resumen de Fathom pegado a mano o cargado por cs_llamada_cargar (106). Solo la ve quien edita el programa.';

drop trigger if exists cs_llamada_transc_updated_at on public.cs_llamada_transcripciones;
create trigger cs_llamada_transc_updated_at before update on public.cs_llamada_transcripciones
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_llamada_transcripciones enable row level security;
revoke all on table public.cs_llamada_transcripciones from anon, authenticated;
grant select, insert, update, delete on table public.cs_llamada_transcripciones to authenticated;
drop policy if exists cs_select on public.cs_llamada_transcripciones;
create policy cs_select on public.cs_llamada_transcripciones for select to authenticated
  using (public.cs_puede_editar(programa_id));
drop policy if exists cs_insert on public.cs_llamada_transcripciones;
create policy cs_insert on public.cs_llamada_transcripciones for insert to authenticated
  with check (public.cs_puede_editar(programa_id));
drop policy if exists cs_update on public.cs_llamada_transcripciones;
create policy cs_update on public.cs_llamada_transcripciones for update to authenticated
  using (public.cs_puede_editar(programa_id)) with check (public.cs_puede_editar(programa_id));
drop policy if exists cs_delete on public.cs_llamada_transcripciones;
create policy cs_delete on public.cs_llamada_transcripciones for delete to authenticated
  using (public.cs_puede_borrar());


-- =====================================================================
-- E. DUDAS FRECUENTES (antes de las funciones de llamada: cs_llamada_crear las usa)
-- =====================================================================
create table if not exists public.cs_dudas (
  id             uuid primary key default gen_random_uuid(),
  programa_id    text not null references public.cs_programas(id),
  texto          text not null check (btrim(texto) <> '' and char_length(texto) <= 300),
  texto_norm     text generated always as (public.cs_norm_nombre(texto)) stored,
  respuesta      text check (respuesta is null or char_length(respuesta) <= 2000),
  recurso_url    text check (recurso_url is null or (recurso_url ~* '^https?://[^[:space:]]+$' and char_length(recurso_url) <= 1000)),
  recurso_titulo text check (recurso_titulo is null or char_length(recurso_titulo) <= 200),
  origen         text not null default 'otro' check (origen in ('discord', 'llamada', 'whatsapp', 'otro')),
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  updated_at     timestamptz not null default now(),
  constraint cs_dudas_texto_norm_chk check (texto_norm is not null),
  constraint cs_dudas_id_programa_uk unique (id, programa_id)
);
create unique index if not exists cs_dudas_programa_texto_uk on public.cs_dudas (programa_id, texto_norm);
comment on table public.cs_dudas is
  'Dudas frecuentes por programa (106). La repeticion se mide en cs_duda_menciones por alumnos distintos.';

create table if not exists public.cs_duda_menciones (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id),
  duda_id      uuid not null,
  cliente_id   uuid not null,
  fecha        date not null default public.cs_hoy(),
  origen       text not null default 'otro' check (origen in ('discord', 'llamada', 'whatsapp', 'otro')),
  llamada_id   uuid,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  constraint cs_duda_menciones_duda_fk foreign key (duda_id, programa_id)
    references public.cs_dudas (id, programa_id) on delete cascade,
  constraint cs_duda_menciones_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  constraint cs_duda_menciones_llamada_fk foreign key (llamada_id, cliente_id)
    references public.cs_llamadas (id, cliente_id) on delete set null (llamada_id)
);
create unique index if not exists cs_duda_menciones_uk on public.cs_duda_menciones (duda_id, cliente_id, fecha);
create index if not exists cs_duda_menciones_programa_idx on public.cs_duda_menciones (programa_id, fecha);
create index if not exists cs_duda_menciones_cliente_idx on public.cs_duda_menciones (cliente_id);

drop trigger if exists cs_dudas_updated_at on public.cs_dudas;
create trigger cs_dudas_updated_at before update on public.cs_dudas
  for each row execute function public.cs_tg_updated_at();

-- La fecha de una mencion no es futura; no cambia de duda ni de alumno.
create or replace function public.cs_tg_duda_mencion_before()
returns trigger language plpgsql set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' and (new.duda_id is distinct from old.duda_id
                           or new.cliente_id is distinct from old.cliente_id
                           or new.programa_id is distinct from old.programa_id) then
    raise exception 'cs: una mencion no cambia de duda ni de alumno' using errcode = '22023';
  end if;
  if new.fecha > public.cs_hoy() then
    raise exception 'cs: la fecha de la mencion no puede ser futura (%)', new.fecha using errcode = 'check_violation';
  end if;
  return new;
end;
$fn$;
drop trigger if exists cs_duda_menciones_before on public.cs_duda_menciones;
create trigger cs_duda_menciones_before before insert or update on public.cs_duda_menciones
  for each row execute function public.cs_tg_duda_mencion_before();

do $$
declare
  t text;
begin
  foreach t in array array['cs_dudas', 'cs_duda_menciones'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('grant select, insert, update, delete on table public.%I to authenticated', t);
    execute format('drop policy if exists cs_select on public.%I', t);
    execute format('create policy cs_select on public.%I for select to authenticated
                      using (public.cs_puede_ver(programa_id))', t);
    execute format('drop policy if exists cs_insert on public.%I', t);
    execute format('create policy cs_insert on public.%I for insert to authenticated
                      with check (public.cs_puede_editar(programa_id))', t);
    execute format('drop policy if exists cs_update on public.%I', t);
    execute format('create policy cs_update on public.%I for update to authenticated
                      using (public.cs_puede_editar(programa_id))
                      with check (public.cs_puede_editar(programa_id))', t);
    execute format('drop policy if exists cs_delete on public.%I', t);
    execute format('create policy cs_delete on public.%I for delete to authenticated
                      using (public.cs_puede_borrar())', t);
  end loop;
end $$;

-- Ranking: alumnos DISTINTOS, nueva esta semana (primera mencion o alta en los ultimos 7 dias)
-- y racha de semanas seguidas (semanas ISO, lunes) hasta la semana actual o la anterior.
create or replace view public.cs_v_dudas
with (security_invoker = on) as
with m as (
  select x.duda_id, count(*) as menciones, count(distinct x.cliente_id) as alumnos,
         min(x.fecha) as primera, max(x.fecha) as ultima
  from public.cs_duda_menciones x
  group by x.duda_id
), sem as (
  select x.duda_id, (date_trunc('week', x.fecha::timestamp))::date as w
  from public.cs_duda_menciones x
  group by 1, 2
), isl as (
  select s.duda_id, s.w,
         s.w - ((row_number() over (partition by s.duda_id order by s.w))::int * 7) as g
  from sem s
), rach as (
  select i.duda_id, i.g, count(*) as n, max(i.w) as ult
  from isl i
  group by i.duda_id, i.g
), ult as (
  select distinct on (r.duda_id) r.duda_id, r.n, r.ult
  from rach r
  order by r.duda_id, r.ult desc
)
select d.id, d.programa_id, d.texto, d.respuesta, d.recurso_url, d.recurso_titulo, d.origen, d.created_at,
       coalesce(m.alumnos, 0)::int   as alumnos,
       coalesce(m.menciones, 0)::int as menciones,
       m.primera                     as primera_mencion,
       m.ultima                      as ultima_mencion,
       (coalesce(m.primera, (d.created_at at time zone 'America/Argentina/Buenos_Aires')::date)
          >= public.cs_hoy() - 6)    as nueva_semana,
       case when u.ult >= (date_trunc('week', public.cs_hoy()::timestamp))::date - 7
            then u.n::int else 0 end as racha_semanas
from public.cs_dudas d
left join m on m.duda_id = d.id
left join ult u on u.duda_id = d.id;

revoke all on table public.cs_v_dudas from anon;
revoke insert, update, delete on table public.cs_v_dudas from authenticated;
grant select on table public.cs_v_dudas to authenticated;

-- Una mencion: sobre una duda existente (p_duda) o creando una nueva por texto. SECURITY INVOKER:
-- la RLS pone el permiso (cs_puede_editar). Lo usan el front y cs_llamada_crear.
create or replace function public.cs_duda_mencion(
  p_programa text,
  p_duda     uuid,
  p_texto    text,
  p_cliente  uuid,
  p_fecha    date default null,
  p_origen   text default 'otro',
  p_llamada  uuid default null
)
returns uuid
language plpgsql
set search_path = public
as $fn$
declare
  v_duda   uuid := p_duda;
  v_norm   text;
  v_origen text := coalesce(nullif(btrim(p_origen), ''), 'otro');
begin
  if v_origen not in ('discord', 'llamada', 'whatsapp', 'otro') then
    raise exception 'cs: origen invalido (discord, llamada, whatsapp u otro)' using errcode = '22023';
  end if;
  if v_duda is null then
    v_norm := public.cs_norm_nombre(p_texto);
    if v_norm is null then
      raise exception 'cs: escribi la duda' using errcode = '22023';
    end if;
    select d.id into v_duda from public.cs_dudas d
     where d.programa_id = p_programa and d.texto_norm = v_norm;
    if v_duda is null then
      insert into public.cs_dudas (programa_id, texto, origen)
      values (p_programa, btrim(p_texto), v_origen)
      returning id into v_duda;
    end if;
  elsif not exists (select 1 from public.cs_dudas d where d.id = v_duda and d.programa_id = p_programa) then
    raise exception 'cs: la duda no existe en este programa' using errcode = '22023';
  end if;

  insert into public.cs_duda_menciones (programa_id, duda_id, cliente_id, fecha, origen, llamada_id)
  values (p_programa, v_duda, p_cliente, coalesce(p_fecha, public.cs_hoy()), v_origen, p_llamada)
  on conflict (duda_id, cliente_id, fecha) do nothing;
  return v_duda;
end;
$fn$;


-- =====================================================================
-- Resolver alumno por id o por nombre (tolerante a acentos, mayusculas y orden de las palabras)
-- =====================================================================
create or replace function public.cs_resolver_alumno(p_programa text, p_alumno text)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_q       text;
  v_n       int;
  v_id      uuid;
  v_nombres text;
begin
  if p_alumno is null or btrim(p_alumno) = '' then
    raise exception 'cs: falta el alumno' using errcode = '22023';
  end if;
  if btrim(p_alumno) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select c.id into v_id from public.cs_clientes c
     where c.id = btrim(p_alumno)::uuid and c.programa_id = p_programa;
    if v_id is null then
      raise exception 'cs: no hay un alumno con ese id en el programa %', p_programa using errcode = '22023';
    end if;
    return v_id;
  end if;

  v_q := public.cs_norm_nombre(p_alumno);
  if v_q is null then
    raise exception 'cs: falta el alumno' using errcode = '22023';
  end if;

  -- 1) nombre igual (normalizado)
  select count(*), (array_agg(c.id))[1] into v_n, v_id
  from public.cs_clientes c
  where c.programa_id = p_programa and public.cs_norm_nombre(c.nombre) = v_q;
  if v_n = 1 then return v_id; end if;

  -- 2) todas las palabras escritas estan en el nombre
  if v_n = 0 then
    select count(*), (array_agg(c.id))[1], string_agg(c.nombre, ' · ' order by c.nombre)
      into v_n, v_id, v_nombres
    from public.cs_clientes c
    where c.programa_id = p_programa
      and not exists (select 1 from unnest(string_to_array(v_q, ' ')) w
                      where public.cs_norm_nombre(c.nombre) not like '%' || w || '%');
    if v_n = 1 then return v_id; end if;
  else
    select string_agg(c.nombre, ' · ' order by c.nombre) into v_nombres
    from public.cs_clientes c
    where c.programa_id = p_programa and public.cs_norm_nombre(c.nombre) = v_q;
  end if;

  if v_n = 0 then
    raise exception 'cs: no se encontro ningun alumno que coincida con "%" en %', p_alumno, p_programa
      using errcode = 'P0002';
  end if;
  raise exception 'cs: "%" coincide con % alumnos (%). Escribi el nombre completo o pasa el id.',
    p_alumno, v_n, left(v_nombres, 300) using errcode = '23505';
end;
$fn$;

-- Buscador para la app: acentos y mayusculas no importan. security invoker: la RLS recorta.
create or replace function public.cs_alumno_buscar(p_programa text, p_q text)
returns table (id uuid, nombre text, estado text)
language sql
stable
set search_path = public
as $$
  select c.id, c.nombre, c.estado
  from public.cs_clientes c
  where c.programa_id = p_programa
    and public.cs_norm_nombre(p_q) is not null
    and not exists (select 1 from unnest(string_to_array(public.cs_norm_nombre(p_q), ' ')) w
                    where public.cs_norm_nombre(c.nombre) not like '%' || w || '%')
  order by (c.estado in ('onboarding', 'activo', 'en_renovacion')) desc, c.nombre
  limit 20
$$;


-- =====================================================================
-- C (cont.). CARGA DE LLAMADAS, ATOMICA
-- =====================================================================
-- cs_llamada_crear: SECURITY INVOKER. Una sola transaccion (una funcion lo es): llamada, accionables
-- (con subtareas), links, transcripcion y dudas. Si algo falla no queda nada. El permiso lo pone la RLS
-- (cs_puede_editar), asi que sirve para el front de cualquier CSM con edicion.
--   p_accionables: [{"texto": "...", "sub": true|false}]   (sub = subtarea del ultimo sin sub)
--   p_links:       [{"titulo": "...", "url": "https://...", "tipo": "doc|sheet|slides|drive|youtube|loom|otro"}]
--   p_dudas:       [{"duda_id": "<uuid>"} | {"texto": "..."}]   (menciones de ese alumno, origen llamada)
create or replace function public.cs_llamada_crear(
  p_cliente        uuid,
  p_fecha          date,
  p_titulo         text default null,
  p_resumen        text default null,
  p_en_que_esta    text default null,
  p_proximos_pasos text default null,
  p_accionables    jsonb default '[]'::jsonb,
  p_links          jsonb default '[]'::jsonb,
  p_transcripcion  text default null,
  p_dudas          jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
set search_path = public
as $fn$
declare
  v_prog   text;
  v_ll     uuid;
  v_fecha  date := coalesce(p_fecha, public.cs_hoy());
  v_item   jsonb;
  v_i      int := 0;
  v_ultimo uuid;
  v_id     uuid;
  v_txt    text;
  v_sub    boolean;
  v_url    text;
begin
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: no se encontro el alumno' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_accionables, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_links, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_dudas, '[]'::jsonb)) <> 'array' then
    raise exception 'cs: accionables, links y dudas tienen que ser listas' using errcode = '22023';
  end if;

  insert into public.cs_llamadas (programa_id, cliente_id, fecha, titulo, resumen, en_que_esta, proximos_pasos)
  values (v_prog, p_cliente, v_fecha, nullif(btrim(p_titulo), ''), nullif(btrim(p_resumen), ''),
          nullif(btrim(p_en_que_esta), ''), nullif(btrim(p_proximos_pasos), ''))
  returning id into v_ll;

  for v_item in select * from jsonb_array_elements(coalesce(p_accionables, '[]'::jsonb)) loop
    v_txt := nullif(btrim(case when jsonb_typeof(v_item) = 'string' then v_item #>> '{}' else v_item ->> 'texto' end), '');
    continue when v_txt is null;
    v_sub := coalesce(case when jsonb_typeof(v_item) = 'object' then (v_item ->> 'sub')::boolean end, false)
             and v_ultimo is not null;
    insert into public.cs_llamada_accionables (programa_id, cliente_id, llamada_id, padre_id, texto, orden)
    values (v_prog, p_cliente, v_ll, case when v_sub then v_ultimo end, left(v_txt, 500), v_i)
    returning id into v_id;
    if not v_sub then v_ultimo := v_id; end if;
    v_i := v_i + 1;
  end loop;

  for v_item in select * from jsonb_array_elements(coalesce(p_links, '[]'::jsonb)) loop
    v_url := btrim(case when jsonb_typeof(v_item) = 'string' then v_item #>> '{}' else v_item ->> 'url' end);
    continue when v_url is null or v_url = '';
    insert into public.cs_llamada_recursos (programa_id, cliente_id, llamada_id, titulo, url, tipo)
    values (v_prog, p_cliente, v_ll,
            left(coalesce(nullif(btrim(case when jsonb_typeof(v_item) = 'object' then v_item ->> 'titulo' end), ''), v_url), 200),
            v_url,
            case when jsonb_typeof(v_item) = 'object'
                      and (v_item ->> 'tipo') in ('doc', 'sheet', 'slides', 'drive', 'youtube', 'loom', 'otro')
                 then v_item ->> 'tipo' else 'otro' end);
  end loop;

  if nullif(btrim(p_transcripcion), '') is not null then
    insert into public.cs_llamada_transcripciones (llamada_id, programa_id, cliente_id, texto)
    values (v_ll, v_prog, p_cliente, p_transcripcion);
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_dudas, '[]'::jsonb)) loop
    perform public.cs_duda_mencion(
      v_prog,
      case when jsonb_typeof(v_item) = 'object' then nullif(v_item ->> 'duda_id', '')::uuid end,
      case when jsonb_typeof(v_item) = 'string' then v_item #>> '{}' else v_item ->> 'texto' end,
      p_cliente, v_fecha, 'llamada', v_ll);
  end loop;

  return v_ll;
end;
$fn$;

-- cs_llamada_cargar: la puerta de entrada para el jefe (fundador o service role / SQL Editor).
-- Resuelve al alumno por id o por nombre (acentos y mayusculas no importan) y llama a cs_llamada_crear.
create or replace function public.cs_llamada_cargar(
  p_programa       text,
  p_alumno         text,
  p_fecha          date,
  p_titulo         text default null,
  p_resumen        text default null,
  p_en_que_esta    text default null,
  p_proximos_pasos text default null,
  p_accionables    jsonb default '[]'::jsonb,
  p_links          jsonb default '[]'::jsonb,
  p_transcripcion  text default null,
  p_dudas          jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_cli    uuid;
  v_nombre text;
  v_ll     uuid;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede cargar llamadas por esta via' using errcode = '42501';
  end if;
  if not exists (select 1 from public.cs_programas p where p.id = p_programa) then
    raise exception 'cs: el programa % no existe', p_programa using errcode = '22023';
  end if;
  v_cli := public.cs_resolver_alumno(p_programa, p_alumno);
  v_ll := public.cs_llamada_crear(v_cli, p_fecha, p_titulo, p_resumen, p_en_que_esta, p_proximos_pasos,
                                  p_accionables, p_links, p_transcripcion, p_dudas);
  select c.nombre into v_nombre from public.cs_clientes c where c.id = v_cli;
  return jsonb_build_object('llamada_id', v_ll, 'cliente_id', v_cli, 'alumno', v_nombre);
end;
$fn$;

-- cs_duda_registrar: menciones en tanda para el jefe (fundador o service role).
--   p_items: [{"duda": "texto" | "duda_id": "<uuid>", "alumno": "nombre o id", "fecha": "AAAA-MM-DD", "origen": "discord"}]
-- Cada item va en su propio bloque: uno que falla no frena a los demas. Devuelve conteos y errores por item.
create or replace function public.cs_duda_registrar(p_programa text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_item   jsonb;
  v_i      int := 0;
  v_cli    uuid;
  v_ok     int := 0;
  v_err    jsonb := '[]'::jsonb;
  v_antes  int;
  v_despues int;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede registrar dudas en tanda' using errcode = '42501';
  end if;
  if not exists (select 1 from public.cs_programas p where p.id = p_programa) then
    raise exception 'cs: el programa % no existe', p_programa using errcode = '22023';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'cs: p_items tiene que ser una lista' using errcode = '22023';
  end if;

  select count(*) into v_antes from public.cs_dudas where programa_id = p_programa;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_i := v_i + 1;
    begin
      v_cli := public.cs_resolver_alumno(p_programa, v_item ->> 'alumno');
      perform public.cs_duda_mencion(
        p_programa, nullif(v_item ->> 'duda_id', '')::uuid, v_item ->> 'duda', v_cli,
        nullif(v_item ->> 'fecha', '')::date, coalesce(nullif(v_item ->> 'origen', ''), 'otro'), null);
      v_ok := v_ok + 1;
    exception when others then
      v_err := v_err || jsonb_build_object('item', v_i, 'motivo', sqlerrm);
    end;
  end loop;
  select count(*) into v_despues from public.cs_dudas where programa_id = p_programa;

  return jsonb_build_object('menciones_ok', v_ok, 'dudas_nuevas', v_despues - v_antes, 'errores', v_err);
end;
$fn$;

-- cs_duda_unir: une dos dudas duplicadas (solo fundador, o service role). Las menciones del origen pasan
-- al destino (si el alumno ya la habia mencionado ese dia, no se duplica) y el origen se borra.
create or replace function public.cs_duda_unir(p_origen uuid, p_destino uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  o public.cs_dudas;
  d public.cs_dudas;
  v_movidas int;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede unir dudas' using errcode = '42501';
  end if;
  if p_origen = p_destino then
    raise exception 'cs: elegi dos dudas distintas' using errcode = '22023';
  end if;
  select * into o from public.cs_dudas where id = p_origen for update;
  select * into d from public.cs_dudas where id = p_destino for update;
  if o.id is null or d.id is null or o.programa_id <> d.programa_id then
    raise exception 'cs: las dudas no existen o son de programas distintos' using errcode = '22023';
  end if;

  insert into public.cs_duda_menciones (programa_id, duda_id, cliente_id, fecha, origen, llamada_id, created_at, created_by)
  select m.programa_id, p_destino, m.cliente_id, m.fecha, m.origen, m.llamada_id, m.created_at, m.created_by
  from public.cs_duda_menciones m where m.duda_id = p_origen
  on conflict (duda_id, cliente_id, fecha) do nothing;
  get diagnostics v_movidas = row_count;

  update public.cs_dudas
     set respuesta      = coalesce(d.respuesta, o.respuesta),
         recurso_url    = coalesce(d.recurso_url, o.recurso_url),
         recurso_titulo = coalesce(d.recurso_titulo, o.recurso_titulo)
   where id = p_destino;
  delete from public.cs_dudas where id = p_origen;   -- las menciones restantes se van en cascada
  return jsonb_build_object('destino', p_destino, 'menciones_movidas', v_movidas);
end;
$fn$;


-- =====================================================================
-- D. WINS y UPSELL
-- =====================================================================
create table if not exists public.cs_wins (
  id              uuid primary key default gen_random_uuid(),
  programa_id     text not null references public.cs_programas(id),
  cliente_id      uuid not null,
  fecha           date not null default public.cs_hoy(),
  texto           text not null check (btrim(texto) <> '' and char_length(texto) <= 300),
  tipo            text not null default 'otro'
                  check (tipo in ('resultado_economico', 'hito', 'testimonio', 'otro')),
  monto           numeric(14, 2) check (monto is null or monto >= 0),
  -- el pendiente "Pedir referido a <alumno>": nace pendiente, aparece en Hoy hasta pedido o descartado
  referido_estado text not null default 'pendiente' check (referido_estado in ('pendiente', 'pedido', 'descartado')),
  referido_at     timestamptz,
  referido_por    uuid,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  updated_at      timestamptz not null default now(),
  constraint cs_wins_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_wins_cliente_idx on public.cs_wins (cliente_id, fecha desc);
create index if not exists cs_wins_programa_idx on public.cs_wins (programa_id, referido_estado, fecha desc);
comment on table public.cs_wins is
  'Wins del alumno (106). Cada alta avisa al canal de wins de Discord y deja el pendiente "Pedir referido" (referido_estado). El monto no sale a Discord salvo cs_discord_canales.incluir_monto.';

drop trigger if exists cs_wins_updated_at on public.cs_wins;
create trigger cs_wins_updated_at before update on public.cs_wins
  for each row execute function public.cs_tg_updated_at();

create or replace function public.cs_tg_wins_before()
returns trigger language plpgsql security definer set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' and (new.cliente_id is distinct from old.cliente_id
                           or new.programa_id is distinct from old.programa_id) then
    raise exception 'cs: un win no cambia de alumno' using errcode = '22023';
  end if;
  if new.fecha > public.cs_hoy() and (tg_op = 'INSERT' or new.fecha is distinct from old.fecha) then
    raise exception 'cs: la fecha del win no puede ser futura (%)', new.fecha using errcode = 'check_violation';
  end if;
  -- quien resolvio el pendiente y cuando: lo pone la base
  if tg_op = 'INSERT' then
    new.referido_estado := 'pendiente';
    new.referido_at := null;
    new.referido_por := null;
  elsif new.referido_estado is distinct from old.referido_estado then
    if new.referido_estado = 'pendiente' then
      new.referido_at := null;
      new.referido_por := null;
    else
      new.referido_at := now();
      new.referido_por := auth.uid();
    end if;
  else
    new.referido_at := old.referido_at;
    new.referido_por := old.referido_por;
  end if;
  return new;
end;
$fn$;
drop trigger if exists cs_wins_before on public.cs_wins;
create trigger cs_wins_before before insert or update on public.cs_wins
  for each row execute function public.cs_tg_wins_before();

-- Aviso a Discord al cargar un win. Nunca rompe el alta.
create or replace function public.cs_tg_wins_aviso()
returns trigger language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog   text;
  v_nombre text;
  v_monto  boolean;
  v_txt    text;
begin
  begin
    select coalesce(p.marca, p.nombre) into v_prog from public.cs_programas p where p.id = new.programa_id;
    select c.nombre into v_nombre from public.cs_clientes c where c.id = new.cliente_id;
    select coalesce(k.incluir_monto, false) into v_monto
      from public.cs_discord_canales k where k.programa_id = new.programa_id and k.tipo = 'wins';
    v_txt := '🏆 Nuevo win · ' || coalesce(v_prog, new.programa_id) || E'\n'
          || 'Alumno: ' || public.cs_discord_nombre(new.programa_id, 'wins', v_nombre) || E'\n'
          || left(new.texto, 300)
          || case when coalesce(v_monto, false) and new.monto is not null
                  then E'\nMonto: ' || new.monto::text else '' end
          || E'\nPedir referido desde Hoy.';
    perform public.cs_discord_canal_post(new.programa_id, 'wins', v_txt);
  exception when others then
    null;
  end;
  return new;
end;
$fn$;
drop trigger if exists cs_wins_aviso on public.cs_wins;
create trigger cs_wins_aviso after insert on public.cs_wins
  for each row execute function public.cs_tg_wins_aviso();

-- Marca manual de "listo para upsell": una fila por alumno. Desmarcar = activo false (borrar es del fundador).
-- La SUGERENCIA automatica no se guarda: la calcula la app con la regla visible en js/config.js.
create table if not exists public.cs_upsell_marcas (
  cliente_id   uuid primary key,
  programa_id  text not null references public.cs_programas(id),
  activo       boolean not null default true,
  motivo       text not null check (btrim(motivo) <> '' and char_length(motivo) <= 300),
  marcado_at   timestamptz not null default now(),
  marcado_por  uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  constraint cs_upsell_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_upsell_programa_idx on public.cs_upsell_marcas (programa_id, activo);
comment on table public.cs_upsell_marcas is
  'Alumnos marcados a mano como listos para upsell (106), con motivo y fecha. Se relaciona con el pipeline de Resell (cs_renovaciones): la marca es el paso previo; al abrirse el pipeline la app lo muestra como "En resell".';

drop trigger if exists cs_upsell_updated_at on public.cs_upsell_marcas;
create trigger cs_upsell_updated_at before update on public.cs_upsell_marcas
  for each row execute function public.cs_tg_updated_at();

create or replace function public.cs_tg_upsell_before()
returns trigger language plpgsql set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' and new.programa_id is distinct from old.programa_id then
    raise exception 'cs: la marca no cambia de programa' using errcode = '22023';
  end if;
  if tg_op = 'INSERT' or (new.activo and not old.activo) then
    new.marcado_at := now();
    new.marcado_por := auth.uid();
  end if;
  return new;
end;
$fn$;
drop trigger if exists cs_upsell_before on public.cs_upsell_marcas;
create trigger cs_upsell_before before insert or update on public.cs_upsell_marcas
  for each row execute function public.cs_tg_upsell_before();

do $$
declare
  t text;
begin
  foreach t in array array['cs_wins', 'cs_upsell_marcas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('grant select, insert, update, delete on table public.%I to authenticated', t);
    execute format('drop policy if exists cs_select on public.%I', t);
    execute format('create policy cs_select on public.%I for select to authenticated
                      using (public.cs_puede_ver(programa_id))', t);
    execute format('drop policy if exists cs_insert on public.%I', t);
    execute format('create policy cs_insert on public.%I for insert to authenticated
                      with check (public.cs_puede_editar(programa_id))', t);
    execute format('drop policy if exists cs_update on public.%I', t);
    execute format('create policy cs_update on public.%I for update to authenticated
                      using (public.cs_puede_editar(programa_id))
                      with check (public.cs_puede_editar(programa_id))', t);
    execute format('drop policy if exists cs_delete on public.%I', t);
    execute format('create policy cs_delete on public.%I for delete to authenticated
                      using (public.cs_puede_borrar())', t);
  end loop;
end $$;


-- =====================================================================
-- F. cs_v_alumno_resumen: lo que leen Clientes, Maestro y la ficha
-- =====================================================================
-- Una fila por alumno. "En que esta" y "Proximos pasos" salen de la ULTIMA llamada que los tiene.
-- Ultimo puntaje = la ultima respuesta de satisfaccion por etapa. wins_30d = wins de los ultimos 30 dias.
create or replace view public.cs_v_alumno_resumen
with (security_invoker = on) as
select c.id          as cliente_id,
       c.programa_id,
       l.llamada_id  as estado_llamada_id,
       l.fecha       as estado_fecha,
       l.en_que_esta,
       l.proximos_pasos,
       s.puntaje     as sat_puntaje,
       s.momento_nombre as sat_momento,
       s.respondido_at  as sat_at,
       coalesce(w.n, 0)::int as wins_30d,
       w.ultimo      as ultimo_win,
       coalesce(w.referidos_pendientes, 0)::int as referidos_pendientes,
       (u.cliente_id is not null) as upsell_marcado,
       u.motivo      as upsell_motivo,
       u.marcado_at  as upsell_at
from public.cs_clientes c
left join lateral (
  select ll.id as llamada_id, ll.fecha, ll.en_que_esta, ll.proximos_pasos
  from public.cs_llamadas ll
  where ll.cliente_id = c.id
    and (nullif(btrim(coalesce(ll.en_que_esta, '')), '') is not null
         or nullif(btrim(coalesce(ll.proximos_pasos, '')), '') is not null)
  order by ll.fecha desc, ll.created_at desc
  limit 1
) l on true
left join lateral (
  select e.puntaje, e.momento_nombre, e.respondido_at
  from public.cs_satisf_envios e
  where e.cliente_id = c.id and e.respondido_at is not null
  order by e.respondido_at desc
  limit 1
) s on true
left join lateral (
  select count(*) filter (where x.fecha >= public.cs_hoy() - 30) as n,
         max(x.fecha) as ultimo,
         count(*) filter (where x.referido_estado = 'pendiente') as referidos_pendientes
  from public.cs_wins x
  where x.cliente_id = c.id
) w on true
left join public.cs_upsell_marcas u on u.cliente_id = c.id and u.activo;

revoke all on table public.cs_v_alumno_resumen from anon;
revoke insert, update, delete on table public.cs_v_alumno_resumen from authenticated;
grant select on table public.cs_v_alumno_resumen to authenticated;


-- =====================================================================
-- G. MAESTRO: claves nuevas del sistema
-- =====================================================================
create table if not exists public.cs_bak_106_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_106_funciones from public, anon, authenticated;

insert into public.cs_bak_106_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.proname = 'cs_maestro_claves_sistema'
on conflict (funcion) do nothing;

-- Misma lista que la 102 (23 claves) y 4 al final. Las filas guardadas en cs_maestro_columnas
-- siguen cumpliendo el CHECK (la lista solo crece).
create or replace function public.cs_maestro_claves_sistema()
returns text[]
language sql immutable parallel safe set search_path = public
as $$
  select array[
    'nombre', 'prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha',
    'nota_csm', 'testimonio', 'renovacion_estado', 'renovacion_producto',
    'aviso_1_at', 'aviso_2_at', 'estado', 'producto', 'etapa', 'dias_restantes',
    'acc', 'dev_pendientes', 'ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
    'proximo_contacto', 'renovaciones_count', 'onb_avance', 'ultima_llamada',
    'en_que_esta', 'proximos_pasos', 'satisfaccion_ultima', 'upsell'
  ]::text[]
$$;
revoke all on function public.cs_maestro_claves_sistema() from public, anon;
grant execute on function public.cs_maestro_claves_sistema() to authenticated;


-- =====================================================================
-- PERMISOS DE LAS FUNCIONES
-- =====================================================================
-- Solo estas dos le sirven a anon (la pagina publica). Todo lo demas: authenticated, y las de uso
-- interno ni eso. service_role y el SQL Editor (owner) las ejecutan siempre.
revoke all on function public.cs_tg_wins_before() from public, anon, authenticated;
revoke all on function public.cs_tg_wins_aviso() from public, anon, authenticated;
revoke all on function public.cs_tg_upsell_before() from public, anon, authenticated;
revoke all on function public.cs_tg_duda_mencion_before() from public, anon, authenticated;
revoke all on function public.cs_discord_canal_post(text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.cs_discord_nombre(text, text, text) from public, anon, authenticated;
revoke all on function public.cs_resolver_alumno(text, text) from public, anon, authenticated;

revoke all on function public.cs_probar_discord_canal(text, text) from public, anon;
revoke all on function public.cs_satisf_pendientes(text) from public, anon;
revoke all on function public.cs_satisf_link(uuid, uuid) from public, anon;
revoke all on function public.cs_satisf_marcar_enviado(uuid) from public, anon;
revoke all on function public.cs_duda_mencion(text, uuid, text, uuid, date, text, uuid) from public, anon;
revoke all on function public.cs_alumno_buscar(text, text) from public, anon;
revoke all on function public.cs_llamada_crear(uuid, date, text, text, text, text, jsonb, jsonb, text, jsonb) from public, anon;
revoke all on function public.cs_llamada_cargar(text, text, date, text, text, text, text, jsonb, jsonb, text, jsonb) from public, anon;
revoke all on function public.cs_duda_registrar(text, jsonb) from public, anon;
revoke all on function public.cs_duda_unir(uuid, uuid) from public, anon;
revoke all on function public.cs_satisf_estado(text) from public;
revoke all on function public.cs_satisf_responder(text, int, text, text, boolean) from public;

grant execute on function public.cs_probar_discord_canal(text, text) to authenticated;
grant execute on function public.cs_satisf_pendientes(text) to authenticated;
grant execute on function public.cs_satisf_link(uuid, uuid) to authenticated;
grant execute on function public.cs_satisf_marcar_enviado(uuid) to authenticated;
grant execute on function public.cs_duda_mencion(text, uuid, text, uuid, date, text, uuid) to authenticated;
grant execute on function public.cs_alumno_buscar(text, text) to authenticated;
grant execute on function public.cs_llamada_crear(uuid, date, text, text, text, text, jsonb, jsonb, text, jsonb) to authenticated;
grant execute on function public.cs_llamada_cargar(text, text, date, text, text, text, text, jsonb, jsonb, text, jsonb) to authenticated;
grant execute on function public.cs_duda_registrar(text, jsonb) to authenticated;
grant execute on function public.cs_duda_unir(uuid, uuid) to authenticated;
grant execute on function public.cs_satisf_estado(text) to anon, authenticated;
grant execute on function public.cs_satisf_responder(text, int, text, text, boolean) to anon, authenticated;

commit;


-- =====================================================================
-- CONTROLES (correr de a uno, despues de la migracion)
-- =====================================================================
-- C1. Tablas, RLS y politicas. Esperado: 12 filas, rls = true.
--     politicas: cs_discord_canales 1, cs_discord_avisos 1, cs_satisf_momentos 4, cs_satisf_envios 2,
--     cs_llamada_transcripciones 4, cs_dudas 4, cs_duda_menciones 4, cs_wins 4, cs_upsell_marcas 4.
-- select c.relname, c.relrowsecurity as rls,
--        (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as politicas
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
--   and c.relname in ('cs_discord_canales', 'cs_discord_avisos', 'cs_satisf_momentos', 'cs_satisf_envios',
--                     'cs_llamada_transcripciones', 'cs_dudas', 'cs_duda_menciones', 'cs_wins', 'cs_upsell_marcas')
-- order by 1;
--
-- C2. anon: solo puede ejecutar las 2 funciones publicas y no tiene nada sobre tablas ni vistas.
--     Esperado: 0 filas en la primera; en la segunda, exactamente cs_satisf_estado y cs_satisf_responder.
-- select table_name, privilege_type from information_schema.role_table_grants
-- where table_schema = 'public' and grantee = 'anon'
--   and table_name in ('cs_discord_canales', 'cs_discord_avisos', 'cs_satisf_momentos', 'cs_satisf_envios',
--                      'cs_llamada_transcripciones', 'cs_dudas', 'cs_duda_menciones', 'cs_wins',
--                      'cs_upsell_marcas', 'cs_v_dudas', 'cs_v_alumno_resumen');
-- select p.proname from pg_proc p
-- where p.pronamespace = 'public'::regnamespace
--   and p.proname in ('cs_satisf_estado', 'cs_satisf_responder', 'cs_satisf_link', 'cs_satisf_pendientes',
--                     'cs_llamada_crear', 'cs_llamada_cargar', 'cs_duda_registrar', 'cs_duda_unir',
--                     'cs_duda_mencion', 'cs_discord_canal_post', 'cs_resolver_alumno')
--   and has_function_privilege('anon', p.oid, 'execute')
-- order by 1;
--
-- C3. El token no se puede leer (permiso por columna). Esperado: false, y las demas true.
-- select has_column_privilege('authenticated', 'public.cs_satisf_envios', 'token', 'select') as token_legible,
--        has_column_privilege('authenticated', 'public.cs_satisf_envios', 'puntaje', 'select') as puntaje_legible;
--
-- C4. Las vistas responden y son security_invoker. Esperado: opts = {security_invoker=on} en las dos.
-- select c.relname, c.reloptions as opts
-- from pg_class c where c.oid in ('public.cs_v_dudas'::regclass, 'public.cs_v_alumno_resumen'::regclass);
-- select count(*) as filas_resumen from public.cs_v_alumno_resumen;
--
-- C5. Claves del Maestro. Esperado: true, 27.
-- select 'upsell' = any (public.cs_maestro_claves_sistema()) as ok,
--        cardinality(public.cs_maestro_claves_sistema()) as claves;
--
-- C6. Datos existentes intactos (comparar con antes de correr).
-- select (select count(*) from public.cs_clientes) as clientes,
--        (select count(*) from public.cs_llamadas) as llamadas,
--        (select count(*) from public.cs_respuestas) as respuestas,
--        (select count(*) from public.cs_maestro_columnas) as columnas_maestro;
--
-- C7. Quien llegaria a un momento hoy (informativo; no crea nada). Reemplazar el programa.
--     Antes de definir momentos devuelve 0 filas: es lo esperado.
-- select * from public.cs_satisf_pendientes('liam') limit 20;
--
-- C8. PRUEBA DE HUMO (se revierte sola: termina en error "HUMO OK"). Necesita un fundador y dos
--     usuarios no fundadores en auth.users. Crea y borra un programa de prueba. No manda nada a Discord
--     (no carga ningun webhook).
-- do $humo$
-- declare
--   v_prog text := 'humo106'; v_fund uuid; v_edit uuid; v_lect uuid;
--   v_c1 uuid; v_c2 uuid; v_mom uuid; v_j jsonb; v_tok text; v_env uuid; v_n int; v_ok int := 0;
--   v_ll uuid; v_win uuid; v_d1 uuid; v_d2 uuid; v_txt text;
-- begin
--   select user_id into v_fund from public.crm_members where rol = 'fundador' limit 1;
--   select u.id into v_edit from auth.users u where u.id <> v_fund
--     and not exists (select 1 from public.crm_members m where m.user_id = u.id and m.rol = 'fundador')
--     order by u.created_at limit 1;
--   select u.id into v_lect from auth.users u where u.id not in (v_fund, v_edit)
--     and not exists (select 1 from public.crm_members m where m.user_id = u.id and m.rol = 'fundador')
--     order by u.created_at limit 1;
--   if v_fund is null or v_edit is null or v_lect is null then
--     raise exception 'faltan usuarios para probar';
--   end if;
--   perform set_config('request.jwt.claim.sub', v_fund::text, true);
--   set local role authenticated;
--   insert into public.cs_programas (id, nombre, activo) values (v_prog, '__humo106__', true);
--   reset role;
--   insert into public.cs_accesos (user_id, programa_id, nivel) values (v_edit, v_prog, 'edicion'), (v_lect, v_prog, 'lectura');
--   insert into public.cs_clientes (programa_id, nombre, estado, fecha_inicio) values (v_prog, 'Humo Cientoseis Uno', 'activo', public.cs_hoy())
--     returning id into v_c1;
--   insert into public.cs_clientes (programa_id, nombre, estado, fecha_inicio) values (v_prog, 'Humo Cientoseis Dos', 'activo', public.cs_hoy())
--     returning id into v_c2;
--
--   -- edicion: define el momento (dias_desde_inicio = 0 llega hoy) y ve a los dos pendientes
--   perform set_config('request.jwt.claim.sub', v_edit::text, true);
--   set local role authenticated;
--   insert into public.cs_satisf_momentos (programa_id, nombre, tipo, valor, desde)
--     values (v_prog, 'Primera semana', 'dias_desde_inicio', 0, public.cs_hoy() - 1) returning id into v_mom;
--   select count(*) into v_n from public.cs_satisf_pendientes(v_prog);
--   if v_n <> 2 then raise exception 'HUMO FALLA: pendientes % (esperado 2)', v_n; end if;
--   v_ok := v_ok + 1;
--   v_j := public.cs_satisf_link(v_c1, v_mom);
--   v_tok := v_j ->> 'token'; v_env := (v_j ->> 'envio_id')::uuid;
--   select count(*) into v_n from public.cs_satisf_pendientes(v_prog);
--   if v_n <> 2 then raise exception 'HUMO FALLA: con link sin enviar siguen pendientes (%)', v_n; end if;
--   perform public.cs_satisf_marcar_enviado(v_env);
--   select count(*) into v_n from public.cs_satisf_pendientes(v_prog);
--   if v_n <> 1 then raise exception 'HUMO FALLA: tras enviar deberia quedar 1 (%)', v_n; end if;
--   v_ok := v_ok + 1;
--   -- el token no se lee ni con select directo
--   begin
--     execute 'select token from public.cs_satisf_envios limit 1';
--     raise exception 'HUMO FALLA: edicion leyo el token';
--   exception when insufficient_privilege then v_ok := v_ok + 1; end;
--
--   -- anon: ve el estado del link, responde UNA vez y no lee tablas
--   reset role;
--   set local role anon;
--   v_j := public.cs_satisf_estado(v_tok);
--   if (v_j ->> 'valido') <> 'true' or (v_j ->> 'respondido') <> 'false' then raise exception 'HUMO FALLA: estado del link'; end if;
--   perform public.cs_satisf_responder(v_tok, 5, 'Todo', 'Mas llamadas', false);
--   begin
--     perform public.cs_satisf_responder(v_tok, 9, null, null, true);
--     raise exception 'HUMO FALLA: dejo responder dos veces';
--   exception when sqlstate 'P0001' then v_ok := v_ok + 1; end;
--   begin
--     execute 'select 1 from public.cs_satisf_envios limit 1';
--     raise exception 'HUMO FALLA: anon leyo la tabla';
--   exception when insufficient_privilege then v_ok := v_ok + 1; end;
--   if (public.cs_satisf_estado(repeat('0', 64)) ->> 'valido') <> 'false' then raise exception 'HUMO FALLA: token inexistente'; end if;
--   reset role;
--   select count(*) into v_n from public.cs_satisf_envios where id = v_env and puntaje = 5 and respondido_at is not null;
--   if v_n <> 1 then raise exception 'HUMO FALLA: no quedo la respuesta'; end if;
--   v_ok := v_ok + 1;
--
--   -- edicion: win (queda con pendiente de referido y sin Discord), upsell y llamada atomica
--   perform set_config('request.jwt.claim.sub', v_edit::text, true);
--   set local role authenticated;
--   insert into public.cs_wins (programa_id, cliente_id, texto, tipo) values (v_prog, v_c1, 'Primera venta', 'hito') returning id into v_win;
--   select count(*) into v_n from public.cs_v_alumno_resumen where cliente_id = v_c1 and wins_30d = 1 and referidos_pendientes = 1 and sat_puntaje = 5;
--   if v_n <> 1 then raise exception 'HUMO FALLA: resumen del alumno (win o puntaje)'; end if;
--   update public.cs_wins set referido_estado = 'pedido' where id = v_win;
--   select count(*) into v_n from public.cs_wins where id = v_win and referido_at is not null and referido_por = v_edit;
--   if v_n <> 1 then raise exception 'HUMO FALLA: quien pidio el referido'; end if;
--   insert into public.cs_upsell_marcas (cliente_id, programa_id, motivo) values (v_c1, v_prog, 'Cerro su primera venta');
--   v_ok := v_ok + 1;
--   v_ll := public.cs_llamada_crear(v_c1, public.cs_hoy(), 'Llamada humo', 'Resumen', 'Armando el embudo', 'Subir 3 reels',
--     '[{"texto":"Tarea A"},{"texto":"Sub A1","sub":true},{"texto":"Tarea B"}]'::jsonb,
--     '[{"titulo":"Doc","url":"https://docs.google.com/document/d/x","tipo":"doc"}]'::jsonb,
--     'Transcripcion larga de prueba', '[{"texto":"Como subo un reel?"}]'::jsonb);
--   select count(*) into v_n from public.cs_llamada_accionables where llamada_id = v_ll;
--   if v_n <> 3 then raise exception 'HUMO FALLA: accionables % (esperado 3)', v_n; end if;
--   select count(*) into v_n from public.cs_llamada_accionables where llamada_id = v_ll and padre_id is not null;
--   if v_n <> 1 then raise exception 'HUMO FALLA: subtarea'; end if;
--   select count(*) into v_n from public.cs_v_alumno_resumen where cliente_id = v_c1 and en_que_esta = 'Armando el embudo' and upsell_marcado;
--   if v_n <> 1 then raise exception 'HUMO FALLA: en que esta / upsell en el resumen'; end if;
--   v_ok := v_ok + 1;
--   -- atomica: una llamada con un link invalido no deja nada
--   begin
--     perform public.cs_llamada_crear(v_c1, public.cs_hoy(), 'No debe quedar', null, null, null,
--       '[{"texto":"X"}]'::jsonb, '[{"titulo":"Mal","url":"ftp://no"}]'::jsonb, null, '[]'::jsonb);
--     raise exception 'HUMO FALLA: dejo un link invalido';
--   exception when check_violation then null; end;
--   select count(*) into v_n from public.cs_llamadas where cliente_id = v_c1 and titulo = 'No debe quedar';
--   if v_n <> 0 then raise exception 'HUMO FALLA: la llamada fallida dejo filas'; end if;
--   v_ok := v_ok + 1;
--   -- cs_llamada_cargar no es del CSM
--   begin
--     perform public.cs_llamada_cargar(v_prog, 'Humo Cientoseis Dos', public.cs_hoy());
--     raise exception 'HUMO FALLA: edicion uso cs_llamada_cargar';
--   exception when insufficient_privilege then v_ok := v_ok + 1; end;
--
--   -- lectura: ve el resumen pero no la transcripcion, y no escribe
--   reset role;
--   perform set_config('request.jwt.claim.sub', v_lect::text, true);
--   set local role authenticated;
--   select count(*) into v_n from public.cs_llamada_transcripciones where cliente_id = v_c1;
--   if v_n <> 0 then raise exception 'HUMO FALLA: lectura vio la transcripcion'; end if;
--   select count(*) into v_n from public.cs_v_alumno_resumen where cliente_id = v_c1 and en_que_esta is not null;
--   if v_n <> 1 then raise exception 'HUMO FALLA: lectura no ve el resumen'; end if;
--   begin
--     insert into public.cs_wins (programa_id, cliente_id, texto) values (v_prog, v_c1, 'No debe');
--     raise exception 'HUMO FALLA: lectura pudo crear un win';
--   exception when insufficient_privilege then v_ok := v_ok + 1; end;
--
--   -- fundador: carga por nombre, dudas en tanda, union y borrado en cascada
--   reset role;
--   perform set_config('request.jwt.claim.sub', v_fund::text, true);
--   set local role authenticated;
--   v_j := public.cs_llamada_cargar(v_prog, 'humo CIENTOSEIS dos', public.cs_hoy(), 'Cargada', 'Resumen', 'En X', 'Y',
--     '[{"texto":"Uno"}]'::jsonb, '[]'::jsonb, 'Texto', '[]'::jsonb);
--   if (v_j ->> 'cliente_id')::uuid <> v_c2 then raise exception 'HUMO FALLA: cs_llamada_cargar por nombre'; end if;
--   v_ok := v_ok + 1;
--   v_j := public.cs_duda_registrar(v_prog, jsonb_build_array(
--     jsonb_build_object('duda', 'Como subo un reel?', 'alumno', 'humo cientoseis dos', 'origen', 'discord'),
--     jsonb_build_object('duda', '¿Cómo subo un reel', 'alumno', 'Humo Cientoseis Uno', 'origen', 'whatsapp'),
--     jsonb_build_object('duda', 'Otra duda', 'alumno', 'Nadie Existe')));
--   if (v_j ->> 'menciones_ok')::int <> 2 or jsonb_array_length(v_j -> 'errores') <> 1 then
--     raise exception 'HUMO FALLA: duda_registrar %', v_j;
--   end if;
--   select count(*) into v_n from public.cs_v_dudas where programa_id = v_prog and alumnos = 2 and nueva_semana;
--   if v_n <> 1 then raise exception 'HUMO FALLA: ranking de dudas'; end if;
--   v_ok := v_ok + 1;
--   v_d1 := public.cs_duda_mencion(v_prog, null, 'Duda duplicada', v_c1, public.cs_hoy(), 'otro', null);
--   select d.id into v_d2 from public.cs_dudas d where d.programa_id = v_prog and d.texto_norm = public.cs_norm_nombre('Como subo un reel');
--   perform public.cs_duda_unir(v_d1, v_d2);
--   select count(*) into v_n from public.cs_dudas where programa_id = v_prog and id = v_d1;
--   if v_n <> 0 then raise exception 'HUMO FALLA: union'; end if;
--   v_ok := v_ok + 1;
--   delete from public.cs_llamadas where id = v_ll;
--   reset role;
--   select count(*) into v_n from public.cs_llamada_transcripciones where llamada_id = v_ll;
--   if v_n <> 0 then raise exception 'HUMO FALLA: cascada de la transcripcion'; end if;
--   v_ok := v_ok + 1;
--   raise exception 'HUMO OK: % comprobaciones (se revierte)', v_ok;
-- end
-- $humo$;
--
-- =====================================================================
-- VUELTA ATRAS (solo si hace falta; borra TODO lo cargado en las tablas nuevas)
-- =====================================================================
-- begin;
-- drop view if exists public.cs_v_alumno_resumen;
-- drop view if exists public.cs_v_dudas;
-- drop function if exists public.cs_duda_unir(uuid, uuid);
-- drop function if exists public.cs_duda_registrar(text, jsonb);
-- drop function if exists public.cs_llamada_cargar(text, text, date, text, text, text, text, jsonb, jsonb, text, jsonb);
-- drop function if exists public.cs_llamada_crear(uuid, date, text, text, text, text, jsonb, jsonb, text, jsonb);
-- drop function if exists public.cs_duda_mencion(text, uuid, text, uuid, date, text, uuid);
-- drop function if exists public.cs_alumno_buscar(text, text);
-- drop function if exists public.cs_resolver_alumno(text, text);
-- drop function if exists public.cs_satisf_responder(text, int, text, text, boolean);
-- drop function if exists public.cs_satisf_estado(text);
-- drop function if exists public.cs_satisf_marcar_enviado(uuid);
-- drop function if exists public.cs_satisf_link(uuid, uuid);
-- drop function if exists public.cs_satisf_pendientes(text);
-- drop table if exists public.cs_upsell_marcas;
-- drop table if exists public.cs_wins;
-- drop table if exists public.cs_duda_menciones;
-- drop table if exists public.cs_dudas;
-- drop table if exists public.cs_llamada_transcripciones;
-- drop table if exists public.cs_satisf_envios;
-- drop table if exists public.cs_satisf_momentos;
-- alter table public.cs_llamadas drop column if exists resumen, drop column if exists en_que_esta, drop column if exists proximos_pasos;
-- drop function if exists public.cs_probar_discord_canal(text, text);
-- drop function if exists public.cs_discord_canal_post(text, text, text, boolean);
-- drop function if exists public.cs_discord_nombre(text, text, text);
-- drop table if exists public.cs_discord_avisos;
-- drop table if exists public.cs_discord_canales;
-- drop function if exists public.cs_tg_wins_aviso();
-- drop function if exists public.cs_tg_wins_before();
-- drop function if exists public.cs_tg_upsell_before();
-- drop function if exists public.cs_tg_duda_mencion_before();
-- -- Las claves nuevas no se pueden sacar de la lista si algun programa ya guardo config de esas columnas:
-- -- primero  delete from public.cs_maestro_columnas where sistema and clave in ('en_que_esta','proximos_pasos','satisfaccion_ultima','upsell');
-- do $$ declare d text; begin
--   select definicion into d from public.cs_bak_106_funciones where funcion like 'cs_maestro_claves_sistema%';
--   if d is not null then execute d; end if;
-- end $$;
-- commit;
-- (La tabla cs_bak_106_funciones se puede borrar a mano cuando ya no haga falta.)
