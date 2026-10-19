-- =====================================================================
-- 194 · Fathom: consultor -> programa, match por horario más seguro y Reclasificar por tandas
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 157 (horarios y consultorías), 124/127 (cs_fathom_consultores, cs_fathom_sin_asignar), es_fundador(), cs_puede_ver().
--
-- Cómo matcheaba antes (157): cs_consultoria_horario_buscar(consultor, inicio) devuelve el horario ACTIVO cuyo
--   consultor es exactamente la cuenta de Fathom que grabó, mismo día de la semana (hora Argentina) y arranque a
--   +-tolerancia_min de la hora (cada horario ya tenía SU tolerancia); si hay dos, el más cercano. La duración
--   NO participa del match (es solo un dato). El programa salía del horario; sin horario no había programa.
--
-- Qué hace esta migración
--   A. Tabla cs_fathom_consultor_programas (consultor, programa_id): en qué programa(s) trabaja cada cuenta de Fathom,
--      aunque la llamada no caiga justo en un horario. Un consultor puede tener más de un programa. Lee quien ve el
--      programa; se escribe SOLO con cs_fathom_consultor_programas_guardar (fundador). Semilla: teo -> teo, martu -> teo
--      (joaco sin programa fijo). NO cambia quién ve qué (la RLS de la 187 no usa esta tabla).
--   B. cs_consultoria_aplicar (la usan fathom-sync y Reclasificar): NO convierte en consultoría una reunión que ya
--      es llamada de un alumno (cs_llamadas sin consultoría) ni una que una persona ya resolvió (asignada, "no es
--      alumno", o pendiente que una persona reabrió: no_auto). En esos casos devuelve 'sin_horario' (+ motivo) y la
--      sync sigue su camino normal, así que fathom-sync NO necesita cambios.
--   C. cs_consultoria_reclasificar(p_limite) reemplaza a la versión sin parámetros: ya NO toca llamadas de alumnos,
--      solo pendientes / internas automáticas que caen en un horario, de a p_limite (25 por defecto, máx 100),
--      las más nuevas primero. Devuelve cuántas quedan para repetir el botón (las 335 viejas de teo no entran en 8 s).
--      Las consultorías ya registradas NO se recalculan ni se mueven.
--   D. Martu (martes 18:00 del programa teo): tolerancia 60 min si hoy es menor. Duración: no hay cambios, el match no la usa.
--
-- No toca: fathom-sync, ia-fathom-clasificar, RLS de llamadas / propuestas, Finanzas, CRM, Ventas. No borra datos.
-- Correr en una sola ejecución, fuera de :00/:15/:30/:45 y de las 9:00. Controles C1 a C7 y vuelta atrás comentados al final.
-- =====================================================================

begin;
set local lock_timeout = '8s';

do $chk$
declare
  v_falta text;
begin
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_fathom_consultores', 'cs_fathom_sin_asignar', 'cs_llamadas',
                    'cs_consultoria_horarios', 'cs_consultorias']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception '194: faltan tablas (corrieron 124, 127 y 157?): %', v_falta;
  end if;
  if to_regprocedure('public.es_fundador()') is null or to_regprocedure('public.cs_puede_ver(text)') is null
     or to_regprocedure('public.cs_consultoria_aplicar(jsonb)') is null
     or to_regprocedure('public.cs_consultoria_horario_buscar(text,timestamptz)') is null then
    raise exception '194: faltan funciones de la 157 / es_fundador() / cs_puede_ver(text)';
  end if;
  if to_regclass('public.cs_fathom_consultor_programas') is not null then
    raise exception '194: ya fue corrida (existe cs_fathom_consultor_programas)';
  end if;
end
$chk$;

lock table public.cs_consultoria_horarios, public.cs_consultorias, public.cs_fathom_sin_asignar in share row exclusive mode;


-- =====================================================================
-- A. Consultor -> programa(s)
-- =====================================================================
create table public.cs_fathom_consultor_programas (
  consultor    text not null references public.cs_fathom_consultores(id) on delete cascade,
  programa_id  text not null references public.cs_programas(id),
  created_at   timestamptz not null default now(),
  primary key (consultor, programa_id)
);
comment on table public.cs_fathom_consultor_programas is
  '194: programa(s) en que trabaja cada cuenta de Fathom. Sirve para ubicar una llamada en su programa aunque no caiga en un horario. No decide permisos. Se escribe con cs_fathom_consultor_programas_guardar (fundador).';

alter table public.cs_fathom_consultor_programas enable row level security;
revoke all on table public.cs_fathom_consultor_programas from public, anon, authenticated;
grant select on table public.cs_fathom_consultor_programas to authenticated, service_role;
create policy cs_select on public.cs_fathom_consultor_programas for select to authenticated
  using (coalesce(public.es_fundador(), false) or public.cs_puede_ver(programa_id));

-- Reemplaza TODOS los programas de un consultor (fundador).
create or replace function public.cs_fathom_consultor_programas_guardar(p_consultor text, p_programas text[])
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_arr text[] := coalesce(p_programas, '{}'::text[]);
  v_n   int;
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede cambiar el programa de un consultor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.cs_fathom_consultores c where c.id = p_consultor) then
    raise exception 'cs: consultor desconocido' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_arr) x where not exists (select 1 from public.cs_programas p where p.id = x)) then
    raise exception 'cs: programa desconocido' using errcode = '22023';
  end if;
  delete from public.cs_fathom_consultor_programas where consultor = p_consultor and programa_id <> all (v_arr);
  insert into public.cs_fathom_consultor_programas (consultor, programa_id)
  select p_consultor, x from (select distinct unnest(v_arr) as x) u
  on conflict do nothing;
  select count(*) into v_n from public.cs_fathom_consultor_programas where consultor = p_consultor;
  return v_n;
end;
$fn$;
revoke all on function public.cs_fathom_consultor_programas_guardar(text, text[]) from public, anon;
grant execute on function public.cs_fathom_consultor_programas_guardar(text, text[]) to authenticated;

-- Semilla: teo -> teo, martu -> teo. joaco queda sin programa fijo.
insert into public.cs_fathom_consultor_programas (consultor, programa_id)
select v.c, v.p
from (values ('teo', 'teo'), ('martu', 'teo')) v(c, p)
where exists (select 1 from public.cs_fathom_consultores c where c.id = v.c)
  and exists (select 1 from public.cs_programas p where p.id = v.p)
on conflict do nothing;


-- =====================================================================
-- B. cs_consultoria_aplicar: igual a la 157 + no pisa lo ya asignado ni lo confirmado por una persona
-- =====================================================================
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

  -- 194: ya es llamada de un alumno (asignada por mail, nombre o a mano) -> no se convierte en consultoría.
  if exists (select 1 from public.cs_llamadas l where l.externo_id = v_ext and l.consultoria_id is null) then
    return jsonb_build_object('resultado', 'sin_horario', 'motivo', 'ya_asignada');
  end if;
  -- 194: una persona ya la resolvió (asignada, "no es alumno", o pendiente que reabrió a mano) -> se respeta.
  if exists (select 1 from public.cs_fathom_sin_asignar s
             where s.externo_id = v_ext
               and (s.estado in ('asignada', 'no_alumno') or (s.estado = 'pendiente' and s.no_auto))) then
    return jsonb_build_object('resultado', 'sin_horario', 'motivo', 'ya_resuelta');
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

  -- si la reunion ya habia entrado como llamada de esta consultoria o como pendiente / interna, se reclasifica
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


-- =====================================================================
-- C. Reclasificar por tandas, sin tocar llamadas de alumnos ni lo confirmado
-- =====================================================================
drop function if exists public.cs_consultoria_reclasificar();

create or replace function public.cs_consultoria_reclasificar(p_limite int default 25)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  r        record;
  v_lim    int := greatest(1, least(coalesce(p_limite, 25), 100));
  v_sa     int := 0;
  v_res    jsonb;
  v_quedan int;
  v_omit_a int;
  v_omit_c int;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede reclasificar llamadas' using errcode = '42501';
  end if;

  -- Solo pendientes / internas AUTOMATICAS que caen en un horario. Las más nuevas primero.
  for r in
    select s.externo_id, s.consultor, s.inicio_at, s.titulo, s.duracion_min, s.grabacion_url, s.grabacion_share_url,
           s.resumen, s.transcripcion, s.invitados, s.nombres
    from public.cs_fathom_sin_asignar s
    where s.estado in ('pendiente', 'interna') and not s.no_auto and s.llamada_id is null
      and s.consultor is not null and s.inicio_at is not null
      and public.cs_consultoria_horario_buscar(s.consultor, s.inicio_at) is not null
    order by s.inicio_at desc
    limit v_lim
  loop
    v_res := public.cs_consultoria_aplicar(jsonb_build_object(
      'externo_id', r.externo_id, 'consultor', r.consultor, 'inicio_at', r.inicio_at, 'titulo', r.titulo,
      'duracion_min', r.duracion_min, 'grabacion_url', r.grabacion_url, 'grabacion_share_url', r.grabacion_share_url,
      'resumen', r.resumen, 'transcripcion', r.transcripcion,
      'asistentes',
        coalesce((select jsonb_agg(jsonb_build_object('email', e #>> '{}'))
                  from jsonb_array_elements(case when jsonb_typeof(r.invitados) = 'array' then r.invitados else '[]'::jsonb end) e
                  where jsonb_typeof(e) = 'string'), '[]'::jsonb)
        || coalesce((select jsonb_agg(jsonb_build_object('nombre', n)) from unnest(r.nombres) n), '[]'::jsonb)));
    if (v_res ->> 'resultado') in ('creada', 'actualizada') then v_sa := v_sa + 1; end if;
  end loop;

  select count(*) into v_quedan
  from public.cs_fathom_sin_asignar s
  where s.estado in ('pendiente', 'interna') and not s.no_auto and s.llamada_id is null
    and s.consultor is not null and s.inicio_at is not null
    and public.cs_consultoria_horario_buscar(s.consultor, s.inicio_at) is not null;

  -- Lo que cae en un horario pero se respeta (informativo).
  select count(*) into v_omit_a
  from public.cs_llamadas l
  where l.fuente = 'fathom' and l.consultoria_id is null and l.externo_id is not null
    and l.consultor is not null and l.inicio_at is not null
    and public.cs_consultoria_horario_buscar(l.consultor, l.inicio_at) is not null;
  select count(*) into v_omit_c
  from public.cs_fathom_sin_asignar s
  where (s.estado in ('asignada', 'no_alumno') or (s.estado = 'pendiente' and s.no_auto))
    and s.consultor is not null and s.inicio_at is not null
    and public.cs_consultoria_horario_buscar(s.consultor, s.inicio_at) is not null;

  return jsonb_build_object(
    'llamadas_reclasificadas', 0,                 -- ya no se tocan llamadas de alumnos (clave que lee la pantalla)
    'pendientes_reclasificadas', v_sa,
    'quedan', v_quedan,
    'omitidas_de_alumno', v_omit_a,
    'omitidas_confirmadas', v_omit_c,
    'consultorias', (select count(*) from public.cs_consultorias));
end;
$fn$;
revoke all on function public.cs_consultoria_reclasificar(int) from public, anon;
grant execute on function public.cs_consultoria_reclasificar(int) to authenticated;


-- =====================================================================
-- D. Martu: martes 18:00 del programa teo, tolerancia 60 (solo si hoy es menor)
-- =====================================================================
do $mar$
declare
  v_n int;
begin
  update public.cs_consultoria_horarios
     set tolerancia_min = 60
   where programa_id = 'teo' and dia_semana = 2 and hora = time '18:00' and tolerancia_min < 60;
  get diagnostics v_n = row_count;
  raise notice '194: horarios del martes 18:00 (teo) pasados a tolerancia 60: %', v_n;
end
$mar$;

comment on column public.cs_consultoria_horarios.tolerancia_min is
  '157/194: minutos antes o después de la hora de inicio en que una reunión del consultor cuenta para este horario. Es por horario y se edita en Configuración > Consultorías grupales.';
comment on column public.cs_consultoria_horarios.duracion_min is
  '157/194: duración HABITUAL, solo informativa. El match usa el arranque de la reunión: una clase de 40 min a 3 h cuenta igual.';


-- Verificación (dentro de la transacción)
do $ver$
begin
  if not (select relrowsecurity from pg_class where oid = 'public.cs_fathom_consultor_programas'::regclass) then
    raise exception '194: cs_fathom_consultor_programas sin RLS';
  end if;
  if to_regprocedure('public.cs_consultoria_reclasificar(integer)') is null
     or to_regprocedure('public.cs_consultoria_reclasificar()') is not null then
    raise exception '194: la firma de cs_consultoria_reclasificar quedó mal';
  end if;
  if exists (select 1 from public.cs_consultoria_horarios where tolerancia_min < 60
             and programa_id = 'teo' and dia_semana = 2 and hora = time '18:00') then
    raise exception '194: quedó un horario del martes 18:00 con tolerancia menor a 60';
  end if;
end
$ver$;

commit;


-- =====================================================================
-- CONTROLES (correr de a uno, DESPUÉS del commit)
-- =====================================================================
-- C1. Semilla consultor -> programa. Esperado: teo -> teo y martu -> teo (si existen las cuentas); joaco sin filas.
--   select consultor, programa_id from public.cs_fathom_consultor_programas order by 1, 2;
-- C2. Horarios y tolerancia. Esperado: martes 18:00 con tolerancia 60; el resto igual que antes. Si el martes 18:00 no
--     aparece, el horario de martu todavía no está cargado (o tiene otra hora): se corrige en la pantalla.
--   select programa_id, consultor, dia_semana, hora, duracion_min, tolerancia_min, activo
--   from public.cs_consultoria_horarios order by programa_id, dia_semana, hora;
-- C3. Cuántas pendientes caen hoy en un horario (lo que va a procesar Reclasificar), por consultor.
--   select s.consultor, count(*) from public.cs_fathom_sin_asignar s
--   where s.estado in ('pendiente','interna') and not s.no_auto and s.llamada_id is null
--     and public.cs_consultoria_horario_buscar(s.consultor, s.inicio_at) is not null
--   group by 1 order by 1;
-- C4. Llamadas de alumnos que caen en un horario y NO se van a tocar (esperado: se informan, no cambian).
--   select l.consultor, count(*) from public.cs_llamadas l
--   where l.fuente = 'fathom' and l.consultoria_id is null and l.inicio_at is not null
--     and public.cs_consultoria_horario_buscar(l.consultor, l.inicio_at) is not null
--   group by 1 order by 1;
-- C5. Duración variable: el match no la usa. Esperado: una fila por cada reunión, sin importar duracion_min.
--   select s.duracion_min, public.cs_consultoria_horario_buscar(s.consultor, s.inicio_at) is not null as cae
--   from public.cs_fathom_sin_asignar s where s.consultor = 'teo' order by s.inicio_at desc limit 20;
-- C6. RLS y permisos. Esperado: 1 fila con relrowsecurity = true; authenticated solo con select.
--   select relrowsecurity from pg_class where oid = 'public.cs_fathom_consultor_programas'::regclass;
--   select privilege_type from information_schema.role_table_grants
--   where table_name = 'cs_fathom_consultor_programas' and grantee = 'authenticated';
-- C7. Después de apretar Reclasificar varias veces hasta que "quedan" sea 0: las consultorías creadas por programa.
--   select programa_id, consultor, count(*) from public.cs_consultorias group by 1, 2 order by 1, 2;

-- =====================================================================
-- VUELTA ATRÁS (comentada). La versión anterior de aplicar / reclasificar está en la 157 (secciones D5 y D7).
-- =====================================================================
-- begin;
--   drop function if exists public.cs_consultoria_reclasificar(int);
--   -- volver a correr en 157 las secciones D5 (cs_consultoria_aplicar) y D7 (cs_consultoria_reclasificar sin parámetros)
--   drop function if exists public.cs_fathom_consultor_programas_guardar(text, text[]);
--   drop table if exists public.cs_fathom_consultor_programas;
-- commit;
