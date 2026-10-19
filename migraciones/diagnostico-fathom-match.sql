-- =====================================================================
-- Diagnóstico del match de Fathom (SOLO LECTURA: únicamente SELECT; no cambia nada).
-- Correr cada bloque por separado en el SQL Editor (como fundador / rol con acceso a las tablas).
-- Este archivo tiene datos personales en sus resultados (mails, nombres): no pegarlos en Discord ni en chats.
-- Tablas: cs_fathom_sin_asignar (llamadas pendientes), cs_clientes, cs_clientes_mails, cs_clientes_alias.
-- Un alumno "coincide por mail" si el mail del invitado, en minúsculas, es el principal o un mail extra de una ficha.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Panorama: las pendientes por consultor, con qué traen (invitados, nombres, candidatos).
--    Si "sin_invitados" es alto, el problema es que la sync no guarda a nadie (invitados sin mail, o solo equipo).
-- ---------------------------------------------------------------------
select s.consultor,
       count(*)                                                        as pendientes,
       count(*) filter (where jsonb_array_length(s.invitados) = 0)     as sin_invitados,
       count(*) filter (where cardinality(s.nombres) = 0)              as sin_nombres,
       count(*) filter (where cardinality(s.candidatos) > 0)           as con_candidatos_sync,
       count(*) filter (where s.titulo is null or btrim(s.titulo) = '') as sin_titulo,
       round(avg(s.duracion_min)::numeric, 0)                          as duracion_media_min
from public.cs_fathom_sin_asignar s
where s.estado = 'pendiente'
group by s.consultor
order by 2 desc;

-- ---------------------------------------------------------------------
-- 2. Títulos más repetidos de las pendientes (¿genéricos? "Reunión de Zoom", "Consultoría", sin nombre).
-- ---------------------------------------------------------------------
select lower(btrim(coalesce(s.titulo, '(sin título)'))) as titulo, count(*) as veces,
       count(*) filter (where jsonb_array_length(s.invitados) > 0) as con_invitados
from public.cs_fathom_sin_asignar s
where s.estado = 'pendiente'
group by 1
order by 2 desc
limit 30;

-- ---------------------------------------------------------------------
-- 3. Muestra de ~20 pendientes (mezcla joaco y teo, las más recientes de cada una): título, fecha, duración,
--    consultor, invitados (mails), nombres detectados y día / hora ART. Es la base de los bloques 4 a 7.
-- ---------------------------------------------------------------------
with muestra as (
  select s.*, row_number() over (partition by s.consultor order by s.fecha desc, s.inicio_at desc) as rn
  from public.cs_fathom_sin_asignar s
  where s.estado = 'pendiente' and s.consultor in ('joaco', 'teo')
)
select m.id, m.consultor, m.fecha,
       to_char(m.inicio_at at time zone 'America/Argentina/Buenos_Aires', 'Dy HH24:MI') as dia_hora_art,
       m.duracion_min, m.titulo,
       (select string_agg(x, ', ') from jsonb_array_elements_text(m.invitados) x) as invitados_mails,
       array_to_string(m.nombres, ' | ') as nombres_detectados,
       cardinality(m.candidatos) as candidatos_sync
from muestra m
where m.rn <= 10
order by m.consultor, m.fecha desc;

-- ---------------------------------------------------------------------
-- 4. Esas mismas llamadas: ¿el mail de algún invitado existe en cs_clientes?
--    exacto = igual en minúsculas (principal o extra);  sin_puntos = gmail sin puntos ni +etiqueta;
--    mismo_usuario = misma parte local con otro dominio (6+ letras).
--    Si todo da 0 acá, los mails de los invitados NO están en ninguna ficha.
-- ---------------------------------------------------------------------
with muestra as (
  select s.id, s.consultor, s.fecha, s.titulo, s.invitados,
         row_number() over (partition by s.consultor order by s.fecha desc, s.inicio_at desc) as rn
  from public.cs_fathom_sin_asignar s
  where s.estado = 'pendiente' and s.consultor in ('joaco', 'teo')
), inv as (
  select m.id, m.consultor, m.fecha, m.titulo, lower(btrim(x)) as mail,
         regexp_replace(split_part(split_part(lower(btrim(x)), '@', 1), '+', 1), '[^a-z0-9]', '', 'g') as local_limpio,
         split_part(lower(btrim(x)), '@', 2) as dominio
  from muestra m, jsonb_array_elements_text(m.invitados) x
  where m.rn <= 10
), fichas as (          -- todos los mails de fichas: principal + extra
  select c.id as cliente_id, c.programa_id, c.estado, lower(btrim(c.email)) as mail from public.cs_clientes c where c.email is not null
  union
  select e.cliente_id, e.programa_id, c.estado, lower(btrim(e.email)) from public.cs_clientes_mails e join public.cs_clientes c on c.id = e.cliente_id
), fichas_n as (
  select f.*, regexp_replace(split_part(split_part(f.mail, '@', 1), '+', 1), '[^a-z0-9]', '', 'g') as local_limpio,
         split_part(f.mail, '@', 2) as dominio
  from fichas f
)
select i.consultor, i.fecha, left(i.titulo, 40) as titulo, i.mail,
       (select count(distinct f.cliente_id) from fichas_n f where f.mail = i.mail)                                   as exacto,
       (select count(distinct f.cliente_id) from fichas_n f
         where f.dominio in ('gmail.com', 'googlemail.com') and i.dominio in ('gmail.com', 'googlemail.com')
           and f.local_limpio = i.local_limpio)                                                                        as gmail_sin_puntos,
       (select count(distinct f.cliente_id) from fichas_n f
         where length(i.local_limpio) >= 6 and f.local_limpio = i.local_limpio and f.dominio <> i.dominio)           as mismo_usuario_otro_dominio
from inv i
order by i.consultor, i.fecha desc, i.mail;

-- ---------------------------------------------------------------------
-- 5a. ¿Está la extensión pg_trgm? Si "instalada" da null, saltear el 5b y usar el 6.
--     El set_config agrega el esquema "extensions" al search_path solo de esta sesión (Supabase instala ahí las extensiones).
-- ---------------------------------------------------------------------
select (select extname from pg_extension where extname = 'pg_trgm') as instalada,
       set_config('search_path', 'public, extensions', false)       as search_path;

-- ---------------------------------------------------------------------
-- 5b. Alumnos con nombre parecido al título (word_similarity >= 0.50 de pg_trgm), 3 mejores por llamada de la muestra.
--     Si no aparece nadie, el alumno probablemente no está en cs_clientes o el título no lo nombra.
-- ---------------------------------------------------------------------
with muestra as (
  select s.id, s.consultor, s.fecha, s.titulo,
         row_number() over (partition by s.consultor order by s.fecha desc, s.inicio_at desc) as rn
  from public.cs_fathom_sin_asignar s
  where s.estado = 'pendiente' and s.consultor in ('joaco', 'teo') and s.titulo is not null
), par as (
  select m.id, m.consultor, m.fecha, left(m.titulo, 40) as titulo, c.nombre, c.programa_id, c.estado,
         word_similarity(public.cs_norm_nombre(c.nombre), public.cs_norm_nombre(m.titulo)) as sim
  from muestra m cross join public.cs_clientes c
  where m.rn <= 10
), top3 as (
  select p.*, row_number() over (partition by p.id order by p.sim desc) as r from par p where p.sim >= 0.50
)
select consultor, fecha, titulo, nombre as alumno_parecido, programa_id, estado, round(sim::numeric, 2) as similitud
from top3 where r <= 3
order by consultor, fecha desc, id, r;

-- ---------------------------------------------------------------------
-- 6. Sin extensión, por palabras: llamada de la muestra y alumno cuando alguna palabra del nombre (4+ letras)
--    está dentro del título. Más ruido que el 5b (nombres comunes), pero no depende de pg_trgm.
-- ---------------------------------------------------------------------
with muestra as (
  select s.id, s.consultor, s.fecha, s.titulo,
         row_number() over (partition by s.consultor order by s.fecha desc, s.inicio_at desc) as rn
  from public.cs_fathom_sin_asignar s
  where s.estado = 'pendiente' and s.consultor in ('joaco', 'teo') and s.titulo is not null
), pal as (
  select c.id, c.nombre, c.programa_id, c.estado, p as palabra
  from public.cs_clientes c, unnest(regexp_split_to_array(public.cs_norm_nombre(c.nombre), ' ')) p
  where length(p) >= 4
)
select m.consultor, m.fecha, left(m.titulo, 50) as titulo, pal.nombre as alumno, pal.programa_id, pal.estado,
       string_agg(distinct pal.palabra, ', ') as palabras_que_coinciden
from muestra m
join pal on public.cs_norm_nombre(m.titulo) like '%' || pal.palabra || '%'
where m.rn <= 10
group by m.id, m.consultor, m.fecha, m.titulo, pal.id, pal.nombre, pal.programa_id, pal.estado
order by m.consultor, m.fecha desc, pal.nombre
limit 200;

-- ---------------------------------------------------------------------
-- 7. Las pendientes que caen en un horario de consultoría semanal (cs_consultoria_horarios) y NO fueron
--    reclasificadas: si hay filas, falta apretar "Reclasificar llamadas ya sincronizadas" (Configuración > Consultorías grupales).
--    Misma regla que cs_consultoria_horario_buscar: mismo consultor, mismo día ART, arranque dentro de la tolerancia.
-- ---------------------------------------------------------------------
select s.consultor, h.programa_id, h.dia_semana, h.hora, h.tolerancia_min,
       count(*) as pendientes_en_horario, min(s.fecha) as desde, max(s.fecha) as hasta
from public.cs_fathom_sin_asignar s
join public.cs_consultoria_horarios h
  on h.activo and h.consultor = s.consultor
 and h.dia_semana = extract(isodow from (s.inicio_at at time zone 'America/Argentina/Buenos_Aires'))::int
 and abs(extract(epoch from ((s.inicio_at at time zone 'America/Argentina/Buenos_Aires')::time - h.hora))) <= h.tolerancia_min * 60
where s.estado in ('pendiente', 'interna', 'no_alumno')
group by s.consultor, h.programa_id, h.dia_semana, h.hora, h.tolerancia_min
order by s.consultor, h.dia_semana, h.hora;

-- ---------------------------------------------------------------------
-- 8. Los 20 invitados (mails) que más aparecen en las pendientes: un mail que se repite 5+ veces es casi seguro
--    un alumno VIP (o un socio / prospecto frecuente) que no está en ninguna ficha: candidato a cargar como mail extra.
--    "en_fichas" = cuántas fichas lo tienen (0 = falta cargarlo).
-- ---------------------------------------------------------------------
with inv as (
  select lower(btrim(x)) as mail, s.consultor, s.fecha
  from public.cs_fathom_sin_asignar s, jsonb_array_elements_text(s.invitados) x
  where s.estado = 'pendiente'
)
select i.mail, count(*) as llamadas, count(distinct i.consultor) as consultores, min(i.fecha) as primera, max(i.fecha) as ultima,
       (select count(*) from public.cs_clientes c where lower(btrim(c.email)) = i.mail)
       + (select count(*) from public.cs_clientes_mails e where lower(btrim(e.email)) = i.mail) as en_fichas
from inv i
group by i.mail
order by llamadas desc
limit 20;

-- ---------------------------------------------------------------------
-- 9. Cobertura del pool: alumnos por programa y estado, con y sin mail (¿cuántos tienen el mail cargado?).
-- ---------------------------------------------------------------------
select c.programa_id, c.estado, count(*) as alumnos,
       count(*) filter (where c.email is null or btrim(c.email) = '') as sin_mail,
       count(*) filter (where c.email ~* '@(gmail|hotmail|outlook|yahoo|icloud)\.') as mail_personal
from public.cs_clientes c
group by 1, 2
order by 1, 2;
