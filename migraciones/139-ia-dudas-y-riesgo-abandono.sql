-- =====================================================================
-- 139 · IA Fase 2 · (1) dudas frecuentes agrupadas con IA · (2) riesgo de abandono por alumno
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 106 (cs_dudas, cs_v_dudas), 123 (aviso de servicio), 133 (cs_servicio_morosos por vínculo; sirve
--           también con la de la 123), 134 y 135 (cs_duda_candidatas con confianza), 137 (ia_uso, cs_en_que_esta).
-- No toca Fathom, Finanzas, Discord (salvo la sección nueva del aviso de servicio), ni datos existentes.
--
-- Qué hace
--   A. Dudas con IA (Haiku). Las preguntas detectadas en llamadas (cs_duda_candidatas, solo confianza alta y
--      pendientes) las agrupa la Edge Function ia-dudas por tema y deja PROPUESTAS en cs_duda_propuestas:
--      texto de la duda, respuesta corta, "falta recurso" (video / SOP) y a qué duda existente se sumaría.
--      NADA queda como respuesta oficial sin aprobación: recién cs_duda_propuesta_aprobar (fundador o edición del
--      programa) crea / completa la duda en cs_dudas (origen_sugerencia = 'ia') y suma las menciones.
--      Alumnos distintos, semanas y primera / última pregunta se calculan acá (vista cs_v_duda_propuestas),
--      NO los dice el modelo. Corre 1 vez por día (13:47 UTC = 10:47 ART) solo sobre candidatas con ia_visto_at
--      null (nuevas), y a pedido del fundador ("Reagrupar con IA": cs_ia_dudas_reiniciar + la función).
--   B. Riesgo de abandono (Haiku). cs_riesgo_abandono: una fila por alumno vivo con nivel (bajo / medio / alto),
--      motivo en una línea, qué hacer y si es buen momento de pedir referido o testimonio. cs_riesgo_senales()
--      junta las señales (llamadas, accionables vencidos, pagos atrasados, satisfacción, texto de "En qué está")
--      y calcula una huella: la IA solo vuelve a evaluar al alumno si la huella cambió.
--      Cron 11:27 UTC (8:27 ART), ANTES del aviso de servicio de las 9:12 ART.
--      El aviso de servicio (cs_servicio_armar) suma el bloque "Riesgo de abandono" (medio / alto, máx. 10 por
--      canal, una línea c/u; sin nombres si el canal tiene incluir_nombre = false). Se inyecta por replace sobre
--      la definición vigente (sirve con la de la 123 o la de la 130 / 133). Respaldo en cs_bak_139_funciones.
--      Si la IA no corrió o falló, el aviso sale igual: usa lo último guardado y, si no hay nada, sin sección.
--   C. Crons cs_ia_dudas (47 13 * * *) y cs_ia_riesgo (27 11 * * *). URLs en Vault: ia_dudas_url, ia_riesgo_url
--      (la clave es la misma fin_sync_service_key). SIN topes por gasto: todo queda en ia_uso.
--
-- Permisos: propuestas y riesgo los ve quien EDITA el programa (fundador y rol producto / CSM). El rol cliente no.
--
-- Correr en una sola ejecución, evitando los minutos :00, :15, :30, :45 y las 9:00.
-- Después: desplegar ia-dudas e ia-riesgo-abandono (--no-verify-jwt) y ver C1 a C10.
-- =====================================================================

begin;
set local lock_timeout = '8s';

-- Autochequeo de requisitos
do $chk$
declare
  v_falta text;
begin
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_dudas'), ('cs_duda_menciones'), ('cs_duda_candidatas'), ('cs_llamadas'), ('cs_clientes'),
               ('cs_accionables'), ('cs_satisf_envios'), ('cs_servicio_config'), ('cs_en_que_esta'),
               ('ia_uso'), ('cs_discord_canales')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception '139: faltan tablas (106, 123, 134, 137): %', v_falta;
  end if;
  if to_regclass('public.cs_v_dudas') is null or to_regclass('public.cs_v_ultima_llamada') is null then
    raise exception '139: faltan las vistas cs_v_dudas (106) o cs_v_ultima_llamada (102)';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_duda_candidatas' and column_name = 'confianza') then
    raise exception '139: falta la 135 (cs_duda_candidatas.confianza)';
  end if;
  if to_regprocedure('public.cs_servicio_armar(text,date)') is null
     or to_regprocedure('public.cs_servicio_morosos(text,integer,date)') is null
     or to_regprocedure('public.cs_servicio_limpio(text)') is null then
    raise exception '139: falta la 123 (cs_servicio_armar / cs_servicio_morosos / cs_servicio_limpio)';
  end if;
  if to_regprocedure('public.cs_puede_editar(text)') is null or to_regprocedure('public.cs_norm_nombre(text)') is null
     or to_regprocedure('public.es_fundador()') is null then
    raise exception '139: faltan cs_puede_editar / cs_norm_nombre / es_fundador';
  end if;
end
$chk$;

lock table public.cs_duda_candidatas, public.cs_dudas, public.cs_clientes, public.cs_llamadas
  in share row exclusive mode;


-- =====================================================================
-- A. DUDAS CON IA
-- =====================================================================
create table if not exists public.cs_duda_propuestas (
  id                uuid primary key default gen_random_uuid(),
  programa_id       text not null references public.cs_programas(id),
  tema              text not null check (btrim(tema) <> '' and char_length(tema) <= 300),    -- texto propuesto de la duda
  respuesta         text check (respuesta is null or char_length(respuesta) <= 2000),        -- respuesta corta propuesta (NO oficial)
  falta_recurso     boolean not null default false,                                          -- hace falta un video o un SOP
  recurso_sugerido  text check (recurso_sugerido is null or char_length(recurso_sugerido) <= 300),
  duda_id_destino   uuid references public.cs_dudas(id) on delete set null,                  -- duda existente a la que se sumaría
  estado            text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'descartada')),
  duda_id           uuid references public.cs_dudas(id) on delete set null,                  -- duda resultante al aprobar
  origen_sugerencia text not null default 'ia' check (origen_sugerencia = 'ia'),
  modelo            text,
  created_at        timestamptz not null default now(),
  resuelta_at       timestamptz,
  resuelta_por      uuid
);
create index if not exists cs_duda_propuestas_programa_idx on public.cs_duda_propuestas (programa_id, estado);
comment on table public.cs_duda_propuestas is
  '139: propuestas de la IA que agrupan preguntas detectadas en llamadas. Nada es oficial hasta cs_duda_propuesta_aprobar. Escribe solo service role (ia-dudas) y las funciones de aprobar / descartar.';

alter table public.cs_duda_candidatas
  add column if not exists ia_visto_at timestamptz,     -- cuándo la leyó la IA (null = nueva para la IA)
  add column if not exists propuesta_id uuid;           -- propuesta de la IA a la que pertenece
do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'cs_duda_cand_propuesta_fk') then
    alter table public.cs_duda_candidatas
      add constraint cs_duda_cand_propuesta_fk foreign key (propuesta_id)
      references public.cs_duda_propuestas (id) on delete set null;
  end if;
end
$c$;
create index if not exists cs_duda_cand_propuesta_idx on public.cs_duda_candidatas (propuesta_id) where propuesta_id is not null;
create index if not exists cs_duda_cand_ia_nuevas_idx on public.cs_duda_candidatas (programa_id)
  where estado = 'pendiente' and ia_visto_at is null;
comment on column public.cs_duda_candidatas.ia_visto_at is '139: cuándo la leyó ia-dudas; null = todavía no (el cron diario toma solo estas).';
comment on column public.cs_duda_candidatas.propuesta_id is '139: propuesta de la IA que la agrupó.';

alter table public.cs_duda_propuestas enable row level security;
revoke all on table public.cs_duda_propuestas from public, anon, authenticated;
grant select on table public.cs_duda_propuestas to authenticated;
drop policy if exists cs_select on public.cs_duda_propuestas;
create policy cs_select on public.cs_duda_propuestas for select to authenticated
  using (public.cs_puede_editar(programa_id));

-- Alumnos distintos, semanas y primera / última pregunta: calculados de las candidatas, no del modelo.
create or replace view public.cs_v_duda_propuestas
with (security_invoker = on) as
select p.id, p.programa_id, p.tema, p.respuesta, p.falta_recurso, p.recurso_sugerido,
       p.duda_id_destino, dd.texto as duda_destino_texto, dd.respuesta as duda_destino_respuesta,
       p.estado, p.duda_id, p.created_at, p.modelo,
       coalesce(c.alumnos, 0)::int          as alumnos,
       coalesce(c.preguntas, 0)::int        as preguntas,
       c.primera, c.ultima,
       coalesce(c.semanas_distintas, 0)::int as semanas_distintas,
       case when c.primera is null then 0 else greatest(0, (public.cs_hoy() - c.primera) / 7) end::int as semanas_desde
from public.cs_duda_propuestas p
left join public.cs_dudas dd on dd.id = p.duda_id_destino
left join lateral (
  select count(distinct x.cliente_id) as alumnos, count(*) as preguntas,
         min(x.fecha) as primera, max(x.fecha) as ultima,
         count(distinct date_trunc('week', x.fecha::timestamp)) as semanas_distintas
  from public.cs_duda_candidatas x
  where x.propuesta_id = p.id and x.estado <> 'descartada'
) c on true;
revoke all on table public.cs_v_duda_propuestas from public, anon;
revoke insert, update, delete on table public.cs_v_duda_propuestas from authenticated;
grant select on table public.cs_v_duda_propuestas to authenticated;


-- Cuántas candidatas nuevas (para la IA) hay por programa. Solo service role.
create or replace function public.cs_ia_dudas_contar(p_programa text default null)
returns table (programa_id text, candidatas int)
language sql stable security definer set search_path = public
as $fn$
  select c.programa_id, count(*)::int
  from public.cs_duda_candidatas c
  where c.estado = 'pendiente' and c.confianza = 'alta' and c.ia_visto_at is null
    and (p_programa is null or c.programa_id = p_programa)
  group by c.programa_id
$fn$;

-- Lo que lee la IA de un programa: candidatas nuevas, propuestas abiertas y dudas ya cargadas. Solo service role.
create or replace function public.cs_ia_dudas_entrada(p_programa text, p_limite int default 150)
returns jsonb
language sql stable security definer set search_path = public
as $fn$
  select jsonb_build_object(
    'candidatas', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'texto', x.texto, 'fecha', x.fecha, 'alumno', x.cliente_id)
                       order by x.fecha, x.created_at)
      from (select c.id, c.texto, c.fecha, c.cliente_id, c.created_at
            from public.cs_duda_candidatas c
            where c.programa_id = p_programa and c.estado = 'pendiente' and c.confianza = 'alta' and c.ia_visto_at is null
            order by c.fecha, c.created_at
            limit greatest(coalesce(p_limite, 150), 1)) x), '[]'::jsonb),
    'pendientes_total', (select count(*) from public.cs_duda_candidatas c
                         where c.programa_id = p_programa and c.estado = 'pendiente' and c.confianza = 'alta' and c.ia_visto_at is null),
    'propuestas', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'tema', p.tema) order by p.created_at desc)
      from (select q.id, q.tema, q.created_at from public.cs_duda_propuestas q
            where q.programa_id = p_programa and q.estado = 'pendiente'
            order by q.created_at desc limit 60) p), '[]'::jsonb),
    'dudas', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'texto', d.texto, 'con_respuesta', d.respuesta is not null)
                       order by d.alumnos desc, d.texto)
      from (select v.id, v.texto, v.respuesta, v.alumnos from public.cs_v_dudas v
            where v.programa_id = p_programa order by v.alumnos desc, v.texto limit 120) d), '[]'::jsonb)
  )
$fn$;

-- Aplica el resultado de la IA. Atómica. Solo service role.
--   p_grupos: [{tema, candidatas:[uuid], destino_tipo:'nueva'|'propuesta'|'duda', destino_id, respuesta, falta_recurso, recurso}]
--   p_vistas: TODAS las candidatas que se le mostraron al modelo (las que no agrupó también quedan vistas).
create or replace function public.cs_ia_dudas_aplicar(
  p_programa text, p_grupos jsonb, p_vistas uuid[], p_modelo text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  g        jsonb;
  v_ids    uuid[];
  v_tipo   text;
  v_ref    uuid;
  v_tema   text;
  v_prop   uuid;
  v_duda   uuid;
  v_nuevas int := 0;
  v_sumadas int := 0;
  v_vistas int := 0;
begin
  if p_grupos is null or jsonb_typeof(p_grupos) <> 'array' then
    raise exception '139: p_grupos tiene que ser un array' using errcode = '22023';
  end if;

  for g in select * from jsonb_array_elements(p_grupos) loop
    select coalesce(array_agg(c.id), '{}') into v_ids
    from public.cs_duda_candidatas c
    where c.programa_id = p_programa and c.estado = 'pendiente'
      and c.id in (select x::uuid from jsonb_array_elements_text(coalesce(g -> 'candidatas', '[]'::jsonb)) x);
    if cardinality(v_ids) = 0 then continue; end if;

    v_tipo := coalesce(g ->> 'destino_tipo', 'nueva');
    v_ref  := case when (g ->> 'destino_id') ~* '^[0-9a-f-]{36}$' then (g ->> 'destino_id')::uuid end;
    v_tema := left(btrim(coalesce(g ->> 'tema', '')), 300);
    v_prop := null;
    v_duda := null;

    if v_tipo = 'propuesta' and v_ref is not null then
      select q.id into v_prop from public.cs_duda_propuestas q
       where q.id = v_ref and q.programa_id = p_programa and q.estado = 'pendiente';
    elsif v_tipo = 'duda' and v_ref is not null then
      select d.id into v_duda from public.cs_dudas d where d.id = v_ref and d.programa_id = p_programa;
    end if;

    if v_prop is null then
      if v_tema = '' or public.cs_norm_nombre(v_tema) is null then continue; end if;
      if v_duda is null then   -- mismo texto que una duda ya cargada: se suma a esa, no se duplica
        select d.id into v_duda from public.cs_dudas d
         where d.programa_id = p_programa and d.texto_norm = public.cs_norm_nombre(v_tema);
      end if;
      insert into public.cs_duda_propuestas
        (programa_id, tema, respuesta, falta_recurso, recurso_sugerido, duda_id_destino, modelo)
      values (p_programa, v_tema,
              nullif(left(btrim(coalesce(g ->> 'respuesta', '')), 2000), ''),
              coalesce((g ->> 'falta_recurso')::boolean, false),
              nullif(left(btrim(coalesce(g ->> 'recurso', '')), 300), ''),
              v_duda, p_modelo)
      returning id into v_prop;
      v_nuevas := v_nuevas + 1;
    else
      v_sumadas := v_sumadas + 1;
    end if;

    update public.cs_duda_candidatas c
       set propuesta_id = v_prop, origen_sugerencia = 'ia', ia_visto_at = now(),
           texto_sugerido = (select left(q.tema, 300) from public.cs_duda_propuestas q where q.id = v_prop),
           duda_sugerida_id = (select q.duda_id_destino from public.cs_duda_propuestas q where q.id = v_prop)
     where c.id = any (v_ids);
  end loop;

  update public.cs_duda_candidatas c
     set ia_visto_at = now()
   where c.programa_id = p_programa and c.id = any (coalesce(p_vistas, '{}')) and c.ia_visto_at is null;
  get diagnostics v_vistas = row_count;

  return jsonb_build_object('propuestas_nuevas', v_nuevas, 'propuestas_ampliadas', v_sumadas, 'vistas_sin_grupo', v_vistas);
end;
$fn$;

-- "Reagrupar con IA": borra las propuestas PENDIENTES (nada oficial: las aprobadas y descartadas se conservan) y
-- libera sus candidatas para que la IA las lea de nuevo. Solo service role (la función verifica al fundador).
create or replace function public.cs_ia_dudas_reiniciar(p_programa text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prop int;
  v_cand int;
begin
  delete from public.cs_duda_propuestas where programa_id = p_programa and estado = 'pendiente';
  get diagnostics v_prop = row_count;
  update public.cs_duda_candidatas c
     set ia_visto_at = null, propuesta_id = null, duda_sugerida_id = null, texto_sugerido = null,
         origen_sugerencia = 'regla'
   where c.programa_id = p_programa and c.estado = 'pendiente' and c.origen_sugerencia = 'ia';
  get diagnostics v_cand = row_count;
  -- las pendientes que la IA ya había visto sin agrupar también vuelven a entrar
  update public.cs_duda_candidatas c set ia_visto_at = null
   where c.programa_id = p_programa and c.estado = 'pendiente' and c.ia_visto_at is not null;
  return jsonb_build_object('propuestas_borradas', v_prop, 'candidatas_liberadas', v_cand);
end;
$fn$;

-- Aprobar (con o sin edición): crea la duda (o completa la que ya existe), suma las menciones y cierra la propuesta.
create or replace function public.cs_duda_propuesta_aprobar(
  p_id uuid, p_texto text default null, p_respuesta text default null,
  p_recurso_titulo text default null, p_recurso_url text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  p       public.cs_duda_propuestas;
  v_texto text;
  v_norm  text;
  v_duda  uuid;
  v_nueva boolean := false;
  v_resp  text := nullif(btrim(coalesce(p_respuesta, '')), '');
  v_tit   text := nullif(btrim(coalesce(p_recurso_titulo, '')), '');
  v_url   text := nullif(btrim(coalesce(p_recurso_url, '')), '');
  v_m     int;
begin
  select * into p from public.cs_duda_propuestas where id = p_id for update;
  if not found then
    raise exception 'cs: la propuesta ya no existe' using errcode = '22023';
  end if;
  if not public.cs_puede_editar(p.programa_id) then
    raise exception 'cs: sin permiso para aprobar dudas de este programa' using errcode = '42501';
  end if;
  if p.estado <> 'pendiente' then
    raise exception 'cs: esa propuesta ya esta resuelta (%)', p.estado using errcode = '22023';
  end if;
  if v_resp is not null and char_length(v_resp) > 2000 then
    raise exception 'cs: la respuesta no puede pasar de 2000 caracteres' using errcode = '22023';
  end if;
  if v_url is not null and v_url !~* '^https?://[^[:space:]]+$' then
    raise exception 'cs: el link del recurso tiene que empezar con http:// o https://' using errcode = '22023';
  end if;

  v_texto := btrim(coalesce(nullif(btrim(p_texto), ''), p.tema));
  if char_length(v_texto) > 300 then
    raise exception 'cs: la duda no puede pasar de 300 caracteres' using errcode = '22023';
  end if;
  v_norm := public.cs_norm_nombre(v_texto);
  if v_norm is null then
    raise exception 'cs: escribi la duda' using errcode = '22023';
  end if;

  -- 1) la duda destino que propuso la IA, 2) una con el mismo texto, 3) nueva
  if p.duda_id_destino is not null then
    select d.id into v_duda from public.cs_dudas d where d.id = p.duda_id_destino and d.programa_id = p.programa_id;
  end if;
  if v_duda is null then
    select d.id into v_duda from public.cs_dudas d where d.programa_id = p.programa_id and d.texto_norm = v_norm;
  end if;
  if v_duda is null then
    insert into public.cs_dudas (programa_id, texto, respuesta, recurso_titulo, recurso_url, origen, origen_sugerencia)
    values (p.programa_id, v_texto, v_resp, v_tit, v_url, 'llamada', 'ia')
    returning id into v_duda;
    v_nueva := true;
  else
    -- una duda que ya existía: solo se completa lo que le faltaba (no se pisa lo oficial)
    update public.cs_dudas d
       set respuesta      = coalesce(d.respuesta, v_resp),
           recurso_titulo = case when d.recurso_url is null and v_url is not null then v_tit else d.recurso_titulo end,
           recurso_url    = coalesce(d.recurso_url, v_url)
     where d.id = v_duda;
  end if;

  insert into public.cs_duda_menciones (programa_id, duda_id, cliente_id, fecha, origen, llamada_id)
  select c.programa_id, v_duda, c.cliente_id, c.fecha, 'llamada', c.llamada_id
  from public.cs_duda_candidatas c
  where c.propuesta_id = p.id and c.estado = 'pendiente'
  on conflict (duda_id, cliente_id, fecha) do nothing;
  get diagnostics v_m = row_count;

  update public.cs_duda_candidatas c
     set estado = 'agregada', duda_id = v_duda, resuelta_at = now(), resuelta_por = auth.uid()
   where c.propuesta_id = p.id and c.estado = 'pendiente';

  update public.cs_duda_propuestas
     set estado = 'aprobada', duda_id = v_duda, resuelta_at = now(), resuelta_por = auth.uid()
   where id = p.id;

  return jsonb_build_object('duda_id', v_duda, 'nueva', v_nueva, 'menciones', v_m);
end;
$fn$;

-- Descartar: la propuesta se cierra y sus preguntas quedan pendientes en la lista manual (la IA no las vuelve a leer).
create or replace function public.cs_duda_propuesta_descartar(p_id uuid)
returns boolean
language plpgsql security definer set search_path = public
as $fn$
declare
  p public.cs_duda_propuestas;
begin
  select * into p from public.cs_duda_propuestas where id = p_id for update;
  if not found then return false; end if;
  if not public.cs_puede_editar(p.programa_id) then
    raise exception 'cs: sin permiso para descartar dudas de este programa' using errcode = '42501';
  end if;
  if p.estado <> 'pendiente' then return false; end if;
  update public.cs_duda_propuestas
     set estado = 'descartada', resuelta_at = now(), resuelta_por = auth.uid()
   where id = p.id;
  update public.cs_duda_candidatas set propuesta_id = null where propuesta_id = p.id and estado = 'pendiente';
  return true;
end;
$fn$;

revoke all on function public.cs_ia_dudas_contar(text) from public, anon, authenticated;
revoke all on function public.cs_ia_dudas_entrada(text, int) from public, anon, authenticated;
revoke all on function public.cs_ia_dudas_aplicar(text, jsonb, uuid[], text) from public, anon, authenticated;
revoke all on function public.cs_ia_dudas_reiniciar(text) from public, anon, authenticated;
grant execute on function public.cs_ia_dudas_contar(text) to service_role;
grant execute on function public.cs_ia_dudas_entrada(text, int) to service_role;
grant execute on function public.cs_ia_dudas_aplicar(text, jsonb, uuid[], text) to service_role;
grant execute on function public.cs_ia_dudas_reiniciar(text) to service_role;
revoke all on function public.cs_duda_propuesta_aprobar(uuid, text, text, text, text) from public, anon;
revoke all on function public.cs_duda_propuesta_descartar(uuid) from public, anon;
grant execute on function public.cs_duda_propuesta_aprobar(uuid, text, text, text, text) to authenticated;
grant execute on function public.cs_duda_propuesta_descartar(uuid) to authenticated;


-- =====================================================================
-- B. RIESGO DE ABANDONO
-- =====================================================================
create table if not exists public.cs_riesgo_abandono (
  cliente_id          uuid primary key,
  programa_id         text not null references public.cs_programas(id),
  nivel               text not null check (nivel in ('bajo', 'medio', 'alto')),
  motivo              text not null check (btrim(motivo) <> '' and char_length(motivo) <= 300),
  accion              text check (accion is null or char_length(accion) <= 300),
  buen_momento_referido   boolean not null default false,
  buen_momento_testimonio boolean not null default false,
  huella              text not null,                       -- señales con las que se evaluó (si cambian, se reevalúa)
  evaluado_en         timestamptz not null default now(),
  modelo              text not null,
  constraint cs_riesgo_abandono_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_riesgo_abandono_programa_idx on public.cs_riesgo_abandono (programa_id, nivel);
comment on table public.cs_riesgo_abandono is
  '139: riesgo de abandono por alumno armado con IA (Haiku). Escribe solo la Edge Function ia-riesgo-abandono (service role). Lo ven fundador y quien edita el programa.';

alter table public.cs_riesgo_abandono enable row level security;
revoke all on table public.cs_riesgo_abandono from public, anon, authenticated;
grant select on table public.cs_riesgo_abandono to authenticated;
drop policy if exists cs_select on public.cs_riesgo_abandono;
create policy cs_select on public.cs_riesgo_abandono for select to authenticated
  using (public.cs_puede_editar(programa_id));

-- Señales por alumno vivo + huella. Solo service role. p_programa / p_cliente null = todos.
-- Pagos: cs_servicio_morosos(programa, 0): cuotas atrasadas cruzadas con un alumno (por el vínculo de Finanzas
-- si está la 133). Si Finanzas falla, las señales salen igual, sin pagos.
create or replace function public.cs_riesgo_senales(p_programa text default null, p_cliente uuid default null)
returns table (
  cliente_id uuid, programa_id text, nombre text, estado text, fecha_fin date,
  dias_sin_llamada int, accionables_vencidos int, cuotas_atrasadas int, dias_atraso int,
  sat_puntaje int, sat_fecha date, huella text
)
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_hoy date := public.cs_hoy();
  v_mor jsonb := '[]'::jsonb;
begin
  begin
    select coalesce(jsonb_agg(jsonb_build_object('c', m.cliente_id, 'n', m.cuotas, 'd', m.dias_max)), '[]'::jsonb)
      into v_mor
    from (select distinct c0.programa_id as pid
          from public.cs_clientes c0
          where c0.estado in ('onboarding', 'activo', 'en_renovacion')
            and (p_programa is null or c0.programa_id = p_programa)
            and (p_cliente is null or c0.id = p_cliente)) pr
    cross join lateral public.cs_servicio_morosos(pr.pid, 0, v_hoy) m
    where m.cliente_id is not null;
  exception when others then
    v_mor := '[]'::jsonb;
  end;

  return query
  with vivos as (
    select c.id, c.programa_id, c.nombre, c.estado, c.fecha_fin
    from public.cs_clientes c
    where c.estado in ('onboarding', 'activo', 'en_renovacion')
      and (p_programa is null or c.programa_id = p_programa)
      and (p_cliente is null or c.id = p_cliente)
  ), mor as (
    select (x ->> 'c')::uuid as cid, (x ->> 'n')::int as n, (x ->> 'd')::int as d
    from jsonb_array_elements(v_mor) x
  ), base as (
    select v.id, v.programa_id, v.nombre, v.estado, v.fecha_fin,
           case when u.ultima_llamada is null then null else greatest(0, v_hoy - u.ultima_llamada) end as dsl,
           (select count(*) from public.cs_accionables a
             where a.cliente_id = v.id and a.estado <> 'completado' and a.vence < v_hoy)::int as accv,
           coalesce(m.n, 0) as cuotas,
           coalesce(m.d, 0) as datr,
           s.puntaje as sp,
           (s.respondido_at at time zone 'America/Argentina/Buenos_Aires')::date as sf,
           (select count(*) from public.cs_llamadas l
             where l.cliente_id = v.id and nullif(btrim(l.resumen), '') is not null)::int as nres,
           (select max(l.fecha) from public.cs_llamadas l
             where l.cliente_id = v.id and nullif(btrim(l.resumen), '') is not null) as ures,
           e.actualizado_en as eqe
    from vivos v
    left join public.cs_v_ultima_llamada u on u.cliente_id = v.id
    left join mor m on m.cid = v.id
    left join lateral (select e2.puntaje, e2.respondido_at from public.cs_satisf_envios e2
                       where e2.cliente_id = v.id and e2.respondido_at is not null
                       order by e2.respondido_at desc limit 1) s on true
    left join public.cs_en_que_esta e on e.cliente_id = v.id
  )
  select b.id, b.programa_id, b.nombre, b.estado, b.fecha_fin,
         b.dsl, b.accv, b.cuotas, b.datr, b.sp, b.sf,
         md5(concat_ws('|',
           b.estado,
           coalesce(least(b.dsl / 7, 8)::text, 'n'),
           case when b.fecha_fin is null then 'n'
                when b.fecha_fin - v_hoy < 0 then 'v'
                when b.fecha_fin - v_hoy <= 14 then '0'
                when b.fecha_fin - v_hoy <= 30 then '1'
                when b.fecha_fin - v_hoy <= 60 then '2'
                else '3' end,
           b.accv::text, b.cuotas::text, (b.datr / 7)::text,
           coalesce(b.sp::text, 'n'), coalesce(b.sf::text, 'n'),
           b.nres::text, coalesce(b.ures::text, 'n'), coalesce(b.eqe::text, 'n')))
  from base b;
end;
$fn$;

-- Alumnos a evaluar: nunca evaluados o con la huella cambiada. Solo service role.
create or replace function public.cs_ia_riesgo_pendientes(p_limite int default 30, p_programa text default null)
returns table (cliente_id uuid, programa_id text, nombre text)
language sql stable security definer set search_path = public
as $fn$
  select s.cliente_id, s.programa_id, s.nombre
  from public.cs_riesgo_senales(p_programa, null) s
  left join public.cs_riesgo_abandono r on r.cliente_id = s.cliente_id
  where r.cliente_id is null or r.huella <> s.huella
  order by r.evaluado_en nulls first, s.nombre
  limit greatest(coalesce(p_limite, 30), 0)
$fn$;

create or replace function public.cs_ia_riesgo_contar(p_programa text default null)
returns table (programa_id text, alumnos int)
language sql stable security definer set search_path = public
as $fn$
  select s.programa_id, count(*)::int
  from public.cs_riesgo_senales(p_programa, null) s
  left join public.cs_riesgo_abandono r on r.cliente_id = s.cliente_id
  where r.cliente_id is null or r.huella <> s.huella
  group by s.programa_id
$fn$;

-- Botón "Evaluar ahora" de la ficha: fundador o edición del programa del alumno.
create or replace function public.cs_ia_riesgo_puede_evaluar(p_cliente uuid)
returns boolean
language sql stable security definer set search_path = public
as $fn$
  select coalesce(public.es_fundador(), false)
      or exists (select 1 from public.cs_clientes c where c.id = p_cliente and public.cs_puede_editar(c.programa_id))
$fn$;

revoke all on function public.cs_riesgo_senales(text, uuid) from public, anon, authenticated;
revoke all on function public.cs_ia_riesgo_pendientes(int, text) from public, anon, authenticated;
revoke all on function public.cs_ia_riesgo_contar(text) from public, anon, authenticated;
grant execute on function public.cs_riesgo_senales(text, uuid) to service_role;
grant execute on function public.cs_ia_riesgo_pendientes(int, text) to service_role;
grant execute on function public.cs_ia_riesgo_contar(text) to service_role;
revoke all on function public.cs_ia_riesgo_puede_evaluar(uuid) from public, anon;
grant execute on function public.cs_ia_riesgo_puede_evaluar(uuid) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- Aviso de servicio: bloque "Riesgo de abandono"
-- ---------------------------------------------------------------------
create or replace function public.cs_riesgo_limpio(p text, p_max int)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[*_`~|<>@\[\]\\]', '', 'g'), '\s+', ' ', 'g')),
              greatest(coalesce(p_max, 60), 1))
$$;

-- Líneas del bloque para un programa: {n: total medio+alto, lineas: [hasta 10 + una de "y N más"]}.
-- Sin nombres (canal con incluir_nombre = false): solo el conteo. Interna: la llama cs_servicio_armar.
create or replace function public.cs_riesgo_aviso_lineas(p_programa text, p_nombres boolean, p_base text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_n int;
  v_l text[] := '{}';
  r   record;
begin
  select count(*) into v_n
  from public.cs_riesgo_abandono a
  join public.cs_clientes c on c.id = a.cliente_id
  where a.programa_id = p_programa and a.nivel in ('medio', 'alto')
    and c.estado in ('onboarding', 'activo', 'en_renovacion');
  if v_n = 0 then
    return jsonb_build_object('n', 0, 'lineas', '[]'::jsonb);
  end if;
  if coalesce(p_nombres, true) then
    for r in
      select c.id, c.nombre, a.nivel, a.motivo, a.accion
      from public.cs_riesgo_abandono a
      join public.cs_clientes c on c.id = a.cliente_id
      where a.programa_id = p_programa and a.nivel in ('medio', 'alto')
        and c.estado in ('onboarding', 'activo', 'en_renovacion')
      order by (a.nivel = 'alto') desc, a.evaluado_en desc, c.nombre
      limit 10
    loop
      v_l := v_l || ('• [' || public.cs_servicio_limpio(r.nombre) || '](<' || rtrim(coalesce(p_base, ''), '/')
        || '/#/p/' || p_programa || '/c/' || r.id || '>)'
        || ' · ' || case r.nivel when 'alto' then '🔴 alto' else '🟠 medio' end
        || ' · ' || public.cs_riesgo_limpio(r.motivo, 110)
        || case when nullif(btrim(coalesce(r.accion, '')), '') is null then ''
                else ' → ' || public.cs_riesgo_limpio(r.accion, 90) end);
    end loop;
    if v_n > 10 then
      v_l := v_l || ('… y ' || (v_n - 10) || ' más con riesgo medio o alto (ver las fichas).');
    end if;
  end if;
  return jsonb_build_object('n', v_n, 'lineas', to_jsonb(v_l));
end;
$fn$;
revoke all on function public.cs_riesgo_limpio(text, int) from public, anon, authenticated;
revoke all on function public.cs_riesgo_aviso_lineas(text, boolean, text) from public, anon, authenticated;

-- Respaldo de la función vigente (una sola vez) e inyección por replace en tres puntos fijos.
create table if not exists public.cs_bak_139_funciones (
  nombre     text primary key,
  definicion text not null,
  guardado   timestamptz not null default now()
);
revoke all on table public.cs_bak_139_funciones from public, anon, authenticated;

do $inj$
declare
  v_def text;
  v_new text;
  a1 constant text := E'  v_lineas  text[] := ''{}'';';
  a2 constant text := E'  if v_total = 0 then';
  a3 constant text := E'  -- partido en mensajes de hasta';
  v_n  int;
begin
  v_def := pg_get_functiondef('public.cs_servicio_armar(text,date)'::regprocedure);
  if position('Riesgo de abandono' in v_def) > 0 then
    raise notice '139: cs_servicio_armar ya tiene el bloque Riesgo de abandono (no se toca)';
    return;
  end if;

  insert into public.cs_bak_139_funciones (nombre, definicion)
  values ('cs_servicio_armar(text,date)', v_def)
  on conflict (nombre) do nothing;

  foreach v_n in array array[1, 2, 3] loop
    if (length(v_def) - length(replace(v_def, case v_n when 1 then a1 when 2 then a2 else a3 end, '')))
       / length(case v_n when 1 then a1 when 2 then a2 else a3 end) <> 1 then
      raise exception '139: no encuentro exactamente una vez el punto de anclaje % en cs_servicio_armar: no se modifica nada', v_n;
    end if;
  end loop;

  v_new := replace(v_def, a1, a1 || E'\n  l_riesgo  text[] := ''{}'';  n_riesgo int := 0;   -- 139');
  v_new := replace(v_new, a2,
    E'  -- 139: riesgo de abandono (IA). Si falla o no hay datos, el aviso sale igual sin esta sección.\n'
    || E'  begin\n'
    || E'    select coalesce((j ->> ''n'')::int, 0), coalesce(array(select jsonb_array_elements_text(j -> ''lineas'')), ''{}'')\n'
    || E'      into n_riesgo, l_riesgo\n'
    || E'    from (select public.cs_riesgo_aviso_lineas(p_programa, v_nom, v_base) as j) x;\n'
    || E'  exception when others then\n'
    || E'    n_riesgo := 0; l_riesgo := ''{}'';\n'
    || E'  end;\n'
    || E'  v_total := v_total + n_riesgo;\n\n'
    || a2);
  v_new := replace(v_new, a3,
    E'  if n_riesgo > 0 then\n'
    || E'    v_lineas := v_lineas || (chr(1) || ''🚨 **Riesgo de abandono** ('' || n_riesgo || '')'') || l_riesgo;\n'
    || E'  end if;\n\n'
    || a3);

  execute v_new;
  raise notice '139: cs_servicio_armar actualizada con el bloque Riesgo de abandono';
end
$inj$;


-- =====================================================================
-- C. CRONES + VAULT
-- =====================================================================
do $v$
begin
  if to_regclass('vault.decrypted_secrets') is null then
    raise notice '139: Vault no disponible: crear a mano ia_dudas_url e ia_riesgo_url (ver comentario al final)';
  else
    if not exists (select 1 from vault.decrypted_secrets where name = 'ia_dudas_url') then
      perform vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/ia-dudas', 'ia_dudas_url');
    end if;
    if not exists (select 1 from vault.decrypted_secrets where name = 'ia_riesgo_url') then
      perform vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/ia-riesgo-abandono', 'ia_riesgo_url');
    end if;
  end if;
end
$v$;

create or replace function public.cs_ia_dudas_cron()
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  v_url text;
  v_key text;
begin
  if to_regclass('vault.decrypted_secrets') is null then return 'sin_vault'; end if;
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'ia_dudas_url';
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
revoke all on function public.cs_ia_dudas_cron() from public, anon, authenticated;

create or replace function public.cs_ia_riesgo_cron()
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  v_url text;
  v_key text;
begin
  if to_regclass('vault.decrypted_secrets') is null then return 'sin_vault'; end if;
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'ia_riesgo_url';
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
revoke all on function public.cs_ia_riesgo_cron() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname in ('cs_ia_dudas', 'cs_ia_riesgo');
select cron.schedule('cs_ia_dudas',  '47 13 * * *', $cron$ select public.cs_ia_dudas_cron(); $cron$);    -- 10:47 ART
select cron.schedule('cs_ia_riesgo', '27 11 * * *', $cron$ select public.cs_ia_riesgo_cron(); $cron$);   -- 8:27 ART, antes del aviso (9:12)


-- =====================================================================
-- HUMO (se revierte solo: lo que escribe lo borra al final)
-- =====================================================================
do $humo$
declare
  v_prog text;
  v_cli  uuid;
  v_j    jsonb;
  v_txt  jsonb;
  v_n    int;
begin
  -- A. La vista de propuestas cuenta bien y el gate de permisos funciona sin sesión.
  select p.id into v_prog from public.cs_programas p order by p.id limit 1;
  if v_prog is not null then
    insert into public.cs_duda_propuestas (programa_id, tema) values (v_prog, 'Humo 139: como subo un reel');
    select count(*) into v_n from public.cs_v_duda_propuestas where tema = 'Humo 139: como subo un reel' and alumnos = 0;
    if v_n <> 1 then raise exception 'HUMO 139: la vista de propuestas no devuelve la fila (%)', v_n; end if;
    begin
      perform public.cs_duda_propuesta_descartar((select id from public.cs_duda_propuestas where tema = 'Humo 139: como subo un reel'));
      raise exception 'HUMO 139: descartar dejo pasar a alguien sin permiso';
    exception when sqlstate '42501' then null;
    end;
    v_j := public.cs_ia_dudas_aplicar(v_prog, '[]'::jsonb, '{}', 'humo');
    if (v_j ->> 'propuestas_nuevas')::int <> 0 then raise exception 'HUMO 139: aplicar con grupos vacios creo propuestas'; end if;
    delete from public.cs_duda_propuestas where tema = 'Humo 139: como subo un reel';
    v_j := public.cs_ia_dudas_entrada(v_prog);
    if jsonb_typeof(v_j -> 'candidatas') <> 'array' or jsonb_typeof(v_j -> 'dudas') <> 'array' then
      raise exception 'HUMO 139: cs_ia_dudas_entrada no devuelve arrays';
    end if;
  end if;

  -- B. Señales, pendientes y el bloque del aviso.
  select count(*) into v_n from public.cs_riesgo_senales(null, null);
  select c.id, c.programa_id into v_cli, v_prog
  from public.cs_clientes c where c.estado in ('onboarding', 'activo', 'en_renovacion')
    and not exists (select 1 from public.cs_riesgo_abandono r0 where r0.cliente_id = c.id)
  order by c.id limit 1;
  if v_cli is not null then
    insert into public.cs_riesgo_abandono (cliente_id, programa_id, nivel, motivo, accion, huella, modelo)
    values (v_cli, v_prog, 'alto', 'Humo 139: sin llamadas y con cuotas atrasadas', 'Llamarlo hoy', 'humo', 'humo');
    v_j := public.cs_riesgo_aviso_lineas(v_prog, true, 'https://producto.dystopia.com.ar');
    if (v_j ->> 'n')::int < 1 or jsonb_array_length(v_j -> 'lineas') < 1 then
      raise exception 'HUMO 139: el bloque del aviso no trae la linea';
    end if;
    if position('Humo 139' in (v_j -> 'lineas' ->> 0)) = 0 and (v_j ->> 'n')::int = 1 then
      raise exception 'HUMO 139: la linea del aviso no tiene el motivo';
    end if;
    v_j := public.cs_riesgo_aviso_lineas(v_prog, false, 'https://producto.dystopia.com.ar');
    if jsonb_array_length(v_j -> 'lineas') <> 0 then
      raise exception 'HUMO 139: con incluir_nombre = false no puede haber lineas con nombres';
    end if;
    -- el aviso completo compila y corre con la inyeccion
    v_txt := public.cs_servicio_armar(v_prog);
    if jsonb_typeof(v_txt -> 'partes') <> 'array' then raise exception 'HUMO 139: cs_servicio_armar no devuelve partes'; end if;
    if position('Riesgo de abandono' in (v_txt ->> 'partes')) = 0 then
      raise exception 'HUMO 139: el aviso no muestra la seccion Riesgo de abandono';
    end if;
    delete from public.cs_riesgo_abandono where cliente_id = v_cli and huella = 'humo';
  end if;
  raise notice 'HUMO OK: 139';
end
$humo$;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- C1. Objetos creados (esperado: cs_duda_propuestas, cs_riesgo_abandono, cs_v_duda_propuestas, cs_bak_139_funciones).
--   select table_name from information_schema.tables where table_schema = 'public'
--     and table_name in ('cs_duda_propuestas', 'cs_riesgo_abandono', 'cs_v_duda_propuestas', 'cs_bak_139_funciones') order by 1;
--
-- C2. Columnas nuevas en candidatas (esperado: 2 filas).
--   select column_name from information_schema.columns where table_name = 'cs_duda_candidatas'
--     and column_name in ('ia_visto_at', 'propuesta_id');
--
-- C3. Permisos (esperado: false, true, false, true).
--   select has_table_privilege('authenticated', 'public.cs_duda_propuestas', 'insert') as ins_prop,
--          has_table_privilege('authenticated', 'public.cs_riesgo_abandono', 'select') as sel_riesgo,
--          has_function_privilege('authenticated', 'public.cs_ia_dudas_aplicar(text,jsonb,uuid[],text)', 'execute') as aplicar,
--          has_function_privilege('authenticated', 'public.cs_duda_propuesta_aprobar(uuid,text,text,text,text)', 'execute') as aprobar;
--
-- C4. Crons (esperado: 2 filas, '47 13 * * *' y '27 11 * * *').
--   select jobname, schedule, active from cron.job where jobname in ('cs_ia_dudas', 'cs_ia_riesgo') order by 1;
--
-- C5. Vault (esperado: 3 filas).
--   select name from vault.decrypted_secrets where name in ('ia_dudas_url', 'ia_riesgo_url', 'fin_sync_service_key') order by 1;
--
-- C6. El aviso tiene el bloque nuevo (esperado: true) y el respaldo existe (esperado: 1).
--   select position('Riesgo de abandono' in pg_get_functiondef('public.cs_servicio_armar(text,date)'::regprocedure)) > 0 as tiene_bloque;
--   select count(*) from public.cs_bak_139_funciones;
--
-- C7. PRIMERA CORRIDA, dudas: cuántas candidatas nuevas (alta confianza) hay por programa (~37 en total entre todas).
--   select * from public.cs_ia_dudas_contar();
--
-- C8. PRIMERA CORRIDA, riesgo: cuántos alumnos se evaluarían (todos los vivos la primera vez; ~133 en liam).
--   select * from public.cs_ia_riesgo_contar();
--   select * from public.cs_ia_riesgo_pendientes(10);
--
-- C9. Después de correr las funciones: propuestas por estado y riesgo por nivel.
--   select programa_id, estado, count(*) from public.cs_duda_propuestas group by 1, 2 order by 1, 2;
--   select programa_id, nivel, count(*) from public.cs_riesgo_abandono group by 1, 2 order by 1, 2;
--
-- C10. Gasto de IA por función (fundador): esperado dudas, riesgo y en_que_esta.
--   select * from public.ia_uso_mensual where app = 'producto' order by mes desc, costo_usd desc;
--
-- C11. Vista previa del aviso con el bloque (no manda nada a Discord; cambiar 'liam').
--   select jsonb_pretty(public.cs_servicio_armar('liam'));

-- =====================================================================
-- VUELTA ATRÁS
-- =====================================================================
--   begin;
--   select cron.unschedule(jobid) from cron.job where jobname in ('cs_ia_dudas', 'cs_ia_riesgo');
--   -- restaura el aviso de servicio como estaba antes de la 139
--   do $r$ declare v text; begin
--     select definicion into v from public.cs_bak_139_funciones where nombre = 'cs_servicio_armar(text,date)';
--     if v is not null then execute v; end if;
--   end $r$;
--   drop function if exists public.cs_riesgo_aviso_lineas(text, boolean, text);
--   drop function if exists public.cs_riesgo_limpio(text, int);
--   drop function if exists public.cs_ia_riesgo_cron();
--   drop function if exists public.cs_ia_dudas_cron();
--   drop function if exists public.cs_ia_riesgo_puede_evaluar(uuid);
--   drop function if exists public.cs_ia_riesgo_contar(text);
--   drop function if exists public.cs_ia_riesgo_pendientes(int, text);
--   drop function if exists public.cs_riesgo_senales(text, uuid);
--   drop table if exists public.cs_riesgo_abandono;
--   drop function if exists public.cs_duda_propuesta_descartar(uuid);
--   drop function if exists public.cs_duda_propuesta_aprobar(uuid, text, text, text, text);
--   drop function if exists public.cs_ia_dudas_reiniciar(text);
--   drop function if exists public.cs_ia_dudas_aplicar(text, jsonb, uuid[], text);
--   drop function if exists public.cs_ia_dudas_entrada(text, int);
--   drop function if exists public.cs_ia_dudas_contar(text);
--   drop view if exists public.cs_v_duda_propuestas;
--   alter table public.cs_duda_candidatas drop constraint if exists cs_duda_cand_propuesta_fk;
--   alter table public.cs_duda_candidatas drop column if exists propuesta_id, drop column if exists ia_visto_at;
--   drop table if exists public.cs_duda_propuestas;
--   drop table if exists public.cs_bak_139_funciones;
--   -- las dudas que ya se aprobaron (cs_dudas.origen_sugerencia = 'ia') quedan: son oficiales.
--   -- Los secretos de Vault ia_dudas_url / ia_riesgo_url se pueden dejar.
--   commit;
