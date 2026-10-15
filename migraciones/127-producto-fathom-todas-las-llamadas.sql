-- =====================================================================
-- 127-producto-fathom-todas-las-llamadas.sql  ·  PRODUCTO: todas las llamadas de Fathom,
-- estado "interna", alias por nombre e historial reanudable
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), primero en el banco de pruebas.
-- Numeracion global asignada por el jefe: 127. Requiere la 126 (y por lo tanto 124, 122, 106 y 102).
-- Evitar :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- La Edge Function (supabase/functions/fathom-sync, v4) se despliega DESPUES de correr esto.
--
-- Que hace:
--   A. Estado nuevo "interna" en cs_fathom_sin_asignar.estado: la reunion no tiene a nadie de afuera
--      (solo el consultor o mails del equipo) ni un nombre en el titulo. Antes esas reuniones se
--      IGNORABAN (no se guardaban); ahora entran a la pestana del consultor. Se ven con el filtro
--      "Internas" (oculto por defecto en la pantalla). Mismos permisos que pendiente / no_alumno:
--      fundador, cliente y el consultor dueno. Se puede asignar a un alumno o marcar "no es alumno".
--   B. cs_clientes_alias: nombres alternativos de un alumno. Se aprenden al asignar o confirmar a
--      mano una llamada (nombre del invitado externo y/o nombre sacado del titulo, normalizado) y
--      los usa fathom-sync junto con el nombre del alumno. Un alias que ya es el nombre de OTRO
--      alumno (de los programas habilitados) o alias de otro, no se guarda y se avisa.
--      Columna `nombres` en cs_llamadas y cs_fathom_sin_asignar: los nombres candidatos de la
--      reunion que calcula la funcion (de ahi se aprende; la app no los muestra).
--   C. Historial reanudable: columnas hist_* en cs_fathom_consultores. La funcion trae todo el
--      historial de una cuenta por tandas y guarda el cursor; la siguiente corrida sigue desde ahi.
--   D. cs_fathom_corridas.internas (conteo de reuniones internas guardadas).
--   E. Funciones reemplazadas (respaldo en cs_bak_127_funciones): cs_fathom_aplicar (nombres,
--      interna, aprende alias), cs_fathom_asignar, cs_fathom_marcar_no_alumno (acepta interna),
--      cs_fathom_confirmar (ahora devuelve jsonb con lo aprendido), cs_fathom_corregir (deshace
--      alias aprendidos) y la vista cs_v_fathom_llamadas (incluye internas).
--
-- No borra ni mueve llamadas ni asignaciones existentes. No toca finanzas, crm, ventas, cron, el
-- aviso de servicio (123) ni los umbrales. Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo
do $$
declare
  v_falta text;
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'cs 127: hace falta Postgres 15 o mas';
  end if;
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_clientes', 'cs_clientes_mails', 'cs_llamadas', 'cs_llamada_accionables',
                    'cs_llamada_transcripciones', 'cs_llamada_recursos', 'cs_fathom_config',
                    'cs_fathom_sin_asignar', 'cs_fathom_consultores', 'cs_fathom_corridas']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception 'cs 127: faltan tablas (corrio la 126?): %', v_falta;
  end if;
  select string_agg(r.f, ', ') into v_falta
  from (values ('es_fundador()'), ('cs_hoy()'), ('cs_norm_nombre(text)'), ('cs_fathom_aplicar(jsonb)'),
               ('cs_fathom_aprender(uuid, jsonb, text)'), ('cs_fathom_asignar(uuid, uuid)'),
               ('cs_fathom_marcar_no_alumno(uuid)'), ('cs_fathom_reabrir(uuid)'),
               ('cs_fathom_confirmar(uuid)'), ('cs_fathom_corregir(uuid, uuid)'),
               ('cs_fathom_programas_cfg()'), ('cs_fathom_ve_privadas()'), ('cs_fathom_es_consultor(text)'),
               ('cs_fathom_es_cliente_de(uuid, text)'), ('cs_fathom_puede_gestionar(text)'),
               ('cs_fathom_puede_asignar_llamada(text, text)'), ('cs_tg_updated_at()')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 127: faltan funciones de la 124/126: %', v_falta;
  end if;
  if to_regclass('public.cs_v_fathom_llamadas') is null then
    raise exception 'cs 127: falta la vista cs_v_fathom_llamadas (126)';
  end if;
end $$;

-- Lock de todo lo que se altera, junto (regla del deadlock).
lock table public.cs_programas, public.cs_clientes, public.cs_clientes_mails, public.cs_llamadas,
           public.cs_llamada_accionables, public.cs_llamada_transcripciones, public.cs_llamada_recursos,
           public.cs_fathom_sin_asignar, public.cs_fathom_consultores, public.cs_fathom_corridas
  in share row exclusive mode;

-- Respaldo de lo que se reemplaza.
create table if not exists public.cs_bak_127_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_127_funciones from public, anon, authenticated;
insert into public.cs_bak_127_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('cs_fathom_aplicar', 'cs_fathom_asignar', 'cs_fathom_marcar_no_alumno',
                    'cs_fathom_confirmar', 'cs_fathom_corregir')
on conflict (funcion) do nothing;
insert into public.cs_bak_127_funciones (funcion, definicion)
select 'view public.cs_v_fathom_llamadas', pg_get_viewdef('public.cs_v_fathom_llamadas'::regclass, true)
on conflict (funcion) do nothing;


-- =====================================================================
-- A. Estado "interna"
-- =====================================================================
alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_124;
alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_127;
alter table public.cs_fathom_sin_asignar add constraint cs_fathom_sin_asignar_estado_127
  check (estado in ('pendiente', 'asignada', 'no_alumno', 'interna'));
comment on column public.cs_fathom_sin_asignar.estado is
  '127: pendiente (hay alguien o un nombre, sin alumno) | interna (nadie de afuera) | no_alumno (marcada a mano) | asignada (ya es una llamada de cs_llamadas).';

alter table public.cs_fathom_sin_asignar add column if not exists nombres text[] not null default '{}';
alter table public.cs_llamadas add column if not exists nombres text[] not null default '{}';
comment on column public.cs_fathom_sin_asignar.nombres is
  '127: nombres candidatos de la reunion (invitados externos con 2 palabras o mas y nombres del titulo, sin el consultor), normalizados. De aca se aprenden los alias al asignar a mano.';
comment on column public.cs_llamadas.nombres is
  '127: idem cs_fathom_sin_asignar.nombres, conservados al asignar para aprender alias al confirmar.';

alter table public.cs_fathom_corridas add column if not exists internas int not null default 0;


-- =====================================================================
-- B. Alias de alumno
-- =====================================================================
create table if not exists public.cs_clientes_alias (
  id                 uuid primary key default gen_random_uuid(),
  cliente_id         uuid not null,
  programa_id        text not null references public.cs_programas(id),
  alias              text not null
                     check (alias = btrim(alias) and alias = lower(alias) and position(' ' in alias) > 0
                            and char_length(alias) between 5 and 80),
  origen             text not null default 'aprendido' check (origen in ('aprendido', 'manual')),
  llamada_externo_id text,           -- llamada de Fathom de la que se aprendio (para deshacerlo al corregir)
  created_at         timestamptz not null default now(),
  created_by         uuid default auth.uid(),
  constraint cs_clientes_alias_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
-- Un alias es de UN solo alumno (la sync busca entre todos los programas habilitados).
create unique index if not exists cs_clientes_alias_uk on public.cs_clientes_alias (alias);
create index if not exists cs_clientes_alias_cliente_idx on public.cs_clientes_alias (cliente_id);
comment on table public.cs_clientes_alias is
  'Nombres alternativos de un alumno (127), normalizados como cs_norm_nombre. fathom-sync los usa junto con cs_clientes.nombre. Se escriben por funcion.';

-- Quien puede ver y quitar alias: fundador o cliente del programa.
create or replace function public.cs_fathom_puede_alias(p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
      or coalesce(public.cs_fathom_es_cliente_de(auth.uid(), p_programa), false)
$$;
revoke all on function public.cs_fathom_puede_alias(text) from public, anon;
grant execute on function public.cs_fathom_puede_alias(text) to authenticated;

alter table public.cs_clientes_alias enable row level security;
revoke all on table public.cs_clientes_alias from anon, authenticated;
grant select on table public.cs_clientes_alias to authenticated;
grant select on table public.cs_clientes_alias to service_role;
drop policy if exists cs_select on public.cs_clientes_alias;
create policy cs_select on public.cs_clientes_alias for select to authenticated
  using (public.cs_fathom_puede_alias(programa_id));

-- Interna. Guarda como alias del alumno los nombres dados, salvo el propio, los que son nombre de
-- OTRO alumno (de su programa o de los habilitados) o alias de otro. Devuelve
-- { guardados: n, conflictos: [{ alias, con }] }.
create or replace function public.cs_fathom_aprender_alias(p_cliente uuid, p_nombres text[], p_externo text,
                                                           p_origen text default 'aprendido')
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog   text;
  v_propio text;
  v_a      text;
  v_otro   text;
  v_g      int := 0;
  v_conf   jsonb := '[]'::jsonb;
begin
  select c.programa_id, public.cs_norm_nombre(c.nombre) into v_prog, v_propio
  from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    return jsonb_build_object('guardados', 0, 'conflictos', '[]'::jsonb);
  end if;
  for v_a in
    select distinct public.cs_norm_nombre(x) from unnest(coalesce(p_nombres, '{}'::text[])) x
  loop
    continue when v_a is null or position(' ' in v_a) = 0 or char_length(v_a) not between 5 and 80;
    continue when v_a = v_propio;
    v_otro := null;
    select o.nombre into v_otro
    from public.cs_clientes o
    where o.id <> p_cliente and public.cs_norm_nombre(o.nombre) = v_a
      and (o.programa_id = v_prog or o.programa_id = any (public.cs_fathom_programas_cfg()))
    limit 1;
    if v_otro is null then
      select o.nombre into v_otro
      from public.cs_clientes_alias al join public.cs_clientes o on o.id = al.cliente_id
      where al.alias = v_a and al.cliente_id <> p_cliente
      limit 1;
    end if;
    if v_otro is not null then
      v_conf := v_conf || jsonb_build_array(jsonb_build_object('alias', v_a, 'con', v_otro));
      continue;
    end if;
    insert into public.cs_clientes_alias (cliente_id, programa_id, alias, origen, llamada_externo_id)
    values (p_cliente, v_prog, v_a,
            case when p_origen = 'manual' then 'manual' else 'aprendido' end, p_externo)
    on conflict (alias) do nothing;
    if found then v_g := v_g + 1; end if;
  end loop;
  return jsonb_build_object('guardados', v_g, 'conflictos', v_conf);
end;
$fn$;
revoke all on function public.cs_fathom_aprender_alias(uuid, text[], text, text) from public, anon, authenticated;

-- Quitar un alias (fundador o cliente del programa).
create or replace function public.cs_fathom_alias_quitar(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog text;
begin
  select a.programa_id into v_prog from public.cs_clientes_alias a where a.id = p_id;
  if v_prog is null then
    raise exception 'cs: el alias no existe' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_alias(v_prog) then
    raise exception 'cs: solo el fundador o el cliente del programa quitan alias' using errcode = '42501';
  end if;
  delete from public.cs_clientes_alias where id = p_id;
end;
$fn$;
revoke all on function public.cs_fathom_alias_quitar(uuid) from public, anon;
grant execute on function public.cs_fathom_alias_quitar(uuid) to authenticated;

-- Agregar un alias a mano (fundador o cliente del programa). Si choca con otro alumno, error con el nombre.
create or replace function public.cs_fathom_alias_agregar(p_cliente uuid, p_alias text)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog text;
  v_r    jsonb;
begin
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: el alumno no existe' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_alias(v_prog) then
    raise exception 'cs: solo el fundador o el cliente del programa agregan alias' using errcode = '42501';
  end if;
  v_r := public.cs_fathom_aprender_alias(p_cliente, array[p_alias], null, 'manual');
  if jsonb_array_length(v_r->'conflictos') > 0 then
    raise exception 'cs: ese nombre ya es de otro alumno (%)', v_r->'conflictos'->0->>'con' using errcode = '22023';
  end if;
  if (v_r->>'guardados')::int = 0 then
    raise exception 'cs: el alias necesita nombre y apellido (2 palabras como minimo) o ya estaba cargado' using errcode = '22023';
  end if;
end;
$fn$;
revoke all on function public.cs_fathom_alias_agregar(uuid, text) from public, anon;
grant execute on function public.cs_fathom_alias_agregar(uuid, text) to authenticated;


-- =====================================================================
-- C. Historial reanudable (estado por cuenta)
-- =====================================================================
alter table public.cs_fathom_consultores add column if not exists hist_estado text;
alter table public.cs_fathom_consultores add column if not exists hist_desde timestamptz;
alter table public.cs_fathom_consultores add column if not exists hist_hasta timestamptz;
alter table public.cs_fathom_consultores add column if not exists hist_cursor text;
alter table public.cs_fathom_consultores add column if not exists hist_oldest timestamptz;
alter table public.cs_fathom_consultores add column if not exists hist_desc boolean;
alter table public.cs_fathom_consultores add column if not exists hist_traidas int not null default 0;
alter table public.cs_fathom_consultores add column if not exists hist_inicio_at timestamptz;
alter table public.cs_fathom_consultores add column if not exists hist_fin_at timestamptz;
alter table public.cs_fathom_consultores drop constraint if exists cs_fathom_consultores_hist_estado_chk;
alter table public.cs_fathom_consultores add constraint cs_fathom_consultores_hist_estado_chk
  check (hist_estado is null or hist_estado in ('en_curso', 'completo'));
comment on column public.cs_fathom_consultores.hist_estado is
  '127: null = nunca se pidio el historial | en_curso = quedan paginas (la sync sigue sola desde hist_cursor) | completo.';
comment on column public.cs_fathom_consultores.hist_cursor is
  '127: cursor de Fathom de la proxima pagina del historial (no sale por la API: solo la funcion lo lee).';
comment on column public.cs_fathom_consultores.hist_oldest is
  '127: created_at mas viejo visto en el historial; respaldo si Fathom rechaza el cursor y el orden es del mas nuevo al mas viejo (hist_desc).';

-- El cursor no sale por la API; el resto del estado si (Configuracion lo muestra).
grant select (hist_estado, hist_desde, hist_hasta, hist_traidas, hist_inicio_at, hist_fin_at)
  on public.cs_fathom_consultores to authenticated;


-- =====================================================================
-- D. cs_fathom_aplicar (reemplaza la de la 126)
--   Suma: p.clasificar = 'interna' (solo sin alumno), p.nombres (text[]), aprende alias al asignar a
--   mano, y devuelve lo aprendido: { resultado, llamada_id, mails, alias_guardados, alias_conflictos }.
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
  v_estado text := case when p->>'clasificar' = 'interna' then 'interna' else 'pendiente' end;
  v_inv    jsonb;
  v_nom    text[];
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
  v_mails  int := 0;
  v_alias  jsonb := jsonb_build_object('guardados', 0, 'conflictos', '[]'::jsonb);
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

  -- nombres candidatos normalizados (hasta 10, 2 palabras o mas)
  select coalesce(array_agg(n order by n), '{}'::text[]) into v_nom
  from (select distinct public.cs_norm_nombre(x) as n
        from jsonb_array_elements_text(
               case when jsonb_typeof(p->'nombres') = 'array' then p->'nombres' else '[]'::jsonb end) x
        where public.cs_norm_nombre(x) like '% %' and char_length(public.cs_norm_nombre(x)) <= 80
        limit 10) t;

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
      nombres = case when nombres = '{}'::text[] then v_nom else nombres end,
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
        nombres = v_nom,
        fathom_sync_at = now()
      where id = v_ll;
      v_res := 'vinculada';
    else
      insert into public.cs_llamadas (programa_id, cliente_id, fecha, titulo, externo_id, fuente, tipo,
                                      duracion_min, grabacion_url, grabacion_share_url, inicio_at,
                                      resumen, en_que_esta, proximos_pasos, fathom_sync_at, consultor,
                                      asignada_por, invitados, nombres)
      values (v_prog, v_cli, v_fecha, v_titulo, v_ext, 'fathom', v_tipo,
              v_dur, v_url, v_share, v_inicio, v_res_txt, v_est, v_prox, now(), v_cons,
              v_asig, v_inv, v_nom)
      returning id into v_ll;
      v_res := 'creada';
    end if;

  -- 3. sin alumno: queda pendiente / interna (o no_alumno si ya la marcaron) para asignar a mano
  else
    v_motivo := case when p->>'motivo' = 'varios_alumnos' then 'varios_alumnos' else 'sin_alumno' end;
    select coalesce(array_agg(x::uuid), '{}') into v_cand
    from jsonb_array_elements_text(
           case when jsonb_typeof(p->'candidatos') = 'array' then p->'candidatos' else '[]'::jsonb end) x;
    insert into public.cs_fathom_sin_asignar as s (
      externo_id, motivo, estado, fecha, inicio_at, titulo, tipo, duracion_min, grabacion_url, grabacion_share_url,
      resumen, en_que_esta, proximos_pasos, transcripcion, action_items, invitados, nombres, candidatos, consultor)
    values (
      v_ext, v_motivo, v_estado, v_fecha, v_inicio, v_titulo, v_tipo, v_dur, v_url, v_share,
      v_res_txt, v_est, v_prox, v_transc,
      case when jsonb_typeof(p->'action_items') = 'array' then p->'action_items' else '[]'::jsonb end,
      v_inv, v_nom, v_cand, v_cons)
    on conflict (externo_id) do update set
      motivo = excluded.motivo,
      -- una "interna" que ahora tiene a alguien pasa a pendiente; una pendiente no vuelve a interna
      estado = case when s.estado = 'interna' then excluded.estado else s.estado end,
      fecha = excluded.fecha, inicio_at = excluded.inicio_at,
      titulo = excluded.titulo, tipo = excluded.tipo, duracion_min = excluded.duracion_min,
      grabacion_url = excluded.grabacion_url, grabacion_share_url = excluded.grabacion_share_url,
      resumen = excluded.resumen, en_que_esta = excluded.en_que_esta, proximos_pasos = excluded.proximos_pasos,
      transcripcion = excluded.transcripcion, action_items = excluded.action_items,
      invitados = excluded.invitados, nombres = excluded.nombres, candidatos = excluded.candidatos,
      consultor = coalesce(s.consultor, excluded.consultor)
    where s.estado in ('pendiente', 'no_alumno', 'interna');
    return jsonb_build_object('resultado', case when v_estado = 'interna' then 'interna' else 'sin_asignar' end,
                              'llamada_id', null);
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

  -- Si estaba en la lista (pendiente, interna o no_alumno), queda resuelta y sin transcripcion propia
  update public.cs_fathom_sin_asignar s
  set estado = 'asignada', cliente_id = v_cli, programa_id = v_prog, llamada_id = v_ll,
      transcripcion = null, no_auto = false,
      resuelta_at = coalesce(s.resuelta_at, now()), resuelta_por = coalesce(s.resuelta_por, auth.uid())
  where s.externo_id = v_ext and s.estado in ('pendiente', 'no_alumno', 'interna');

  -- Aprende: una asignacion a mano convierte los mails de la llamada en mails del alumno y sus
  -- nombres en alias (los que no chocan con otro alumno).
  if v_manual then
    v_mails := public.cs_fathom_aprender(v_cli, v_inv, v_ext);
    v_alias := public.cs_fathom_aprender_alias(v_cli, v_nom, v_ext, 'aprendido');
  end if;

  return jsonb_build_object('resultado', v_res, 'llamada_id', v_ll, 'mails', v_mails,
                            'alias_guardados', (v_alias->>'guardados')::int,
                            'alias_conflictos', v_alias->'conflictos');
end;
$fn$;
revoke all on function public.cs_fathom_aplicar(jsonb) from public, anon, authenticated;


-- =====================================================================
-- E. Funciones de la app
-- =====================================================================

-- E1. Asignar a mano una pendiente / interna / no_alumno.
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
    'invitados', v_row.invitados, 'nombres', to_jsonb(v_row.nombres)));
end;
$fn$;
revoke all on function public.cs_fathom_asignar(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_asignar(uuid, uuid) to authenticated;

-- E2. "No es alumno": desde pendiente o interna (fundador, cliente o el consultor de la llamada).
create or replace function public.cs_fathom_marcar_no_alumno(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_cons text;
begin
  select s.consultor into v_cons from public.cs_fathom_sin_asignar s
  where s.id = p_id and s.estado in ('pendiente', 'interna');
  if not found then
    raise exception 'cs: la llamada no existe o ya no esta pendiente' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_gestionar(v_cons) then
    raise exception 'cs: solo el fundador, el cliente o el consultor de la llamada la marcan como "no es alumno"' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'no_alumno', resuelta_at = now(), resuelta_por = auth.uid()
  where id = p_id and estado in ('pendiente', 'interna');
end;
$fn$;
revoke all on function public.cs_fathom_marcar_no_alumno(uuid) from public, anon;
grant execute on function public.cs_fathom_marcar_no_alumno(uuid) to authenticated;

-- E3. Confirmar una llamada asignada por nombre: pasa a manual y aprende mails y alias.
--     Cambia el tipo de retorno (void -> jsonb): se recrea.
drop function if exists public.cs_fathom_confirmar(uuid);
create function public.cs_fathom_confirmar(p_llamada uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_l     public.cs_llamadas%rowtype;
  v_mails int;
  v_alias jsonb;
begin
  select * into v_l from public.cs_llamadas where id = p_llamada and fuente = 'fathom' for update;
  if not found then
    raise exception 'cs: la llamada no existe' using errcode = '22023';
  end if;
  if not public.cs_fathom_puede_asignar_llamada(v_l.programa_id, v_l.consultor) then
    raise exception 'cs: no tenes permiso para confirmar esa llamada' using errcode = '42501';
  end if;
  update public.cs_llamadas set asignada_por = 'manual' where id = v_l.id;
  v_mails := public.cs_fathom_aprender(v_l.cliente_id, v_l.invitados, v_l.externo_id);
  v_alias := public.cs_fathom_aprender_alias(v_l.cliente_id, v_l.nombres, v_l.externo_id, 'aprendido');
  return jsonb_build_object('resultado', 'confirmada', 'llamada_id', v_l.id, 'mails', v_mails,
                            'alias_guardados', (v_alias->>'guardados')::int,
                            'alias_conflictos', v_alias->'conflictos');
end;
$fn$;
revoke all on function public.cs_fathom_confirmar(uuid) from public, anon;
grant execute on function public.cs_fathom_confirmar(uuid) to authenticated;

-- E4. Corregir: pasar una llamada ya asignada a OTRO alumno, o devolverla a pendiente (p_cliente null).
--     Deshace los mails y alias aprendidos de esa llamada para el alumno anterior.
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

  -- lo aprendido de esta llamada para el alumno anterior se deshace (mails y alias)
  delete from public.cs_clientes_mails
  where cliente_id = v_l.cliente_id and origen = 'aprendido' and llamada_externo_id = v_l.externo_id;
  delete from public.cs_clientes_alias
  where cliente_id = v_l.cliente_id and origen = 'aprendido' and llamada_externo_id = v_l.externo_id;

  delete from public.cs_llamadas where id = v_l.id;   -- cascade: accionables y transcripcion

  if p_cliente is null then
    insert into public.cs_fathom_sin_asignar as s (
      externo_id, motivo, estado, no_auto, fecha, inicio_at, titulo, tipo, duracion_min, grabacion_url,
      grabacion_share_url, resumen, en_que_esta, proximos_pasos, transcripcion, action_items, invitados,
      nombres, candidatos, consultor)
    values (v_l.externo_id, 'sin_alumno', 'pendiente', true, v_l.fecha, v_l.inicio_at, v_l.titulo, v_l.tipo,
            v_l.duracion_min, v_l.grabacion_url, v_l.grabacion_share_url, v_l.resumen, v_l.en_que_esta,
            v_l.proximos_pasos, v_transc, v_items, v_l.invitados, v_l.nombres, '{}', v_l.consultor)
    on conflict (externo_id) do update set
      estado = 'pendiente', no_auto = true, motivo = 'sin_alumno', transcripcion = excluded.transcripcion,
      action_items = excluded.action_items, invitados = excluded.invitados, nombres = excluded.nombres,
      candidatos = '{}', programa_id = null, cliente_id = null, llamada_id = null,
      resuelta_at = null, resuelta_por = null;
    return jsonb_build_object('resultado', 'pendiente', 'llamada_id', null);
  end if;

  v_out := public.cs_fathom_aplicar(jsonb_build_object(
    'externo_id', v_l.externo_id, 'cliente_id', p_cliente, 'consultor', v_l.consultor, 'origen', 'manual',
    'inicio_at', coalesce(v_l.inicio_at, v_l.fecha::timestamptz),
    'titulo', v_l.titulo, 'tipo', v_l.tipo, 'duracion_min', v_l.duracion_min,
    'grabacion_url', v_l.grabacion_url, 'grabacion_share_url', v_l.grabacion_share_url,
    'resumen', v_l.resumen, 'en_que_esta', v_l.en_que_esta, 'proximos_pasos', v_l.proximos_pasos,
    'transcripcion', v_transc, 'action_items', v_items, 'invitados', v_l.invitados,
    'nombres', to_jsonb(v_l.nombres)));

  -- la fila de la lista (si la hubo) apunta ahora al alumno nuevo
  update public.cs_fathom_sin_asignar
  set cliente_id = p_cliente, programa_id = v_prog, llamada_id = (v_out->>'llamada_id')::uuid, estado = 'asignada'
  where externo_id = v_l.externo_id;
  return v_out;
end;
$fn$;
revoke all on function public.cs_fathom_corregir(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_corregir(uuid, uuid) to authenticated;


-- =====================================================================
-- F. Vista para la pantalla "Llamadas" (suma las internas)
-- =====================================================================
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
where s.estado in ('pendiente', 'no_alumno', 'interna')
  and (public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor(s.consultor));
revoke all on public.cs_v_fathom_llamadas from anon;
grant select on public.cs_v_fathom_llamadas to authenticated;

commit;


-- =====================================================================
-- DESPUES DE CORRER (a mano, fuera de este archivo)
-- =====================================================================
--   1. Redesplegar:  supabase functions deploy fathom-sync --no-verify-jwt
--   2. Configuracion general (Panel general) > Llamadas de Fathom > "Traer historial completo" en la
--      cuenta de Joaco. Cada corrida trae una tanda y guarda el cursor; con la sincronizacion
--      automatica activa se completa sola (2 veces por dia), o se aprieta el boton de nuevo.
--   3. Pantalla Llamadas: filtro de estado "Internas" (ocultas por defecto) y asignar a mano.


-- =====================================================================
-- CONTROLES (de a uno, despues de correr la migracion)
-- =====================================================================

-- C1. Objetos nuevos. Esperado: tabla = true; columnas = 12 filas; 5 funciones; vista = true.
-- select to_regclass('public.cs_clientes_alias') is not null as tabla;
-- select table_name, column_name from information_schema.columns
-- where table_schema = 'public' and (table_name, column_name) in
--   (('cs_llamadas','nombres'), ('cs_fathom_sin_asignar','nombres'), ('cs_fathom_corridas','internas'),
--    ('cs_fathom_consultores','hist_estado'), ('cs_fathom_consultores','hist_desde'),
--    ('cs_fathom_consultores','hist_hasta'), ('cs_fathom_consultores','hist_cursor'),
--    ('cs_fathom_consultores','hist_oldest'), ('cs_fathom_consultores','hist_desc'),
--    ('cs_fathom_consultores','hist_traidas'), ('cs_fathom_consultores','hist_inicio_at'),
--    ('cs_fathom_consultores','hist_fin_at'));
-- select proname from pg_proc where pronamespace = 'public'::regnamespace and proname in
--   ('cs_fathom_aprender_alias','cs_fathom_alias_quitar','cs_fathom_alias_agregar','cs_fathom_puede_alias',
--    'cs_fathom_confirmar') order by 1;

-- C2. Nada se perdio ni se movio. Esperado: mismos conteos que antes de la migracion
--     (2 asignadas y 5 pendientes de la cuenta de Joaco al 14/10) y 0 internas hasta la proxima sync.
-- select estado, consultor, count(*) from public.cs_fathom_sin_asignar group by 1, 2 order by 1, 2;
-- select consultor, count(*) from public.cs_llamadas where fuente = 'fathom' group by 1;

-- C3. El cursor del historial no sale por la API. Esperado: false; y el estado si: true.
-- select has_column_privilege('authenticated', 'public.cs_fathom_consultores', 'hist_cursor', 'select') as cursor_api,
--        has_column_privilege('authenticated', 'public.cs_fathom_consultores', 'hist_estado', 'select') as estado_api;

-- C4. Quien ejecuta las funciones. Esperado: aprender_alias sin ningun rol de la app; el resto authenticated.
-- select p.proname,
--        has_function_privilege('anon', p.oid, 'execute') as anon,
--        has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
-- from pg_proc p where p.pronamespace = 'public'::regnamespace
--   and (p.proname like 'cs_fathom_%alias%' or p.proname in ('cs_fathom_confirmar', 'cs_fathom_puede_alias')) order by 1;

-- C5. Estado "interna" aceptado por el CHECK. Esperado: 1 fila con 'interna' en la definicion.
-- select conname, pg_get_constraintdef(oid) from pg_constraint
-- where conrelid = 'public.cs_fathom_sin_asignar'::regclass and conname = 'cs_fathom_sin_asignar_estado_127';

-- C6. Alias (informativo). Esperado: 0 filas hasta que alguien asigne o confirme una llamada a mano.
-- select origen, count(*) from public.cs_clientes_alias group by 1;

-- C7. Un alias que es el nombre de otro alumno. Esperado: 0 filas (la funcion no lo guarda).
-- select a.alias, a.cliente_id, o.id as otro, o.nombre
-- from public.cs_clientes_alias a join public.cs_clientes o
--   on o.id <> a.cliente_id and public.cs_norm_nombre(o.nombre) = a.alias;

-- C8. HUMO (se revierte solo: termina en error "HUMO OK: N comprobaciones"). Usa dos alumnos reales y los
--     deshace. Hace de fundador con set_config. v_b tiene que tener nombre de 2 palabras o mas.
-- do $$
-- declare
--   v_a uuid; v_b uuid; v_fund uuid; v_n int := 0; v_r jsonb; v_cnt int; v_sa uuid; v_ll uuid;
--   v_nom_b text; v_est text; v_id uuid;
-- begin
--   select id into v_b from public.cs_clientes where public.cs_norm_nombre(nombre) like '% %' order by created_at limit 1;
--   select id into v_a from public.cs_clientes
--   where id <> v_b and programa_id = (select programa_id from public.cs_clientes where id = v_b)
--   order by created_at limit 1;
--   if v_a is null or v_b is null then raise exception 'hacen falta 2 alumnos del mismo programa (uno con nombre y apellido) para probar'; end if;
--   select public.cs_norm_nombre(nombre) into v_nom_b from public.cs_clientes where id = v_b;
--   select user_id into v_fund from public.crm_members where rol = 'fundador' limit 1;
--   if v_fund is null then raise exception 'sin fundador en crm_members'; end if;
--   -- 1. sin nadie de afuera: queda interna
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-127a','inicio_at', now(),
--     'consultor','joaco','origen','sync','clasificar','interna','titulo','Reunion instantanea'));
--   if v_r->>'resultado' <> 'interna' then raise exception 'esperaba interna, vino %', v_r; end if;
--   select id, estado into v_sa, v_est from public.cs_fathom_sin_asignar where externo_id = 'fathom:humo-127a';
--   if v_est <> 'interna' then raise exception 'estado deberia ser interna: %', v_est; end if;
--   v_n := v_n + 2;
--   -- 2. una vuelta de la sync con alguien: pasa de interna a pendiente (y una pendiente no vuelve a interna)
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-127a','inicio_at', now(),
--     'consultor','joaco','origen','sync','invitados','["zz-humo-127@x.com"]'::jsonb));
--   select estado into v_est from public.cs_fathom_sin_asignar where id = v_sa;
--   if v_est <> 'pendiente' then raise exception 'deberia pasar a pendiente: %', v_est; end if;
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-127a','inicio_at', now(),
--     'consultor','joaco','origen','sync','clasificar','interna'));
--   select estado into v_est from public.cs_fathom_sin_asignar where id = v_sa;
--   if v_est <> 'pendiente' then raise exception 'una pendiente no deberia volver a interna: %', v_est; end if;
--   v_n := v_n + 2;
--   -- 3. como fundador: interna -> no es alumno -> reabrir
--   perform set_config('request.jwt.claim.sub', v_fund::text, true);
--   perform set_config('request.jwt.claims', json_build_object('sub', v_fund, 'role', 'authenticated')::text, true);
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-127b','inicio_at', now(),
--     'consultor','joaco','origen','sync','clasificar','interna'));
--   select id into v_id from public.cs_fathom_sin_asignar where externo_id = 'fathom:humo-127b';
--   perform public.cs_fathom_marcar_no_alumno(v_id);
--   select estado into v_est from public.cs_fathom_sin_asignar where id = v_id;
--   if v_est <> 'no_alumno' then raise exception 'esperaba no_alumno: %', v_est; end if;
--   perform public.cs_fathom_reabrir(v_id);
--   select estado into v_est from public.cs_fathom_sin_asignar where id = v_id;
--   if v_est <> 'pendiente' then raise exception 'esperaba pendiente: %', v_est; end if;
--   v_n := v_n + 2;
--   -- 4. la vista muestra las internas al fundador
--   select count(*) into v_cnt from public.cs_v_fathom_llamadas where id = v_id;
--   if v_cnt <> 1 then raise exception 'la vista no muestra la fila: %', v_cnt; end if;
--   v_n := v_n + 1;
--   -- 5. asignar a mano una con nombres: aprende el alias nuevo y NO el nombre de otro alumno
--   v_r := public.cs_fathom_aplicar(jsonb_build_object('externo_id','fathom:humo-127c','inicio_at', now(),
--     'consultor','joaco','origen','sync','clasificar','interna',
--     'nombres', jsonb_build_array('zz humo alias', v_nom_b)));
--   select id into v_id from public.cs_fathom_sin_asignar where externo_id = 'fathom:humo-127c';
--   v_r := public.cs_fathom_asignar(v_id, v_a);
--   v_ll := (v_r->>'llamada_id')::uuid;
--   if (v_r->>'alias_guardados')::int <> 1 then raise exception 'esperaba 1 alias guardado: %', v_r; end if;
--   if jsonb_array_length(v_r->'alias_conflictos') <> 1 then raise exception 'esperaba 1 conflicto: %', v_r; end if;
--   select count(*) into v_cnt from public.cs_clientes_alias where cliente_id = v_a and alias = 'zz humo alias';
--   if v_cnt <> 1 then raise exception 'no guardo el alias'; end if;
--   select count(*) into v_cnt from public.cs_clientes_alias where alias = v_nom_b;
--   if v_cnt <> 0 then raise exception 'guardo el nombre de otro alumno como alias'; end if;
--   v_n := v_n + 4;
--   -- 6. el alias no se puede repetir en otro alumno
--   v_r := public.cs_fathom_aprender_alias(v_b, array['zz humo alias'], 'fathom:humo-127d', 'aprendido');
--   if (v_r->>'guardados')::int <> 0 or jsonb_array_length(v_r->'conflictos') <> 1 then
--     raise exception 'el alias repetido no deberia guardarse: %', v_r;
--   end if;
--   v_n := v_n + 1;
--   -- 7. corregir a otro alumno: el alias aprendido se mueve con la llamada
--   v_r := public.cs_fathom_corregir(v_ll, v_b);
--   select count(*) into v_cnt from public.cs_clientes_alias where cliente_id = v_a and alias = 'zz humo alias';
--   if v_cnt <> 0 then raise exception 'no deshizo el alias del alumno anterior'; end if;
--   select count(*) into v_cnt from public.cs_clientes_alias where cliente_id = v_b and alias = 'zz humo alias';
--   if v_cnt <> 1 then raise exception 'el alumno nuevo no aprendio el alias'; end if;
--   v_n := v_n + 2;
--   -- 8. quitar el alias
--   select id into v_id from public.cs_clientes_alias where cliente_id = v_b and alias = 'zz humo alias';
--   perform public.cs_fathom_alias_quitar(v_id);
--   select count(*) into v_cnt from public.cs_clientes_alias where alias = 'zz humo alias';
--   if v_cnt <> 0 then raise exception 'no quito el alias'; end if;
--   v_n := v_n + 1;
--   raise exception 'HUMO OK: % comprobaciones', v_n;
-- end $$;


-- =====================================================================
-- VUELTA ATRAS (comentada). Pierde los alias, los nombres guardados y el estado del historial.
-- Las internas se pasan a no_alumno ANTES de sacar el estado (no se borran). Las definiciones
-- anteriores de las funciones y de la vista estan en cs_bak_127_funciones; mas simple: despues de
-- este bloque, volver a correr migraciones/126-producto-fathom-asignacion-inteligente.sql (es
-- idempotente) restaura aplicar / asignar / marcar / confirmar / corregir y la vista de la 126.
-- =====================================================================
-- begin;
-- drop view if exists public.cs_v_fathom_llamadas;
-- update public.cs_fathom_sin_asignar set estado = 'no_alumno' where estado = 'interna';
-- alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_127;
-- alter table public.cs_fathom_sin_asignar add constraint cs_fathom_sin_asignar_estado_124
--   check (estado in ('pendiente', 'asignada', 'no_alumno'));
-- drop function if exists public.cs_fathom_alias_agregar(uuid, text);
-- drop function if exists public.cs_fathom_alias_quitar(uuid);
-- drop function if exists public.cs_fathom_aprender_alias(uuid, text[], text, text);
-- drop function if exists public.cs_fathom_confirmar(uuid);
-- drop table if exists public.cs_clientes_alias;
-- drop function if exists public.cs_fathom_puede_alias(text);
-- alter table public.cs_fathom_consultores
--   drop column if exists hist_estado, drop column if exists hist_desde, drop column if exists hist_hasta,
--   drop column if exists hist_cursor, drop column if exists hist_oldest, drop column if exists hist_desc,
--   drop column if exists hist_traidas, drop column if exists hist_inicio_at, drop column if exists hist_fin_at;
-- alter table public.cs_fathom_corridas drop column if exists internas;
-- alter table public.cs_fathom_sin_asignar drop column if exists nombres;
-- alter table public.cs_llamadas drop column if exists nombres;
-- commit;
-- -- y volver a correr migraciones/126-producto-fathom-asignacion-inteligente.sql
