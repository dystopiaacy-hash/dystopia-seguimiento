-- =====================================================================
-- 128a-producto-teo-duracion-vista-previa.sql  ·  PRODUCTO: VISTA PREVIA de la 128 (SOLO LECTURA)
-- =====================================================================
-- NO escribe nada, no crea nada, no necesita la 128. Se puede correr las veces que haga falta, ANTES
-- de la 128. Cada bloque Q1 a Q5 es una consulta independiente: correrlos de a uno en el SQL Editor.
-- Evitar :00, :15, :30 y :45 (sync de Finanzas), por prolijidad (solo lee).
--
-- Qué calcula (exactamente lo mismo que va a hacer la 128 con los datos):
--   * Solo alumnos de teo (cs_clientes.programa_id = 'teo').
--   * fecha_fin inicial = fecha_inicio + 4 meses calendario (Postgres recorta fin de mes: 31/10 + 4 = 28/02).
--   * Renovación (6 meses), mirando fin_pagos de Finanzas (cliente_id = 'teo', solo lectura), cruzado con el
--     alumno por nombre normalizado (cs_norm_nombre); por teléfono (cs_norm_tel) solo cuenta como DUDOSO:
--       - RENOVACIÓN SEGURA = pago cruzado por nombre, posterior al inicio, cuyo concepto contiene la palabra
--         RESELL (cualquier mayúscula: "RESELL", "CUOTA RESELL", "UPSELL / RESELL", "COMPLETA UPSELL / RESELL")
--         o contiene "renov". Fecha de la renovación = el primer pago de ese tipo.
--       - Varios pagos RESELL / renov del mismo alumno = UNA sola renovación (la del primero). Si hay otro
--         separado del primero por más de 5 meses, NO se encadena: queda como dudoso (Q2) para revisar.
--       - NO renuevan (quedan como dudosos informativos en Q2, sin extender la fecha): cualquier otro pago
--         posterior al fin del primer ciclo (FEE, PIF, FEE DE PIF, 2DA CUOTA, REFUERZA FEE, UPSELL, CUOTA
--         UPSELL, vacío, etc.), un pago RESELL / renov cruzado solo por teléfono, o (si no cruzó ningún
--         pago) un ultimo_pago de la planilla de la 125 posterior al fin del primer ciclo.
--       - UPSELL solo es un cambio de plan: nunca cambia fechas.
--     Si hay una renovación segura: fecha_fin = mayor(fin del primer ciclo, fecha del pago) + 6 meses.
--     Si el alumno ya tiene una renovación 'renovado' cargada en la app, no se toca.
--   * Estado: baja y pausado no cambian; el resto queda activo/onboarding/en_renovacion si fecha_fin >= hoy,
--     finalizado si ya pasó (un finalizado con fecha_fin >= hoy vuelve a activo).
--   * Alumnos que ya pasaron por la 128 (campos_extra.dur128) no se tocan: es lo que la hace idempotente.
-- Duraciones: 4 y 6 van escritas en el bloque "params" de cada consulta. Si cambian, cambiarlas igual en la 128.
-- =====================================================================


-- =====================================================================
-- Q1. RESUMEN (una fila por número). Los números para mostrarle a Joaquín.
-- =====================================================================
with params as (
  select 4::int as m_ini, 6::int as m_ren, public.cs_hoy() as hoy
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
  select g.id, g.fecha, g.concepto, g.via, a.fin_inicial,
         case when g.fecha > a.fecha_inicio and g.concepto ~* 'renov' then 'renov'
              when g.fecha > a.fecha_inicio and g.concepto ~* '\yresell\y' then 'resell' end as es_ren
  from pagos g join al a on a.id = g.id
),
cls as (
  select c0.id, c0.fecha, c0.concepto, c0.via,
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
    coalesce((select min(x.fecha) from cls x where x.id = a.id and x.tipo = 'dudoso'),
             case when not exists (select 1 from pagos g where g.id = a.id)
                  and a.ultimo_pago_planilla > a.fin_inicial then a.ultimo_pago_planilla end) as pago_dud
  from al a
),
plan as (
  select a.id, a.estado, a.fin_actual, a.fin_inicial, r.pago_ren, r.tipo_ren, r.pago_dud, p.hoy,
         (not a.ya_128 and a.estado <> 'pausado' and a.ren_app_fin is null) as tocar,
         case when a.ren_app_fin is not null then 'app'
              when r.pago_ren is not null then 'finanzas'
              when r.pago_dud is not null then 'dudoso'
              else 'ninguna' end as renovacion,
         case when r.pago_ren is not null and a.ren_app_fin is null
              then (greatest(a.fin_inicial, r.pago_ren) + make_interval(months => p.m_ren))::date
              else a.fin_inicial end as fin_nuevo
  from al a join res r on r.id = a.id cross join params p
),
fin as (
  select pl.*,
         case when not pl.tocar then pl.fin_actual else pl.fin_nuevo end as fin_final,
         case when not pl.tocar or pl.estado in ('baja', 'pausado') then pl.estado
              when pl.fin_nuevo >= pl.hoy then case when pl.estado = 'finalizado' then 'activo' else pl.estado end
              else 'finalizado' end as estado_final
  from plan pl
)
select orden, concepto, valor from (
  select 10 as orden, 'Alumnos de teo' as concepto, count(*)::text as valor from fin
  union all select 11, 'Pagos de teo en Finanzas (fin_pagos)', (select count(*)::text from public.fin_pagos where cliente_id = 'teo')
  union all select 12, 'Alumnos sin ningún pago cruzado en Finanzas', count(*)::text from fin f
         where not exists (select 1 from pagos g where g.id = f.id)
  union all select 20, 'Se recalculan', count(*) filter (where tocar)::text from fin
  union all select 21, 'No se tocan: pausados', count(*) filter (where estado = 'pausado')::text from fin
  union all select 22, 'No se tocan: ya pasaron por la 128', (select count(*)::text from al where ya_128)
  union all select 23, 'No se tocan: ya tienen renovación en la app', count(*) filter (where renovacion = 'app')::text from fin
  union all select 30, 'Cambia fecha_fin', count(*) filter (where tocar and fin_final <> fin_actual)::text from fin
  union all select 31, 'Activos hoy (activo/onboarding/en renovación) hoy', count(*) filter (where estado in ('activo','onboarding','en_renovacion'))::text from fin
  union all select 32, 'Finalizados hoy', count(*) filter (where estado = 'finalizado')::text from fin
  union all select 40, 'Estado: activo/onboarding/en renovación -> finalizado', count(*) filter (where tocar and estado in ('activo','onboarding','en_renovacion') and estado_final = 'finalizado')::text from fin
  union all select 41, 'Estado: finalizado -> activo', count(*) filter (where tocar and estado = 'finalizado' and estado_final = 'activo')::text from fin
  union all select 42, 'Quedan activos/onboarding/en renovación (después)', count(*) filter (where estado_final in ('activo','onboarding','en_renovacion'))::text from fin
  union all select 43, 'Quedan finalizados (después)', count(*) filter (where estado_final = 'finalizado')::text from fin
  union all select 50, 'Renovados detectados en Finanzas (6 meses)', count(*) filter (where tocar and renovacion = 'finanzas')::text from fin
  union all select 51, '  por concepto "renov"', count(*) filter (where tocar and renovacion = 'finanzas' and tipo_ren = 'seguro_renov')::text from fin
  union all select 52, '  por concepto RESELL (RESELL, CUOTA RESELL, UPSELL / RESELL...)', count(*) filter (where tocar and renovacion = 'finanzas' and tipo_ren = 'seguro_resell')::text from fin
  union all select 53, '  renovados que hoy ya estarían vencidos', count(*) filter (where tocar and renovacion = 'finanzas' and fin_nuevo < hoy)::text from fin
  union all select 60, 'Dudosos (sin renovación, ver Q2)', count(*) filter (where tocar and renovacion = 'dudoso')::text from fin
  union all select 61, 'Renovados que además tienen otro pago posterior o un RESELL separado por más de 5 meses (ver Q2)', count(*) filter (where tocar and renovacion = 'finanzas' and pago_dud is not null)::text from fin
) t
order by orden;


-- =====================================================================
-- Q2. DUDOSOS: pagos que NO renuevan y se muestran solo para revisar (no extienden la fecha):
-- pagos posteriores al primer ciclo (FEE, PIF, 2DA CUOTA, UPSELL, etc.), RESELL / renov cruzado solo por
-- teléfono o separado por más de 5 meses de la primera renovación. "renovacion_detectada" dice si el alumno
-- ya tiene una renovación segura por RESELL / renov.
-- Tiene nombres: es para revisar a mano, no para pegar en chats.
-- =====================================================================
with params as (select 4::int as m_ini, 6::int as m_ren, public.cs_hoy() as hoy),
al as (
  select c.id, c.nombre, c.estado, c.fecha_inicio, c.fecha_fin as fin_actual,
         (c.fecha_inicio + make_interval(months => p.m_ini))::date as fin_inicial,
         public.cs_norm_nombre(c.nombre) as nom, public.cs_norm_tel(c.telefono) as tel,
         case when c.campos_extra->>'ultimo_pago' ~ '^\d{4}-\d{2}-\d{2}$'
              then (c.campos_extra->>'ultimo_pago')::date end as ultimo_pago_planilla,
         (c.campos_extra ? 'dur128') as ya_128,
         (select 1 from public.cs_renovaciones r where r.cliente_id = c.id and r.estado = 'renovado' limit 1) as ren_app
  from public.cs_clientes c cross join params p where c.programa_id = 'teo'
),
pagos as (
  select a.id, f.fecha, btrim(coalesce(f.concepto, '')) as concepto,
         case when public.cs_norm_nombre(f.alumno) = a.nom then 'nombre' else 'telefono' end as via
  from al a join public.fin_pagos f on f.cliente_id = 'teo'
   and (public.cs_norm_nombre(f.alumno) = a.nom or (a.tel is not null and public.cs_norm_tel(f.telefono) = a.tel))
),
cls0 as (
  select g.id, g.fecha, g.concepto, g.via, a.fin_inicial,
         case when g.fecha > a.fecha_inicio and g.concepto ~* 'renov' then 'renov'
              when g.fecha > a.fecha_inicio and g.concepto ~* '\yresell\y' then 'resell' end as es_ren
  from pagos g join al a on a.id = g.id
),
cls as (
  select c0.id, c0.fecha, c0.concepto, c0.via,
         case
           when c0.via = 'nombre' and c0.es_ren is not null
                and c0.fecha <= min(c0.fecha) filter (where c0.via = 'nombre' and c0.es_ren is not null)
                                over (partition by c0.id) + interval '5 months'
             then 'seguro_' || c0.es_ren
           when c0.es_ren is not null or c0.fecha > c0.fin_inicial then 'dudoso'
         end as tipo
  from cls0 c0
)
select a.nombre, a.estado, a.fecha_inicio, a.fin_inicial, x.fecha as pago_posterior, x.concepto, x.via as cruzado_por,
       'pago de Finanzas' as origen,
       exists (select 1 from cls y where y.id = a.id and y.tipo like 'seguro%') as renovacion_detectada,
       case when x.via = 'telefono' then 'cruzado solo por teléfono'
            when x.concepto ~* 'renov' or x.concepto ~* '\yresell\y' then 'otro RESELL / renov separado por más de 5 meses'
            else 'pago posterior al primer ciclo: no renueva' end as motivo
from al a
join cls x on x.id = a.id and x.tipo = 'dudoso'
where not a.ya_128 and a.estado <> 'pausado' and a.ren_app is null
union all
select a.nombre, a.estado, a.fecha_inicio, a.fin_inicial, a.ultimo_pago_planilla, null, null, 'último pago de la planilla (sin cruce)',
       false, 'sin pagos cruzados: solo el último pago de la planilla'
from al a
where not a.ya_128 and a.estado <> 'pausado' and a.ren_app is null
  and not exists (select 1 from pagos g where g.id = a.id)
  and a.ultimo_pago_planilla > a.fin_inicial
order by 1, 5;


-- =====================================================================
-- Q3. RENOVADOS DETECTADOS (los que la 128 marcaría como "Renovado (6 meses)"): primer pago RESELL / renov.
-- =====================================================================
with params as (select 4::int as m_ini, 6::int as m_ren, public.cs_hoy() as hoy),
al as (
  select c.id, c.nombre, c.estado, c.fecha_inicio, c.fecha_fin as fin_actual,
         (c.fecha_inicio + make_interval(months => p.m_ini))::date as fin_inicial,
         public.cs_norm_nombre(c.nombre) as nom, public.cs_norm_tel(c.telefono) as tel,
         (c.campos_extra ? 'dur128') as ya_128,
         (select 1 from public.cs_renovaciones r where r.cliente_id = c.id and r.estado = 'renovado' limit 1) as ren_app
  from public.cs_clientes c cross join params p where c.programa_id = 'teo'
),
pagos as (
  select a.id, f.fecha, btrim(coalesce(f.concepto, '')) as concepto,
         case when public.cs_norm_nombre(f.alumno) = a.nom then 'nombre' else 'telefono' end as via
  from al a join public.fin_pagos f on f.cliente_id = 'teo'
   and (public.cs_norm_nombre(f.alumno) = a.nom or (a.tel is not null and public.cs_norm_tel(f.telefono) = a.tel))
),
cls0 as (
  select g.id, g.fecha, g.concepto, g.via, a.fin_inicial,
         case when g.fecha > a.fecha_inicio and g.concepto ~* 'renov' then 'renov'
              when g.fecha > a.fecha_inicio and g.concepto ~* '\yresell\y' then 'resell' end as es_ren
  from pagos g join al a on a.id = g.id
),
cls as (
  select c0.id, c0.fecha, c0.concepto, c0.via,
         case
           when c0.via = 'nombre' and c0.es_ren is not null
                and c0.fecha <= min(c0.fecha) filter (where c0.via = 'nombre' and c0.es_ren is not null)
                                over (partition by c0.id) + interval '5 months'
             then 'seguro_' || c0.es_ren
           when c0.es_ren is not null or c0.fecha > c0.fin_inicial then 'dudoso'
         end as tipo
  from cls0 c0
),
primero as (
  select distinct on (x.id) x.id, x.fecha, x.concepto, x.tipo
  from cls x where x.tipo like 'seguro%' order by x.id, x.fecha
)
select a.nombre, a.estado as estado_hoy, a.fecha_inicio, a.fin_inicial, p.fecha as pago_renovacion, p.concepto, p.tipo as regla,
       (greatest(a.fin_inicial, p.fecha) + make_interval(months => (select m_ren from params)))::date as fin_nuevo,
       case when (greatest(a.fin_inicial, p.fecha) + make_interval(months => (select m_ren from params)))::date >= (select hoy from params)
            then 'activo' else 'finalizado' end as estado_despues
from al a join primero p on p.id = a.id
where not a.ya_128 and a.estado <> 'pausado' and a.ren_app is null
order by a.nombre;


-- =====================================================================
-- Q4. CONCEPTOS de los pagos de teo en Finanzas: para validar la regla (qué existe y cómo los categoriza
-- Finanzas). "posteriores" = pagos después del fin del primer ciclo (fecha_inicio del alumno + 4 meses).
-- "la_regla_lo_toma_como_renovacion" = true si el concepto contiene la palabra RESELL o "renov" (cualquier
-- mayúscula); es lo único que renueva. UPSELL solo, FEE, PIF, 2DA CUOTA, vacío, etc. dan false.
-- Si aparece un concepto de renovación que la regla no reconoce, avisar ANTES de aplicar.
-- =====================================================================
select btrim(coalesce(f.concepto, '')) as concepto,
       public.fin_categoria_concepto(f.cliente_id, f.concepto) as categoria_finanzas,
       count(*) as pagos,
       count(*) filter (where exists (
         select 1 from public.cs_clientes c
         where c.programa_id = 'teo' and public.cs_norm_nombre(c.nombre) = public.cs_norm_nombre(f.alumno)
           and f.fecha > (c.fecha_inicio + make_interval(months => 4))::date)) as posteriores_al_primer_ciclo,
       (btrim(coalesce(f.concepto, '')) ~* 'renov'
        or btrim(coalesce(f.concepto, '')) ~* '\yresell\y') as la_regla_lo_toma_como_renovacion
from public.fin_pagos f
where f.cliente_id = 'teo'
group by 1, 2
order by 3 desc;


-- =====================================================================
-- Q5. ALUMNOS DE teo QUE NO SE VAN A TOCAR y por qué (pausados, con renovación en la app, o ya recalculados).
-- =====================================================================
select c.nombre, c.estado, c.fecha_inicio, c.fecha_fin,
       case when c.campos_extra ? 'dur128' then 'ya pasó por la 128'
            when c.estado = 'pausado' then 'pausado (la fecha se corre al reanudar)'
            else 'tiene una renovación cerrada en la app' end as motivo
from public.cs_clientes c
where c.programa_id = 'teo'
  and (c.campos_extra ? 'dur128' or c.estado = 'pausado'
       or exists (select 1 from public.cs_renovaciones r where r.cliente_id = c.id and r.estado = 'renovado'))
order by c.nombre;
