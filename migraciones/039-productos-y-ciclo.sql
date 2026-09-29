-- =====================================================================
-- 039-productos-y-ciclo.sql  —  Dystopia Producto: productos y ciclo del cliente
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
--
-- Qué hace:
--   - Catálogo de productos por programa (tabla nueva cs_productos:
--     programa_id, nombre, duracion_dias, activo, orden).
--       * cs_clientes.producto_id (nullable). cs_clientes.plan queda como
--         texto libre heredado, sin tocar.
--       * Alta con producto y sin fecha_fin: fecha_fin = fecha_inicio +
--         duración del producto (antes: la del programa). Si viene
--         fecha_fin explícita se respeta, igual que antes.
--       * cs_renovaciones.producto_id (nullable). Al cerrar como renovado
--         con producto y sin nueva_fecha_fin: nueva_fecha_fin = la mayor
--         entre la fecha_fin vigente del cliente (corrida por la pausa si
--         está pausado) y hoy, + duración del producto. El cliente queda
--         con ese producto.
--       * Seed de liam: los 5 productos de la planilla.
--   - Estado nuevo 'pausado' en cs_clientes + cs_clientes.pausado_desde.
--       * Mientras está pausado, dias_restantes / dias_transcurridos /
--         pct_programa quedan congelados en pausado_desde.
--       * No genera renovacion_proxima, programa_vencido, sin_chequeo ni
--         los avisos; el chequeo diario no lo finaliza; no cuenta como
--         activo en los KPIs (ya filtraban por onboarding/activo/en_renovacion).
--       * Semáforo nunca rojo: lo que lo pondría en rojo lo deja amarillo.
--       * Al volver a un estado vivo, fecha_fin se corre por los días
--         pausados (salvo que en el mismo update venga otra fecha_fin).
--   - Dos avisos de renovación: cs_programas.aviso_1_dias (21) y
--     aviso_2_dias (5); cs_clientes.aviso_1_at / aviso_2_at registran
--     cuándo se hizo cada uno. Alertas nuevas aviso_renovacion_1 y
--     aviso_renovacion_2. aviso_renovacion_dias sigue siendo el umbral del
--     semáforo y de renovacion_proxima, sin cambios.
--   - Offboarding: la plantilla de accionables acepta "disparo":
--     "inicio" (default, lo de siempre) | "cierre". Los de cierre se crean
--     cuando el cliente pasa a finalizado o baja. Seed de liam: sacar de
--     WhatsApp, sacar de Skool, pedir testimonio.
--   - cs_clientes.testimonio: sin_pedir | pitchiado | grabado | no_quiere.
--   - cs_calls (tipo renovacion): encargado, show_up, calificacion, resultado.
--   - cs_v_maestro suma al final: producto_id, producto, testimonio,
--     aviso_1_at, aviso_2_at, pausado_desde.
--
-- Toca objetos existentes (todo cs_*):
--   - CHECK de cs_clientes.estado (anónimo en 001): se reemplaza por uno
--     con 'pausado'.
--   - CHECK de cs_alertas.tipo (038): se reemplaza, + 2 tipos.
--   - cs_validar_plantilla (001): acepta "disparo".
--   - Funciones reescritas:
--       cs_tg_clientes_before          (001)  producto, pausa y reanudación
--       cs_tg_clientes_after_insert    (001)  solo ítems de disparo inicio
--       cs_aplicar_plantillas          (003)  solo ítems de disparo inicio
--       cs_tg_renovaciones_before      (037)  producto -> nueva_fecha_fin
--       cs_tg_renovaciones_after       (037)  producto, avisos, pausa, cierre
--       cs_cerrar_vencidos             (037)  no finaliza pausados
--       cs_generar_alertas             (038)  pausa, avisos, cierre vencido
--       cs_digest_diario               (038)  etiquetas de los tipos nuevos
--   - Triggers de historial de cs_clientes y cs_renovaciones: campos nuevos.
--   - Vistas: cs_v_clientes (mismas columnas, mismo orden) y cs_v_maestro
--     (columnas nuevas al final).
--   - Datos: seed de liam (productos + 3 ítems de cierre en su plantilla).
-- Nada crm_* / fin_* / ventas.
-- Es re-ejecutable (if not exists / create or replace / on conflict).
--
-- Estructura:
--   0. Foto de ANTES (semáforo, tasa, KPIs, columnas de cs_v_clientes)
--   1. cs_productos
--   2. cs_programas: avisos
--   3. cs_clientes: producto, pausa, avisos, testimonio
--   4. cs_renovaciones.producto_id y cs_calls (datos de la call de resell)
--   5. Plantilla: disparo inicio | cierre
--   6. Triggers de cs_clientes
--   7. Triggers de cs_renovaciones
--   8. Chequeo diario y alertas
--   9. Vistas: cs_v_clientes, cs_v_maestro
--  10. Permisos
--  11. Seed de liam
--  12. PRUEBA DE HUMO (crea datos, los verifica y los deshace)
--  13. QUERY DE CONTROL
-- =====================================================================


-- =====================================================================
-- 0. FOTO DE ANTES (fuera de la transacción, en tablas temporales)
-- =====================================================================
-- Se comparan en la query de control. Si la migración se corre dos
-- veces, la foto es la del estado ya migrado y la comparación sigue
-- valiendo.
drop table if exists pg_temp.cs_039_antes_sem;
create temp table cs_039_antes_sem as
  select id, semaforo, motivos_semaforo, dias_restantes, pct_programa from public.cs_v_clientes;

drop table if exists pg_temp.cs_039_antes_kpi;
create temp table cs_039_antes_kpi as
  select programa_id, tasa_renovacion, clientes_activos, por_vencer, clientes_rojo, sin_chequeo
  from public.cs_v_kpis_programa;

drop table if exists pg_temp.cs_039_antes_cols;
create temp table cs_039_antes_cols as
  select string_agg(column_name::text, ',' order by ordinal_position) as cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_v_clientes';

drop table if exists pg_temp.cs_039_antes_prog;
create temp table cs_039_antes_prog as
  select id, aviso_renovacion_dias, duracion_default_dias from public.cs_programas;

begin;

-- =====================================================================
-- 1. cs_productos
-- =====================================================================
-- Lo que se vende dentro de un programa, con su duración. activo solo
-- filtra el selector de la UI: un producto inactivo sigue valiendo para
-- los clientes y renovaciones que ya lo tienen. No se borra un producto
-- en uso (las FK no tienen cascade): se desactiva.
create table if not exists public.cs_productos (
  id             uuid primary key default gen_random_uuid(),
  programa_id    text not null references public.cs_programas(id) on delete cascade,
  nombre         text not null check (btrim(nombre) <> ''),
  duracion_dias  int  not null check (duracion_dias > 0),
  activo         boolean not null default true,
  orden          int  not null default 0,
  created_at     timestamptz not null default now(),
  constraint cs_productos_nombre_key unique (programa_id, nombre),
  -- destino de las FK compuestas: el producto tiene que ser del programa
  constraint cs_productos_id_programa_key unique (id, programa_id)
);

-- Mismo patrón que cs_programas: ven los que tienen acceso; escribe fundador.
alter table public.cs_productos enable row level security;
revoke all on table public.cs_productos from anon;
revoke truncate, references, trigger on table public.cs_productos from authenticated;
grant select, insert, update, delete on table public.cs_productos to authenticated;

drop policy if exists cs_select on public.cs_productos;
create policy cs_select on public.cs_productos for select to authenticated
  using (public.cs_puede_ver(programa_id));
drop policy if exists cs_insert on public.cs_productos;
create policy cs_insert on public.cs_productos for insert to authenticated
  with check (public.es_fundador());
drop policy if exists cs_update on public.cs_productos;
create policy cs_update on public.cs_productos for update to authenticated
  using (public.es_fundador()) with check (public.es_fundador());
drop policy if exists cs_delete on public.cs_productos;
create policy cs_delete on public.cs_productos for delete to authenticated
  using (public.es_fundador());


-- =====================================================================
-- 2. cs_programas: DOS AVISOS DE RENOVACIÓN
-- =====================================================================
-- aviso_renovacion_dias NO se toca: sigue siendo el umbral del semáforo,
-- de "por vencer" y de la alerta renovacion_proxima.
alter table public.cs_programas
  add column if not exists aviso_1_dias int not null default 21,
  add column if not exists aviso_2_dias int not null default 5;
alter table public.cs_programas drop constraint if exists cs_programas_avisos_chk;
alter table public.cs_programas add constraint cs_programas_avisos_chk
  check (aviso_2_dias >= 0 and aviso_1_dias > aviso_2_dias);


-- =====================================================================
-- 3. cs_clientes: PRODUCTO, PAUSA, AVISOS, TESTIMONIO
-- =====================================================================
alter table public.cs_clientes
  add column if not exists producto_id    uuid,
  add column if not exists pausado_desde  date,
  add column if not exists aviso_1_at     timestamptz,
  add column if not exists aviso_2_at     timestamptz,
  add column if not exists testimonio     text not null default 'sin_pedir';

comment on column public.cs_clientes.plan is
  'Texto libre heredado (antes de cs_productos). El producto vigente es producto_id.';
comment on column public.cs_clientes.pausado_desde is
  'Día en que se pausó. Solo con estado pausado. Al reanudar, fecha_fin se corre por hoy - pausado_desde.';
comment on column public.cs_clientes.aviso_1_at is
  'Cuándo se hizo el 1er aviso de renovación del ciclo actual (se limpia al renovar).';
comment on column public.cs_clientes.aviso_2_at is
  'Cuándo se hizo el 2do aviso de renovación del ciclo actual (se limpia al renovar).';

alter table public.cs_clientes drop constraint if exists cs_clientes_producto_fk;
alter table public.cs_clientes add constraint cs_clientes_producto_fk
  foreign key (producto_id, programa_id) references public.cs_productos (id, programa_id);
create index if not exists cs_clientes_producto_idx on public.cs_clientes (producto_id);

alter table public.cs_clientes drop constraint if exists cs_clientes_testimonio_chk;
alter table public.cs_clientes add constraint cs_clientes_testimonio_chk
  check (testimonio in ('sin_pedir','pitchiado','grabado','no_quiere'));

-- CHECK de estado. En 001 era inline sin nombre (cs_clientes_estado_check).
-- Se borra cualquier check de la tabla que liste los estados, por si
-- Postgres le dio otro nombre (y el propio, si se corre dos veces).
do $$
declare
  r record;
begin
  for r in
    select c.conname from pg_constraint c
    where c.conrelid = 'public.cs_clientes'::regclass and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ~ 'en_renovacion'
  loop
    execute format('alter table public.cs_clientes drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.cs_clientes add constraint cs_clientes_estado_chk
  check (estado in ('onboarding','activo','en_renovacion','pausado','finalizado','baja'));

-- pausado_desde si y solo si está pausado (el trigger lo completa y lo limpia).
alter table public.cs_clientes drop constraint if exists cs_clientes_pausa_chk;
alter table public.cs_clientes add constraint cs_clientes_pausa_chk
  check ((estado = 'pausado') = (pausado_desde is not null));


-- =====================================================================
-- 4. cs_renovaciones.producto_id Y DATOS DE LA CALL DE RESELL
-- =====================================================================
alter table public.cs_renovaciones add column if not exists producto_id uuid;
alter table public.cs_renovaciones drop constraint if exists cs_renovaciones_producto_fk;
alter table public.cs_renovaciones add constraint cs_renovaciones_producto_fk
  foreign key (producto_id, programa_id) references public.cs_productos (id, programa_id);
create index if not exists cs_renovaciones_producto_idx on public.cs_renovaciones (producto_id);

-- La call de resell (cs_calls tipo 'renovacion'). Todo nullable: las
-- calls viejas no lo tienen. "Qué pasó" = resultado (notas sigue siendo
-- la nota libre de siempre).
alter table public.cs_calls
  add column if not exists encargado     text,
  add column if not exists show_up       boolean,
  add column if not exists calificacion  text,
  add column if not exists resultado     text;

alter table public.cs_calls drop constraint if exists cs_calls_calificacion_chk;
alter table public.cs_calls add constraint cs_calls_calificacion_chk
  check (calificacion is null or calificacion in ('calificado','no_calificado'));

-- Solo en calls de renovación.
alter table public.cs_calls drop constraint if exists cs_calls_resell_solo_renovacion;
alter table public.cs_calls add constraint cs_calls_resell_solo_renovacion
  check (tipo = 'renovacion'
         or (encargado is null and show_up is null and calificacion is null and resultado is null));

-- show_up no puede contradecir el estado de la call.
alter table public.cs_calls drop constraint if exists cs_calls_show_up_chk;
alter table public.cs_calls add constraint cs_calls_show_up_chk
  check (show_up is null
         or (not (estado = 'no_show' and show_up) and not (estado = 'realizada' and not show_up)));


-- =====================================================================
-- 5. PLANTILLA: DISPARO inicio | cierre
-- =====================================================================
-- Igual que 001 + "disparo" opcional: 'inicio' (default: el ítem sale
-- a los dia_offset días de fecha_inicio, como siempre) o 'cierre' (sale
-- cuando el cliente pasa a finalizado o baja; vence = ese día +
-- vence_en_dias; dia_offset se ignora). Las plantillas existentes no
-- tienen disparo: todas quedan como 'inicio'.
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
         or coalesce(e->>'disparo', 'inicio') not in ('inicio', 'cierre')
    )
    and (select count(*) = count(distinct e->>'key') from jsonb_array_elements(p) e)
  end
$$;


-- =====================================================================
-- 6. TRIGGERS DE cs_clientes
-- =====================================================================

-- ---------- antes de guardar: fecha_fin, producto, pausa ----------
-- Igual que 001 (programa inmutable, fecha_inicio y fecha_fin por
-- defecto) con tres cambios:
--   - fecha_fin por defecto sale del producto si hay; si no, del programa.
--     Solo cuando viene null: cambiar el producto de un cliente existente
--     no le mueve la fecha.
--   - el producto tiene que ser del programa del cliente (la FK compuesta
--     también lo asegura; esto da un mensaje legible).
--   - pausa: al entrar a 'pausado' completa pausado_desde (hoy, o el que
--     venga); al salir a un estado vivo corre fecha_fin por los días
--     pausados y limpia pausado_desde. Si se reanuda a 'activo' con una
--     renovación abierta, queda 'en_renovacion'.
create or replace function public.cs_tg_clientes_before()
returns trigger language plpgsql set search_path = public
as $$
declare
  v_dur   int;
  v_prog  text;
begin
  if tg_op = 'UPDATE' and new.programa_id is distinct from old.programa_id then
    raise exception 'cs: no se puede cambiar el programa de un cliente' using errcode = '23514';
  end if;
  if new.fecha_inicio is null then
    new.fecha_inicio := public.cs_hoy();
  end if;

  -- producto
  if new.producto_id is not null
     and (tg_op = 'INSERT' or new.producto_id is distinct from old.producto_id) then
    select pr.programa_id into v_prog from public.cs_productos pr where pr.id = new.producto_id;
    if v_prog is null then
      raise exception 'cs: el producto % no existe', new.producto_id using errcode = '23503';
    elsif v_prog <> new.programa_id then
      raise exception 'cs: el producto es del programa %, no del programa del cliente (%)', v_prog, new.programa_id
        using errcode = '23514';
    end if;
  end if;

  if new.fecha_fin is null then
    if new.producto_id is not null then
      select pr.duracion_dias into v_dur from public.cs_productos pr where pr.id = new.producto_id;
    else
      select p.duracion_default_dias into v_dur from public.cs_programas p where p.id = new.programa_id;
    end if;
    new.fecha_fin := new.fecha_inicio + coalesce(v_dur, 90);
  end if;

  -- pausa
  if new.estado = 'pausado' then
    if tg_op = 'UPDATE' and old.estado <> 'pausado' then
      if old.estado in ('finalizado', 'baja') then
        raise exception 'cs: un cliente % no se puede pausar', old.estado using errcode = '23514';
      end if;
      new.pausado_desde := coalesce(new.pausado_desde, public.cs_hoy());
    elsif tg_op = 'INSERT' then
      new.pausado_desde := coalesce(new.pausado_desde, public.cs_hoy());
    end if;
    if new.pausado_desde > public.cs_hoy() then
      raise exception 'cs: pausado_desde (%) no puede ser futura', new.pausado_desde using errcode = '23514';
    end if;
    if new.pausado_desde < new.fecha_inicio then
      raise exception 'cs: pausado_desde (%) es anterior al inicio del programa (%)', new.pausado_desde, new.fecha_inicio
        using errcode = '23514';
    end if;

  elsif tg_op = 'UPDATE' and old.estado = 'pausado' then
    -- reanuda (o se cierra estando pausado: ahí no se corre nada)
    if new.estado in ('onboarding', 'activo', 'en_renovacion') then
      if new.fecha_fin is not distinct from old.fecha_fin then
        new.fecha_fin := old.fecha_fin + greatest(public.cs_hoy() - old.pausado_desde, 0);
      end if;
      if new.estado = 'activo' and exists (
           select 1 from public.cs_renovaciones r
           where r.cliente_id = new.id and public.cs_ren_abierta(r.estado)) then
        new.estado := 'en_renovacion';
      end if;
    end if;
    new.pausado_desde := null;

  else
    new.pausado_desde := null;
  end if;
  return new;
end;
$$;

-- ---------- al crear: call de onboarding + plantilla día 0 ----------
-- Igual que 001; solo toma los ítems de disparo 'inicio'.
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

  -- Plantilla de accionables: ítems de inicio con dia_offset = 0.
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
      and coalesce(e->>'disparo', 'inicio') = 'inicio'
      and coalesce((e->>'dia_offset')::int, 0) = 0
    on conflict (cliente_id, plantilla_key) do nothing;
  end if;
  return null;
end;
$$;

-- ---------- accionables de cierre (offboarding) ----------
-- Crea los ítems de disparo 'cierre' de la plantilla para un cliente
-- finalizado o de baja (si no lo está, no hace nada). plantilla_key =
-- 'cierre:<key>:<fecha_fin>': no duplica si se llama dos veces, y un
-- cliente que renueva y vuelve a cerrar más adelante tiene los suyos.
-- vence = hoy + vence_en_dias. La usan los triggers y la puede llamar la
-- importación (SQL Editor) para clientes que ya entran cerrados.
create or replace function public.cs_generar_accionables_cierre(p_cliente uuid)
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int;
begin
  with nuevos as (
    insert into public.cs_accionables
      (programa_id, cliente_id, responsable, titulo, descripcion, vence, origen, plantilla_key)
    select c.programa_id, c.id,
           e->>'responsable', e->>'titulo', nullif(e->>'descripcion', ''),
           public.cs_hoy() + (e->>'vence_en_dias')::int,
           'plantilla',
           'cierre:' || (e->>'key') || ':' || c.fecha_fin
    from public.cs_clientes c
    join public.cs_programas p on p.id = c.programa_id
    cross join lateral jsonb_array_elements(p.plantilla_accionables) e
    where c.id = p_cliente
      and c.estado in ('finalizado', 'baja')
      and e->>'disparo' = 'cierre'
    on conflict (cliente_id, plantilla_key) do nothing
    returning 1
  )
  select count(*) into v_n from nuevos;
  return v_n;
end;
$fn$;

-- ---------- al cerrarse el cliente: offboarding ----------
-- Pasa a finalizado o baja desde cualquier otro estado.
--   - baja: siempre.
--   - finalizado con una renovación abierta (vencido dentro de la gracia
--     del pipeline de resell): todavía no. Se generan cuando esa
--     renovación se cierra como no_renovado (cs_tg_renovaciones_after),
--     para no sacar del grupo a alguien que está renovando.
-- Solo en UPDATE: un cliente que se importa ya cerrado no dispara nada
-- (la importación decide con cs_generar_accionables_cierre).
create or replace function public.cs_tg_clientes_after_cierre()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.estado = 'baja' or not exists (
       select 1 from public.cs_renovaciones r
       where r.cliente_id = new.id and public.cs_ren_abierta(r.estado)) then
    perform public.cs_generar_accionables_cierre(new.id);
  end if;
  return null;
end;
$$;

create or replace trigger cs_trg_after_cierre
  after update of estado on public.cs_clientes
  for each row
  when (new.estado in ('finalizado', 'baja') and old.estado not in ('finalizado', 'baja'))
  execute function public.cs_tg_clientes_after_cierre();

-- ---------- historial ----------
-- Mismo trigger genérico de 001: 037 + producto, testimonio y avisos.
-- La pausa queda en 'estado' y la reanudación en 'fecha_fin'.
create or replace trigger cs_trg_historial
  after insert or update of estado, fecha_fin, prioridad, producto_id, testimonio, aviso_1_at, aviso_2_at
  on public.cs_clientes
  for each row execute function public.cs_tg_historial('estado', 'fecha_fin', 'prioridad', 'producto_id',
                                                       'testimonio', 'aviso_1_at', 'aviso_2_at');


-- =====================================================================
-- 7. TRIGGERS DE cs_renovaciones
-- =====================================================================

-- ---------- reglas antes de guardar ----------
-- Igual que 037 + producto:
--   - tiene que ser del programa; inmutable una vez cerrada como renovado.
--   - al cerrar como renovado con producto y sin nueva_fecha_fin:
--     nueva_fecha_fin = greatest(fecha_fin vigente, hoy) + duración.
--     "Vigente" = la del cliente, corrida por los días de pausa si está
--     pausado. Si viene nueva_fecha_fin explícita, manda esa.
-- El producto se puede elegir en cualquier estado (p. ej. en la propuesta).
create or replace function public.cs_tg_renovaciones_before()
returns trigger language plpgsql set search_path = public
as $$
declare
  v_prog  text;
  v_dur   int;
  v_base  date;
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
    if old.estado = 'renovado' and new.resell_producto is distinct from old.resell_producto then
      raise exception 'cs: no se puede cambiar el producto de una renovación ya cerrada. Para corregirla, borrala (fundador) y cargá una nueva'
        using errcode = '23514';
    end if;
    if old.estado = 'renovado' and new.producto_id is distinct from old.producto_id then
      raise exception 'cs: no se puede cambiar el producto de una renovación ya cerrada. Para corregirla, borrala (fundador) y cargá una nueva'
        using errcode = '23514';
    end if;
  end if;

  if new.estado = 'renovado' and new.resell_producto is null then
    raise exception 'cs: para cerrar como renovado indicá qué compró (mismo_programa, upgrade, downgrade u otro)'
      using errcode = '23514';
  end if;
  if new.estado <> 'renovado' and new.resell_producto is not null then
    raise exception 'cs: el producto solo se carga al cerrar como renovado (estado actual: %)', new.estado
      using errcode = '23514';
  end if;

  -- producto del catálogo (programa_id ya lo completó cs_trg_10_programa)
  if new.producto_id is not null
     and (tg_op = 'INSERT' or new.producto_id is distinct from old.producto_id) then
    select pr.programa_id into v_prog from public.cs_productos pr where pr.id = new.producto_id;
    if v_prog is null then
      raise exception 'cs: el producto % no existe', new.producto_id using errcode = '23503';
    elsif v_prog <> new.programa_id then
      raise exception 'cs: el producto es del programa %, no del de la renovación (%)', v_prog, new.programa_id
        using errcode = '23514';
    end if;
  end if;

  -- nueva_fecha_fin desde el producto
  if new.estado = 'renovado' and new.nueva_fecha_fin is null and new.producto_id is not null
     and (tg_op = 'INSERT' or old.estado <> 'renovado') then
    select pr.duracion_dias into v_dur from public.cs_productos pr where pr.id = new.producto_id;
    select greatest(c.fecha_fin
                      + case when c.estado = 'pausado'
                             then greatest(public.cs_hoy() - c.pausado_desde, 0) else 0 end,
                    public.cs_hoy())
      into v_base
    from public.cs_clientes c where c.id = new.cliente_id;
    new.nueva_fecha_fin := v_base + v_dur;
  end if;

  if new.estado in ('renovado','no_renovado') then
    if tg_op = 'INSERT' then
      new.resultado_at := coalesce(new.resultado_at, now());
    elsif public.cs_ren_abierta(old.estado) then
      new.resultado_at := now();
    end if;
  else
    new.resultado_at := null;
  end if;
  return new;
end;
$$;

-- ---------- efecto sobre el cliente ----------
-- Igual que 037 con cuatro cambios:
--   - abrir / mover el pipeline no despausa a un cliente pausado.
--   - renovado: el cliente queda con el producto de la renovación (si
--     trae) y los dos avisos se limpian (arranca un ciclo nuevo; lo
--     anterior queda en cs_historial).
--   - no_renovado: si el cliente ya está cerrado (vencido en la gracia,
--     o se cerró recién), genera el offboarding.
create or replace function public.cs_tg_renovaciones_after()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.estado = old.estado then
    return null;
  end if;

  if public.cs_ren_abierta(new.estado) then
    -- Un cliente ya finalizado por vencimiento sigue finalizado mientras
    -- dura la gracia del pipeline: si no, cada cambio de etapa lo pasaría
    -- a en_renovacion y el chequeo diario lo volvería a finalizar.
    -- Un cliente pausado sigue pausado.
    update public.cs_clientes
       set estado = 'en_renovacion'
     where id = new.cliente_id and estado not in ('en_renovacion','baja','pausado')
       and not (estado = 'finalizado' and fecha_fin < public.cs_hoy());

  elsif new.estado = 'renovado' then
    update public.cs_clientes
       set estado = 'activo',
           fecha_fin = new.nueva_fecha_fin,
           renovaciones_count = renovaciones_count + 1,
           producto_id = coalesce(new.producto_id, producto_id),
           aviso_1_at = null,
           aviso_2_at = null
     where id = new.cliente_id;

  elsif new.estado = 'no_renovado' then
    -- Vuelve a 'activo' hasta que venza fecha_fin; si ya venció, pasa directo a 'finalizado'.
    update public.cs_clientes
       set estado = case when fecha_fin < public.cs_hoy() then 'finalizado' else 'activo' end
     where id = new.cliente_id and estado = 'en_renovacion';
    -- offboarding (no duplica lo que ya haya creado cs_trg_after_cierre)
    if exists (select 1 from public.cs_clientes c
               where c.id = new.cliente_id and c.estado in ('finalizado', 'baja')) then
      perform public.cs_generar_accionables_cierre(new.cliente_id);
    end if;
  end if;
  return null;
end;
$$;

-- ---------- historial: + producto_id ----------
create or replace trigger cs_trg_historial
  after insert or update of estado, resell_producto, producto_id on public.cs_renovaciones
  for each row execute function public.cs_tg_historial('estado', 'resell_producto', 'producto_id');


-- =====================================================================
-- 8. CHEQUEO DIARIO Y ALERTAS
-- =====================================================================

-- ---------- cs_aplicar_plantillas ----------
-- Igual que 003; solo ítems de disparo 'inicio'. Un pausado no recibe
-- ítems (ya no estaba en la lista de estados vivos); al reanudar recibe
-- los que se le hayan pasado.
create or replace function public.cs_aplicar_plantillas()
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int;
begin
  with nuevos as (
    insert into public.cs_accionables
      (programa_id, cliente_id, responsable, titulo, descripcion, vence, origen, plantilla_key)
    select c.programa_id,
           c.id,
           e->>'responsable',
           e->>'titulo',
           nullif(e->>'descripcion', ''),
           -- mismo criterio que el seed 002: inicio + dia_offset + vence_en_dias
           -- (null si al ítem le falta alguno de los dos: son opcionales)
           c.fecha_inicio + (e->>'dia_offset')::int + (e->>'vence_en_dias')::int,
           'plantilla',
           e->>'key'
    from public.cs_clientes c
    join public.cs_programas p on p.id = c.programa_id
    cross join lateral jsonb_array_elements(p.plantilla_accionables) e
    where c.estado in ('onboarding', 'activo', 'en_renovacion')
      and coalesce(e->>'disparo', 'inicio') = 'inicio'
      and coalesce((e->>'dia_offset')::int, 0) <= public.cs_hoy() - c.fecha_inicio
    on conflict (cliente_id, plantilla_key) do nothing
    returning 1
  )
  select count(*) into v_n from nuevos;
  return v_n;
end;
$fn$;

-- ---------- cs_cerrar_vencidos ----------
-- Igual que 037. Único cambio: un pausado no se finaliza (sus días no
-- corren; fecha_fin se corre al reanudar).
create or replace function public.cs_cerrar_vencidos()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_cli int;
  v_ren int;
begin
  -- 1. clientes vencidos -> finalizado
  with cerrados as (
    update public.cs_clientes c
       set estado = 'finalizado'
     where c.fecha_fin < public.cs_hoy()
       and c.estado not in ('finalizado', 'baja', 'pausado')
       and not exists (
         select 1 from public.cs_renovaciones r
         where r.cliente_id = c.id
           and r.estado = 'renovado'
           and r.nueva_fecha_fin >= public.cs_hoy()
       )
    returning 1
  )
  select count(*) into v_cli from cerrados;

  -- 2. renovaciones abiertas de clientes ya cerrados y fuera de la gracia -> no_renovado
  with cerradas as (
    update public.cs_renovaciones r
       set estado = 'no_renovado',
           motivo = 'Vencido sin respuesta'
     where public.cs_ren_abierta(r.estado)
       and exists (
         select 1 from public.cs_clientes c
         join public.cs_programas p on p.id = c.programa_id
         where c.id = r.cliente_id
           and c.fecha_fin + p.resell_gracia_dias < public.cs_hoy()
           and c.estado in ('finalizado', 'baja')
       )
    returning 1
  )
  select count(*) into v_ren from cerradas;

  return jsonb_build_object('clientes_finalizados', v_cli,
                            'renovaciones_cerradas', v_ren);
end;
$fn$;

-- ---------- CHECK de cs_alertas.tipo ----------
-- Se busca por definición (el de 038) y se reemplaza.
do $$
declare
  r record;
begin
  for r in
    select c.conname from pg_constraint c
    where c.conrelid = 'public.cs_alertas'::regclass and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ~ 'sin_chequeo'
  loop
    execute format('alter table public.cs_alertas drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.cs_alertas add constraint cs_alertas_tipo_check
  check (tipo in ('renovacion_proxima','devolucion_vencida','onboarding_demorado',
                  'accionable_bpf_vencido','sin_chequeo','satisfaccion_baja',
                  'programa_vencido','proximo_contacto_vencido',
                  'aviso_renovacion_1','aviso_renovacion_2'));

-- ---------- cs_generar_alertas ----------
-- Igual que 038 con tres cambios:
--   - pausado: no genera renovacion_proxima, programa_vencido, sin_chequeo
--     ni avisos (y las que tenía abiertas se resuelven solas). Sigue
--     generando las de trabajo concreto: devoluciones, accionables,
--     onboarding, próximo contacto.
--   - aviso_renovacion_1: aviso_2_dias < días restantes <= aviso_1_dias
--     y aviso_1_at vacío. aviso_renovacion_2: 0 <= días restantes <=
--     aviso_2_dias y aviso_2_at vacío. Clave con fecha_fin: un ciclo
--     nuevo (renovación o reanudación) avisa de nuevo. Se resuelven al
--     registrar el aviso o al salir de la ventana.
--   - accionable_bpf_vencido también para los ítems de cierre de clientes
--     finalizados o de baja (el offboarding no se tiene que perder). Los
--     clientes cerrados antes de 039 no tienen ítems de cierre: no cambia
--     nada para ellos.
create or replace function public.cs_generar_alertas()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_creadas   int;
  v_resueltas int;
begin
  with base as (
    select c.id                             as cliente_id,
           c.programa_id,
           c.estado,
           c.fecha_inicio,
           c.fecha_fin,
           c.aviso_1_at,
           c.aviso_2_at,
           p.aviso_renovacion_dias,
           p.aviso_1_dias,
           p.aviso_2_dias,
           p.sla_devolucion_horas,
           p.sla_onboarding_dias,
           p.dias_sin_chequeo_alerta,
           c.fecha_fin - public.cs_hoy()    as dias_restantes,
           public.cs_hoy() - c.fecha_inicio as dias_transcurridos,
           (coalesce(c.ultimo_chequeo_at, c.created_at)
              at time zone 'America/Argentina/Buenos_Aires')::date as base_chequeo
    from public.cs_clientes c
    join public.cs_programas p on p.id = c.programa_id
    -- un cliente finalizado o dado de baja no genera trabajo: al salir de
    -- este conjunto, sus alertas abiertas se resuelven solas más abajo.
    -- (excepción: los accionables de cierre, rama aparte)
    where c.estado not in ('finalizado', 'baja')
  ),
  estado_ren as (
    select b.cliente_id,
           (select r.estado
              from public.cs_renovaciones r
             where r.cliente_id = b.cliente_id
             -- si hay una abierta manda esa; si no, la más reciente (igual que cs_v_clientes)
             order by public.cs_ren_abierta(r.estado) desc, r.iniciada_at desc
             limit 1) as renovacion_estado
    from base b
  ),
  estado_onb as (
    select b.cliente_id,
           (select k.estado
              from public.cs_calls k
             where k.cliente_id = b.cliente_id and k.tipo = 'onboarding'
             order by k.created_at desc
             limit 1) as onboarding_estado
    from base b
  ),
  ult_seg as (
    select b.cliente_id, s.id as seguimiento_id, s.proximo_contacto
    from base b
    cross join lateral (
      select x.id, x.proximo_contacto
      from public.cs_seguimientos x
      where x.cliente_id = b.cliente_id
      order by x.fecha desc, x.created_at desc
      limit 1
    ) s
  ),
  vigentes as (
    -- renovacion_proxima: entró en la ventana de aviso y nadie inició la renovación
    select b.programa_id,
           b.cliente_id,
           'renovacion_proxima'::text as tipo,
           format('Vence en %s día(s) sin renovación iniciada', b.dias_restantes) as mensaje,
           'renovacion_proxima:' || b.cliente_id || ':' || b.fecha_fin as clave_dedupe
    from base b
    join estado_ren r on r.cliente_id = b.cliente_id
    where b.estado <> 'pausado'
      and b.dias_restantes >= 0
      and b.dias_restantes <= b.aviso_renovacion_dias
      and not public.cs_ren_abierta(r.renovacion_estado)
      and coalesce(r.renovacion_estado, '') <> 'no_renovado'

    union all
    -- programa_vencido: red de seguridad. Si corrió el chequeo completo,
    -- cs_cerrar_vencidos ya finalizó a estos clientes y esto no dispara.
    -- Si aparece, es un cliente vencido que no se pudo cerrar.
    select b.programa_id,
           b.cliente_id,
           'programa_vencido',
           format('Programa vencido hace %s día(s) y el cliente sigue abierto', -b.dias_restantes),
           'programa_vencido:' || b.cliente_id || ':' || b.fecha_fin
    from base b
    where b.estado <> 'pausado'
      and b.dias_restantes < 0

    union all
    -- aviso_renovacion_1: primer aviso al cliente, pendiente
    select b.programa_id,
           b.cliente_id,
           'aviso_renovacion_1',
           format('Hacer el 1er aviso de renovación: vence en %s día(s)', b.dias_restantes),
           'aviso_renovacion_1:' || b.cliente_id || ':' || b.fecha_fin
    from base b
    where b.estado <> 'pausado'
      and b.aviso_1_at is null
      and b.dias_restantes > b.aviso_2_dias
      and b.dias_restantes <= b.aviso_1_dias

    union all
    -- aviso_renovacion_2: segundo aviso al cliente, pendiente
    select b.programa_id,
           b.cliente_id,
           'aviso_renovacion_2',
           format('Hacer el 2do aviso de renovación: vence en %s día(s)', b.dias_restantes),
           'aviso_renovacion_2:' || b.cliente_id || ':' || b.fecha_fin
    from base b
    where b.estado <> 'pausado'
      and b.aviso_2_at is null
      and b.dias_restantes >= 0
      and b.dias_restantes <= b.aviso_2_dias

    union all
    -- devolucion_vencida: una por devolución fuera del SLA
    select b.programa_id,
           b.cliente_id,
           'devolucion_vencida',
           format('Devolución "%s" fuera del SLA de %s h', d.titulo, b.sla_devolucion_horas),
           'devolucion_vencida:' || d.id
    from base b
    join public.cs_devoluciones d on d.cliente_id = b.cliente_id
    where d.estado in ('pendiente', 'en_proceso')
      and d.solicitada_at + make_interval(hours => b.sla_devolucion_horas) < now()

    union all
    -- onboarding_demorado: la call de onboarding sigue sin agendar
    select b.programa_id,
           b.cliente_id,
           'onboarding_demorado',
           format('Onboarding sin agendar hace %s día(s)', b.dias_transcurridos),
           'onboarding_demorado:' || b.cliente_id || ':' || b.fecha_inicio
    from base b
    join estado_onb o on o.cliente_id = b.cliente_id
    where o.onboarding_estado = 'pendiente_agendar'
      and b.dias_transcurridos > b.sla_onboarding_dias

    union all
    -- accionable_bpf_vencido: una por accionable del equipo vencido
    select b.programa_id,
           b.cliente_id,
           'accionable_bpf_vencido',
           format('Accionable BPF vencido: %s (vencía el %s)', a.titulo, a.vence),
           'accionable_bpf_vencido:' || a.id
    from base b
    join public.cs_accionables a on a.cliente_id = b.cliente_id
    where a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence < public.cs_hoy()

    union all
    -- accionable_bpf_vencido de offboarding: clientes cerrados, ítems de cierre
    select c.programa_id,
           c.id,
           'accionable_bpf_vencido',
           format('Accionable BPF vencido: %s (vencía el %s)', a.titulo, a.vence),
           'accionable_bpf_vencido:' || a.id
    from public.cs_clientes c
    join public.cs_accionables a on a.cliente_id = c.id
    where c.estado in ('finalizado', 'baja')
      and a.plantilla_key like 'cierre:%'
      and a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence < public.cs_hoy()

    union all
    -- sin_chequeo: una por racha sin chequear (la clave cambia con cada chequeo)
    select b.programa_id,
           b.cliente_id,
           'sin_chequeo',
           format('Sin chequeo hace %s día(s)', public.cs_hoy() - b.base_chequeo),
           'sin_chequeo:' || b.cliente_id || ':' || b.base_chequeo
    from base b
    where b.estado <> 'pausado'
      and public.cs_hoy() - b.base_chequeo > b.dias_sin_chequeo_alerta

    union all
    -- proximo_contacto_vencido: una por seguimiento cuyo próximo contacto
    -- pasó sin que se cargara otro seguimiento después
    select b.programa_id,
           b.cliente_id,
           'proximo_contacto_vencido',
           format('Próximo contacto vencido hace %s día(s) (era el %s)',
                  public.cs_hoy() - s.proximo_contacto, to_char(s.proximo_contacto, 'DD/MM/YYYY')),
           'proximo_contacto_vencido:' || s.seguimiento_id
    from base b
    join ult_seg s on s.cliente_id = b.cliente_id
    where s.proximo_contacto < public.cs_hoy()
  ),
  creadas as (
    insert into public.cs_alertas (programa_id, cliente_id, tipo, mensaje, clave_dedupe)
    select v.programa_id, v.cliente_id, v.tipo, v.mensaje, v.clave_dedupe
    from vigentes v
    on conflict (clave_dedupe) do nothing
    returning 1
  ),
  resueltas as (
    update public.cs_alertas a
       set resuelta = true          -- resuelta_at lo completa cs_tg_alertas_before
     where a.resuelta = false
       and a.tipo in ('renovacion_proxima', 'devolucion_vencida', 'onboarding_demorado',
                      'accionable_bpf_vencido', 'sin_chequeo', 'programa_vencido',
                      'proximo_contacto_vencido', 'aviso_renovacion_1', 'aviso_renovacion_2')
       and not exists (select 1 from vigentes v where v.clave_dedupe = a.clave_dedupe)
    returning 1
  )
  select (select count(*) from creadas), (select count(*) from resueltas)
    into v_creadas, v_resueltas;

  return jsonb_build_object('creadas', v_creadas, 'resueltas', v_resueltas);
end;
$fn$;

-- ---------- cs_digest_diario ----------
-- Igual que 038. Único cambio: etiquetas de aviso_renovacion_1 y _2.
create or replace function public.cs_digest_diario(p_enviar boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r        record;
  k        record;
  v_ids    uuid[];
  v_conteo text;
  v_total  int;
  v_txt    text;
  v_id     bigint;
  v_envios jsonb := '[]'::jsonb;
  v_marcadas int := 0;
begin
  for r in
    select p.id, p.nombre, p.aviso_renovacion_dias
    from public.cs_programas p
    join public.cs_integraciones i on i.programa_id = p.id
    where p.activo and i.discord_activo and i.discord_webhook_url is not null
    order by p.id
  loop
    select * into k from public.cs_v_kpis_programa v where v.programa_id = r.id;

    select coalesce(array_agg(a.id), '{}'), count(*)
      into v_ids, v_total
    from public.cs_alertas a
    where a.programa_id = r.id
      and not a.resuelta
      and a.notificada_discord_at is null;

    -- "3 devoluciones fuera de SLA, 2 onboarding demorados": de más a menos.
    select string_agg(
             x.n || ' ' || case x.tipo
               when 'renovacion_proxima'     then 'por vencer sin renovación iniciada'
               when 'programa_vencido'       then case when x.n = 1 then 'programa vencido sin cerrar' else 'programas vencidos sin cerrar' end
               when 'devolucion_vencida'     then case when x.n = 1 then 'devolución fuera de SLA' else 'devoluciones fuera de SLA' end
               when 'onboarding_demorado'    then case when x.n = 1 then 'onboarding demorado' else 'onboarding demorados' end
               when 'accionable_bpf_vencido' then case when x.n = 1 then 'accionable BPF vencido' else 'accionables BPF vencidos' end
               when 'sin_chequeo'            then 'sin chequeo'
               when 'satisfaccion_baja'      then case when x.n = 1 then 'satisfacción baja' else 'satisfacciones bajas' end
               when 'proximo_contacto_vencido' then case when x.n = 1 then 'próximo contacto vencido' else 'próximos contactos vencidos' end
               when 'aviso_renovacion_1'     then case when x.n = 1 then '1er aviso de renovación pendiente' else '1eros avisos de renovación pendientes' end
               when 'aviso_renovacion_2'     then case when x.n = 1 then '2do aviso de renovación pendiente' else '2dos avisos de renovación pendientes' end
               else x.tipo
             end, ', ' order by x.n desc, x.tipo)
      into v_conteo
    from (
      select a.tipo, count(*) as n
      from public.cs_alertas a
      where a.id = any (v_ids)
      group by a.tipo
    ) x;

    v_txt := concat_ws(E'\n',
      format('**Producto · %s** — %s', r.nombre, to_char(public.cs_hoy(), 'DD/MM/YYYY')),
      format('Activos: %s | Rojo: %s | Amarillo: %s',
             coalesce(k.clientes_activos, 0), coalesce(k.clientes_rojo, 0), coalesce(k.clientes_amarillo, 0)),
      format('Devoluciones pendientes: %s (%s%%) | Vencidas SLA: %s',
             coalesce(k.dev_pendientes, 0), coalesce(k.pct_dev_pendientes, 0), coalesce(k.dev_vencidas_sla, 0)),
      format('Onboarding pendientes: %s', coalesce(k.onboarding_pendientes, 0)),
      format('Por vencer (%sd): %s | Renovaciones en proceso: %s',
             r.aviso_renovacion_dias, coalesce(k.por_vencer, 0), coalesce(k.en_renovacion, 0)),
      'Nuevas alertas: ' || coalesce(v_conteo, 'ninguna'));

    v_id := public.cs_discord_post(r.id, 'digest', v_txt, p_enviar);

    if v_id is not null and v_total > 0 then
      update public.cs_alertas set notificada_discord_at = now() where id = any (v_ids);
      v_marcadas := v_marcadas + v_total;
    end if;

    v_envios := v_envios || jsonb_build_object('programa_id', r.id, 'envio_id', v_id, 'alertas', v_total);
  end loop;

  return jsonb_build_object('programas', jsonb_array_length(v_envios),
                            'alertas_notificadas', v_marcadas,
                            'envios', v_envios,
                            'corrido_at', now());
end;
$fn$;


-- =====================================================================
-- 9. VISTAS (security_invoker = on)
-- =====================================================================

-- ---------- cs_v_clientes ----------
-- Igual que 037 (mismas columnas, mismo orden) con dos cambios, ambos
-- solo para clientes pausados (para el resto da exactamente lo mismo):
--   - "hoy" del cliente = pausado_desde: dias_restantes,
--     dias_transcurridos y pct_programa quedan congelados.
--   - no suma renovación ni sin chequeo al semáforo, y lo que lo pondría
--     en rojo (devolución fuera de SLA, accionable BPF vencido,
--     onboarding sin agendar) lo deja amarillo.
create or replace view public.cs_v_clientes
with (security_invoker = on) as
with m as (
  select
    c.id as cliente_id,
    c.estado as estado_cliente,
    p.aviso_renovacion_dias,
    p.sla_onboarding_dias,
    p.dias_sin_chequeo_alerta,
    c.fecha_fin - h.hoy     as dias_restantes,
    h.hoy - c.fecha_inicio  as dias_transcurridos,
    least(100, greatest(0, round(100.0 * (h.hoy - c.fecha_inicio)
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
  cross join lateral (
    select case when c.estado = 'pausado'
                then least(public.cs_hoy(), coalesce(c.pausado_desde, public.cs_hoy()))
                else public.cs_hoy() end as hoy
  ) h
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
    -- si hay una abierta, manda esa; si no, la más reciente
    select x.estado from public.cs_renovaciones x
    where x.cliente_id = c.id
    order by public.cs_ren_abierta(x.estado) desc, x.iniciada_at desc
    limit 1
  ) r on true
),
f as (
  select m.*,
    (m.estado_cliente = 'pausado')                                                 as pausado,
    (m.dev_vencidas_sla > 0)                                                       as r_dev,
    (m.acc_bpf_vencidos > 0)                                                       as r_acc,
    (m.onboarding_estado = 'pendiente_agendar'
       and m.dias_transcurridos > m.sla_onboarding_dias)                           as r_onb,
    (m.dias_restantes <= m.aviso_renovacion_dias
       and m.estado_cliente not in ('finalizado','baja','pausado')
       and not public.cs_ren_abierta(m.renovacion_estado)
       and coalesce(m.renovacion_estado, '') <> 'no_renovado')                     as r_ren,
    (m.dias_restantes <= m.aviso_renovacion_dias
       and m.estado_cliente not in ('finalizado','baja','pausado')
       and public.cs_ren_abierta(m.renovacion_estado))                             as a_ren,
    (m.estado_cliente not in ('finalizado','baja','pausado')
       and m.dias_sin_chequeo > m.dias_sin_chequeo_alerta)                         as a_chq,
    (m.acc_cliente_vencidos > 0)                                                   as a_acc,
    (m.dev_pendientes > m.dev_vencidas_sla)                                        as a_dev
  from m
)
select
  c.id,
  c.programa_id,
  c.nombre,
  c.email,
  c.telefono,
  c.fecha_inicio,
  c.fecha_fin,
  c.estado,
  c.etapa,
  c.responsable,
  c.plan,
  c.notas,
  c.token_publico,
  c.ultimo_chequeo_at,
  c.renovaciones_count,
  c.created_at,
  c.updated_at,
  c.created_by,
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
    when not f.pausado and (f.r_dev or f.r_acc or f.r_onb or f.r_ren) then 'rojo'
    when f.r_dev or f.r_acc or f.r_onb or f.r_ren
      or f.a_ren or f.a_chq or f.a_acc or f.a_dev then 'amarillo'
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

-- ---------- cs_v_maestro ----------
-- Igual que 038, con 6 columnas nuevas AL FINAL (create or replace view
-- no deja insertarlas en el medio): producto (id y nombre), testimonio,
-- los dos avisos y pausado_desde.
create or replace view public.cs_v_maestro
with (security_invoker = on) as
select
  -- identidad
  v.id,
  v.programa_id,
  v.nombre,
  v.email,
  v.telefono,
  v.plan,
  -- editables por el CSM
  v.responsable,
  c.prioridad,
  c.proxima_accion,
  c.proxima_accion_fecha,
  c.nota_csm,
  v.etapa,
  v.estado,
  v.fecha_inicio,
  v.fecha_fin,
  -- calculados (cs_v_clientes)
  v.semaforo,
  v.motivos_semaforo,
  v.dias_restantes,
  v.pct_programa,
  v.acc_bpf_pendientes,
  v.acc_bpf_vencidos,
  v.acc_cliente_pendientes,
  v.acc_cliente_vencidos,
  v.dev_pendientes,
  v.dev_vencidas_sla,
  v.ultimo_chequeo_at,
  v.dias_sin_chequeo,
  v.renovaciones_count,
  -- renovación vigente
  r.id               as renovacion_id,
  r.estado           as renovacion_estado,
  r.resell_producto  as renovacion_producto,
  r.iniciada_at      as renovacion_iniciada_at,
  r.resultado_at     as renovacion_resultado_at,
  r.nueva_fecha_fin  as renovacion_nueva_fecha_fin,
  r.motivo           as renovacion_motivo,
  v.updated_at,
  -- último seguimiento (038)
  s.fecha            as ultimo_seguimiento_fecha,
  s.avance           as ultimo_seguimiento_avance,
  s.proximo_contacto,
  coalesce(s.proximo_contacto < public.cs_hoy()
           and v.estado not in ('finalizado', 'baja'), false) as proximo_contacto_vencido,
  -- producto y ciclo (039)
  c.producto_id,
  pr.nombre          as producto,
  c.testimonio,
  c.aviso_1_at,
  c.aviso_2_at,
  c.pausado_desde
from public.cs_v_clientes v
join public.cs_clientes c on c.id = v.id
left join public.cs_productos pr on pr.id = c.producto_id
left join lateral (
  select x.id, x.estado, x.resell_producto, x.iniciada_at, x.resultado_at, x.nueva_fecha_fin, x.motivo
  from public.cs_renovaciones x
  where x.cliente_id = v.id
  order by public.cs_ren_abierta(x.estado) desc, x.iniciada_at desc
  limit 1
) r on true
left join lateral (
  select y.fecha, y.avance, y.proximo_contacto
  from public.cs_seguimientos y
  where y.cliente_id = v.id
  order by y.fecha desc, y.created_at desc
  limit 1
) s on true;


-- =====================================================================
-- 10. PERMISOS
-- =====================================================================
-- create or replace conserva los permisos de lo que ya existía. Solo
-- hace falta darlos en lo nuevo; las vistas se repiten por las dudas.
revoke all on table public.cs_v_maestro from anon;
revoke insert, update, delete on table public.cs_v_maestro from authenticated;
grant select on table public.cs_v_maestro to authenticated;

-- Funciones de trigger y el helper de cierre: nadie las llama desde la UI.
-- cs_generar_accionables_cierre la corre la importación en el SQL Editor.
revoke all on function public.cs_tg_clientes_after_cierre() from public, anon, authenticated;
revoke all on function public.cs_generar_accionables_cierre(uuid) from public, anon, authenticated;


-- =====================================================================
-- 11. SEED DE liam
-- =====================================================================
-- Productos de la planilla de BPF. Si liam no existe (base de pruebas),
-- no inserta nada. on conflict: re-ejecutable y no pisa una duración
-- que ya se haya corregido a mano.
insert into public.cs_productos (programa_id, nombre, duracion_dias, orden)
select p.id, x.nombre, x.dias, x.orden
from public.cs_programas p
cross join (values
  ('BPF 1-1 4 Meses',     120, 1),
  ('BPF 1-1 6 Meses',     180, 2),
  ('BPF 1-1 12 Meses',    365, 3),
  ('BPF Grupal',          120, 4),
  ('Gestión de Capital',  365, 5)
) as x(nombre, dias, orden)
where p.id = 'liam'
on conflict (programa_id, nombre) do nothing;

-- Offboarding de liam: se agregan al final de su plantilla los ítems
-- que falten (por key). No toca los ítems que ya tiene.
update public.cs_programas p
   set plantilla_accionables = p.plantilla_accionables || coalesce((
         select jsonb_agg(i order by o)
         from jsonb_array_elements('[
           {"key":"cierre_whatsapp",   "titulo":"Sacar del grupo de WhatsApp", "responsable":"bpf", "disparo":"cierre", "dia_offset":0, "vence_en_dias":2},
           {"key":"cierre_skool",      "titulo":"Sacar de Skool",              "responsable":"bpf", "disparo":"cierre", "dia_offset":0, "vence_en_dias":2},
           {"key":"cierre_testimonio", "titulo":"Pedir testimonio",            "responsable":"bpf", "disparo":"cierre", "dia_offset":0, "vence_en_dias":7}
         ]'::jsonb) with ordinality as t(i, o)
         where not exists (
           select 1 from jsonb_array_elements(p.plantilla_accionables) e where e->>'key' = i->>'key')
       ), '[]'::jsonb)
 where p.id = 'liam';

commit;


-- =====================================================================
-- 12. PRUEBA DE HUMO (no deja datos)
-- =====================================================================
-- Programa propio (humo039: aviso de renovación 30, avisos 21 / 5,
-- duración 90, gracia 30, sin chequeo 7) con dos productos, y un
-- segundo programa (humo039b) para probar productos cruzados. Los
-- clientes se cargan 'activo' (sin call de onboarding) y, donde el
-- semáforo importa, sin accionables.
-- Al final fuerza un error para deshacer TODO, incluido lo que
-- cs_aplicar_plantillas, cs_cerrar_vencidos y cs_generar_alertas le
-- hagan a datos reales.
drop table if exists pg_temp.cs_smoke39;
create temp table cs_smoke39 (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res      text[] := '{}';
  hoy      date := public.cs_hoy();
  v_p120   uuid;
  v_p365   uuid;
  v_pb     uuid;
  v_a      uuid;   -- alta con producto
  v_a2     uuid;   -- alta sin producto
  v_a3     uuid;   -- alta con producto y fecha_fin explícita
  v_a4     uuid;   -- cs_aplicar_plantillas
  v_r      uuid;   -- renovación con producto
  v_r2     uuid;   -- renovación con fecha explícita
  v_g      uuid;   -- renovación después de vencido
  v_p      uuid;   -- pausa
  v_p2     uuid;   -- pausado con fecha_fin pasada
  v_q      uuid;   -- pausado con renovación abierta
  v_v      uuid;   -- aviso 1
  v_w      uuid;   -- aviso 2
  v_x      uuid;   -- lejos de vencer
  v_f      uuid;   -- finalizado a mano
  v_b      uuid;   -- baja
  v_h      uuid;   -- vencido con renovación abierta (gracia)
  v_y      uuid;   -- baja con renovación abierta
  v_ren    uuid;
  v_ren2   uuid;
  v_d      date;
  v_d2     date;
  v_n      int;
  v_n2     int;
  v_k1     int;
  v_k2     int;
  v_num    numeric;
  v_txt    text;
  v_txt2   text;
  v_bool   boolean;
  v_state  text;
begin
  begin
    insert into public.cs_programas (id, nombre, activo, plantilla_accionables) values
      ('humo039', '__humo039__', true, '[
        {"key":"bienvenida",     "titulo":"Bienvenida",                  "responsable":"bpf", "dia_offset":0,  "vence_en_dias":1},
        {"key":"revision_30",    "titulo":"Revisión día 30",             "responsable":"bpf", "dia_offset":30, "vence_en_dias":3},
        {"key":"c_wpp",          "titulo":"Sacar del grupo de WhatsApp", "responsable":"bpf", "disparo":"cierre", "dia_offset":0, "vence_en_dias":2},
        {"key":"c_testimonio",   "titulo":"Pedir testimonio",            "responsable":"bpf", "disparo":"cierre", "vence_en_dias":7}
      ]'::jsonb);
    insert into public.cs_programas (id, nombre, activo) values ('humo039b', '__humo039b__', true);
    insert into public.cs_productos (programa_id, nombre, duracion_dias, orden) values ('humo039', 'Humo 120', 120, 1)
      returning id into v_p120;
    insert into public.cs_productos (programa_id, nombre, duracion_dias, orden) values ('humo039', 'Humo 365', 365, 2)
      returning id into v_p365;
    insert into public.cs_productos (programa_id, nombre, duracion_dias) values ('humo039b', 'Humo B', 60)
      returning id into v_pb;

    -- ================= PLANTILLA =================
    -- 1. el validador acepta disparo cierre y rechaza otro valor
    res := res || format('validador: disparo cierre ok, disparo raro no|%s|',
      public.cs_validar_plantilla('[{"key":"a","titulo":"b","responsable":"bpf","disparo":"cierre"}]')
      and not public.cs_validar_plantilla('[{"key":"a","titulo":"b","responsable":"bpf","disparo":"nunca"}]'));

    -- ================= PRODUCTOS: ALTA =================
    -- 2. alta con producto: fecha_fin = inicio + duración del producto
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado, producto_id)
    values ('humo039', '__humo039_a', hoy - 10, 'activo', v_p120) returning id into v_a;
    select fecha_fin into v_d from public.cs_clientes where id = v_a;
    res := res || format('alta con producto: fecha_fin = inicio + 120|%s|fin=%s', v_d = hoy + 110, v_d);

    -- 3. alta sin producto: la del programa, como antes
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado)
    values ('humo039', '__humo039_a2', hoy - 10, 'activo') returning id into v_a2;
    select fecha_fin into v_d from public.cs_clientes where id = v_a2;
    res := res || format('alta sin producto: fecha_fin = inicio + 90 del programa|%s|fin=%s', v_d = hoy + 80, v_d);

    -- 4. alta con producto y fecha_fin explícita: se respeta
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado, producto_id)
    values ('humo039', '__humo039_a3', hoy - 10, hoy + 5, 'activo', v_p365) returning id into v_a3;
    select fecha_fin into v_d from public.cs_clientes where id = v_a3;
    res := res || format('alta con fecha_fin explicita la respeta|%s|fin=%s', v_d = hoy + 5, v_d);

    -- 5. producto de otro programa: rechazado
    begin
      insert into public.cs_clientes (programa_id, nombre, estado, producto_id)
      values ('humo039', '__humo039_mal', 'activo', v_pb);
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('producto de otro programa: rechazado|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 6. el alta crea los ítems de inicio día 0 y ninguno de cierre
    select count(*) filter (where plantilla_key = 'bienvenida'),
           count(*) filter (where plantilla_key in ('c_wpp', 'c_testimonio') or plantilla_key like 'cierre:%')
      into v_n, v_n2
    from public.cs_accionables where cliente_id = v_a;
    res := res || format('alta: item de inicio si, de cierre no|%s|inicio=%s cierre=%s', v_n = 1 and v_n2 = 0, v_n, v_n2);

    -- 7. cs_aplicar_plantillas: el ítem de día 30 sí, los de cierre no
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado)
    values ('humo039', '__humo039_a4', hoy - 40, 'activo') returning id into v_a4;
    perform public.cs_aplicar_plantillas();
    select count(*) filter (where plantilla_key = 'revision_30'),
           count(*) filter (where plantilla_key in ('c_wpp', 'c_testimonio') or plantilla_key like 'cierre:%')
      into v_n, v_n2
    from public.cs_accionables where cliente_id = v_a4;
    res := res || format('aplicar_plantillas: dia 30 si, cierre no|%s|dia30=%s cierre=%s', v_n = 1 and v_n2 = 0, v_n, v_n2);

    -- ================= PRODUCTOS: RENOVACIÓN =================
    -- 8. renovado con producto y sin fecha: fecha_fin + 365; el cliente
    --    queda con ese producto y los avisos del ciclo se limpian
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado, producto_id)
    values ('humo039', '__humo039_r', hoy - 100, hoy + 10, 'activo', v_p120) returning id into v_r;
    update public.cs_clientes set aviso_1_at = now(), aviso_2_at = now() where id = v_r;
    insert into public.cs_renovaciones (cliente_id) values (v_r) returning id into v_ren;
    update public.cs_renovaciones set estado = 'renovado', resell_producto = 'upgrade', producto_id = v_p365
     where id = v_ren;
    select r.nueva_fecha_fin, c.fecha_fin, (c.producto_id = v_p365), c.estado || '/' || c.renovaciones_count,
           c.aviso_1_at is null and c.aviso_2_at is null
      into v_d, v_d2, v_bool, v_txt, v_txt2
    from public.cs_renovaciones r join public.cs_clientes c on c.id = r.cliente_id where r.id = v_ren;
    res := res || format('renovado con producto: nueva fecha = fin + 365, cliente con el producto|%s|nueva=%s fin=%s prod=%s %s',
                         v_d = hoy + 375 and v_d2 = hoy + 375 and v_bool and v_txt = 'activo/1',
                         v_d, v_d2, v_bool, v_txt);
    res := res || format('renovado limpia los dos avisos del ciclo|%s|limpios=%s', v_txt2::boolean, v_txt2);

    -- 9. renovado después de vencido: desde hoy + duración
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_g', hoy - 130, hoy - 3, 'activo') returning id into v_g;
    insert into public.cs_renovaciones (cliente_id, estado, resell_producto, producto_id)
    values (v_g, 'renovado', 'mismo_programa', v_p120) returning nueva_fecha_fin into v_d;
    select fecha_fin into v_d2 from public.cs_clientes where id = v_g;
    res := res || format('renovado ya vencido: nueva fecha = hoy + 120|%s|nueva=%s fin=%s',
                         v_d = hoy + 120 and v_d2 = hoy + 120, v_d, v_d2);

    -- 10. renovado con producto y nueva_fecha_fin explícita: manda la explícita
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_r2', hoy - 80, hoy + 10, 'activo') returning id into v_r2;
    insert into public.cs_renovaciones (cliente_id, estado, resell_producto, producto_id, nueva_fecha_fin)
    values (v_r2, 'renovado', 'mismo_programa', v_p120, hoy + 200) returning nueva_fecha_fin into v_d;
    res := res || format('renovado con fecha explicita la respeta|%s|nueva=%s', v_d = hoy + 200, v_d);

    -- 11. producto inmutable en una renovación cerrada
    begin
      update public.cs_renovaciones set producto_id = v_p120 where id = v_ren;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('producto de renovacion cerrada: inmutable|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 12. producto de otro programa en una renovación: rechazado
    begin
      insert into public.cs_renovaciones (cliente_id, producto_id) values (v_a2, v_pb);
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('renovacion con producto de otro programa: rechazada|%s|sqlstate=%s', v_state = '23514', v_state);

    -- ================= PAUSA =================
    -- 13. línea base: vence en 10 (dentro de 30 y de 21), 20 días sin chequeo
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_p', hoy - 30, hoy + 10, 'activo') returning id into v_p;
    delete from public.cs_accionables where cliente_id = v_p;
    update public.cs_clientes set ultimo_chequeo_at = now() - interval '20 days' where id = v_p;
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_p and not resuelta
      and tipo in ('renovacion_proxima', 'sin_chequeo', 'aviso_renovacion_1');
    select semaforo, dias_restantes into v_txt, v_n2 from public.cs_v_clientes where id = v_p;
    select clientes_activos into v_k1 from public.cs_v_kpis_programa where programa_id = 'humo039';
    res := res || format('linea base: rojo, 10 dias, 3 alertas (renovacion, sin chequeo, aviso 1)|%s|sem=%s dias=%s alertas=%s',
                         v_txt = 'rojo' and v_n2 = 10 and v_n = 3, v_txt, v_n2, v_n);

    -- 14. pausa desde hace 6 días: días congelados y nada de rojo
    update public.cs_clientes set estado = 'pausado', pausado_desde = hoy - 6 where id = v_p;
    select semaforo, dias_restantes, dias_transcurridos into v_txt, v_n, v_n2 from public.cs_v_clientes where id = v_p;
    res := res || format('pausado: dias restantes congelados (16), transcurridos (24), verde|%s|sem=%s rest=%s trans=%s',
                         v_txt = 'verde' and v_n = 16 and v_n2 = 24, v_txt, v_n, v_n2);

    -- 15. pausado: sus alertas de renovación, sin chequeo y aviso se resuelven y no vuelven
    perform public.cs_generar_alertas();
    select count(*) filter (where not resuelta), count(*) filter (where resuelta) into v_n, v_n2
    from public.cs_alertas
    where cliente_id = v_p and tipo in ('renovacion_proxima', 'sin_chequeo', 'aviso_renovacion_1', 'aviso_renovacion_2');
    res := res || format('pausado: sin alertas de renovacion / sin chequeo / avisos|%s|abiertas=%s resueltas=%s',
                         v_n = 0 and v_n2 = 3, v_n, v_n2);

    -- 16. no cuenta como activo en los KPIs
    select clientes_activos into v_k2 from public.cs_v_kpis_programa where programa_id = 'humo039';
    res := res || format('pausado: no cuenta como activo|%s|activos %s -> %s', v_k2 = v_k1 - 1, v_k1, v_k2);

    -- 17. un accionable BPF vencido lo pone amarillo, no rojo
    insert into public.cs_accionables (cliente_id, responsable, titulo, vence)
    values (v_p, 'bpf', 'tarea vencida', hoy - 1);
    select semaforo, array_to_string(motivos_semaforo, ' / ') into v_txt, v_txt2 from public.cs_v_clientes where id = v_p;
    res := res || format('pausado con accionable BPF vencido: amarillo, no rojo|%s|sem=%s motivos=%s',
                         v_txt = 'amarillo' and v_txt2 ~ 'BPF vencido', v_txt, v_txt2);

    -- 18. pausado con fecha_fin pasada: el chequeo diario no lo finaliza ni alerta vencido
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado, pausado_desde)
    values ('humo039', '__humo039_p2', hoy - 100, hoy - 2, 'pausado', hoy - 10) returning id into v_p2;
    perform public.cs_cerrar_vencidos();
    perform public.cs_generar_alertas();
    select c.estado, v.dias_restantes into v_txt, v_n from public.cs_clientes c
    join public.cs_v_clientes v on v.id = c.id where c.id = v_p2;
    select count(*) into v_n2 from public.cs_alertas where cliente_id = v_p2 and tipo = 'programa_vencido';
    res := res || format('pausado vencido: sigue pausado, 8 dias congelados, sin programa_vencido|%s|estado=%s dias=%s alertas=%s',
                         v_txt = 'pausado' and v_n = 8 and v_n2 = 0, v_txt, v_n, v_n2);

    -- 19. pausado_desde futura: rechazada
    begin
      update public.cs_clientes set estado = 'pausado', pausado_desde = hoy + 3 where id = v_a2;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('pausado_desde futura: rechazada|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 20. reanudar: fecha_fin + 6 días, pausado_desde vacío, días iguales a los congelados, vuelve el rojo
    update public.cs_clientes set estado = 'activo' where id = v_p;
    select c.fecha_fin, c.pausado_desde is null, v.dias_restantes, v.semaforo
      into v_d, v_bool, v_n, v_txt
    from public.cs_clientes c join public.cs_v_clientes v on v.id = c.id where c.id = v_p;
    res := res || format('reanudar: fecha_fin corrida 6 dias, 16 restantes, rojo de nuevo|%s|fin=%s limpio=%s dias=%s sem=%s',
                         v_d = hoy + 16 and v_bool and v_n = 16 and v_txt = 'rojo', v_d, v_bool, v_n, v_txt);

    -- 21. la corrida queda en el historial
    select count(*) into v_n from public.cs_historial
    where registro_id = v_p and campo = 'fecha_fin'
      and valor_anterior = (hoy + 10)::text and valor_nuevo = (hoy + 16)::text;
    res := res || format('reanudar: historial de fecha_fin|%s|filas=%s', v_n = 1, v_n);

    -- 22. reanudado: vuelve la alerta de renovación (clave con la fecha nueva)
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_p and tipo = 'renovacion_proxima' and not resuelta
      and clave_dedupe = 'renovacion_proxima:' || v_p || ':' || (hoy + 16);
    res := res || format('reanudado: renovacion_proxima con la fecha nueva|%s|abiertas=%s', v_n = 1, v_n);

    -- 23. reanudar el vencido pausado: fecha_fin + 10
    update public.cs_clientes set estado = 'activo' where id = v_p2;
    select fecha_fin into v_d from public.cs_clientes where id = v_p2;
    res := res || format('reanudar pausado vencido: fecha_fin + 10 dias|%s|fin=%s', v_d = hoy + 8, v_d);

    -- 24. pausado con renovación abierta: mover el pipeline no lo despausa;
    --     al reanudar a activo queda en_renovacion
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_q', hoy - 60, hoy + 20, 'activo') returning id into v_q;
    insert into public.cs_renovaciones (cliente_id) values (v_q) returning id into v_ren2;
    update public.cs_clientes set estado = 'pausado' where id = v_q;
    update public.cs_renovaciones set estado = 'contactado' where id = v_ren2;
    select estado into v_txt from public.cs_clientes where id = v_q;
    update public.cs_clientes set estado = 'activo' where id = v_q;
    select estado into v_txt2 from public.cs_clientes where id = v_q;
    res := res || format('pausado con renovacion abierta: sigue pausado; reanuda en_renovacion|%s|%s -> %s',
                         v_txt = 'pausado' and v_txt2 = 'en_renovacion', v_txt, v_txt2);

    -- ================= AVISOS =================
    -- 25. vence en 15: aviso 1 sí, aviso 2 no. Vence en 3: aviso 2 sí, aviso 1 no. Vence en 60: ninguno.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_v', hoy - 60, hoy + 15, 'activo') returning id into v_v;
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_w', hoy - 60, hoy + 3, 'activo') returning id into v_w;
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_x', hoy - 30, hoy + 60, 'activo') returning id into v_x;
    perform public.cs_generar_alertas();
    select string_agg(x.quien || '=' || x.tipos, ' ' order by x.quien) into v_txt
    from (
      select case c.id when v_v then 'v' when v_w then 'w' else 'x' end as quien,
             coalesce(string_agg(replace(a.tipo, 'aviso_renovacion_', 'aviso'), ',' order by a.tipo), '-') as tipos
      from public.cs_clientes c
      left join public.cs_alertas a on a.cliente_id = c.id and not a.resuelta and a.tipo like 'aviso_renovacion_%'
      where c.id in (v_v, v_w, v_x)
      group by c.id
    ) x;
    res := res || format('avisos: 15 dias -> aviso 1, 3 dias -> aviso 2, 60 dias -> nada|%s|%s',
                         v_txt = 'v=aviso1 w=aviso2 x=-', v_txt);

    -- 26. registrar los avisos los resuelve
    update public.cs_clientes set aviso_1_at = now() where id = v_v;
    update public.cs_clientes set aviso_2_at = now() where id = v_w;
    perform public.cs_generar_alertas();
    select count(*) filter (where not resuelta), count(*) filter (where resuelta) into v_n, v_n2
    from public.cs_alertas where cliente_id in (v_v, v_w) and tipo like 'aviso_renovacion_%';
    res := res || format('registrar el aviso resuelve la alerta|%s|abiertas=%s resueltas=%s', v_n = 0 and v_n2 = 2, v_n, v_n2);

    -- 27. el registro queda en el historial y en el maestro
    select count(*) into v_n from public.cs_historial
    where registro_id = v_v and campo = 'aviso_1_at' and valor_anterior is null and valor_nuevo is not null;
    select aviso_1_at is not null and aviso_2_at is null into v_bool from public.cs_v_maestro where id = v_v;
    res := res || format('aviso registrado: historial y maestro|%s|historial=%s maestro=%s', v_n = 1 and v_bool, v_n, v_bool);

    -- ================= OFFBOARDING =================
    -- 28. finalizado a mano: los 2 ítems de cierre, BPF, vencen hoy + 2 y hoy + 7
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_f', hoy - 50, hoy + 40, 'activo') returning id into v_f;
    update public.cs_clientes set estado = 'finalizado' where id = v_f;
    select count(*),
           string_agg(to_char(vence - hoy, 'FM999'), ',' order by vence),
           bool_and(responsable = 'bpf' and origen = 'plantilla' and plantilla_key like 'cierre:%:' || (hoy + 40))
      into v_n, v_txt, v_bool
    from public.cs_accionables where cliente_id = v_f and plantilla_key like 'cierre:%';
    res := res || format('finalizado: 2 accionables de cierre (vencen +2 y +7)|%s|n=%s vence=%s ok=%s',
                         v_n = 2 and v_txt = '2,7' and v_bool, v_n, v_txt, v_bool);

    -- 29. baja: los mismos 2
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_b', hoy - 50, hoy + 40, 'activo') returning id into v_b;
    update public.cs_clientes set estado = 'baja' where id = v_b;
    select count(*) into v_n from public.cs_accionables where cliente_id = v_b and plantilla_key like 'cierre:%';
    res := res || format('baja: 2 accionables de cierre|%s|n=%s', v_n = 2, v_n);

    -- 30. baja -> finalizado y otros updates no duplican
    update public.cs_clientes set estado = 'finalizado' where id = v_b;
    update public.cs_clientes set notas = 'x' where id = v_f;
    select count(*) filter (where cliente_id = v_b), count(*) filter (where cliente_id = v_f) into v_n, v_n2
    from public.cs_accionables where cliente_id in (v_b, v_f) and plantilla_key like 'cierre:%';
    res := res || format('cierre no se duplica|%s|baja=%s finalizado=%s', v_n = 2 and v_n2 = 2, v_n, v_n2);

    -- 31. un finalizado no se puede pausar
    begin
      update public.cs_clientes set estado = 'pausado' where id = v_f;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('finalizado no se puede pausar|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 32. vencido con renovación abierta: el chequeo lo finaliza (gracia) sin
    --     offboarding; al cerrar la renovación como no_renovado, sí
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_h', hoy - 120, hoy - 1, 'activo') returning id into v_h;
    insert into public.cs_renovaciones (cliente_id) values (v_h) returning id into v_ren2;
    perform public.cs_cerrar_vencidos();
    select c.estado, r.estado into v_txt, v_txt2
    from public.cs_clientes c join public.cs_renovaciones r on r.cliente_id = c.id where c.id = v_h;
    select count(*) into v_n from public.cs_accionables where cliente_id = v_h and plantilla_key like 'cierre:%';
    update public.cs_renovaciones set estado = 'no_renovado', motivo = 'no le interesa' where id = v_ren2;
    select count(*) into v_n2 from public.cs_accionables where cliente_id = v_h and plantilla_key like 'cierre:%';
    res := res || format('vencido en gracia: sin offboarding hasta el no_renovado|%s|%s/%s cierre %s -> %s',
                         v_txt = 'finalizado' and v_txt2 = 'en_proceso' and v_n = 0 and v_n2 = 2,
                         v_txt, v_txt2, v_n, v_n2);

    -- 33. baja con renovación abierta: offboarding en el momento
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo039', '__humo039_y', hoy - 60, hoy + 20, 'activo') returning id into v_y;
    insert into public.cs_renovaciones (cliente_id) values (v_y);
    update public.cs_clientes set estado = 'baja' where id = v_y;
    select count(*) into v_n from public.cs_accionables where cliente_id = v_y and plantilla_key like 'cierre:%';
    res := res || format('baja con renovacion abierta: offboarding igual|%s|n=%s', v_n = 2, v_n);

    -- 34. un ítem de cierre vencido alerta aunque el cliente esté cerrado
    update public.cs_accionables set vence = hoy - 1
     where cliente_id = v_f and plantilla_key like 'cierre:c_wpp:%';
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas a
    join public.cs_accionables x on a.clave_dedupe = 'accionable_bpf_vencido:' || x.id
    where x.cliente_id = v_f and x.plantilla_key like 'cierre:c_wpp:%' and not a.resuelta;
    res := res || format('item de cierre vencido: alerta accionable_bpf_vencido|%s|abiertas=%s', v_n = 1, v_n);

    -- ================= TESTIMONIO =================
    -- 35. default sin_pedir, se edita, valor raro rechazado
    select testimonio into v_txt from public.cs_clientes where id = v_a;
    update public.cs_clientes set testimonio = 'grabado' where id = v_a;
    select testimonio into v_txt2 from public.cs_v_maestro where id = v_a;
    begin
      update public.cs_clientes set testimonio = 'quizas' where id = v_a;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('testimonio: default sin_pedir, grabado en el maestro, valor raro rechazado|%s|%s -> %s, raro=%s',
                         v_txt = 'sin_pedir' and v_txt2 = 'grabado' and v_state = '23514', v_txt, v_txt2, v_state);

    -- ================= CALL DE RESELL =================
    -- 36. call de renovación con los 4 datos
    insert into public.cs_calls (cliente_id, tipo, estado, fecha, encargado, show_up, calificacion, resultado)
    values (v_q, 'renovacion', 'realizada', now(), 'Closer', true, 'calificado', 'Pidió propuesta de 12 meses');
    select count(*) into v_n from public.cs_calls
    where cliente_id = v_q and tipo = 'renovacion' and show_up and calificacion = 'calificado';
    res := res || format('call de renovacion guarda encargado, show up, calificacion y resultado|%s|n=%s', v_n = 1, v_n);

    -- 37. esos datos en una call que no es de renovación: rechazados
    begin
      insert into public.cs_calls (cliente_id, tipo, calificacion) values (v_q, 'seguimiento', 'calificado');
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('datos de resell en call de seguimiento: rechazados|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 38. no_show con show_up = true: rechazado
    begin
      insert into public.cs_calls (cliente_id, tipo, estado, show_up) values (v_q, 'renovacion', 'no_show', true);
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('no_show con show up: rechazado|%s|sqlstate=%s', v_state = '23514', v_state);

    -- ================= MÉTRICAS =================
    -- 39. tasa de renovación con la fórmula de siempre: 3 renovados (r, g, r2) / 1 no renovado (h)
    select tasa_renovacion into v_num from public.cs_v_kpis_programa where programa_id = 'humo039';
    res := res || format('tasa de renovacion: renovado / (renovado + no_renovado) = 75.0|%s|tasa=%s', v_num = 75.0, v_num);

    -- 40. maestro: producto por nombre
    select producto into v_txt from public.cs_v_maestro where id = v_r;
    res := res || format('maestro: producto del cliente renovado = Humo 365|%s|%s', v_txt = 'Humo 365', v_txt);

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s (%s)', replace(sqlerrm, '|', '/'), sqlstate);
    end if;
  end;

  insert into cs_smoke39 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 13. QUERY DE CONTROL (una sola tabla de resultados; mirar la columna ok)
-- =====================================================================
with
cols_p as (
  select column_name::text as c from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_productos'
),
cols_c as (
  select column_name::text as c from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_clientes'
),
cols_k as (
  select column_name::text as c from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_calls'
),
cols_m as (
  select column_name::text as c from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_v_maestro'
),
cols_v as (
  select string_agg(column_name::text, ',' order by ordinal_position) as cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_v_clientes'
),
pol as (
  select string_agg(p.policyname || ':' || p.cmd, ', ' order by p.policyname) as lista, count(*) as n
  from pg_policies p
  where p.schemaname = 'public' and p.tablename = 'cs_productos'
),
estado_chk as (
  select string_agg(pg_get_constraintdef(c.oid), ' ; ') as def, count(*) as n
  from pg_constraint c
  where c.conrelid = 'public.cs_clientes'::regclass and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ~ 'en_renovacion'
),
tipo_chk as (
  select string_agg(pg_get_constraintdef(c.oid), ' ; ') as def, count(*) as n
  from pg_constraint c
  where c.conrelid = 'public.cs_alertas'::regclass and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ~ 'sin_chequeo'
),
sem as (
  select count(*) filter (where v.id is null or v.semaforo is distinct from a.semaforo) as dif_sem,
         count(*) filter (where v.id is null or v.motivos_semaforo is distinct from a.motivos_semaforo) as dif_mot,
         count(*) filter (where v.id is null or v.dias_restantes is distinct from a.dias_restantes
                            or v.pct_programa is distinct from a.pct_programa) as dif_dias,
         count(*) as total
  from cs_039_antes_sem a
  left join public.cs_v_clientes v on v.id = a.id
),
kpi as (
  select a.programa_id, a.tasa_renovacion as tasa_antes, k.tasa_renovacion as tasa_despues,
         (a.clientes_activos, a.por_vencer, a.clientes_rojo, a.sin_chequeo)::text as kpi_antes,
         (k.clientes_activos, k.por_vencer, k.clientes_rojo, k.sin_chequeo)::text as kpi_despues
  from cs_039_antes_kpi a
  left join public.cs_v_kpis_programa k on k.programa_id = a.programa_id
),
prog as (
  select count(*) filter (where p.id is null
                            or p.aviso_renovacion_dias is distinct from a.aviso_renovacion_dias
                            or p.duracion_default_dias is distinct from a.duracion_default_dias) as difieren,
         count(*) filter (where p.aviso_1_dias = 21 and p.aviso_2_dias = 5) as con_default,
         count(*) as total
  from cs_039_antes_prog a
  left join public.cs_programas p on p.id = a.id
),
liam as (
  select exists (select 1 from public.cs_programas where id = 'liam') as existe,
         (select string_agg(nombre || '=' || duracion_dias, ', ' order by orden)
            from public.cs_productos where programa_id = 'liam') as productos,
         (select count(*) from public.cs_productos where programa_id = 'liam'
            and (nombre, duracion_dias) in (('BPF 1-1 4 Meses', 120), ('BPF 1-1 6 Meses', 180),
                                            ('BPF 1-1 12 Meses', 365), ('BPF Grupal', 120),
                                            ('Gestión de Capital', 365))) as productos_ok,
         (select count(*) from public.cs_programas p
            cross join lateral jsonb_array_elements(p.plantilla_accionables) e
            where p.id = 'liam' and e->>'disparo' = 'cierre'
              and e->>'key' in ('cierre_whatsapp', 'cierre_skool', 'cierre_testimonio')) as cierre_ok
)
select '01 tabla cs_productos' as control, 'columnas' as objeto, '7' as esperado,
       (select count(*) from cols_p)::text as obtenido,
       (select count(*) from cols_p where c in ('id', 'programa_id', 'nombre', 'duracion_dias',
                                                'activo', 'orden', 'created_at')) = 7 as ok
union all
select '01 RLS cs_productos', 'rls activa + 4 politicas', 'true / 4',
       (select relrowsecurity from pg_class where oid = 'public.cs_productos'::regclass)::text || ' / '
         || p.n || ' (' || coalesce(p.lista, '') || ')',
       (select relrowsecurity from pg_class where oid = 'public.cs_productos'::regclass) and p.n = 4
from pol p
union all
select '01 permisos cs_productos', 'anon select', 'false',
       has_table_privilege('anon', 'public.cs_productos', 'SELECT')::text,
       not has_table_privilege('anon', 'public.cs_productos', 'SELECT')
union all
select '02 cs_clientes columnas nuevas', 'producto_id, pausado_desde, aviso_1_at, aviso_2_at, testimonio', '5',
       (select count(*) from cols_c where c in ('producto_id', 'pausado_desde', 'aviso_1_at', 'aviso_2_at', 'testimonio'))::text,
       (select count(*) from cols_c where c in ('producto_id', 'pausado_desde', 'aviso_1_at', 'aviso_2_at', 'testimonio')) = 5
union all
select '02 cs_clientes.plan sigue', 'columna plan', 'true',
       exists (select 1 from cols_c where c = 'plan')::text, exists (select 1 from cols_c where c = 'plan')
union all
select '02 CHECK de estado', 'un solo check, con pausado', 'n=1',
       'n=' || e.n || ' ' || left(coalesce(e.def, ''), 120),
       e.n = 1 and e.def ~ 'pausado' and e.def ~ 'onboarding' and e.def ~ 'baja'
from estado_chk e
union all
select '02 testimonio de los clientes existentes', 'distinto de sin_pedir', '0',
       (select count(*) from public.cs_clientes where testimonio <> 'sin_pedir')::text,
       (select count(*) from public.cs_clientes where testimonio <> 'sin_pedir') = 0
union all
select '03 avisos en cs_programas', 'programas con 21 / 5', p.total::text, p.con_default::text,
       p.con_default = p.total
from prog p
union all
select '03 aviso_renovacion_dias y duracion sin cambios', 'programas que cambiaron', '0',
       p.difieren || ' de ' || p.total, p.difieren = 0
from prog p
union all
select '04 cs_calls columnas nuevas', 'encargado, show_up, calificacion, resultado', '4',
       (select count(*) from cols_k where c in ('encargado', 'show_up', 'calificacion', 'resultado'))::text,
       (select count(*) from cols_k where c in ('encargado', 'show_up', 'calificacion', 'resultado')) = 4
union all
select '04 cs_renovaciones.producto_id', 'columna', 'true',
       exists (select 1 from information_schema.columns where table_schema = 'public'
               and table_name = 'cs_renovaciones' and column_name = 'producto_id')::text,
       exists (select 1 from information_schema.columns where table_schema = 'public'
               and table_name = 'cs_renovaciones' and column_name = 'producto_id')
union all
select '05 CHECK de cs_alertas.tipo', 'un solo check, con los 2 avisos', 'n=1',
       'n=' || t.n || ' ' || left(coalesce(t.def, ''), 120),
       t.n = 1 and t.def ~ 'aviso_renovacion_1' and t.def ~ 'aviso_renovacion_2' and t.def ~ 'proximo_contacto_vencido'
from tipo_chk t
union all
select '06 cs_v_maestro columnas nuevas', 'producto_id, producto, testimonio, aviso_1_at, aviso_2_at, pausado_desde', '6',
       (select count(*) from cols_m where c in ('producto_id', 'producto', 'testimonio',
                                                'aviso_1_at', 'aviso_2_at', 'pausado_desde'))::text,
       (select count(*) from cols_m where c in ('producto_id', 'producto', 'testimonio',
                                                'aviso_1_at', 'aviso_2_at', 'pausado_desde')) = 6
union all
select '06 security_invoker', c.relname, 'security_invoker=on',
       coalesce(array_to_string(c.reloptions, ','), ''),
       coalesce(array_to_string(c.reloptions, ','), '') ~ 'security_invoker=(on|true)'
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in ('cs_v_maestro', 'cs_v_clientes')
union all
select '07 cs_v_clientes mismas columnas', 'mismo orden que antes', 'iguales',
       case when v.cols = a.cols then 'iguales' else 'distintas' end, v.cols = a.cols
from cols_v v cross join cs_039_antes_cols a
union all
select '08 seed liam productos', coalesce(l.productos, '(ninguno)'),
       case when l.existe then '5' else 'liam no existe' end,
       l.productos_ok::text, not l.existe or l.productos_ok = 5
from liam l
union all
select '08 seed liam offboarding', 'items de cierre en la plantilla',
       case when l.existe then '3' else 'liam no existe' end,
       l.cierre_ok::text, not l.existe or l.cierre_ok = 3
from liam l
union all
select '09 semaforo igual que antes', 'clientes que cambiaron', '0',
       s.dif_sem || ' de ' || s.total, s.dif_sem = 0
from sem s
union all
select '09 motivos del semaforo igual que antes', 'clientes que cambiaron', '0',
       s.dif_mot || ' de ' || s.total, s.dif_mot = 0
from sem s
union all
select '09 dias restantes y % igual que antes', 'clientes que cambiaron', '0',
       s.dif_dias || ' de ' || s.total, s.dif_dias = 0
from sem s
union all
select '10 tasa de renovacion igual que antes', k.programa_id,
       coalesce(k.tasa_antes::text, 'null'), coalesce(k.tasa_despues::text, 'null'),
       k.tasa_antes is not distinct from k.tasa_despues
from kpi k
union all
select '11 KPIs igual que antes (activos, por vencer, rojo, sin chequeo)', k.programa_id,
       k.kpi_antes, k.kpi_despues, k.kpi_antes is not distinct from k.kpi_despues
from kpi k
union all
select '12 la prueba de humo no dejo datos', 'programas humo039* / clientes __humo039_', '0',
       ((select count(*) from public.cs_programas where id like 'humo039%')
        + (select count(*) from public.cs_clientes where nombre like '\_\_humo039\_%'))::text,
       ((select count(*) from public.cs_programas where id like 'humo039%')
        + (select count(*) from public.cs_clientes where nombre like '\_\_humo039\_%')) = 0
union all
select '13 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke39 s
order by 1, 2;
