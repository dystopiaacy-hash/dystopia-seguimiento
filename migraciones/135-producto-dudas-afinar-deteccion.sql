-- =====================================================================
-- 135 · Producto · afinar la detección de dudas en llamadas (menos ruido)
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 134 (cs_duda_candidatas, cs_dudas_procesadas y funciones). No toca Fathom (cs_fathom_*),
-- Finanzas, cs_servicio_*, ni migraciones anteriores (solo reemplaza funciones de la 134).
--
-- Motivo: sobre las 8 llamadas de teo la 134 dio 144 candidatas (~18 por llamada) y solo ~30% eran
-- preguntas reales del alumno (signo ~45%, palabra ~10%).
--
-- Qué cambia
--   1. Regla 'palabra' APAGADA por defecto (configurable por programa). Si se prende, sus candidatas
--      salen siempre con confianza 'baja'.
--   2. Regla 'signo': mínimo 6 palabras (configurable, default 6) y se descartan:
--        - segunda persona típica del consultor ("¿tenés…?", "¿pudiste…?", "¿viste…?", "¿me mostrás…?",
--          "¿cómo vas con…?", "¿te quedó claro?", "¿se entiende?"…) (configurable, default activo);
--        - logística de la llamada ampliada: pantalla, link, enlace, grabación, horario, zoom, meet,
--          invitación, calendario, agendar, "¿me escuchás?", "¿estás?", "¿se ve?", "¿a qué hora?"…
--   3. Atribución del hablante con confianza (cs_dudas_atribucion):
--        alta  = EXACTAMENTE una voz comparte nombre/alias con el alumno y a lo sumo otra voz más;
--        baja  = el alumno se deduce por descarte (1 a 1, ninguna voz coincide con su nombre) o hay 2+
--                voces ajenas además del alumno (la diarización pudo cruzarse);
--        nada  = 2+ voces coinciden con el nombre del alumno, o ninguna coincide y hay 0 o 2+ voces
--                sin atribuir: NO se generan candidatas y la llamada queda 'ambiguo' / 'sin_hablante'.
--      Las 'baja' se guardan pero la pantalla las oculta por defecto ("solo alta confianza").
--   4. Tope por llamada: 6 candidatas (configurable). Ordenadas por palabras de contenido (4+ letras,
--      sin palabras vacías) y luego por largo.
--   5. cs_duda_candidatas.confianza ('alta' | 'baja') y .motivo (nombre | varias_voces | unico_otro |
--      palabra | regla_134). Las pendientes que ya existían de la 134 pasan a 'baja' (motivo
--      'regla_134'): no se borra nada y quedan ocultas por defecto.
--   6. Control de calidad C2: cuántas candidatas daría la regla nueva por llamada, sin guardar.
--
-- Correr fuera de :00/:15/:30/:45 y de las 9:00. No manda nada a Discord. No hace backfill.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo
do $$
declare
  v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values
    ('cs_dudas_hablantes(uuid)'), ('cs_dudas_extraer(uuid)'), ('cs_dudas_detectar_llamada(uuid)'),
    ('cs_dudas_estado(text)'), ('cs_norm_nombre(text)'), ('es_fundador()'), ('cs_puede_ver(text)')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 135: faltan funciones (corrio la 134?): %', v_falta;
  end if;
  if to_regclass('public.cs_duda_candidatas') is null or to_regclass('public.cs_dudas_procesadas') is null then
    raise exception 'cs 135: faltan las tablas de la 134';
  end if;
end $$;

lock table public.cs_duda_candidatas, public.cs_dudas_procesadas, public.cs_llamadas,
           public.cs_llamada_transcripciones, public.cs_programas
  in share row exclusive mode;


-- =====================================================================
-- 0. Respaldo de las funciones que se reemplazan (solo la primera vez)
-- =====================================================================
create table if not exists public.cs_bak_135_funciones (
  nombre text primary key,
  def    text not null,
  at     timestamptz not null default now()
);
alter table public.cs_bak_135_funciones enable row level security;
revoke all on table public.cs_bak_135_funciones from public, anon, authenticated;

insert into public.cs_bak_135_funciones (nombre, def)
select p.proname, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('cs_dudas_hablantes', 'cs_dudas_extraer', 'cs_dudas_detectar_llamada', 'cs_dudas_estado')
on conflict (nombre) do nothing;


-- =====================================================================
-- 1. Columnas y configuración
-- =====================================================================
alter table public.cs_duda_candidatas
  add column if not exists confianza text not null default 'alta' check (confianza in ('alta', 'baja')),
  add column if not exists motivo    text;
comment on column public.cs_duda_candidatas.confianza is
  '135: alta = alumno identificado por nombre y pregunta que pasa los filtros; baja = atribucion por descarte, varias voces, o regla palabra. La pantalla oculta las baja por defecto.';
comment on column public.cs_duda_candidatas.motivo is
  '135: por que tiene esa confianza: nombre | varias_voces | unico_otro | palabra | regla_134 (detectada con la regla vieja).';

-- Lo que ya existía (regla vieja de la 134): se conserva pero queda como baja confianza.
update public.cs_duda_candidatas
   set motivo = 'regla_134',
       confianza = case when estado = 'pendiente' then 'baja' else confianza end
 where motivo is null;

alter table public.cs_dudas_procesadas
  add column if not exists confianza text check (confianza is null or confianza in ('alta', 'baja'));

-- estado de procesada: suma 'ambiguo'
do $$
declare
  v_nom text;
begin
  for v_nom in
    select c.conname from pg_constraint c
     where c.conrelid = 'public.cs_dudas_procesadas'::regclass and c.contype = 'c'
       and pg_get_constraintdef(c.oid) like '%sin_formato%'
  loop
    execute format('alter table public.cs_dudas_procesadas drop constraint %I', v_nom);
  end loop;
end $$;
alter table public.cs_dudas_procesadas drop constraint if exists cs_dudas_procesadas_estado_chk;
alter table public.cs_dudas_procesadas
  add constraint cs_dudas_procesadas_estado_chk
  check (estado in ('ok', 'sin_hablante', 'sin_formato', 'ambiguo'));

create table if not exists public.cs_dudas_config (
  programa_id             text primary key references public.cs_programas(id),
  regla_palabra           boolean not null default false,
  min_palabras            int not null default 6 check (min_palabras between 4 and 20),
  max_por_llamada         int not null default 6 check (max_por_llamada between 1 and 30),
  filtrar_segunda_persona boolean not null default true,
  updated_at              timestamptz not null default now(),
  updated_by              uuid
);
comment on table public.cs_dudas_config is
  '135: parametros de la deteccion de dudas por programa. Sin fila = valores por defecto (palabra apagada, 6 palabras, 6 por llamada, filtro de segunda persona activo). Escribe solo el fundador por cs_dudas_config_guardar.';
alter table public.cs_dudas_config enable row level security;
revoke all on table public.cs_dudas_config from anon, authenticated;
grant select on table public.cs_dudas_config to authenticated;
drop policy if exists cs_select on public.cs_dudas_config;
create policy cs_select on public.cs_dudas_config for select to authenticated
  using (public.cs_puede_ver(programa_id));

-- Valores vigentes de un programa (con defaults). Interna.
create or replace function public.cs_dudas_cfg(p_programa text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'regla_palabra',           coalesce(c.regla_palabra, false),
    'min_palabras',            coalesce(c.min_palabras, 6),
    'max_por_llamada',         coalesce(c.max_por_llamada, 6),
    'filtrar_segunda_persona', coalesce(c.filtrar_segunda_persona, true))
  from (select 1) x
  left join public.cs_dudas_config c on c.programa_id = p_programa
$$;

create or replace function public.cs_dudas_config_leer(p_programa text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
begin
  if not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: sin acceso al programa' using errcode = '42501';
  end if;
  return public.cs_dudas_cfg(p_programa);
end;
$fn$;

create or replace function public.cs_dudas_config_guardar(
  p_programa text,
  p_regla_palabra boolean default null,
  p_min_palabras int default null,
  p_max_por_llamada int default null,
  p_filtrar_segunda_persona boolean default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador cambia las reglas de detección' using errcode = '42501';
  end if;
  if not exists (select 1 from public.cs_programas p where p.id = p_programa) then
    raise exception 'cs: programa inexistente' using errcode = '22023';
  end if;
  if p_min_palabras is not null and p_min_palabras not between 4 and 20 then
    raise exception 'cs: el mínimo de palabras va de 4 a 20' using errcode = '22023';
  end if;
  if p_max_por_llamada is not null and p_max_por_llamada not between 1 and 30 then
    raise exception 'cs: el tope por llamada va de 1 a 30' using errcode = '22023';
  end if;
  insert into public.cs_dudas_config as c
    (programa_id, regla_palabra, min_palabras, max_por_llamada, filtrar_segunda_persona, updated_at, updated_by)
  values (p_programa, coalesce(p_regla_palabra, false), coalesce(p_min_palabras, 6),
          coalesce(p_max_por_llamada, 6), coalesce(p_filtrar_segunda_persona, true), now(), auth.uid())
  on conflict (programa_id) do update
    set regla_palabra           = coalesce(p_regla_palabra, c.regla_palabra),
        min_palabras            = coalesce(p_min_palabras, c.min_palabras),
        max_por_llamada         = coalesce(p_max_por_llamada, c.max_por_llamada),
        filtrar_segunda_persona = coalesce(p_filtrar_segunda_persona, c.filtrar_segunda_persona),
        updated_at = now(), updated_by = auth.uid();
  return public.cs_dudas_cfg(p_programa);
end;
$fn$;


-- =====================================================================
-- 2. Quién habla (misma regla que la 134 + cómo se atribuyó: por = nombre | unico)
-- =====================================================================
drop function if exists public.cs_dudas_hablantes(uuid);
create function public.cs_dudas_hablantes(p_llamada uuid)
returns table (hablante text, lineas int, rol text, por text)
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_texto text;
  v_cli   uuid;
  v_cons  text;
  v_alu   text[];
  v_con   text[];
  v_stop  text[] := array['del', 'los', 'las', 'van', 'von', 'dos', 'das', 'con', 'por'];
begin
  select t.texto, l.cliente_id, l.consultor
    into v_texto, v_cli, v_cons
  from public.cs_llamadas l
  join public.cs_llamada_transcripciones t on t.llamada_id = l.id
  where l.id = p_llamada and l.fuente = 'fathom';
  if v_texto is null then
    return;
  end if;

  select coalesce(array_agg(distinct x.w), '{}') into v_alu
  from (
    select unnest(string_to_array(public.cs_norm_nombre(c.nombre), ' ')) as w
      from public.cs_clientes c where c.id = v_cli
    union all
    select unnest(string_to_array(a.alias, ' ')) as w
      from public.cs_clientes_alias a where a.cliente_id = v_cli
  ) x
  where char_length(x.w) >= 3 and x.w <> all (v_stop);

  select coalesce(array_agg(distinct x.w), '{}') into v_con
  from (
    select unnest(string_to_array(public.cs_norm_nombre(k.nombre), ' ')) as w
      from public.cs_fathom_consultores k where k.id = v_cons
    union all
    select v_cons
  ) x
  where x.w is not null and char_length(x.w) >= 3;

  return query
  with l as (
    select btrim((regexp_match(ln, '^\[[^\]]*\]\s*([^:]{1,80}):\s*\S'))[1]) as quien
    from regexp_split_to_table(v_texto, E'\r?\n') ln
  ),
  sp as (
    select l.quien, count(*)::int as cant from l where l.quien is not null group by l.quien
  ),
  w as (
    select sp.quien, sp.cant,
           array(select p from unnest(string_to_array(public.cs_norm_nombre(sp.quien), ' ')) p
                  where char_length(p) >= 3 and p <> all (v_stop)) as ws
    from sp
  ),
  r as (
    select w.quien, w.cant,
           case when cardinality(w.ws) > 0 and w.ws <@ v_con then 'consultor'
                when w.ws && v_alu then 'alumno'
                else 'otro' end as papel
    from w
  ),
  d as (
    select r.*,
           (r.papel = 'otro'
              and not exists (select 1 from r r2 where r2.papel = 'alumno')
              and (select count(*) from r r3 where r3.papel = 'otro') = 1) as unico
    from r
  )
  select d.quien, d.cant,
         case when d.unico then 'alumno' else d.papel end,
         case when d.papel = 'alumno' then 'nombre' when d.unico then 'unico' else null end
  from d;
end;
$fn$;


-- Atribución de la llamada: una fila (confianza, motivo) o ninguna si no se puede identificar al alumno.
create or replace function public.cs_dudas_atribucion(p_llamada uuid)
returns table (confianza text, motivo text)
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_nombre int;
  v_unico  int;
  v_otros  int;
begin
  select count(*) filter (where h.rol = 'alumno' and h.por = 'nombre'),
         count(*) filter (where h.por = 'unico'),
         count(*) filter (where h.rol = 'otro')
    into v_nombre, v_unico, v_otros
  from public.cs_dudas_hablantes(p_llamada) h;

  if v_nombre = 1 and v_otros <= 1 then
    return query select 'alta'::text, 'nombre'::text;
  elsif v_nombre = 1 then
    return query select 'baja'::text, 'varias_voces'::text;
  elsif v_nombre = 0 and v_unico = 1 then
    return query select 'baja'::text, 'unico_otro'::text;
  end if;
  -- 2+ voces con el nombre del alumno, o ninguna y 0 / 2+ sin atribuir: no se identifica al alumno.
  return;
end;
$fn$;


-- =====================================================================
-- 3. Extraer preguntas (no escribe)
-- =====================================================================
-- REGLA 135 (solo líneas del alumno; se parte cada línea en oraciones en . ! ? …):
--   - si la oración trae "¿", se toma desde el ÚLTIMO "¿"; se normaliza y se sacan muletillas del inicio;
--   - 'signo': termina en "?" y tiene min_palabras o más (default 6); si termina en muletilla de
--     confirmación ("…, no?", "…, viste?") exige palabra interrogativa al inicio;
--   - 'palabra': solo si cs_dudas_config.regla_palabra = true (default apagada); sin "?" y empieza con
--     palabra de pregunta, min_palabras o más; siempre confianza 'baja';
--   - se descartan: ruido y logística de la llamada (lista ampliada), no-preguntas ("como te decía…") y,
--     si filtrar_segunda_persona (default true), preguntas del estilo del consultor al alumno;
--   - solo si la llamada tiene atribución (cs_dudas_atribucion); la confianza de la candidata es la de
--     la llamada ('alta' / 'baja'); 'palabra' siempre 'baja';
--   - tope max_por_llamada (default 6): primero las de más palabras de contenido (4+ letras, sin
--     palabras vacías), después las más largas; sin repetidas;
--   - largo máximo 300 caracteres.
drop function if exists public.cs_dudas_extraer(uuid);
create function public.cs_dudas_extraer(p_llamada uuid)
returns table (hablante text, texto text, regla text, confianza text, motivo text, puntaje int)
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_texto text;
  v_prog  text;
  v_cfg   jsonb;
  v_min   int;
  v_max   int;
  v_pal   boolean;
  v_seg   boolean;
  v_conf  text;
  v_mot   text;
  v_vacias text[] := array['para', 'como', 'esta', 'este', 'esto', 'esos', 'esas', 'pero', 'porque', 'cuando',
                           'donde', 'tengo', 'tiene', 'tienen', 'hacer', 'puedo', 'sobre', 'entre', 'desde',
                           'hasta', 'algo', 'todo', 'toda', 'todos', 'todas', 'cual', 'cuales', 'quien',
                           'cuanto', 'cuanta', 'puede', 'puedes', 'podes', 'seria', 'hace', 'haces', 'hago'];
begin
  select t.texto, l.programa_id into v_texto, v_prog
  from public.cs_llamadas l
  join public.cs_llamada_transcripciones t on t.llamada_id = l.id
  where l.id = p_llamada and l.fuente = 'fathom';
  if v_texto is null then
    return;
  end if;

  select a.confianza, a.motivo into v_conf, v_mot from public.cs_dudas_atribucion(p_llamada) a;
  if v_conf is null then
    return;   -- no se identifica con seguridad al alumno: sin candidatas
  end if;

  v_cfg := public.cs_dudas_cfg(v_prog);
  v_pal := (v_cfg ->> 'regla_palabra')::boolean;
  v_min := (v_cfg ->> 'min_palabras')::int;
  v_max := (v_cfg ->> 'max_por_llamada')::int;
  v_seg := (v_cfg ->> 'filtrar_segunda_persona')::boolean;

  return query
  with al as (
    select h.hablante as quien from public.cs_dudas_hablantes(p_llamada) h where h.rol = 'alumno'
  ),
  ln as (
    select btrim(m[1]) as quien, btrim(m[2]) as txt
    from regexp_split_to_table(v_texto, E'\r?\n') x,
         lateral (select regexp_match(x, '^\[[^\]]*\]\s*([^:]{1,80}):\s*(.*)$') as m) q
    where q.m is not null
  ),
  se as (
    select ln.quien, btrim(s.s) as s
    from ln, lateral regexp_split_to_table(ln.txt, '(?<=[.!?…])\s+') as s(s)
    where ln.quien in (select al.quien from al)
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
           -- ruido y logistica de la llamada
           (k.nn ~ '\m(escuch|oyen|oyes|oigo|congel|microfon|camar|conexion|audio|pantalla|link|enlace|grabac|grabando|grabar|horario|invitacion|calendario|agendar|reagend|reprogram|zoom\M|meet\M)'
              or k.nn ~ '\m(me|se) (ve|ves|ven|corta|cortan|escucha|escuchan|oye|oyen)\M'
              or k.nn ~ '\m(a que hora|que hora|proxima (llamada|reunion|clase|sesion)|esta grabando|estan grabando)'
              or k.n2 ~ '^(estas|estan|seguis|sigues|ahi|hola|me escuchas|me oyes|me ves|se ve|se ven|se escucha|se corta)( |$)') as ruido,
           (k.n2 ~ '^(como (te|les|le|ya|dije|dijimos|vimos|siempre|quedamos|hablamos|mencione|comentaba|decia)|que (bueno|lindo|bien|genial|barbaro|se yo|tal|loco|mal|pena|raro)|cuando (quieras|puedas)|donde (quieras|sea))') as no_preg,
           (k.nn ~ ' (no|si|verdad|cierto|viste|entendes|entiendes|ok|dale|te parece)$') as tag,
           -- segunda persona tipica del consultor hacia el alumno
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
  select t.qn, t.t, t.rg,
         case when t.rg = 'palabra' then 'baja' else v_conf end,
         case when t.rg = 'palabra' then 'palabra' else v_mot end,
         t.cont
  from top t
  where t.rn <= v_max
  order by t.rn;
end;
$fn$;


-- =====================================================================
-- 4. Detectar (escribe) y estado
-- =====================================================================
create or replace function public.cs_dudas_detectar_llamada(p_llamada uuid)
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_ll     record;
  v_nuevas int := 0;
  v_max    int;
  v_cupo   int;
  v_tot    int;
  v_alu    int;
  v_estado text;
  v_conf   text;
begin
  select l.id, l.cliente_id, l.programa_id, l.fecha, l.consultor, l.fuente
    into v_ll from public.cs_llamadas l where l.id = p_llamada;
  if not found or v_ll.fuente <> 'fathom' then
    return 0;
  end if;
  if not exists (select 1 from public.cs_llamada_transcripciones t where t.llamada_id = p_llamada) then
    return 0;
  end if;

  v_max := (public.cs_dudas_cfg(v_ll.programa_id) ->> 'max_por_llamada')::int;
  -- el tope cuenta lo que ya hay de esta llamada (pendientes y decididas): reprocesar no lo supera
  v_cupo := greatest(v_max - (select count(*) from public.cs_duda_candidatas c where c.llamada_id = p_llamada), 0)::int;

  insert into public.cs_duda_candidatas
    (programa_id, cliente_id, llamada_id, fecha, consultor, hablante, texto, regla, confianza, motivo)
  select v_ll.programa_id, v_ll.cliente_id, v_ll.id, v_ll.fecha, v_ll.consultor,
         e.hablante, e.texto, e.regla, e.confianza, e.motivo
  from public.cs_dudas_extraer(p_llamada) e
  where not exists (select 1 from public.cs_duda_candidatas c
                     where c.llamada_id = p_llamada and c.texto_norm = public.cs_norm_nombre(e.texto))
  order by e.puntaje desc, char_length(e.texto) desc, e.texto
  limit v_cupo
  on conflict (llamada_id, texto_norm) do nothing;
  get diagnostics v_nuevas = row_count;

  select count(*), count(*) filter (where h.rol = 'alumno') into v_tot, v_alu
  from public.cs_dudas_hablantes(p_llamada) h;
  select a.confianza into v_conf from public.cs_dudas_atribucion(p_llamada) a;
  v_estado := case when v_tot = 0 then 'sin_formato'
                   when v_conf is not null then 'ok'
                   when v_alu = 0 then 'sin_hablante'
                   else 'ambiguo' end;

  insert into public.cs_dudas_procesadas (llamada_id, programa_id, procesada_at, estado, candidatas, confianza)
  values (p_llamada, v_ll.programa_id, now(), v_estado,
          (select count(*) from public.cs_duda_candidatas c where c.llamada_id = p_llamada), v_conf)
  on conflict (llamada_id) do update
    set procesada_at = excluded.procesada_at, estado = excluded.estado,
        candidatas = excluded.candidatas, confianza = excluded.confianza;
  return v_nuevas;
end;
$fn$;

-- Conteos para la pantalla (quien ve el programa). Mismas claves de la 134 + pendientes por confianza.
create or replace function public.cs_dudas_estado(p_programa text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
begin
  if not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: sin acceso al programa' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'pendientes',  (select count(*) from public.cs_duda_candidatas c where c.programa_id = p_programa and c.estado = 'pendiente'),
    'pendientes_alta', (select count(*) from public.cs_duda_candidatas c
                         where c.programa_id = p_programa and c.estado = 'pendiente' and c.confianza = 'alta'),
    'pendientes_baja', (select count(*) from public.cs_duda_candidatas c
                         where c.programa_id = p_programa and c.estado = 'pendiente' and c.confianza = 'baja'),
    'agregadas',   (select count(*) from public.cs_duda_candidatas c where c.programa_id = p_programa and c.estado = 'agregada'),
    'descartadas', (select count(*) from public.cs_duda_candidatas c where c.programa_id = p_programa and c.estado = 'descartada'),
    'llamadas',    (select count(*) from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
                     where l.programa_id = p_programa and l.fuente = 'fathom'),
    'sin_procesar',(select count(*) from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
                     where l.programa_id = p_programa and l.fuente = 'fathom'
                       and not exists (select 1 from public.cs_dudas_procesadas x where x.llamada_id = l.id)),
    'sin_hablante',(select count(*) from public.cs_dudas_procesadas x
                     where x.programa_id = p_programa and x.estado <> 'ok'),
    'ambiguas',    (select count(*) from public.cs_dudas_procesadas x
                     where x.programa_id = p_programa and x.estado = 'ambiguo'));
end;
$fn$;


-- =====================================================================
-- 5. Permisos (las funciones recreadas pierden los grants)
-- =====================================================================
revoke all on function public.cs_dudas_hablantes(uuid) from public, anon, authenticated;
revoke all on function public.cs_dudas_extraer(uuid) from public, anon, authenticated;
revoke all on function public.cs_dudas_atribucion(uuid) from public, anon, authenticated;
revoke all on function public.cs_dudas_detectar_llamada(uuid) from public, anon, authenticated;
revoke all on function public.cs_dudas_cfg(text) from public, anon, authenticated;
revoke all on function public.cs_dudas_estado(text) from public, anon;
revoke all on function public.cs_dudas_config_leer(text) from public, anon;
revoke all on function public.cs_dudas_config_guardar(text, boolean, int, int, boolean) from public, anon;
grant execute on function public.cs_dudas_estado(text) to authenticated;
grant execute on function public.cs_dudas_config_leer(text) to authenticated;
grant execute on function public.cs_dudas_config_guardar(text, boolean, int, int, boolean) to authenticated;


-- =====================================================================
-- 6. PRUEBA DE HUMO (se revierte sola; no manda nada a Discord)
-- =====================================================================
do $$
declare
  v_c     record;
  v_fund  uuid;
  v_ll    uuid := gen_random_uuid();
  v_ll2   uuid := gen_random_uuid();
  v_w     text;
  v_n     int;
  v_c1    uuid;
  v_c2    uuid;
  v_c3    uuid;
  v_duda  uuid;
  v_j     jsonb;
begin
  begin
    select c.id, c.programa_id, c.nombre into v_c
      from public.cs_clientes c
     where public.cs_norm_nombre(c.nombre) ~ '[a-z]{3}' and position(':' in c.nombre) = 0
       and char_length(c.nombre) <= 80
     order by c.created_at limit 1;
    if not found then
      raise notice 'smoke 135: no hay alumnos; se omite la parte con datos';
      raise exception 'SMOKE_OK';
    end if;

    insert into public.cs_llamadas (id, programa_id, cliente_id, fecha, titulo, externo_id, fuente)
    values (v_ll, v_c.programa_id, v_c.id, public.cs_hoy() - 1, 'Humo 135', 'smoke135:' || v_ll::text, 'fathom');

    -- el trigger de la 134 corre solo al entrar la transcripcion
    insert into public.cs_llamada_transcripciones (llamada_id, programa_id, cliente_id, texto)
    values (v_ll, v_c.programa_id, v_c.id,
      '[00:00:01] Coach Humo: ¿Cómo te fue con el reel de la semana pasada?' || E'\n' ||
      '[00:00:09] ' || v_c.nombre || ': Hola, ¿cómo hago para subir un reel de humo todos los días? Bueno perfecto gracias.' || E'\n' ||
      '[00:00:20] ' || v_c.nombre || ': Cómo configuro el pixel de mi tienda de humo' || E'\n' ||
      '[00:00:30] ' || v_c.nombre || ': ¿Me escuchas bien? ¿Sí? Esto sale así, ¿no? Qué bueno que llegamos hasta acá.' || E'\n' ||
      '[00:00:40] ' || v_c.nombre || ': ¿Cuánto tarda en aprobar la cuenta publicitaria de mi tienda?' || E'\n' ||
      '[00:00:50] ' || v_c.nombre || ': ¿Pudiste ver el video que te mandé de la semana pasada?' || E'\n' ||
      '[00:01:00] ' || v_c.nombre || ': ¿Me podés compartir el link de la grabación de la llamada de hoy?' || E'\n' ||
      '[00:01:10] ' || v_c.nombre || ': ¿A qué horario nos conviene seguir hablando de esto mañana?' || E'\n' ||
      '[00:01:20] ' || v_c.nombre || ': ¿Cuánto cuesta el reel?');

    -- 1. atribucion alta (una voz con el nombre, una ajena)
    select count(*) into v_n from public.cs_dudas_atribucion(v_ll) a where a.confianza = 'alta' and a.motivo = 'nombre';
    if v_n <> 1 then raise exception 'smoke 135: atribucion no es alta/nombre'; end if;

    -- 2. exactamente 2 candidatas, ambas signo y alta; sin palabra, sin 2da persona, sin logistica, sin cortas
    select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll;
    if v_n <> 2 then raise exception 'smoke 135: candidatas = % (esperaba 2)', v_n; end if;
    select count(*) into v_n from public.cs_duda_candidatas
     where llamada_id = v_ll and regla = 'signo' and confianza = 'alta' and motivo = 'nombre';
    if v_n <> 2 then raise exception 'smoke 135: regla / confianza incorrectas (%)', v_n; end if;
    select count(*) into v_n from public.cs_duda_candidatas
     where llamada_id = v_ll and (texto ilike '%pixel%' or texto ilike '%pudiste%' or texto ilike '%link%'
                                  or texto ilike '%horario%' or texto ilike '%escuch%' or texto ilike '%cuesta el reel%');
    if v_n <> 0 then raise exception 'smoke 135: entraron oraciones que debian filtrarse (%)', v_n; end if;

    -- 3. idempotencia
    v_n := public.cs_dudas_detectar_llamada(v_ll);
    if v_n <> 0 then raise exception 'smoke 135: reprocesar agrego % filas', v_n; end if;
    select count(*) into v_n from public.cs_dudas_procesadas
     where llamada_id = v_ll and estado = 'ok' and candidatas = 2 and confianza = 'alta';
    if v_n <> 1 then raise exception 'smoke 135: procesada mal marcada'; end if;

    select id into v_c1 from public.cs_duda_candidatas where llamada_id = v_ll and texto ilike '%subir un reel%';
    select id into v_c2 from public.cs_duda_candidatas where llamada_id = v_ll and texto ilike '%cuenta publicitaria%';
    if v_c1 is null or v_c2 is null then raise exception 'smoke 135: faltan candidatas esperadas'; end if;

    -- 4. alumno ambiguo: dos voces con el nombre del alumno => sin candidatas, estado 'ambiguo'
    select w into v_w
      from unnest(string_to_array(public.cs_norm_nombre(v_c.nombre), ' ')) w
     where char_length(w) >= 3 and w <> all (array['del','los','las','van','von','dos','das','con','por']) limit 1;
    if v_w is not null then
      insert into public.cs_llamadas (id, programa_id, cliente_id, fecha, titulo, externo_id, fuente)
      values (v_ll2, v_c.programa_id, v_c.id, public.cs_hoy() - 1, 'Humo 135b', 'smoke135b:' || v_ll2::text, 'fathom');
      insert into public.cs_llamada_transcripciones (llamada_id, programa_id, cliente_id, texto)
      values (v_ll2, v_c.programa_id, v_c.id,
        '[00:00:09] ' || v_c.nombre || ': ¿Cómo hago para subir un reel de humo todos los días?' || E'\n' ||
        '[00:00:20] Invitado ' || v_w || ': ¿Cuánto tarda en aprobar la cuenta publicitaria de mi tienda?');
      select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll2;
      if v_n <> 0 then raise exception 'smoke 135: llamada ambigua genero % candidatas', v_n; end if;
      select count(*) into v_n from public.cs_dudas_procesadas where llamada_id = v_ll2 and estado = 'ambiguo';
      if v_n <> 1 then raise exception 'smoke 135: la llamada ambigua no quedo marcada'; end if;
    else
      raise notice 'smoke 135: el alumno no tiene palabra de 3+ letras; se omite el caso ambiguo';
    end if;

    -- 5. sin sesion no se puede gestionar ni cambiar la config
    begin
      perform public.cs_dudas_config_guardar(v_c.programa_id, true, null, null, null);
      raise exception 'smoke 135: sin sesion dejo guardar la config';
    exception when sqlstate '42501' then
      null;
    end;

    -- 6. como fundador
    select m.user_id into v_fund from public.crm_members m where m.rol = 'fundador' limit 1;
    if v_fund is null then
      raise notice 'smoke 135: no hay fundador en crm_members; se omiten las acciones y la config';
    else
      perform set_config('request.jwt.claim.sub', v_fund::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', v_fund, 'role', 'authenticated')::text, true);

      -- defaults
      v_j := public.cs_dudas_config_leer(v_c.programa_id);
      if (v_j ->> 'regla_palabra')::boolean or (v_j ->> 'min_palabras')::int <> 6
         or (v_j ->> 'max_por_llamada')::int <> 6 or not (v_j ->> 'filtrar_segunda_persona')::boolean then
        raise exception 'smoke 135: defaults = %', v_j;
      end if;

      -- acciones de la 134 siguen andando
      v_j := public.cs_duda_cand_crear(v_c1, 'Como subo un reel (humo 135)');
      v_duda := (v_j ->> 'duda_id')::uuid;
      if v_duda is null or not (v_j ->> 'nueva')::boolean then raise exception 'smoke 135: crear = %', v_j; end if;
      perform public.cs_duda_cand_agregar(v_c2, v_duda);
      select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll and estado = 'agregada';
      if v_n <> 2 then raise exception 'smoke 135: agregadas = %', v_n; end if;

      -- prender 'palabra': entra la candidata del pixel, siempre en baja confianza
      perform public.cs_dudas_config_guardar(v_c.programa_id, true, null, null, null);
      v_n := public.cs_dudas_detectar_llamada(v_ll);
      if v_n <> 1 then raise exception 'smoke 135: con palabra prendida entraron % (esperaba 1)', v_n; end if;
      select id into v_c3 from public.cs_duda_candidatas
       where llamada_id = v_ll and texto ilike '%pixel%' and regla = 'palabra' and confianza = 'baja' and motivo = 'palabra';
      if v_c3 is null then raise exception 'smoke 135: la candidata palabra no quedo en baja'; end if;
      select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll and estado = 'agregada';
      if v_n <> 2 then raise exception 'smoke 135: reprocesar piso estados (agregadas = %)', v_n; end if;

      -- tope por llamada: con 1, el control devuelve 1; el detector no pasa de lo que ya hay
      perform public.cs_dudas_config_guardar(v_c.programa_id, null, null, 1, null);
      select count(*) into v_n from public.cs_dudas_extraer(v_ll);
      if v_n <> 1 then raise exception 'smoke 135: tope 1 devolvio %', v_n; end if;
      if public.cs_dudas_detectar_llamada(v_ll) <> 0 then raise exception 'smoke 135: el tope no frena el detector'; end if;

      -- minimo de palabras: con 20 no queda ninguna por signo
      perform public.cs_dudas_config_guardar(v_c.programa_id, false, 20, 6, null);
      select count(*) into v_n from public.cs_dudas_extraer(v_ll);
      if v_n <> 0 then raise exception 'smoke 135: minimo 20 devolvio %', v_n; end if;

      v_j := public.cs_dudas_estado(v_c.programa_id);
      if v_j -> 'pendientes_alta' is null or v_j -> 'pendientes_baja' is null then
        raise exception 'smoke 135: estado = %', v_j;
      end if;

      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '', true);
    end if;

    -- 7. permisos
    if has_function_privilege('authenticated', 'public.cs_dudas_extraer(uuid)', 'execute')
       or has_function_privilege('authenticated', 'public.cs_dudas_atribucion(uuid)', 'execute')
       or has_function_privilege('authenticated', 'public.cs_dudas_hablantes(uuid)', 'execute')
       or has_function_privilege('authenticated', 'public.cs_dudas_detectar_llamada(uuid)', 'execute')
       or has_function_privilege('anon', 'public.cs_dudas_config_guardar(text,boolean,int,int,boolean)', 'execute') then
      raise exception 'smoke 135: permisos de funcion incorrectos';
    end if;
    if has_table_privilege('authenticated', 'public.cs_dudas_config', 'insert')
       or has_table_privilege('authenticated', 'public.cs_dudas_config', 'update')
       or has_table_privilege('anon', 'public.cs_dudas_config', 'select') then
      raise exception 'smoke 135: permisos de tabla incorrectos';
    end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 135: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

commit;

-- =====================================================================
-- CONTROLES (de a uno, después de correr)
-- =====================================================================
-- C1. Objetos en su lugar (esperado: 1 tabla de config, 2 columnas en candidatas, 1 en procesadas,
--     6 funciones nuevas o reemplazadas, 4 respaldos).
--   select (select count(*) from pg_class where oid = 'public.cs_dudas_config'::regclass) as config,
--          (select count(*) from information_schema.columns where table_name = 'cs_duda_candidatas' and column_name in ('confianza','motivo')) as cols_cand,
--          (select count(*) from information_schema.columns where table_name = 'cs_dudas_procesadas' and column_name = 'confianza') as col_proc,
--          (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
--             ('cs_dudas_cfg','cs_dudas_config_leer','cs_dudas_config_guardar','cs_dudas_atribucion','cs_dudas_extraer','cs_dudas_hablantes')) as funciones,
--          (select count(*) from public.cs_bak_135_funciones) as respaldos;
--
-- C2. CONTROL DE CALIDAD: cuántas candidatas daría la regla NUEVA por llamada (no escribe nada).
--     Comparar con las 144 de antes (unas 18 por llamada). Esperado: como máximo 6 por llamada
--     (tope), o sea 48 como mucho en las 8 de teo, y bastante menos por llamada que 18. Una llamada
--     con atribucion NULL no daría ninguna (alumno no identificado).
--   select l.fecha, l.consultor, l.id as llamada, a.confianza as atribucion, a.motivo,
--          count(e.texto) filter (where e.confianza = 'alta') as alta,
--          count(e.texto) filter (where e.confianza = 'baja') as baja,
--          count(e.texto) as total
--   from public.cs_llamadas l
--   join public.cs_llamada_transcripciones t on t.llamada_id = l.id
--   left join lateral public.cs_dudas_atribucion(l.id) a on true
--   left join lateral public.cs_dudas_extraer(l.id) e on true
--   where l.fuente = 'fathom' and l.programa_id = 'teo'
--   group by 1, 2, 3, 4, 5 order by 1 desc, 3;
--
-- C3. Total del control de calidad (una fila) y comparación con la 134 (144 candidatas, 8 llamadas).
--   select count(distinct l.id) as llamadas, count(e.texto) as candidatas,
--          count(e.texto) filter (where e.confianza = 'alta') as alta,
--          count(e.texto) filter (where e.confianza = 'baja') as baja,
--          count(distinct l.id) filter (where not exists (select 1 from public.cs_dudas_atribucion(l.id))) as llamadas_sin_alumno_identificado
--   from public.cs_llamadas l
--   join public.cs_llamada_transcripciones t on t.llamada_id = l.id
--   left join lateral public.cs_dudas_extraer(l.id) e on true
--   where l.fuente = 'fathom' and l.programa_id = 'teo';
--
-- C4. Las mismas candidatas con su texto, para revisar a ojo (30 al azar; ya no deberia haber
--     preguntas del consultor, de logística ni cortas).
--   select l.fecha, e.regla, e.confianza, e.motivo, e.puntaje, e.hablante, e.texto
--   from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
--   cross join lateral public.cs_dudas_extraer(l.id) e
--   where l.fuente = 'fathom' and l.programa_id = 'teo' order by random() limit 30;
--
-- C5. Quién habla y cómo se atribuyó, en las llamadas con transcripción (por = nombre | unico).
--   select l.fecha, h.hablante, h.lineas, h.rol, h.por
--   from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
--   cross join lateral public.cs_dudas_hablantes(l.id) h
--   where l.fuente = 'fathom' and l.programa_id = 'teo' order by l.fecha desc, l.id, h.rol;
--
-- C6. Configuración vigente (esperado: regla_palabra false, 6, 6, true; sin fila = defaults).
--   select 'teo' as programa, public.cs_dudas_cfg('teo') as cfg;
--
-- C7. Lo que ya existía de la 134: quedó marcado (pendientes en baja, nada borrado).
--   select estado, confianza, motivo, count(*) from public.cs_duda_candidatas group by 1, 2, 3 order by 1, 2, 3;
--
-- C8. Permisos (esperado: authenticated sin execute en las 4 internas, con execute en las 3 de la pantalla).
--   select has_function_privilege('authenticated', 'public.cs_dudas_extraer(uuid)', 'execute') as extraer,
--          has_function_privilege('authenticated', 'public.cs_dudas_atribucion(uuid)', 'execute') as atribucion,
--          has_function_privilege('authenticated', 'public.cs_dudas_hablantes(uuid)', 'execute') as hablantes,
--          has_function_privilege('authenticated', 'public.cs_dudas_config_guardar(text,boolean,int,int,boolean)', 'execute') as guardar,
--          has_table_privilege('authenticated', 'public.cs_dudas_config', 'insert') as ins;
--
-- C9. Las llamadas nuevas siguen entrando (el trigger de la 134 no las frena) y llevan confianza.
--   select l.fecha, p.estado, p.confianza, p.candidatas, p.procesada_at
--   from public.cs_llamadas l left join public.cs_dudas_procesadas p on p.llamada_id = l.id
--   where l.fuente = 'fathom' order by l.created_at desc limit 20;

-- =====================================================================
-- VUELTA ATRÁS (en este orden; las funciones vuelven a la definición de la 134 desde el respaldo)
-- =====================================================================
--   begin;
--   drop function if exists public.cs_dudas_extraer(uuid);
--   drop function if exists public.cs_dudas_hablantes(uuid);
--   update public.cs_dudas_procesadas set estado = 'sin_hablante' where estado = 'ambiguo';
--   do $$ declare r record; begin
--     for r in select def from public.cs_bak_135_funciones
--               where nombre in ('cs_dudas_hablantes','cs_dudas_extraer','cs_dudas_detectar_llamada','cs_dudas_estado')
--               order by case nombre when 'cs_dudas_hablantes' then 1 when 'cs_dudas_extraer' then 2 else 3 end
--     loop execute r.def; end loop;
--   end $$;
--   revoke all on function public.cs_dudas_hablantes(uuid) from public, anon, authenticated;
--   revoke all on function public.cs_dudas_extraer(uuid) from public, anon, authenticated;
--   revoke all on function public.cs_dudas_detectar_llamada(uuid) from public, anon, authenticated;
--   drop function if exists public.cs_dudas_config_guardar(text, boolean, int, int, boolean);
--   drop function if exists public.cs_dudas_config_leer(text);
--   drop function if exists public.cs_dudas_cfg(text);
--   drop function if exists public.cs_dudas_atribucion(uuid);
--   drop table if exists public.cs_dudas_config;
--   alter table public.cs_dudas_procesadas drop constraint if exists cs_dudas_procesadas_estado_chk;
--   alter table public.cs_dudas_procesadas add constraint cs_dudas_procesadas_estado_check
--     check (estado in ('ok', 'sin_hablante', 'sin_formato'));
--   alter table public.cs_dudas_procesadas drop column if exists confianza;
--   alter table public.cs_duda_candidatas drop column if exists confianza, drop column if exists motivo;
--   commit;
--   -- Opcional, cuando ya no haga falta: drop table public.cs_bak_135_funciones;
