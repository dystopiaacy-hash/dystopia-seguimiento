-- =====================================================================
-- 192 · Fathom: nombres de los hablantes de cada llamada (para que la IA encuentre al alumno)
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 122 y 127 (cs_fathom_sin_asignar, cs_fathom_consultores, cs_norm_nombre).
--
-- Qué hace
--   A. cs_fathom_sin_asignar.hablantes text[] (default '{}'): nombres de quienes hablan en la
--      transcripción, únicos, sin el consultor de la llamada. Misma tabla y misma RLS que el resto de
--      la llamada pendiente (privacidad por programa de la 187 intacta: no se agregan políticas).
--   B. cs_fathom_hablantes_guardar(p jsonb): SOLO service_role. {externo_id, hablantes[], solo_vacias}.
--      Escribe únicamente la columna hablantes de la fila de esa llamada. NUNCA toca estado,
--      clasificación, cliente, llamada ni propuestas, así que no pisa nada confirmado por una persona.
--      La usa fathom-sync para las llamadas nuevas.
--   C. cs_fathom_hablantes_backfill(p_despues uuid, p_limite int): SOLO service_role. Completa hablantes
--      de las llamadas ya sincronizadas leyendo la transcripción guardada (líneas "[hh:mm:ss] Nombre: texto"),
--      sin volver a llamar a Fathom. Solo filas con hablantes vacío, por orden de id, de a p_limite
--      (tope 500), devuelve el último id para seguir ("reanudable"). La dispara fathom-sync con
--      {"accion":"backfill_hablantes"}. No crea ni duplica llamadas.
--
-- No cambia nada del front ni de cs_llamadas. Correr en una sola ejecución, evitando los minutos
-- :00, :15, :30 y :45 y las 9:00. Después: desplegar fathom-sync e ia-fathom-clasificar y controles C1 a C5.
-- =====================================================================

begin;
set local lock_timeout = '8s';

do $chk$
begin
  if to_regclass('public.cs_fathom_sin_asignar') is null or to_regclass('public.cs_fathom_consultores') is null then
    raise exception '192: faltan la 122 / 124 (cs_fathom_sin_asignar / cs_fathom_consultores)';
  end if;
  if to_regprocedure('public.cs_norm_nombre(text)') is null then
    raise exception '192: falta cs_norm_nombre(text) (070)';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'cs_fathom_sin_asignar' and column_name = 'hablantes') then
    raise exception '192: ya fue corrida (existe cs_fathom_sin_asignar.hablantes)';
  end if;
end
$chk$;

lock table public.cs_fathom_sin_asignar in share row exclusive mode;

-- A.
alter table public.cs_fathom_sin_asignar add column hablantes text[] not null default '{}';
comment on column public.cs_fathom_sin_asignar.hablantes is
  '192: nombres de los hablantes de la transcripción (únicos, sin el consultor). Los usa ia-fathom-clasificar para encontrar al alumno.';

-- B.
create or replace function public.cs_fathom_hablantes_guardar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ext  text := nullif(btrim(p->>'externo_id'), '');
  v_hab  text[];
  v_n    int := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role' and coalesce(current_user, '') not in ('postgres', 'supabase_admin') then
    raise exception 'cs_fathom_hablantes_guardar: solo service_role' using errcode = '42501';
  end if;
  if v_ext is null then
    return jsonb_build_object('actualizadas', 0);
  end if;
  select coalesce(array_agg(x order by o), '{}'::text[]) into v_hab
  from (select left(btrim(e), 80) as x, min(o) as o
        from jsonb_array_elements_text(case when jsonb_typeof(p->'hablantes') = 'array' then p->'hablantes' else '[]'::jsonb end)
             with ordinality as t(e, o)
        where btrim(e) <> '' and btrim(e) <> '?'
        group by left(btrim(e), 80)
        order by min(o) limit 20) s;
  update public.cs_fathom_sin_asignar
     set hablantes = v_hab
   where externo_id = v_ext
     and hablantes is distinct from v_hab
     and (coalesce((p->>'solo_vacias')::boolean, false) = false or hablantes = '{}'::text[]);
  get diagnostics v_n = row_count;
  return jsonb_build_object('actualizadas', v_n);
end
$$;

-- C.
create or replace function public.cs_fathom_hablantes_backfill(p_despues uuid default null, p_limite int default 200)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lim     int := least(greatest(coalesce(p_limite, 200), 1), 500);
  v_ids     uuid[];
  v_ultimo  uuid;
  v_proc    int := 0;
  v_con     int := 0;
  v_quedan  int := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role' and coalesce(current_user, '') not in ('postgres', 'supabase_admin') then
    raise exception 'cs_fathom_hablantes_backfill: solo service_role' using errcode = '42501';
  end if;

  select array_agg(id order by id) into v_ids
  from (select id from public.cs_fathom_sin_asignar
        where hablantes = '{}'::text[] and transcripcion is not null
          and (p_despues is null or id > p_despues)
        order by id limit v_lim) s;
  v_proc := coalesce(cardinality(v_ids), 0);

  if v_proc > 0 then
    v_ultimo := v_ids[v_proc];
    -- Hablantes de cada transcripción: primer orden de aparición, únicos, sin '?' y sin el consultor
    -- (todas las palabras del hablante están en el nombre de la cuenta del consultor).
    with filas as (
      select s.id, s.consultor, s.transcripcion
      from public.cs_fathom_sin_asignar s where s.id = any (v_ids)
    ),
    nombres as (
      select f.id, f.consultor, t.g[1] as nombre, min(t.ord) as ord
      from filas f
      cross join lateral regexp_matches(f.transcripcion, '^\[[^\]]*\] ([^:\n]{1,80}): ', 'gn') with ordinality as t(g, ord)
      group by f.id, f.consultor, t.g[1]
    ),
    propios as (
      select c.id as consultor, string_to_array(public.cs_norm_nombre(c.nombre), ' ') as toks
      from public.cs_fathom_consultores c
    ),
    buenos as (
      select n.id, btrim(n.nombre) as nombre, n.ord
      from nombres n
      left join propios p on p.consultor = n.consultor
      where btrim(n.nombre) not in ('', '?')
        and not (p.toks is not null
                 and public.cs_norm_nombre(n.nombre) is not null
                 and string_to_array(public.cs_norm_nombre(n.nombre), ' ') <@ p.toks)
    ),
    agrupados as (
      select id, (array_agg(nombre order by ord))[1:20] as hab
      from (select id, nombre, min(ord) as ord from buenos group by id, nombre) u
      group by id
    )
    update public.cs_fathom_sin_asignar s
       set hablantes = a.hab
      from agrupados a
     where s.id = a.id and s.hablantes = '{}'::text[];
    get diagnostics v_con = row_count;
  end if;

  select count(*) into v_quedan
  from public.cs_fathom_sin_asignar
  where hablantes = '{}'::text[] and transcripcion is not null
    and (coalesce(v_ultimo, p_despues) is null or id > coalesce(v_ultimo, p_despues));

  return jsonb_build_object('procesadas', v_proc, 'con_hablantes', v_con, 'ultimo_id', v_ultimo, 'quedan_por_revisar', v_quedan);
end
$$;

revoke all on function public.cs_fathom_hablantes_guardar(jsonb) from public, anon, authenticated;
revoke all on function public.cs_fathom_hablantes_backfill(uuid, int) from public, anon, authenticated;
grant execute on function public.cs_fathom_hablantes_guardar(jsonb) to service_role;
grant execute on function public.cs_fathom_hablantes_backfill(uuid, int) to service_role;

-- Humo (se revierte solo con el rollback del bloque): la regex saca los hablantes de un texto de ejemplo.
do $humo$
declare v_txt text := E'[00:00:01] Ana Gomez: hola\n[00:00:05] Joaco Fernandez: buenas\n[00:01:00] Ana Gomez: ok\n[00:01:10] ?: eco';
        v_n int;
begin
  select count(distinct t.g[1]) into v_n from regexp_matches(v_txt, '^\[[^\]]*\] ([^:\n]{1,80}): ', 'gn') as t(g);
  if v_n <> 3 then raise exception '192 humo: la regex devolvio % hablantes (esperado 3: Ana, Joaco, ?)', v_n; end if;
end
$humo$;

commit;

-- =====================================================================
-- CONTROLES (de a uno, después del commit)
-- =====================================================================
-- C1. La columna existe. Esperado: 1 fila, text[] / '{}'.
--   select column_name, data_type, column_default from information_schema.columns
--   where table_schema = 'public' and table_name = 'cs_fathom_sin_asignar' and column_name = 'hablantes';
--
-- C2. Funciones solo para service_role. Esperado: ambas con anon=false, authenticated=false, service_role=true.
--   select p.proname,
--          has_function_privilege('anon', p.oid, 'execute') as anon,
--          has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--          has_function_privilege('service_role', p.oid, 'execute') as service_role
--   from pg_proc p where p.pronamespace = 'public'::regnamespace
--     and p.proname in ('cs_fathom_hablantes_guardar', 'cs_fathom_hablantes_backfill');
--
-- C3. Después del backfill (todas las rondas). Cobertura de hablantes por estado.
--   select estado, count(*) as llamadas, count(*) filter (where cardinality(hablantes) > 0) as con_hablantes,
--          count(*) filter (where transcripcion is null) as sin_transcripcion
--   from public.cs_fathom_sin_asignar group by estado order by estado;
--
-- C4. Las pendientes: cuántos hablantes tienen (sin nombres, solo conteos).
--   select cardinality(hablantes) as n_hablantes, count(*) from public.cs_fathom_sin_asignar
--   where estado = 'pendiente' group by 1 order by 1;
--
-- C5. Nada confirmado se movió: las propuestas decididas y los estados siguen igual (comparar con antes).
--   select estado, count(*) from public.cs_fathom_propuestas group by estado order by estado;
--   select estado, count(*) from public.cs_fathom_sin_asignar group by estado order by estado;
--
-- VUELTA ATRÁS (comentada)
--   drop function if exists public.cs_fathom_hablantes_guardar(jsonb);
--   drop function if exists public.cs_fathom_hablantes_backfill(uuid, int);
--   alter table public.cs_fathom_sin_asignar drop column if exists hablantes;
