-- =====================================================================
-- 128-producto-teo-duracion-meses-y-renovaciones.sql  ·  PRODUCTO: duración en meses (teo 4 + renovación 6)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), DESPUÉS de mirar la vista previa
-- (128a-producto-teo-duracion-vista-previa.sql) y de que Joaquín dé el visto bueno a los números.
-- Evitar los minutos :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- Requiere 039 (productos y ciclo), 070 (cs_norm_nombre, cs_norm_tel, pago_clave) y 071 (campos_extra).
-- NO tiene datos personales. Contiene el UPDATE de los alumnos de teo (cs_clientes.programa_id = 'teo').
--
-- Dónde estaba la lógica de duración (039):
--   * alta sin fecha_fin  -> cs_tg_clientes_before: fecha_inicio + cs_productos.duracion_dias del producto
--     (o cs_programas.duracion_default_dias, o 90).
--   * renovación cerrada como 'renovado' sin nueva_fecha_fin -> cs_tg_renovaciones_before:
--     mayor(fecha_fin vigente, hoy) + duracion_dias del producto; la aplica cs_tg_renovaciones_after.
--   * el chequeo diario (cs_cerrar_vencidos) finaliza a quien vence sin renovación 'renovado' vigente.
--
-- Qué hace:
--   1. cs_programas: columnas duracion_inicial_meses y duracion_renovacion_meses (1 a 60, null = "usar la
--      lógica actual en días"). Solo teo se carga: 4 y 6. Liam y agus quedan en null: NO cambian.
--   2. Reemplaza 3 funciones (respaldadas en cs_bak_128_funciones). Con meses cargados en el programa:
--        alta sin fecha_fin  -> fecha_inicio + N meses calendario (gana sobre los días del producto);
--        renovación sin fecha -> mayor(fin vigente, hoy) + N meses calendario, con o sin producto;
--        al renovar, se guarda campos_extra.renovacion {meses, pago_fecha, desde, hasta, origen: 'app'} para
--        que la ficha muestre "Renovado (6 meses)". Con fecha explícita manda la explícita (como antes).
--      Programas sin meses: el comportamiento es idéntico al de la 039.
--   3. Recalcula los alumnos de teo (ver la regla en la vista previa 128a):
--        fecha_fin = fecha_inicio + 4 meses, o mayor(fin del primer ciclo, pago) + 6 meses si Finanzas muestra
--        una renovación segura = pago cruzado por nombre cuyo concepto contiene la palabra RESELL (incluye
--        CUOTA RESELL, UPSELL / RESELL, COMPLETA UPSELL / RESELL) o "renov"; el primero de ellos marca la
--        fecha, y otro separado por más de 5 meses NO se encadena (queda dudoso).
--        UPSELL solo, FEE, PIF, 2DA CUOTA, etc. NO renuevan ni cambian fechas.
--        CASO PRIMER PAGO: si el primer pago de Finanzas del alumno (el que definió su fecha_inicio en la 125) es
--        RESELL / renov, ese ciclo ya es la renovación: fecha_fin = fecha de ese pago + 6 meses (no 4 + 6) y
--        queda "Renovado (6 meses)" con campos_extra.renovacion.primer_pago = true.
--        estado: activo si fecha_fin >= hoy, finalizado si ya pasó; baja y pausado no cambian de estado.
--      Los pagos dudosos NO se renuevan: quedan marcados en campos_extra.dur128.dudosa (la ficha lo avisa).
--      Respaldo previo de cada fila que toca en cs_bak_128_clientes (fecha_fin, estado, campos_extra).
--      Idempotente: marca cada fila con campos_extra.dur128; la 2da corrida no toca a nadie.
--      Durante el UPDATE se apaga el trigger cs_trg_after_cierre (offboarding): igual que la carga de la 125,
--      no se generan accionables de cierre por esta corrección de fechas. Se vuelve a prender en la misma
--      transacción.
--
-- Qué NO toca: liam, agus, Fathom, aviso de servicio, finanzas (solo lee fin_pagos), crm, ventas,
-- cs_renovaciones (no inserta renovaciones: las detectadas viven en campos_extra), renovaciones_count.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Parámetros del recálculo (deben coincidir con los de la vista previa 128a).
-- v_permitir_sin_finanzas: si Finanzas no tiene pagos de teo la migración se frena (no se renovaría a nadie
-- por falta de datos, y eso es una decisión). Poner true solo si se acepta recalcular sin renovaciones.
create temp table cfg128 on commit drop as
select 4::int as m_ini, 6::int as m_ren, false as permitir_sin_finanzas;

-- Autochequeo: lo que usa esta migración tiene que existir.
do $$
declare
  v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values
    ('cs_hoy()'), ('cs_norm_nombre(text)'), ('cs_norm_tel(text)'),
    ('cs_tg_clientes_before()'), ('cs_tg_renovaciones_before()'), ('cs_tg_renovaciones_after()'),
    ('cs_ren_abierta(text)')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 128: faltan funciones: % (corrieron 039 y 070?)', v_falta;
  end if;
  if not exists (select 1 from public.cs_programas where id = 'teo') then
    raise exception 'cs 128: no existe el programa teo';
  end if;
  if to_regclass('public.fin_pagos') is null then
    raise exception 'cs 128: no existe fin_pagos (Finanzas)';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'cs_clientes' and column_name = 'campos_extra') then
    raise exception 'cs 128: falta cs_clientes.campos_extra (071)';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.cs_clientes'::regclass
                 and tgname = 'cs_trg_after_cierre') then
    raise exception 'cs 128: falta el trigger cs_trg_after_cierre en cs_clientes (039)';
  end if;
  if (select count(*) from public.fin_pagos where cliente_id = 'teo') = 0
     and not (select permitir_sin_finanzas from cfg128) then
    raise exception 'cs 128: fin_pagos no tiene pagos de teo (cliente_id = teo). Revisar con la vista previa Q4.';
  end if;
end $$;

-- Locks juntos al principio (regla del deadlock): lo que tocan los triggers y el UPDATE.
lock table public.cs_programas, public.cs_clientes, public.cs_renovaciones, public.cs_accionables, public.cs_historial
  in share row exclusive mode;

-- ---------------------------------------------------------------------
-- 0. Respaldos
-- ---------------------------------------------------------------------
create table if not exists public.cs_bak_128_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_128_funciones from public, anon, authenticated;
insert into public.cs_bak_128_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('cs_tg_clientes_before', 'cs_tg_renovaciones_before', 'cs_tg_renovaciones_after')
on conflict (funcion) do nothing;

create table if not exists public.cs_bak_128_clientes (
  id           uuid primary key,
  fecha_fin    date not null,
  estado       text not null,
  campos_extra jsonb not null,
  respaldada   timestamptz not null default now()
);
revoke all on table public.cs_bak_128_clientes from public, anon, authenticated;


-- =====================================================================
-- 1. DURACIÓN EN MESES POR PROGRAMA (null = usar la lógica actual)
-- =====================================================================
alter table public.cs_programas
  add column if not exists duracion_inicial_meses    int,
  add column if not exists duracion_renovacion_meses int;

alter table public.cs_programas drop constraint if exists cs_programas_dur_inicial_meses_chk;
alter table public.cs_programas add constraint cs_programas_dur_inicial_meses_chk
  check (duracion_inicial_meses is null or duracion_inicial_meses between 1 and 60);
alter table public.cs_programas drop constraint if exists cs_programas_dur_renov_meses_chk;
alter table public.cs_programas add constraint cs_programas_dur_renov_meses_chk
  check (duracion_renovacion_meses is null or duracion_renovacion_meses between 1 and 60);

comment on column public.cs_programas.duracion_inicial_meses is
  '128: meses calendario del programa. null = lógica de días (producto o duracion_default_dias). Con valor, manda sobre los días.';
comment on column public.cs_programas.duracion_renovacion_meses is
  '128: meses calendario que suma una renovación. null = lógica de días del producto. Con valor, manda sobre los días.';

-- Solo teo, y solo si nadie lo cargó antes (no pisa un cambio hecho desde Configuración).
update public.cs_programas
   set duracion_inicial_meses = (select m_ini from cfg128),
       duracion_renovacion_meses = (select m_ren from cfg128)
 where id = 'teo' and duracion_inicial_meses is null and duracion_renovacion_meses is null;


-- =====================================================================
-- 2. FUNCIONES (copia de 039 + meses)
-- =====================================================================

-- ---------- antes de guardar un cliente: fecha_fin por meses ----------
-- Idéntica a 039 salvo el bloque "fecha_fin por defecto": con duracion_inicial_meses del programa,
-- fecha_inicio + N meses calendario (gana sobre los días del producto).
create or replace function public.cs_tg_clientes_before()
returns trigger language plpgsql set search_path = public
as $$
declare
  v_dur   int;
  v_prog  text;
  v_meses int;
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
    select p.duracion_inicial_meses into v_meses from public.cs_programas p where p.id = new.programa_id;
    if v_meses is not null then
      new.fecha_fin := (new.fecha_inicio + make_interval(months => v_meses))::date;
    else
      if new.producto_id is not null then
        select pr.duracion_dias into v_dur from public.cs_productos pr where pr.id = new.producto_id;
      else
        select p.duracion_default_dias into v_dur from public.cs_programas p where p.id = new.programa_id;
      end if;
      new.fecha_fin := new.fecha_inicio + coalesce(v_dur, 90);
    end if;
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

-- ---------- antes de guardar una renovación: nueva_fecha_fin por meses ----------
-- Idéntica a 039 salvo el bloque "nueva_fecha_fin": con duracion_renovacion_meses del programa,
-- mayor(fin vigente (corrida por la pausa si está pausado), hoy) + N meses calendario, con o sin producto.
-- Sin meses: igual que 039 (solo con producto, + duracion_dias).
create or replace function public.cs_tg_renovaciones_before()
returns trigger language plpgsql set search_path = public
as $$
declare
  v_prog  text;
  v_dur   int;
  v_base  date;
  v_meses int;
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

  -- nueva_fecha_fin: por meses del programa (128) o desde el producto (039)
  if new.estado = 'renovado' and new.nueva_fecha_fin is null
     and (tg_op = 'INSERT' or old.estado <> 'renovado') then
    select p.duracion_renovacion_meses into v_meses from public.cs_programas p where p.id = new.programa_id;
    if v_meses is not null or new.producto_id is not null then
      select greatest(c.fecha_fin
                        + case when c.estado = 'pausado'
                               then greatest(public.cs_hoy() - c.pausado_desde, 0) else 0 end,
                      public.cs_hoy())
        into v_base
      from public.cs_clientes c where c.id = new.cliente_id;
      if v_meses is not null then
        new.nueva_fecha_fin := (v_base + make_interval(months => v_meses))::date;
      else
        select pr.duracion_dias into v_dur from public.cs_productos pr where pr.id = new.producto_id;
        new.nueva_fecha_fin := v_base + v_dur;
      end if;
    end if;
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
-- Idéntica a 039 salvo la rama 'renovado': si el programa tiene duracion_renovacion_meses, guarda en
-- campos_extra.renovacion {meses, pago_fecha, desde, hasta, origen}. 'meses' queda solo si la fecha
-- nueva es justo base + N meses (si alguien puso otra fecha a mano, se muestra "Renovado" sin meses).
create or replace function public.cs_tg_renovaciones_after()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_meses int;
  v_fin   date;
  v_est   text;
  v_pd    date;
  v_base  date;
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
    select p.duracion_renovacion_meses into v_meses from public.cs_programas p where p.id = new.programa_id;
    select c.fecha_fin, c.estado, c.pausado_desde into v_fin, v_est, v_pd
      from public.cs_clientes c where c.id = new.cliente_id;
    v_base := greatest(v_fin + case when v_est = 'pausado' then greatest(public.cs_hoy() - v_pd, 0) else 0 end,
                       public.cs_hoy());
    update public.cs_clientes c
       set estado = 'activo',
           fecha_fin = new.nueva_fecha_fin,
           renovaciones_count = c.renovaciones_count + 1,
           producto_id = coalesce(new.producto_id, c.producto_id),
           aviso_1_at = null,
           aviso_2_at = null,
           campos_extra = case when v_meses is null then c.campos_extra
             else c.campos_extra || jsonb_build_object('renovacion', jsonb_strip_nulls(jsonb_build_object(
                    'meses', case when new.nueva_fecha_fin = (v_base + make_interval(months => v_meses))::date
                                  then v_meses end,
                    'pago_fecha', (new.resultado_at at time zone 'America/Argentina/Buenos_Aires')::date,
                    'desde', v_base,
                    'hasta', new.nueva_fecha_fin,
                    'origen', 'app'))) end
     where c.id = new.cliente_id;

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


-- =====================================================================
-- 3. RECÁLCULO DE LOS ALUMNOS DE TEO
-- =====================================================================
-- Mismas reglas y mismo SQL que la vista previa 128a (leer ahí la regla de renovación).
create temp table plan128 on commit drop as
with params as (
  select c.m_ini, c.m_ren, public.cs_hoy() as hoy from cfg128 c
),
al as (
  select c.id, c.nombre, c.estado, c.fecha_inicio, c.fecha_fin as fin_actual,
         (c.fecha_inicio + make_interval(months => p.m_ini))::date as fin_inicial,
         public.cs_norm_nombre(c.nombre) as nom,
         public.cs_norm_tel(c.telefono)  as tel,
         case when c.campos_extra->>'ultimo_pago' ~ '^\d{4}-\d{2}-\d{2}$'
              then (c.campos_extra->>'ultimo_pago')::date end as ultimo_pago_planilla,
         (c.campos_extra ? 'dur128') as ya_128,
         (select r.nueva_fecha_fin from public.cs_renovaciones r
           where r.cliente_id = c.id and r.estado = 'renovado'
           order by r.resultado_at desc nulls last limit 1) as ren_app_fin
  from public.cs_clientes c cross join params p
  where c.programa_id = 'teo'
),
pagos as (
  select a.id, f.fecha, btrim(coalesce(f.concepto, '')) as concepto,
         case when public.cs_norm_nombre(f.alumno) = a.nom then 'nombre' else 'telefono' end as via
  from al a
  join public.fin_pagos f
    on f.cliente_id = 'teo'
   and (public.cs_norm_nombre(f.alumno) = a.nom
        or (a.tel is not null and public.cs_norm_tel(f.telefono) = a.tel))
),
cls0 as (
  select h.id, h.fecha, h.concepto, h.via, h.fin_inicial, h.es_primero,
         case when (h.es_primero or h.fecha > h.fecha_inicio) and h.concepto ~* 'renov' then 'renov'
              when (h.es_primero or h.fecha > h.fecha_inicio) and h.concepto ~* '\yresell\y' then 'resell' end as es_ren
  from (select g.id, g.fecha, g.concepto, g.via, a.fin_inicial, a.fecha_inicio,
               -- primer pago cruzado por nombre = el que definió fecha_inicio (125)
               (g.via = 'nombre' and g.fecha <= a.fecha_inicio
                and g.fecha = min(g.fecha) filter (where g.via = 'nombre') over (partition by g.id)) as es_primero
        from pagos g join al a on a.id = g.id) h
),
cls as (
  select c0.id, c0.fecha, c0.concepto, c0.via, c0.es_primero,
         case
           when c0.via = 'nombre' and c0.es_ren is not null
                and c0.fecha <= min(c0.fecha) filter (where c0.via = 'nombre' and c0.es_ren is not null)
                                over (partition by c0.id) + interval '5 months'
             then 'seguro_' || c0.es_ren
           when c0.es_ren is not null or c0.fecha > c0.fin_inicial then 'dudoso'
         end as tipo
  from cls0 c0
),
res as (
  select a.id,
    (select min(x.fecha) from cls x where x.id = a.id and x.tipo like 'seguro%') as pago_ren,
    (select x.tipo from cls x where x.id = a.id and x.tipo like 'seguro%' order by x.fecha limit 1) as tipo_ren,
    exists (select 1 from cls x where x.id = a.id and x.tipo like 'seguro%' and x.es_primero) as primer_pago,
    (select min(x.fecha) from cls x where x.id = a.id and x.tipo = 'dudoso') as pago_dud_fin,
    (select x.concepto from cls x where x.id = a.id and x.tipo = 'dudoso' order by x.fecha limit 1) as concepto_dud,
    case when not exists (select 1 from pagos g where g.id = a.id)
              and a.ultimo_pago_planilla > a.fin_inicial then a.ultimo_pago_planilla end as pago_dud_planilla
  from al a
),
plan as (
  select a.id, a.estado, a.fin_actual, a.fin_inicial, r.pago_ren, r.tipo_ren, r.primer_pago,
         coalesce(r.pago_dud_fin, r.pago_dud_planilla) as pago_dud, r.concepto_dud,
         p.hoy, p.m_ini, p.m_ren,
         (not a.ya_128 and a.estado <> 'pausado' and a.ren_app_fin is null) as tocar,
         case when a.ren_app_fin is not null then 'app'
              when r.pago_ren is not null then 'finanzas'
              when coalesce(r.pago_dud_fin, r.pago_dud_planilla) is not null then 'dudoso'
              else 'ninguna' end as renovacion,
         case when r.pago_ren is not null and a.ren_app_fin is null
              then (case when r.primer_pago then r.pago_ren else greatest(a.fin_inicial, r.pago_ren) end
                    + make_interval(months => p.m_ren))::date
              else a.fin_inicial end as fin_nuevo
  from al a join res r on r.id = a.id cross join params p
)
select pl.*,
       case when pl.estado in ('baja', 'pausado') then pl.estado
            when pl.fin_nuevo >= pl.hoy then case when pl.estado = 'finalizado' then 'activo' else pl.estado end
            else 'finalizado' end as estado_nuevo
from plan pl;

-- Respaldo de lo que se va a tocar (la primera copia manda: si se corre dos veces no pisa el original).
insert into public.cs_bak_128_clientes (id, fecha_fin, estado, campos_extra)
select c.id, c.fecha_fin, c.estado, c.campos_extra
from public.cs_clientes c
join plan128 p on p.id = c.id
where p.tocar
on conflict (id) do nothing;

-- Sin offboarding por esta corrección (ver cabecera). Se vuelve a prender abajo, en esta transacción.
alter table public.cs_clientes disable trigger cs_trg_after_cierre;

update public.cs_clientes c
   set fecha_fin = p.fin_nuevo,
       estado    = p.estado_nuevo,
       campos_extra = c.campos_extra
         || jsonb_build_object('dur128', jsonb_strip_nulls(jsonb_build_object(
              'aplicado', p.hoy,
              'meses_inicial', p.m_ini,
              'renovacion', p.renovacion,
              'primer_pago', case when p.renovacion = 'finanzas' and p.primer_pago then true end,
              'dudosa', case when p.renovacion = 'dudoso'
                             then jsonb_strip_nulls(jsonb_build_object('pago_fecha', p.pago_dud, 'concepto', p.concepto_dud))
                        end)))
         || case when p.renovacion = 'finanzas'
                 then jsonb_build_object('renovacion', jsonb_build_object(
                        'meses', p.m_ren,
                        'pago_fecha', p.pago_ren,
                        'desde', case when p.primer_pago then p.pago_ren else greatest(p.fin_inicial, p.pago_ren) end,
                        'primer_pago', case when p.primer_pago then true end,
                        'hasta', p.fin_nuevo,
                        'origen', 'finanzas'))
                 else '{}'::jsonb end
  from plan128 p
 where p.id = c.id and p.tocar;

alter table public.cs_clientes enable trigger cs_trg_after_cierre;


-- =====================================================================
-- 4. PRUEBA DE HUMO (se revierte sola: subtransacción que termina con una excepción propia)
-- =====================================================================
create temp table cs_smoke128 (orden int, paso text, ok boolean, detalle text) on commit drop;

do $$
declare
  res   text[] := '{}';
  hoy   date := public.cs_hoy();
  v_a   uuid;
  v_b   uuid;
  v_c   uuid;
  v_d   uuid;
  v_f   date;
  v_f2  date;
  v_e   jsonb;
  v_ok  boolean;
begin
  begin
    insert into public.cs_programas (id, nombre, duracion_inicial_meses, duracion_renovacion_meses)
    values ('humo128', 'Humo 128 con meses', 4, 6);
    insert into public.cs_programas (id, nombre) values ('humo128b', 'Humo 128 sin meses');

    -- 1. alta sin fecha_fin con meses: inicio + 4 meses calendario
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado)
    values ('humo128', 'Humo A', hoy - 10, 'activo') returning id into v_a;
    select fecha_fin into v_f from public.cs_clientes where id = v_a;
    res := res || format('alta con meses: fecha_fin = inicio + 4 meses|%s|fin=%s',
                         v_f = ((hoy - 10) + make_interval(months => 4))::date, v_f);

    -- 2. alta sin fecha_fin sin meses: lógica de días de siempre (default 90)
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado)
    values ('humo128b', 'Humo B', hoy - 10, 'activo') returning id into v_b;
    select fecha_fin into v_f from public.cs_clientes where id = v_b;
    res := res || format('alta sin meses: fecha_fin = inicio + 90 dias|%s|fin=%s', v_f = (hoy - 10) + 90, v_f);

    -- 3. fecha_fin explícita: se respeta
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo128', 'Humo X', hoy - 10, hoy + 5, 'activo') returning id into v_c;
    select fecha_fin into v_f from public.cs_clientes where id = v_c;
    res := res || format('fecha_fin explicita la respeta|%s|fin=%s', v_f = hoy + 5, v_f);

    -- 4. renovación sin fecha ni producto con fin vigente futuro: fin + 6 meses
    select fecha_fin into v_f from public.cs_clientes where id = v_a;
    insert into public.cs_renovaciones (cliente_id, estado, resell_producto)
    values (v_a, 'renovado', 'mismo_programa');
    select fecha_fin, campos_extra->'renovacion' into v_f2, v_e from public.cs_clientes where id = v_a;
    res := res || format('renovar: fin vigente + 6 meses|%s|fin=%s', v_f2 = (v_f + make_interval(months => 6))::date, v_f2);
    res := res || format('renovar: queda campos_extra.renovacion con 6 meses y origen app|%s|%s',
                         coalesce((v_e->>'meses') = '6' and (v_e->>'origen') = 'app'
                                  and (v_e->>'hasta')::date = v_f2, false), v_e::text);

    -- 5. renovación con el programa ya vencido: desde hoy + 6 meses
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo128', 'Humo V', hoy - 200, hoy - 20, 'activo') returning id into v_d;
    insert into public.cs_renovaciones (cliente_id, estado, resell_producto)
    values (v_d, 'renovado', 'mismo_programa');
    select fecha_fin into v_f2 from public.cs_clientes where id = v_d;
    res := res || format('renovar vencido: hoy + 6 meses|%s|fin=%s', v_f2 = (hoy + make_interval(months => 6))::date, v_f2);

    -- 6. renovación con fecha explícita (programa sin meses): manda la fecha y no deja campos_extra.renovacion
    insert into public.cs_renovaciones (cliente_id, estado, resell_producto, nueva_fecha_fin)
    values (v_b, 'renovado', 'mismo_programa', hoy + 100);
    select fecha_fin, campos_extra into v_f2, v_e from public.cs_clientes where id = v_b;
    res := res || format('renovar sin meses con fecha explicita: la respeta, sin renovacion en campos_extra|%s|fin=%s',
                         v_f2 = hoy + 100 and not (v_e ? 'renovacion'), v_f2);

    -- 7. regla de concepto de la renovación (la misma de la sección 3): RESELL o renov renuevan;
    --    UPSELL solo, FEE, PIF, 2DA CUOTA, FEE DE PIF, REFUERZA FEE, vacío y "RESELLER" no.
    select bool_and((x.c ~* 'renov' or x.c ~* '\yresell\y') = x.esp) into v_ok
    from (values
      ('RESELL', true), ('CUOTA RESELL', true), ('UPSELL / RESELL', true), ('COMPLETA UPSELL / RESELL', true),
      ('resell', true), ('Renovación', true),
      ('UPSELL', false), ('CUOTA UPSELL', false), ('FEE', false), ('PIF', false), ('FEE DE PIF', false),
      ('2DA CUOTA', false), ('1RA CUOTA', false), ('REFUERZA FEE', false), ('COMPLETA PIF', false),
      ('', false), ('RESELLER', false)
    ) as x(c, esp);
    res := res || format('regla de concepto: RESELL y renov renuevan, UPSELL solo / FEE / PIF no|%s|17 conceptos',
                         coalesce(v_ok, false));

    -- 8. caso primer pago RESELL: el ciclo ya es la renovación, fecha_fin = pago + 6 meses (no 4 + 6).
    --    (Aritmética de la fórmula; la clasificación real corre en la sección 3 y se controla en 10d.)
    v_f := date '2026-03-10';
    res := res || format('primer pago RESELL: fin = pago + 6 meses, no (pago + 4) + 6|%s|fin=%s',
                         (v_f + make_interval(months => 6))::date = date '2026-09-10'
                         and (v_f + make_interval(months => 6))::date
                             <> ((v_f + make_interval(months => 4))::date + make_interval(months => 6))::date,
                         (v_f + make_interval(months => 6))::date);

    raise exception 'HUMO128_FIN';
  exception when others then
    if sqlerrm <> 'HUMO128_FIN' then
      res := res || format('ERROR INESPERADO|false|%s (%s)', replace(sqlerrm, '|', '/'), sqlstate);
    end if;
  end;

  insert into cs_smoke128 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 5. CONTROLES (una sola tabla; mirar la columna ok. Todo tiene que dar true)
-- =====================================================================
with t as (
  select c.*, (c.campos_extra->'dur128') as d
  from public.cs_clientes c where c.programa_id = 'teo'
)
select '01 columnas y valores de teo' as control, 'teo 4 / 6; liam y agus null' as esperado,
       (select string_agg(id || '=' || coalesce(duracion_inicial_meses::text, 'null') || '/'
                          || coalesce(duracion_renovacion_meses::text, 'null'), ', ' order by id)
        from public.cs_programas where id in ('teo', 'liam', 'agus')) as obtenido,
       coalesce((select duracion_inicial_meses = 4 and duracion_renovacion_meses = 6
                 from public.cs_programas where id = 'teo'), false)
       and not exists (select 1 from public.cs_programas
                       where id in ('liam', 'agus') and (duracion_inicial_meses is not null
                                                          or duracion_renovacion_meses is not null)) as ok
union all
select '02 las 3 funciones usan los meses', '3',
       (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
          and p.proname in ('cs_tg_clientes_before', 'cs_tg_renovaciones_before', 'cs_tg_renovaciones_after')
          and pg_get_functiondef(p.oid) ~ 'duracion_(inicial|renovacion)_meses')::text,
       (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
          and p.proname in ('cs_tg_clientes_before', 'cs_tg_renovaciones_before', 'cs_tg_renovaciones_after')
          and pg_get_functiondef(p.oid) ~ 'duracion_(inicial|renovacion)_meses') = 3
union all
select '03 trigger de offboarding prendido', 'O (habilitado)',
       (select tgenabled::text from pg_trigger where tgrelid = 'public.cs_clientes'::regclass and tgname = 'cs_trg_after_cierre'),
       coalesce((select tgenabled = 'O' from pg_trigger
                 where tgrelid = 'public.cs_clientes'::regclass and tgname = 'cs_trg_after_cierre'), false)
union all
select '04 respaldo solo de teo', '0 filas de otro programa',
       (select count(*) from public.cs_bak_128_clientes b join public.cs_clientes c on c.id = b.id
         where c.programa_id <> 'teo')::text,
       not exists (select 1 from public.cs_bak_128_clientes b join public.cs_clientes c on c.id = b.id
                   where c.programa_id <> 'teo')
union all
select '05 alumnos de teo marcados con la 128 (+ pausados / con renovación en la app sin marca)', 'todos',
       (select count(*) filter (where d is not null)::text || ' de ' || count(*)::text from t),
       (select count(*) filter (where d is null and estado <> 'pausado'
                                 and not exists (select 1 from public.cs_renovaciones r
                                                 where r.cliente_id = t.id and r.estado = 'renovado')) = 0 from t)
union all
select '06 sin vencidos vivos (activo/onboarding/en renovación con fecha_fin pasada) entre los marcados', '0',
       (select count(*) from t where d is not null and estado in ('activo', 'onboarding', 'en_renovacion')
                                 and fecha_fin < public.cs_hoy())::text,
       not exists (select 1 from t where d is not null and estado in ('activo', 'onboarding', 'en_renovacion')
                                    and fecha_fin < public.cs_hoy())
union all
select '07 sin finalizados con fecha_fin futura entre los marcados', '0',
       (select count(*) from t where d is not null and estado = 'finalizado' and fecha_fin >= public.cs_hoy())::text,
       not exists (select 1 from t where d is not null and estado = 'finalizado' and fecha_fin >= public.cs_hoy())
union all
select '08 no renovados: fecha_fin = inicio + 4 meses', '0 que no cumplan',
       (select count(*) from t where d is not null and d->>'renovacion' in ('ninguna', 'dudoso')
                                 and fecha_fin <> (fecha_inicio + make_interval(months => 4))::date)::text,
       not exists (select 1 from t where d is not null and d->>'renovacion' in ('ninguna', 'dudoso')
                                    and fecha_fin <> (fecha_inicio + make_interval(months => 4))::date)
union all
select '09 renovados detectados: hasta = fecha_fin y 6 meses', '0 que no cumplan',
       (select count(*) from t where d->>'renovacion' = 'finanzas'
                                 and (campos_extra->'renovacion'->>'hasta')::date is distinct from fecha_fin)::text,
       not exists (select 1 from t where d->>'renovacion' = 'finanzas'
                                    and (campos_extra->'renovacion'->>'hasta')::date is distinct from fecha_fin)
union all
select '10 resumen (informativo)', 'renovados / dudosos / sin renovación',
       count(*) filter (where d->>'renovacion' = 'finanzas')::text || ' / '
       || count(*) filter (where d->>'renovacion' = 'dudoso')::text || ' / '
       || count(*) filter (where d->>'renovacion' = 'ninguna')::text, true
from t
union all
select '10b renovados por Finanzas: el pago es RESELL / renov del mismo alumno (por nombre)', '0 que no cumplan',
       (select count(*) from t where d->>'renovacion' = 'finanzas' and not exists (
          select 1 from public.fin_pagos f
          where f.cliente_id = 'teo'
            and public.cs_norm_nombre(f.alumno) = public.cs_norm_nombre(t.nombre)
            and f.fecha = (t.campos_extra->'renovacion'->>'pago_fecha')::date
            and (f.concepto ~* 'renov' or f.concepto ~* '\yresell\y')))::text,
       not exists (select 1 from t where d->>'renovacion' = 'finanzas' and not exists (
          select 1 from public.fin_pagos f
          where f.cliente_id = 'teo'
            and public.cs_norm_nombre(f.alumno) = public.cs_norm_nombre(t.nombre)
            and f.fecha = (t.campos_extra->'renovacion'->>'pago_fecha')::date
            and (f.concepto ~* 'renov' or f.concepto ~* '\yresell\y')))
union all
select '10c sin renovados por FEE / PIF / UPSELL solos (el concepto del pago no es RESELL ni renov)', '0',
       (select count(*) from t where d->>'renovacion' = 'finanzas' and exists (
          select 1 from public.fin_pagos f
          where f.cliente_id = 'teo'
            and public.cs_norm_nombre(f.alumno) = public.cs_norm_nombre(t.nombre)
            and f.fecha = (t.campos_extra->'renovacion'->>'pago_fecha')::date
            and btrim(coalesce(f.concepto, '')) ~* '^(FEE|PIF|UPSELL|CUOTA UPSELL|2DA CUOTA|FEE DE PIF)$'))::text,
       not exists (select 1 from t where d->>'renovacion' = 'finanzas' and exists (
          select 1 from public.fin_pagos f
          where f.cliente_id = 'teo'
            and public.cs_norm_nombre(f.alumno) = public.cs_norm_nombre(t.nombre)
            and f.fecha = (t.campos_extra->'renovacion'->>'pago_fecha')::date
            and btrim(coalesce(f.concepto, '')) ~* '^(FEE|PIF|UPSELL|CUOTA UPSELL|2DA CUOTA|FEE DE PIF)$'))
union all
select '10d renovados cuyo primer pago es RESELL / renov: fecha_fin = ese pago + 6 meses (no 4 + 6)', '0 que no cumplan',
       (select count(*) from t where d->>'primer_pago' = 'true'
          and fecha_fin is distinct from ((t.campos_extra->'renovacion'->>'pago_fecha')::date
                                          + make_interval(months => 6))::date)::text,
       not exists (select 1 from t where d->>'primer_pago' = 'true'
          and fecha_fin is distinct from ((t.campos_extra->'renovacion'->>'pago_fecha')::date
                                          + make_interval(months => 6))::date)
union all
select '10e renovados cuyo primer pago es RESELL (informativo)', 'cantidad',
       count(*) filter (where d->>'primer_pago' = 'true')::text, true
from t
union all
select '10f pagos RESELL / renov sin alumno de teo (informativo, ver C17)', 'cantidad para revisar a mano',
       (select count(*)::text from public.fin_pagos f
         where f.cliente_id = 'teo'
           and (btrim(coalesce(f.concepto, '')) ~* 'renov' or btrim(coalesce(f.concepto, '')) ~* '\yresell\y')
           and not exists (select 1 from t x where public.cs_norm_nombre(f.alumno) = public.cs_norm_nombre(x.nombre)
                           or (public.cs_norm_tel(x.telefono) is not null
                               and public.cs_norm_tel(x.telefono) = public.cs_norm_tel(f.telefono)))), true
union all
select '11 la prueba de humo no dejó datos', '0',
       (select count(*) from public.cs_programas where id like 'humo128%')::text,
       not exists (select 1 from public.cs_programas where id like 'humo128%')
union all
select '12 humo ' || lpad(s.orden::text, 2, '0') || ': ' || s.paso, 'true', s.detalle, s.ok from cs_smoke128 s
order by 1;

commit;


-- =====================================================================
-- DESPUÉS DE CORRER (a mano, de a una)
-- =====================================================================
-- C13. Activos y finalizados de teo ahora (comparar con la vista previa Q1, filas 42 y 43):
--   select estado, count(*) from public.cs_clientes where programa_id = 'teo' group by 1 order by 1;
--
-- C14. Idempotencia: volver a correr esta migración entera. Los controles 05 y 10 tienen que dar lo mismo y
--      cs_bak_128_clientes no cambia de cantidad (la segunda corrida no toca a nadie, ya están marcados).
--   select count(*) from public.cs_bak_128_clientes;
--
-- C15. Renovados detectados (con nombres, no pegar en chats):
--   select nombre, fecha_inicio, fecha_fin, campos_extra->'renovacion' as renovacion
--   from public.cs_clientes where programa_id = 'teo' and campos_extra->'dur128'->>'renovacion' = 'finanzas'
--   order by nombre;
--   (los que traen "primer_pago": true entraron antes de la planilla y su primer pago ya era RESELL)
--
-- C16. Dudosos, para revisar uno por uno y renovarlos desde la app si corresponde:
--   select nombre, fecha_fin, campos_extra->'dur128'->'dudosa' as dudosa
--   from public.cs_clientes where programa_id = 'teo' and campos_extra->'dur128'->>'renovacion' = 'dudoso'
--   order by nombre;
--
-- C17. RESELL sin alumno: pagos RESELL / renov de teo que no cruzan con ningún alumno (revisar a mano, no hacen
--      nada; con nombres, no pegar en chats). Es la misma lista que Q6 de la vista previa 128a.
--   select f.fecha, f.alumno, f.telefono, btrim(coalesce(f.concepto, '')) as concepto
--   from public.fin_pagos f
--   where f.cliente_id = 'teo'
--     and (btrim(coalesce(f.concepto, '')) ~* 'renov' or btrim(coalesce(f.concepto, '')) ~* '\yresell\y')
--     and not exists (select 1 from public.cs_clientes c
--                     where c.programa_id = 'teo'
--                       and (public.cs_norm_nombre(c.nombre) = public.cs_norm_nombre(f.alumno)
--                            or (public.cs_norm_tel(c.telefono) is not null
--                                and public.cs_norm_tel(c.telefono) = public.cs_norm_tel(f.telefono))))
--   order by f.fecha, f.alumno;


-- =====================================================================
-- VUELTA ATRÁS (comentada; correr completa si hay que deshacer)
-- =====================================================================
-- begin;
--   lock table public.cs_programas, public.cs_clientes, public.cs_renovaciones, public.cs_accionables, public.cs_historial
--     in share row exclusive mode;
--   -- 1. Alumnos de teo a como estaban (fecha_fin, estado y campos_extra). Sin offboarding.
--   alter table public.cs_clientes disable trigger cs_trg_after_cierre;
--   update public.cs_clientes c
--      set fecha_fin = b.fecha_fin, estado = b.estado, campos_extra = b.campos_extra
--     from public.cs_bak_128_clientes b where b.id = c.id;
--   alter table public.cs_clientes enable trigger cs_trg_after_cierre;
--   -- 2. Funciones a la definición de 039 (guardadas antes de reemplazarlas).
--   do $$
--   declare r record;
--   begin
--     for r in select definicion from public.cs_bak_128_funciones loop
--       execute r.definicion;
--     end loop;
--   end $$;
--   -- 3. Columnas (si no se quieren dejar).
--   alter table public.cs_programas
--     drop constraint if exists cs_programas_dur_inicial_meses_chk,
--     drop constraint if exists cs_programas_dur_renov_meses_chk,
--     drop column if exists duracion_inicial_meses,
--     drop column if exists duracion_renovacion_meses;
--   -- 4. Respaldos (opcional, recién cuando se confirme que no hacen falta):
--   -- drop table public.cs_bak_128_clientes; drop table public.cs_bak_128_funciones;
-- commit;
-- Nota: una renovación cerrada en la app DESPUÉS de la 128 con meses ya está en cs_renovaciones y no se
-- deshace con esto (la vuelta atrás de los alumnos restituye el campos_extra respaldado, que no la tiene).
