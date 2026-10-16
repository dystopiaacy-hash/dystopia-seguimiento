-- =====================================================================
-- duplicados-teo.sql  ·  PRODUCTO: posibles fichas duplicadas del programa teo (SOLO SELECT)
-- =====================================================================
-- SQL SIN PROBAR: el agente no pudo correr SQL. No escribe nada, no es migración. Se corre COMPLETO en el
-- SQL Editor de Supabase (una sola sentencia). Requiere cs_norm_nombre / cs_norm_tel (070) y cs_productos (039);
-- el bloque de pagos usa fin_cs_vinculo, fin_pagos y fin_cs_norm_nombre (Finanzas 129).
-- No usa extensiones (ni pg_trgm ni fuzzystrmatch): la "distancia de edición chica" se mide con similitud de
-- trigramas calculada a mano (Jaccard de los trozos de 3 letras del nombre normalizado).
--
-- Para cambiar de programa o de sensibilidad, tocar solo el CTE `cfg`.
--
-- Salida: una fila por ficha de cada par (dos filas por par), ordenada por par.
--   par            número de par (1..N); una ficha puede estar en más de un par
--   rol            A / B (A = la de id menor; no implica cuál debería quedar)
--   motivos        qué reglas dispararon: nombre, email, telefono, apellido_ini3, parecido(0.xx)
--   ficha          prefijo de 8 del uuid (el mismo criterio de las migraciones 164 y 165)
--   id             uuid completo
--   nombre, email, telefono, estado, fecha_inicio, fecha_fin, producto
--   llamadas, ultima_llamada, wins, accionables, accionables_abiertos, renovaciones, renovaciones_renovado,
--   mails_extra, alias, seguimientos
--   vinculos_pagos filas de fin_cs_vinculo (estado vinculado) apuntando a la ficha
--   pagos          filas de fin_pagos de los alumnos vinculados a la ficha (cliente 'teo')
--   cuotas         filas de fin_cuotas de esos mismos alumnos
--   ultimo_pago    fecha del último pago con monto > 0
-- =====================================================================

with cfg as (
  select 'teo'::text as programa,        -- programa a revisar
         0.55::numeric as umbral_parecido  -- 0 a 1; más bajo = más pares (y más ruido). 0.55 atrapa Kari/Karina
),
fichas as (
  select c.id, c.nombre, c.email, c.telefono, c.estado, c.fecha_inicio, c.fecha_fin, c.producto_id,
         public.cs_norm_nombre(c.nombre) as nn,
         lower(btrim(c.email)) as em,
         public.cs_norm_tel(c.telefono) as tel
  from public.cs_clientes c, cfg
  where c.programa_id = cfg.programa
),
f as (
  select x.*,
         split_part(x.nn, ' ', 1) as primer,
         (regexp_split_to_array(x.nn, ' '))[array_length(regexp_split_to_array(x.nn, ' '), 1)] as ultimo,
         array_length(regexp_split_to_array(x.nn, ' '), 1) as n_pal,
         -- todos los mails de la ficha: el principal y los extra (126)
         array(select m from (
                 select x.em as m
                 union
                 select lower(btrim(mm.email)) from public.cs_clientes_mails mm where mm.cliente_id = x.id
               ) q where m is not null) as mails,
         -- trigramas del nombre normalizado, con relleno como pg_trgm
         array(select distinct substr('  ' || x.nn || ' ', i, 3)
               from generate_series(1, length('  ' || x.nn || ' ') - 2) i) as tri
  from fichas x
  where x.nn is not null
),
pares as (
  select a.id as a_id, b.id as b_id,
         (a.nn = b.nn) as r_nombre,
         (a.mails && b.mails) as r_email,
         (a.tel is not null and a.tel = b.tel) as r_tel,
         (a.n_pal >= 2 and b.n_pal >= 2 and a.ultimo = b.ultimo
            and left(a.primer, 3) = left(b.primer, 3)) as r_ap_ini,
         case when cardinality(a.tri) + cardinality(b.tri) > 0 then
           round(cardinality(array(select unnest(a.tri) intersect select unnest(b.tri)))::numeric
                 / nullif(cardinality(array(select unnest(a.tri) union select unnest(b.tri))), 0), 2)
         end as parecido
  from f a
  join f b on a.id < b.id
),
pares_ok as (
  select p.*, row_number() over (order by p.a_id, p.b_id) as par
  from pares p, cfg
  where p.r_nombre or p.r_email or p.r_tel or p.r_ap_ini or p.parecido >= cfg.umbral_parecido
),
lados as (
  select p.par, 'A'::text as rol, p.a_id as id, p, 1 as o from pares_ok p
  union all
  select p.par, 'B', p.b_id, p, 2 from pares_ok p
)
select
  l.par,
  l.rol,
  concat_ws(', ',
    case when (l.p).r_nombre then 'nombre' end,
    case when (l.p).r_email then 'email' end,
    case when (l.p).r_tel then 'telefono' end,
    case when (l.p).r_ap_ini then 'apellido_ini3' end,
    case when (l.p).parecido >= (select umbral_parecido from cfg) then 'parecido(' || (l.p).parecido || ')' end
  ) as motivos,
  left(c.id::text, 8) as ficha,
  c.id,
  c.nombre, c.email, c.telefono, c.estado, c.fecha_inicio, c.fecha_fin,
  pr.nombre as producto,
  (select count(*) from public.cs_llamadas x where x.cliente_id = c.id) as llamadas,
  (select max(x.fecha) from public.cs_llamadas x where x.cliente_id = c.id) as ultima_llamada,
  (select count(*) from public.cs_wins x where x.cliente_id = c.id) as wins,
  (select count(*) from public.cs_accionables x where x.cliente_id = c.id) as accionables,
  (select count(*) from public.cs_accionables x where x.cliente_id = c.id
      and x.estado in ('pendiente', 'en_proceso')) as accionables_abiertos,
  (select count(*) from public.cs_renovaciones x where x.cliente_id = c.id) as renovaciones,
  (select count(*) from public.cs_renovaciones x where x.cliente_id = c.id and x.estado = 'renovado') as renovaciones_renovado,
  (select count(*) from public.cs_clientes_mails x where x.cliente_id = c.id) as mails_extra,
  (select count(*) from public.cs_clientes_alias x where x.cliente_id = c.id) as alias,
  (select count(*) from public.cs_seguimientos x where x.cliente_id = c.id) as seguimientos,
  (select count(*) from public.fin_cs_vinculo v
     where v.cs_cliente_id = c.id and v.estado = 'vinculado') as vinculos_pagos,
  (select count(*) from public.fin_pagos p
     where p.cliente_id = (select programa from cfg)
       and public.fin_cs_norm_nombre(p.alumno) in
           (select v.alumno_norm from public.fin_cs_vinculo v
             where v.cs_cliente_id = c.id and v.estado = 'vinculado')) as pagos,
  (select count(*) from public.fin_cuotas q
     where q.cliente_id = (select programa from cfg)
       and public.fin_cs_norm_nombre(q.alumno) in
           (select v.alumno_norm from public.fin_cs_vinculo v
             where v.cs_cliente_id = c.id and v.estado = 'vinculado')) as cuotas,
  (select max(p.fecha) from public.fin_pagos p
     where p.cliente_id = (select programa from cfg) and p.monto_usd > 0
       and public.fin_cs_norm_nombre(p.alumno) in
           (select v.alumno_norm from public.fin_cs_vinculo v
             where v.cs_cliente_id = c.id and v.estado = 'vinculado')) as ultimo_pago
from lados l
join public.cs_clientes c on c.id = l.id
left join public.cs_productos pr on pr.id = c.producto_id
order by l.par, l.o;
