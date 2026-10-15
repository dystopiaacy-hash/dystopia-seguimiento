-- =====================================================================
-- 126-producto-fathom-asignacion-inteligente.sql  ·  PRODUCTO: Fathom, mails multiples por
-- alumno, aprendizaje, match por nombre y rol consultor
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), primero en el banco de pruebas.
-- Numeracion global asignada por el jefe: 126. Requiere la 124 (y por lo tanto la 122, 106 y 102).
-- Evitar :00, :15, :30, :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- La Edge Function (supabase/functions/fathom-sync) se despliega DESPUES de correr esto.
--
-- Que hace:
--   A. cs_clientes_mails: mails EXTRA de un alumno (ademas de cs_clientes.email). El match de la
--      sincronizacion busca en el principal + extras. Origen: manual | aprendido | importado.
--   B. Aprende: cuando alguien asigna a mano una llamada a un alumno (cs_fathom_asignar,
--      cs_fathom_corregir, cs_fathom_confirmar), los mails de los invitados externos de esa llamada
--      pasan a ser mails extra del alumno, salvo los que ya son de OTRO alumno. La proxima llamada
--      con ese mail se asigna sola.
--   C. Match por nombre (lo hace la Edge Function como respaldo del mail): la llamada queda
--      asignada con cs_llamadas.asignada_por = 'nombre' (visible en la pantalla, con "Confirmar"
--      y "Corregir"). Si hay mas de un candidato o dudas, queda pendiente con los candidatos.
--      cs_llamadas.asignada_por: mail | nombre | manual. cs_llamadas.invitados: mails externos.
--   D. Rol consultor: cs_fathom_consultores.email_login (mail con el que el consultor entra a la
--      app). El consultor ve y asigna SUS llamadas (pendientes y no_alumno incluidas), ademas del
--      fundador y del cliente. Si el usuario no existe todavia, no pasa nada: la fila queda con el
--      mail y se activa sola cuando el usuario se crea. email_login NO lo lee la app salvo el
--      fundador (permiso de columna + cs_fathom_logins()).
--   E. Corregir una llamada ya asignada: cs_fathom_corregir(llamada, alumno) la pasa a otro alumno
--      (o a pendiente con alumno null). Una llamada no cambia de alumno (trigger de la 102): se
--      reconstruye. No se corrige si tiene accionables hechos, subtareas, accionables a mano o
--      recursos colgados: se avisa y se arregla a mano.
--   F. La sincronizacion no reasigna una llamada que alguien devolvio a pendiente
--      (cs_fathom_sin_asignar.no_auto).
--   G. Vista cs_v_fathom_llamadas: ahora filtra por funciones (fundador, cliente, quien ve el
--      programa, o el consultor de la llamada). Corre como su dueno, por eso el filtro va adentro.
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
    raise exception 'cs 126: hace falta Postgres 15 o mas';
  end if;
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_clientes', 'cs_llamadas', 'cs_llamada_accionables',
                    'cs_llamada_transcripciones', 'cs_llamada_recursos', 'cs_accesos', 'cs_fathom_config',
                    'cs_fathom_sin_asignar', 'cs_fathom_consultores', 'crm_members']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception 'cs 126: faltan tablas (corrio la 124?): %', v_falta;
  end if;
  select string_agg(r.f, ', ') into v_falta
  from (values ('es_fundador()'), ('cs_hoy()'), ('cs_tg_updated_at()'), ('cs_puede_editar(text)'),
               ('cs_puede_ver(text)'), ('cs_fathom_aplicar(jsonb)'), ('cs_fathom_registrar(jsonb)'),
               ('cs_fathom_ve_privadas()'), ('cs_fathom_ve_privadas_de(uuid)'),
               ('cs_fathom_es_cliente_de(uuid, text)'), ('cs_fathom_puede_asignar(text)')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 126: faltan funciones de la 124: %', v_falta;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_llamadas' and column_name = 'consultor') then
    raise exception 'cs 126: cs_llamadas no tiene la columna consultor (124)';
  end if;
end $$;

-- Lock de todo lo que se altera, junto (regla del deadlock).
lock table public.cs_clientes, public.cs_llamadas, public.cs_llamada_accionables,
           public.cs_llamada_transcripciones, public.cs_llamada_recursos,
           public.cs_fathom_sin_asignar, public.cs_fathom_consultores
  in share row exclusive mode;


-- =====================================================================
-- A. Mails extra por alumno
-- =====================================================================
create table if not exists public.cs_clientes_mails (
  id                 uuid primary key default gen_random_uuid(),
  cliente_id         uuid not null,
  programa_id        text not null references public.cs_programas(id),
  email              text not null
                     check (email = lower(btrim(email)) and char_length(email) <= 200
                            and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  origen             text not null default 'manual' check (origen in ('manual', 'aprendido', 'importado')),
  llamada_externo_id text,           -- llamada de Fathom de la que se aprendio (para deshacerlo al corregir)
  created_at         timestamptz not null default now(),
  created_by         uuid default auth.uid(),
  constraint cs_clientes_mails_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  constraint cs_clientes_mails_uk unique (cliente_id, email)
);
create index if not exists cs_clientes_mails_email_idx on public.cs_clientes_mails (email);
create index if not exists cs_clientes_mails_programa_idx on public.cs_clientes_mails (programa_id);
comment on table public.cs_clientes_mails is
  'Mails extra de un alumno (126), ademas de cs_clientes.email. El match de fathom-sync busca en el principal y en estos. Se escriben por funcion (aprendido o a mano).';

alter table public.cs_clientes_mails enable row level security;
revoke all on table public.cs_clientes_mails from anon, authenticated;
grant select on table public.cs_clientes_mails to authenticated;
grant select on table public.cs_clientes_mails to service_role;
drop policy if exists cs_select on public.cs_clientes_mails;
create policy cs_select on public.cs_clientes_mails for select to authenticated
  using (coalesce(public.cs_puede_ver(programa_id), false));


-- =====================================================================
-- B. Columnas nuevas
-- =====================================================================
alter table public.cs_llamadas add column if not exists asignada_por text;
alter table public.cs_llamadas drop constraint if exists cs_llamadas_asignada_por_chk;
alter table public.cs_llamadas add constraint cs_llamadas_asignada_por_chk
  check (asignada_por is null or asignada_por in ('mail', 'nombre', 'manual'));
alter table public.cs_llamadas add column if not exists invitados jsonb not null default '[]'::jsonb;
alter table public.cs_llamadas drop constraint if exists cs_llamadas_invitados_chk;
alter table public.cs_llamadas add constraint cs_llamadas_invitados_chk check (jsonb_typeof(invitados) = 'array');
comment on column public.cs_llamadas.asignada_por is
  '126: como se asigno la llamada de Fathom al alumno: mail (sync), nombre (sync por nombre, a confirmar) o manual.';
comment on column public.cs_llamadas.invitados is
  '126: mails de los invitados externos de la reunion de Fathom (sin quien grabo). Sirve para aprender mails al confirmar o corregir.';

alter table public.cs_fathom_sin_asignar add column if not exists no_auto boolean not null default false;
comment on column public.cs_fathom_sin_asignar.no_auto is
  '126: true = alguien devolvio la llamada a pendiente al corregirla; la sincronizacion no la vuelve a asignar sola.';

alter table public.cs_fathom_consultores add column if not exists email_login text;
alter table public.cs_fathom_consultores drop constraint if exists cs_fathom_consultores_email_login_chk;
alter table public.cs_fathom_consultores add constraint cs_fathom_consultores_email_login_chk
  check (email_login is null or (email_login = lower(btrim(email_login)) and char_length(email_login) <= 200
                                 and email_login ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'));
comment on column public.cs_fathom_consultores.email_login is
  '126: mail con el que el consultor entra a la app (auth.users.email). Null o sin usuario = el consultor no tiene permisos propios todavia. Solo lo lee el fundador.';

-- email_login no sale por la API para los demas roles (permiso de columna). El fundador lo lee con
-- cs_fathom_logins() y lo escribe con cs_fathom_login_guardar().
revoke select on table public.cs_fathom_consultores from authenticated;
grant select (id, nombre, secreto, activo, orden, ultimo_at, ultimo_estado, ultimo_resumen,
              ultima_sync_ok_at, created_at, updated_at)
  on public.cs_fathom_consultores to authenticated;

-- Backfill de lo que ya entro desde Fathom.
update public.cs_llamadas l
set asignada_por = case when exists (select 1 from public.cs_fathom_sin_asignar s where s.llamada_id = l.id)
                        then 'manual' else 'mail' end
where l.fuente = 'fathom' and l.asignada_por is null;

update public.cs_llamadas l
set invitados = s.invitados
from public.cs_fathom_sin_asignar s
where s.llamada_id = l.id and l.fuente = 'fathom' and l.invitados = '[]'::jsonb
  and jsonb_typeof(s.invitados) = 'array' and s.invitados <> '[]'::jsonb;


-- =====================================================================
-- C. Helpers de permisos (rol consultor)
-- =====================================================================
create or replace function public.cs_fathom_es_consultor_de(p_uid uuid, p_consultor text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select p_uid is not null and p_consultor is not null and exists (
    select 1
    from public.cs_fathom_consultores c
    join auth.users u on lower(u.email) = c.email_login
    where c.id = p_consultor and c.email_login is not null and u.id = p_uid)
$$;
revoke all on function public.cs_fathom_es_consultor_de(uuid, text) from public, anon, authenticated;

create or replace function public.cs_fathom_es_consultor(p_consultor text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.cs_fathom_es_consultor_de(auth.uid(), p_consultor), false)
$$;
revoke all on function public.cs_fathom_es_consultor(text) from public, anon;
grant execute on function public.cs_fathom_es_consultor(text) to authenticated;

create or replace function public.cs_fathom_es_consultor_alguno()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.cs_fathom_consultores c
    join auth.users u on lower(u.email) = c.email_login
    where c.email_login is not null and u.id = auth.uid())
$$;
revoke all on function public.cs_fathom_es_consultor_alguno() from public, anon;
grant execute on function public.cs_fathom_es_consultor_alguno() to authenticated;

-- Programas habilitados en la config (los usa mas de una funcion).
create or replace function public.cs_fathom_programas_cfg()
returns text[]
language sql stable security definer set search_path = public
as $$
  select coalesce((select c.programas from public.cs_fathom_config c limit 1), '{}'::text[])
$$;
revoke all on function public.cs_fathom_programas_cfg() from public, anon, authenticated;

-- Puede gestionar una llamada pendiente / no_alumno: fundador, cliente, o el consultor de la llamada.
create or replace function public.cs_fathom_puede_gestionar(p_consultor text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor(p_consultor)
$$;
revoke all on function public.cs_fathom_puede_gestionar(text) from public, anon;
grant execute on function public.cs_fathom_puede_gestionar(text) to authenticated;

-- Puede asignar / corregir / confirmar hacia un alumno de ese programa: fundador, cliente del
-- programa, edicion en el programa, o el consultor de la llamada (solo programas habilitados).
create or replace function public.cs_fathom_puede_asignar_llamada(p_programa text, p_consultor text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.cs_fathom_puede_asignar(p_programa)
      or (public.cs_fathom_es_consultor(p_consultor)
          and p_programa = any (public.cs_fathom_programas_cfg()))
$$;
revoke all on function public.cs_fathom_puede_asignar_llamada(text, text) from public, anon;
grant execute on function public.cs_fathom_puede_asignar_llamada(text, text) to authenticated;


-- RLS de cs_fathom_sin_asignar: fundador, cliente o el consultor de la llamada.
drop policy if exists cs_privadas_select on public.cs_fathom_sin_asignar;
create policy cs_privadas_select on public.cs_fathom_sin_asignar for select to authenticated
  using (public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor(consultor));


-- =====================================================================
-- D. Aprender mails
-- =====================================================================
-- Interna. Guarda como mails extra del alumno los mails externos de la llamada, salvo el principal
-- y los que son de OTRO alumno (principal o extra, de cualquier programa). Devuelve cuantos guardo.
create or replace function public.cs_fathom_aprender(p_cliente uuid, p_invitados jsonb, p_externo text)
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog text;
  v_pri  text;
  v_n    int := 0;
  v_m    text;
begin
  select c.programa_id, lower(btrim(c.email)) into v_prog, v_pri
  from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null or jsonb_typeof(p_invitados) is distinct from 'array' then
    return 0;
  end if;
  for v_m in
    select distinct lower(btrim(x)) from jsonb_array_elements_text(p_invitados) x
  loop
    continue when v_m !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_m) > 200;
    continue when v_m = coalesce(v_pri, '');
    continue when exists (select 1 from public.cs_clientes o
                          where o.id <> p_cliente and lower(btrim(o.email)) = v_m);
    continue when exists (select 1 from public.cs_clientes_mails e
                          where e.cliente_id <> p_cliente and e.email = v_m);
    insert into public.cs_clientes_mails (cliente_id, programa_id, email, origen, llamada_externo_id)
    values (p_cliente, v_prog, v_m, 'aprendido', p_externo)
    on conflict (cliente_id, email) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end;
$fn$;
revoke all on function public.cs_fathom_aprender(uuid, jsonb, text) from public, anon, authenticated;


-- =====================================================================
-- E. cs_fathom_aplicar (reemplaza la de la 124)
--   Suma: invitados y asignada_por en la llamada, aprender (origen 'manual'), hash de action item
--   conservado, y respeta no_auto ademas de no_alumno cuando viene de la sync.
--   p suma: asignada_por ('mail' | 'nombre', solo origen sync), invitados (mails).
-- =====================================================================
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
  v_manual boolean := coalesce(p->>'origen', '') = 'manual';
  v_asig   text := case when v_manual then 'manual'
                        when p->>'asignada_por' = 'nombre' then 'nombre' else 'mail' end;
  v_inv    jsonb;
  v_prog   text;
  v_ll     uuid;
  v_cli_ll uuid;
  v_res    text;
  v_it     jsonb;
  v_desc   text;
  v_texto  text;
  v_hash   text;
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

  -- mails externos validos, en minusculas y sin repetir
  select coalesce(jsonb_agg(m order by m), '[]'::jsonb) into v_inv
  from (select distinct lower(btrim(x)) as m
        from jsonb_array_elements_text(
               case when jsonb_typeof(p->'invitados') = 'array' then p->'invitados' else '[]'::jsonb end) x
        where lower(btrim(x)) ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(btrim(x)) <= 200) t;

  -- Lo que alguien marco "no es alumno", o devolvio a pendiente al corregirlo, no lo reasigna la sync.
  if p->>'origen' = 'sync' and v_cli is not null
     and exists (select 1 from public.cs_fathom_sin_asignar s
                 where s.externo_id = v_ext and (s.estado = 'no_alumno' or (s.estado = 'pendiente' and s.no_auto)))
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
      invitados = case when invitados = '[]'::jsonb then v_inv else invitados end,
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
        asignada_por = v_asig,
        invitados = v_inv,
        fathom_sync_at = now()
      where id = v_ll;
      v_res := 'vinculada';
    else
      insert into public.cs_llamadas (programa_id, cliente_id, fecha, titulo, externo_id, fuente, tipo,
                                      duracion_min, grabacion_url, grabacion_share_url, inicio_at,
                                      resumen, en_que_esta, proximos_pasos, fathom_sync_at, consultor,
                                      asignada_por, invitados)
      values (v_prog, v_cli, v_fecha, v_titulo, v_ext, 'fathom', v_tipo,
              v_dur, v_url, v_share, v_inicio, v_res_txt, v_est, v_prox, now(), v_cons,
              v_asig, v_inv)
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
      v_inv, v_cand, v_cons)
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
      -- 'hash' lo trae cs_fathom_corregir: conserva el hash original para que la sync no duplique
      v_hash := case when (v_it->>'hash') ~ '^[0-9a-f]{32}$' then v_it->>'hash'
                     else md5(v_ext || '|' || lower(v_desc)) end;
      insert into public.cs_llamada_accionables (programa_id, cliente_id, llamada_id, texto, orden, externo_hash)
      values (v_prog, v_cli, v_ll, v_texto, v_orden, v_hash)
      on conflict (llamada_id, externo_hash) do nothing;
      v_orden := v_orden + 1;
    end loop;
  end if;

  -- Si estaba en la lista (pendiente o no_alumno), queda resuelta y sin transcripcion propia
  update public.cs_fathom_sin_asignar s
  set estado = 'asignada', cliente_id = v_cli, programa_id = v_prog, llamada_id = v_ll,
      transcripcion = null, no_auto = false,
      resuelta_at = coalesce(s.resuelta_at, now()), resuelta_por = coalesce(s.resuelta_por, auth.uid())
  where s.externo_id = v_ext and s.estado in ('pendiente', 'no_alumno');

  -- Aprende: una asignacion a mano convierte los mails de la llamada en mails del alumno.
  if v_manual then
    perform public.cs_fathom_aprender(v_cli, v_inv, v_ext);
  end if;

  return jsonb_build_object('resultado', v_res, 'llamada_id', v_ll);
end;
$fn$;
revoke all on function public.cs_fathom_aplicar(jsonb) from public, anon, authenticated;


-- =====================================================================
-- F. Funciones de la app
-- =====================================================================

-- F1. Asignar a mano una pendiente / no_alumno (reemplaza la de la 124).
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
  select * into v_row from public.cs_fathom_sin_asignar where id = p_id for update;
  if not found then
    raise exception 'cs: la llamada no existe' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_asignar_llamada(v_prog, v_row.consultor) then
    raise exception 'cs: no tenes permiso para asignar esa llamada a un alumno de ese programa' using errcode = '42501';
  end if;
  if v_row.estado = 'asignada' then
    raise exception 'cs: esa llamada ya fue asignada' using errcode = '22023';
  end if;
  return public.cs_fathom_aplicar(jsonb_build_object(
    'externo_id', v_row.externo_id, 'cliente_id', p_cliente, 'consultor', v_row.consultor, 'origen', 'manual',
    'inicio_at', coalesce(v_row.inicio_at, v_row.fecha::timestamptz),
    'titulo', v_row.titulo, 'tipo', v_row.tipo, 'duracion_min', v_row.duracion_min,
    'grabacion_url', v_row.grabacion_url, 'grabacion_share_url', v_row.grabacion_share_url,
    'resumen', v_row.resumen, 'en_que_esta', v_row.en_que_esta, 'proximos_pasos', v_row.proximos_pasos,
    'transcripcion', v_row.transcripcion, 'action_items', v_row.action_items,
    'invitados', v_row.invitados));
end;
$fn$;
revoke all on function public.cs_fathom_asignar(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_asignar(uuid, uuid) to authenticated;

-- F2. Marcar "no es alumno" / reabrir: fundador, cliente o el consultor de la llamada.
create or replace function public.cs_fathom_marcar_no_alumno(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_cons text;
begin
  select s.consultor into v_cons from public.cs_fathom_sin_asignar s where s.id = p_id and s.estado = 'pendiente';
  if not found then
    raise exception 'cs: la llamada no existe o ya no esta pendiente' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_gestionar(v_cons) then
    raise exception 'cs: solo el fundador, el cliente o el consultor de la llamada la marcan como "no es alumno"' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'no_alumno', resuelta_at = now(), resuelta_por = auth.uid()
  where id = p_id and estado = 'pendiente';
end;
$fn$;
revoke all on function public.cs_fathom_marcar_no_alumno(uuid) from public, anon;
grant execute on function public.cs_fathom_marcar_no_alumno(uuid) to authenticated;

create or replace function public.cs_fathom_reabrir(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_cons text;
begin
  select s.consultor into v_cons from public.cs_fathom_sin_asignar s where s.id = p_id and s.estado = 'no_alumno';
  if not found then
    raise exception 'cs: la llamada no existe o no esta marcada como "no es alumno"' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_gestionar(v_cons) then
    raise exception 'cs: solo el fundador, el cliente o el consultor de la llamada la reabren' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'pendiente', resuelta_at = null, resuelta_por = null
  where id = p_id and estado = 'no_alumno';
end;
$fn$;
revoke all on function public.cs_fathom_reabrir(uuid) from public, anon;
grant execute on function public.cs_fathom_reabrir(uuid) to authenticated;

-- F3. Programas habilitados (los ve quien ve las llamadas privadas o es consultor).
create or replace function public.cs_fathom_programas()
returns text[]
language sql stable security definer set search_path = public
as $$
  select case when public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor_alguno()
              then public.cs_fathom_programas_cfg() else '{}'::text[] end
$$;
revoke all on function public.cs_fathom_programas() from public, anon;
grant execute on function public.cs_fathom_programas() to authenticated;

-- F4. Alumnos a los que se puede asignar o corregir: solo id, programa, nombre y estado (sin mails ni
--     telefonos), de los programas habilitados. Para fundador, cliente, consultor o edicion en el programa.
create or replace function public.cs_fathom_alumnos()
returns table (id uuid, programa_id text, nombre text, estado text)
language sql stable security definer set search_path = public
as $$
  select c.id, c.programa_id, c.nombre, c.estado
  from public.cs_clientes c
  where c.programa_id = any (public.cs_fathom_programas_cfg())
    and (public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor_alguno()
         or coalesce(public.cs_puede_editar(c.programa_id), false))
  order by c.nombre
$$;
revoke all on function public.cs_fathom_alumnos() from public, anon;
grant execute on function public.cs_fathom_alumnos() to authenticated;

-- F5. Confirmar una llamada asignada por nombre: pasa a manual y aprende los mails.
create or replace function public.cs_fathom_confirmar(p_llamada uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_l public.cs_llamadas%rowtype;
begin
  select * into v_l from public.cs_llamadas where id = p_llamada and fuente = 'fathom' for update;
  if not found then
    raise exception 'cs: la llamada no existe' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_asignar_llamada(v_l.programa_id, v_l.consultor) then
    raise exception 'cs: no tenes permiso para confirmar esa llamada' using errcode = '42501';
  end if;
  update public.cs_llamadas set asignada_por = 'manual' where id = v_l.id;
  perform public.cs_fathom_aprender(v_l.cliente_id, v_l.invitados, v_l.externo_id);
end;
$fn$;
revoke all on function public.cs_fathom_confirmar(uuid) from public, anon;
grant execute on function public.cs_fathom_confirmar(uuid) to authenticated;

-- F6. Corregir: pasar una llamada ya asignada a OTRO alumno, o devolverla a pendiente (p_cliente null).
--     Una llamada no cambia de alumno (102): se guarda su contenido, se borra y se vuelve a crear.
create or replace function public.cs_fathom_corregir(p_llamada uuid, p_cliente uuid default null)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_l      public.cs_llamadas%rowtype;
  v_prog   text;
  v_items  jsonb;
  v_transc text;
  v_out    jsonb;
begin
  select * into v_l from public.cs_llamadas where id = p_llamada and fuente = 'fathom' for update;
  if not found or v_l.externo_id is null then
    raise exception 'cs: la llamada no existe o no viene de Fathom' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_asignar_llamada(v_l.programa_id, v_l.consultor) then
    raise exception 'cs: no tenes permiso para corregir esa llamada' using errcode = '42501';
  end if;
  if p_cliente is not null then
    if p_cliente = v_l.cliente_id then
      raise exception 'cs: la llamada ya es de ese alumno' using errcode = '22023';
    end if;
    select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
    if v_prog is null then
      raise exception 'cs: el alumno no existe' using errcode = '22023';
    end if;
    if not public.cs_fathom_puede_asignar_llamada(v_prog, v_l.consultor) then
      raise exception 'cs: no tenes permiso para asignar la llamada a un alumno de ese programa' using errcode = '42501';
    end if;
  end if;

  if exists (select 1 from public.cs_llamada_accionables a
             where a.llamada_id = v_l.id and (a.hecho or a.padre_id is not null or a.externo_hash is null))
     or exists (select 1 from public.cs_llamada_recursos r where r.llamada_id = v_l.id) then
    raise exception 'cs: la llamada ya tiene accionables hechos, subtareas, accionables o recursos cargados a mano: no se puede mover sola. Arreglalo a mano en la ficha.'
      using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('descripcion', a.texto, 'hash', a.externo_hash)
                            order by a.orden, a.created_at), '[]'::jsonb)
    into v_items
  from public.cs_llamada_accionables a where a.llamada_id = v_l.id;
  select t.texto into v_transc from public.cs_llamada_transcripciones t where t.llamada_id = v_l.id;

  -- lo aprendido de esta llamada para el alumno anterior se deshace
  delete from public.cs_clientes_mails
  where cliente_id = v_l.cliente_id and origen = 'aprendido' and llamada_externo_id = v_l.externo_id;

  delete from public.cs_llamadas where id = v_l.id;   -- cascade: accionables y transcripcion

  if p_cliente is null then
    insert into public.cs_fathom_sin_asignar as s (
      externo_id, motivo, estado, no_auto, fecha, inicio_at, titulo, tipo, duracion_min, grabacion_url,
      grabacion_share_url, resumen, en_que_esta, proximos_pasos, transcripcion, action_items, invitados,
      candidatos, consultor)
    values (v_l.externo_id, 'sin_alumno', 'pendiente', true, v_l.fecha, v_l.inicio_at, v_l.titulo, v_l.tipo,
            v_l.duracion_min, v_l.grabacion_url, v_l.grabacion_share_url, v_l.resumen, v_l.en_que_esta,
            v_l.proximos_pasos, v_transc, v_items, v_l.invitados, '{}', v_l.consultor)
    on conflict (externo_id) do update set
      estado = 'pendiente', no_auto = true, motivo = 'sin_alumno', transcripcion = excluded.transcripcion,
      action_items = excluded.action_items, invitados = excluded.invitados, candidatos = '{}',
      programa_id = null, cliente_id = null, llamada_id = null, resuelta_at = null, resuelta_por = null;
    return jsonb_build_object('resultado', 'pendiente', 'llamada_id', null);
  end if;

  v_out := public.cs_fathom_aplicar(jsonb_build_object(
    'externo_id', v_l.externo_id, 'cliente_id', p_cliente, 'consultor', v_l.consultor, 'origen', 'manual',
    'inicio_at', coalesce(v_l.inicio_at, v_l.fecha::timestamptz),
    'titulo', v_l.titulo, 'tipo', v_l.tipo, 'duracion_min', v_l.duracion_min,
    'grabacion_url', v_l.grabacion_url, 'grabacion_share_url', v_l.grabacion_share_url,
    'resumen', v_l.resumen, 'en_que_esta', v_l.en_que_esta, 'proximos_pasos', v_l.proximos_pasos,
    'transcripcion', v_transc, 'action_items', v_items, 'invitados', v_l.invitados));

  -- la fila de la lista (si la hubo) apunta ahora al alumno nuevo
  update public.cs_fathom_sin_asignar
  set cliente_id = p_cliente, programa_id = v_prog, llamada_id = (v_out->>'llamada_id')::uuid, estado = 'asignada'
  where externo_id = v_l.externo_id;
  return v_out;
end;
$fn$;
revoke all on function public.cs_fathom_corregir(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_corregir(uuid, uuid) to authenticated;

-- F7. Mails extra de un alumno a mano (quien edita el programa) y quitarlos.
create or replace function public.cs_cliente_mail_agregar(p_cliente uuid, p_email text)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog text;
  v_m    text := lower(btrim(coalesce(p_email, '')));
begin
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: el alumno no existe' using errcode = '22023';
  end if;
  if not coalesce(public.cs_puede_editar(v_prog), false) then
    raise exception 'cs: sin permiso de edicion en el programa' using errcode = '42501';
  end if;
  if v_m !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_m) > 200 then
    raise exception 'cs: el mail no es valido' using errcode = '22023';
  end if;
  insert into public.cs_clientes_mails (cliente_id, programa_id, email, origen)
  values (p_cliente, v_prog, v_m, 'manual')
  on conflict (cliente_id, email) do nothing;
end;
$fn$;
revoke all on function public.cs_cliente_mail_agregar(uuid, text) from public, anon;
grant execute on function public.cs_cliente_mail_agregar(uuid, text) to authenticated;

create or replace function public.cs_cliente_mail_quitar(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog text;
begin
  select m.programa_id into v_prog from public.cs_clientes_mails m where m.id = p_id;
  if v_prog is null then
    raise exception 'cs: el mail no existe' using errcode = '22023';
  end if;
  if not coalesce(public.cs_puede_editar(v_prog), false) then
    raise exception 'cs: sin permiso de edicion en el programa' using errcode = '42501';
  end if;
  delete from public.cs_clientes_mails where id = p_id;
end;
$fn$;
revoke all on function public.cs_cliente_mail_quitar(uuid) from public, anon;
grant execute on function public.cs_cliente_mail_quitar(uuid) to authenticated;

-- F8. Login del consultor (solo fundador).
create or replace function public.cs_fathom_logins()
returns table (consultor text, email_login text, usuario_existe boolean)
language sql stable security definer set search_path = public
as $$
  select c.id, c.email_login,
         (c.email_login is not null and exists (select 1 from auth.users u where lower(u.email) = c.email_login))
  from public.cs_fathom_consultores c
  where coalesce(public.es_fundador(), false)
  order by c.orden, c.id
$$;
revoke all on function public.cs_fathom_logins() from public, anon;
grant execute on function public.cs_fathom_logins() to authenticated;

create or replace function public.cs_fathom_login_guardar(p_consultor text, p_email text)
returns boolean
language plpgsql security definer set search_path = public
as $fn$
declare
  v_m text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador asigna el usuario de un consultor' using errcode = '42501';
  end if;
  if v_m is not null and (v_m !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_m) > 200) then
    raise exception 'cs: el mail no es valido' using errcode = '22023';
  end if;
  update public.cs_fathom_consultores set email_login = v_m where id = p_consultor;
  if not found then
    raise exception 'cs: el consultor no existe' using errcode = '22023';
  end if;
  return v_m is not null and exists (select 1 from auth.users u where lower(u.email) = v_m);
end;
$fn$;
revoke all on function public.cs_fathom_login_guardar(text, text) from public, anon;
grant execute on function public.cs_fathom_login_guardar(text, text) to authenticated;


-- =====================================================================
-- G. Vista para la pantalla "Llamadas"
-- =====================================================================
-- Corre como su dueno (no security_invoker): el consultor tiene que ver el nombre del alumno de SUS
-- llamadas aunque no tenga acceso al programa. El filtro va adentro, con funciones que leen auth.uid().
drop view if exists public.cs_v_fathom_llamadas;
create view public.cs_v_fathom_llamadas as
select l.id, 'alumno'::text as estado, l.consultor, l.fecha, l.inicio_at, l.titulo, l.tipo, l.duracion_min,
       l.grabacion_url, l.grabacion_share_url, l.resumen, l.en_que_esta, l.proximos_pasos,
       l.cliente_id, l.programa_id, c.nombre as alumno_nombre,
       l.invitados, null::text as motivo, '{}'::uuid[] as candidatos, l.asignada_por
from public.cs_llamadas l
left join public.cs_clientes c on c.id = l.cliente_id
where l.fuente = 'fathom'
  and (coalesce(public.cs_puede_ver(l.programa_id), false) or public.cs_fathom_es_consultor(l.consultor))
union all
select s.id, s.estado, s.consultor, s.fecha, s.inicio_at, s.titulo, s.tipo, s.duracion_min,
       s.grabacion_url, s.grabacion_share_url, s.resumen, s.en_que_esta, s.proximos_pasos,
       null::uuid, null::text, null::text,
       s.invitados, s.motivo, s.candidatos, null::text
from public.cs_fathom_sin_asignar s
where s.estado in ('pendiente', 'no_alumno')
  and (public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor(s.consultor));
revoke all on public.cs_v_fathom_llamadas from anon;
grant select on public.cs_v_fathom_llamadas to authenticated;

commit;


-- =====================================================================
-- DESPUES DE CORRER (a mano, fuera de este archivo)
-- =====================================================================
--   1. Mails de login de cada consultor (Configuracion > Llamadas de Fathom > "Usuario"), o por SQL:
--        select public.cs_fathom_login_guardar('teo', 'MAIL_DE_LOGIN_DE_TEO');   -- como fundador en la app
--      o directo (SQL Editor): update public.cs_fathom_consultores set email_login = 'mail@...' where id = 'teo';
--      Si el usuario todavia no existe, queda guardado y se activa cuando se cree.
--      Para que el consultor entre a la app necesita ademas su fila en cs_accesos (079) y crm_members.
--   2. Redesplegar:  supabase functions deploy fathom-sync --no-verify-jwt
--   3. "Sincronizar Fathom ahora" y mirar la pantalla Llamadas (etiqueta "por nombre").


-- =====================================================================
-- CONTROLES (de a uno, despues de correr la migracion)
-- =====================================================================

-- C1. Objetos nuevos. Esperado: tabla = true; columnas = 4 filas; 11 funciones; vista = true.
-- select to_regclass('public.cs_clientes_mails') is not null as tabla;
-- select table_name, column_name from information_schema.columns
-- where table_schema = 'public' and (table_name, column_name) in
--   (('cs_llamadas','asignada_por'), ('cs_llamadas','invitados'), ('cs_fathom_sin_asignar','no_auto'),
--    ('cs_fathom_consultores','email_login'));
-- select proname from pg_proc where pronamespace = 'public'::regnamespace and proname in
--   ('cs_fathom_aprender','cs_fathom_confirmar','cs_fathom_corregir','cs_fathom_alumnos','cs_fathom_logins',
--    'cs_fathom_login_guardar','cs_fathom_es_consultor','cs_fathom_es_consultor_alguno','cs_cliente_mail_agregar',
--    'cs_cliente_mail_quitar','cs_fathom_puede_asignar_llamada') order by 1;

-- C2. Backfill. Esperado: ninguna llamada de Fathom sin asignada_por.
-- select asignada_por, count(*) from public.cs_llamadas where fuente = 'fathom' group by 1 order by 1;

-- C3. email_login no lo lee la API (solo el fundador, por funcion). Esperado: false, false.
-- select has_column_privilege('authenticated', 'public.cs_fathom_consultores', 'email_login', 'select') as authenticated,
--        has_column_privilege('anon', 'public.cs_fathom_consultores', 'email_login', 'select') as anon;

-- C4. Consultores y su usuario. Esperado: email_login null hasta cargarlos; usuario_existe false.
-- select c.id, c.email_login,
--        c.email_login is not null and exists (select 1 from auth.users u where lower(u.email) = c.email_login) as usuario_existe
-- from public.cs_fathom_consultores c order by c.orden;

-- C5. Quien ejecuta las funciones. Esperado: aprender, aplicar, es_consultor_de y programas_cfg sin ningun rol
-- de la app; el resto authenticated.
-- select p.proname,
--        has_function_privilege('anon', p.oid, 'execute') as anon,
--        has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
-- from pg_proc p where p.pronamespace = 'public'::regnamespace
--   and (p.proname like 'cs_fathom_%' or p.proname like 'cs_cliente_mail_%') order by 1;

-- C6. Mails extra (informativo). Esperado: 0 filas hasta que alguien asigne una llamada a mano.
-- select origen, count(*) from public.cs_clientes_mails group by 1;

-- C7. Un mail repetido entre alumnos distintos (principal o extra). Esperado: 0 filas salvo parejas conocidas.
-- select m.email, count(distinct m.cliente_id) from (
--   select lower(btrim(email)) as email, id as cliente_id from public.cs_clientes where email is not null
--   union all select email, cliente_id from public.cs_clientes_mails) m
-- group by 1 having count(distinct m.cliente_id) > 1;

-- C8. HUMO (se revierte solo: termina en error "HUMO OK: N comprobaciones"). Usa dos alumnos reales y los
--     deshace. Hace de fundador con set_config.
-- do $$
-- declare
--   v_a uuid; v_b uuid; v_fund uuid; v_mail text; v_n int := 0; v_r jsonb; v_cnt int; v_sa uuid;
--   v_ll uuid; v_txt text;
-- begin
--   select id into v_a from public.cs_clientes order by created_at limit 1;
--   select id into v_b from public.cs_clientes where id <> v_a order by created_at limit 1;
--   if v_a is null or v_b is null then raise exception 'hacen falta 2 alumnos para probar'; end if;
--   select user_id into v_fund from public.crm_members where rol = 'fundador' limit 1;
--   if v_fund is null then raise exception 'sin fundador en crm_members'; end if;
--   -- 1. sin alumno: queda pendiente con invitados
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-126a','inicio_at', now(),
--     'consultor','teo','origen','sync',
--     'invitados','["zz-humo-a@x.com","ZZ-humo-b@x.com"]'::jsonb,'transcripcion','texto',
--     'action_items','[{"descripcion":"Mandar el plan","responsable":"Joaco"}]'::jsonb));
--   if v_r->>'resultado' <> 'sin_asignar' then raise exception 'esperaba sin_asignar, vino %', v_r; end if;
--   select id into v_sa from public.cs_fathom_sin_asignar where externo_id = 'fathom:humo-126a';
--   v_n := v_n + 1;
--   -- 2. asignar a mano como fundador: crea la llamada, aprende los 2 mails (en minusculas)
--   perform set_config('request.jwt.claim.sub', v_fund::text, true);
--   perform set_config('request.jwt.claims', json_build_object('sub', v_fund, 'role', 'authenticated')::text, true);
--   v_r := public.cs_fathom_asignar(v_sa, v_a);
--   v_ll := (v_r->>'llamada_id')::uuid;
--   select count(*) into v_cnt from public.cs_clientes_mails
--   where cliente_id = v_a and origen = 'aprendido' and email in ('zz-humo-a@x.com','zz-humo-b@x.com');
--   if v_cnt <> 2 then raise exception 'no aprendio los 2 mails: %', v_cnt; end if;
--   select asignada_por into v_txt from public.cs_llamadas where id = v_ll;
--   if v_txt <> 'manual' then raise exception 'asignada_por deberia ser manual: %', v_txt; end if;
--   v_n := v_n + 2;
--   -- 3. un mail de otro alumno no se aprende
--   update public.cs_clientes set email = 'zz-humo-dueno@x.com' where id = v_b;
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-126b','inicio_at', now(),
--     'consultor','teo','origen','manual','cliente_id', v_a,
--     'invitados','["zz-humo-dueno@x.com","zz-humo-c@x.com"]'::jsonb));
--   select count(*) into v_cnt from public.cs_clientes_mails where cliente_id = v_a and email = 'zz-humo-dueno@x.com';
--   if v_cnt <> 0 then raise exception 'aprendio el mail de otro alumno'; end if;
--   select count(*) into v_cnt from public.cs_clientes_mails where cliente_id = v_a and email = 'zz-humo-c@x.com';
--   if v_cnt <> 1 then raise exception 'no aprendio el mail propio'; end if;
--   v_n := v_n + 2;
--   -- 4. corregir a otro alumno: se mueven la llamada y lo aprendido de ella
--   v_r := public.cs_fathom_corregir(v_ll, v_b);
--   select count(*) into v_cnt from public.cs_llamadas where externo_id = 'fathom:humo-126a' and cliente_id = v_b;
--   if v_cnt <> 1 then raise exception 'la llamada no paso al otro alumno'; end if;
--   select count(*) into v_cnt from public.cs_clientes_mails
--   where cliente_id = v_a and llamada_externo_id = 'fathom:humo-126a';
--   if v_cnt <> 0 then raise exception 'no deshizo lo aprendido del alumno anterior'; end if;
--   select count(*) into v_cnt from public.cs_clientes_mails
--   where cliente_id = v_b and llamada_externo_id = 'fathom:humo-126a';
--   if v_cnt <> 2 then raise exception 'el alumno nuevo no aprendio los 2 mails: %', v_cnt; end if;
--   select count(*) into v_cnt from public.cs_llamada_accionables a join public.cs_llamadas l on l.id = a.llamada_id
--   where l.externo_id = 'fathom:humo-126a';
--   if v_cnt <> 1 then raise exception 'los accionables no se conservaron: %', v_cnt; end if;
--   v_n := v_n + 4;
--   -- 5. devolver a pendiente: la sync NO la reasigna
--   v_r := public.cs_fathom_corregir((v_r->>'llamada_id')::uuid, null);
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-126a','cliente_id', v_a,
--     'inicio_at', now(), 'consultor','teo','origen','sync','asignada_por','nombre'));
--   if v_r->>'resultado' <> 'sin_asignar' then raise exception 'la sync reasigno una llamada devuelta: %', v_r; end if;
--   v_n := v_n + 1;
--   -- 6. por nombre desde la sync, y confirmar la pasa a manual y aprende
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-126c','cliente_id', v_a,
--     'inicio_at', now(), 'consultor','teo','origen','sync','asignada_por','nombre',
--     'invitados','["zz-humo-d@x.com"]'::jsonb));
--   v_ll := (v_r->>'llamada_id')::uuid;
--   select asignada_por into v_txt from public.cs_llamadas where id = v_ll;
--   if v_txt <> 'nombre' then raise exception 'esperaba nombre, hay %', v_txt; end if;
--   select count(*) into v_cnt from public.cs_clientes_mails where cliente_id = v_a and email = 'zz-humo-d@x.com';
--   if v_cnt <> 0 then raise exception 'la sync aprendio sin que nadie confirme'; end if;
--   perform public.cs_fathom_confirmar(v_ll);
--   select count(*) into v_cnt from public.cs_clientes_mails where cliente_id = v_a and email = 'zz-humo-d@x.com';
--   if v_cnt <> 1 then raise exception 'confirmar no aprendio el mail'; end if;
--   v_n := v_n + 3;
--   -- 7. consultor: con email_login de un usuario existente, es consultor de teo y no de joaco
--   select email into v_mail from auth.users where id = v_fund;
--   update public.cs_fathom_consultores set email_login = lower(v_mail) where id = 'teo';
--   update public.cs_fathom_consultores set email_login = null where id = 'joaco';
--   if not public.cs_fathom_es_consultor_de(v_fund, 'teo') then raise exception 'deberia ser consultor de teo'; end if;
--   if public.cs_fathom_es_consultor_de(v_fund, 'joaco') then raise exception 'no deberia ser consultor de joaco'; end if;
--   v_n := v_n + 2;
--   raise exception 'HUMO OK: % comprobaciones', v_n;
-- end $$;


-- =====================================================================
-- VUELTA ATRAS (comentada). Pierde los mails extra, asignada_por, invitados y el login de consultores.
-- Despues, volver a correr la 124 (es idempotente) restaura cs_fathom_aplicar / asignar / marcar /
-- reabrir / programas, la politica cs_privadas_select y la vista cs_v_fathom_llamadas de la 124.
-- =====================================================================
-- begin;
-- drop view if exists public.cs_v_fathom_llamadas;
-- drop policy if exists cs_privadas_select on public.cs_fathom_sin_asignar;
-- drop function if exists public.cs_fathom_login_guardar(text, text);
-- drop function if exists public.cs_fathom_logins();
-- drop function if exists public.cs_cliente_mail_quitar(uuid);
-- drop function if exists public.cs_cliente_mail_agregar(uuid, text);
-- drop function if exists public.cs_fathom_corregir(uuid, uuid);
-- drop function if exists public.cs_fathom_confirmar(uuid);
-- drop function if exists public.cs_fathom_alumnos();
-- drop function if exists public.cs_fathom_aprender(uuid, jsonb, text);
-- drop function if exists public.cs_fathom_puede_asignar_llamada(text, text);
-- drop function if exists public.cs_fathom_puede_gestionar(text);
-- drop function if exists public.cs_fathom_programas_cfg();
-- drop function if exists public.cs_fathom_es_consultor_alguno();
-- drop function if exists public.cs_fathom_es_consultor(text);
-- drop function if exists public.cs_fathom_es_consultor_de(uuid, text);
-- grant select on table public.cs_fathom_consultores to authenticated;
-- alter table public.cs_fathom_consultores drop column if exists email_login;
-- alter table public.cs_fathom_sin_asignar drop column if exists no_auto;
-- alter table public.cs_llamadas drop column if exists invitados;
-- alter table public.cs_llamadas drop column if exists asignada_por;
-- drop table if exists public.cs_clientes_mails;
-- commit;
-- -- y volver a correr migraciones/124-producto-fathom-consultores.sql
