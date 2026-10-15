-- =====================================================================
-- 124-producto-fathom-consultores.sql  ·  PRODUCTO: Fathom por consultor, estados de
-- la llamada y permisos para las llamadas que no son de un alumno
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), primero en el banco de pruebas.
-- Numeracion global asignada por el jefe: 124. Requiere la 122 (y por lo tanto la 102 y la 106).
-- Evitar :00, :15, :30, :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- La Edge Function (supabase/functions/fathom-sync) se despliega DESPUES de correr esto.
--
-- Que hace:
--   A. cs_fathom_consultores: una fila por cuenta de Fathom (nombre visible, NOMBRE del secreto
--      de la funcion, activo). Nunca se guarda una key: solo el nombre del secreto, y la base
--      exige que empiece con FATHOM_API_KEY (para que nadie pueda apuntar la funcion a otro
--      secreto, ej. la service key). Semilla: joaco / teo / martu. Sumar un consultor = una fila
--      (desde Configuracion, solo fundador). Sin secreto cargado la funcion lo saltea sin error.
--   B. Columna consultor en cs_llamadas y en cs_fathom_sin_asignar (backfill: todo lo que ya
--      entro desde Fathom es de joaco).
--   C. Estado de la llamada de Fathom, en cs_fathom_sin_asignar.estado:
--        pendiente  = con invitados externos, sin alumno
--        no_alumno  = marcada a mano (prospecto, socio, etc.)   [antes 'descartada']
--        asignada   = ya se convirtio en una llamada de alumno (vive en cs_llamadas)
--      El estado "alumno" es una llamada de cs_llamadas con fuente = 'fathom'. La vista
--      cs_v_fathom_llamadas junta las dos cosas para la pantalla "Llamadas".
--   D. Permisos (RLS):
--        llamada de alumno      -> cs_llamadas: la ve quien tiene acceso al programa (sin cambios)
--        pendiente / no_alumno  -> solo fundador y rol "cliente" (ver abajo). La CSM NO las ve.
--        transcripcion de esas  -> nadie la lee por la API (permiso de columna revocado); al
--                                  asignar pasa a cs_llamada_transcripciones (106: solo quien edita)
--   E. Funciones nuevas / reemplazadas (todas security definer):
--        cs_fathom_aplicar        (reemplaza la de la 122: consultor + respeta "no es alumno")
--        cs_fathom_asignar        (reemplaza: fundador, cliente del programa del alumno o edicion)
--        cs_fathom_marcar_no_alumno / cs_fathom_reabrir   (fundador y cliente)
--        cs_fathom_descartar      (se elimina: lo reemplaza marcar_no_alumno)
--   F. cs_fathom_corridas.por_consultor (jsonb con el desglose de cada corrida).
--
-- Rol "cliente": en este modelo el acceso a Producto lo da cs_accesos (079) y el rol de area
-- esta en crm_members.rol. "Cliente" = crm_members.rol = 'cliente' Y fila en cs_accesos del
-- programa (cualquier nivel). Es el dueno del programa (ej. cliente@liam, nivel lectura).
-- Para una llamada sin programa conocido (pendiente / no_alumno): fundador, o un cliente cuyo
-- programa este en cs_fathom_config.programas.
--
-- No toca finanzas, crm, ventas, cron, alertas ni el umbral de "sin llamada". Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo
do $$
declare
  v_falta text;
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'cs 124: hace falta Postgres 15 o mas (vistas security_invoker)';
  end if;
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_clientes', 'cs_llamadas', 'cs_llamada_accionables',
                    'cs_llamada_transcripciones', 'cs_accesos', 'cs_fathom_config',
                    'cs_fathom_sin_asignar', 'cs_fathom_corridas', 'crm_members']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception 'cs 124: faltan tablas (corrio la 122?): %', v_falta;
  end if;
  select string_agg(r.f, ', ') into v_falta
  from (values ('es_fundador()'), ('cs_hoy()'), ('cs_tg_updated_at()'), ('cs_puede_editar(text)'),
               ('cs_puede_ver(text)'), ('cs_fathom_aplicar(jsonb)'), ('cs_fathom_registrar(jsonb)')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 124: faltan funciones: %', v_falta;
  end if;
end $$;

-- Lock de todo lo que se altera, junto (regla del deadlock).
lock table public.cs_programas, public.cs_clientes, public.cs_llamadas, public.cs_llamada_accionables,
           public.cs_llamada_transcripciones, public.cs_fathom_config, public.cs_fathom_sin_asignar,
           public.cs_fathom_corridas
  in share row exclusive mode;


-- =====================================================================
-- A. cs_fathom_consultores
-- =====================================================================
create table if not exists public.cs_fathom_consultores (
  id                 text primary key check (id ~ '^[a-z][a-z0-9_]{1,30}$'),
  nombre             text not null check (btrim(nombre) <> '' and char_length(nombre) <= 60),
  secreto            text not null unique
                     check (secreto ~ '^FATHOM_API_KEY(_[A-Z0-9]+)*$' and char_length(secreto) <= 64),
  activo             boolean not null default true,
  orden              int not null default 0,
  ultimo_at          timestamptz,          -- ultima vez que la funcion lo intento
  ultimo_estado      text check (ultimo_estado is null or ultimo_estado in
                       ('ok', 'parcial', 'con_errores', 'error', 'sin_secreto', 'clave_repetida', 'omitido_por_tiempo')),
  ultimo_resumen     jsonb,                -- conteos de esa corrida (nunca contenido)
  ultima_sync_ok_at  timestamptz,          -- ultima corrida completa (ok o con_errores)
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.cs_fathom_consultores is
  'Cuentas de Fathom por consultor (124). secreto = NOMBRE del secreto de la Edge Function fathom-sync (nunca la key). Sumar un consultor = agregar una fila.';

create or replace function public.cs_tg_fathom_consultores_before()
returns trigger language plpgsql set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' and new.id is distinct from old.id then
    raise exception 'cs: el id de un consultor no cambia' using errcode = '22023';
  end if;
  new.updated_at := now();
  return new;
end;
$fn$;
drop trigger if exists cs_fathom_consultores_before on public.cs_fathom_consultores;
create trigger cs_fathom_consultores_before before insert or update on public.cs_fathom_consultores
  for each row execute function public.cs_tg_fathom_consultores_before();
revoke all on function public.cs_tg_fathom_consultores_before() from public, anon, authenticated;

alter table public.cs_fathom_consultores enable row level security;
revoke all on table public.cs_fathom_consultores from anon, authenticated;
grant select, insert, update on table public.cs_fathom_consultores to authenticated;
grant select, update on table public.cs_fathom_consultores to service_role;
drop policy if exists cs_select on public.cs_fathom_consultores;
create policy cs_select on public.cs_fathom_consultores for select to authenticated using (true);
drop policy if exists cs_fundador_insert on public.cs_fathom_consultores;
create policy cs_fundador_insert on public.cs_fathom_consultores for insert to authenticated
  with check (coalesce(public.es_fundador(), false));
drop policy if exists cs_fundador_update on public.cs_fathom_consultores;
create policy cs_fundador_update on public.cs_fathom_consultores for update to authenticated
  using (coalesce(public.es_fundador(), false)) with check (coalesce(public.es_fundador(), false));
-- Sin delete: un consultor se desactiva, no se borra (las llamadas lo referencian).

insert into public.cs_fathom_consultores (id, nombre, secreto, activo, orden) values
  ('joaco', 'Joaco', 'FATHOM_API_KEY',       true, 1),
  ('teo',   'Teo',   'FATHOM_API_KEY_TEO',   true, 2),
  ('martu', 'Martu', 'FATHOM_API_KEY_MARTU', true, 3)
on conflict (id) do nothing;

-- Joaco ya corrio: su ultima corrida completa evita volver a traer 60 dias.
update public.cs_fathom_consultores
set ultima_sync_ok_at = (select max(inicio) from public.cs_fathom_corridas where estado = 'ok')
where id = 'joaco' and ultima_sync_ok_at is null;


-- =====================================================================
-- B. Columna consultor
-- =====================================================================
alter table public.cs_llamadas
  add column if not exists consultor text references public.cs_fathom_consultores(id);
alter table public.cs_fathom_sin_asignar
  add column if not exists consultor text references public.cs_fathom_consultores(id);

create index if not exists cs_llamadas_consultor_idx on public.cs_llamadas (consultor) where consultor is not null;
create index if not exists cs_fathom_sin_asignar_consultor_idx on public.cs_fathom_sin_asignar (consultor, fecha desc);

-- Backfill: lo que ya entro desde Fathom salio de la cuenta de Joaco.
update public.cs_llamadas set consultor = 'joaco' where fuente = 'fathom' and consultor is null;
update public.cs_fathom_sin_asignar set consultor = 'joaco' where consultor is null;

comment on column public.cs_llamadas.consultor is
  '124: cuenta de Fathom (cs_fathom_consultores.id) que grabo la llamada. Null en llamadas manuales.';
comment on column public.cs_fathom_sin_asignar.consultor is
  '124: cuenta de Fathom (cs_fathom_consultores.id) que grabo la reunion.';


-- =====================================================================
-- C. Estados de la llamada de Fathom
-- =====================================================================
do $$
declare
  r record;
begin
  for r in select c.conname from pg_constraint c
           where c.conrelid = 'public.cs_fathom_sin_asignar'::regclass and c.contype = 'c'
             and pg_get_constraintdef(c.oid) like '%descartada%'
  loop
    execute format('alter table public.cs_fathom_sin_asignar drop constraint %I', r.conname);
  end loop;
end $$;
update public.cs_fathom_sin_asignar set estado = 'no_alumno' where estado = 'descartada';
alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_124;
alter table public.cs_fathom_sin_asignar add constraint cs_fathom_sin_asignar_estado_124
  check (estado in ('pendiente', 'asignada', 'no_alumno'));
comment on column public.cs_fathom_sin_asignar.estado is
  '124: pendiente (con externos, sin alumno) | no_alumno (marcada a mano) | asignada (ya es una llamada de cs_llamadas).';

-- Una fila ya asignada no conserva la transcripcion de una reunion que dejo de ser "privada".
update public.cs_fathom_sin_asignar set transcripcion = null where estado = 'asignada' and transcripcion is not null;

-- F. corridas
alter table public.cs_fathom_corridas add column if not exists por_consultor jsonb;


-- =====================================================================
-- D. Permisos
-- =====================================================================
-- Helpers con uid explicito (internos: sirven para auditar permisos desde el SQL Editor).
create or replace function public.cs_fathom_es_cliente_de(p_uid uuid, p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.crm_members m
    join public.cs_accesos a on a.user_id = m.user_id
    where m.user_id = p_uid and m.rol = 'cliente' and a.programa_id = p_programa)
$$;
revoke all on function public.cs_fathom_es_cliente_de(uuid, text) from public, anon, authenticated;

-- Ve las llamadas pendiente / no_alumno: fundador, o cliente de un programa habilitado en la config.
create or replace function public.cs_fathom_ve_privadas_de(p_uid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select p_uid is not null and (
    exists (select 1 from public.crm_members m where m.user_id = p_uid and m.rol = 'fundador')
    or exists (
      select 1
      from public.crm_members m
      join public.cs_accesos a on a.user_id = m.user_id
      where m.user_id = p_uid and m.rol = 'cliente'
        and a.programa_id in (select unnest(c.programas) from public.cs_fathom_config c)))
$$;
revoke all on function public.cs_fathom_ve_privadas_de(uuid) from public, anon, authenticated;

create or replace function public.cs_fathom_ve_privadas()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.cs_fathom_ve_privadas_de(auth.uid()), false)
$$;
revoke all on function public.cs_fathom_ve_privadas() from public, anon;
grant execute on function public.cs_fathom_ve_privadas() to authenticated;

-- Asignar a un alumno de ese programa: fundador, cliente del programa, o edicion en el programa.
create or replace function public.cs_fathom_puede_asignar(p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
      or public.cs_fathom_es_cliente_de(auth.uid(), p_programa)
      or coalesce(public.cs_puede_editar(p_programa), false)
$$;
revoke all on function public.cs_fathom_puede_asignar(text) from public, anon;
grant execute on function public.cs_fathom_puede_asignar(text) to authenticated;

-- RLS de cs_fathom_sin_asignar: reemplaza la del fundador+CSM de la 122.
drop policy if exists cs_gestor_select on public.cs_fathom_sin_asignar;
drop policy if exists cs_privadas_select on public.cs_fathom_sin_asignar;
create policy cs_privadas_select on public.cs_fathom_sin_asignar for select to authenticated
  using (public.cs_fathom_ve_privadas());

-- La transcripcion no sale por la API a ningun rol (permiso de columna). Al asignar pasa a
-- cs_llamada_transcripciones, que solo ve quien edita el programa del alumno.
revoke select on table public.cs_fathom_sin_asignar from authenticated;
grant select (id, externo_id, motivo, estado, fecha, inicio_at, titulo, tipo, duracion_min, grabacion_url,
              grabacion_share_url, resumen, en_que_esta, proximos_pasos, action_items, invitados, candidatos,
              programa_id, cliente_id, llamada_id, resuelta_at, resuelta_por, created_at, updated_at, consultor)
  on public.cs_fathom_sin_asignar to authenticated;

-- cs_fathom_gestor (122) deja de usarse en politicas; se conserva por si la 122 se vuelve a correr.


-- =====================================================================
-- E. Funciones
-- =====================================================================

-- E1. cs_fathom_aplicar: igual que la 122 + consultor + respeta "no es alumno" cuando viene de la sync.
--   p suma: consultor (id), origen ('sync' | otro)
create or replace function public.cs_fathom_aplicar(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_ext    text := nullif(btrim(p->>'externo_id'), '');
  v_cli    uuid := nullif(p->>'cliente_id', '')::uuid;
  v_inicio timestamptz := nullif(p->>'inicio_at', '')::timestamptz;
  v_fecha  date;
  v_cons   text := nullif(btrim(coalesce(p->>'consultor', '')), '');
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
  if v_cons is not null and not exists (select 1 from public.cs_fathom_consultores where id = v_cons) then
    raise exception 'cs: consultor inexistente: %', v_cons using errcode = '22023';
  end if;
  v_fecha := least((v_inicio at time zone 'America/Argentina/Buenos_Aires')::date, public.cs_hoy());

  -- Lo que alguien marco "no es alumno" no lo vuelve a asignar la sync (solo una asignacion a mano).
  if p->>'origen' = 'sync' and v_cli is not null
     and exists (select 1 from public.cs_fathom_sin_asignar s where s.externo_id = v_ext and s.estado = 'no_alumno')
     and not exists (select 1 from public.cs_llamadas l where l.externo_id = v_ext) then
    return jsonb_build_object('resultado', 'sin_asignar', 'llamada_id', null);
  end if;

  -- 1. ya existe por id externo: se completa lo que falta, nunca se pisa
  select l.id, l.cliente_id into v_ll, v_cli_ll from public.cs_llamadas l where l.externo_id = v_ext;
  if found then
    update public.cs_llamadas set
      consultor = coalesce(consultor, v_cons),
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
        consultor = coalesce(consultor, v_cons),
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
                                      resumen, en_que_esta, proximos_pasos, fathom_sync_at, consultor)
      values (v_prog, v_cli, v_fecha, v_titulo, v_ext, 'fathom', v_tipo,
              v_dur, v_url, v_share, v_inicio, v_res_txt, v_est, v_prox, now(), v_cons)
      returning id into v_ll;
      v_res := 'creada';
    end if;

  -- 3. sin alumno: queda pendiente (o no_alumno si ya la marcaron) para asignar a mano
  else
    v_motivo := case when p->>'motivo' = 'varios_alumnos' then 'varios_alumnos' else 'sin_alumno' end;
    select coalesce(array_agg(x::uuid), '{}') into v_cand
    from jsonb_array_elements_text(
           case when jsonb_typeof(p->'candidatos') = 'array' then p->'candidatos' else '[]'::jsonb end) x;
    insert into public.cs_fathom_sin_asignar as s (
      externo_id, motivo, fecha, inicio_at, titulo, tipo, duracion_min, grabacion_url, grabacion_share_url,
      resumen, en_que_esta, proximos_pasos, transcripcion, action_items, invitados, candidatos, consultor)
    values (
      v_ext, v_motivo, v_fecha, v_inicio, v_titulo, v_tipo, v_dur, v_url, v_share,
      v_res_txt, v_est, v_prox, v_transc,
      case when jsonb_typeof(p->'action_items') = 'array' then p->'action_items' else '[]'::jsonb end,
      case when jsonb_typeof(p->'invitados') = 'array' then p->'invitados' else '[]'::jsonb end,
      v_cand, v_cons)
    on conflict (externo_id) do update set
      motivo = excluded.motivo, fecha = excluded.fecha, inicio_at = excluded.inicio_at,
      titulo = excluded.titulo, tipo = excluded.tipo, duracion_min = excluded.duracion_min,
      grabacion_url = excluded.grabacion_url, grabacion_share_url = excluded.grabacion_share_url,
      resumen = excluded.resumen, en_que_esta = excluded.en_que_esta, proximos_pasos = excluded.proximos_pasos,
      transcripcion = excluded.transcripcion, action_items = excluded.action_items,
      invitados = excluded.invitados, candidatos = excluded.candidatos,
      consultor = coalesce(s.consultor, excluded.consultor)
    where s.estado in ('pendiente', 'no_alumno');
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

  -- Si estaba en la lista (pendiente o no_alumno), queda resuelta y sin transcripcion propia
  update public.cs_fathom_sin_asignar s
  set estado = 'asignada', cliente_id = v_cli, programa_id = v_prog, llamada_id = v_ll,
      transcripcion = null,
      resuelta_at = coalesce(s.resuelta_at, now()), resuelta_por = coalesce(s.resuelta_por, auth.uid())
  where s.externo_id = v_ext and s.estado in ('pendiente', 'no_alumno');

  return jsonb_build_object('resultado', v_res, 'llamada_id', v_ll);
end;
$fn$;
revoke all on function public.cs_fathom_aplicar(jsonb) from public, anon, authenticated;


-- E2. cs_fathom_asignar: pendiente / no_alumno -> llamada de un alumno.
--   Permiso: fundador, cliente del programa del alumno, o edicion en ese programa.
create or replace function public.cs_fathom_asignar(p_id uuid, p_cliente uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_row  public.cs_fathom_sin_asignar%rowtype;
  v_prog text;
begin
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: el alumno no existe' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_asignar(v_prog) then
    raise exception 'cs: no tenes permiso para asignar llamadas a alumnos de ese programa' using errcode = '42501';
  end if;
  select * into v_row from public.cs_fathom_sin_asignar where id = p_id for update;
  if not found then
    raise exception 'cs: la llamada no existe' using errcode = '22023';
  end if;
  if v_row.estado = 'asignada' then
    raise exception 'cs: esa llamada ya fue asignada' using errcode = '22023';
  end if;
  return public.cs_fathom_aplicar(jsonb_build_object(
    'externo_id', v_row.externo_id, 'cliente_id', p_cliente, 'consultor', v_row.consultor,
    'inicio_at', coalesce(v_row.inicio_at, v_row.fecha::timestamptz),
    'titulo', v_row.titulo, 'tipo', v_row.tipo, 'duracion_min', v_row.duracion_min,
    'grabacion_url', v_row.grabacion_url, 'grabacion_share_url', v_row.grabacion_share_url,
    'resumen', v_row.resumen, 'en_que_esta', v_row.en_que_esta, 'proximos_pasos', v_row.proximos_pasos,
    'transcripcion', v_row.transcripcion, 'action_items', v_row.action_items));
end;
$fn$;
revoke all on function public.cs_fathom_asignar(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_asignar(uuid, uuid) to authenticated;


-- E3. Marcar "no es alumno" y deshacerlo: fundador y cliente (los que ven esas llamadas).
create or replace function public.cs_fathom_marcar_no_alumno(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  if not public.cs_fathom_ve_privadas() then
    raise exception 'cs: solo el fundador o el cliente marcan llamadas como "no es alumno"' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'no_alumno', resuelta_at = now(), resuelta_por = auth.uid()
  where id = p_id and estado = 'pendiente';
  if not found then
    raise exception 'cs: la llamada no existe o ya no esta pendiente' using errcode = '22023';
  end if;
end;
$fn$;
revoke all on function public.cs_fathom_marcar_no_alumno(uuid) from public, anon;
grant execute on function public.cs_fathom_marcar_no_alumno(uuid) to authenticated;

create or replace function public.cs_fathom_reabrir(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  if not public.cs_fathom_ve_privadas() then
    raise exception 'cs: solo el fundador o el cliente reabren llamadas' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'pendiente', resuelta_at = null, resuelta_por = null
  where id = p_id and estado = 'no_alumno';
  if not found then
    raise exception 'cs: la llamada no existe o no esta marcada como "no es alumno"' using errcode = '22023';
  end if;
end;
$fn$;
revoke all on function public.cs_fathom_reabrir(uuid) from public, anon;
grant execute on function public.cs_fathom_reabrir(uuid) to authenticated;

drop function if exists public.cs_fathom_descartar(uuid);

-- E4. Programas habilitados (cs_fathom_config es solo del fundador): los necesita el cliente para
--     el buscador de "Asignar a alumno". Devuelve {} si no ve las llamadas privadas.
create or replace function public.cs_fathom_programas()
returns text[]
language sql stable security definer set search_path = public
as $$
  select case when public.cs_fathom_ve_privadas()
              then coalesce((select c.programas from public.cs_fathom_config c limit 1), '{}')
              else '{}'::text[] end
$$;
revoke all on function public.cs_fathom_programas() from public, anon;
grant execute on function public.cs_fathom_programas() to authenticated;


-- =====================================================================
-- Vista para la pantalla "Llamadas": alumno + pendiente + no_alumno, con la RLS de quien consulta
-- =====================================================================
create or replace view public.cs_v_fathom_llamadas with (security_invoker = true) as
select l.id, 'alumno'::text as estado, l.consultor, l.fecha, l.inicio_at, l.titulo, l.tipo, l.duracion_min,
       l.grabacion_url, l.grabacion_share_url, l.resumen, l.en_que_esta, l.proximos_pasos,
       l.cliente_id, l.programa_id, c.nombre as alumno_nombre,
       '[]'::jsonb as invitados, null::text as motivo, '{}'::uuid[] as candidatos
from public.cs_llamadas l
left join public.cs_clientes c on c.id = l.cliente_id
where l.fuente = 'fathom'
union all
select s.id, s.estado, s.consultor, s.fecha, s.inicio_at, s.titulo, s.tipo, s.duracion_min,
       s.grabacion_url, s.grabacion_share_url, s.resumen, s.en_que_esta, s.proximos_pasos,
       null::uuid, null::text, null::text,
       s.invitados, s.motivo, s.candidatos
from public.cs_fathom_sin_asignar s
where s.estado in ('pendiente', 'no_alumno');
revoke all on public.cs_v_fathom_llamadas from anon;
grant select on public.cs_v_fathom_llamadas to authenticated;

commit;


-- =====================================================================
-- ANTES DE ENCENDER (a mano, fuera de este archivo)
-- =====================================================================
--   1. Secretos de la funcion (Edge Functions > fathom-sync > Secrets). Nombres exactos:
--        FATHOM_API_KEY         (Joaco, ya cargado)
--        FATHOM_API_KEY_TEO     (Teo: User Settings > API Access de SU Fathom)
--        FATHOM_API_KEY_MARTU   (Martu, idem)
--      Mientras un secreto no exista, la funcion saltea a ese consultor sin error.
--   2. Redesplegar:  supabase functions deploy fathom-sync --no-verify-jwt
--   3. "Sincronizar Fathom ahora" (Configuracion) y revisar el resultado por consultor.
--   Sumar un consultor: Configuracion > Llamadas de Fathom > Agregar cuenta (o un insert en
--   cs_fathom_consultores; el secreto tiene que llamarse FATHOM_API_KEY_<ALGO>).


-- =====================================================================
-- CONTROLES (de a uno, despues de correr la migracion)
-- =====================================================================

-- C1. Consultores sembrados. Esperado: 3 filas (joaco, teo, martu), activo = true;
--     secreto FATHOM_API_KEY / FATHOM_API_KEY_TEO / FATHOM_API_KEY_MARTU.
-- select id, nombre, secreto, activo, ultima_sync_ok_at is not null as sync_previa from public.cs_fathom_consultores order by orden;

-- C2. Backfill. Esperado: 0 llamadas de Fathom sin consultor, 0 sin asignar sin consultor,
--     y las 4 filas que habia siguen ahi (estado pendiente, consultor joaco).
-- select (select count(*) from public.cs_llamadas where fuente = 'fathom' and consultor is null) as llamadas_sin_consultor,
--        (select count(*) from public.cs_fathom_sin_asignar where consultor is null) as sin_asignar_sin_consultor;
-- select estado, consultor, count(*) from public.cs_fathom_sin_asignar group by 1, 2 order by 1, 2;

-- C3. Estados validos y que ya no queda 'descartada'. Esperado: 0 filas.
-- select estado, count(*) from public.cs_fathom_sin_asignar where estado not in ('pendiente','asignada','no_alumno') group by 1;

-- C4. Politicas y RLS. Esperado: sin_asignar = cs_privadas_select (1); consultores = cs_select,
--     cs_fundador_insert, cs_fundador_update; rls = true en ambas.
-- select c.relname, c.relrowsecurity as rls,
--        (select string_agg(p.polname, ', ' order by p.polname) from pg_policy p where p.polrelid = c.oid) as politicas
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace and c.relname in ('cs_fathom_sin_asignar', 'cs_fathom_consultores');

-- C5. La transcripcion no sale por la API. Esperado: false, false, true (la service role la lee).
-- select has_column_privilege('authenticated', 'public.cs_fathom_sin_asignar', 'transcripcion', 'select') as authenticated,
--        has_column_privilege('anon', 'public.cs_fathom_sin_asignar', 'transcripcion', 'select') as anon,
--        has_column_privilege('service_role', 'public.cs_fathom_sin_asignar', 'transcripcion', 'select') as service_role;

-- C6. QUIEN VE LAS PENDIENTE / NO_ALUMNO (la tabla de permisos real, por usuario).
--     Esperado: fundador = true; el rol 'cliente' con acceso a un programa habilitado = true;
--     producto@ (CSM, edicion) = false; ventas/finanzas/contenido = false.
-- select u.email, m.rol,
--        public.cs_fathom_ve_privadas_de(u.id) as ve_pendientes_y_no_alumno,
--        (select string_agg(a.programa_id || ':' || a.nivel, ', ') from public.cs_accesos a where a.user_id = u.id) as accesos
-- from public.crm_members m join auth.users u on u.id = m.user_id
-- order by 2, 1;

-- C7. Quien ejecuta las funciones. Esperado: aplicar y los *_de / es_cliente_de sin ningun rol de la app;
--     registrar solo service_role; asignar, marcar_no_alumno, reabrir, ve_privadas, puede_asignar: authenticated;
--     descartar no existe.
-- select p.proname,
--        has_function_privilege('anon', p.oid, 'execute') as anon,
--        has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
-- from pg_proc p
-- where p.pronamespace = 'public'::regnamespace
--   and p.proname in ('cs_fathom_aplicar', 'cs_fathom_registrar', 'cs_fathom_asignar', 'cs_fathom_marcar_no_alumno',
--                     'cs_fathom_reabrir', 'cs_fathom_ve_privadas', 'cs_fathom_ve_privadas_de', 'cs_fathom_es_cliente_de',
--                     'cs_fathom_puede_asignar', 'cs_fathom_programas', 'cs_fathom_descartar')
-- order by 1;

-- C8. La vista junta bien. Esperado: filas por estado y consultor (alumno, pendiente, no_alumno).
--     Corrida como postgres ve todo; en la app cada rol ve lo que su RLS deja.
-- select estado, consultor, count(*) from public.cs_v_fathom_llamadas group by 1, 2 order by 2, 1;

-- C9. HUMO (se revierte solo: termina en error "HUMO OK: N comprobaciones"). Usa un alumno real
--     para colgarle datos de prueba y los deshace. Hace de fundador con set_config.
-- do $$
-- declare
--   v_cli uuid; v_fund uuid; v_n int := 0; v_r jsonb; v_cnt int; v_est text;
--   v_sa uuid; v_hoy date := public.cs_hoy();
-- begin
--   select id into v_cli from public.cs_clientes order by created_at limit 1;
--   if v_cli is null then raise exception 'sin alumnos para probar'; end if;
--   select user_id into v_fund from public.crm_members where rol = 'fundador' limit 1;
--   if v_fund is null then raise exception 'sin fundador en crm_members'; end if;
--   -- 1. sin alumno: queda pendiente con su consultor
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-124a','inicio_at', now(),
--     'consultor','teo','origen','sync','invitados','["x@y.com"]','transcripcion','texto privado'));
--   if v_r->>'resultado' <> 'sin_asignar' then raise exception 'esperaba sin_asignar, vino %', v_r; end if;
--   select id, estado into v_sa, v_est from public.cs_fathom_sin_asignar where externo_id = 'fathom:humo-124a' and consultor = 'teo';
--   if v_est <> 'pendiente' then raise exception 'esperaba pendiente, hay %', v_est; end if;
--   v_n := v_n + 2;
--   -- 2. como fundador: marcar no_alumno, reabrir, marcar de nuevo
--   perform set_config('request.jwt.claim.sub', v_fund::text, true);
--   perform set_config('request.jwt.claims', json_build_object('sub', v_fund, 'role', 'authenticated')::text, true);
--   if not public.cs_fathom_ve_privadas() then raise exception 'el fundador deberia ver privadas'; end if;
--   perform public.cs_fathom_marcar_no_alumno(v_sa);
--   select estado into v_est from public.cs_fathom_sin_asignar where id = v_sa;
--   if v_est <> 'no_alumno' then raise exception 'no quedo no_alumno: %', v_est; end if;
--   perform public.cs_fathom_reabrir(v_sa);
--   perform public.cs_fathom_marcar_no_alumno(v_sa);
--   v_n := v_n + 3;
--   -- 3. la sync NO reasigna una no_alumno aunque ahora matchee un alumno
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-124a','cliente_id', v_cli,
--     'inicio_at', now(), 'consultor','teo','origen','sync'));
--   if v_r->>'resultado' <> 'sin_asignar' then raise exception 'la sync reasigno una no_alumno: %', v_r; end if;
--   select count(*) into v_cnt from public.cs_llamadas where externo_id = 'fathom:humo-124a';
--   if v_cnt <> 0 then raise exception 'se creo una llamada'; end if;
--   v_n := v_n + 2;
--   -- 4. asignar a mano: crea la llamada con el consultor, pasa la transcripcion y borra la copia privada
--   v_r := public.cs_fathom_asignar(v_sa, v_cli);
--   if v_r->>'resultado' <> 'creada' then raise exception 'esperaba creada, vino %', v_r; end if;
--   select count(*) into v_cnt from public.cs_llamadas where externo_id = 'fathom:humo-124a' and consultor = 'teo' and fuente = 'fathom';
--   if v_cnt <> 1 then raise exception 'la llamada no quedo con consultor teo'; end if;
--   select count(*) into v_cnt from public.cs_llamada_transcripciones where llamada_id = (v_r->>'llamada_id')::uuid;
--   if v_cnt <> 1 then raise exception 'la transcripcion no paso a la ficha'; end if;
--   select count(*) into v_cnt from public.cs_fathom_sin_asignar where id = v_sa and estado = 'asignada' and transcripcion is null;
--   if v_cnt <> 1 then raise exception 'la fila no quedo asignada y sin transcripcion'; end if;
--   v_n := v_n + 3;
--   -- 5. una asignada ya no se puede marcar ni reasignar
--   begin
--     perform public.cs_fathom_marcar_no_alumno(v_sa);
--     raise exception 'dejo marcar una asignada';
--   exception when sqlstate '22023' then v_n := v_n + 1; end;
--   -- 6. sin sesion no se asigna ni se marca
--   perform set_config('request.jwt.claim.sub', '', true);
--   perform set_config('request.jwt.claims', '', true);
--   begin
--     perform public.cs_fathom_asignar(v_sa, v_cli);
--     raise exception 'asigno sin permiso';
--   exception when sqlstate '42501' then v_n := v_n + 1; end;
--   raise exception 'HUMO OK: % comprobaciones', v_n;
-- end $$;

-- C10. Despues de "Sincronizar ahora" (informativo): resultado por consultor.
-- select id, ultimo_at, ultimo_estado, ultimo_resumen from public.cs_fathom_consultores order by orden;
-- select id, inicio, estado, traidas, sin_asignar, ignoradas, errores, por_consultor from public.cs_fathom_corridas order by inicio desc limit 3;


-- =====================================================================
-- VUELTA ATRAS (comentada). Pierde la columna consultor y el desglose por corrida.
-- Despues, volver a correr la 122 (es idempotente) restaura cs_fathom_aplicar/asignar/descartar
-- y la politica cs_gestor_select de la 122.
-- =====================================================================
-- begin;
-- drop view if exists public.cs_v_fathom_llamadas;
-- drop function if exists public.cs_fathom_programas();
-- drop function if exists public.cs_fathom_reabrir(uuid);
-- drop function if exists public.cs_fathom_marcar_no_alumno(uuid);
-- drop policy if exists cs_privadas_select on public.cs_fathom_sin_asignar;
-- grant select on table public.cs_fathom_sin_asignar to authenticated;   -- vuelve el permiso de tabla entera
-- drop function if exists public.cs_fathom_puede_asignar(text);
-- drop function if exists public.cs_fathom_ve_privadas();
-- drop function if exists public.cs_fathom_ve_privadas_de(uuid);
-- drop function if exists public.cs_fathom_es_cliente_de(uuid, text);
-- alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_124;
-- update public.cs_fathom_sin_asignar set estado = 'descartada' where estado = 'no_alumno';
-- alter table public.cs_fathom_sin_asignar add constraint cs_fathom_sin_asignar_estado_check
--   check (estado in ('pendiente', 'asignada', 'descartada'));
-- alter table public.cs_fathom_sin_asignar drop column if exists consultor;
-- alter table public.cs_llamadas drop column if exists consultor;
-- alter table public.cs_fathom_corridas drop column if exists por_consultor;
-- drop table if exists public.cs_fathom_consultores;
-- drop function if exists public.cs_tg_fathom_consultores_before();
-- commit;
-- -- y volver a correr migraciones/122-producto-fathom-sync.sql
