-- =====================================================================
-- 157 · Producto · Fathom: alumnos grupales vs VIP y consultorias grupales
-- =====================================================================
-- Requiere (corridas): 102, 106, 124, 126, 127, 134, 135, 137.  Opcional: 139-141 (si estan, se parchan sus consultas).
-- SIN PROBAR: se escribio sin poder correr SQL. Correr fuera de :00/:15/:30/:45 y de las 9:00 ART.
--
-- Como funcionan los programas (Joaquin, 16/10):
--   grupal = UNA sola llamada 1 a 1 (el onboarding); despues solo clases / consultorias grupales.
--   VIP / 1 a 1 = llamadas 1 a 1 periodicas.
--   Las consultorias no tienen nombre en Fathom: se reconocen por DIA y HORA (ART).
--
-- Que hace:
--   A. cs_clientes.modalidad ('grupal' | 'vip' | null = automatica). Si es null se deduce del producto / plan
--      (cs_modalidad_calc); si no se puede deducir queda "sin dato" y el alumno se trata como hasta hoy (1 a 1).
--      Vista cs_v_modalidad (modalidad efectiva, manual, automatica y de donde sale).
--   B. cs_consultoria_horarios: horarios recurrentes por cliente (programa) y consultor, editables por el fundador.
--      Precarga: teo, joaco, viernes 18:00. Una reunion de Fathom del consultor que arranca dentro de la
--      tolerancia de un horario activo es una consultoria grupal de ese cliente.
--   C. cs_consultorias (+ cs_consultoria_transcripciones, solo edicion) y cs_consultoria_asistentes (quien estuvo,
--      por mail / nombre / hablante, y lo que dijo cada alumno: la columna intervenciones NO se lee desde el front;
--      la usan las funciones de IA con service role).
--   D. Funciones: cs_consultoria_horario_buscar, cs_consultoria_registrar (la llama fathom-sync),
--      cs_consultoria_procesar (asistentes + intervenciones por alumno + preguntas -> cs_duda_candidatas),
--      cs_consultoria_reclasificar (fundador: reclasifica llamadas ya sincronizadas; se corre una vez ACA).
--   E. cs_v_ultima_llamada (reemplaza): grupal = ultima consultoria a la que asistio; sin datos de asistencia
--      => sin_alerta = true (no se alerta por falta de 1 a 1). Columnas nuevas al final: modalidad, sin_alerta,
--      onboarding_fecha, ultima_consultoria. cs_v_llamadas_clase: onboarding / uno_a_uno / consultoria / otra.
--   F. Parches SUAVES por replace sobre las definiciones vigentes: cs_servicio_armar (aviso diario) y
--      cs_chat_atrasados (chat): no cuentan a los grupales sin datos de asistencia. Si un punto de anclaje no
--      esta exactamente una vez, esa funcion NO se toca y queda avisada (control C7).
--   G. cs_v_alumno_resumen (reemplaza, misma forma): "En que esta" no sale de una consultoria grupal.
--      cs_ia_en_que_esta_pendientes / _contar: tambien cuentan consultorias nuevas con lo que dijo el alumno.
--
-- No toca: crons, finanzas, crm, ventas, Dystopita, ia-preguntar. No borra datos. Se puede correr dos veces.
-- Vuelta atras y controles comentados al final.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo
do $$
declare
  v_falta text;
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'cs 157: hace falta Postgres 15 o mas';
  end if;
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_clientes', 'cs_productos', 'cs_calls', 'cs_seguimientos', 'cs_llamadas',
                    'cs_llamada_transcripciones', 'cs_fathom_consultores', 'cs_fathom_sin_asignar',
                    'cs_clientes_mails', 'cs_clientes_alias', 'cs_duda_candidatas', 'cs_dudas_config',
                    'cs_en_que_esta', 'cs_v_ultima_llamada', 'cs_v_alumno_resumen']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception 'cs 157: faltan objetos (corrieron 102, 106, 124, 126, 127, 134, 135 y 137?): %', v_falta;
  end if;
  select string_agg(r.f, ', ') into v_falta
  from (values ('es_fundador()'), ('cs_hoy()'), ('cs_norm_nombre(text)'), ('cs_tg_updated_at()'),
               ('cs_puede_ver(text)'), ('cs_puede_editar(text)'), ('cs_dudas_cfg(text)'),
               ('cs_ia_en_que_esta_pendientes(int, text)'), ('cs_ia_en_que_esta_contar(text)')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 157: faltan funciones: %', v_falta;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_duda_candidatas' and column_name = 'confianza') then
    raise exception 'cs 157: falta cs_duda_candidatas.confianza (135)';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_clientes' and column_name = 'email') then
    raise exception 'cs 157: falta cs_clientes.email';
  end if;
end $$;

-- Lock de todo lo que se altera, junto (regla del deadlock).
lock table public.cs_programas, public.cs_clientes, public.cs_llamadas, public.cs_fathom_sin_asignar,
           public.cs_duda_candidatas, public.cs_en_que_esta, public.cs_fathom_consultores
  in share row exclusive mode;

-- Respaldo de lo que se reemplaza o parcha (solo la primera vez).
create table if not exists public.cs_bak_157_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
alter table public.cs_bak_157_funciones enable row level security;
revoke all on table public.cs_bak_157_funciones from public, anon, authenticated;
insert into public.cs_bak_157_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('cs_ia_en_que_esta_pendientes', 'cs_ia_en_que_esta_contar')
on conflict (funcion) do nothing;
insert into public.cs_bak_157_funciones (funcion, definicion)
select 'view public.cs_v_ultima_llamada', pg_get_viewdef('public.cs_v_ultima_llamada'::regclass, true)
on conflict (funcion) do nothing;
insert into public.cs_bak_157_funciones (funcion, definicion)
select 'view public.cs_v_alumno_resumen', pg_get_viewdef('public.cs_v_alumno_resumen'::regclass, true)
on conflict (funcion) do nothing;


-- =====================================================================
-- A. Modalidad del alumno
-- =====================================================================
alter table public.cs_clientes
  add column if not exists modalidad text check (modalidad is null or modalidad in ('grupal', 'vip'));
comment on column public.cs_clientes.modalidad is
  '157: grupal | vip. Null = automatica (se deduce del producto / plan con cs_modalidad_calc; si no se puede, sin dato). Se edita en la ficha.';

-- Producto / plan -> modalidad. VIP gana si el texto menciona 1 a 1 (mas especifico que "comunidad").
create or replace function public.cs_modalidad_calc(p_manual text, p_plan text, p_producto text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select case
    when p_manual in ('grupal', 'vip') then p_manual
    else (
      select case
        when t ~ '(\m1 ?(a|x|-|:) ?1\M|uno a uno|one ?on ?one|\mvip\M|individual)' then 'vip'
        when t ~ '(grupal|grupo|comunidad|group)' then 'grupal'
      end
      from (select translate(lower(coalesce(p_producto, '') || ' ' || coalesce(p_plan, '')), 'áéíóúü', 'aeiouu') as t) x
    )
  end
$$;

create or replace view public.cs_v_modalidad
with (security_invoker = on) as
select c.id as cliente_id, c.programa_id,
       public.cs_modalidad_calc(c.modalidad, c.plan, pr.nombre) as modalidad,
       c.modalidad as modalidad_manual,
       public.cs_modalidad_calc(null, c.plan, pr.nombre) as modalidad_auto,
       case when c.modalidad is not null then 'manual'
            when public.cs_modalidad_calc(null, c.plan, pr.nombre) is not null then 'automatica'
            else 'sin_dato' end as origen
from public.cs_clientes c
left join public.cs_productos pr on pr.id = c.producto_id;
revoke all on table public.cs_v_modalidad from anon;
revoke insert, update, delete on table public.cs_v_modalidad from authenticated;
grant select on table public.cs_v_modalidad to authenticated;


-- =====================================================================
-- B. Horarios de consultorias grupales
-- =====================================================================
create table if not exists public.cs_consultoria_horarios (
  id             uuid primary key default gen_random_uuid(),
  programa_id    text not null references public.cs_programas(id),
  consultor      text not null references public.cs_fathom_consultores(id),
  dia_semana     smallint not null check (dia_semana between 1 and 7),     -- ISO: 1 lunes ... 7 domingo
  hora           time not null,                                            -- hora de inicio, ART
  duracion_min   int not null default 60 check (duracion_min between 15 and 480),
  tolerancia_min int not null default 30 check (tolerancia_min between 0 and 240),
  activo         boolean not null default true,
  nota           text check (nota is null or char_length(nota) <= 200),
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  updated_at     timestamptz not null default now()
);
create unique index if not exists cs_consultoria_horarios_uk
  on public.cs_consultoria_horarios (programa_id, consultor, dia_semana, hora);
create index if not exists cs_consultoria_horarios_consultor_idx
  on public.cs_consultoria_horarios (consultor) where activo;
comment on table public.cs_consultoria_horarios is
  '157: horarios recurrentes de consultorias grupales (hora ART). Una reunion de Fathom del consultor que arranca a +-tolerancia_min de la hora, ese dia de la semana, es una consultoria grupal del cliente (programa). Escribe solo el fundador.';

drop trigger if exists cs_consultoria_horarios_updated_at on public.cs_consultoria_horarios;
create trigger cs_consultoria_horarios_updated_at before update on public.cs_consultoria_horarios
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_consultoria_horarios enable row level security;
revoke all on table public.cs_consultoria_horarios from anon, authenticated;
grant select, insert, update, delete on table public.cs_consultoria_horarios to authenticated;
grant select on table public.cs_consultoria_horarios to service_role;
drop policy if exists cs_select on public.cs_consultoria_horarios;
create policy cs_select on public.cs_consultoria_horarios for select to authenticated
  using (coalesce(public.es_fundador(), false) or public.cs_puede_ver(programa_id));
drop policy if exists cs_fundador_insert on public.cs_consultoria_horarios;
create policy cs_fundador_insert on public.cs_consultoria_horarios for insert to authenticated
  with check (coalesce(public.es_fundador(), false));
drop policy if exists cs_fundador_update on public.cs_consultoria_horarios;
create policy cs_fundador_update on public.cs_consultoria_horarios for update to authenticated
  using (coalesce(public.es_fundador(), false)) with check (coalesce(public.es_fundador(), false));
drop policy if exists cs_fundador_delete on public.cs_consultoria_horarios;
create policy cs_fundador_delete on public.cs_consultoria_horarios for delete to authenticated
  using (coalesce(public.es_fundador(), false));

-- Precarga: teo, consultor Joaquin (cuenta joaco), viernes 18:00 ART. Duracion 60 supuesta: ajustarla en la pantalla.
insert into public.cs_consultoria_horarios (programa_id, consultor, dia_semana, hora, duracion_min, tolerancia_min, nota)
select 'teo', 'joaco', 5, time '18:00', 60, 30, 'Consultoria grupal de los viernes (precarga de la 157)'
where exists (select 1 from public.cs_programas where id = 'teo')
  and exists (select 1 from public.cs_fathom_consultores where id = 'joaco')
on conflict (programa_id, consultor, dia_semana, hora) do nothing;

-- Horario que corresponde a una reunion (la mas cercana a la hora de inicio) o null.
create or replace function public.cs_consultoria_horario_buscar(p_consultor text, p_inicio timestamptz)
returns uuid
language sql stable security definer set search_path = public
as $$
  select h.id
  from public.cs_consultoria_horarios h,
       lateral (select (p_inicio at time zone 'America/Argentina/Buenos_Aires') as loc) t
  where h.activo
    and p_consultor is not null and p_inicio is not null
    and h.consultor = p_consultor
    and h.dia_semana = extract(isodow from t.loc)::int
    and abs(extract(epoch from (t.loc::time - h.hora))) <= h.tolerancia_min * 60
  order by abs(extract(epoch from (t.loc::time - h.hora))), h.programa_id
  limit 1
$$;
revoke all on function public.cs_consultoria_horario_buscar(text, timestamptz) from public, anon, authenticated;
grant execute on function public.cs_consultoria_horario_buscar(text, timestamptz) to service_role;


-- =====================================================================
-- C. Consultorias, transcripcion y asistentes
-- =====================================================================
create table if not exists public.cs_consultorias (
  id                  uuid primary key default gen_random_uuid(),
  programa_id         text not null references public.cs_programas(id),
  horario_id          uuid references public.cs_consultoria_horarios(id) on delete set null,
  consultor           text references public.cs_fathom_consultores(id),
  externo_id          text not null unique check (btrim(externo_id) <> '' and char_length(externo_id) <= 200),
  fecha               date not null,
  inicio_at           timestamptz not null,
  titulo              text check (titulo is null or char_length(titulo) <= 200),
  duracion_min        int check (duracion_min is null or duracion_min >= 0),
  grabacion_url       text check (grabacion_url is null or (grabacion_url ~* '^https?://[^[:space:]]+$' and char_length(grabacion_url) <= 1000)),
  grabacion_share_url text check (grabacion_share_url is null or (grabacion_share_url ~* '^https?://[^[:space:]]+$' and char_length(grabacion_share_url) <= 1000)),
  resumen             text check (resumen is null or char_length(resumen) <= 4000),
  invitados           jsonb not null default '[]'::jsonb check (jsonb_typeof(invitados) = 'array'),   -- [{nombre, email}]
  transc_md5          text,
  procesada_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists cs_consultorias_programa_fecha_idx on public.cs_consultorias (programa_id, fecha desc);
comment on table public.cs_consultorias is
  '157: reuniones de Fathom que caen en un horario de cs_consultoria_horarios. No son llamadas de un alumno: la asistencia vive en cs_consultoria_asistentes.';

drop trigger if exists cs_consultorias_updated_at on public.cs_consultorias;
create trigger cs_consultorias_updated_at before update on public.cs_consultorias
  for each row execute function public.cs_tg_updated_at();

create table if not exists public.cs_consultoria_transcripciones (
  consultoria_id uuid primary key references public.cs_consultorias(id) on delete cascade,
  programa_id    text not null references public.cs_programas(id),
  texto          text not null check (btrim(texto) <> '' and char_length(texto) <= 200000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.cs_consultoria_transcripciones is
  '157: transcripcion de una consultoria grupal. Solo la ve quien edita el programa (como cs_llamada_transcripciones).';

create table if not exists public.cs_consultoria_asistentes (
  consultoria_id uuid not null references public.cs_consultorias(id) on delete cascade,
  cliente_id     uuid not null,
  programa_id    text not null references public.cs_programas(id),
  via            text not null check (via in ('mail', 'nombre', 'hablante', 'llamada', 'manual')),
  hablo          boolean not null default false,
  intervenciones text check (intervenciones is null or char_length(intervenciones) <= 20000),
  created_at     timestamptz not null default now(),
  primary key (consultoria_id, cliente_id),
  constraint cs_consultoria_asist_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_consultoria_asist_cliente_idx on public.cs_consultoria_asistentes (cliente_id);
comment on table public.cs_consultoria_asistentes is
  '157: quien estuvo en cada consultoria (via: mail | nombre del invitado | hablante de la transcripcion | su llamada ya asignada | manual). intervenciones = lineas del alumno en la transcripcion; sin permiso de lectura desde el front.';

do $$
declare
  t text;
begin
  foreach t in array array['cs_consultorias', 'cs_consultoria_transcripciones', 'cs_consultoria_asistentes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant select on table public.%I to service_role', t);
  end loop;
end $$;
-- Lectura desde la app: consultorias y asistencia, quien ve el programa; transcripcion, quien edita.
grant select on table public.cs_consultorias to authenticated;
grant select (consultoria_id, cliente_id, programa_id, via, hablo, created_at)
  on table public.cs_consultoria_asistentes to authenticated;
grant select on table public.cs_consultoria_transcripciones to authenticated;
drop policy if exists cs_select on public.cs_consultorias;
create policy cs_select on public.cs_consultorias for select to authenticated
  using (public.cs_puede_ver(programa_id));
drop policy if exists cs_select on public.cs_consultoria_asistentes;
create policy cs_select on public.cs_consultoria_asistentes for select to authenticated
  using (public.cs_puede_ver(programa_id));
drop policy if exists cs_select on public.cs_consultoria_transcripciones;
create policy cs_select on public.cs_consultoria_transcripciones for select to authenticated
  using (public.cs_puede_editar(programa_id));
-- Sin politicas de escritura: se escribe por las funciones de abajo (security definer).

-- Una llamada ya sincronizada que resulta ser una consultoria: queda guardada pero marcada.
alter table public.cs_llamadas
  add column if not exists consultoria_id uuid references public.cs_consultorias(id) on delete set null;
create index if not exists cs_llamadas_consultoria_idx on public.cs_llamadas (consultoria_id) where consultoria_id is not null;
comment on column public.cs_llamadas.consultoria_id is
  '157: si no es null la reunion fue una consultoria grupal (clase = consultoria): no cuenta como 1 a 1 ni alimenta "En que esta" del alumno.';

-- Las preguntas de las consultorias entran a la misma lista de candidatas a duda frecuente.
alter table public.cs_duda_candidatas
  add column if not exists consultoria_id uuid references public.cs_consultorias(id) on delete cascade;
alter table public.cs_duda_candidatas alter column llamada_id drop not null;
alter table public.cs_duda_candidatas drop constraint if exists cs_duda_cand_origen_157_chk;
alter table public.cs_duda_candidatas add constraint cs_duda_cand_origen_157_chk
  check (llamada_id is not null or consultoria_id is not null);
create unique index if not exists cs_duda_cand_consultoria_texto_uk
  on public.cs_duda_candidatas (consultoria_id, cliente_id, texto_norm) where consultoria_id is not null;
comment on column public.cs_duda_candidatas.consultoria_id is
  '157: consultoria grupal de la que salio la pregunta (llamada_id queda null).';

-- Estado nuevo de la lista "Llamadas": ya es una consultoria.
alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_127;
alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_157;
alter table public.cs_fathom_sin_asignar add constraint cs_fathom_sin_asignar_estado_157
  check (estado in ('pendiente', 'asignada', 'no_alumno', 'interna', 'consultoria'));
comment on column public.cs_fathom_sin_asignar.estado is
  '157: pendiente | interna | no_alumno | asignada (ya es una llamada de cs_llamadas) | consultoria (cayo en un horario de consultoria grupal: vive en cs_consultorias).';

-- "En que esta" automatico: consultorias ya vistas.
alter table public.cs_en_que_esta add column if not exists consultorias_ids uuid[] not null default '{}';


-- =====================================================================
-- D. Funciones
-- =====================================================================

-- D1. Alumno por mail (principal o extra) dentro de un programa. Null si no hay o hay mas de uno.
create or replace function public.cs_consultoria_match_mail(p_programa text, p_mail text)
returns uuid
language sql stable security definer set search_path = public
as $$
  select case when count(distinct x.id) = 1 then (array_agg(distinct x.id))[1] end
  from (
    select c.id from public.cs_clientes c
     where c.programa_id = p_programa and lower(btrim(c.email)) = lower(btrim(p_mail))
    union all
    select m.cliente_id from public.cs_clientes_mails m
     where m.programa_id = p_programa and m.email = lower(btrim(p_mail))
  ) x
$$;
revoke all on function public.cs_consultoria_match_mail(text, text) from public, anon, authenticated;

-- D2. Alumno por nombre (2 palabras o mas): exacto contra nombre o alias; si no, primera y ultima palabra
-- iguales y las del mas corto incluidas en el mas largo. Null si no hay o hay mas de uno.
create or replace function public.cs_consultoria_match_nombre(p_programa text, p_nombre text)
returns uuid
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_n    text := public.cs_norm_nombre(p_nombre);
  v_toks text[];
  v_ids  uuid[];
begin
  if v_n is null or position(' ' in v_n) = 0 then
    return null;
  end if;
  v_toks := string_to_array(v_n, ' ');

  select array_agg(distinct x.id) into v_ids
  from (
    select c.id from public.cs_clientes c
     where c.programa_id = p_programa and public.cs_norm_nombre(c.nombre) = v_n
    union
    select a.cliente_id from public.cs_clientes_alias a
     where a.programa_id = p_programa and a.alias = v_n
  ) x;
  if coalesce(cardinality(v_ids), 0) = 1 then return v_ids[1]; end if;
  if coalesce(cardinality(v_ids), 0) > 1 then return null; end if;

  select array_agg(distinct y.id) into v_ids
  from (
    select c.id, string_to_array(public.cs_norm_nombre(c.nombre), ' ') as ct
      from public.cs_clientes c where c.programa_id = p_programa
    union all
    select a.cliente_id, string_to_array(a.alias, ' ')
      from public.cs_clientes_alias a where a.programa_id = p_programa
  ) y
  where y.ct[1] = v_toks[1]
    and y.ct[cardinality(y.ct)] = v_toks[cardinality(v_toks)]
    and (case when cardinality(v_toks) <= cardinality(y.ct) then v_toks <@ y.ct else y.ct <@ v_toks end);
  if coalesce(cardinality(v_ids), 0) = 1 then return v_ids[1]; end if;
  return null;
end;
$fn$;
revoke all on function public.cs_consultoria_match_nombre(text, text) from public, anon, authenticated;

-- D3. Preguntas de un alumno en una consultoria. Misma regla que cs_dudas_extraer (135) pero sobre el
-- texto del alumno ya separado ("[hora] Nombre: texto" por linea). No escribe.
create or replace function public.cs_consultoria_preguntas(p_programa text, p_texto text)
returns table (hablante text, texto text, regla text, puntaje int)
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_cfg    jsonb := public.cs_dudas_cfg(p_programa);
  v_pal    boolean := (v_cfg ->> 'regla_palabra')::boolean;
  v_min    int := (v_cfg ->> 'min_palabras')::int;
  v_max    int := (v_cfg ->> 'max_por_llamada')::int;
  v_seg    boolean := (v_cfg ->> 'filtrar_segunda_persona')::boolean;
  v_vacias text[] := array['para', 'como', 'esta', 'este', 'esto', 'esos', 'esas', 'pero', 'porque', 'cuando',
                           'donde', 'tengo', 'tiene', 'tienen', 'hacer', 'puedo', 'sobre', 'entre', 'desde',
                           'hasta', 'algo', 'todo', 'toda', 'todos', 'todas', 'cual', 'cuales', 'quien',
                           'cuanto', 'cuanta', 'puede', 'puedes', 'podes', 'seria', 'hace', 'haces', 'hago'];
begin
  if nullif(btrim(coalesce(p_texto, '')), '') is null then
    return;
  end if;
  return query
  with ln as (
    select btrim(m[1]) as quien, btrim(m[2]) as txt
    from regexp_split_to_table(p_texto, E'\r?\n') x,
         lateral (select regexp_match(x, '^\[[^\]]*\]\s*([^:]{1,80}):\s*(.*)$') as m) q
    where q.m is not null
  ),
  se as (
    select ln.quien, btrim(s.s) as s
    from ln, lateral regexp_split_to_table(ln.txt, '(?<=[.!?…])\s+') as s(s)
  ),
  q as (
    select se.quien,
           btrim(case when position('¿' in se.s) > 0 then substring(se.s from '¿[^¿]*$') else se.s end) as s2
    from se
  ),
  n as (
    select q.quien, q.s2,
           public.cs_norm_nombre(q.s2) as nn,
           (q.s2 ~ '\?[\s"”)]*$') as con_signo
    from q
  ),
  k as (
    select n.*,
           regexp_replace(n.nn,
             '^((eh|em|este|bueno|pero|y|o|entonces|mira|che|ok|dale|osea|o sea|igual|ah|a ver|disculpa|perdon|una pregunta|una duda|te queria preguntar|queria preguntar|queria saber) )+',
             '') as n2
    from n
    where n.nn is not null
  ),
  z as (
    select k.*,
           coalesce(array_length(string_to_array(k.n2, ' '), 1), 0) as nw,
           (k.n2 ~ '^(como|que|cuando|donde|por que|cuanto|cuanta|cuantos|cuantas|cual|cuales|quien|quienes|se puede|se pueden|hay que|puedo|podria|podemos|podes|puedes|tengo que|debo|deberia|conviene|es posible|existe|hay alguna|hay algun|hay forma|hay manera)( |$)') as empieza,
           (k.nn ~ '\m(escuch|oyen|oyes|oigo|congel|microfon|camar|conexion|audio|pantalla|link|enlace|grabac|grabando|grabar|horario|invitacion|calendario|agendar|reagend|reprogram|zoom\M|meet\M)'
              or k.nn ~ '\m(me|se) (ve|ves|ven|corta|cortan|escucha|escuchan|oye|oyen)\M'
              or k.nn ~ '\m(a que hora|que hora|proxima (llamada|reunion|clase|sesion)|esta grabando|estan grabando)'
              or k.n2 ~ '^(estas|estan|seguis|sigues|ahi|hola|me escuchas|me oyes|me ves|se ve|se ven|se escucha|se corta)( |$)') as ruido,
           (k.n2 ~ '^(como (te|les|le|ya|dije|dijimos|vimos|siempre|quedamos|hablamos|mencione|comentaba|decia)|que (bueno|lindo|bien|genial|barbaro|se yo|tal|loco|mal|pena|raro)|cuando (quieras|puedas)|donde (quieras|sea))') as no_preg,
           (k.nn ~ ' (no|si|verdad|cierto|viste|entendes|entiendes|ok|dale|te parece)$') as tag,
           (k.n2 ~ '^(ya )?(tenes|tienes|pudiste|pudieron|viste|vieron|lograste|lograron|hiciste|probaste|revisaste|miraste|leiste|completaste|terminaste|llegaste|alcanzaste|me mostras|me muestras|me contas|me cuentas|me pasas|me compartis|me compartes|me dejas|te quedo|te queda|te parece|te sirve|te resulta|entendes|entiendes|se entiende|queda claro|como vas|como te va|como te fue|como estas|como andas|como venis|como vienes|como te sentis|como te sientes|cuanto llevas|en que estas|en que andas|que tal)( |$)'
              or k.n2 ~ ' (se entiende|te quedo claro|queda claro|tiene sentido|me explico)$') as segunda,
           (select count(*) from unnest(string_to_array(k.n2, ' ')) w
             where char_length(w) >= 4 and w <> all (v_vacias))::int as cont
    from k
  ),
  sel as (
    select z.quien as qn, left(btrim(z.s2), 300) as t, z.n2,
           case when z.con_signo then 'signo' else 'palabra' end as rg,
           z.cont,
           row_number() over (partition by z.n2 order by z.cont desc, char_length(z.s2) desc) as dup
    from z
    where not z.ruido and not z.no_preg
      and not (v_seg and z.segunda)
      and ((z.con_signo and z.nw >= v_min and (z.empieza or not z.tag))
           or (v_pal and not z.con_signo and z.empieza and z.nw >= v_min))
  ),
  top as (
    select s.*,
           row_number() over (order by s.cont desc, char_length(s.t) desc, s.t) as rn
    from sel s where s.dup = 1
  )
  select t.qn, t.t, t.rg, t.cont
  from top t
  where t.rn <= v_max
  order by t.rn;
end;
$fn$;
revoke all on function public.cs_consultoria_preguntas(text, text) from public, anon, authenticated;

-- D4. Procesar una consultoria: asistentes (invitados por mail / nombre, hablantes de la transcripcion,
-- alumno de una llamada ya asignada), lo que dijo cada alumno, y sus preguntas como candidatas a duda.
-- Idempotente. Interna: la llaman cs_consultoria_aplicar y cs_consultoria_reclasificar.
create or replace function public.cs_consultoria_procesar(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  k       public.cs_consultorias;
  v_texto text;
  x       jsonb;
  v_mail  text;
  v_nom   text;
  v_cid   uuid;
  v_via   text;
  a       record;
  v_max   int;
  v_cupo  int;
  v_n     int;
  v_preg  int := 0;
begin
  select * into k from public.cs_consultorias where id = p_id;
  if not found then
    return jsonb_build_object('error', 'no existe');
  end if;
  select t.texto into v_texto from public.cs_consultoria_transcripciones t where t.consultoria_id = p_id;

  -- 1. invitados: por mail y, si no, por nombre
  for x in select e from jsonb_array_elements(k.invitados) e loop
    v_mail := lower(btrim(case jsonb_typeof(x) when 'string' then x #>> '{}' else coalesce(x ->> 'email', '') end));
    v_nom  := case when jsonb_typeof(x) = 'object' then x ->> 'nombre' end;
    v_cid := null; v_via := null;
    if v_mail is not null and v_mail <> '' then
      v_cid := public.cs_consultoria_match_mail(k.programa_id, v_mail);
      v_via := 'mail';
    end if;
    if v_cid is null and v_nom is not null then
      v_cid := public.cs_consultoria_match_nombre(k.programa_id, v_nom);
      v_via := 'nombre';
    end if;
    if v_cid is not null then
      insert into public.cs_consultoria_asistentes (consultoria_id, cliente_id, programa_id, via)
      values (p_id, v_cid, k.programa_id, v_via)
      on conflict (consultoria_id, cliente_id) do nothing;
    end if;
  end loop;

  -- 2. alumno de una llamada ya asignada (reclasificada)
  insert into public.cs_consultoria_asistentes (consultoria_id, cliente_id, programa_id, via)
  select p_id, l.cliente_id, l.programa_id, 'llamada'
  from public.cs_llamadas l where l.consultoria_id = p_id
  on conflict (consultoria_id, cliente_id) do nothing;

  -- 3. hablantes de la transcripcion -> alumnos; sus lineas quedan en intervenciones
  if v_texto is not null then
    with ln as (
      select t.n, t.l, btrim((regexp_match(t.l, '^\[[^\]]*\]\s*([^:]{1,80}):'))[1]) as quien
      from unnest(string_to_array(replace(v_texto, E'\r', ''), E'\n')) with ordinality as t(l, n)
    ), sp as (
      select distinct ln.quien from ln where ln.quien is not null
    ), m as (
      select sp.quien, public.cs_consultoria_match_nombre(k.programa_id, sp.quien) as cid from sp
    ), agg as (
      select m.cid, string_agg(ln.l, E'\n' order by ln.n) as txt
      from m join ln on ln.quien = m.quien
      where m.cid is not null
      group by m.cid
    )
    insert into public.cs_consultoria_asistentes (consultoria_id, cliente_id, programa_id, via, hablo, intervenciones)
    select p_id, agg.cid, k.programa_id, 'hablante', true, left(agg.txt, 20000)
    from agg
    on conflict (consultoria_id, cliente_id)
    do update set hablo = true, intervenciones = excluded.intervenciones;
  end if;

  -- 4. preguntas de cada alumno -> candidatas a duda (confianza alta: el hablante se reconocio por nombre completo)
  v_max := (public.cs_dudas_cfg(k.programa_id) ->> 'max_por_llamada')::int;
  for a in select s.cliente_id, s.programa_id, s.intervenciones
           from public.cs_consultoria_asistentes s
           where s.consultoria_id = p_id and nullif(btrim(coalesce(s.intervenciones, '')), '') is not null
  loop
    v_cupo := greatest(v_max - (select count(*) from public.cs_duda_candidatas c
                                where c.consultoria_id = p_id and c.cliente_id = a.cliente_id), 0)::int;
    insert into public.cs_duda_candidatas
      (programa_id, cliente_id, consultoria_id, fecha, consultor, hablante, texto, regla, confianza, motivo)
    select a.programa_id, a.cliente_id, p_id, k.fecha, k.consultor, e.hablante, e.texto, e.regla,
           case when e.regla = 'palabra' then 'baja' else 'alta' end,
           case when e.regla = 'palabra' then 'palabra' else 'nombre' end
    from public.cs_consultoria_preguntas(k.programa_id, a.intervenciones) e
    where not exists (select 1 from public.cs_duda_candidatas c
                       where c.consultoria_id = p_id and c.cliente_id = a.cliente_id
                         and c.texto_norm = public.cs_norm_nombre(e.texto))
    order by e.puntaje desc, char_length(e.texto) desc, e.texto
    limit v_cupo
    on conflict (consultoria_id, cliente_id, texto_norm) where consultoria_id is not null do nothing;
    get diagnostics v_n = row_count;
    v_preg := v_preg + v_n;
  end loop;

  update public.cs_consultorias set procesada_at = now() where id = p_id;
  return jsonb_build_object(
    'asistentes', (select count(*) from public.cs_consultoria_asistentes where consultoria_id = p_id),
    'hablaron',   (select count(*) from public.cs_consultoria_asistentes where consultoria_id = p_id and hablo),
    'preguntas_nuevas', v_preg);
end;
$fn$;
revoke all on function public.cs_consultoria_procesar(uuid) from public, anon, authenticated;

-- D5. Crear / actualizar una consultoria desde el payload de fathom-sync (o de la reclasificacion).
-- p: externo_id, consultor, inicio_at, titulo, duracion_min, grabacion_url, grabacion_share_url, resumen,
--    transcripcion, asistentes [{nombre, email}]. Si la reunion no cae en un horario: { resultado: 'sin_horario' }.
create or replace function public.cs_consultoria_aplicar(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_ext    text := nullif(btrim(p ->> 'externo_id'), '');
  v_cons   text := nullif(btrim(coalesce(p ->> 'consultor', '')), '');
  v_ini    timestamptz := nullif(p ->> 'inicio_at', '')::timestamptz;
  v_hor    uuid;
  v_prog   text;
  v_fecha  date;
  v_titulo text := nullif(left(btrim(coalesce(p ->> 'titulo', '')), 200), '');
  v_dur    int  := case when (p ->> 'duracion_min') ~ '^\d{1,4}$' then (p ->> 'duracion_min')::int end;
  v_url    text := case when (p ->> 'grabacion_url') ~* '^https?://[^[:space:]]+$'
                         and char_length(p ->> 'grabacion_url') <= 1000 then p ->> 'grabacion_url' end;
  v_share  text := case when (p ->> 'grabacion_share_url') ~* '^https?://[^[:space:]]+$'
                         and char_length(p ->> 'grabacion_share_url') <= 1000 then p ->> 'grabacion_share_url' end;
  v_res    text := nullif(left(btrim(coalesce(p ->> 'resumen', '')), 4000), '');
  v_transc text := nullif(left(btrim(coalesce(p ->> 'transcripcion', '')), 200000), '');
  v_md5    text;
  v_old    text;
  v_inv    jsonb;
  v_id     uuid;
  v_nueva  boolean;
begin
  if v_ext is null or v_ini is null then
    raise exception 'cs: faltan externo_id o inicio_at' using errcode = '22023';
  end if;
  v_hor := public.cs_consultoria_horario_buscar(v_cons, v_ini);
  if v_hor is null then
    return jsonb_build_object('resultado', 'sin_horario');
  end if;
  select h.programa_id into v_prog from public.cs_consultoria_horarios h where h.id = v_hor;
  v_fecha := least((v_ini at time zone 'America/Argentina/Buenos_Aires')::date, public.cs_hoy());
  v_md5 := case when v_transc is not null then md5(v_transc) end;

  select coalesce(jsonb_agg(jsonb_build_object('nombre', t.nom, 'email', t.mail)), '[]'::jsonb) into v_inv
  from (
    select nullif(left(btrim(coalesce(e ->> 'nombre', '')), 80), '') as nom,
           case when lower(btrim(coalesce(e ->> 'email', ''))) ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
                then lower(btrim(e ->> 'email')) end as mail
    from jsonb_array_elements(case when jsonb_typeof(p -> 'asistentes') = 'array' then p -> 'asistentes' else '[]'::jsonb end) e
    limit 60
  ) t
  where t.nom is not null or t.mail is not null;

  select c.id, c.transc_md5 into v_id, v_old from public.cs_consultorias c where c.externo_id = v_ext;
  v_nueva := v_id is null;
  if v_nueva then
    insert into public.cs_consultorias (programa_id, horario_id, consultor, externo_id, fecha, inicio_at, titulo,
                                        duracion_min, grabacion_url, grabacion_share_url, resumen, invitados, transc_md5)
    values (v_prog, v_hor, v_cons, v_ext, v_fecha, v_ini, v_titulo, v_dur, v_url, v_share, v_res, v_inv, v_md5)
    returning id into v_id;
  else
    update public.cs_consultorias set
      horario_id = coalesce(horario_id, v_hor),
      consultor = coalesce(consultor, v_cons),
      titulo = coalesce(titulo, v_titulo),
      duracion_min = coalesce(duracion_min, v_dur),
      grabacion_url = coalesce(grabacion_url, v_url),
      grabacion_share_url = coalesce(grabacion_share_url, v_share),
      resumen = coalesce(resumen, v_res),
      invitados = case when invitados = '[]'::jsonb then v_inv else invitados end,
      transc_md5 = coalesce(v_md5, transc_md5)
    where id = v_id;
  end if;

  -- transcripcion: la nueva, o la de la llamada que esta reunion ya era
  if v_transc is not null then
    insert into public.cs_consultoria_transcripciones (consultoria_id, programa_id, texto)
    values (v_id, v_prog, v_transc)
    on conflict (consultoria_id) do update set texto = excluded.texto
      where public.cs_consultoria_transcripciones.texto is distinct from excluded.texto;
  else
    insert into public.cs_consultoria_transcripciones (consultoria_id, programa_id, texto)
    select v_id, v_prog, t.texto
    from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
    where l.externo_id = v_ext
    limit 1
    on conflict (consultoria_id) do nothing;
  end if;

  -- si la reunion ya habia entrado como llamada de un alumno o como pendiente / interna, se reclasifica
  update public.cs_llamadas set consultoria_id = v_id where externo_id = v_ext and consultoria_id is distinct from v_id;
  update public.cs_fathom_sin_asignar
     set estado = 'consultoria', transcripcion = null
   where externo_id = v_ext and estado in ('pendiente', 'interna');

  if v_nueva or (v_md5 is not null and v_md5 is distinct from v_old)
     or exists (select 1 from public.cs_consultorias c where c.id = v_id and c.procesada_at is null) then
    perform public.cs_consultoria_procesar(v_id);
  end if;
  return jsonb_build_object('resultado', case when v_nueva then 'creada' else 'actualizada' end, 'consultoria_id', v_id);
end;
$fn$;
revoke all on function public.cs_consultoria_aplicar(jsonb) from public, anon, authenticated;

-- D6. La puerta de la Edge Function (service role). Un usuario logueado no entra.
create or replace function public.cs_consultoria_registrar(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
begin
  if auth.uid() is not null then
    raise exception 'cs: solo la funcion de sincronizacion puede registrar consultorias' using errcode = '42501';
  end if;
  return public.cs_consultoria_aplicar(p);
end;
$fn$;
revoke all on function public.cs_consultoria_registrar(jsonb) from public, anon, authenticated;
grant execute on function public.cs_consultoria_registrar(jsonb) to service_role;

-- D7. Reclasificar lo ya sincronizado: llamadas de alumnos y pendientes / internas que caen en un horario.
-- Fundador (boton de la pantalla de horarios) o sin sesion (SQL Editor / migracion). Idempotente.
create or replace function public.cs_consultoria_reclasificar()
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  r      record;
  v_ll   int := 0;
  v_sa   int := 0;
  v_pre  int := 0;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede reclasificar llamadas' using errcode = '42501';
  end if;

  for r in
    select l.id, l.externo_id, l.consultor, l.inicio_at, l.titulo, l.duracion_min, l.grabacion_url,
           l.grabacion_share_url, l.resumen, l.invitados, l.nombres,
           (select t.texto from public.cs_llamada_transcripciones t where t.llamada_id = l.id) as transcripcion
    from public.cs_llamadas l
    where l.fuente = 'fathom' and l.consultoria_id is null and l.externo_id is not null
      and l.consultor is not null and l.inicio_at is not null
      and public.cs_consultoria_horario_buscar(l.consultor, l.inicio_at) is not null
  loop
    perform public.cs_consultoria_aplicar(jsonb_build_object(
      'externo_id', r.externo_id, 'consultor', r.consultor, 'inicio_at', r.inicio_at, 'titulo', r.titulo,
      'duracion_min', r.duracion_min, 'grabacion_url', r.grabacion_url, 'grabacion_share_url', r.grabacion_share_url,
      'resumen', r.resumen, 'transcripcion', r.transcripcion,
      'asistentes',
        coalesce((select jsonb_agg(jsonb_build_object('email', e #>> '{}'))
                  from jsonb_array_elements(case when jsonb_typeof(r.invitados) = 'array' then r.invitados else '[]'::jsonb end) e
                  where jsonb_typeof(e) = 'string'), '[]'::jsonb)
        || coalesce((select jsonb_agg(jsonb_build_object('nombre', n)) from unnest(r.nombres) n), '[]'::jsonb)));
    v_ll := v_ll + 1;
  end loop;

  for r in
    select s.externo_id, s.consultor, s.inicio_at, s.titulo, s.duracion_min, s.grabacion_url, s.grabacion_share_url,
           s.resumen, s.transcripcion, s.invitados, s.nombres
    from public.cs_fathom_sin_asignar s
    where s.estado in ('pendiente', 'interna') and s.consultor is not null and s.inicio_at is not null
      and public.cs_consultoria_horario_buscar(s.consultor, s.inicio_at) is not null
  loop
    perform public.cs_consultoria_aplicar(jsonb_build_object(
      'externo_id', r.externo_id, 'consultor', r.consultor, 'inicio_at', r.inicio_at, 'titulo', r.titulo,
      'duracion_min', r.duracion_min, 'grabacion_url', r.grabacion_url, 'grabacion_share_url', r.grabacion_share_url,
      'resumen', r.resumen, 'transcripcion', r.transcripcion,
      'asistentes',
        coalesce((select jsonb_agg(jsonb_build_object('email', e #>> '{}'))
                  from jsonb_array_elements(case when jsonb_typeof(r.invitados) = 'array' then r.invitados else '[]'::jsonb end) e
                  where jsonb_typeof(e) = 'string'), '[]'::jsonb)
        || coalesce((select jsonb_agg(jsonb_build_object('nombre', n)) from unnest(r.nombres) n), '[]'::jsonb)));
    v_sa := v_sa + 1;
  end loop;

  select count(*) into v_pre from public.cs_duda_candidatas where consultoria_id is not null;
  return jsonb_build_object('llamadas_reclasificadas', v_ll, 'pendientes_reclasificadas', v_sa,
                            'consultorias', (select count(*) from public.cs_consultorias),
                            'preguntas_en_candidatas', v_pre);
end;
$fn$;
revoke all on function public.cs_consultoria_reclasificar() from public, anon;
grant execute on function public.cs_consultoria_reclasificar() to authenticated;


-- =====================================================================
-- E. Vistas
-- =====================================================================
-- cs_v_ultima_llamada: los consumidores (Hoy, ficha, Clientes, Maestro, aviso, riesgo, chat) siguen leyendo
-- ultima_llamada y fuente. Grupal => ultima consultoria a la que asistio (fuente 'consultoria'); sin asistencia
-- conocida => ultima_llamada null y sin_alerta = true (no hay que alertar por falta de 1 a 1).
-- Las 4 columnas nuevas van al final. Una fila por alumno con alguna llamada, mas todos los grupales.
create or replace view public.cs_v_ultima_llamada
with (security_invoker = on) as
with src as (
  select l.cliente_id, l.programa_id, l.fecha, 'llamada'::text as fuente, 1 as prio, true as ob
  from public.cs_llamadas l
  where l.consultoria_id is null
  union all
  select c.cliente_id, c.programa_id,
         (c.fecha at time zone 'America/Argentina/Buenos_Aires')::date, 'call'::text, 2, true
  from public.cs_calls c
  where c.estado = 'realizada' and c.fecha is not null
  union all
  select s.cliente_id, s.programa_id, s.fecha, 'seguimiento'::text, 3, false
  from public.cs_seguimientos s
  where s.canal in ('call', 'reunion')
), uno as (
  select x.cliente_id, x.programa_id,
         max(x.fecha) as fecha,
         (array_agg(x.fuente order by x.fecha desc, x.prio))[1] as fuente,
         min(x.fecha) filter (where x.ob) as primera
  from src x
  group by x.cliente_id, x.programa_id
), cons as (
  select a.cliente_id, max(k.fecha) as fecha
  from public.cs_consultoria_asistentes a
  join public.cs_consultorias k on k.id = a.consultoria_id
  group by a.cliente_id
)
select c.id as cliente_id,
       c.programa_id,
       case when m.modalidad = 'grupal' then cn.fecha else u.fecha end as ultima_llamada,
       case when m.modalidad = 'grupal' then (case when cn.fecha is not null then 'consultoria' end) else u.fuente end as fuente,
       m.modalidad,
       (m.modalidad = 'grupal' and cn.fecha is null) as sin_alerta,
       u.primera as onboarding_fecha,
       cn.fecha as ultima_consultoria
from public.cs_clientes c
join public.cs_v_modalidad m on m.cliente_id = c.id
left join uno u on u.cliente_id = c.id
left join cons cn on cn.cliente_id = c.id
where m.modalidad = 'grupal' or u.cliente_id is not null;

revoke all on table public.cs_v_ultima_llamada from anon;
revoke insert, update, delete on table public.cs_v_ultima_llamada from authenticated;
grant select on table public.cs_v_ultima_llamada to authenticated;

-- Clase de cada llamada 1 a 1 cargada: consultoria (reclasificada) | onboarding (la primera de un grupal) |
-- otra (cualquier otra de un grupal) | uno_a_uno (VIP o sin dato de modalidad). Las consultorias son filas de
-- cs_consultorias (siempre clase consultoria).
create or replace view public.cs_v_llamadas_clase
with (security_invoker = on) as
select l.id as llamada_id, l.cliente_id, l.programa_id, l.fecha, l.consultoria_id,
       case when l.consultoria_id is not null then 'consultoria'
            when m.modalidad = 'grupal' and l.id = p.primera_id then 'onboarding'
            when m.modalidad = 'grupal' then 'otra'
            else 'uno_a_uno' end as clase
from public.cs_llamadas l
left join public.cs_v_modalidad m on m.cliente_id = l.cliente_id
left join lateral (
  select ll.id as primera_id from public.cs_llamadas ll
  where ll.cliente_id = l.cliente_id and ll.consultoria_id is null
  order by ll.fecha, ll.created_at, ll.id
  limit 1
) p on true;
revoke all on table public.cs_v_llamadas_clase from anon;
revoke insert, update, delete on table public.cs_v_llamadas_clase from authenticated;
grant select on table public.cs_v_llamadas_clase to authenticated;

-- cs_v_alumno_resumen: igual que la 106, pero "En que esta" / "Proximos pasos" no salen de una consultoria grupal.
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
    and ll.consultoria_id is null
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
-- F. Parches suaves a funciones vigentes (aviso diario y chat)
-- =====================================================================
-- Cada ancla tiene que estar EXACTAMENTE una vez; si no, esa funcion no se toca (queda un NOTICE y el control C7).
do $parches$
declare
  r     record;
  v_oid regprocedure;
  v_def text;
  v_n   int;
begin
  for r in
    select * from (values
      ('public.cs_servicio_armar(text,date)',
       E'order by greatest(0, v_hoy - u.ultima_llamada) desc nulls last, c.nombre',
       E'and coalesce(u.sin_alerta, false) = false   -- 157: grupal sin datos de asistencia no alerta\n    order by greatest(0, v_hoy - u.ultima_llamada) desc nulls last, c.nombre'),
      ('public.cs_chat_atrasados(text)',
       E'and (u.ultima_llamada is null',
       E'and coalesce(u.sin_alerta, false) = false   -- 157: grupal sin datos de asistencia no alerta\n    and (u.ultima_llamada is null')
    ) as t(firma, ancla, nuevo)
  loop
    v_oid := to_regprocedure(r.firma);
    if v_oid is null then
      raise notice '157: % no existe todavia, no se parcha', r.firma;
      continue;
    end if;
    v_def := pg_get_functiondef(v_oid);
    if position('sin_alerta' in v_def) > 0 then
      raise notice '157: % ya estaba parchada', r.firma;
      continue;
    end if;
    v_n := (length(v_def) - length(replace(v_def, r.ancla, ''))) / length(r.ancla);
    if v_n <> 1 then
      raise notice '157: PENDIENTE: % tiene % veces el punto de anclaje (esperaba 1); no se toca', r.firma, v_n;
      continue;
    end if;
    insert into public.cs_bak_157_funciones (funcion, definicion) values (r.firma, v_def)
    on conflict (funcion) do nothing;
    execute replace(v_def, r.ancla, r.nuevo);
    raise notice '157: % parchada', r.firma;
  end loop;
end $parches$;


-- =====================================================================
-- G. "En que esta" automatico: tambien lo que dijo el alumno en las consultorias
-- =====================================================================
-- Misma firma y columnas que la 137. Una consultoria cuenta si el alumno dijo algo con sustancia (120+ caracteres).
create or replace function public.cs_ia_en_que_esta_pendientes(p_limite int default 10, p_programa text default null)
returns table (cliente_id uuid, programa_id text, nombre text, llamadas int)
language sql stable security definer set search_path = public
as $fn$
  with mat as (
    select l.cliente_id, l.id as fid, l.fecha, false as cons
    from public.cs_llamadas l
    where l.fuente = 'fathom' and l.consultoria_id is null and nullif(btrim(l.resumen), '') is not null
    union all
    select a.cliente_id, a.consultoria_id, k.fecha, true
    from public.cs_consultoria_asistentes a
    join public.cs_consultorias k on k.id = a.consultoria_id
    where char_length(btrim(coalesce(a.intervenciones, ''))) >= 120
  )
  select c.id, c.programa_id, c.nombre, count(m.fid)::int
  from public.cs_clientes c
  join mat m on m.cliente_id = c.id
  left join public.cs_en_que_esta e on e.cliente_id = c.id
  where c.estado in ('onboarding', 'activo', 'en_renovacion')
    and (p_programa is null or c.programa_id = p_programa)
  group by c.id, c.programa_id, c.nombre, e.cliente_id, e.llamadas_ids, e.consultorias_ids
  having e.cliente_id is null
      or bool_or(not m.cons and not (m.fid = any (e.llamadas_ids)))
      or bool_or(m.cons and not (m.fid = any (e.consultorias_ids)))
  order by max(m.fecha) desc
  limit greatest(coalesce(p_limite, 10), 0)
$fn$;
revoke all on function public.cs_ia_en_que_esta_pendientes(int, text) from public, anon, authenticated;
grant execute on function public.cs_ia_en_que_esta_pendientes(int, text) to service_role;

create or replace function public.cs_ia_en_que_esta_contar(p_programa text default null)
returns table (programa_id text, alumnos int, llamadas int)
language sql stable security definer set search_path = public
as $fn$
  with mat as (
    select l.cliente_id, l.id as fid, false as cons
    from public.cs_llamadas l
    where l.fuente = 'fathom' and l.consultoria_id is null and nullif(btrim(l.resumen), '') is not null
    union all
    select a.cliente_id, a.consultoria_id, true
    from public.cs_consultoria_asistentes a
    where char_length(btrim(coalesce(a.intervenciones, ''))) >= 120
  )
  select c.programa_id, count(distinct c.id)::int, count(m.fid)::int
  from public.cs_clientes c
  join mat m on m.cliente_id = c.id
  left join public.cs_en_que_esta e on e.cliente_id = c.id
  where c.estado in ('onboarding', 'activo', 'en_renovacion')
    and (p_programa is null or c.programa_id = p_programa)
    and (e.cliente_id is null
         or (not m.cons and not (m.fid = any (e.llamadas_ids)))
         or (m.cons and not (m.fid = any (e.consultorias_ids))))
  group by c.programa_id
$fn$;
revoke all on function public.cs_ia_en_que_esta_contar(text) from public, anon, authenticated;
grant execute on function public.cs_ia_en_que_esta_contar(text) to service_role;


-- =====================================================================
-- H. Reclasificar lo ya sincronizado (una vez, ahora)
-- =====================================================================
-- Si falla, el esquema igual queda (el subbloque deshace solo lo suyo): se vuelve a correr a mano con
--   select public.cs_consultoria_reclasificar();
do $recl$
declare
  v_r jsonb;
begin
  begin
    v_r := public.cs_consultoria_reclasificar();
    raise notice '157: reclasificacion %', v_r;
  exception when others then
    raise warning '157: la reclasificacion fallo (% / %). El esquema quedo; corregir y correr select public.cs_consultoria_reclasificar();', sqlstate, sqlerrm;
  end;
end $recl$;

commit;


-- =====================================================================
-- DESPUES DE CORRER (a mano, fuera de este archivo)
-- =====================================================================
--   1. Redesplegar (en este orden, todas con --no-verify-jwt):
--        supabase functions deploy fathom-sync --no-verify-jwt
--        supabase functions deploy ia-en-que-esta --no-verify-jwt
--        supabase functions deploy ia-riesgo-abandono --no-verify-jwt
--      (ia-dudas no cambia: lee cs_duda_candidatas, que ahora tambien recibe preguntas de consultorias.)
--   2. Mirar C3 (modalidad por programa): si hay alumnos "sin_dato" que son grupales o VIP, fijar la modalidad en la
--      ficha (selector "Modalidad") o decir que palabra del producto / plan los distingue y se ajusta cs_modalidad_calc.
--   3. Configuracion general > "Consultorias grupales": revisar el horario precargado (duracion 60 supuesta) y cargar
--      los de teo (2 o 3 por semana), liam y agus. Despues de cada cambio, "Reclasificar llamadas ya sincronizadas".
--   4. Si C7 muestra funciones sin parchar, mandar su definicion vigente (pg_get_functiondef).


-- =====================================================================
-- CONTROLES (de a uno, despues de correr la migracion)
-- =====================================================================

-- C1. Objetos nuevos. Esperado: 9 filas con true.
-- select t, to_regclass('public.' || t) is not null as existe
-- from unnest(array['cs_consultoria_horarios','cs_consultorias','cs_consultoria_transcripciones','cs_consultoria_asistentes',
--                   'cs_v_modalidad','cs_v_llamadas_clase','cs_bak_157_funciones']) t;
-- select column_name from information_schema.columns
-- where table_schema='public' and ((table_name='cs_clientes' and column_name='modalidad')
--    or (table_name='cs_llamadas' and column_name='consultoria_id')
--    or (table_name='cs_duda_candidatas' and column_name='consultoria_id')
--    or (table_name='cs_en_que_esta' and column_name='consultorias_ids')
--    or (table_name='cs_v_ultima_llamada' and column_name in ('modalidad','sin_alerta','onboarding_fecha','ultima_consultoria')));
--   -- esperado: 8 filas

-- C2. Horarios cargados. Esperado: al menos teo / joaco / dia 5 / 18:00:00 / activo.
-- select programa_id, consultor, dia_semana, hora, duracion_min, tolerancia_min, activo from public.cs_consultoria_horarios order by 1,2,3,4;

-- C3. Modalidad por programa y de donde sale. Mirar sobre todo 'sin_dato' y los productos / planes de cada grupo.
-- select m.programa_id, m.modalidad, m.origen, coalesce(pr.nombre, '(sin producto)') as producto, coalesce(c.plan, '(sin plan)') as plan, count(*) as alumnos
-- from public.cs_v_modalidad m
-- join public.cs_clientes c on c.id = m.cliente_id
-- left join public.cs_productos pr on pr.id = c.producto_id
-- where c.estado in ('onboarding','activo','en_renovacion')
-- group by 1,2,3,4,5 order by 1,2,3,4,5;

-- C4. Lo reclasificado. Esperado en teo: consultorias de los viernes ~18:00 (la fecha cae en viernes ART).
-- select k.programa_id, k.fecha, to_char(k.inicio_at at time zone 'America/Argentina/Buenos_Aires', 'Dy HH24:MI') as dia_hora,
--        k.consultor, k.titulo,
--        (select count(*) from public.cs_consultoria_asistentes a where a.consultoria_id = k.id) as asistentes,
--        (select count(*) from public.cs_consultoria_asistentes a where a.consultoria_id = k.id and a.hablo) as hablaron,
--        (select count(*) from public.cs_duda_candidatas d where d.consultoria_id = k.id) as preguntas
-- from public.cs_consultorias k order by k.fecha desc;
-- select estado, count(*) from public.cs_fathom_sin_asignar group by 1 order by 1;   -- 'consultoria' = las que cayeron en un horario
-- select count(*) as llamadas_marcadas_consultoria from public.cs_llamadas where consultoria_id is not null;

-- C5. Clase de las llamadas por programa y modalidad.
-- select l.programa_id, coalesce(m.modalidad, 'sin_dato') as modalidad, l.clase, count(*)
-- from public.cs_v_llamadas_clase l left join public.cs_v_modalidad m on m.cliente_id = l.cliente_id
-- group by 1,2,3 order by 1,2,3;

-- C6. "Dias sin llamada": grupales con y sin datos de asistencia, y VIP / sin dato sin cambios.
-- select programa_id, coalesce(modalidad, 'sin_dato') as modalidad, sin_alerta, count(*) as alumnos,
--        count(ultima_llamada) as con_fecha, min(ultima_llamada) as mas_vieja, max(ultima_llamada) as mas_nueva
-- from public.cs_v_ultima_llamada group by 1,2,3 order by 1,2,3;

-- C7. Parches. Esperado: 'parchada = true' en las que existen. Si dice false, no se toco (anclaje distinto).
-- select p.oid::regprocedure::text as funcion, position('sin_alerta' in pg_get_functiondef(p.oid)) > 0 as parchada
-- from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('cs_servicio_armar', 'cs_chat_atrasados');

-- C8. Permisos. Esperado: asistentes SIN columna intervenciones para authenticated; reclasificar = true;
--     registrar / procesar / aplicar = false.
-- select has_column_privilege('authenticated', 'public.cs_consultoria_asistentes', 'intervenciones', 'select') as ve_intervenciones,
--        has_function_privilege('authenticated', 'public.cs_consultoria_reclasificar()', 'execute') as reclasificar,
--        has_function_privilege('authenticated', 'public.cs_consultoria_registrar(jsonb)', 'execute') as registrar,
--        has_function_privilege('authenticated', 'public.cs_consultoria_procesar(uuid)', 'execute') as procesar,
--        has_function_privilege('authenticated', 'public.cs_consultoria_aplicar(jsonb)', 'execute') as aplicar;

-- C9. Horarios que no matchean nada todavia / reuniones de joaco que casi caen en un horario (sirve para ajustar la tolerancia).
-- select (l.inicio_at at time zone 'America/Argentina/Buenos_Aires')::date as dia,
--        to_char(l.inicio_at at time zone 'America/Argentina/Buenos_Aires', 'Dy HH24:MI') as dia_hora, l.titulo, l.consultoria_id is not null as ya_es_consultoria
-- from public.cs_llamadas l
-- where l.consultor = 'joaco' and extract(isodow from l.inicio_at at time zone 'America/Argentina/Buenos_Aires') = 5
--   and (l.inicio_at at time zone 'America/Argentina/Buenos_Aires')::time between time '15:00' and time '21:00'
-- order by l.inicio_at desc limit 40;

-- C10. HUMO (se revierte solo: termina con un error "HUMO OK"). Necesita al menos un alumno de teo y el horario precargado.
-- do $humo$
-- declare
--   v_cli uuid; v_nom text; v_ini timestamptz; v_r jsonb; v_k uuid; v_n int; v_otro uuid;
-- begin
--   -- modalidad: funcion pura
--   if public.cs_modalidad_calc(null, 'Grupal', null) <> 'grupal' then raise exception 'HUMO 157: Grupal'; end if;
--   if public.cs_modalidad_calc(null, null, 'Mentoria 1 a 1') <> 'vip' then raise exception 'HUMO 157: 1 a 1'; end if;
--   if public.cs_modalidad_calc(null, 'Comunidad', null) <> 'grupal' then raise exception 'HUMO 157: Comunidad'; end if;
--   if public.cs_modalidad_calc(null, 'Grupal + 1 a 1', null) <> 'vip' then raise exception 'HUMO 157: grupal + 1 a 1 deberia ser vip'; end if;
--   if public.cs_modalidad_calc(null, 'Otro', null) is not null then raise exception 'HUMO 157: Otro deberia ser null'; end if;
--   if public.cs_modalidad_calc('grupal', '1 a 1', null) <> 'grupal' then raise exception 'HUMO 157: manual manda'; end if;
--   -- horario: viernes 18:05 ART si, viernes 20:00 no, jueves 18:00 no
--   v_ini := ((date_trunc('week', now() at time zone 'America/Argentina/Buenos_Aires') + interval '4 days 18 hours 5 minutes')
--             at time zone 'America/Argentina/Buenos_Aires');
--   if public.cs_consultoria_horario_buscar('joaco', v_ini) is null then raise exception 'HUMO 157: viernes 18:05 no matchea (esta el horario de teo?)'; end if;
--   if public.cs_consultoria_horario_buscar('joaco', v_ini + interval '2 hours') is not null then raise exception 'HUMO 157: viernes 20:05 no deberia matchear'; end if;
--   if public.cs_consultoria_horario_buscar('joaco', v_ini - interval '1 day') is not null then raise exception 'HUMO 157: jueves no deberia matchear'; end if;
--   if public.cs_consultoria_horario_buscar('teo', v_ini) is not null then raise exception 'HUMO 157: otro consultor no deberia matchear'; end if;
--   -- flujo: un alumno de teo habla en una consultoria
--   select c.id, c.nombre into v_cli, v_nom from public.cs_clientes c
--    where c.programa_id = 'teo' and position(' ' in btrim(c.nombre)) > 0 and public.cs_norm_nombre(c.nombre) is not null limit 1;
--   if v_cli is null then raise exception 'HUMO 157: no hay alumnos de teo con nombre y apellido'; end if;
--   v_r := public.cs_consultoria_aplicar(jsonb_build_object(
--     'externo_id', 'fathom:humo157', 'consultor', 'joaco', 'inicio_at', v_ini, 'titulo', 'Humo 157',
--     'asistentes', jsonb_build_array(jsonb_build_object('nombre', 'Persona Inexistente Zzz')),
--     'transcripcion', E'[00:00:01] Joaquin: Bienvenidos a la consultoria\n[00:00:20] ' || v_nom
--       || E': Tengo una pregunta sobre como configurar la cuenta publicitaria para las campanas nuevas?\n[00:00:40] Joaquin: Dale, te explico'));
--   if v_r ->> 'resultado' <> 'creada' then raise exception 'HUMO 157: esperaba creada, vino %', v_r; end if;
--   v_k := (v_r ->> 'consultoria_id')::uuid;
--   select count(*) into v_n from public.cs_consultoria_asistentes where consultoria_id = v_k and cliente_id = v_cli and hablo and via = 'hablante';
--   if v_n <> 1 then raise exception 'HUMO 157: el alumno no figura como asistente que hablo (%)', v_n; end if;
--   select count(*) into v_n from public.cs_consultoria_asistentes where consultoria_id = v_k and intervenciones like '%Joaquin:%';
--   if v_n <> 0 then raise exception 'HUMO 157: las lineas del consultor no deberian estar en intervenciones'; end if;
--   select count(*) into v_n from public.cs_duda_candidatas where consultoria_id = v_k and cliente_id = v_cli and confianza = 'alta';
--   if v_n < 1 then raise exception 'HUMO 157: no salio la pregunta como candidata (revisar regla de 135 / min_palabras)'; end if;
--   -- idempotente
--   v_r := public.cs_consultoria_aplicar(jsonb_build_object('externo_id', 'fathom:humo157', 'consultor', 'joaco', 'inicio_at', v_ini));
--   if v_r ->> 'resultado' <> 'actualizada' then raise exception 'HUMO 157: la segunda vez deberia ser actualizada'; end if;
--   select count(*) into v_n from public.cs_duda_candidatas where consultoria_id = v_k;
--   if v_n > 6 then raise exception 'HUMO 157: reprocesar duplico candidatas (%)', v_n; end if;
--   -- la vista: si el alumno es grupal, su ultima llamada es esta consultoria
--   update public.cs_clientes set modalidad = 'grupal' where id = v_cli;
--   if not exists (select 1 from public.cs_v_ultima_llamada u where u.cliente_id = v_cli and u.fuente = 'consultoria' and not u.sin_alerta) then
--     raise exception 'HUMO 157: la vista no toma la consultoria como ultima llamada del grupal';
--   end if;
--   -- fuera de horario no es consultoria
--   v_r := public.cs_consultoria_aplicar(jsonb_build_object('externo_id', 'fathom:humo157b', 'consultor', 'joaco', 'inicio_at', v_ini + interval '3 hours'));
--   if v_r ->> 'resultado' <> 'sin_horario' then raise exception 'HUMO 157: fuera de horario deberia ser sin_horario'; end if;
--   raise exception 'HUMO OK: 157 (se revierte)';
-- end
-- $humo$;


-- =====================================================================
-- VUELTA ATRAS (comentada). Orden importa. NO borra datos de otras migraciones.
-- =====================================================================
-- begin;
--   -- 1. vistas y funciones a como estaban (respaldo de la 157). cs_v_ultima_llamada pierde 4 columnas: drop + create
--   --    y se reponen sus grants (como estaban: authenticated solo lectura, sin anon).
--   do $va$
--   declare r record;
--   begin
--     if to_regclass('public.cs_bak_157_funciones') is null then raise exception '157 vuelta atras: no hay respaldo'; end if;
--     for r in select funcion, definicion from public.cs_bak_157_funciones where funcion like 'view %' loop
--       execute format('drop view if exists %s', substr(r.funcion, 6));
--       execute format('create view %s with (security_invoker = on) as %s', substr(r.funcion, 6), r.definicion);
--       execute format('revoke all on table %s from anon', substr(r.funcion, 6));
--       execute format('revoke insert, update, delete on table %s from authenticated', substr(r.funcion, 6));
--       execute format('grant select on table %s to authenticated', substr(r.funcion, 6));
--     end loop;
--     for r in select funcion, definicion from public.cs_bak_157_funciones where funcion not like 'view %' loop
--       execute r.definicion;
--     end loop;
--   end $va$;
--   -- las pendientes / internas que pasaron a 'consultoria' vuelven a pendiente CON su transcripcion
--   update public.cs_fathom_sin_asignar s
--      set estado = 'pendiente',
--          transcripcion = coalesce(s.transcripcion, (select t.texto from public.cs_consultorias k
--                                                       join public.cs_consultoria_transcripciones t on t.consultoria_id = k.id
--                                                      where k.externo_id = s.externo_id))
--    where s.estado = 'consultoria';
--   -- 2. objetos nuevos
--   drop view if exists public.cs_v_llamadas_clase;
--   drop function if exists public.cs_consultoria_reclasificar();
--   drop function if exists public.cs_consultoria_registrar(jsonb);
--   drop function if exists public.cs_consultoria_aplicar(jsonb);
--   drop function if exists public.cs_consultoria_procesar(uuid);
--   drop function if exists public.cs_consultoria_preguntas(text, text);
--   drop function if exists public.cs_consultoria_match_nombre(text, text);
--   drop function if exists public.cs_consultoria_match_mail(text, text);
--   drop function if exists public.cs_consultoria_horario_buscar(text, timestamptz);
--   -- las preguntas de consultorias se pierden con la tabla (candidatas con consultoria_id): borrarlas antes de dejar llamada_id not null
--   delete from public.cs_duda_candidatas where consultoria_id is not null;
--   alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_157;
--   alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_estado_127;
--   alter table public.cs_fathom_sin_asignar add constraint cs_fathom_sin_asignar_estado_127
--     check (estado in ('pendiente', 'asignada', 'no_alumno', 'interna'));
--   alter table public.cs_duda_candidatas drop constraint if exists cs_duda_cand_origen_157_chk;
--   drop index if exists public.cs_duda_cand_consultoria_texto_uk;
--   alter table public.cs_duda_candidatas drop column if exists consultoria_id;
--   alter table public.cs_duda_candidatas alter column llamada_id set not null;
--   alter table public.cs_llamadas drop column if exists consultoria_id;
--   alter table public.cs_en_que_esta drop column if exists consultorias_ids;
--   drop table if exists public.cs_consultoria_asistentes;
--   drop table if exists public.cs_consultoria_transcripciones;
--   drop table if exists public.cs_consultorias;
--   drop table if exists public.cs_consultoria_horarios;
--   drop view if exists public.cs_v_modalidad;
--   drop function if exists public.cs_modalidad_calc(text, text, text);
--   alter table public.cs_clientes drop column if exists modalidad;
--   drop table if exists public.cs_bak_157_funciones;
-- commit;
