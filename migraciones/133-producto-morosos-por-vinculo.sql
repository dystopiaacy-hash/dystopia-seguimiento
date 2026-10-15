-- =====================================================================
-- 133 · Producto · morosos del aviso diario por el vínculo de Finanzas (129)
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 123 (aviso de servicio), 129 (fin_cs_vinculo) y 132 (cs_estado_pagos_alumno; la usa la pantalla).
--
-- Qué hace
--   1. Reemplaza cs_servicio_morosos(text,int,date) de la 123 (misma firma y mismas columnas:
--      cliente_id, cuotas, dias_max, pendiente). Antes cruzaba fin_v_cobranzas por teléfono o nombre;
--      ahora usa el vínculo de la 129:
--        - cliente_id = ficha de Producto vinculada (fin_cs_vinculo.estado = 'vinculado');
--        - fila con cliente_id null = cuotas atrasadas de alumnos de Finanzas SIN vincular
--          (los marcados 'no_producto' no cuentan: se dijo a mano que no son de Producto).
--      Respeta el umbral (cuotas con más de p_dias días de atraso) y la clasificación de cuotas de la
--      129/132 (pagada / otra = churn, pausado, cancelado / pendiente; solo fuentes activas).
--      `pendiente` (monto) lo usa el aviso solo si el canal tiene incluir_monto; nunca sale de la base.
--   2. Retoca el TEXTO de la línea final de cs_servicio_armar: "N cuotas atrasadas de alumnos sin
--      vincular en Finanzas: vincularlos en <link>". Lo hace sobre la definición VIGENTE (replace sobre
--      pg_get_functiondef), así funciona igual antes o después de correr la 130 (que también reemplaza
--      cs_servicio_armar). Si la 130 se corre DESPUÉS, trae el texto viejo: volver a correr el bloque 3.
--
-- Decisión de diseño: NO se usa fin_cs_estado_pagos_base. Esa base devuelve contadores de TODAS las
-- cuotas atrasadas por alumno, sin poder aplicar el umbral de días ni dar las cuotas sin vincular.
-- Se lee fin_cs_vinculo y fin_cuotas directamente (solo lectura, security definer, igual que la 123).
-- No se toca Finanzas.
--
-- Qué NO toca: datos, cron, Discord (no manda nada), 128, 130, Fathom.
-- Correr evitando los minutos :00, :15, :30, :45 (sync de Finanzas) y la hora 9:00 (cron diario).
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo
do $$
declare
  v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values ('cs_servicio_morosos(text,int,date)'), ('cs_servicio_armar(text,date)'),
               ('cs_norm_nombre(text)'), ('cs_hoy()'),
               ('fin_cs_norm_nombre(text)'), ('cs_estado_pagos_alumno(uuid[])')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 133: faltan funciones (corrieron 123, 129 y 132?): %', v_falta;
  end if;
  if to_regclass('public.fin_cs_vinculo') is null or to_regclass('public.fin_cuotas') is null
     or to_regclass('public.fin_fuentes') is null then
    raise exception 'cs 133: faltan fin_cs_vinculo / fin_cuotas / fin_fuentes (corrió la 129?)';
  end if;
end $$;

-- Respaldo
create table if not exists public.cs_bak_133_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_133_funciones from public, anon, authenticated;
insert into public.cs_bak_133_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('cs_servicio_morosos', 'cs_servicio_armar')
on conflict (funcion) do nothing;

-- =====================================================================
-- 1. cs_servicio_morosos por vínculo
-- =====================================================================
create or replace function public.cs_servicio_morosos(p_programa text, p_dias int, p_hoy date default null)
returns table (cliente_id uuid, cuotas int, dias_max int, pendiente numeric)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_hoy date := coalesce(p_hoy, public.cs_hoy());
begin
  if to_regclass('public.fin_cuotas') is null or to_regclass('public.fin_fuentes') is null
     or to_regclass('public.fin_cs_vinculo') is null then
    return;
  end if;
  return query
  with cuotas as (
    select public.fin_cs_norm_nombre(q.alumno) as nom,
           (v_hoy - q.fecha_pago)              as atraso,
           greatest(coalesce(q.monto, 0) - coalesce(q.monto_cobrado, 0), 0) as pend
    from public.fin_cuotas q
    join public.fin_fuentes f on f.id = q.fuente_id and f.activo
    where q.cliente_id = p_programa
      and q.fecha_pago is not null
      and (v_hoy - q.fecha_pago) > p_dias
      -- pendiente = ni pagada ni churn / pausado / cancelado (misma clasificación que 129 y 132)
      and lower(btrim(coalesce(q.estado, ''))) not in
          ('pagado', 'pagada', 'cuota pagada', 'churn', 'pausado', 'cancelado')
  ),
  con_vinculo as (
    select c.atraso, c.pend,
           v.estado as v_estado, v.cs_cliente_id
    from cuotas c
    left join public.fin_cs_vinculo v
           on v.cliente_id = p_programa and v.alumno_norm = c.nom
  )
  select z.cs_cliente_id, count(*)::int, max(z.atraso)::int, sum(z.pend)
  from con_vinculo z
  where z.v_estado is distinct from 'no_producto'
  group by z.cs_cliente_id;      -- null = alumnos de Finanzas sin vincular (o desvinculados)
end;
$fn$;

comment on function public.cs_servicio_morosos(text, int, date) is
  '133: morosos del aviso diario por el vínculo de la 129. cliente_id null = cuotas atrasadas de alumnos sin vincular. Solo lectura sobre Finanzas.';

-- =====================================================================
-- 2. Texto de la línea "sin vincular" en cs_servicio_armar (sobre la definición vigente)
-- =====================================================================
do $$
declare
  v_def   text;
  v_viejo text := $q$' de Finanzas no se pudo cruzar con un alumno de forma segura: revisar en Finanzas._'$q$;
  v_nuevo text := $q$' de alumnos sin vincular en Finanzas: vincularlos en <https://finanzas.dystopia.com.ar/#/vincular>._'$q$;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  where p.oid = 'public.cs_servicio_armar(text,date)'::regprocedure;
  if position(v_viejo in v_def) = 0 then
    if position(v_nuevo in v_def) > 0 then
      raise notice 'cs 133: cs_servicio_armar ya tiene el texto nuevo';
    else
      raise exception 'cs 133: no se encontró la línea "sin cruzar" en cs_servicio_armar; no se aplica nada';
    end if;
  else
    execute replace(v_def, v_viejo, v_nuevo);
  end if;
end $$;

-- Permisos (create or replace los conserva; se reafirman)
revoke all on function public.cs_servicio_morosos(text, int, date) from public, anon, authenticated;
revoke all on function public.cs_servicio_armar(text, date) from public, anon, authenticated;

-- =====================================================================
-- 3. PRUEBA DE HUMO (se revierte sola; NO manda nada a Discord: solo arma el texto)
-- =====================================================================
do $$
declare
  v_cs   record;
  v_fc   bigint;
  v_hoy  date := public.cs_hoy();
  v_n    int;
  v_r    record;
  v_j    jsonb;
  v_def  text;
begin
  begin
    select c.id, c.programa_id into v_cs
      from public.cs_clientes c
     where exists (select 1 from public.crm_clients k where k.id = c.programa_id)
       and exists (select 1 from public.cs_servicio_config s where s.programa_id = c.programa_id)
     order by (c.programa_id = 'liam') desc, c.created_at
     limit 1;
    if not found then
      raise notice 'smoke 133: no hay ficha con programa en crm_clients y cs_servicio_config; se omite la parte con datos';
      raise exception 'SMOKE_OK';
    end if;

    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, forma, tope_monto)
    values (v_cs.programa_id, 'SMOKE_133', 1, 'Smoke', 'cuotas', 'cuotas_plano', 10000) returning id into v_fc;

    -- vinculado: 1 cuota a 20 días (cuenta), 1 a 10 días (no pasa el umbral 14), 1 pagada (no cuenta)
    insert into public.fin_cuotas (cliente_id, fuente_id, alumno, programa, numero_cuota, monto, monto_cobrado, fecha_pago, estado, fila_planilla) values
      (v_cs.programa_id, v_fc, 'Zz Smoke 133 Vinc', 'Prog Z', 1, 100, 20,  v_hoy - 20, 'Pendiente', 1),
      (v_cs.programa_id, v_fc, 'Zz Smoke 133 Vinc', 'Prog Z', 2, 100,  0,  v_hoy - 10, null,        2),
      (v_cs.programa_id, v_fc, 'Zz Smoke 133 Vinc', 'Prog Z', 3, 100, 100, v_hoy - 40, 'Pagado',    3),
    -- sin vincular: 2 cuotas atrasadas; no_producto: 1 cuota (no debe contar en ningún lado)
      (v_cs.programa_id, v_fc, 'Zz Smoke 133 Sin',  'Prog Z', 1, 50, 0, v_hoy - 30, 'Pendiente', 4),
      (v_cs.programa_id, v_fc, 'Zz Smoke 133 Sin',  'Prog Z', 2, 50, 0, v_hoy - 16, 'Pendiente', 5),
      (v_cs.programa_id, v_fc, 'Zz Smoke 133 Nop',  'Prog Z', 1, 70, 0, v_hoy - 25, 'Pendiente', 6);

    insert into public.fin_cs_vinculo (cliente_id, alumno_norm, alumno_ejemplo, estado, cs_cliente_id, origen) values
      (v_cs.programa_id, public.fin_cs_norm_nombre('Zz Smoke 133 Vinc'), 'Zz Smoke 133 Vinc', 'vinculado', v_cs.id, 'manual'),
      (v_cs.programa_id, public.fin_cs_norm_nombre('Zz Smoke 133 Nop'),  'Zz Smoke 133 Nop',  'no_producto', null, 'manual');

    -- 1. la ficha vinculada: 1 cuota, 20 días, pendiente 80 (100 - 20)
    select * into v_r from public.cs_servicio_morosos(v_cs.programa_id, 14, v_hoy) m where m.cliente_id = v_cs.id;
    if not found or v_r.cuotas <> 1 or v_r.dias_max <> 20 or v_r.pendiente <> 80 then
      raise exception 'smoke 133: vinculado = %', to_jsonb(v_r);
    end if;

    -- 2. la fila sin vincular suma al menos las 2 cuotas del smoke (puede haber más reales)
    select coalesce(sum(m.cuotas), 0) into v_n
      from public.cs_servicio_morosos(v_cs.programa_id, 14, v_hoy) m where m.cliente_id is null;
    if v_n < 2 then raise exception 'smoke 133: sin vincular = % (esperaba al menos 2)', v_n; end if;

    -- 3. umbral: con 17 días la cuota de 20 días sigue contando; con 25 el vinculado ya no sale
    select * into v_r from public.cs_servicio_morosos(v_cs.programa_id, 17, v_hoy) m where m.cliente_id = v_cs.id;
    if not found or v_r.cuotas <> 1 then raise exception 'smoke 133: umbral 17 = %', to_jsonb(v_r); end if;
    select * into v_r from public.cs_servicio_morosos(v_cs.programa_id, 25, v_hoy) m where m.cliente_id = v_cs.id;
    if found then raise exception 'smoke 133: con umbral 25 no deberia salir el vinculado'; end if;

    -- 4. el aviso se arma (solo texto, no envía) y trae la línea nueva
    v_j := public.cs_servicio_armar(v_cs.programa_id, v_hoy);
    if v_j -> 'cuentas' is null or jsonb_typeof(v_j -> 'partes') <> 'array' then
      raise exception 'smoke 133: cs_servicio_armar no devolvio cuentas / partes';
    end if;
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.oid = 'public.cs_servicio_armar(text,date)'::regprocedure;
    if position('vincularlos en <https://finanzas.dystopia.com.ar/#/vincular>' in v_def) = 0 then
      raise exception 'smoke 133: cs_servicio_armar no tiene el texto nuevo';
    end if;

    -- 5. permisos: nadie de la app llama a las internas
    if has_function_privilege('anon', 'public.cs_servicio_morosos(text,int,date)', 'execute')
       or has_function_privilege('authenticated', 'public.cs_servicio_morosos(text,int,date)', 'execute')
       or has_function_privilege('authenticated', 'public.cs_servicio_armar(text,date)', 'execute') then
      raise exception 'smoke 133: permisos incorrectos';
    end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 133: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

commit;

-- =====================================================================
-- CONTROLES (correr DE A UNO; solo lectura; ninguno manda nada a Discord)
-- =====================================================================
-- C1. Funciones en su lugar y el texto nuevo en el aviso (esperado: texto_nuevo true, texto_viejo false).
--   select position('vincularlos en <https://finanzas.dystopia.com.ar/#/vincular>' in pg_get_functiondef('public.cs_servicio_armar(text,date)'::regprocedure)) > 0 as texto_nuevo,
--          position('no se pudo cruzar con un alumno' in pg_get_functiondef('public.cs_servicio_armar(text,date)'::regprocedure)) > 0 as texto_viejo;
--
-- C2. Morosos por ficha vinculada, programa liam, umbral 14 (cliente_id null = sin vincular).
--   select m.cliente_id, c.nombre, m.cuotas, m.dias_max, m.pendiente
--     from public.cs_servicio_morosos('liam', 14) m left join public.cs_clientes c on c.id = m.cliente_id
--    order by m.dias_max desc;
--
-- C3. Coherencia con la función de Producto de la 132 (sin umbral = 0 días): cuotas atrasadas por ficha.
--   select a.cs_cliente_id, a.cuotas_atrasadas as de_132, coalesce(m.cuotas, 0) as de_133
--     from public.cs_estado_pagos_alumno(array(select id from public.cs_clientes where programa_id = 'liam')) a
--     left join public.cs_servicio_morosos('liam', 0) m on m.cliente_id = a.cs_cliente_id
--    where coalesce(a.cuotas_atrasadas, 0) <> coalesce(m.cuotas, 0);   -- esperado: 0 filas
--
-- C4. Cuántas cuotas atrasadas quedan sin vincular, por programa (umbral 14).
--   select p.id, (select coalesce(sum(m.cuotas), 0) from public.cs_servicio_morosos(p.id, 14) m where m.cliente_id is null) as sin_vincular
--     from public.cs_programas p order by 1;
--
-- C5. El mensaje que saldría hoy (solo texto; no se envía). Reemplazar 'liam'.
--   select public.cs_servicio_armar('liam') -> 'cuentas' as cuentas,
--          array_to_string(array(select jsonb_array_elements_text(public.cs_servicio_armar('liam') -> 'partes')), E'\n') as texto;
--
-- C6. Sin montos en el aviso si el canal no los pide (esperado: incluir_monto false => el texto no tiene "USD").
--   select programa_id, incluir_monto from public.cs_discord_canales where tipo = 'servicio' order by 1;
--
-- C7. Respaldo guardado (esperado: 2 filas).
--   select funcion, respaldada from public.cs_bak_133_funciones order by 1;
--
-- ---------------------------------------------------------------------
-- VUELTA ATRÁS (en este orden; las definiciones están en cs_bak_133_funciones):
--   1. Volver a correr la definición de cs_servicio_morosos de la 123 (sección "Morosos cruzados").
--   2. Restaurar cs_servicio_armar: ejecutar la `definicion` guardada.
--        select definicion from public.cs_bak_133_funciones where funcion like 'cs_servicio_armar%';
--      (si entre medio se corrió la 130, restaurar desde cs_bak_130_funciones o volver a correr la 130).
--   3. drop table if exists public.cs_bak_133_funciones;
-- =====================================================================
