-- =====================================================================
-- 037-maestro-csm.sql  —  Dystopia Producto: maestro de clientes del CSM
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
--
-- Qué hace:
--   - cs_clientes suma 4 campos que edita el CSM: prioridad,
--     proxima_accion, proxima_accion_fecha, nota_csm. El responsable ya
--     existía (cs_clientes.responsable) y se reusa.
--   - cs_renovaciones pasa a ser el pipeline de resell (sin tabla nueva):
--       abiertos:  en_proceso | contactado | call_agendada | propuesta_enviada
--       cerrados:  renovado | no_renovado
--     y suma resell_producto (mismo_programa | upgrade | downgrade | otro),
--     obligatorio al cerrar como renovado y null en cualquier otro estado.
--     El motivo de pérdida sigue siendo cs_renovaciones.motivo.
--   - Días de gracia del pipeline (cs_programas.resell_gracia_dias,
--     default 30): el cliente vencido pasa a finalizado igual, pero su
--     renovación abierta sobrevive hasta fecha_fin + gracia. Recién ahí
--     el chequeo diario la cierra como no_renovado "Vencido sin respuesta".
--   - La tasa de renovación NO cambia: renovado / (renovado + no_renovado),
--     cuente lo que cuente como producto. Se agrega el desglose por
--     producto a cs_v_kpis_programa y cs_v_metricas_mensuales.
--   - Vista nueva cs_v_maestro: una fila por cliente con lo editable +
--     lo calculado de cs_v_clientes + la renovación vigente.
--   - cs_historial registra prioridad (cs_clientes) y resell_producto
--     (cs_renovaciones). Los estados nuevos del pipeline ya se registran
--     solos: el trigger de historial de cs_renovaciones mira 'estado'.
--
-- NO es puramente aditiva. Toca objetos existentes (todo cs_*):
--   - CHECK de cs_renovaciones.estado: se reemplaza por uno con 6 valores.
--   - Índice único "una renovación en_proceso por cliente": pasa a "una
--     renovación ABIERTA por cliente" (cualquiera de los 4 estados abiertos).
--   - Funciones reescritas, cambiando SOLO 'en_proceso' por "abierta"
--     (helper cs_ren_abierta), más las reglas de resell_producto:
--       cs_tg_renovaciones_before       (001)
--       cs_tg_renovaciones_after        (001)
--       cs_tg_renovaciones_after_delete (003)
--       cs_cerrar_vencidos              (003)
--       cs_generar_alertas              (003)
--   - Triggers de historial de cs_clientes y cs_renovaciones: se recrean
--     con los campos nuevos.
--   - Vistas reescritas: cs_v_clientes (mismas columnas, mismo orden),
--     cs_v_kpis_programa y cs_v_metricas_mensuales (columnas nuevas al final).
--   - cs_programas: columna resell_gracia_dias.
--   - Datos: las renovaciones que ya están 'renovado' quedan con
--     resell_producto = 'mismo_programa' (antes de esto no existía otra
--     opción). Ese relleno NO se registra en cs_historial.
-- Nada crm_* / fin_* / ventas. No toca políticas RLS.
-- Es re-ejecutable (if not exists / create or replace / drop if exists).
--
-- Por qué cs_v_clientes lista las columnas en vez de usar c.*:
--   Postgres congeló c.* con las columnas que tenía cs_clientes en 001.
--   Si se recrea con c.* después de agregar columnas, las nuevas caerían
--   en el medio y "create or replace view" falla. Se listan las 18
--   originales en el mismo orden: la vista queda idéntica para la UI.
--
-- Estructura:
--   0. Foto de ANTES (tasa y semáforo actuales, para comparar al final)
--   1. Helper cs_ren_abierta()
--   2. cs_clientes: campos del CSM + historial de prioridad
--   3. cs_renovaciones: estados, resell_producto, índice, historial,
--      días de gracia (cs_programas)
--   4. Triggers de cs_renovaciones (reescritos)
--   5. Funciones del chequeo diario (003, reescritas)
--   6. Vistas: cs_v_clientes, cs_v_kpis_programa, cs_v_metricas_mensuales,
--      cs_v_maestro (nueva)
--   7. Permisos
--   8. PRUEBA DE HUMO (crea datos, los verifica y los deshace)
--   9. QUERY DE CONTROL
-- =====================================================================


-- =====================================================================
-- 0. FOTO DE ANTES (fuera de la transacción, en tablas temporales)
-- =====================================================================
-- Se comparan en la query de control. Si la migración se corre dos
-- veces, la foto es la del estado ya migrado y la comparación sigue
-- valiendo.
drop table if exists pg_temp.cs_037_antes_tasa;
create temp table cs_037_antes_tasa as
  select programa_id, tasa_renovacion from public.cs_v_kpis_programa;

drop table if exists pg_temp.cs_037_antes_sem;
create temp table cs_037_antes_sem as
  select id, semaforo, renovacion_estado from public.cs_v_clientes;

drop table if exists pg_temp.cs_037_antes_cols;
create temp table cs_037_antes_cols as
  select string_agg(column_name::text, ',' order by ordinal_position) as cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_v_clientes';

begin;

-- =====================================================================
-- 1. HELPER
-- =====================================================================
-- Estados abiertos del pipeline de resell. Única definición: la usan
-- triggers, funciones y vistas. El índice único de la sección 3 repite
-- la lista literal (mantenerlas iguales).
create or replace function public.cs_ren_abierta(p_estado text)
returns boolean
language sql immutable
set search_path = public
as $$
  select coalesce(p_estado in ('en_proceso','contactado','call_agendada','propuesta_enviada'), false)
$$;


-- =====================================================================
-- 2. cs_clientes: CAMPOS DEL CSM
-- =====================================================================
alter table public.cs_clientes
  add column if not exists prioridad            text,
  add column if not exists proxima_accion       text,
  add column if not exists proxima_accion_fecha date,
  add column if not exists nota_csm             text;

alter table public.cs_clientes drop constraint if exists cs_clientes_prioridad_chk;
alter table public.cs_clientes add constraint cs_clientes_prioridad_chk
  check (prioridad is null or prioridad in ('alta','media','baja'));

-- Historial: mismo trigger genérico de 001, con prioridad sumada.
create or replace trigger cs_trg_historial
  after insert or update of estado, fecha_fin, prioridad on public.cs_clientes
  for each row execute function public.cs_tg_historial('estado', 'fecha_fin', 'prioridad');


-- =====================================================================
-- 3. cs_renovaciones: PIPELINE DE RESELL
-- =====================================================================

-- 3a. CHECK de estado. En 001 era un check inline sin nombre
-- (cs_renovaciones_estado_check). Se borra cualquier check de la tabla
-- que restrinja estado a la lista vieja, por si Postgres le dio otro nombre.
do $$
declare
  v_con text;
begin
  for v_con in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.cs_renovaciones'::regclass
      and c.contype = 'c'
      and c.conname <> 'cs_renovaciones_estado_chk'
      and pg_get_constraintdef(c.oid) ~ 'en_proceso'
  loop
    execute format('alter table public.cs_renovaciones drop constraint %I', v_con);
  end loop;
end $$;

alter table public.cs_renovaciones drop constraint if exists cs_renovaciones_estado_chk;
alter table public.cs_renovaciones add constraint cs_renovaciones_estado_chk
  check (estado in ('en_proceso','contactado','call_agendada','propuesta_enviada','renovado','no_renovado'));

-- 3b. resell_producto
alter table public.cs_renovaciones add column if not exists resell_producto text;

-- Relleno de las renovaciones ya cerradas como renovado. Sin tocar
-- updated_at (no es un cambio del CSM). El update no dispara historial
-- ni el trigger de efecto sobre el cliente: ambos son "update of estado".
alter table public.cs_renovaciones disable trigger cs_trg_90_updated_at;
update public.cs_renovaciones
   set resell_producto = 'mismo_programa'
 where estado = 'renovado' and resell_producto is null;
alter table public.cs_renovaciones enable trigger cs_trg_90_updated_at;

alter table public.cs_renovaciones drop constraint if exists cs_renovaciones_resell_producto_chk;
alter table public.cs_renovaciones add constraint cs_renovaciones_resell_producto_chk
  check (resell_producto is null or resell_producto in ('mismo_programa','upgrade','downgrade','otro'));

-- Obligatorio si y solo si está cerrada como renovado. El trigger de la
-- sección 4 da un mensaje legible antes; esto es la red de seguridad.
alter table public.cs_renovaciones drop constraint if exists cs_renovaciones_resell_solo_renovado;
alter table public.cs_renovaciones add constraint cs_renovaciones_resell_solo_renovado
  check ((estado = 'renovado') = (resell_producto is not null));

-- 3c. Una sola renovación ABIERTA por cliente (antes: una en_proceso).
-- Misma lista que cs_ren_abierta().
drop index if exists public.cs_renovaciones_una_en_proceso;
create unique index if not exists cs_renovaciones_una_abierta
  on public.cs_renovaciones (cliente_id)
  where estado in ('en_proceso','contactado','call_agendada','propuesta_enviada');

-- 3d. Historial: estado (ya estaba) + resell_producto.
create or replace trigger cs_trg_historial
  after insert or update of estado, resell_producto on public.cs_renovaciones
  for each row execute function public.cs_tg_historial('estado', 'resell_producto');

-- 3e. Días de gracia del pipeline, por programa. El cliente vencido pasa
-- a finalizado igual; su renovación abierta sobrevive hasta
-- fecha_fin + resell_gracia_dias (ver cs_cerrar_vencidos).
alter table public.cs_programas
  add column if not exists resell_gracia_dias int not null default 30;
alter table public.cs_programas drop constraint if exists cs_programas_resell_gracia_chk;
alter table public.cs_programas add constraint cs_programas_resell_gracia_chk
  check (resell_gracia_dias >= 0);


-- =====================================================================
-- 4. TRIGGERS DE cs_renovaciones (reescritos)
-- =====================================================================

-- ---------- reglas antes de guardar ----------
-- Igual que 001, con dos cambios:
--   - resultado_at se pone al cerrar desde CUALQUIER estado abierto
--     (antes solo desde en_proceso).
--   - reglas de resell_producto: obligatorio al cerrar como renovado,
--     prohibido en cualquier otro estado, e inmutable una vez cerrada.
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
    if old.estado = 'renovado' and new.resell_producto is distinct from old.resell_producto then
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
-- Igual que 001; la rama 'en_proceso' pasa a ser "cualquier estado
-- abierto". Moverse entre estados abiertos no cambia al cliente (ya está
-- en_renovacion). La rama renovado no mira el producto: mismo_programa,
-- upgrade, downgrade y otro mueven fecha_fin a nueva_fecha_fin igual.
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
    update public.cs_clientes
       set estado = 'en_renovacion'
     where id = new.cliente_id and estado not in ('en_renovacion','baja')
       and not (estado = 'finalizado' and fecha_fin < public.cs_hoy());

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

-- ---------- borrar una renovación abierta destraba al cliente ----------
-- Igual que 003, con 'en_proceso' -> abierta.
create or replace function public.cs_tg_renovaciones_after_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.cs_ren_abierta(old.estado) then
    return null;
  end if;

  update public.cs_clientes c
     set estado = case when c.fecha_fin < public.cs_hoy() then 'finalizado' else 'activo' end
   where c.id = old.cliente_id
     and c.estado = 'en_renovacion'
     -- si quedó otra renovación abierta, el cliente sigue en renovación
     and not exists (
       select 1 from public.cs_renovaciones r
       where r.cliente_id = old.cliente_id and public.cs_ren_abierta(r.estado)
     );
  return null;
end;
$fn$;


-- =====================================================================
-- 5. FUNCIONES DEL CHEQUEO DIARIO (003, reescritas)
-- =====================================================================

-- ---------- cs_cerrar_vencidos ----------
-- Igual que 003, con dos cambios en el paso 2:
--   - cierra las renovaciones ABIERTAS (cualquier etapa del pipeline);
--   - solo cuando pasó la gracia: fecha_fin + resell_gracia_dias < hoy.
--     Mientras tanto el cliente ya está finalizado (paso 1, sin cambios)
--     y el pipeline sigue abierto.
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
       and c.estado not in ('finalizado', 'baja')
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

-- ---------- cs_generar_alertas ----------
-- Igual que 003. Único cambio: 'en_proceso' -> abierta, en el orden de
-- la renovación vigente y en renovacion_proxima (un cliente contactado,
-- con call agendada o con propuesta enviada ya tiene la renovación iniciada).
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
           c.fecha_inicio,
           c.fecha_fin,
           p.aviso_renovacion_dias,
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
  vigentes as (
    -- renovacion_proxima: entró en la ventana de aviso y nadie inició la renovación
    select b.programa_id,
           b.cliente_id,
           'renovacion_proxima'::text as tipo,
           format('Vence en %s día(s) sin renovación iniciada', b.dias_restantes) as mensaje,
           'renovacion_proxima:' || b.cliente_id || ':' || b.fecha_fin as clave_dedupe
    from base b
    join estado_ren r on r.cliente_id = b.cliente_id
    where b.dias_restantes >= 0
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
    where b.dias_restantes < 0

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
    -- sin_chequeo: una por racha sin chequear (la clave cambia con cada chequeo)
    select b.programa_id,
           b.cliente_id,
           'sin_chequeo',
           format('Sin chequeo hace %s día(s)', public.cs_hoy() - b.base_chequeo),
           'sin_chequeo:' || b.cliente_id || ':' || b.base_chequeo
    from base b
    where public.cs_hoy() - b.base_chequeo > b.dias_sin_chequeo_alerta
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
                      'accionable_bpf_vencido', 'sin_chequeo', 'programa_vencido')
       and not exists (select 1 from vigentes v where v.clave_dedupe = a.clave_dedupe)
    returning 1
  )
  select (select count(*) from creadas), (select count(*) from resueltas)
    into v_creadas, v_resueltas;

  return jsonb_build_object('creadas', v_creadas, 'resueltas', v_resueltas);
end;
$fn$;


-- =====================================================================
-- 6. VISTAS (security_invoker = on)
-- =====================================================================

-- ---------- cs_v_clientes ----------
-- Igual que 001, con dos cambios:
--   - c.* reemplazado por las 18 columnas originales (ver encabezado).
--   - 'en_proceso' -> abierta: un cliente contactado / con call agendada /
--     con propuesta enviada queda AMARILLO ("Renovación en proceso"),
--     no ROJO ("sin renovación iniciada").
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
    -- si hay una abierta, manda esa; si no, la más reciente
    select x.estado from public.cs_renovaciones x
    where x.cliente_id = c.id
    order by public.cs_ren_abierta(x.estado) desc, x.iniciada_at desc
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
       and not public.cs_ren_abierta(m.renovacion_estado)
       and coalesce(m.renovacion_estado, '') <> 'no_renovado')                     as r_ren,
    (m.dias_restantes <= m.aviso_renovacion_dias
       and m.estado_cliente not in ('finalizado','baja')
       and public.cs_ren_abierta(m.renovacion_estado))                             as a_ren,
    (m.estado_cliente not in ('finalizado','baja')
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
-- Igual que 001 (tasa_renovacion con la MISMA fórmula) + desglose de los
-- renovados por producto, al final.
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
  v.sin_chequeo,
  r.ren_mismo  as ren_mismo_programa,
  r.ren_up     as ren_upgrade,
  r.ren_down   as ren_downgrade,
  r.ren_otro   as ren_otro
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
         count(*) filter (where x.estado = 'no_renovado') as noren,
         count(*) filter (where x.estado = 'renovado' and x.resell_producto = 'mismo_programa') as ren_mismo,
         count(*) filter (where x.estado = 'renovado' and x.resell_producto = 'upgrade')        as ren_up,
         count(*) filter (where x.estado = 'renovado' and x.resell_producto = 'downgrade')      as ren_down,
         count(*) filter (where x.estado = 'renovado' and x.resell_producto = 'otro')           as ren_otro
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
-- Igual que 001 + renovados del mes por producto, al final.
create or replace view public.cs_v_metricas_mensuales
with (security_invoker = on) as
with ev as (
  select c.programa_id, date_trunc('month', c.fecha_inicio)::date as mes, 'alta'::text as k, null::numeric as v,
         null::text as prod
  from public.cs_clientes c
  union all
  select r.programa_id,
         date_trunc('month', r.resultado_at at time zone 'America/Argentina/Buenos_Aires')::date,
         r.estado, null, r.resell_producto
  from public.cs_renovaciones r
  where r.estado in ('renovado','no_renovado') and r.resultado_at is not null
  union all
  select d.programa_id,
         date_trunc('month', d.entregada_at at time zone 'America/Argentina/Buenos_Aires')::date,
         'dev', extract(epoch from (d.entregada_at - d.solicitada_at)) / 3600.0, null
  from public.cs_devoluciones d
  where d.estado = 'entregada' and d.entregada_at is not null
  union all
  select x.programa_id,
         date_trunc('month', x.created_at at time zone 'America/Argentina/Buenos_Aires')::date,
         'resp', x.puntaje, null
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
  count(*) filter (where k = 'resp')         as respuestas,
  count(*) filter (where k = 'renovado' and prod = 'mismo_programa') as renovados_mismo_programa,
  count(*) filter (where k = 'renovado' and prod = 'upgrade')        as renovados_upgrade,
  count(*) filter (where k = 'renovado' and prod = 'downgrade')      as renovados_downgrade,
  count(*) filter (where k = 'renovado' and prod = 'otro')           as renovados_otro
from ev
group by programa_id, mes;

-- ---------- cs_v_maestro (NUEVA) ----------
-- La planilla del CSM: una fila por cliente. Lo editable sale de
-- cs_clientes (la UI escribe en cs_clientes, no en la vista); lo
-- calculado sale de cs_v_clientes, sin recalcular nada acá.
-- Renovación vigente = la abierta si hay una; si no, la más reciente
-- (mismo criterio que cs_v_clientes.renovacion_estado).
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
  v.updated_at
from public.cs_v_clientes v
join public.cs_clientes c on c.id = v.id
left join lateral (
  select x.id, x.estado, x.resell_producto, x.iniciada_at, x.resultado_at, x.nueva_fecha_fin, x.motivo
  from public.cs_renovaciones x
  where x.cliente_id = v.id
  order by public.cs_ren_abierta(x.estado) desc, x.iniciada_at desc
  limit 1
) r on true;


-- =====================================================================
-- 7. PERMISOS
-- =====================================================================
-- create or replace conserva los permisos de lo que ya existía. Solo
-- hace falta darlos en lo nuevo.

-- cs_ren_abierta la usan las vistas (security_invoker) y el trigger
-- before de cs_renovaciones, que corre como el usuario.
revoke all on function public.cs_ren_abierta(text) from public, anon;
grant execute on function public.cs_ren_abierta(text) to authenticated;

revoke all on table public.cs_v_maestro from anon;
revoke insert, update, delete on table public.cs_v_maestro from authenticated;
grant select on table public.cs_v_maestro to authenticated;

commit;


-- =====================================================================
-- 8. PRUEBA DE HUMO (no deja datos)
-- =====================================================================
-- Crea un programa propio (humo037) para que los números sean exactos.
-- Clientes a 10 días de vencer (dentro del aviso de 30), cargados como
-- 'activo' y sin accionables, para que el semáforo dependa solo de la
-- renovación. Al final fuerza un error para deshacer TODO, incluido lo
-- que cs_generar_alertas y cs_cerrar_vencidos le hagan a datos reales.
drop table if exists pg_temp.cs_smoke37;
create temp table cs_smoke37 (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res      text[] := '{}';
  v_x      uuid;      -- cliente para reglas, alertas, prioridad y borrado
  v_cli    uuid;
  v_ren    uuid;
  v_ren_x  uuid;
  v_ren_up uuid;
  v_prod   text;
  v_fecha  date;
  v_fecha2 date;
  v_n      int;
  v_n2     int;
  v_txt    text;
  v_txt2   text;
  v_state  text;
  v_ok     boolean;
begin
  begin
    insert into public.cs_programas (id, nombre, activo) values ('humo037', '__humo037__', true);

    -- ---------- cliente X: reglas del pipeline ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo037', '__humo037_x', public.cs_hoy() - 80, public.cs_hoy() + 10, 'activo')
    returning id into v_x;
    delete from public.cs_accionables where cliente_id = v_x;

    -- 1. sin renovación y a 10 días: rojo (línea base)
    select semaforo into v_txt from public.cs_v_clientes where id = v_x;
    res := res || format('sin renovacion a 10 dias -> rojo|%s|semaforo=%s', v_txt = 'rojo', v_txt);

    -- 2. alerta renovacion_proxima creada
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_x and tipo = 'renovacion_proxima' and resuelta = false;
    res := res || format('sin renovacion -> alerta renovacion_proxima|%s|abiertas=%s', v_n = 1, v_n);

    -- 3. abrir como en_proceso (camino viejo de la UI) -> cliente en_renovacion
    insert into public.cs_renovaciones (cliente_id) values (v_x) returning id into v_ren_x;
    select estado into v_txt from public.cs_clientes where id = v_x;
    res := res || format('en_proceso -> cliente en_renovacion|%s|estado=%s', v_txt = 'en_renovacion', v_txt);

    -- 4. en_proceso -> contactado
    update public.cs_renovaciones set estado = 'contactado' where id = v_ren_x;
    select estado into v_txt from public.cs_renovaciones where id = v_ren_x;
    res := res || format('en_proceso -> contactado|%s|estado=%s', v_txt = 'contactado', v_txt);

    -- 5. contactado cuenta como iniciada: amarillo, no rojo
    select semaforo, array_to_string(motivos_semaforo, ' / ') into v_txt, v_txt2
    from public.cs_v_clientes where id = v_x;
    res := res || format('contactado -> amarillo|%s|semaforo=%s (%s)',
                         v_txt = 'amarillo', v_txt, replace(coalesce(v_txt2, ''), '|', '/'));

    -- 6. ...y la alerta renovacion_proxima se resuelve
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_x and tipo = 'renovacion_proxima' and resuelta = false;
    res := res || format('contactado -> alerta renovacion_proxima resuelta|%s|abiertas=%s', v_n = 0, v_n);

    -- 7. segunda renovación abierta (otro estado abierto) se rechaza
    begin
      insert into public.cs_renovaciones (cliente_id, estado) values (v_x, 'propuesta_enviada');
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('una sola renovacion abierta por cliente|%s|sqlstate=%s', v_state = '23505', v_state);

    -- 8. producto con la renovación abierta se rechaza
    begin
      update public.cs_renovaciones set resell_producto = 'upgrade' where id = v_ren_x;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('producto con la renovacion abierta se rechaza|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 9. cerrar como renovado SIN producto se rechaza (update)
    begin
      update public.cs_renovaciones
         set estado = 'renovado', nueva_fecha_fin = public.cs_hoy() + 90
       where id = v_ren_x;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('renovado sin producto se rechaza (update)|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 10. insertar directo como renovado SIN producto se rechaza
    begin
      insert into public.cs_renovaciones (cliente_id, estado, nueva_fecha_fin)
      values (v_x, 'renovado', public.cs_hoy() + 90);
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('renovado sin producto se rechaza (insert)|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 11. borrar una renovación abierta en una etapa nueva destraba al cliente
    update public.cs_renovaciones set estado = 'call_agendada' where id = v_ren_x;
    delete from public.cs_renovaciones where id = v_ren_x;
    select estado into v_txt from public.cs_clientes where id = v_x;
    res := res || format('borrar renovacion en call_agendada -> cliente activo|%s|estado=%s', v_txt = 'activo', v_txt);

    -- ---------- pipeline completo, un cliente por producto ----------
    foreach v_prod in array array['mismo_programa', 'upgrade', 'downgrade', 'otro'] loop
      insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
      values ('humo037', '__humo037_' || v_prod, public.cs_hoy() - 80, public.cs_hoy() + 10, 'activo')
      returning id into v_cli;
      delete from public.cs_accionables where cliente_id = v_cli;

      insert into public.cs_renovaciones (cliente_id, estado) values (v_cli, 'contactado') returning id into v_ren;
      update public.cs_renovaciones set estado = 'call_agendada'     where id = v_ren;
      update public.cs_renovaciones set estado = 'propuesta_enviada' where id = v_ren;
      select estado into v_txt2 from public.cs_clientes where id = v_cli;

      -- el downgrade compra un programa más corto: fecha_fin puede quedar antes
      v_fecha := public.cs_hoy() + case v_prod when 'upgrade' then 180 when 'downgrade' then 5 else 90 end;
      update public.cs_renovaciones
         set estado = 'renovado', resell_producto = v_prod, nueva_fecha_fin = v_fecha
       where id = v_ren;
      if v_prod = 'upgrade' then v_ren_up := v_ren; end if;

      select c.estado, c.fecha_fin, c.renovaciones_count into v_txt, v_fecha2, v_n
      from public.cs_clientes c where c.id = v_cli;
      select (r.resultado_at is not null) into v_ok from public.cs_renovaciones r where r.id = v_ren;
      res := res || format('pipeline -> renovado (%s): cliente activo, fecha_fin nueva, contador|%s|en pipeline=%s; al cerrar estado=%s fin_ok=%s contador=%s resultado_at=%s',
                           v_prod,
                           v_txt2 = 'en_renovacion' and v_txt = 'activo' and v_fecha2 = v_fecha and v_n = 1 and v_ok,
                           v_txt2, v_txt, v_fecha2 = v_fecha, v_n, v_ok);

      -- historial de la renovación: contactado, call_agendada, propuesta_enviada, renovado + producto
      select string_agg(h.valor_nuevo, '>' order by h.id) into v_txt
      from public.cs_historial h
      where h.registro_id = v_ren and h.tabla = 'cs_renovaciones' and h.campo = 'estado';
      select count(*) into v_n from public.cs_historial h
      where h.registro_id = v_ren and h.tabla = 'cs_renovaciones' and h.campo = 'resell_producto'
        and h.valor_anterior is null and h.valor_nuevo = v_prod;
      res := res || format('historial del pipeline (%s)|%s|estado=%s producto=%s',
                           v_prod,
                           v_txt = 'contactado>call_agendada>propuesta_enviada>renovado' and v_n = 1,
                           v_txt, v_n);
    end loop;

    -- 20. el producto de una renovación cerrada no se cambia
    begin
      update public.cs_renovaciones set resell_producto = 'otro' where id = v_ren_up;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('producto de una renovacion cerrada no se cambia|%s|sqlstate=%s', v_state = '23514', v_state);

    -- ---------- no_renovado desde propuesta_enviada ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo037', '__humo037_perdido', public.cs_hoy() - 80, public.cs_hoy() + 10, 'activo')
    returning id into v_cli;
    delete from public.cs_accionables where cliente_id = v_cli;
    insert into public.cs_renovaciones (cliente_id, estado) values (v_cli, 'propuesta_enviada') returning id into v_ren;

    -- 21. no_renovado con producto se rechaza
    begin
      update public.cs_renovaciones
         set estado = 'no_renovado', resell_producto = 'downgrade', motivo = 'Precio'
       where id = v_ren;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('no_renovado con producto se rechaza|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 22. no_renovado con motivo: cliente activo, resultado_at puesto, producto null
    update public.cs_renovaciones set estado = 'no_renovado', motivo = 'Precio' where id = v_ren;
    select c.estado into v_txt from public.cs_clientes c where c.id = v_cli;
    select (r.resultado_at is not null), r.resell_producto, r.motivo into v_ok, v_txt2, v_state
    from public.cs_renovaciones r where r.id = v_ren;
    res := res || format('propuesta_enviada -> no_renovado|%s|cliente=%s resultado_at=%s producto=%s motivo=%s',
                         v_txt = 'activo' and v_ok and v_txt2 is null and v_state = 'Precio',
                         v_txt, v_ok, coalesce(v_txt2, 'null'), v_state);

    -- ---------- métricas ----------
    -- 23. tasa: 4 renovados (uno de cada producto) y 1 no renovado = 80.0
    select k.tasa_renovacion::text || ' mismo=' || k.ren_mismo_programa || ' up=' || k.ren_upgrade
           || ' down=' || k.ren_downgrade || ' otro=' || k.ren_otro,
           k.tasa_renovacion = 80.0 and k.ren_mismo_programa = 1 and k.ren_upgrade = 1
           and k.ren_downgrade = 1 and k.ren_otro = 1
      into v_txt, v_ok
    from public.cs_v_kpis_programa k where k.programa_id = 'humo037';
    res := res || format('kpis: upgrade/downgrade cuentan como renovado + desglose|%s|tasa=%s', coalesce(v_ok, false), v_txt);

    -- 24. mensuales: mismo desglose en el mes actual
    select m.renovados || '/' || m.no_renovados || ' mismo=' || m.renovados_mismo_programa
           || ' up=' || m.renovados_upgrade || ' down=' || m.renovados_downgrade || ' otro=' || m.renovados_otro,
           m.renovados = 4 and m.no_renovados = 1 and m.renovados_mismo_programa = 1
           and m.renovados_upgrade = 1 and m.renovados_downgrade = 1 and m.renovados_otro = 1
      into v_txt, v_ok
    from public.cs_v_metricas_mensuales m
    where m.programa_id = 'humo037'
      and m.mes = date_trunc('month', public.cs_hoy())::date;
    res := res || format('metricas mensuales con desglose por producto|%s|ren/noren=%s', coalesce(v_ok, false), v_txt);

    -- ---------- campos del CSM + historial ----------
    -- 25. prioridad inválida se rechaza
    begin
      update public.cs_clientes set prioridad = 'urgente' where id = v_x;
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('prioridad invalida se rechaza|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 26. dos cambios de prioridad = dos filas en cs_historial
    update public.cs_clientes set prioridad = 'alta' where id = v_x;
    update public.cs_clientes set prioridad = 'baja' where id = v_x;
    select string_agg(coalesce(h.valor_anterior, 'null') || '->' || h.valor_nuevo, ', ' order by h.id) into v_txt
    from public.cs_historial h
    where h.registro_id = v_x and h.tabla = 'cs_clientes' and h.campo = 'prioridad';
    res := res || format('cambios de prioridad en cs_historial|%s|%s',
                         v_txt = 'null->alta, alta->baja', coalesce(v_txt, '(nada)'));

    -- 27. los otros campos del CSM se editan y no ensucian el historial
    update public.cs_clientes
       set proxima_accion = 'Mandar propuesta 1a1', proxima_accion_fecha = public.cs_hoy() + 3,
           nota_csm = 'Interesado en upgrade', responsable = 'Nacho'
     where id = v_x;
    select count(*) into v_n from public.cs_historial h
    where h.registro_id = v_x and h.tabla = 'cs_clientes'
      and h.campo in ('proxima_accion', 'proxima_accion_fecha', 'nota_csm', 'responsable');
    res := res || format('proxima_accion / nota_csm / responsable sin historial|%s|filas=%s', v_n = 0, v_n);

    -- ---------- cs_v_maestro ----------
    -- 28. una fila por cliente del programa
    select count(*), count(distinct id) into v_n, v_n2 from public.cs_v_maestro where programa_id = 'humo037';
    res := res || format('cs_v_maestro: una fila por cliente|%s|filas=%s distintos=%s (esperado 6)',
                         v_n = 6 and v_n2 = 6, v_n, v_n2);

    -- 29. X: editables y sin renovación vigente (se borró)
    select m.prioridad || ' / ' || m.proxima_accion || ' / ' || m.responsable || ' / ' || m.semaforo
           || ' / ren=' || coalesce(m.renovacion_estado, 'null'),
           m.prioridad = 'baja' and m.proxima_accion = 'Mandar propuesta 1a1' and m.nota_csm = 'Interesado en upgrade'
           and m.responsable = 'Nacho' and m.semaforo = 'rojo' and m.renovacion_id is null
      into v_txt, v_ok
    from public.cs_v_maestro m where m.id = v_x;
    res := res || format('cs_v_maestro muestra lo editable|%s|%s', coalesce(v_ok, false), v_txt);

    -- 30. cliente upgrade: renovación vigente y calculados de cs_v_clientes
    select m.renovacion_estado || ' / ' || m.renovacion_producto || ' / renov=' || m.renovaciones_count
           || ' / dias=' || m.dias_restantes || ' / ' || m.estado,
           m.renovacion_estado = 'renovado' and m.renovacion_producto = 'upgrade' and m.renovaciones_count = 1
           and m.dias_restantes = 180 and m.estado = 'activo'
           and m.semaforo = v.semaforo and m.dev_pendientes = v.dev_pendientes
      into v_txt, v_ok
    from public.cs_v_maestro m
    join public.cs_v_clientes v on v.id = m.id
    where m.renovacion_id = v_ren_up;
    res := res || format('cs_v_maestro trae renovacion vigente y calculados|%s|%s', coalesce(v_ok, false), v_txt);

    -- ---------- chequeo diario y días de gracia (default 30) ----------
    -- Cliente DENTRO de la gracia: venció hace 2 días, propuesta enviada.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo037', '__humo037_en_gracia', public.cs_hoy() - 100, public.cs_hoy() - 2, 'activo')
    returning id into v_cli;
    delete from public.cs_accionables where cliente_id = v_cli;
    insert into public.cs_renovaciones (cliente_id, estado) values (v_cli, 'propuesta_enviada') returning id into v_ren;
    perform public.cs_cerrar_vencidos();

    -- 31. el cliente pasa a finalizado, la renovación sigue abierta
    select c.estado into v_txt from public.cs_clientes c where c.id = v_cli;
    select r.estado into v_txt2 from public.cs_renovaciones r where r.id = v_ren;
    res := res || format('dentro de la gracia: cliente finalizado, pipeline abierto|%s|cliente=%s ren=%s',
                         v_txt = 'finalizado' and v_txt2 = 'propuesta_enviada', v_txt, v_txt2);

    -- 32. finalizado con pipeline abierto: no queda en rojo por renovación
    select semaforo, array_to_string(motivos_semaforo, ' / ') into v_txt, v_txt2
    from public.cs_v_clientes where id = v_cli;
    res := res || format('finalizado con pipeline abierto no queda rojo|%s|semaforo=%s (%s)',
                         v_txt <> 'rojo' and coalesce(v_txt2, '') not like '%renovaci%',
                         v_txt, replace(coalesce(v_txt2, ''), '|', '/'));

    -- 33. mover el pipeline no revive al cliente (sigue finalizado)
    update public.cs_renovaciones set estado = 'call_agendada' where id = v_ren;
    perform public.cs_cerrar_vencidos();
    select c.estado into v_txt from public.cs_clientes c where c.id = v_cli;
    select r.estado into v_txt2 from public.cs_renovaciones r where r.id = v_ren;
    res := res || format('mover etapa dentro de la gracia: cliente sigue finalizado|%s|cliente=%s ren=%s',
                         v_txt = 'finalizado' and v_txt2 = 'call_agendada', v_txt, v_txt2);

    -- 34. cerrar como renovado dentro de la gracia reactiva al cliente
    update public.cs_renovaciones
       set estado = 'renovado', resell_producto = 'upgrade', nueva_fecha_fin = public.cs_hoy() + 180
     where id = v_ren;
    select c.estado, c.fecha_fin into v_txt, v_fecha from public.cs_clientes c where c.id = v_cli;
    res := res || format('renovado dentro de la gracia -> cliente activo|%s|cliente=%s fin_ok=%s',
                         v_txt = 'activo' and v_fecha = public.cs_hoy() + 180, v_txt, v_fecha = public.cs_hoy() + 180);

    -- Cliente FUERA de la gracia: venció hace 31 días (gracia 30), contactado.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo037', '__humo037_sin_gracia', public.cs_hoy() - 130, public.cs_hoy() - 31, 'activo')
    returning id into v_cli;
    insert into public.cs_renovaciones (cliente_id, estado) values (v_cli, 'contactado') returning id into v_ren;
    perform public.cs_cerrar_vencidos();

    -- 35. el cliente pasa a finalizado y la renovación se cierra con el motivo de siempre
    select c.estado into v_txt from public.cs_clientes c where c.id = v_cli;
    select r.estado || ' / ' || coalesce(r.motivo, 'null') || ' / producto=' || coalesce(r.resell_producto, 'null')
      into v_txt2 from public.cs_renovaciones r where r.id = v_ren;
    res := res || format('pasada la gracia: cliente finalizado, pipeline cerrado|%s|cliente=%s ren=%s',
                         v_txt = 'finalizado' and v_txt2 = 'no_renovado / Vencido sin respuesta / producto=null',
                         v_txt, v_txt2);

    -- 36. la gracia es por programa
    update public.cs_programas set resell_gracia_dias = 0 where id = 'humo037';
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo037', '__humo037_gracia_cero', public.cs_hoy() - 100, public.cs_hoy() - 1, 'activo')
    returning id into v_cli;
    insert into public.cs_renovaciones (cliente_id, estado) values (v_cli, 'contactado') returning id into v_ren;
    perform public.cs_cerrar_vencidos();
    select r.estado into v_txt from public.cs_renovaciones r where r.id = v_ren;
    res := res || format('gracia 0 en el programa: se cierra al dia siguiente de vencer|%s|ren=%s',
                         v_txt = 'no_renovado', v_txt);

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s (%s)', replace(sqlerrm, '|', '/'), sqlstate);
    end if;
  end;

  insert into cs_smoke37 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 9. QUERY DE CONTROL (una sola tabla de resultados; mirar la columna ok)
-- =====================================================================
with
cols as (
  select table_name::text as t, column_name::text as c
  from information_schema.columns
  where table_schema = 'public' and table_name in ('cs_clientes', 'cs_renovaciones')
),
vistas as (
  select c.oid, c.relname::text as relname, coalesce(array_to_string(c.reloptions, ','), '') as opts
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v'
    and c.relname in ('cs_v_clientes', 'cs_v_kpis_programa', 'cs_v_metricas_mensuales', 'cs_v_maestro')
),
trg as (
  select c.relname::text as relname, pg_get_triggerdef(t.oid) as def
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where t.tgname = 'cs_trg_historial' and c.relname in ('cs_clientes', 'cs_renovaciones')
),
estado_chk as (
  select string_agg(pg_get_constraintdef(c.oid), ' ; ') as def, count(*) as n
  from pg_constraint c
  where c.conrelid = 'public.cs_renovaciones'::regclass and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ~ 'en_proceso'
),
tasa as (
  select a.programa_id, a.tasa_renovacion as antes, k.tasa_renovacion as despues
  from cs_037_antes_tasa a
  left join public.cs_v_kpis_programa k on k.programa_id = a.programa_id
),
sem as (
  select count(*) filter (where v.id is null or v.semaforo is distinct from a.semaforo
                                or v.renovacion_estado is distinct from a.renovacion_estado) as difieren,
         count(*) as total
  from cs_037_antes_sem a
  left join public.cs_v_clientes v on v.id = a.id
)
select '01 columnas del CSM en cs_clientes' as control, 'prioridad, proxima_accion, proxima_accion_fecha, nota_csm' as objeto,
       '4' as esperado,
       (select count(*) from cols where t = 'cs_clientes'
          and c in ('prioridad', 'proxima_accion', 'proxima_accion_fecha', 'nota_csm'))::text as obtenido,
       (select count(*) from cols where t = 'cs_clientes'
          and c in ('prioridad', 'proxima_accion', 'proxima_accion_fecha', 'nota_csm')) = 4 as ok
union all
select '02 resell_producto en cs_renovaciones', 'columna', '1',
       (select count(*) from cols where t = 'cs_renovaciones' and c = 'resell_producto')::text,
       (select count(*) from cols where t = 'cs_renovaciones' and c = 'resell_producto') = 1
union all
select '02 resell_gracia_dias en cs_programas', 'columna (default 30)', '1',
       (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'cs_programas' and column_name = 'resell_gracia_dias')::text,
       (select count(*) from information_schema.columns
        where table_schema = 'public' and table_name = 'cs_programas' and column_name = 'resell_gracia_dias') = 1
union all
select '03 CHECK de estado', 'un solo check, con los 6 estados', 'n=1 con propuesta_enviada',
       'n=' || e.n || ' ' || left(coalesce(e.def, ''), 160),
       e.n = 1 and e.def ~ 'contactado' and e.def ~ 'call_agendada' and e.def ~ 'propuesta_enviada'
from estado_chk e
union all
select '04 renovados sin producto', 'cs_renovaciones estado=renovado', '0',
       (select count(*) from public.cs_renovaciones where estado = 'renovado' and resell_producto is null)::text,
       (select count(*) from public.cs_renovaciones where estado = 'renovado' and resell_producto is null) = 0
union all
select '04 renovados rellenados como mismo_programa', 'informativo', '(lo que haya)',
       (select count(*) from public.cs_renovaciones where estado = 'renovado' and resell_producto = 'mismo_programa')::text,
       true
union all
select '05 indice una abierta por cliente', 'cs_renovaciones_una_abierta existe / una_en_proceso no', 'true / false',
       (to_regclass('public.cs_renovaciones_una_abierta') is not null)::text || ' / '
         || (to_regclass('public.cs_renovaciones_una_en_proceso') is not null)::text,
       to_regclass('public.cs_renovaciones_una_abierta') is not null
         and to_regclass('public.cs_renovaciones_una_en_proceso') is null
union all
select '06 security_invoker', v.relname, 'security_invoker=on', v.opts, v.opts ~ 'security_invoker=(on|true)'
from vistas v
union all
select '07 permisos cs_v_maestro', 'anon select / authenticated select', 'false / true',
       has_table_privilege('anon', 'public.cs_v_maestro', 'SELECT')::text || ' / '
         || has_table_privilege('authenticated', 'public.cs_v_maestro', 'SELECT')::text,
       not has_table_privilege('anon', 'public.cs_v_maestro', 'SELECT')
         and has_table_privilege('authenticated', 'public.cs_v_maestro', 'SELECT')
union all
select '07 permisos cs_ren_abierta', 'anon / authenticated', 'false / true',
       has_function_privilege('anon', 'public.cs_ren_abierta(text)', 'EXECUTE')::text || ' / '
         || has_function_privilege('authenticated', 'public.cs_ren_abierta(text)', 'EXECUTE')::text,
       not has_function_privilege('anon', 'public.cs_ren_abierta(text)', 'EXECUTE')
         and has_function_privilege('authenticated', 'public.cs_ren_abierta(text)', 'EXECUTE')
union all
select '08 historial', t.relname,
       case t.relname when 'cs_clientes' then 'estado, fecha_fin, prioridad' else 'estado, resell_producto' end,
       substring(t.def from 'OF (.*) ON'),
       case t.relname when 'cs_clientes' then t.def ~ 'prioridad' and t.def ~ 'fecha_fin'
                      else t.def ~ 'resell_producto' and t.def ~ 'OF estado' end
from trg t
union all
select '09 tasa de renovacion igual que antes', t.programa_id,
       coalesce(t.antes::text, 'null'), coalesce(t.despues::text, 'null'),
       t.antes is not distinct from t.despues
from tasa t
union all
select '10 semaforo igual que antes', 'clientes existentes que cambiaron', '0',
       s.difieren || ' de ' || s.total, s.difieren = 0
from sem s
union all
select '11 cs_v_clientes mismas columnas', 'nombres y orden', '(los de antes)',
       case when (select cols from cs_037_antes_cols)
                 = (select string_agg(column_name::text, ',' order by ordinal_position)
                    from information_schema.columns
                    where table_schema = 'public' and table_name = 'cs_v_clientes')
            then 'iguales' else 'DISTINTAS' end,
       (select cols from cs_037_antes_cols)
         = (select string_agg(column_name::text, ',' order by ordinal_position)
            from information_schema.columns
            where table_schema = 'public' and table_name = 'cs_v_clientes')
union all
select '12 la prueba de humo no dejo datos', 'programa humo037 / clientes __humo037_', '0',
       ((select count(*) from public.cs_programas where id = 'humo037')
        + (select count(*) from public.cs_clientes where nombre like '\_\_humo037\_%'))::text,
       ((select count(*) from public.cs_programas where id = 'humo037')
        + (select count(*) from public.cs_clientes where nombre like '\_\_humo037\_%')) = 0
union all
select '13 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke37 s
order by 1, 2;
