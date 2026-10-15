-- =====================================================================
-- 122-producto-fathom-sync.sql  ·  PRODUCTO: llamadas de Fathom entran solas (empieza por teo)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), primero en el banco de pruebas.
-- Numeracion global asignada por el jefe: 122.
-- Requiere la 102 (cs_llamadas, accionables por llamada) y la 106 (resumen, en_que_esta,
-- proximos_pasos y cs_llamada_transcripciones). Evitar :00, :15, :30, :45 y las 9:00.
-- La Edge Function se despliega aparte: supabase/functions/fathom-sync (ver ESTADO-APP.md).
--
-- Que hace:
--   A. cs_llamadas: columnas nuevas (id externo unico, fuente, link de grabacion, duracion,
--      tipo, inicio, "vinculada a una carga manual", ultima sync). La transcripcion NO va
--      en una columna: usa cs_llamada_transcripciones (106), que solo ve quien edita.
--   B. cs_llamada_accionables.externo_hash: un action item de Fathom no se duplica.
--   C. cs_fathom_config (una fila): programas habilitados (hoy solo teo) y cron_activo
--      (arranca APAGADO). Solo el fundador lee y edita.
--   D. cs_fathom_sin_asignar: reuniones con invitados externos que no matchean un alumno
--      habilitado (o matchean a varios). Se asignan a mano desde la app. Ven fundador y CSM
--      (edicion en algun programa). anon: nada.
--   E. cs_fathom_corridas: registro de cada corrida (conteos y motivos, nunca contenido).
--   F. Funciones:
--        cs_fathom_aplicar(jsonb)   interna: toda la escritura de UNA reunion, atomica
--        cs_fathom_registrar(jsonb) solo service role: la llama la Edge Function
--        cs_fathom_asignar(uuid, uuid) / cs_fathom_descartar(uuid): desde la app
--        cs_fathom_cron()           la llama pg_cron; sin efecto si falta el secreto
--   G. pg_cron 'cs_fathom_sync' 2 veces por dia (10:07 y 19:07 hora Argentina) con net.http_post.
--      URL y clave salen de Vault: fathom_sync_url e fin_sync_service_key. Sin esos secretos,
--      o con cron_activo = false, no hace nada.
--
-- No pisa datos cargados a mano: una llamada manual del mismo alumno y fecha NO se duplica ni
-- se borra, queda vinculada (externo_id + vinculada_manual = true) y solo se le completan los
-- campos que estaban vacios.
-- No toca cs_calls, cs_seguimientos, cs_accionables, cs_v_ultima_llamada (la nueva llamada
-- entra sola en el semaforo), el cron diario ni las alertas.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo
do $$
declare
  v_falta text;
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'cs 122: hace falta Postgres 15 o mas';
  end if;
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_clientes', 'cs_llamadas', 'cs_llamada_accionables',
                    'cs_llamada_transcripciones', 'cs_accesos']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception 'cs 122: faltan tablas (corrieron la 102 y la 106?): %', v_falta;
  end if;
  select string_agg(c, ', ') into v_falta
  from unnest(array['resumen', 'en_que_esta', 'proximos_pasos']) c
  where not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'cs_llamadas' and column_name = c);
  if v_falta is not null then
    raise exception 'cs 122: a cs_llamadas le faltan columnas de la 106: %', v_falta;
  end if;
  select string_agg(r.f, ', ') into v_falta
  from (values ('es_fundador()'), ('cs_hoy()'), ('cs_tg_updated_at()'), ('cs_puede_editar(text)')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 122: faltan funciones: %', v_falta;
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise exception 'cs 122: faltan pg_cron y/o pg_net (Database > Extensions)';
  end if;
end $$;

-- Lock de las tablas que se alteran o referencian, todas juntas (regla del deadlock).
lock table public.cs_programas, public.cs_clientes, public.cs_llamadas,
           public.cs_llamada_accionables, public.cs_llamada_transcripciones
  in share row exclusive mode;


-- =====================================================================
-- A. cs_llamadas
-- =====================================================================
alter table public.cs_llamadas
  add column if not exists externo_id          text
    check (externo_id is null or (btrim(externo_id) <> '' and char_length(externo_id) <= 200)),
  add column if not exists fuente              text not null default 'manual'
    check (fuente in ('manual', 'fathom')),
  add column if not exists grabacion_url       text
    check (grabacion_url is null or (grabacion_url ~* '^https?://[^[:space:]]+$' and char_length(grabacion_url) <= 1000)),
  add column if not exists grabacion_share_url text
    check (grabacion_share_url is null or (grabacion_share_url ~* '^https?://[^[:space:]]+$' and char_length(grabacion_share_url) <= 1000)),
  add column if not exists duracion_min        int check (duracion_min is null or duracion_min >= 0),
  add column if not exists tipo                text
    check (tipo is null or tipo in ('onboarding', 'seguimiento', 'resell', 'otra')),
  add column if not exists inicio_at           timestamptz,
  add column if not exists vinculada_manual    boolean not null default false,
  add column if not exists fathom_sync_at      timestamptz;

create unique index if not exists cs_llamadas_externo_uk on public.cs_llamadas (externo_id);

comment on column public.cs_llamadas.externo_id is
  'Id de la reunion en la fuente externa, ej. fathom:123456 (122). Unico: una reunion no se duplica.';
comment on column public.cs_llamadas.vinculada_manual is
  '122: true si la llamada la cargo una persona y Fathom se vinculo a ella (no se duplico ni se piso).';


-- =====================================================================
-- B. cs_llamada_accionables.externo_hash
-- =====================================================================
alter table public.cs_llamada_accionables
  add column if not exists externo_hash text
    check (externo_hash is null or char_length(externo_hash) = 32);
create unique index if not exists cs_llamada_acc_externo_uk
  on public.cs_llamada_accionables (llamada_id, externo_hash);
comment on column public.cs_llamada_accionables.externo_hash is
  'md5(id externo || descripcion en minusculas) del action item de Fathom (122): evita duplicarlo si la sync corre de nuevo.';


-- =====================================================================
-- Funcion de permiso: fundador o CSM (edicion en algun programa)
-- =====================================================================
create or replace function public.cs_fathom_gestor()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
      or exists (select 1 from public.cs_accesos a where a.user_id = auth.uid() and a.nivel = 'edicion')
$$;
revoke all on function public.cs_fathom_gestor() from public, anon;
grant execute on function public.cs_fathom_gestor() to authenticated;


-- =====================================================================
-- C. cs_fathom_config (una fila)
-- =====================================================================
create table if not exists public.cs_fathom_config (
  id          boolean primary key default true check (id),
  programas   text[] not null default array['teo']::text[],
  cron_activo boolean not null default false,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid()
);
comment on table public.cs_fathom_config is
  'Config de la sync de Fathom (122). programas = a que programas se asignan llamadas. cron_activo = si pg_cron llama a la funcion (arranca apagado). Solo fundador.';

create or replace function public.cs_tg_fathom_config_before()
returns trigger language plpgsql set search_path = public
as $fn$
declare
  v_mal text;
begin
  new.programas := coalesce(new.programas, '{}');
  select string_agg(p, ', ') into v_mal
  from unnest(new.programas) p
  where not exists (select 1 from public.cs_programas c where c.id = p);
  if v_mal is not null then
    raise exception 'cs: programa inexistente: %', v_mal using errcode = '22023';
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$fn$;
drop trigger if exists cs_fathom_config_before on public.cs_fathom_config;
create trigger cs_fathom_config_before before insert or update on public.cs_fathom_config
  for each row execute function public.cs_tg_fathom_config_before();
revoke all on function public.cs_tg_fathom_config_before() from public, anon, authenticated;

alter table public.cs_fathom_config enable row level security;
revoke all on table public.cs_fathom_config from anon, authenticated;
grant select, update on table public.cs_fathom_config to authenticated;
grant select, insert, update on table public.cs_fathom_config to service_role;
drop policy if exists cs_fundador_select on public.cs_fathom_config;
create policy cs_fundador_select on public.cs_fathom_config for select to authenticated
  using (coalesce(public.es_fundador(), false));
drop policy if exists cs_fundador_update on public.cs_fathom_config;
create policy cs_fundador_update on public.cs_fathom_config for update to authenticated
  using (coalesce(public.es_fundador(), false)) with check (coalesce(public.es_fundador(), false));

insert into public.cs_fathom_config (id, programas, cron_activo)
select true, array['teo']::text[], false
where exists (select 1 from public.cs_programas where id = 'teo')
on conflict (id) do nothing;


-- =====================================================================
-- D. cs_fathom_sin_asignar
-- =====================================================================
create table if not exists public.cs_fathom_sin_asignar (
  id                  uuid primary key default gen_random_uuid(),
  externo_id          text not null unique,
  motivo              text not null default 'sin_alumno' check (motivo in ('sin_alumno', 'varios_alumnos')),
  estado              text not null default 'pendiente' check (estado in ('pendiente', 'asignada', 'descartada')),
  fecha               date not null,
  inicio_at           timestamptz,
  titulo              text,
  tipo                text check (tipo is null or tipo in ('onboarding', 'seguimiento', 'resell', 'otra')),
  duracion_min        int check (duracion_min is null or duracion_min >= 0),
  grabacion_url       text,
  grabacion_share_url text,
  resumen             text,
  en_que_esta         text,
  proximos_pasos      text,
  transcripcion       text,
  action_items        jsonb not null default '[]'::jsonb check (jsonb_typeof(action_items) = 'array'),
  invitados           jsonb not null default '[]'::jsonb check (jsonb_typeof(invitados) = 'array'),
  candidatos          uuid[] not null default '{}',
  programa_id         text references public.cs_programas(id),
  cliente_id          uuid,
  llamada_id          uuid,
  resuelta_at         timestamptz,
  resuelta_por        uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists cs_fathom_sin_asignar_estado_idx
  on public.cs_fathom_sin_asignar (estado, fecha desc);
comment on table public.cs_fathom_sin_asignar is
  'Reuniones de Fathom con invitados externos que no matchean un alumno de los programas habilitados (122). Se asignan a mano. Ven fundador y CSM.';

drop trigger if exists cs_fathom_sin_asignar_updated_at on public.cs_fathom_sin_asignar;
create trigger cs_fathom_sin_asignar_updated_at before update on public.cs_fathom_sin_asignar
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_fathom_sin_asignar enable row level security;
revoke all on table public.cs_fathom_sin_asignar from anon, authenticated;
grant select on table public.cs_fathom_sin_asignar to authenticated;
grant select, insert, update, delete on table public.cs_fathom_sin_asignar to service_role;
drop policy if exists cs_gestor_select on public.cs_fathom_sin_asignar;
create policy cs_gestor_select on public.cs_fathom_sin_asignar for select to authenticated
  using (public.cs_fathom_gestor());
-- Sin politicas de escritura: se asigna y descarta por las funciones de abajo.


-- =====================================================================
-- E. cs_fathom_corridas
-- =====================================================================
create table if not exists public.cs_fathom_corridas (
  id           bigint generated always as identity primary key,
  inicio       timestamptz not null default now(),
  fin          timestamptz,
  origen       text not null check (origen in ('servicio', 'manual', 'cron')),
  desde        timestamptz,
  estado       text not null default 'en_curso'
               check (estado in ('en_curso', 'ok', 'parcial', 'con_errores', 'error', 'sin_secretos')),
  traidas      int not null default 0,
  asignadas    int not null default 0,
  creadas      int not null default 0,
  actualizadas int not null default 0,
  vinculadas   int not null default 0,
  sin_asignar  int not null default 0,
  ignoradas    int not null default 0,
  errores      int not null default 0,
  parcial      boolean not null default false,
  detalle      text check (detalle is null or char_length(detalle) <= 2000)
);
create index if not exists cs_fathom_corridas_inicio_idx on public.cs_fathom_corridas (inicio desc);
comment on table public.cs_fathom_corridas is
  'Una fila por corrida de fathom-sync (122): conteos y motivos de error, nunca contenido de llamadas. Solo fundador.';

alter table public.cs_fathom_corridas enable row level security;
revoke all on table public.cs_fathom_corridas from anon, authenticated;
grant select on table public.cs_fathom_corridas to authenticated;
grant select, insert, update on table public.cs_fathom_corridas to service_role;
drop policy if exists cs_fundador_select on public.cs_fathom_corridas;
create policy cs_fundador_select on public.cs_fathom_corridas for select to authenticated
  using (coalesce(public.es_fundador(), false));


-- =====================================================================
-- F. Funciones
-- =====================================================================

-- F1. cs_fathom_aplicar: toda la escritura de UNA reunion. Interna (sin chequeo de permisos).
--   p = { externo_id, cliente_id|null, motivo, candidatos[], inicio_at, titulo, tipo, duracion_min,
--         grabacion_url, grabacion_share_url, resumen, en_que_esta, proximos_pasos, transcripcion,
--         action_items: [{descripcion, responsable}], invitados: [mail] }
--   Devuelve { resultado: creada | actualizada | vinculada | sin_asignar, llamada_id }
create or replace function public.cs_fathom_aplicar(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_ext    text := nullif(btrim(p->>'externo_id'), '');
  v_cli    uuid := nullif(p->>'cliente_id', '')::uuid;
  v_inicio timestamptz := nullif(p->>'inicio_at', '')::timestamptz;
  v_fecha  date;
  v_titulo text := nullif(left(btrim(coalesce(p->>'titulo', '')), 120), '');
  v_tipo   text := case when p->>'tipo' in ('onboarding', 'seguimiento', 'resell', 'otra') then p->>'tipo' else 'otra' end;
  v_dur    int  := case when (p->>'duracion_min') ~ '^\d{1,4}$' then (p->>'duracion_min')::int end;
  v_url    text := case when (p->>'grabacion_url') ~* '^https?://[^[:space:]]+$'
                         and char_length(p->>'grabacion_url') <= 1000 then p->>'grabacion_url' end;
  v_share  text := case when (p->>'grabacion_share_url') ~* '^https?://[^[:space:]]+$'
                         and char_length(p->>'grabacion_share_url') <= 1000 then p->>'grabacion_share_url' end;
  v_res_txt text := nullif(left(btrim(coalesce(p->>'resumen', '')), 4000), '');
  v_est    text := nullif(left(btrim(coalesce(p->>'en_que_esta', '')), 2000), '');
  v_prox   text := nullif(left(btrim(coalesce(p->>'proximos_pasos', '')), 2000), '');
  v_transc text := nullif(left(btrim(coalesce(p->>'transcripcion', '')), 200000), '');
  v_prog   text;
  v_ll     uuid;
  v_cli_ll uuid;
  v_res    text;
  v_it     jsonb;
  v_desc   text;
  v_texto  text;
  v_orden  int;
  v_motivo text;
  v_cand   uuid[];
begin
  if v_ext is null or v_inicio is null then
    raise exception 'cs: faltan externo_id o inicio_at' using errcode = '22023';
  end if;
  v_fecha := least((v_inicio at time zone 'America/Argentina/Buenos_Aires')::date, public.cs_hoy());

  -- 1. ya existe por id externo: se completa lo que falta, nunca se pisa
  select l.id, l.cliente_id into v_ll, v_cli_ll from public.cs_llamadas l where l.externo_id = v_ext;
  if found then
    update public.cs_llamadas set
      titulo = coalesce(titulo, v_titulo),
      tipo = coalesce(tipo, v_tipo),
      duracion_min = coalesce(duracion_min, v_dur),
      grabacion_url = coalesce(grabacion_url, v_url),
      grabacion_share_url = coalesce(grabacion_share_url, v_share),
      inicio_at = coalesce(inicio_at, v_inicio),
      resumen = coalesce(resumen, v_res_txt),
      en_que_esta = coalesce(en_que_esta, v_est),
      proximos_pasos = coalesce(proximos_pasos, v_prox),
      fathom_sync_at = now()
    where id = v_ll;
    v_cli := v_cli_ll;
    v_res := 'actualizada';

  -- 2. alumno resuelto: vincular a una carga manual del mismo dia, o crear
  elsif v_cli is not null then
    select c.programa_id into v_prog from public.cs_clientes c where c.id = v_cli;
    if v_prog is null then
      raise exception 'cs: el alumno % no existe', v_cli using errcode = '22023';
    end if;
    select l.id into v_ll from public.cs_llamadas l
    where l.cliente_id = v_cli and l.fecha = v_fecha and l.externo_id is null
    order by l.created_at limit 1 for update;
    if found then
      update public.cs_llamadas set
        externo_id = v_ext, fuente = 'fathom', vinculada_manual = true,
        titulo = coalesce(titulo, v_titulo),
        tipo = coalesce(tipo, v_tipo),
        duracion_min = coalesce(duracion_min, v_dur),
        grabacion_url = coalesce(grabacion_url, v_url),
        grabacion_share_url = coalesce(grabacion_share_url, v_share),
        inicio_at = coalesce(inicio_at, v_inicio),
        resumen = coalesce(resumen, v_res_txt),
        en_que_esta = coalesce(en_que_esta, v_est),
        proximos_pasos = coalesce(proximos_pasos, v_prox),
        fathom_sync_at = now()
      where id = v_ll;
      v_res := 'vinculada';
    else
      insert into public.cs_llamadas (programa_id, cliente_id, fecha, titulo, externo_id, fuente, tipo,
                                      duracion_min, grabacion_url, grabacion_share_url, inicio_at,
                                      resumen, en_que_esta, proximos_pasos, fathom_sync_at)
      values (v_prog, v_cli, v_fecha, v_titulo, v_ext, 'fathom', v_tipo,
              v_dur, v_url, v_share, v_inicio, v_res_txt, v_est, v_prox, now())
      returning id into v_ll;
      v_res := 'creada';
    end if;

  -- 3. sin alumno: queda para asignar a mano
  else
    v_motivo := case when p->>'motivo' = 'varios_alumnos' then 'varios_alumnos' else 'sin_alumno' end;
    select coalesce(array_agg(x::uuid), '{}') into v_cand
    from jsonb_array_elements_text(
           case when jsonb_typeof(p->'candidatos') = 'array' then p->'candidatos' else '[]'::jsonb end) x;
    insert into public.cs_fathom_sin_asignar as s (
      externo_id, motivo, fecha, inicio_at, titulo, tipo, duracion_min, grabacion_url, grabacion_share_url,
      resumen, en_que_esta, proximos_pasos, transcripcion, action_items, invitados, candidatos)
    values (
      v_ext, v_motivo, v_fecha, v_inicio, v_titulo, v_tipo, v_dur, v_url, v_share,
      v_res_txt, v_est, v_prox, v_transc,
      case when jsonb_typeof(p->'action_items') = 'array' then p->'action_items' else '[]'::jsonb end,
      case when jsonb_typeof(p->'invitados') = 'array' then p->'invitados' else '[]'::jsonb end,
      v_cand)
    on conflict (externo_id) do update set
      motivo = excluded.motivo, fecha = excluded.fecha, inicio_at = excluded.inicio_at,
      titulo = excluded.titulo, tipo = excluded.tipo, duracion_min = excluded.duracion_min,
      grabacion_url = excluded.grabacion_url, grabacion_share_url = excluded.grabacion_share_url,
      resumen = excluded.resumen, en_que_esta = excluded.en_que_esta, proximos_pasos = excluded.proximos_pasos,
      transcripcion = excluded.transcripcion, action_items = excluded.action_items,
      invitados = excluded.invitados, candidatos = excluded.candidatos
    where s.estado = 'pendiente';
    return jsonb_build_object('resultado', 'sin_asignar', 'llamada_id', null);
  end if;

  -- Con llamada: programa, transcripcion y accionables
  if v_prog is null then
    select c.programa_id into v_prog from public.cs_clientes c where c.id = v_cli;
  end if;

  if v_transc is not null then
    insert into public.cs_llamada_transcripciones (llamada_id, programa_id, cliente_id, texto)
    values (v_ll, v_prog, v_cli, v_transc)
    on conflict (llamada_id) do nothing;   -- una transcripcion pegada a mano no se pisa
  end if;

  select coalesce(max(a.orden) + 1, 0) into v_orden from public.cs_llamada_accionables a where a.llamada_id = v_ll;
  if jsonb_typeof(p->'action_items') = 'array' then
    for v_it in select e from jsonb_array_elements(p->'action_items') e loop
      v_desc := btrim(coalesce(v_it->>'descripcion', ''));
      continue when v_desc = '';
      v_texto := left(v_desc || case when nullif(btrim(coalesce(v_it->>'responsable', '')), '') is not null
                                     then ' (' || btrim(v_it->>'responsable') || ')' else '' end, 500);
      insert into public.cs_llamada_accionables (programa_id, cliente_id, llamada_id, texto, orden, externo_hash)
      values (v_prog, v_cli, v_ll, v_texto, v_orden, md5(v_ext || '|' || lower(v_desc)))
      on conflict (llamada_id, externo_hash) do nothing;
      v_orden := v_orden + 1;
    end loop;
  end if;

  -- Si estaba en la lista de sin asignar, queda resuelta
  update public.cs_fathom_sin_asignar s
  set estado = 'asignada', cliente_id = v_cli, programa_id = v_prog, llamada_id = v_ll,
      resuelta_at = coalesce(s.resuelta_at, now()), resuelta_por = coalesce(s.resuelta_por, auth.uid())
  where s.externo_id = v_ext and s.estado in ('pendiente', 'descartada');

  return jsonb_build_object('resultado', v_res, 'llamada_id', v_ll);
end;
$fn$;
revoke all on function public.cs_fathom_aplicar(jsonb) from public, anon, authenticated;


-- F2. cs_fathom_registrar: la puerta de la Edge Function (service role). Un usuario logueado no entra.
create or replace function public.cs_fathom_registrar(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
begin
  if auth.uid() is not null then
    raise exception 'cs: solo la funcion de sincronizacion puede registrar llamadas de Fathom' using errcode = '42501';
  end if;
  return public.cs_fathom_aplicar(p);
end;
$fn$;
revoke all on function public.cs_fathom_registrar(jsonb) from public, anon, authenticated;
grant execute on function public.cs_fathom_registrar(jsonb) to service_role;


-- F3. cs_fathom_asignar: desde "Llamadas sin asignar".
create or replace function public.cs_fathom_asignar(p_id uuid, p_cliente uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_row  public.cs_fathom_sin_asignar%rowtype;
  v_prog text;
  v_out  jsonb;
begin
  if not public.cs_fathom_gestor() then
    raise exception 'cs: solo el fundador o la CSM asignan llamadas' using errcode = '42501';
  end if;
  select * into v_row from public.cs_fathom_sin_asignar where id = p_id for update;
  if not found then
    raise exception 'cs: la llamada no existe' using errcode = '22023';
  end if;
  if v_row.estado <> 'pendiente' then
    raise exception 'cs: esa llamada ya fue asignada o descartada' using errcode = '22023';
  end if;
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: el alumno no existe' using errcode = '22023';
  end if;
  if not public.cs_puede_editar(v_prog) then
    raise exception 'cs: no tenes permiso de edicion en ese programa' using errcode = '42501';
  end if;
  v_out := public.cs_fathom_aplicar(jsonb_build_object(
    'externo_id', v_row.externo_id, 'cliente_id', p_cliente, 'inicio_at', coalesce(v_row.inicio_at, v_row.fecha::timestamptz),
    'titulo', v_row.titulo, 'tipo', v_row.tipo, 'duracion_min', v_row.duracion_min,
    'grabacion_url', v_row.grabacion_url, 'grabacion_share_url', v_row.grabacion_share_url,
    'resumen', v_row.resumen, 'en_que_esta', v_row.en_que_esta, 'proximos_pasos', v_row.proximos_pasos,
    'transcripcion', v_row.transcripcion, 'action_items', v_row.action_items));
  return v_out;
end;
$fn$;
revoke all on function public.cs_fathom_asignar(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_asignar(uuid, uuid) to authenticated;


-- F4. cs_fathom_descartar: "no es de un alumno" (reunion que no hay que asignar).
create or replace function public.cs_fathom_descartar(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  if not public.cs_fathom_gestor() then
    raise exception 'cs: solo el fundador o la CSM descartan llamadas' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'descartada', resuelta_at = now(), resuelta_por = auth.uid()
  where id = p_id and estado = 'pendiente';
  if not found then
    raise exception 'cs: la llamada no existe o ya no esta pendiente' using errcode = '22023';
  end if;
end;
$fn$;
revoke all on function public.cs_fathom_descartar(uuid) from public, anon;
grant execute on function public.cs_fathom_descartar(uuid) to authenticated;


-- F5. cs_fathom_cron: la llama pg_cron. Sin efecto si esta apagado o faltan los secretos de Vault.
--   Devuelve: apagado | sin_vault | sin_secretos | enviado
create or replace function public.cs_fathom_cron()
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  v_activo boolean;
  v_url    text;
  v_key    text;
  v_req    bigint;
begin
  select c.cron_activo into v_activo from public.cs_fathom_config c limit 1;
  if not coalesce(v_activo, false) then
    return 'apagado';
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    insert into public.cs_fathom_corridas (origen, estado, fin, detalle)
    values ('cron', 'sin_secretos', now(), 'Vault no esta disponible');
    return 'sin_vault';
  end if;
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'fathom_sync_url';
  select s.decrypted_secret into v_key from vault.decrypted_secrets s where s.name = 'fin_sync_service_key';
  if nullif(btrim(v_url), '') is null or nullif(btrim(v_key), '') is null then
    insert into public.cs_fathom_corridas (origen, estado, fin, detalle)
    values ('cron', 'sin_secretos', now(), 'Faltan los secretos fathom_sync_url y/o fin_sync_service_key en Vault');
    return 'sin_secretos';
  end if;
  v_req := net.http_post(
    url     := v_url,
    headers := jsonb_build_object('content-type', 'application/json', 'authorization', 'Bearer ' || v_key),
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000);
  return 'enviado';
end;
$fn$;
revoke all on function public.cs_fathom_cron() from public, anon, authenticated;


-- =====================================================================
-- G. pg_cron: 10:07 y 19:07 hora Argentina (13:07 y 22:07 UTC). No pisa :00/:15/:30/:45 ni 9:00.
-- =====================================================================
select cron.unschedule(jobid) from cron.job where jobname = 'cs_fathom_sync';
select cron.schedule('cs_fathom_sync', '7 13,22 * * *', $cron$ select public.cs_fathom_cron(); $cron$);

commit;


-- =====================================================================
-- ANTES DE ENCENDER (a mano, fuera de este archivo; una sola vez)
-- =====================================================================
--   1. Secreto de la funcion (Supabase > Edge Functions > fathom-sync > Secrets):
--        FATHOM_API_KEY = <API key de Fathom de la cuenta de Joaquin: User Settings > API Access>
--   2. Desplegar:  supabase functions deploy fathom-sync --no-verify-jwt
--   3. Vault (SQL Editor): la clave tiene que ser una sb_secret_ (la service_role legacy se rechaza):
--        select vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/fathom-sync', 'fathom_sync_url');
--        select vault.create_secret('<sb_secret_...>', 'fin_sync_service_key');   -- si ya existe, no se repite
--   4. Probar a mano con "Sincronizar Fathom ahora" (Configuracion) o con curl, y recien despues:
--        update public.cs_fathom_config set cron_activo = true;
--      (o con el interruptor de la pantalla de Configuracion)
--   Para habilitar liam o agus: update public.cs_fathom_config set programas = array['teo','liam'];
--      (o desde Configuracion). No hace falta tocar codigo.


-- =====================================================================
-- CONTROLES (de a uno, despues de correr la migracion)
-- =====================================================================

-- C1. Columnas nuevas (9 en cs_llamadas + externo_hash). Esperado: 10 filas.
-- select table_name, column_name from information_schema.columns
-- where table_schema = 'public'
--   and ((table_name = 'cs_llamadas' and column_name in ('externo_id','fuente','grabacion_url','grabacion_share_url',
--         'duracion_min','tipo','inicio_at','vinculada_manual','fathom_sync_at'))
--     or (table_name = 'cs_llamada_accionables' and column_name = 'externo_hash'))
-- order by 1, 2;

-- C2. Tablas nuevas con RLS activa y sus politicas. Esperado: rls = true en las 3;
--     config: 2 politicas (select, update) · sin_asignar: 1 (select) · corridas: 1 (select).
-- select c.relname, c.relrowsecurity as rls,
--        (select string_agg(p.polname, ', ' order by p.polname) from pg_policy p where p.polrelid = c.oid) as politicas
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace
--   and c.relname in ('cs_fathom_config', 'cs_fathom_sin_asignar', 'cs_fathom_corridas');

-- C3. anon y authenticated no escriben donde no deben. Esperado: 0 filas.
-- select grantee, table_name, privilege_type from information_schema.role_table_grants
-- where table_schema = 'public'
--   and table_name in ('cs_fathom_config', 'cs_fathom_sin_asignar', 'cs_fathom_corridas')
--   and (grantee = 'anon'
--        or (grantee = 'authenticated' and privilege_type in ('insert', 'delete', 'truncate')
--            or (grantee = 'authenticated' and privilege_type = 'update' and table_name <> 'cs_fathom_config')));

-- C4. Config inicial. Esperado: programas = {teo}, cron_activo = false.
-- select programas, cron_activo from public.cs_fathom_config;

-- C5. Job de cron. Esperado: 1 fila, '7 13,22 * * *', active = true.
-- select jobname, schedule, active from cron.job where jobname = 'cs_fathom_sync';

-- C6. Quien puede ejecutar las funciones. Esperado: aplicar y cron sin ningun rol de la app;
--     registrar solo service_role; asignar, descartar y gestor: authenticated.
-- select p.proname,
--        has_function_privilege('anon', p.oid, 'execute') as anon,
--        has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
-- from pg_proc p
-- where p.pronamespace = 'public'::regnamespace
--   and p.proname in ('cs_fathom_aplicar', 'cs_fathom_registrar', 'cs_fathom_asignar',
--                     'cs_fathom_descartar', 'cs_fathom_cron', 'cs_fathom_gestor')
-- order by 1;

-- C7. Secretos de Vault cargados (solo nombres). Esperado: 2 filas cuando se hayan cargado.
-- select name from vault.decrypted_secrets where name in ('fathom_sync_url', 'fin_sync_service_key') order by 1;

-- C8. HUMO (se revierte solo: termina en error "HUMO OK: 11 comprobaciones"). Usa un alumno real
--     cualquiera para colgarle datos de prueba y los deshace; no manda nada a Discord ni a Fathom.
-- do $$
-- declare
--   v_cli uuid; v_n int := 0; v_r jsonb; v_ll uuid; v_cnt int;
--   v_hoy date := public.cs_hoy();
--   v_item jsonb := '[{"descripcion":"Mandar el plan","responsable":"Joaquin"},{"descripcion":"mandar el PLAN"},{"descripcion":"Revisar accesos"}]';
-- begin
--   select id into v_cli from public.cs_clientes order by created_at limit 1;
--   if v_cli is null then raise exception 'sin alumnos para probar'; end if;
--   -- 1. crea la llamada
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-122','cliente_id',v_cli,
--     'inicio_at', (v_hoy - 1)::timestamptz + interval '15 hours', 'titulo','Seguimiento humo','tipo','seguimiento',
--     'duracion_min', 45, 'grabacion_url','https://fathom.video/xyz','resumen','## Summary\nok',
--     'transcripcion','[00:00:01] A: hola','action_items', v_item));
--   if v_r->>'resultado' <> 'creada' then raise exception 'esperaba creada, vino %', v_r; end if;
--   v_n := v_n + 1;
--   v_ll := (v_r->>'llamada_id')::uuid;
--   -- 2. accionables sin duplicar (2 distintos: el segundo es el mismo en minusculas)
--   select count(*) into v_cnt from public.cs_llamada_accionables where llamada_id = v_ll;
--   if v_cnt <> 2 then raise exception 'esperaba 2 accionables, hay %', v_cnt; end if;
--   v_n := v_n + 1;
--   -- 3. segunda corrida: no duplica nada
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-122','cliente_id',v_cli,
--     'inicio_at', (v_hoy - 1)::timestamptz + interval '15 hours', 'transcripcion','[00:00:01] A: hola','action_items', v_item));
--   if v_r->>'resultado' <> 'actualizada' then raise exception 'esperaba actualizada, vino %', v_r; end if;
--   select count(*) into v_cnt from public.cs_llamada_accionables where llamada_id = v_ll;
--   if v_cnt <> 2 then raise exception 'la segunda corrida duplico accionables: %', v_cnt; end if;
--   select count(*) into v_cnt from public.cs_llamadas where externo_id = 'fathom:humo-122';
--   if v_cnt <> 1 then raise exception 'llamada duplicada: %', v_cnt; end if;
--   v_n := v_n + 3;
--   -- 4. transcripcion guardada
--   select count(*) into v_cnt from public.cs_llamada_transcripciones where llamada_id = v_ll;
--   if v_cnt <> 1 then raise exception 'sin transcripcion'; end if;
--   v_n := v_n + 1;
--   -- 5. una carga manual del mismo dia se vincula, no se duplica
--   insert into public.cs_llamadas (programa_id, cliente_id, fecha, titulo)
--     select programa_id, id, v_hoy - 3, 'Manual humo' from public.cs_clientes where id = v_cli;
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-122b','cliente_id',v_cli,
--     'inicio_at', (v_hoy - 3)::timestamptz + interval '15 hours', 'titulo','Otro titulo'));
--   if v_r->>'resultado' <> 'vinculada' then raise exception 'esperaba vinculada, vino %', v_r; end if;
--   select count(*) into v_cnt from public.cs_llamadas where cliente_id = v_cli and fecha = v_hoy - 3;
--   if v_cnt <> 1 then raise exception 'la manual se duplico: %', v_cnt; end if;
--   select count(*) into v_cnt from public.cs_llamadas
--     where externo_id = 'fathom:humo-122b' and vinculada_manual and titulo = 'Manual humo';
--   if v_cnt <> 1 then raise exception 'la manual no quedo vinculada o perdio el titulo'; end if;
--   v_n := v_n + 2;
--   -- 6. sin alumno: va a sin asignar, una sola fila aunque se repita
--   perform public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-122c','inicio_at', now(),'invitados','["x@y.com"]'));
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-122c','inicio_at', now(),'invitados','["x@y.com"]'));
--   if v_r->>'resultado' <> 'sin_asignar' then raise exception 'esperaba sin_asignar, vino %', v_r; end if;
--   select count(*) into v_cnt from public.cs_fathom_sin_asignar where externo_id = 'fathom:humo-122c' and estado = 'pendiente';
--   if v_cnt <> 1 then raise exception 'sin asignar duplicada: %', v_cnt; end if;
--   v_n := v_n + 1;
--   -- 7. cuando matchea, la de sin asignar queda resuelta
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-122c','cliente_id',v_cli,'inicio_at', now()));
--   select count(*) into v_cnt from public.cs_fathom_sin_asignar where externo_id = 'fathom:humo-122c' and estado = 'asignada';
--   if v_cnt <> 1 then raise exception 'la sin asignar no quedo resuelta'; end if;
--   v_n := v_n + 1;
--   raise exception 'HUMO OK: % comprobaciones', v_n;
-- end $$;

-- C9. Despues de la primera sync real (informativo):
-- select id, inicio, estado, origen, traidas, creadas, actualizadas, vinculadas, sin_asignar, ignoradas, errores, left(detalle, 200)
-- from public.cs_fathom_corridas order by inicio desc limit 5;
-- select fuente, count(*) from public.cs_llamadas group by 1;
-- select motivo, estado, count(*) from public.cs_fathom_sin_asignar group by 1, 2;
-- Cron: select status, return_message, start_time from cron.job_run_details
--       where jobid = (select jobid from cron.job where jobname = 'cs_fathom_sync') order by start_time desc limit 5;


-- =====================================================================
-- VUELTA ATRAS (comentada). Ojo: borra la vinculacion con Fathom y las llamadas traidas por la sync.
-- =====================================================================
-- begin;
-- select cron.unschedule(jobid) from cron.job where jobname = 'cs_fathom_sync';
-- drop function if exists public.cs_fathom_cron();
-- drop function if exists public.cs_fathom_descartar(uuid);
-- drop function if exists public.cs_fathom_asignar(uuid, uuid);
-- drop function if exists public.cs_fathom_registrar(jsonb);
-- drop function if exists public.cs_fathom_aplicar(jsonb);
-- drop table if exists public.cs_fathom_corridas;
-- drop table if exists public.cs_fathom_sin_asignar;
-- drop table if exists public.cs_fathom_config;
-- drop function if exists public.cs_tg_fathom_config_before();
-- drop function if exists public.cs_fathom_gestor();
-- -- Llamadas que trajo Fathom (no toca las manuales; las vinculadas vuelven a ser manuales):
-- delete from public.cs_llamadas where fuente = 'fathom' and not vinculada_manual;
-- update public.cs_llamadas set externo_id = null, fuente = 'manual', vinculada_manual = false where fuente = 'fathom';
-- drop index if exists public.cs_llamada_acc_externo_uk;
-- alter table public.cs_llamada_accionables drop column if exists externo_hash;
-- drop index if exists public.cs_llamadas_externo_uk;
-- alter table public.cs_llamadas
--   drop column if exists externo_id, drop column if exists fuente, drop column if exists grabacion_url,
--   drop column if exists grabacion_share_url, drop column if exists duracion_min, drop column if exists tipo,
--   drop column if exists inicio_at, drop column if exists vinculada_manual, drop column if exists fathom_sync_at;
-- commit;
