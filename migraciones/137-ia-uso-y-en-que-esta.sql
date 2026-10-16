-- =====================================================================
-- 137 · IA Fase 1 · registro de uso de IA (compartido con el CRM) + "En qué está" por alumno
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 001 (cs_clientes, cs_puede_ver), 102 y 106 (cs_llamadas.resumen, cs_llamada_accionables),
--           122 (cs_llamadas.fuente = 'fathom'), es_fundador() del sistema.
-- No toca Fathom, Discord, Finanzas ni ningún dato existente.
--
-- Qué hace
--   A. ia_uso: una fila por llamada a un modelo de IA (cualquier app). CONTRATO COMPARTIDO con el CRM:
--      el CRM escribe acá con service role. Solo el fundador lee; nadie escribe desde el front.
--      Vista ia_uso_mensual (mes, app, funcion, modelo: cantidad, tokens, costo).
--      SIN topes por gasto: solo se mide.
--   B. cs_en_que_esta: texto "En qué está" automático por alumno (una fila por alumno), con las
--      llamadas de Fathom de las que salió y la fecha de actualización.
--      cs_ia_en_que_esta_pendientes(): alumnos vivos con llamadas de Fathom con resumen que todavía
--      no entraron en su texto (o sin texto). La usa la Edge Function ia-en-que-esta.
--      cs_ia_puede_actualizar(cliente): fundador o edición del programa (botón "Actualizar").
--   C. Cron cs_ia_en_que_esta: 10:27 y 19:27 ART (13:27 y 22:27 UTC), 20 minutos después de la sync de
--      Fathom. Mismo patrón: net.http_post con URL y clave en Vault. La URL (ia_en_que_esta_url) se
--      agrega a Vault desde esta migración; la clave es la misma fin_sync_service_key.
--
-- Correr en una sola ejecución, evitando los minutos :00, :15, :30, :45 y las 9:00.
-- Después: desplegar la función (supabase functions deploy ia-en-que-esta --no-verify-jwt), ver C1 a C8.
-- =====================================================================

begin;
set local lock_timeout = '8s';

-- Autochequeo de requisitos
do $chk$
begin
  if to_regclass('public.cs_llamadas') is null or to_regclass('public.cs_llamada_accionables') is null then
    raise exception '137: falta la 102 (cs_llamadas / cs_llamada_accionables)';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_llamadas' and column_name = 'resumen') then
    raise exception '137: falta la 106 (cs_llamadas.resumen)';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_llamadas' and column_name = 'fuente') then
    raise exception '137: falta la 122 (cs_llamadas.fuente)';
  end if;
  if to_regprocedure('public.es_fundador()') is null then
    raise exception '137: falta la funcion es_fundador()';
  end if;
end
$chk$;

lock table public.cs_llamadas, public.cs_clientes in share row exclusive mode;


-- =====================================================================
-- A. ia_uso (contrato compartido con el CRM)
-- =====================================================================
create table if not exists public.ia_uso (
  id              bigserial primary key,
  creado_en       timestamptz not null default now(),
  app             text not null check (app in ('producto', 'crm', 'finanzas', 'ventas')),
  funcion         text not null check (btrim(funcion) <> ''),
  user_id         uuid,                       -- null si lo dispara un cron
  cliente_id      text,                       -- alumno / lead / cliente (texto: cada app tiene su tipo de id)
  modelo          text not null check (btrim(modelo) <> ''),
  tokens_entrada  int,
  tokens_salida   int,
  costo_usd       numeric(10,6),
  ok              boolean not null,
  error           text check (error is null or char_length(error) <= 300),   -- nunca texto de alumnos
  ms              int
);
create index if not exists ia_uso_creado_idx on public.ia_uso (creado_en);
create index if not exists ia_uso_app_funcion_idx on public.ia_uso (app, funcion);
create index if not exists ia_uso_cliente_idx on public.ia_uso (cliente_id);

comment on table public.ia_uso is
  'Registro de cada llamada a un modelo de IA (137). Contrato compartido entre apps: escribe solo service role (Edge Functions); lee solo el fundador. Sin topes: solo mide.';

alter table public.ia_uso enable row level security;
drop policy if exists ia_uso_select on public.ia_uso;
create policy ia_uso_select on public.ia_uso for select to authenticated
  using (coalesce(public.es_fundador(), false));
-- Sin policies de insert/update/delete: el front no escribe. service role salta RLS.
revoke all on public.ia_uso from public, anon, authenticated;
grant select on public.ia_uso to authenticated;
grant usage, select on sequence public.ia_uso_id_seq to service_role;

create or replace view public.ia_uso_mensual
with (security_invoker = true) as
select date_trunc('month', creado_en at time zone 'America/Argentina/Buenos_Aires')::date as mes,
       app, funcion, modelo,
       count(*)                                   as llamadas,
       count(*) filter (where not ok)             as fallidas,
       coalesce(sum(tokens_entrada), 0)::bigint   as tokens_entrada,
       coalesce(sum(tokens_salida), 0)::bigint    as tokens_salida,
       coalesce(sum(costo_usd), 0)::numeric(12,6) as costo_usd
from public.ia_uso
group by 1, 2, 3, 4;
revoke all on public.ia_uso_mensual from public, anon;
grant select on public.ia_uso_mensual to authenticated;


-- =====================================================================
-- B. cs_en_que_esta
-- =====================================================================
create table if not exists public.cs_en_que_esta (
  cliente_id     uuid primary key,
  programa_id    text not null references public.cs_programas(id),
  texto          text not null check (btrim(texto) <> '' and char_length(texto) <= 2000),
  llamadas_ids   uuid[] not null default '{}',     -- TODAS las llamadas con resumen vistas al generar (para detectar nuevas)
  reuniones      jsonb not null default '[]'::jsonb,   -- las usadas en el texto: [{id, fecha, titulo}]
  actualizado_en timestamptz not null default now(),
  modelo         text not null,
  constraint cs_en_que_esta_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_en_que_esta_programa_idx on public.cs_en_que_esta (programa_id);
comment on table public.cs_en_que_esta is
  '"En qué está" automático por alumno (137), armado con IA a partir de los resúmenes de Fathom. Escribe solo la Edge Function ia-en-que-esta (service role).';

alter table public.cs_en_que_esta enable row level security;
drop policy if exists cs_en_que_esta_select on public.cs_en_que_esta;
create policy cs_en_que_esta_select on public.cs_en_que_esta for select to authenticated
  using (public.cs_puede_ver(programa_id));
revoke all on public.cs_en_que_esta from public, anon, authenticated;
grant select on public.cs_en_que_esta to authenticated;


-- Alumnos a actualizar: vivos, con al menos una llamada de Fathom con resumen que no esté en
-- llamadas_ids de su fila (o sin fila). Solo service role. p_programa null = todos.
create or replace function public.cs_ia_en_que_esta_pendientes(p_limite int default 10, p_programa text default null)
returns table (cliente_id uuid, programa_id text, nombre text, llamadas int)
language sql stable security definer set search_path = public
as $fn$
  select c.id, c.programa_id, c.nombre, count(l.id)::int
  from public.cs_clientes c
  join public.cs_llamadas l
    on l.cliente_id = c.id and l.fuente = 'fathom' and nullif(btrim(l.resumen), '') is not null
  left join public.cs_en_que_esta e on e.cliente_id = c.id
  where c.estado in ('onboarding', 'activo', 'en_renovacion')
    and (p_programa is null or c.programa_id = p_programa)
  group by c.id, c.programa_id, c.nombre, e.llamadas_ids, e.cliente_id
  having e.cliente_id is null
      or exists (select 1 from public.cs_llamadas l2
                 where l2.cliente_id = c.id and l2.fuente = 'fathom' and nullif(btrim(l2.resumen), '') is not null
                   and not (l2.id = any (e.llamadas_ids)))
  order by max(l.fecha) desc
  limit greatest(coalesce(p_limite, 10), 0)
$fn$;
revoke all on function public.cs_ia_en_que_esta_pendientes(int, text) from public, anon, authenticated;
grant execute on function public.cs_ia_en_que_esta_pendientes(int, text) to service_role;

-- Cuántos hay en total (para estimar la primera corrida).
create or replace function public.cs_ia_en_que_esta_contar(p_programa text default null)
returns table (programa_id text, alumnos int, llamadas int)
language sql stable security definer set search_path = public
as $fn$
  select c.programa_id, count(distinct c.id)::int, count(l.id)::int
  from public.cs_clientes c
  join public.cs_llamadas l
    on l.cliente_id = c.id and l.fuente = 'fathom' and nullif(btrim(l.resumen), '') is not null
  left join public.cs_en_que_esta e on e.cliente_id = c.id
  where c.estado in ('onboarding', 'activo', 'en_renovacion')
    and (p_programa is null or c.programa_id = p_programa)
    and (e.cliente_id is null or not (l.id = any (e.llamadas_ids)))
  group by c.programa_id
$fn$;
revoke all on function public.cs_ia_en_que_esta_contar(text) from public, anon, authenticated;
grant execute on function public.cs_ia_en_que_esta_contar(text) to service_role;

-- Botón "Actualizar" de la ficha: fundador o edición en el programa del alumno.
create or replace function public.cs_ia_puede_actualizar(p_cliente uuid)
returns boolean
language sql stable security definer set search_path = public
as $fn$
  select coalesce(public.es_fundador(), false)
      or exists (select 1 from public.cs_clientes c
                 where c.id = p_cliente and public.cs_puede_editar(c.programa_id))
$fn$;
revoke all on function public.cs_ia_puede_actualizar(uuid) from public, anon;
grant execute on function public.cs_ia_puede_actualizar(uuid) to authenticated, service_role;


-- =====================================================================
-- C. Cron + Vault
-- =====================================================================
-- URL de la función en Vault (la clave fin_sync_service_key ya existe, es la misma de las otras).
do $v$
begin
  if to_regclass('vault.decrypted_secrets') is null then
    raise notice '137: Vault no disponible: crear a mano ia_en_que_esta_url (ver comentario al final)';
  elsif not exists (select 1 from vault.decrypted_secrets where name = 'ia_en_que_esta_url') then
    perform vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/ia-en-que-esta',
                                'ia_en_que_esta_url');
  end if;
end
$v$;

create or replace function public.cs_ia_en_que_esta_cron()
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  v_url text;
  v_key text;
begin
  if to_regclass('vault.decrypted_secrets') is null then return 'sin_vault'; end if;
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'ia_en_que_esta_url';
  select s.decrypted_secret into v_key from vault.decrypted_secrets s where s.name = 'fin_sync_service_key';
  if nullif(btrim(v_url), '') is null or nullif(btrim(v_key), '') is null then return 'sin_secretos'; end if;
  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('content-type', 'application/json', 'authorization', 'Bearer ' || v_key),
    body    := '{"lote": true}'::jsonb,
    timeout_milliseconds := 150000);
  return 'enviado';
end;
$fn$;
revoke all on function public.cs_ia_en_que_esta_cron() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'cs_ia_en_que_esta';
select cron.schedule('cs_ia_en_que_esta', '27 13,22 * * *', $cron$ select public.cs_ia_en_que_esta_cron(); $cron$);

-- Humo (se revierte solo): la tabla acepta el contrato y rechaza una app desconocida.
do $humo$
declare v_n int;
begin
  insert into public.ia_uso (app, funcion, modelo, ok) values ('producto', 'humo137', 'humo', true);
  begin
    insert into public.ia_uso (app, funcion, modelo, ok) values ('otra', 'humo137', 'humo', true);
    raise exception 'HUMO 137: dejo pasar una app desconocida';
  exception when check_violation then null;
  end;
  select count(*) into v_n from public.ia_uso_mensual where funcion = 'humo137';
  if v_n <> 1 then raise exception 'HUMO 137: la vista mensual no agrupa (%)', v_n; end if;
  delete from public.ia_uso where funcion = 'humo137';
  raise notice 'HUMO OK: 137';
end
$humo$;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- C1. Tablas y vista creadas (esperado: 3 filas).
--   select table_name from information_schema.tables
--   where table_schema = 'public' and table_name in ('ia_uso', 'ia_uso_mensual', 'cs_en_que_esta') order by 1;
--
-- C2. Permisos (esperado: ia_uso sin insert para authenticated; select sí).
--   select has_table_privilege('authenticated', 'public.ia_uso', 'insert') as ins,
--          has_table_privilege('authenticated', 'public.ia_uso', 'select') as sel,
--          has_table_privilege('authenticated', 'public.cs_en_que_esta', 'insert') as ins_texto,
--          has_function_privilege('authenticated', 'public.cs_ia_en_que_esta_pendientes(int,text)', 'execute') as pend;
--
-- C3. Cron (esperado: 1 fila, schedule '27 13,22 * * *').
--   select jobname, schedule, active from cron.job where jobname = 'cs_ia_en_que_esta';
--
-- C4. Vault (esperado: 2 filas).
--   select name from vault.decrypted_secrets where name in ('ia_en_que_esta_url', 'fin_sync_service_key') order by 1;
--
-- C5. PRIMERA CORRIDA: cuántos alumnos y llamadas (solo lectura; correr como service role / SQL Editor).
--   select * from public.cs_ia_en_que_esta_contar();
--   -- Costo estimado con Haiku 5.5: alumnos * ~0,0011 USD.
--
-- C6. Pendientes ahora (primeros 10).
--   select * from public.cs_ia_en_que_esta_pendientes(10);
--
-- C7. Después de correr la función: textos guardados y de cuántas reuniones salen.
--   select programa_id, count(*) as alumnos, round(avg(jsonb_array_length(reuniones)), 1) as reuniones_prom, max(actualizado_en)
--   from public.cs_en_que_esta group by 1;
--
-- C8. Gasto de IA por mes (fundador).
--   select * from public.ia_uso_mensual order by mes desc, costo_usd desc;
--   select count(*) filter (where not ok) as fallidas, count(*) as total from public.ia_uso where funcion = 'en_que_esta';

-- =====================================================================
-- VUELTA ATRÁS
-- =====================================================================
--   begin;
--   select cron.unschedule(jobid) from cron.job where jobname = 'cs_ia_en_que_esta';
--   drop function if exists public.cs_ia_en_que_esta_cron();
--   drop function if exists public.cs_ia_puede_actualizar(uuid);
--   drop function if exists public.cs_ia_en_que_esta_contar(text);
--   drop function if exists public.cs_ia_en_que_esta_pendientes(int, text);
--   drop table if exists public.cs_en_que_esta;
--   -- ia_uso es compartida con el CRM: NO borrarla si el CRM ya escribe ahí.
--   -- drop view if exists public.ia_uso_mensual; drop table if exists public.ia_uso;
--   commit;
