-- =====================================================================
-- 186 · Fathom: propuestas de la IA para las llamadas "sin asignar" (tipo + alumno)
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 122 y 124 (cs_fathom_sin_asignar, cs_fathom_config, cs_fathom_ve_privadas),
--           126 y 127 (cs_fathom_asignar, cs_fathom_marcar_no_alumno, cs_fathom_puede_asignar_llamada),
--           137 (ia_uso). No toca fathom-sync, cs_llamadas ni cs_fathom_sin_asignar.
--
-- Qué hace
--   A. cs_fathom_propuestas: UNA propuesta por llamada sin asignar (unique llamada_id): tipo
--      (consultoria_1a1 | clase_grupal | venta | interna | otra), alumno propuesto, confianza
--      (alta | media | baja), motivo (1 línea), origen (mail | ia), estado (pendiente | aceptada |
--      corregida | descartada), lo que se decidió (tipo_final, alumno_final), quién y cuándo, modelo y costo.
--      Lee: quien hoy ve las llamadas pendientes (cs_fathom_ve_privadas: fundador y cliente de un programa
--      habilitado). Escribe la IA con service_role. Nadie escribe desde el front: se decide por las funciones.
--   B. cs_fathom_prop_resolver(propuesta, accion, alumno, tipo): aceptar | corregir | descartar.
--      Aceptar / corregir llaman a la MISMA función que la asignación manual: cs_fathom_asignar(llamada, alumno)
--      si hay alumno, o cs_fathom_marcar_no_alumno(llamada) si no hay. Los permisos los valida esa función
--      (el uid del usuario llega intacto). Todo en una transacción: o se asigna y se marca, o nada.
--   C. cs_fathom_prop_aceptar_altas(limite): "Aceptar todas las de confianza alta". Solo propuestas con alumno,
--      confianza alta y tipo consultoria_1a1; cada una en su subtransacción (si una falla, sigue con las demás).
--   D. cs_fathom_config.ia_clasificar_auto (boolean, default false): flag APAGADO. Lo leerá fathom-sync en el
--      futuro para disparar la clasificación de lo nuevo. Nada lo lee hoy: no cambia ningún comportamiento.
--
-- Correr en una sola ejecución, evitando los minutos :00, :15, :30 y :45 y las 9:00.
-- Después: desplegar ia-fathom-clasificar (supabase functions deploy ia-fathom-clasificar --no-verify-jwt), controles C1 a C8.
-- =====================================================================

begin;
set local lock_timeout = '8s';

do $chk$
declare v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values ('cs_fathom_ve_privadas()'), ('cs_fathom_asignar(uuid, uuid)'), ('cs_fathom_marcar_no_alumno(uuid)'),
               ('cs_fathom_puede_asignar_llamada(text, text)'), ('cs_tg_updated_at()')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception '186: faltan funciones de la 122 a 127: %', v_falta;
  end if;
  if to_regclass('public.cs_fathom_sin_asignar') is null or to_regclass('public.cs_fathom_config') is null then
    raise exception '186: falta la 122 (cs_fathom_sin_asignar / cs_fathom_config)';
  end if;
  if to_regclass('public.ia_uso') is null then
    raise exception '186: falta la 137 (ia_uso)';
  end if;
  if to_regclass('public.cs_fathom_propuestas') is not null then
    raise exception '186: ya fue corrida (existe cs_fathom_propuestas)';
  end if;
end
$chk$;

lock table public.cs_fathom_sin_asignar, public.cs_fathom_config, public.cs_clientes in share row exclusive mode;


-- =====================================================================
-- A. cs_fathom_propuestas
-- =====================================================================
create table public.cs_fathom_propuestas (
  id            uuid primary key default gen_random_uuid(),
  llamada_id    uuid not null unique references public.cs_fathom_sin_asignar(id) on delete cascade,
  tipo          text not null check (tipo in ('consultoria_1a1', 'clase_grupal', 'venta', 'interna', 'otra')),
  alumno_id     uuid references public.cs_clientes(id) on delete set null,
  confianza     text not null check (confianza in ('alta', 'media', 'baja')),
  motivo        text not null default '' check (char_length(motivo) <= 300),
  origen        text not null default 'ia' check (origen in ('mail', 'ia')),
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'aceptada', 'corregida', 'descartada')),
  tipo_final    text check (tipo_final is null or tipo_final in ('consultoria_1a1', 'clase_grupal', 'venta', 'interna', 'otra')),
  alumno_final  uuid references public.cs_clientes(id) on delete set null,
  resuelta_por  uuid,
  resuelta_at   timestamptz,
  modelo        text,
  costo_usd     numeric(10,6),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint cs_fathom_propuestas_resuelta_chk check ((estado = 'pendiente') = (resuelta_at is null))
);
create index cs_fathom_propuestas_estado_idx on public.cs_fathom_propuestas (estado, confianza);
create index cs_fathom_propuestas_alumno_idx on public.cs_fathom_propuestas (alumno_id) where alumno_id is not null;
comment on table public.cs_fathom_propuestas is
  '186: propuestas de la IA (tipo + alumno) para llamadas de cs_fathom_sin_asignar. Nada se asigna solo: una persona acepta, corrige o descarta (cs_fathom_prop_resolver). Escribe solo service_role.';

create trigger cs_fathom_propuestas_updated_at before update on public.cs_fathom_propuestas
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_fathom_propuestas enable row level security;
revoke all on table public.cs_fathom_propuestas from public, anon, authenticated;
grant select on table public.cs_fathom_propuestas to authenticated;
grant select, insert, update, delete on table public.cs_fathom_propuestas to service_role;
create policy cs_prop_select on public.cs_fathom_propuestas for select to authenticated
  using (public.cs_fathom_ve_privadas());
-- Sin políticas de escritura: se decide por cs_fathom_prop_resolver / cs_fathom_prop_aceptar_altas.
-- (La PK es uuid: no hay secuencias que revocar.)


-- =====================================================================
-- B. Resolver una propuesta
-- =====================================================================
create or replace function public.cs_fathom_prop_resolver(
  p_prop uuid, p_accion text, p_cliente uuid default null, p_tipo text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_p       public.cs_fathom_propuestas%rowtype;
  v_est     text;
  v_cliente uuid;
  v_tipo    text;
  v_res     jsonb := '{}'::jsonb;
  v_nuevo   text;
begin
  if not coalesce(public.cs_fathom_ve_privadas(), false) then
    raise exception 'cs: no tenes permiso para decidir propuestas de llamadas' using errcode = '42501';
  end if;
  if p_accion not in ('aceptar', 'corregir', 'descartar') then
    raise exception 'cs: accion invalida (aceptar | corregir | descartar)' using errcode = '22023';
  end if;
  select * into v_p from public.cs_fathom_propuestas where id = p_prop for update;
  if not found then
    raise exception 'cs: la propuesta no existe' using errcode = '22023';
  end if;
  if v_p.estado <> 'pendiente' then
    raise exception 'cs: la propuesta ya fue resuelta' using errcode = '22023';
  end if;
  if p_tipo is not null and p_tipo not in ('consultoria_1a1', 'clase_grupal', 'venta', 'interna', 'otra') then
    raise exception 'cs: tipo invalido' using errcode = '22023';
  end if;

  if p_accion = 'descartar' then
    update public.cs_fathom_propuestas
    set estado = 'descartada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = v_p.id;
    return jsonb_build_object('resultado', 'descartada');
  end if;

  if p_accion = 'aceptar' then
    v_cliente := v_p.alumno_id;
    v_tipo := v_p.tipo;
    v_nuevo := 'aceptada';
  else
    v_cliente := p_cliente;
    v_tipo := coalesce(p_tipo, v_p.tipo);
    v_nuevo := 'corregida';
  end if;

  select s.estado into v_est from public.cs_fathom_sin_asignar s where s.id = v_p.llamada_id for update;
  if not found or v_est not in ('pendiente', 'interna') then
    -- Alguien ya la resolvió a mano: la propuesta deja de tener sentido.
    update public.cs_fathom_propuestas
    set estado = 'descartada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = v_p.id;
    return jsonb_build_object('resultado', 'llamada_ya_resuelta');
  end if;

  if v_cliente is not null then
    -- Mismo camino que la asignación manual (valida permiso, aprende mails y alias, crea la llamada en la ficha).
    v_res := public.cs_fathom_asignar(v_p.llamada_id, v_cliente);
  elsif v_tipo = 'consultoria_1a1' then
    raise exception 'cs: una consultoria 1 a 1 necesita alumno: elegilo para corregir' using errcode = '22023';
  else
    perform public.cs_fathom_marcar_no_alumno(v_p.llamada_id);
    v_res := jsonb_build_object('resultado', 'no_alumno');
  end if;

  update public.cs_fathom_propuestas
  set estado = v_nuevo, tipo_final = v_tipo, alumno_final = v_cliente,
      resuelta_por = auth.uid(), resuelta_at = now()
  where id = v_p.id;
  return coalesce(v_res, '{}'::jsonb);
end;
$fn$;
revoke all on function public.cs_fathom_prop_resolver(uuid, text, uuid, text) from public, anon;
grant execute on function public.cs_fathom_prop_resolver(uuid, text, uuid, text) to authenticated;


-- =====================================================================
-- C. Aceptar todas las de confianza alta (solo con alumno)
-- =====================================================================
create or replace function public.cs_fathom_prop_aceptar_altas(p_limite int default 100)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  r        record;
  v_ok     int := 0;
  v_fallo  int := 0;
  v_errs   jsonb := '[]'::jsonb;
  v_quedan int;
begin
  if not coalesce(public.cs_fathom_ve_privadas(), false) then
    raise exception 'cs: no tenes permiso para decidir propuestas de llamadas' using errcode = '42501';
  end if;
  for r in
    select p.id from public.cs_fathom_propuestas p
    join public.cs_fathom_sin_asignar s on s.id = p.llamada_id and s.estado in ('pendiente', 'interna')
    where p.estado = 'pendiente' and p.confianza = 'alta' and p.alumno_id is not null and p.tipo = 'consultoria_1a1'
    order by s.fecha, p.id
    limit greatest(least(coalesce(p_limite, 100), 300), 1)
  loop
    begin
      perform public.cs_fathom_prop_resolver(r.id, 'aceptar');
      v_ok := v_ok + 1;
    exception when others then
      v_fallo := v_fallo + 1;
      if jsonb_array_length(v_errs) < 10 then
        v_errs := v_errs || jsonb_build_object('propuesta', r.id, 'codigo', sqlstate, 'mensaje', left(sqlerrm, 160));
      end if;
    end;
  end loop;
  select count(*) into v_quedan
  from public.cs_fathom_propuestas p
  join public.cs_fathom_sin_asignar s on s.id = p.llamada_id and s.estado in ('pendiente', 'interna')
  where p.estado = 'pendiente' and p.confianza = 'alta' and p.alumno_id is not null and p.tipo = 'consultoria_1a1';
  return jsonb_build_object('aceptadas', v_ok, 'fallidas', v_fallo, 'errores', v_errs, 'quedan', v_quedan);
end;
$fn$;
revoke all on function public.cs_fathom_prop_aceptar_altas(int) from public, anon;
grant execute on function public.cs_fathom_prop_aceptar_altas(int) to authenticated;


-- =====================================================================
-- D. Flag APAGADO: que fathom-sync dispare la clasificación de lo nuevo (hoy nadie lo lee)
-- =====================================================================
alter table public.cs_fathom_config add column if not exists ia_clasificar_auto boolean not null default false;
comment on column public.cs_fathom_config.ia_clasificar_auto is
  '186: reservado. Si algún día fathom-sync lo lee en true, dispara ia-fathom-clasificar con lo nuevo. Hoy nada lo lee y debe estar en false.';


-- =====================================================================
-- Humo (se revierte solo): la tabla, los checks y las funciones se comportan.
-- =====================================================================
do $humo$
declare
  v_s  uuid;
  v_p  uuid;
  v_n  int;
begin
  insert into public.cs_fathom_sin_asignar (externo_id, fecha, titulo, consultor)
  values ('fathom:humo-186', current_date, 'humo 186', (select c.id from public.cs_fathom_consultores c order by c.orden, c.id limit 1))
  returning id into v_s;
  insert into public.cs_fathom_propuestas (llamada_id, tipo, confianza, motivo, origen)
  values (v_s, 'venta', 'baja', 'humo', 'ia') returning id into v_p;

  begin   -- tipo inválido rechazado
    insert into public.cs_fathom_propuestas (llamada_id, tipo, confianza) values (gen_random_uuid(), 'x', 'alta');
    raise exception 'HUMO 186: dejo pasar un tipo invalido';
  exception when check_violation or foreign_key_violation then null;
  end;
  begin   -- una sola propuesta por llamada
    insert into public.cs_fathom_propuestas (llamada_id, tipo, confianza) values (v_s, 'otra', 'alta');
    raise exception 'HUMO 186: dejo pasar dos propuestas para la misma llamada';
  exception when unique_violation then null;
  end;
  begin   -- sin sesión (auth.uid() null) no se decide
    perform public.cs_fathom_prop_resolver(v_p, 'descartar');
    raise exception 'HUMO 186: dejo decidir sin permiso';
  exception when insufficient_privilege then null;
  end;

  select count(*) into v_n from public.cs_fathom_config where ia_clasificar_auto;
  if v_n <> 0 then raise exception 'HUMO 186: el flag ia_clasificar_auto no esta apagado'; end if;
  if has_table_privilege('anon', 'public.cs_fathom_propuestas', 'select')
     or has_table_privilege('authenticated', 'public.cs_fathom_propuestas', 'insert')
     or has_table_privilege('authenticated', 'public.cs_fathom_propuestas', 'update')
     or has_function_privilege('anon', 'public.cs_fathom_prop_resolver(uuid,text,uuid,text)', 'execute') then
    raise exception 'HUMO 186: permisos de mas';
  end if;

  delete from public.cs_fathom_propuestas where llamada_id = v_s;
  delete from public.cs_fathom_sin_asignar where id = v_s;
  raise notice 'HUMO OK: 186';
end
$humo$;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- C1. Tabla, RLS y políticas (esperado: relrowsecurity = true, 1 política cs_prop_select).
--   select c.relrowsecurity, (select count(*) from pg_policies p where p.tablename = c.relname) as politicas
--   from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = 'cs_fathom_propuestas';
--
-- C2. Permisos (esperado: anon false/false/false; authenticated select true, insert false, update false;
--     service_role insert true; funciones: authenticated true, anon false).
--   select has_table_privilege('anon', 'public.cs_fathom_propuestas', 'select') as anon_sel,
--          has_table_privilege('authenticated', 'public.cs_fathom_propuestas', 'select') as auth_sel,
--          has_table_privilege('authenticated', 'public.cs_fathom_propuestas', 'insert') as auth_ins,
--          has_table_privilege('service_role', 'public.cs_fathom_propuestas', 'insert') as sr_ins,
--          has_function_privilege('authenticated', 'public.cs_fathom_prop_resolver(uuid,text,uuid,text)', 'execute') as res_auth,
--          has_function_privilege('anon', 'public.cs_fathom_prop_resolver(uuid,text,uuid,text)', 'execute') as res_anon,
--          has_function_privilege('anon', 'public.cs_fathom_prop_aceptar_altas(int)', 'execute') as altas_anon;
--
-- C3. Flag apagado (esperado: ia_clasificar_auto = false).
--   select programas, cron_activo, ia_clasificar_auto from public.cs_fathom_config;
--
-- C4. Llamadas sin asignar hoy (la tarea esperaba ~190), por consultor y estado.
--   select consultor, estado, count(*) from public.cs_fathom_sin_asignar group by 1, 2 order by 1, 2;
--
-- C5. DESPUÉS de "Clasificar pendientes": propuestas por estado, tipo y confianza.
--   select estado, tipo, confianza, origen, count(*) from public.cs_fathom_propuestas group by 1, 2, 3, 4 order by 1, 2, 3, 4;
--
-- C6. Costo de la clasificación (ia_uso; funcion 'fathom_clasificar').
--   select count(*) as pedidos, count(*) filter (where not ok) as fallidos, sum(costo_usd) as usd,
--          sum(tokens_entrada) as t_in, sum(tokens_salida) as t_out
--   from public.ia_uso where funcion = 'fathom_clasificar';
--
-- C7. Propuestas huérfanas (llamada ya resuelta a mano y propuesta todavía pendiente; esperado: se limpian solas al
--     aceptar / descartar; si hay muchas, es que alguien asigna a mano sin pasar por acá).
--   select count(*) from public.cs_fathom_propuestas p join public.cs_fathom_sin_asignar s on s.id = p.llamada_id
--   where p.estado = 'pendiente' and s.estado not in ('pendiente', 'interna');
--
-- C8. Aceptadas: la llamada quedó en la ficha (esperado: 0 filas con problema).
--   select p.id, s.estado from public.cs_fathom_propuestas p join public.cs_fathom_sin_asignar s on s.id = p.llamada_id
--   where p.estado in ('aceptada', 'corregida') and p.alumno_final is not null and s.estado <> 'asignada';

-- =====================================================================
-- VUELTA ATRÁS (comentada). Las llamadas ya asignadas por aceptar siguen asignadas (eso es la asignación manual de siempre).
-- =====================================================================
--   begin;
--   drop function if exists public.cs_fathom_prop_aceptar_altas(int);
--   drop function if exists public.cs_fathom_prop_resolver(uuid, text, uuid, text);
--   drop table if exists public.cs_fathom_propuestas;
--   alter table public.cs_fathom_config drop column if exists ia_clasificar_auto;
--   commit;
