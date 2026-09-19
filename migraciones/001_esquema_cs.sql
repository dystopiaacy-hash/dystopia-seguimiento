-- =====================================================================
-- 001_esquema_cs.sql  —  Dystopia Seguimiento, FASE 1: esquema cs_*
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
--
-- Migración PURAMENTE ADITIVA: solo crea objetos cs_*, crea/extiende la
-- publicación supabase_realtime y lee crm_clients para dar de alta los
-- 5 programas. No toca ningún objeto crm_*, es_fundador, rol_actual ni
-- tiene_acceso (solo los usa). No requiere backup previo.
--
-- Todo va dentro de una transacción: si algo falla, no queda nada a medias.
-- No usa pg_cron ni pg_net (no están instaladas).
--
-- Conteos PREVIOS (de 000_inspeccion, para comparar con la query de control):
--   crm_clients          = 5   (liam, agus, teo, mauro, lucas)
--   crm_members fundador = 1   (el total de crm_members no se midió en la
--                               inspección: compará con lo que veas en Dystopia)
--   políticas crm_*      = 11
--
-- Estructura:
--   0. Helpers y validadores
--   1. Tablas + índices
--   2. Funciones de trigger + triggers
--   3. RLS, políticas y permisos
--   4. Vistas (security_invoker)
--   5. Realtime
--   6. Alta de los 5 programas (liam activo, el resto inactivo)
--   7. Prueba de humo (inserta datos de prueba y los deshace)
--   8. QUERY DE CONTROL
-- =====================================================================

begin;

-- =====================================================================
-- 0. HELPERS Y VALIDADORES
-- =====================================================================

-- Fecha de negocio: hoy en Buenos Aires, no en UTC.
create or replace function public.cs_hoy()
returns date
language sql stable security definer set search_path = public
as $$
  select (now() at time zone 'America/Argentina/Buenos_Aires')::date
$$;

-- Fundador ve todo; rol 'cliente' ve solo los programas asignados.
-- Los editores de Dystopia no ven nada de esta app.
create or replace function public.cs_puede_ver(p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
      or (    coalesce(public.rol_actual() = 'cliente', false)
          and coalesce(public.tiene_acceso(p_programa), false))
$$;

create or replace function public.cs_puede_borrar()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
$$;

-- Valida cs_programas.plantilla_accionables:
-- array de {key, titulo, descripcion, responsable: bpf|cliente, dia_offset, vence_en_dias}
create or replace function public.cs_validar_plantilla(p jsonb)
returns boolean
language sql immutable set search_path = public
as $$
  select case when jsonb_typeof(p) is distinct from 'array' then false else
    not exists (
      select 1 from jsonb_array_elements(p) e
      where jsonb_typeof(e) <> 'object'
         or coalesce(btrim(e->>'key'), '') = ''
         or coalesce(btrim(e->>'titulo'), '') = ''
         or coalesce(e->>'responsable', '') not in ('bpf', 'cliente')
         or coalesce(e->>'dia_offset', '0') !~ '^\d+$'
         or coalesce(e->>'vence_en_dias', '0') !~ '^\d+$'
    )
    and (select count(*) = count(distinct e->>'key') from jsonb_array_elements(p) e)
  end
$$;

-- Valida cs_formularios.campos:
-- array de {key, label, tipo, opciones, requerido, es_metrica}.
-- Claves únicas, 'opcion' con opciones, máximo un es_metrica y debe ser escala_0_10.
create or replace function public.cs_validar_campos(p jsonb)
returns boolean
language sql immutable set search_path = public
as $$
  select case when jsonb_typeof(p) is distinct from 'array' then false else
    not exists (
      select 1 from jsonb_array_elements(p) e
      where jsonb_typeof(e) <> 'object'
         or coalesce(btrim(e->>'key'), '') = ''
         or coalesce(btrim(e->>'label'), '') = ''
         or coalesce(e->>'tipo', '') not in ('texto','parrafo','numero','escala_0_10','opcion','si_no')
         or (e->>'tipo' = 'opcion' and case when jsonb_typeof(e->'opciones') = 'array'
                                            then jsonb_array_length(e->'opciones') = 0
                                            else true end)
         or (e->>'es_metrica' = 'true' and e->>'tipo' <> 'escala_0_10')
    )
    and (select count(*) = count(distinct e->>'key') from jsonb_array_elements(p) e)
    and (select count(*) <= 1 from jsonb_array_elements(p) e where e->>'es_metrica' = 'true')
  end
$$;


-- =====================================================================
-- 1. TABLAS
-- =====================================================================

-- ---------- cs_programas ----------
create table if not exists public.cs_programas (
  id                        text primary key check (id ~ '^[a-z0-9_]+$'),
  nombre                    text not null,
  marca                     text,
  activo                    boolean not null default false,
  duracion_default_dias     int not null default 90  check (duracion_default_dias > 0),
  aviso_renovacion_dias     int not null default 30  check (aviso_renovacion_dias >= 0),
  sla_devolucion_horas      int not null default 72  check (sla_devolucion_horas > 0),
  sla_onboarding_dias       int not null default 3   check (sla_onboarding_dias >= 0),
  dias_sin_chequeo_alerta   int not null default 7   check (dias_sin_chequeo_alerta > 0),
  satisfaccion_umbral_bajo  numeric not null default 6 check (satisfaccion_umbral_bajo between 0 and 10),
  etapas                    jsonb not null
                            default '["Onboarding","Diagnóstico","Armado de portafolio","Seguimiento","Renovación"]'::jsonb
                            check (jsonb_typeof(etapas) = 'array'),
  plantilla_accionables     jsonb not null default '[]'::jsonb
                            check (public.cs_validar_plantilla(plantilla_accionables)),
  created_at                timestamptz not null default now()
);

-- ---------- cs_integraciones (solo fundador) ----------
create table if not exists public.cs_integraciones (
  programa_id          text primary key references public.cs_programas(id) on delete cascade,
  discord_webhook_url  text check (discord_webhook_url is null
                                   or discord_webhook_url ~* '^https://((canary|ptb)\.)?(discord|discordapp)\.com/api/webhooks/'),
  discord_activo       boolean not null default false,
  updated_at           timestamptz not null default now()
);

-- ---------- cs_clientes ----------
create table if not exists public.cs_clientes (
  id                  uuid primary key default gen_random_uuid(),
  programa_id         text not null references public.cs_programas(id),
  nombre              text not null check (btrim(nombre) <> ''),
  email               text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  telefono            text,
  fecha_inicio        date not null default public.cs_hoy(),
  fecha_fin           date not null,   -- si viene null, lo completa el trigger
  estado              text not null default 'onboarding'
                      check (estado in ('onboarding','activo','en_renovacion','finalizado','baja')),
  etapa               text,
  responsable         text,
  plan                text,
  notas               text,
  token_publico       uuid not null unique default gen_random_uuid(),
  ultimo_chequeo_at   timestamptz,
  renovaciones_count  int not null default 0 check (renovaciones_count >= 0),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid default auth.uid(),
  constraint cs_clientes_fechas_chk check (fecha_fin >= fecha_inicio),
  -- destino de las FK compuestas (cliente_id, programa_id) de las tablas hijas
  constraint cs_clientes_id_programa_key unique (id, programa_id)
);
create index if not exists cs_clientes_programa_estado_idx on public.cs_clientes (programa_id, estado);

-- ---------- cs_accionables ----------
create table if not exists public.cs_accionables (
  id             uuid primary key default gen_random_uuid(),
  programa_id    text not null references public.cs_programas(id),
  cliente_id     uuid not null,
  responsable    text not null check (responsable in ('bpf','cliente')),
  titulo         text not null check (btrim(titulo) <> ''),
  descripcion    text,
  estado         text not null default 'pendiente' check (estado in ('pendiente','en_proceso','completado')),
  vence          date,
  completado_at  timestamptz,
  origen         text not null default 'manual' check (origen in ('manual','plantilla','sistema')),
  plantilla_key  text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  constraint cs_accionables_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  constraint cs_accionables_plantilla_key unique (cliente_id, plantilla_key)
);
create index if not exists cs_accionables_programa_estado_idx on public.cs_accionables (programa_id, estado);

-- ---------- cs_devoluciones ----------
create table if not exists public.cs_devoluciones (
  id             uuid primary key default gen_random_uuid(),
  programa_id    text not null references public.cs_programas(id),
  cliente_id     uuid not null,
  titulo         text not null check (btrim(titulo) <> ''),
  solicitada_at  timestamptz not null default now(),
  estado         text not null default 'pendiente' check (estado in ('pendiente','en_proceso','entregada')),
  loom_url       text check (loom_url is null or loom_url ~* '^https://(www\.)?loom\.com/'),
  entregada_at   timestamptz,
  notas          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  constraint cs_devoluciones_entregada_requiere_loom check (estado <> 'entregada' or loom_url is not null),
  constraint cs_devoluciones_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_devoluciones_cliente_idx on public.cs_devoluciones (cliente_id);
create index if not exists cs_devoluciones_programa_estado_idx on public.cs_devoluciones (programa_id, estado);

-- ---------- cs_calls ----------
create table if not exists public.cs_calls (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id),
  cliente_id   uuid not null,
  tipo         text not null default 'seguimiento' check (tipo in ('onboarding','seguimiento','renovacion','otra')),
  estado       text not null default 'pendiente_agendar'
               check (estado in ('pendiente_agendar','agendada','realizada','no_show','cancelada')),
  fecha        timestamptz,
  notas        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  constraint cs_calls_agendada_requiere_fecha check (estado <> 'agendada' or fecha is not null),
  constraint cs_calls_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_calls_cliente_tipo_idx on public.cs_calls (cliente_id, tipo);

-- ---------- cs_renovaciones ----------
create table if not exists public.cs_renovaciones (
  id               uuid primary key default gen_random_uuid(),
  programa_id      text not null references public.cs_programas(id),
  cliente_id       uuid not null,
  iniciada_at      timestamptz not null default now(),
  estado           text not null default 'en_proceso' check (estado in ('en_proceso','renovado','no_renovado')),
  resultado_at     timestamptz,
  nueva_fecha_fin  date,
  motivo           text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  constraint cs_renovaciones_renovado_requiere_fecha check (estado <> 'renovado' or nueva_fecha_fin is not null),
  constraint cs_renovaciones_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_renovaciones_cliente_idx on public.cs_renovaciones (cliente_id);
-- Solo una renovación en_proceso por cliente.
create unique index if not exists cs_renovaciones_una_en_proceso
  on public.cs_renovaciones (cliente_id) where estado = 'en_proceso';

-- ---------- cs_formularios ----------
create table if not exists public.cs_formularios (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id),
  nombre       text not null check (btrim(nombre) <> ''),
  tipo         text not null default 'otro' check (tipo in ('onboarding','satisfaccion','checkin','devolucion','otro')),
  campos       jsonb not null default '[]'::jsonb check (public.cs_validar_campos(campos)),
  activo       boolean not null default true,
  token        uuid not null unique default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint cs_formularios_id_programa_key unique (id, programa_id)
);
create index if not exists cs_formularios_programa_idx on public.cs_formularios (programa_id);

-- ---------- cs_respuestas (insert solo vía RPC SECURITY DEFINER, Fase 5) ----------
create table if not exists public.cs_respuestas (
  id             uuid primary key default gen_random_uuid(),
  programa_id    text not null references public.cs_programas(id),
  formulario_id  uuid not null,
  cliente_id     uuid,
  respuestas     jsonb not null check (jsonb_typeof(respuestas) = 'object'
                                       and octet_length(respuestas::text) <= 20000),
  puntaje        numeric check (puntaje is null or puntaje between 0 and 10),
  created_at     timestamptz not null default now(),
  constraint cs_respuestas_formulario_fk foreign key (formulario_id, programa_id)
    references public.cs_formularios (id, programa_id) on delete cascade,
  -- si se borra el cliente, la respuesta queda (cliente_id = null) y conserva programa_id
  constraint cs_respuestas_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete set null (cliente_id)
);
create index if not exists cs_respuestas_programa_fecha_idx on public.cs_respuestas (programa_id, created_at);
create index if not exists cs_respuestas_formulario_idx on public.cs_respuestas (formulario_id);
create index if not exists cs_respuestas_cliente_idx on public.cs_respuestas (cliente_id);

-- ---------- cs_chequeos ----------
create table if not exists public.cs_chequeos (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id),
  cliente_id   uuid not null,
  usuario      uuid default auth.uid(),
  nota         text,
  created_at   timestamptz not null default now(),
  constraint cs_chequeos_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_chequeos_cliente_fecha_idx on public.cs_chequeos (cliente_id, created_at);

-- ---------- cs_historial (solo lo escriben triggers) ----------
create table if not exists public.cs_historial (
  id              bigserial primary key,
  tabla           text not null,
  registro_id     uuid not null,
  programa_id     text not null,
  campo           text not null,
  valor_anterior  text,
  valor_nuevo     text,
  usuario         uuid default auth.uid(),
  at              timestamptz not null default now()
);
create index if not exists cs_historial_registro_idx on public.cs_historial (registro_id, at);
create index if not exists cs_historial_programa_idx on public.cs_historial (programa_id, at);

-- ---------- cs_alertas (insert solo desde funciones SECURITY DEFINER) ----------
create table if not exists public.cs_alertas (
  id                     uuid primary key default gen_random_uuid(),
  programa_id            text not null references public.cs_programas(id),
  cliente_id             uuid,
  tipo                   text not null check (tipo in ('renovacion_proxima','devolucion_vencida','onboarding_demorado',
                                                       'accionable_bpf_vencido','sin_chequeo','satisfaccion_baja',
                                                       'programa_vencido')),
  mensaje                text,
  clave_dedupe           text not null unique,
  resuelta               boolean not null default false,
  resuelta_at            timestamptz,
  notificada_discord_at  timestamptz,
  created_at             timestamptz not null default now(),
  constraint cs_alertas_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create index if not exists cs_alertas_programa_resuelta_idx on public.cs_alertas (programa_id, resuelta);
create index if not exists cs_alertas_cliente_idx on public.cs_alertas (cliente_id);


-- =====================================================================
-- 2. FUNCIONES DE TRIGGER + TRIGGERS
-- =====================================================================

-- ---------- updated_at automático ----------
create or replace function public.cs_tg_updated_at()
returns trigger language plpgsql set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------- programa_id de tablas hijas: se copia del cliente o se rechaza ----------
-- Corre como el usuario (sin SECURITY DEFINER): si no ve al cliente, no puede colgarle nada.
create or replace function public.cs_tg_programa_desde_cliente()
returns trigger language plpgsql set search_path = public
as $$
declare
  v_programa text;
begin
  if new.cliente_id is null then
    if new.programa_id is null then
      raise exception 'cs: programa_id es obligatorio cuando no hay cliente_id' using errcode = '23502';
    end if;
    return new;
  end if;

  select c.programa_id into v_programa from public.cs_clientes c where c.id = new.cliente_id;
  if v_programa is null then
    raise exception 'cs: el cliente % no existe o no tenés acceso', new.cliente_id using errcode = '23503';
  end if;

  if new.programa_id is null then
    new.programa_id := v_programa;
  elsif new.programa_id <> v_programa then
    raise exception 'cs: programa_id (%) no coincide con el del cliente (%)', new.programa_id, v_programa
      using errcode = '23514';
  end if;
  return new;
end;
$$;

-- ---------- cs_respuestas: programa desde el formulario + puntaje del campo métrico ----------
create or replace function public.cs_tg_respuestas_programa()
returns trigger language plpgsql set search_path = public
as $$
declare
  v_programa  text;
  v_key       text;
  v_cliente_p text;
  v_valor     text;
begin
  select f.programa_id,
         (select e->>'key' from jsonb_array_elements(f.campos) e where e->>'es_metrica' = 'true' limit 1)
    into v_programa, v_key
  from public.cs_formularios f where f.id = new.formulario_id;

  if v_programa is null then
    raise exception 'cs: el formulario % no existe', new.formulario_id using errcode = '23503';
  end if;
  if new.programa_id is null then
    new.programa_id := v_programa;
  elsif new.programa_id <> v_programa then
    raise exception 'cs: programa_id no coincide con el del formulario' using errcode = '23514';
  end if;

  if new.cliente_id is not null then
    select c.programa_id into v_cliente_p from public.cs_clientes c where c.id = new.cliente_id;
    if v_cliente_p is distinct from new.programa_id then
      raise exception 'cs: el cliente no pertenece al programa del formulario' using errcode = '23514';
    end if;
  end if;

  -- puntaje: se extrae del campo es_metrica si viene un número válido de 0 a 10
  if new.puntaje is null and v_key is not null then
    v_valor := new.respuestas->>v_key;
    if (case when v_valor ~ '^\d+(\.\d+)?$' then v_valor::numeric between 0 and 10 else false end) then
      new.puntaje := v_valor::numeric;
    end if;
  end if;
  return new;
end;
$$;

-- ---------- cs_clientes: fecha_fin por defecto y programa inmutable ----------
create or replace function public.cs_tg_clientes_before()
returns trigger language plpgsql set search_path = public
as $$
declare
  v_dur int;
begin
  if tg_op = 'UPDATE' and new.programa_id is distinct from old.programa_id then
    raise exception 'cs: no se puede cambiar el programa de un cliente' using errcode = '23514';
  end if;
  if new.fecha_inicio is null then
    new.fecha_inicio := public.cs_hoy();
  end if;
  if new.fecha_fin is null then
    select p.duracion_default_dias into v_dur from public.cs_programas p where p.id = new.programa_id;
    new.fecha_fin := new.fecha_inicio + coalesce(v_dur, 90);
  end if;
  return new;
end;
$$;

-- ---------- cs_clientes: al crear, call de onboarding + plantilla día 0 ----------
create or replace function public.cs_tg_clientes_after_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  -- Call de onboarding solo si el cliente arranca en onboarding
  -- (si se carga directamente como 'activo', el onboarding ya se hizo).
  if new.estado = 'onboarding' then
    insert into public.cs_calls (programa_id, cliente_id, tipo, estado, created_by)
    values (new.programa_id, new.id, 'onboarding', 'pendiente_agendar', new.created_by);
  end if;

  -- Plantilla de accionables: ítems con dia_offset = 0.
  if new.estado in ('onboarding','activo','en_renovacion') then
    insert into public.cs_accionables
      (programa_id, cliente_id, responsable, titulo, descripcion, vence, origen, plantilla_key, created_by)
    select new.programa_id, new.id,
           e->>'responsable', e->>'titulo', nullif(e->>'descripcion', ''),
           new.fecha_inicio + (e->>'vence_en_dias')::int,   -- null si no hay vence_en_dias
           'plantilla', e->>'key', new.created_by
    from public.cs_programas p
    cross join lateral jsonb_array_elements(p.plantilla_accionables) e
    where p.id = new.programa_id
      and coalesce((e->>'dia_offset')::int, 0) = 0
    on conflict (cliente_id, plantilla_key) do nothing;
  end if;
  return null;
end;
$$;

-- ---------- cs_accionables: completado_at ----------
create or replace function public.cs_tg_accionables_estado()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.estado = 'completado' then
    if tg_op = 'INSERT' then
      new.completado_at := coalesce(new.completado_at, now());
    elsif old.estado <> 'completado' then
      new.completado_at := now();
    else
      new.completado_at := coalesce(new.completado_at, old.completado_at, now());
    end if;
  else
    new.completado_at := null;
  end if;
  return new;
end;
$$;

-- ---------- cs_devoluciones: entregada_at (el loom obligatorio lo asegura un CHECK) ----------
create or replace function public.cs_tg_devoluciones_estado()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.estado = 'entregada' then
    if tg_op = 'INSERT' then
      new.entregada_at := coalesce(new.entregada_at, now());
    elsif old.estado <> 'entregada' then
      new.entregada_at := now();
    else
      new.entregada_at := coalesce(new.entregada_at, old.entregada_at, now());
    end if;
  else
    new.entregada_at := null;
  end if;
  return new;
end;
$$;

-- ---------- cs_renovaciones: reglas antes de guardar ----------
create or replace function public.cs_tg_renovaciones_before()
returns trigger language plpgsql set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    if new.cliente_id is distinct from old.cliente_id then
      raise exception 'cs: no se puede mover una renovación a otro cliente' using errcode = '23514';
    end if;
    -- Una renovación cerrada no se reabre (evita contar dos veces renovaciones_count).
    if old.estado in ('renovado','no_renovado') and new.estado is distinct from old.estado then
      raise exception 'cs: la renovación ya está cerrada (%). Para corregirla, borrala (fundador) y cargá una nueva', old.estado
        using errcode = '23514';
    end if;
    if old.estado = 'renovado' and new.nueva_fecha_fin is distinct from old.nueva_fecha_fin then
      raise exception 'cs: no se puede cambiar nueva_fecha_fin de una renovación ya cerrada' using errcode = '23514';
    end if;
  end if;

  if new.estado in ('renovado','no_renovado') then
    if tg_op = 'INSERT' then
      new.resultado_at := coalesce(new.resultado_at, now());
    elsif old.estado = 'en_proceso' then
      new.resultado_at := now();
    end if;
  else
    new.resultado_at := null;
  end if;
  return new;
end;
$$;

-- ---------- cs_renovaciones: efecto sobre el cliente ----------
create or replace function public.cs_tg_renovaciones_after()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.estado = old.estado then
    return null;
  end if;

  if new.estado = 'en_proceso' then
    update public.cs_clientes
       set estado = 'en_renovacion'
     where id = new.cliente_id and estado not in ('en_renovacion','baja');

  elsif new.estado = 'renovado' then
    update public.cs_clientes
       set estado = 'activo',
           fecha_fin = new.nueva_fecha_fin,
           renovaciones_count = renovaciones_count + 1
     where id = new.cliente_id;

  elsif new.estado = 'no_renovado' then
    -- Vuelve a 'activo' hasta que venza fecha_fin; si ya venció, pasa directo a 'finalizado'.
    update public.cs_clientes
       set estado = case when fecha_fin < public.cs_hoy() then 'finalizado' else 'activo' end
     where id = new.cliente_id and estado = 'en_renovacion';
  end if;
  return null;
end;
$$;

-- ---------- cs_chequeos: actualiza ultimo_chequeo_at del cliente ----------
create or replace function public.cs_tg_chequeos_after()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  update public.cs_clientes
     set ultimo_chequeo_at = greatest(coalesce(ultimo_chequeo_at, new.created_at), new.created_at)
   where id = new.cliente_id;
  return null;
end;
$$;

-- ---------- cs_alertas: resuelta_at ----------
create or replace function public.cs_tg_alertas_before()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.resuelta and not old.resuelta then
    new.resuelta_at := now();
  elsif not new.resuelta then
    new.resuelta_at := null;
  end if;
  return new;
end;
$$;

-- ---------- cs_historial: registra cambios de los campos pasados como argumentos ----------
-- En INSERT registra el valor inicial (valor_anterior = null) para poder medir
-- días reales en cada estado desde el primer momento.
create or replace function public.cs_tg_historial()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_campo  text;
  v_old    text;
  v_new    text;
  j_new    jsonb := to_jsonb(new);
  j_old    jsonb;
begin
  if tg_op = 'UPDATE' then
    j_old := to_jsonb(old);
  end if;

  foreach v_campo in array tg_argv loop
    v_new := j_new->>v_campo;
    v_old := j_old->>v_campo;   -- null en INSERT
    if (tg_op = 'INSERT' and v_new is not null)
       or (tg_op = 'UPDATE' and v_old is distinct from v_new) then
      insert into public.cs_historial (tabla, registro_id, programa_id, campo, valor_anterior, valor_nuevo)
      values (tg_table_name, (j_new->>'id')::uuid, j_new->>'programa_id', v_campo, v_old, v_new);
    end if;
  end loop;
  return null;
end;
$$;

-- ---------- Triggers (el prefijo numérico fija el orden entre BEFORE) ----------

-- cs_programas: no tiene updated_at.

create or replace trigger cs_trg_90_updated_at before update on public.cs_integraciones
  for each row execute function public.cs_tg_updated_at();

-- cs_clientes
create or replace trigger cs_trg_10_before before insert or update on public.cs_clientes
  for each row execute function public.cs_tg_clientes_before();
create or replace trigger cs_trg_90_updated_at before update on public.cs_clientes
  for each row execute function public.cs_tg_updated_at();
create or replace trigger cs_trg_after_insert after insert on public.cs_clientes
  for each row execute function public.cs_tg_clientes_after_insert();
create or replace trigger cs_trg_historial after insert or update of estado, fecha_fin on public.cs_clientes
  for each row execute function public.cs_tg_historial('estado', 'fecha_fin');

-- cs_accionables
create or replace trigger cs_trg_10_programa before insert or update of cliente_id, programa_id on public.cs_accionables
  for each row execute function public.cs_tg_programa_desde_cliente();
create or replace trigger cs_trg_20_estado before insert or update on public.cs_accionables
  for each row execute function public.cs_tg_accionables_estado();
create or replace trigger cs_trg_90_updated_at before update on public.cs_accionables
  for each row execute function public.cs_tg_updated_at();
create or replace trigger cs_trg_historial after insert or update of estado on public.cs_accionables
  for each row execute function public.cs_tg_historial('estado');

-- cs_devoluciones
create or replace trigger cs_trg_10_programa before insert or update of cliente_id, programa_id on public.cs_devoluciones
  for each row execute function public.cs_tg_programa_desde_cliente();
create or replace trigger cs_trg_20_estado before insert or update on public.cs_devoluciones
  for each row execute function public.cs_tg_devoluciones_estado();
create or replace trigger cs_trg_90_updated_at before update on public.cs_devoluciones
  for each row execute function public.cs_tg_updated_at();
create or replace trigger cs_trg_historial after insert or update of estado on public.cs_devoluciones
  for each row execute function public.cs_tg_historial('estado');

-- cs_calls
create or replace trigger cs_trg_10_programa before insert or update of cliente_id, programa_id on public.cs_calls
  for each row execute function public.cs_tg_programa_desde_cliente();
create or replace trigger cs_trg_90_updated_at before update on public.cs_calls
  for each row execute function public.cs_tg_updated_at();
create or replace trigger cs_trg_historial after insert or update of estado on public.cs_calls
  for each row execute function public.cs_tg_historial('estado');

-- cs_renovaciones
create or replace trigger cs_trg_10_programa before insert or update of cliente_id, programa_id on public.cs_renovaciones
  for each row execute function public.cs_tg_programa_desde_cliente();
create or replace trigger cs_trg_20_reglas before insert or update on public.cs_renovaciones
  for each row execute function public.cs_tg_renovaciones_before();
create or replace trigger cs_trg_90_updated_at before update on public.cs_renovaciones
  for each row execute function public.cs_tg_updated_at();
create or replace trigger cs_trg_after_estado after insert or update of estado on public.cs_renovaciones
  for each row execute function public.cs_tg_renovaciones_after();
create or replace trigger cs_trg_historial after insert or update of estado on public.cs_renovaciones
  for each row execute function public.cs_tg_historial('estado');

-- cs_formularios
create or replace trigger cs_trg_90_updated_at before update on public.cs_formularios
  for each row execute function public.cs_tg_updated_at();

-- cs_respuestas
create or replace trigger cs_trg_10_programa before insert or update on public.cs_respuestas
  for each row execute function public.cs_tg_respuestas_programa();

-- cs_chequeos
create or replace trigger cs_trg_10_programa before insert or update of cliente_id, programa_id on public.cs_chequeos
  for each row execute function public.cs_tg_programa_desde_cliente();
create or replace trigger cs_trg_after_insert after insert on public.cs_chequeos
  for each row execute function public.cs_tg_chequeos_after();

-- cs_alertas
create or replace trigger cs_trg_10_programa before insert or update of cliente_id, programa_id on public.cs_alertas
  for each row execute function public.cs_tg_programa_desde_cliente();
create or replace trigger cs_trg_20_resuelta before update on public.cs_alertas
  for each row execute function public.cs_tg_alertas_before();


-- =====================================================================
-- 3. RLS, POLÍTICAS Y PERMISOS
-- =====================================================================

-- RLS en las 12 tablas + nada para anon + sin TRUNCATE/REFERENCES/TRIGGER
-- para authenticated (TRUNCATE saltea RLS).
do $$
declare
  t text;
begin
  foreach t in array array[
    'cs_programas','cs_integraciones','cs_clientes','cs_accionables','cs_devoluciones','cs_calls',
    'cs_renovaciones','cs_formularios','cs_respuestas','cs_chequeos','cs_historial','cs_alertas'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke truncate, references, trigger on table public.%I from authenticated', t);
  end loop;
end $$;
revoke all on sequence public.cs_historial_id_seq from anon, authenticated;

-- Patrón estándar: tablas con programa_id que el usuario edita.
do $$
declare
  t text;
begin
  foreach t in array array[
    'cs_clientes','cs_accionables','cs_devoluciones','cs_calls','cs_renovaciones','cs_formularios','cs_chequeos'
  ] loop
    execute format('grant select, insert, update, delete on table public.%I to authenticated', t);

    execute format('drop policy if exists cs_select on public.%I', t);
    execute format('create policy cs_select on public.%I for select to authenticated
                      using (public.cs_puede_ver(programa_id))', t);

    execute format('drop policy if exists cs_insert on public.%I', t);
    execute format('create policy cs_insert on public.%I for insert to authenticated
                      with check (public.cs_puede_ver(programa_id))', t);

    execute format('drop policy if exists cs_update on public.%I', t);
    execute format('create policy cs_update on public.%I for update to authenticated
                      using (public.cs_puede_ver(programa_id))
                      with check (public.cs_puede_ver(programa_id))', t);

    execute format('drop policy if exists cs_delete on public.%I', t);
    execute format('create policy cs_delete on public.%I for delete to authenticated
                      using (public.cs_puede_borrar())', t);
  end loop;
end $$;

-- cs_programas: ven los que tienen acceso; escribe solo fundador.
grant select, insert, update, delete on table public.cs_programas to authenticated;
drop policy if exists cs_select on public.cs_programas;
create policy cs_select on public.cs_programas for select to authenticated
  using (public.cs_puede_ver(id));
drop policy if exists cs_insert on public.cs_programas;
create policy cs_insert on public.cs_programas for insert to authenticated
  with check (public.es_fundador());
drop policy if exists cs_update on public.cs_programas;
create policy cs_update on public.cs_programas for update to authenticated
  using (public.es_fundador()) with check (public.es_fundador());
drop policy if exists cs_delete on public.cs_programas;
create policy cs_delete on public.cs_programas for delete to authenticated
  using (public.es_fundador());

-- cs_integraciones: todo solo fundador (ni lectura para cliente).
grant select, insert, update, delete on table public.cs_integraciones to authenticated;
drop policy if exists cs_fundador on public.cs_integraciones;
create policy cs_fundador on public.cs_integraciones for all to authenticated
  using (public.es_fundador()) with check (public.es_fundador());

-- cs_respuestas: lectura + delete solo fundador (spam de formularios públicos).
-- El insert va por RPC SECURITY DEFINER en Fase 5; nadie hace update.
grant select, delete on table public.cs_respuestas to authenticated;
revoke insert, update on table public.cs_respuestas from authenticated;
drop policy if exists cs_select on public.cs_respuestas;
create policy cs_select on public.cs_respuestas for select to authenticated
  using (public.cs_puede_ver(programa_id));
drop policy if exists cs_delete on public.cs_respuestas;
create policy cs_delete on public.cs_respuestas for delete to authenticated
  using (public.cs_puede_borrar());

-- cs_historial: solo lectura (lo escriben los triggers).
grant select on table public.cs_historial to authenticated;
revoke insert, update, delete on table public.cs_historial from authenticated;
drop policy if exists cs_select on public.cs_historial;
create policy cs_select on public.cs_historial for select to authenticated
  using (public.cs_puede_ver(programa_id));

-- cs_alertas: select + update SOLO de la columna 'resuelta'; delete fundador;
-- insert solo desde funciones SECURITY DEFINER.
grant select, delete on table public.cs_alertas to authenticated;
revoke insert, update on table public.cs_alertas from authenticated;
grant update (resuelta) on table public.cs_alertas to authenticated;
drop policy if exists cs_select on public.cs_alertas;
create policy cs_select on public.cs_alertas for select to authenticated
  using (public.cs_puede_ver(programa_id));
drop policy if exists cs_update on public.cs_alertas;
create policy cs_update on public.cs_alertas for update to authenticated
  using (public.cs_puede_ver(programa_id)) with check (public.cs_puede_ver(programa_id));
drop policy if exists cs_delete on public.cs_alertas;
create policy cs_delete on public.cs_alertas for delete to authenticated
  using (public.cs_puede_borrar());

-- Funciones: nada para anon/public. authenticated ejecuta helpers y validadores
-- (los usan RLS, el default de fecha_inicio y los CHECK).
revoke all on function
  public.cs_hoy(), public.cs_puede_ver(text), public.cs_puede_borrar(),
  public.cs_validar_plantilla(jsonb), public.cs_validar_campos(jsonb),
  public.cs_tg_updated_at(), public.cs_tg_programa_desde_cliente(), public.cs_tg_respuestas_programa(),
  public.cs_tg_clientes_before(), public.cs_tg_clientes_after_insert(), public.cs_tg_accionables_estado(),
  public.cs_tg_devoluciones_estado(), public.cs_tg_renovaciones_before(), public.cs_tg_renovaciones_after(),
  public.cs_tg_chequeos_after(), public.cs_tg_alertas_before(), public.cs_tg_historial()
from public, anon;
grant execute on function
  public.cs_hoy(), public.cs_puede_ver(text), public.cs_puede_borrar(),
  public.cs_validar_plantilla(jsonb), public.cs_validar_campos(jsonb)
to authenticated;


-- =====================================================================
-- 4. VISTAS (security_invoker = on: respetan la RLS del que consulta)
-- =====================================================================

-- ---------- cs_v_clientes ----------
-- Semáforo:
--   ROJO:     devolución fuera de SLA | accionable BPF vencido |
--             onboarding sin agendar pasado el SLA |
--             vence dentro del aviso (o ya venció) sin renovación en proceso
--             ni decisión de no renovar, y estado no finalizado/baja.
--   AMARILLO: vence dentro del aviso con renovación en proceso |
--             sin chequeo > umbral (solo clientes no finalizados/baja) |
--             accionable del cliente vencido | devolución pendiente dentro de SLA.
--   VERDE:    el resto.
-- Nota: una renovación 'renovado' NO silencia la alerta del ciclo siguiente,
-- porque al renovarse ya se movió fecha_fin (ver resumen de decisiones).
create or replace view public.cs_v_clientes
with (security_invoker = on) as
with m as (
  select
    c.id as cliente_id,
    c.estado as estado_cliente,
    p.aviso_renovacion_dias,
    p.sla_onboarding_dias,
    p.dias_sin_chequeo_alerta,
    c.fecha_fin - public.cs_hoy()     as dias_restantes,
    public.cs_hoy() - c.fecha_inicio  as dias_transcurridos,
    least(100, greatest(0, round(100.0 * (public.cs_hoy() - c.fecha_inicio)
                                 / nullif(c.fecha_fin - c.fecha_inicio, 0))))::int as pct_programa,
    a.bpf_pend  as acc_bpf_pendientes,
    a.bpf_venc  as acc_bpf_vencidos,
    a.cli_pend  as acc_cliente_pendientes,
    a.cli_venc  as acc_cliente_vencidos,
    d.pend      as dev_pendientes,
    d.venc      as dev_vencidas_sla,
    o.estado    as onboarding_estado,
    r.estado    as renovacion_estado,
    public.cs_hoy()
      - (coalesce(c.ultimo_chequeo_at, c.created_at) at time zone 'America/Argentina/Buenos_Aires')::date
                as dias_sin_chequeo
  from public.cs_clientes c
  join public.cs_programas p on p.id = c.programa_id
  left join lateral (
    select count(*) filter (where x.responsable = 'bpf')                                 as bpf_pend,
           count(*) filter (where x.responsable = 'bpf' and x.vence < public.cs_hoy())     as bpf_venc,
           count(*) filter (where x.responsable = 'cliente')                             as cli_pend,
           count(*) filter (where x.responsable = 'cliente' and x.vence < public.cs_hoy()) as cli_venc
    from public.cs_accionables x
    where x.cliente_id = c.id and x.estado <> 'completado'
  ) a on true
  left join lateral (
    select count(*) as pend,
           count(*) filter (where x.solicitada_at + make_interval(hours => p.sla_devolucion_horas) < now()) as venc
    from public.cs_devoluciones x
    where x.cliente_id = c.id and x.estado in ('pendiente','en_proceso')
  ) d on true
  left join lateral (
    select x.estado from public.cs_calls x
    where x.cliente_id = c.id and x.tipo = 'onboarding'
    order by x.created_at desc
    limit 1
  ) o on true
  left join lateral (
    -- si hay una en_proceso, manda esa; si no, la más reciente
    select x.estado from public.cs_renovaciones x
    where x.cliente_id = c.id
    order by (x.estado = 'en_proceso') desc, x.iniciada_at desc
    limit 1
  ) r on true
),
f as (
  select m.*,
    (m.dev_vencidas_sla > 0)                                                       as r_dev,
    (m.acc_bpf_vencidos > 0)                                                       as r_acc,
    (m.onboarding_estado = 'pendiente_agendar'
       and m.dias_transcurridos > m.sla_onboarding_dias)                           as r_onb,
    (m.dias_restantes <= m.aviso_renovacion_dias
       and m.estado_cliente not in ('finalizado','baja')
       and coalesce(m.renovacion_estado, '') not in ('en_proceso','no_renovado'))   as r_ren,
    (m.dias_restantes <= m.aviso_renovacion_dias
       and m.estado_cliente not in ('finalizado','baja')
       and m.renovacion_estado = 'en_proceso')                                     as a_ren,
    (m.estado_cliente not in ('finalizado','baja')
       and m.dias_sin_chequeo > m.dias_sin_chequeo_alerta)                         as a_chq,
    (m.acc_cliente_vencidos > 0)                                                   as a_acc,
    (m.dev_pendientes > m.dev_vencidas_sla)                                        as a_dev
  from m
)
select
  c.*,
  f.dias_restantes,
  f.dias_transcurridos,
  f.pct_programa,
  f.acc_bpf_pendientes,
  f.acc_bpf_vencidos,
  f.acc_cliente_pendientes,
  f.acc_cliente_vencidos,
  f.dev_pendientes,
  f.dev_vencidas_sla,
  f.onboarding_estado,
  f.renovacion_estado,
  f.dias_sin_chequeo,
  case
    when f.r_dev or f.r_acc or f.r_onb or f.r_ren then 'rojo'
    when f.a_ren or f.a_chq or f.a_acc or f.a_dev then 'amarillo'
    else 'verde'
  end as semaforo,
  array_remove(array[
    case when f.r_dev then format('%s devolución(es) fuera de SLA', f.dev_vencidas_sla) end,
    case when f.r_acc then format('%s accionable(s) BPF vencido(s)', f.acc_bpf_vencidos) end,
    case when f.r_onb then format('Onboarding sin agendar hace %s días', f.dias_transcurridos) end,
    case when f.r_ren and f.dias_restantes < 0
         then format('Programa vencido hace %s días sin renovación', -f.dias_restantes) end,
    case when f.r_ren and f.dias_restantes >= 0
         then format('Vence en %s días sin renovación iniciada', f.dias_restantes) end,
    case when f.a_ren then format('Renovación en proceso, vence en %s días', f.dias_restantes) end,
    case when f.a_chq then format('Sin chequeo hace %s días', f.dias_sin_chequeo) end,
    case when f.a_acc then format('%s accionable(s) del cliente vencido(s)', f.acc_cliente_vencidos) end,
    case when f.a_dev then format('%s devolución(es) pendiente(s) dentro de SLA',
                                  f.dev_pendientes - f.dev_vencidas_sla) end
  ], null) as motivos_semaforo
from public.cs_clientes c
join f on f.cliente_id = c.id;

-- ---------- cs_v_kpis_programa ----------
-- "Clientes vivos" = estado en onboarding, activo, en_renovacion.
-- tasa_renovacion, pct_* y nps en escala 0-100.
create or replace view public.cs_v_kpis_programa
with (security_invoker = on) as
select
  p.id      as programa_id,
  p.nombre,
  p.activo,
  v.clientes_activos,
  v.onboarding_pendientes,
  v.acc_bpf_pendientes,
  v.acc_bpf_vencidos,
  v.acc_cliente_pendientes,
  d.pend    as dev_pendientes,
  d.ent     as dev_entregadas,
  d.total   as dev_total,
  round(100.0 * d.pend / nullif(d.total, 0), 1) as pct_dev_pendientes,
  round(100.0 * d.ent  / nullif(d.total, 0), 1) as pct_dev_entregadas,
  v.dev_vencidas_sla,
  v.por_vencer,
  v.en_renovacion,
  round(100.0 * r.ren / nullif(r.ren + r.noren, 0), 1)  as tasa_renovacion,
  round(s.prom, 2)                                      as satisfaccion_prom_90d,
  round(100.0 * (s.promotores - s.detractores) / nullif(s.n, 0), 1) as nps_90d,
  s.n                                                   as respuestas_90d,
  v.clientes_rojo,
  v.clientes_amarillo,
  v.clientes_verde,
  v.sin_chequeo
from public.cs_programas p
left join lateral (
  select
    count(*) filter (where vc.estado in ('onboarding','activo','en_renovacion'))                  as clientes_activos,
    count(*) filter (where vc.estado in ('onboarding','activo','en_renovacion')
                       and vc.onboarding_estado = 'pendiente_agendar')                           as onboarding_pendientes,
    coalesce(sum(vc.acc_bpf_pendientes), 0)::int                                                 as acc_bpf_pendientes,
    coalesce(sum(vc.acc_bpf_vencidos), 0)::int                                                   as acc_bpf_vencidos,
    coalesce(sum(vc.acc_cliente_pendientes), 0)::int                                             as acc_cliente_pendientes,
    coalesce(sum(vc.dev_vencidas_sla), 0)::int                                                   as dev_vencidas_sla,
    count(*) filter (where vc.estado in ('onboarding','activo','en_renovacion')
                       and vc.dias_restantes between 0 and p.aviso_renovacion_dias)             as por_vencer,
    count(*) filter (where vc.estado = 'en_renovacion')                                          as en_renovacion,
    count(*) filter (where vc.estado in ('onboarding','activo','en_renovacion') and vc.semaforo = 'rojo')     as clientes_rojo,
    count(*) filter (where vc.estado in ('onboarding','activo','en_renovacion') and vc.semaforo = 'amarillo') as clientes_amarillo,
    count(*) filter (where vc.estado in ('onboarding','activo','en_renovacion') and vc.semaforo = 'verde')    as clientes_verde,
    count(*) filter (where vc.estado in ('onboarding','activo','en_renovacion')
                       and vc.dias_sin_chequeo > p.dias_sin_chequeo_alerta)                      as sin_chequeo
  from public.cs_v_clientes vc
  where vc.programa_id = p.id
) v on true
left join lateral (
  select count(*) filter (where x.estado in ('pendiente','en_proceso')) as pend,
         count(*) filter (where x.estado = 'entregada')                 as ent,
         count(*)                                                       as total
  from public.cs_devoluciones x where x.programa_id = p.id
) d on true
left join lateral (
  select count(*) filter (where x.estado = 'renovado')    as ren,
         count(*) filter (where x.estado = 'no_renovado') as noren
  from public.cs_renovaciones x where x.programa_id = p.id
) r on true
left join lateral (
  select count(*)                                  as n,
         avg(x.puntaje)                            as prom,
         count(*) filter (where x.puntaje >= 9)    as promotores,
         count(*) filter (where x.puntaje <= 6)    as detractores
  from public.cs_respuestas x
  where x.programa_id = p.id
    and x.puntaje is not null
    and x.created_at >= now() - interval '90 days'
) s on true;

-- ---------- cs_v_metricas_mensuales ----------
-- Una fila por programa y mes (hora de Buenos Aires) con al menos un evento.
create or replace view public.cs_v_metricas_mensuales
with (security_invoker = on) as
with ev as (
  select c.programa_id, date_trunc('month', c.fecha_inicio)::date as mes, 'alta'::text as k, null::numeric as v
  from public.cs_clientes c
  union all
  select r.programa_id,
         date_trunc('month', r.resultado_at at time zone 'America/Argentina/Buenos_Aires')::date,
         r.estado, null
  from public.cs_renovaciones r
  where r.estado in ('renovado','no_renovado') and r.resultado_at is not null
  union all
  select d.programa_id,
         date_trunc('month', d.entregada_at at time zone 'America/Argentina/Buenos_Aires')::date,
         'dev', extract(epoch from (d.entregada_at - d.solicitada_at)) / 3600.0
  from public.cs_devoluciones d
  where d.estado = 'entregada' and d.entregada_at is not null
  union all
  select x.programa_id,
         date_trunc('month', x.created_at at time zone 'America/Argentina/Buenos_Aires')::date,
         'resp', x.puntaje
  from public.cs_respuestas x
  where x.puntaje is not null
)
select
  programa_id,
  mes,
  count(*) filter (where k = 'alta')         as altas,
  count(*) filter (where k = 'renovado')     as renovados,
  count(*) filter (where k = 'no_renovado')  as no_renovados,
  count(*) filter (where k = 'dev')          as devoluciones_entregadas,
  round(avg(v) filter (where k = 'dev'), 1)  as horas_prom_entrega_devolucion,
  round(avg(v) filter (where k = 'resp'), 2) as satisfaccion_prom,
  count(*) filter (where k = 'resp')         as respuestas
from ev
group by programa_id, mes;

revoke all on table public.cs_v_clientes, public.cs_v_kpis_programa, public.cs_v_metricas_mensuales from anon;
revoke insert, update, delete
  on table public.cs_v_clientes, public.cs_v_kpis_programa, public.cs_v_metricas_mensuales from authenticated;
grant select on table public.cs_v_clientes, public.cs_v_kpis_programa, public.cs_v_metricas_mensuales to authenticated;


-- =====================================================================
-- 5. REALTIME
-- =====================================================================
-- Crea la publicación si no existe y agrega las tablas cs_ (menos
-- cs_integraciones) solo si no están. Si la publicación fuera FOR ALL
-- TABLES, no se puede (ni hace falta) agregar tablas: se avisa y se sigue.
do $$
declare
  t      text;
  v_all  boolean;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;

  select puballtables into v_all from pg_publication where pubname = 'supabase_realtime';
  if v_all then
    raise notice 'supabase_realtime es FOR ALL TABLES: no se agregan tablas (incluye cs_integraciones, ojo).';
    return;
  end if;

  foreach t in array array[
    'cs_programas','cs_clientes','cs_accionables','cs_devoluciones','cs_calls','cs_renovaciones',
    'cs_formularios','cs_respuestas','cs_chequeos','cs_historial','cs_alertas'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;


-- =====================================================================
-- 6. ALTA DE PROGRAMAS (config, no datos demo)
-- =====================================================================
-- Lee crm_clients (solo lectura). liam activo; el resto inactivo.
-- No pisa nada si ya existen.
insert into public.cs_programas (id, nombre, marca, activo)
select c.id,
       c.nombre,
       case when c.id = 'liam' then 'Blueprint Financiero' end,
       c.id = 'liam'
from public.crm_clients c
where c.id in ('liam','agus','teo','mauro','lucas')
on conflict (id) do nothing;

commit;


-- =====================================================================
-- 7. PRUEBA DE HUMO (no deja datos)
-- =====================================================================
-- Crea un cliente de prueba en 'liam', ejercita triggers y vista, y
-- después fuerza un error para deshacer TODO. Los resultados se juntan en
-- una variable (que sobrevive al rollback) y se vuelcan a una tabla temporal.
drop table if exists pg_temp.cs_smoke;
create temp table cs_smoke (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res       text[] := '{}';
  v_cli     uuid;
  v_ren     uuid;
  v_n       int;
  v_txt     text;
  v_fecha   date;
  v_arr     text[];
begin
  begin
    -- 1. fecha_fin por defecto (90 días)
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio)
    values ('liam', '__prueba_de_humo__', public.cs_hoy() - 10)
    returning id into v_cli;
    select fecha_fin - fecha_inicio into v_n from public.cs_clientes where id = v_cli;
    res := res || format('fecha_fin por defecto = inicio + 90|%s|dias=%s', v_n = 90, v_n);

    -- 2. call de onboarding automática
    select count(*) into v_n from public.cs_calls
    where cliente_id = v_cli and tipo = 'onboarding' and estado = 'pendiente_agendar';
    res := res || format('call de onboarding creada|%s|calls=%s', v_n = 1, v_n);

    -- 3. programa_id heredado del cliente
    insert into public.cs_accionables (cliente_id, responsable, titulo, vence)
    values (v_cli, 'bpf', 'prueba', public.cs_hoy() - 1);
    select programa_id into v_txt from public.cs_accionables where cliente_id = v_cli limit 1;
    res := res || format('programa_id heredado del cliente|%s|programa=%s', v_txt = 'liam', v_txt);

    -- 4. programa_id que no coincide se rechaza
    begin
      insert into public.cs_calls (programa_id, cliente_id, tipo) values ('agus', v_cli, 'otra');
      res := res || 'programa_id distinto rechazado|false|NO falló'::text;
    exception when others then
      res := res || format('programa_id distinto rechazado|true|%s', replace(sqlerrm, '|', '/'));
    end;

    -- 5. devolución entregada sin loom se rechaza
    begin
      insert into public.cs_devoluciones (cliente_id, titulo, estado) values (v_cli, 'prueba', 'entregada');
      res := res || 'entregada sin loom rechazada|false|NO falló'::text;
    exception when check_violation then
      res := res || 'entregada sin loom rechazada|true|check_violation'::text;
    end;

    -- 6. devolución con loom: entregada_at se completa
    insert into public.cs_devoluciones (cliente_id, titulo) values (v_cli, 'prueba 2');
    update public.cs_devoluciones set estado = 'entregada', loom_url = 'https://www.loom.com/share/abc'
    where cliente_id = v_cli and titulo = 'prueba 2';
    select count(*) into v_n from public.cs_devoluciones
    where cliente_id = v_cli and titulo = 'prueba 2' and entregada_at is not null;
    res := res || format('entregada_at seteado al entregar|%s|', v_n = 1);

    -- 7. semáforo rojo (onboarding 10 días sin agendar + accionable BPF vencido)
    select semaforo, motivos_semaforo into v_txt, v_arr from public.cs_v_clientes where id = v_cli;
    res := res || format('semaforo rojo en cs_v_clientes|%s|%s', v_txt = 'rojo',
                         replace(array_to_string(v_arr, '; '), '|', '/'));

    -- 8. renovación en_proceso -> cliente en_renovacion
    insert into public.cs_renovaciones (cliente_id) values (v_cli) returning id into v_ren;
    select estado into v_txt from public.cs_clientes where id = v_cli;
    res := res || format('renovación en_proceso -> cliente en_renovacion|%s|estado=%s', v_txt = 'en_renovacion', v_txt);

    -- 9. segunda renovación en_proceso se rechaza
    begin
      insert into public.cs_renovaciones (cliente_id) values (v_cli);
      res := res || 'solo una renovación en_proceso|false|NO falló'::text;
    exception when unique_violation then
      res := res || 'solo una renovación en_proceso|true|unique_violation'::text;
    end;

    -- 10. renovado -> cliente activo, fecha_fin nueva, contador +1
    update public.cs_renovaciones set estado = 'renovado', nueva_fecha_fin = public.cs_hoy() + 200 where id = v_ren;
    select estado, fecha_fin, renovaciones_count into v_txt, v_fecha, v_n from public.cs_clientes where id = v_cli;
    res := res || format('renovado -> activo + fecha_fin + contador|%s|estado=%s fin=%s count=%s',
                         v_txt = 'activo' and v_fecha = public.cs_hoy() + 200 and v_n = 1, v_txt, v_fecha, v_n);

    -- 11. chequeo actualiza ultimo_chequeo_at
    insert into public.cs_chequeos (cliente_id, nota) values (v_cli, 'prueba');
    select count(*) into v_n from public.cs_clientes where id = v_cli and ultimo_chequeo_at is not null;
    res := res || format('chequeo actualiza ultimo_chequeo_at|%s|', v_n = 1);

    -- 12. historial registró cambios de estado
    select count(*) into v_n from public.cs_historial
    where registro_id = v_cli and tabla = 'cs_clientes' and campo = 'estado';
    res := res || format('historial de estado del cliente|%s|filas=%s (esperado 3)', v_n = 3, v_n);

    -- 13. kpis del programa se calculan
    select count(*) into v_n from public.cs_v_kpis_programa where programa_id = 'liam';
    res := res || format('cs_v_kpis_programa devuelve liam|%s|', v_n = 1);

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s', replace(sqlerrm, '|', '/'));
    end if;
  end;

  insert into cs_smoke (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 8. QUERY DE CONTROL (una sola tabla de resultados; mirar la columna ok)
-- =====================================================================
with
tablas as (
  select c.relname::text as relname, c.relrowsecurity as rls
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'cs\_%'
),
pol as (
  select tablename, string_agg(cmd, ',' order by cmd) as cmds
  from pg_policies where schemaname = 'public' and tablename like 'cs\_%'
  group by tablename
),
esperadas(tabla, cmds) as (
  values ('cs_programas','DELETE,INSERT,SELECT,UPDATE'), ('cs_integraciones','ALL'),
         ('cs_clientes','DELETE,INSERT,SELECT,UPDATE'), ('cs_accionables','DELETE,INSERT,SELECT,UPDATE'),
         ('cs_devoluciones','DELETE,INSERT,SELECT,UPDATE'), ('cs_calls','DELETE,INSERT,SELECT,UPDATE'),
         ('cs_renovaciones','DELETE,INSERT,SELECT,UPDATE'), ('cs_formularios','DELETE,INSERT,SELECT,UPDATE'),
         ('cs_chequeos','DELETE,INSERT,SELECT,UPDATE'), ('cs_respuestas','DELETE,SELECT'),
         ('cs_historial','SELECT'), ('cs_alertas','DELETE,SELECT,UPDATE')
),
vistas as (
  select c.relname::text as relname, coalesce(array_to_string(c.reloptions, ','), '') as opts
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v' and c.relname like 'cs\_v\_%'
),
rt as (
  select tablename::text as tablename from pg_publication_tables
  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename like 'cs\_%'
),
anon_grants as (
  select count(*) as n from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public' and table_name like 'cs\_%'
),
helpers as (
  select p.proname::text as proname, p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('cs_hoy','cs_puede_ver','cs_puede_borrar')
)
select '01 tablas cs_' as control, 'cantidad' as objeto, '12' as esperado,
       (select count(*) from tablas)::text as obtenido, (select count(*) from tablas) = 12 as ok
union all
select '02 rls', t.relname, 'true', t.rls::text, t.rls from tablas t
union all
select '03 politicas', e.tabla, e.cmds, coalesce(p.cmds, '(ninguna)'), coalesce(p.cmds = e.cmds, false)
from esperadas e left join pol p on p.tablename = e.tabla
union all
select '04 vistas security_invoker', v.relname, 'security_invoker=on', v.opts,
       v.opts ~* 'security_invoker=(on|true|1)' from vistas v
union all
select '04 vistas security_invoker', 'cantidad', '3', (select count(*) from vistas)::text,
       (select count(*) from vistas) = 3
union all
select '05 realtime', 'tablas cs_ en supabase_realtime',
       case when (select puballtables from pg_publication where pubname = 'supabase_realtime')
            then 'FOR ALL TABLES' else '11 (sin cs_integraciones)' end,
       (select count(*) from rt)::text
         || case when exists (select 1 from rt where tablename = 'cs_integraciones') then ' (incluye cs_integraciones!)' else '' end,
       coalesce((select puballtables from pg_publication where pubname = 'supabase_realtime'), false)
         or ((select count(*) from rt) = 11 and not exists (select 1 from rt where tablename = 'cs_integraciones'))
union all
select '06 permisos anon', 'grants de anon en cs_*', '0', (select n from anon_grants)::text,
       (select n from anon_grants) = 0
union all
select '07 helpers security definer', h.proname, 'true', h.prosecdef::text, h.prosecdef from helpers h
union all
select '08 programas', 'filas en cs_programas', '5', (select count(*) from public.cs_programas)::text,
       (select count(*) from public.cs_programas) = 5
union all
select '08 programas', 'activos', 'liam', coalesce((select string_agg(id, ',') from public.cs_programas where activo), '(ninguno)'),
       coalesce((select string_agg(id, ',') from public.cs_programas where activo), '') = 'liam'
union all
select '09 crm intacto', 'crm_clients (antes 5)', '5', (select count(*) from public.crm_clients)::text,
       (select count(*) from public.crm_clients) = 5
union all
select '09 crm intacto', 'crm_members fundador (antes 1)', '1',
       (select count(*) from public.crm_members where rol = 'fundador')::text,
       (select count(*) from public.crm_members where rol = 'fundador') = 1
union all
select '09 crm intacto', 'crm_members total (comparar a mano)', '(sin dato previo)',
       (select count(*) from public.crm_members)::text, null
union all
select '09 crm intacto', 'políticas crm_* (antes 11)', '11',
       (select count(*) from pg_policies where schemaname = 'public' and tablename like 'crm\_%')::text,
       (select count(*) from pg_policies where schemaname = 'public' and tablename like 'crm\_%') = 11
union all
select '10 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke s
order by 1, 2;
