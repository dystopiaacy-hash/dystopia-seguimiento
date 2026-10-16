-- =====================================================================
-- 162-producto-revision-16-10.sql  ·  PRODUCTO: arreglos de la revisión del 16/10
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución). Evitar los minutos :00, :15, :30 y :45
-- (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- Requiere 039 (cs_cerrar_vencidos, cs_ren_abierta), 071 (campos_extra), 130 (cs_csm_generar), 134 y 135
-- (cs_duda_candidatas con confianza y motivo) y 139 (cs_ia_riesgo_pendientes).
-- NO tiene datos personales. No crea ni cambia crons. Nada se borra: lo que cambia se respalda en cs_bak_162_*.
--
-- Qué hace (los números son los de la lista de la revisión):
--   2. Riesgo de abandono: cs_ia_riesgo_pendientes() ya no ordena por nombre. Antes, con 60 alumnos por corrida
--      y orden alfabético, los últimos de la lista (L, M, T...) esperaban varios días y, si algún alumno
--      fallaba, volvía a ocupar su lugar al principio todos los días. Ahora: primero los NUNCA evaluados, en un
--      orden que rota cada día (md5 del alumno + la fecha), y después los que cambiaron, del más viejo al más
--      nuevo. La función ia-riesgo-abandono (TypeScript, se despliega aparte) además sube a 150 por corrida
--      y pide las señales de todos de una sola vez (antes, una consulta de pagos por alumno).
--   3. Vencidos sin renovar: todo alumno vivo (onboarding, activo, en renovación) vencido hace MAS DE 30 DIAS
--      y sin una renovación 'renovado' vigente pasa a 'finalizado' (la misma regla del cierre diario
--      cs_cerrar_vencidos, 039, pero con 30 días de margen). Respaldo en cs_bak_162_clientes y marca en
--      campos_extra.cierre162. Se apaga cs_trg_after_cierre durante el UPDATE: no se generan accionables de
--      offboarding para gente que se fue hace meses (se vuelve a prender en la misma transacción). Las
--      renovaciones abiertas de esos alumnos las cierra solo el próximo cierre diario ("Vencido sin respuesta").
--      OJO: el cierre diario YA hacía esto; que haya quedado gente vencida hace 285 días significa que no corre
--      o que falla. Mirar el control C3 (cron) y C4 (fallas) antes de dar el tema por cerrado.
--   4. Proceso CSM duplicado: cs_csm_resell_unica() deja UNA sola tarea de resell pendiente por alumno y fecha de
--      fin: la MAS VIEJA (la que vence primero, la que ya está para hacer; decisión de Joaquín 16/10). Las
--      pendientes más nuevas del mismo alumno y fecha de fin pasan a 'completado' con la nota
--      "Duplicada de una anterior." (no se borra nada; respaldo en cs_bak_162_accionables). Solo cuenta otra
--      PENDIENTE de origen plantilla: si la vieja ya se completó, la siguiente queda. Empate de vence: queda la de
--      menor id. Mismo criterio en la corrida inicial y en el chequeo diario.
--      cs_csm_generar() se renombra a cs_csm_generar_base() y queda un cs_csm_generar() nuevo que la llama y
--      después aplica cs_csm_resell_unica(): el chequeo diario, el botón "Generar ahora" y los llamados de
--      siempre siguen funcionando sin cambios. Se corre una vez al final de esta migración para limpiar lo que
--      ya está duplicado.
--   6. Dudas frecuentes: cs_duda_texto_problema() devuelve 'no_espanol' (más palabras de inglés que de español)
--      o 'fragmento' (empieza con «...» o termina cortado en una palabra suelta como "de", "y", "que"). Un
--      trigger BEFORE INSERT en cs_duda_candidatas deja esas candidatas con confianza 'baja' y ese motivo: la
--      pantalla las oculta por defecto ("Solo alta confianza") y ia-dudas solo lee las de confianza alta.
--      Las pendientes de confianza alta que ya existen y caen en esa regla se pasan a 'baja' (respaldo en
--      cs_bak_162_dudas). No se descarta ni se borra ninguna.
--
-- ANTES de correrla, mirar a cuántos finaliza el punto 3 (solo lectura, sin nombres):
--   select c.programa_id, c.estado, count(*) as se_finalizan, max(public.cs_hoy() - c.fecha_fin) as max_dias_vencido
--   from public.cs_clientes c
--   where c.estado in ('onboarding','activo','en_renovacion') and c.fecha_fin < public.cs_hoy() - 30
--     and not exists (select 1 from public.cs_renovaciones r where r.cliente_id = c.id and r.estado = 'renovado'
--                     and r.nueva_fecha_fin >= public.cs_hoy())
--   group by 1, 2 order by 1, 2;
--
-- Qué NO toca: crons, Fathom, finanzas, crm, ventas, cs_cerrar_vencidos, cs_correr_diario, la vista de KPIs.
-- Los puntos 1 y 5 (texto de Fathom en bruto, aviso a 30 días) son solo de la app: no necesitan SQL.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo: lo que usa esta migración tiene que existir.
do $$
declare
  v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values
    ('cs_hoy()'), ('es_fundador()'), ('cs_ren_abierta(text)'), ('cs_csm_generar(text)'),
    ('cs_ia_riesgo_pendientes(int,text)'), ('cs_riesgo_senales(text,uuid)')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null
    and not (r.f = 'cs_csm_generar(text)' and to_regprocedure('public.cs_csm_generar_base(text)') is not null);
  if v_falta is not null then
    raise exception 'cs 162: faltan funciones (corrieron 039, 130 y 139?): %', v_falta;
  end if;
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_clientes'), ('cs_accionables'), ('cs_renovaciones'), ('cs_duda_candidatas'), ('cs_riesgo_abandono')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 162: faltan tablas (corrieron 130, 134 y 139?): %', v_falta;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_clientes' and column_name = 'campos_extra') then
    raise exception 'cs 162: falta cs_clientes.campos_extra (071)';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_duda_candidatas' and column_name = 'confianza') then
    raise exception 'cs 162: falta cs_duda_candidatas.confianza (135)';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.cs_clientes'::regclass
                 and tgname = 'cs_trg_after_cierre') then
    raise exception 'cs 162: falta el trigger cs_trg_after_cierre en cs_clientes (039)';
  end if;
end $$;

-- Todas las tablas que lee la app o el cron, juntas y al principio (ya hubo un deadlock por no hacerlo).
lock table public.cs_clientes, public.cs_accionables, public.cs_renovaciones, public.cs_duda_candidatas
  in share row exclusive mode;


-- =====================================================================
-- 0. RESPALDOS
-- =====================================================================
create table if not exists public.cs_bak_162_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldado_at timestamptz not null default now()
);
create table if not exists public.cs_bak_162_clientes (
  id          uuid primary key,
  estado      text not null,
  campos_extra jsonb,
  respaldado_at timestamptz not null default now()
);
create table if not exists public.cs_bak_162_accionables (
  id          uuid primary key,
  estado      text not null,
  descripcion text,
  respaldado_at timestamptz not null default now()
);
create table if not exists public.cs_bak_162_dudas (
  id          uuid primary key,
  confianza   text not null,
  motivo      text,
  respaldado_at timestamptz not null default now()
);
revoke all on table public.cs_bak_162_funciones, public.cs_bak_162_clientes,
  public.cs_bak_162_accionables, public.cs_bak_162_dudas from public, anon, authenticated;
alter table public.cs_bak_162_funciones enable row level security;
alter table public.cs_bak_162_clientes enable row level security;
alter table public.cs_bak_162_accionables enable row level security;
alter table public.cs_bak_162_dudas enable row level security;

-- Definición vigente de la función que se reemplaza (solo la primera vez).
insert into public.cs_bak_162_funciones (funcion, definicion)
select 'cs_ia_riesgo_pendientes(int,text)', pg_get_functiondef('public.cs_ia_riesgo_pendientes(int,text)'::regprocedure)
on conflict (funcion) do nothing;


-- =====================================================================
-- 2. RIESGO DE ABANDONO: orden justo de la cola
-- =====================================================================
-- Misma firma y mismas columnas que la 139. Solo cambia el orden.
create or replace function public.cs_ia_riesgo_pendientes(p_limite int default 30, p_programa text default null)
returns table (cliente_id uuid, programa_id text, nombre text)
language sql stable security definer set search_path = public
as $fn$
  select s.cliente_id, s.programa_id, s.nombre
  from public.cs_riesgo_senales(p_programa, null) s
  left join public.cs_riesgo_abandono r on r.cliente_id = s.cliente_id
  where r.cliente_id is null or r.huella <> s.huella
  order by (r.cliente_id is null) desc,                                   -- primero los nunca evaluados
           r.evaluado_en nulls first,                                     -- después el más viejo
           md5(s.cliente_id::text || public.cs_hoy()::text)               -- rota cada día: un alumno que falla no frena a los demás
  limit greatest(coalesce(p_limite, 30), 0)
$fn$;
revoke all on function public.cs_ia_riesgo_pendientes(int, text) from public, anon, authenticated;
grant execute on function public.cs_ia_riesgo_pendientes(int, text) to service_role;


-- =====================================================================
-- 3. VENCIDOS SIN RENOVAR (más de 30 días) -> finalizado
-- =====================================================================
create temp table cierre162 on commit drop as
select c.id, c.estado, c.campos_extra, (public.cs_hoy() - c.fecha_fin) as dias_vencido
from public.cs_clientes c
where c.estado in ('onboarding', 'activo', 'en_renovacion')
  and c.fecha_fin is not null
  and c.fecha_fin < public.cs_hoy() - 30
  and not exists (
    select 1 from public.cs_renovaciones r
    where r.cliente_id = c.id and r.estado = 'renovado' and r.nueva_fecha_fin >= public.cs_hoy());

insert into public.cs_bak_162_clientes (id, estado, campos_extra)
select id, estado, campos_extra from cierre162
on conflict (id) do nothing;

-- Sin offboarding por esta limpieza (ver cabecera). Se vuelve a prender enseguida, en esta transacción.
alter table public.cs_clientes disable trigger cs_trg_after_cierre;

update public.cs_clientes c
   set estado = 'finalizado',
       campos_extra = coalesce(c.campos_extra, '{}'::jsonb)
         || jsonb_build_object('cierre162', jsonb_build_object(
              'fecha', public.cs_hoy(), 'estado_antes', k.estado, 'dias_vencido', k.dias_vencido))
  from cierre162 k
 where k.id = c.id;

alter table public.cs_clientes enable trigger cs_trg_after_cierre;


-- =====================================================================
-- 4. PROCESO CSM: una sola tarea de resell por alumno y renovación
-- =====================================================================
create or replace function public.cs_csm_resell_unica(p_programa text default null)
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int;
begin
  -- Pendientes de resell para las que existe otra PENDIENTE del MISMO alumno y la MISMA fecha de fin que vence
  -- antes (o el mismo día con menor id): queda la más vieja, se cierran las más nuevas.
  with viejas as (
    select a.id, a.estado, a.descripcion
    from public.cs_accionables a
    where a.plantilla_key ~ '^csm:res:[0-9]+:[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      and a.estado <> 'completado'
      and a.origen = 'plantilla'
      and a.vence is not null
      and (p_programa is null or a.programa_id = p_programa)
      and exists (
        select 1 from public.cs_accionables b
        where b.cliente_id = a.cliente_id
          and b.id <> a.id
          and b.plantilla_key ~ '^csm:res:[0-9]+:[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          and split_part(b.plantilla_key, ':', 4) = split_part(a.plantilla_key, ':', 4)
          and b.estado <> 'completado'
          and b.origen = 'plantilla'
          and b.vence is not null
          and (b.vence < a.vence or (b.vence = a.vence and b.id < a.id)))
  ), bak as (
    insert into public.cs_bak_162_accionables (id, estado, descripcion)
    select v.id, v.estado, v.descripcion from viejas v
    on conflict (id) do nothing
    returning 1
  ), cerradas as (
    update public.cs_accionables a
       set estado = 'completado',
           descripcion = left(btrim(coalesce(a.descripcion, '') || ' Duplicada de una anterior.'), 500)
      from viejas v
     where v.id = a.id
    returning 1
  )
  select count(*) into v_n from cerradas;
  return v_n;
end;
$fn$;
revoke all on function public.cs_csm_resell_unica(text) from public, anon, authenticated;

-- cs_csm_generar (130) pasa a llamarse cs_csm_generar_base; el nombre de siempre queda como envoltorio.
do $$
begin
  if to_regprocedure('public.cs_csm_generar_base(text)') is null then
    insert into public.cs_bak_162_funciones (funcion, definicion)
    select 'cs_csm_generar(text)', pg_get_functiondef('public.cs_csm_generar(text)'::regprocedure)
    on conflict (funcion) do nothing;
    alter function public.cs_csm_generar(text) rename to cs_csm_generar_base;
  end if;
end $$;
revoke all on function public.cs_csm_generar_base(text) from public, anon, authenticated;

create or replace function public.cs_csm_generar(p_programa text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_j jsonb;
  v_u int;
begin
  v_j := public.cs_csm_generar_base(p_programa);            -- valida el permiso (fundador) y crea lo que falta
  v_u := public.cs_csm_resell_unica(p_programa);
  return v_j || jsonb_build_object('resell_duplicados_cerrados', v_u);
end;
$fn$;
comment on function public.cs_csm_generar(text) is
  'Genera los accionables del proceso CSM (130) y deja una sola tarea de resell por alumno y renovación (162). Idempotente.';
revoke all on function public.cs_csm_generar(text) from public, anon;
grant execute on function public.cs_csm_generar(text) to authenticated;   -- valida fundador adentro

-- Limpieza de lo que ya está duplicado (idempotente: la segunda vez no encuentra nada).
select public.cs_csm_resell_unica(null);


-- =====================================================================
-- 6. DUDAS: preguntas que no están en español o son fragmentos
-- =====================================================================
create or replace function public.cs_duda_texto_problema(p_texto text)
returns text
language plpgsql
immutable
set search_path = public
as $fn$
declare
  v_x   text := replace(lower(coalesce(p_texto, '')), '’', '''');
  v_ing text[] := array['the','and','you','that','is','are','was','were','this','what','why','how','do','does','did',
                        'have','has','with','for','not','but','so','because','about','from','just','like','would',
                        'could','should','can','will','i','i''m','it','it''s','that''s','don''t','can''t','didn''t',
                        'what''s','there','they','your','my','we','when','where','if','then','than','an','be','been',
                        'to','of','in','on','at','all','she','her','his','their','our','us'];
  v_esp text[] := array['que','qué','el','la','los','las','de','del','un','una','unos','unas','y','en','por','para',
                        'con','se','es','como','cómo','lo','mi','mis','tu','su','sus','al','más','pero','ya','muy',
                        'hay','está','esto','eso','cuando','cuándo','donde','dónde','puedo','puedes','tengo',
                        'quiero','si','también','entonces','porque','cual','cuál','sobre','sin','le','les','te',
                        'nos','ese','esa','este','esta','son','fue','ser','tiene','hacer'];
  v_p   text[];
  v_n   int;
  v_en  int;
  v_es  int;
begin
  v_p  := array_remove(regexp_split_to_array(v_x, '[^a-záéíóúüñ'']+'), '');
  v_n  := coalesce(cardinality(v_p), 0);
  select count(*) filter (where k = any (v_ing)), count(*) filter (where k = any (v_esp))
    into v_en, v_es
    from unnest(v_p) k;

  if (v_en >= 2 and v_en > v_es) or (v_es = 0 and v_en >= 1 and v_n >= 5) then
    return 'no_espanol';
  end if;
  -- Fragmento de charla: arranca en puntos suspensivos o termina cortado en una palabra suelta.
  if v_x ~ '^\s*(\.\.\.|…)' then
    return 'fragmento';
  end if;
  if v_n < 9 and v_n >= 1
     and v_p[v_n] = any (array['de','del','y','e','o','que','con','para','por','a','en','un','una','la','el','los','las','pero','and','or','the','of','to']) then
    return 'fragmento';
  end if;
  return null;
end;
$fn$;
comment on function public.cs_duda_texto_problema(text) is
  '162: null si la pregunta sirve; "no_espanol" o "fragmento" si no. Heurística simple por palabras, sin IA.';

create or replace function public.cs_tg_duda_cand_filtro()
returns trigger
language plpgsql
set search_path = public
as $fn$
declare
  v text;
begin
  v := public.cs_duda_texto_problema(new.texto);
  if v is not null then
    new.confianza := 'baja';
    new.motivo := v;
  end if;
  return new;
end;
$fn$;

drop trigger if exists cs_trg_duda_cand_filtro on public.cs_duda_candidatas;
create trigger cs_trg_duda_cand_filtro before insert on public.cs_duda_candidatas
  for each row execute function public.cs_tg_duda_cand_filtro();

-- Las pendientes de confianza alta que ya existen y caen en la regla: pasan a 'baja' (no se descartan).
create temp table dudas162 on commit drop as
select c.id, c.confianza, c.motivo, public.cs_duda_texto_problema(c.texto) as problema
from public.cs_duda_candidatas c
where c.estado = 'pendiente' and c.confianza = 'alta';
delete from dudas162 where problema is null;

insert into public.cs_bak_162_dudas (id, confianza, motivo)
select id, confianza, motivo from dudas162
on conflict (id) do nothing;

update public.cs_duda_candidatas c
   set confianza = 'baja', motivo = d.problema
  from dudas162 d
 where d.id = c.id;


-- =====================================================================
-- PRUEBA DE HUMO (solo funciones puras: no escribe nada; si falla, frena toda la migración)
-- =====================================================================
do $$
begin
  if public.cs_duda_texto_problema('So that''s why I''m divided about whether to keep going with this?') is distinct from 'no_espanol' then
    raise exception 'humo 162: una pregunta en inglés no se detectó';
  end if;
  if public.cs_duda_texto_problema('¿Cómo hago para subir el video de la clase al drive?') is not null then
    raise exception 'humo 162: una pregunta en español válida se marcó';
  end if;
  if public.cs_duda_texto_problema('y cuando hago esto con el cliente de?') is distinct from 'fragmento' then
    raise exception 'humo 162: un fragmento cortado no se detectó';
  end if;
  if public.cs_duda_texto_problema('Se puede cambiar el plan después de pagar la primera cuota?') is not null then
    raise exception 'humo 162: una pregunta en español sin ¿ se marcó';
  end if;
end $$;

commit;


-- =====================================================================
-- CONTROLES (correr de a uno, después del commit)
-- =====================================================================
-- C1. Riesgo: evaluados vs vivos por programa. Después de desplegar ia-riesgo-abandono y correr el lote
--     (ver abajo) "sin_evaluar" tiene que bajar a 0 en pocas corridas.
-- select s.programa_id, count(*) as vivos, count(r.cliente_id) as evaluados, count(*) - count(r.cliente_id) as sin_evaluar
-- from public.cs_riesgo_senales(null, null) s
-- left join public.cs_riesgo_abandono r on r.cliente_id = s.cliente_id
-- group by 1 order by 1;
--     Para vaciar la cola YA (cada corrida hace hasta 150; repetir hasta faltan_despues = 0), con la secret key:
--     curl -X POST "$URL/functions/v1/ia-riesgo-abandono" -H "authorization: Bearer $SECRET" -H "content-type: application/json" -d '{"lote":true,"max":200}'
--     Costo: ~0,0009 USD por alumno evaluado (Haiku 5.5); para estimar sin gastar: -d '{"lote":true,"solo_contar":true}'.

-- C2. Vencidos que quedaron vivos (esperado: 0 filas, salvo los que tienen una renovación 'renovado' vigente
--     y no actualizaron su fecha_fin: esos se ven en C2b).
-- select c.programa_id, count(*) from public.cs_clientes c
-- where c.estado in ('onboarding','activo','en_renovacion') and c.fecha_fin < public.cs_hoy() - 30 group by 1;
-- C2b. Los de arriba que tienen una renovación 'renovado' vigente (dato inconsistente: arreglar fecha_fin a mano).
-- select c.programa_id, c.nombre, c.estado, c.fecha_fin, r.nueva_fecha_fin
-- from public.cs_clientes c join public.cs_renovaciones r on r.cliente_id = c.id and r.estado = 'renovado' and r.nueva_fecha_fin >= public.cs_hoy()
-- where c.estado in ('onboarding','activo','en_renovacion') and c.fecha_fin < public.cs_hoy() - 30;
-- C2c. Cuántos se finalizaron en esta migración, por programa y días vencidos (sin nombres).
-- select c.programa_id, count(*) as finalizados, min((c.campos_extra->'cierre162'->>'dias_vencido')::int) as min_dias,
--        max((c.campos_extra->'cierre162'->>'dias_vencido')::int) as max_dias
-- from public.cs_clientes c where c.campos_extra ? 'cierre162' group by 1;

-- C3. ¿Corre el cierre diario? Esperado: una fila activa que llama a cs_correr_diario.
-- select jobid, jobname, schedule, active, command from cron.job where command ilike '%cs_correr_diario%' or jobname ilike '%cs_diario%';
-- C4. Últimas corridas de ese cron: si "status" dice failed, el motivo está en return_message (si falla algo
--     DESPUES del cierre, todo el chequeo se revierte y nadie se finaliza nunca: es la causa más probable).
-- select d.start_time, d.status, left(d.return_message, 300) as mensaje
-- from cron.job_run_details d join cron.job j on j.jobid = d.jobid
-- where j.command ilike '%cs_correr_diario%' order by d.start_time desc limit 10;

-- C5. Resell duplicado (esperado: 0 filas): más de una pendiente por alumno y fecha de fin.
-- select a.cliente_id, split_part(a.plantilla_key, ':', 4) as fecha_fin, count(*)
-- from public.cs_accionables a
-- where a.plantilla_key ~ '^csm:res:[0-9]+:[0-9]{4}-[0-9]{2}-[0-9]{2}$' and a.estado <> 'completado'
-- group by 1, 2 having count(*) > 1;
-- C5b. Cuántas se cerraron por esta migración.
-- select count(*) from public.cs_bak_162_accionables;

-- C6. Dudas: candidatas marcadas por la regla nueva, por motivo y estado.
-- select estado, confianza, motivo, count(*) from public.cs_duda_candidatas
-- where motivo in ('no_espanol', 'fragmento') group by 1, 2, 3 order by 1, 2, 3;
-- C6b. Pendientes de confianza alta que todavía caen en la regla (esperado: 0).
-- select count(*) from public.cs_duda_candidatas c
-- where c.estado = 'pendiente' and c.confianza = 'alta' and public.cs_duda_texto_problema(c.texto) is not null;

-- C7. El generador sigue funcionando (solo lectura: la vista previa no escribe).
-- select public.cs_csm_resumen('teo');


-- =====================================================================
-- VUELTA ATRAS (comentada; correr completa y en una sola ejecución)
-- =====================================================================
--   begin;
--   lock table public.cs_clientes, public.cs_accionables, public.cs_duda_candidatas in share row exclusive mode;
--   -- 6. dudas
--   drop trigger if exists cs_trg_duda_cand_filtro on public.cs_duda_candidatas;
--   drop function if exists public.cs_tg_duda_cand_filtro();
--   update public.cs_duda_candidatas c set confianza = b.confianza, motivo = b.motivo
--     from public.cs_bak_162_dudas b where b.id = c.id;
--   drop function if exists public.cs_duda_texto_problema(text);
--   -- 4. proceso CSM
--   drop function if exists public.cs_csm_generar(text);
--   alter function public.cs_csm_generar_base(text) rename to cs_csm_generar;
--   grant execute on function public.cs_csm_generar(text) to authenticated;
--   drop function if exists public.cs_csm_resell_unica(text);
--   update public.cs_accionables a set estado = b.estado, descripcion = b.descripcion
--     from public.cs_bak_162_accionables b where b.id = a.id;
--   -- 3. vencidos (vuelven a su estado; sin offboarding)
--   alter table public.cs_clientes disable trigger cs_trg_after_cierre;
--   update public.cs_clientes c set estado = b.estado, campos_extra = b.campos_extra
--     from public.cs_bak_162_clientes b where b.id = c.id;
--   alter table public.cs_clientes enable trigger cs_trg_after_cierre;
--   -- 2. orden de la cola de riesgo (definición anterior)
--   do $$ declare r record; begin
--     for r in select definicion from public.cs_bak_162_funciones where funcion = 'cs_ia_riesgo_pendientes(int,text)'
--     loop execute r.definicion; end loop; end $$;
--   -- (las tablas cs_bak_162_* se pueden dejar o borrar a mano cuando ya no hagan falta)
--   commit;
