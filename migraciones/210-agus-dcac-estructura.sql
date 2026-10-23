-- =====================================================================
-- 210-agus-dcac-estructura.sql  ·  PRODUCTO: agus (DCAC) igual que su Maestro de Clientes
-- =====================================================================
-- NÚMERO PENDIENTE: el jefe asigna el número (renombrar el archivo). Va ANTES de la migración de datos
-- (213-agus-dcac-datos.sql, que genera scripts/generar-importacion-agus.mjs).
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), primero en el banco de pruebas.
-- Evitar :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- Requiere: 039 (cs_productos), 071 (cs_maestro_columnas), 079 (cs_puede_ver / cs_puede_editar),
-- 106 (lista vigente de columnas del sistema), 113 (productos de agus).
--
-- Fuente: MAESTRO DE CLIENTES - DCAC.xlsx (bajado el 23/10/2026). Hojas: Maestro de Clientes,
-- Fuera del maestro y Resumen.
--
-- Qué hace:
--   A. cs_maestro_claves_sistema(): suma 3 columnas del sistema (fecha_inicio = FECHA DE CARGA, email = Mail,
--      telefono = Numero). Es la lista de la 106 (27 claves) + 3. Si la lista vigente NO es exactamente la
--      de la 106, aborta sin tocar nada (alguien la cambió después: avisar). Las 3 nuevas arrancan OCULTAS en
--      los demás programas (el front las muestra solo si el fundador las activa en Columnas).
--   B. Productos de agus que faltan: Skool (SIN VENCIMIENTO: duracion_dias = 36500, ver abajo), Comunidad
--      (90 días, inactivo: ya nadie la vende), Resell Grupal y Resell 1 a 1 (120 días). Grupal, 1 a 1, 1 mes,
--      3 meses y 45 días ya existen por la 113 (on conflict: no se pisa nada).
--      "Sin vencimiento": no se tocó el esquema (duracion_dias > 0 y fecha_fin not null siguen igual). Skool vale 36500
--      días (100 años) y la carga de datos pone fecha_fin = 2099-12-31. El front (js/sin-vencimiento.js) trata
--      cualquier fecha_fin >= 2099-01-01 como "Sin vencimiento": sin días restantes, sin avisos, sin renovación.
--      El cron no los finaliza ni les genera alertas de vencimiento porque la fecha nunca llega.
--   C. Columnas del Maestro de agus (cs_maestro_columnas), en el orden de la hoja y con sus nombres:
--        Alumno | Fecha de carga | Programa | Mail | Número | Días restantes | Aviso 14-21 días | Aviso 0-7 días |
--        Estado (resell) | Contexto | ¿Lo saqué del grupo de WPP? | ¿Lo saqué de Skool? | Concepto |
--        Grupo creado 1-1 | No responde (!)  — y después las demás del sistema (Estado, Testimonio, Prioridad...).
--      Nuevas (C1): x_saque_wpp (opción Si / No aplica), x_saque_skool (casilla), x_concepto (opción), x_grupo_creado_1_1
--      (casilla), x_no_responde (casilla, para el "!" de ESTADO). Si agus YA tiene configuración de columnas
--      (alguien las movió o renombró), NO se reordena ni se renombra nada (se avisa por NOTICE); las nuevas se crean igual.
--      Bloque C2 (vacías en la hoja, tipo decidido): x_ref_0_2 / x_ref_2_4 / x_ref_4_6 (número), x_seguimiento_1 /
--      x_seguimiento_2 (fecha) y x_aviso_baja (casilla), órdenes 160 a 197.
--   D. Tabla cs_fuera_maestro (hoja "Fuera del maestro"): solo lectura para la app (pestaña "Fuera del maestro"
--      de agus). La carga la hace la migración de datos. RLS: ve quien ve el programa.
--
-- No toca: datos de clientes, liam / teo, la sync, accionables, la base de dcc_ (otra app).
-- Se puede correr dos veces (on conflict / if not exists).
-- =====================================================================

begin;

set local lock_timeout = '8s';

lock table public.cs_programas, public.cs_productos, public.cs_maestro_columnas
  in share row exclusive mode;


-- ---------------------------------------------------------------------
-- 0. GUARDAS
-- ---------------------------------------------------------------------
do $$
declare
  v_falta  text;
  v_lista  text[];
  v_106    text[] := array[
    'nombre', 'prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha',
    'nota_csm', 'testimonio', 'renovacion_estado', 'renovacion_producto',
    'aviso_1_at', 'aviso_2_at', 'estado', 'producto', 'etapa', 'dias_restantes',
    'acc', 'dev_pendientes', 'ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
    'proximo_contacto', 'renovaciones_count', 'onb_avance', 'ultima_llamada',
    'en_que_esta', 'proximos_pasos', 'satisfaccion_ultima', 'upsell'
  ];
begin
  select string_agg(x.t, ', ') into v_falta
  from (values ('cs_programas'), ('cs_productos'), ('cs_clientes'), ('cs_maestro_columnas')) as x(t)
  where to_regclass('public.' || x.t) is null;
  if v_falta is not null then
    raise exception 'cs agus-estructura: faltan tablas: %', v_falta;
  end if;

  if not exists (select 1 from public.cs_programas where id = 'agus') then
    raise exception 'cs agus-estructura: no existe el programa agus (corré la 113).';
  end if;
  if to_regprocedure('public.cs_puede_ver(text)') is null then
    raise exception 'cs agus-estructura: falta cs_puede_ver (079).';
  end if;
  if not exists (select 1 from public.cs_productos where programa_id = 'agus' and nombre = 'Grupal') then
    raise exception 'cs agus-estructura: agus no tiene sus productos (corré la 113).';
  end if;

  -- La lista vigente tiene que ser exactamente la de la 106 (si no, esta migración la pisaría).
  v_lista := public.cs_maestro_claves_sistema();
  if v_lista is distinct from v_106
     and v_lista is distinct from (v_106 || array['fecha_inicio', 'email', 'telefono']) then
    raise exception 'cs agus-estructura: la lista de columnas del sistema cambió desde la 106 (%). No se toca nada: avisar al jefe.',
      array_to_string(v_lista, ', ');
  end if;
end $$;


-- ---------------------------------------------------------------------
-- A. COLUMNAS DEL SISTEMA: + fecha_inicio, email, telefono
-- ---------------------------------------------------------------------
create or replace function public.cs_maestro_claves_sistema()
returns text[]
language sql immutable parallel safe set search_path = public
as $$
  select array[
    'nombre', 'prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha',
    'nota_csm', 'testimonio', 'renovacion_estado', 'renovacion_producto',
    'aviso_1_at', 'aviso_2_at', 'estado', 'producto', 'etapa', 'dias_restantes',
    'acc', 'dev_pendientes', 'ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
    'proximo_contacto', 'renovaciones_count', 'onb_avance', 'ultima_llamada',
    'en_que_esta', 'proximos_pasos', 'satisfaccion_ultima', 'upsell',
    'fecha_inicio', 'email', 'telefono'
  ]::text[]
$$;
revoke all on function public.cs_maestro_claves_sistema() from public, anon;
grant execute on function public.cs_maestro_claves_sistema() to authenticated;


-- ---------------------------------------------------------------------
-- B. PRODUCTOS DE AGUS
-- ---------------------------------------------------------------------
insert into public.cs_productos (programa_id, nombre, duracion_dias, orden, activo)
values
  ('agus', 'Skool',         36500, 6, true),    -- SIN VENCIMIENTO (100 años; fecha_fin = 2099-12-31 en la carga)
  ('agus', 'Comunidad',        90, 7, false),   -- ya no se vende (último alta: marzo)
  ('agus', 'Resell Grupal',   120, 8, true),
  ('agus', 'Resell 1 a 1',    120, 9, true)
on conflict (programa_id, nombre) do nothing;


-- ---------------------------------------------------------------------
-- C. COLUMNAS DEL MAESTRO DE AGUS
-- ---------------------------------------------------------------------
-- C1. Columnas nuevas (siempre; on conflict no pisa lo que ya exista)
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, visible, tipo, opciones)
values
  ('agus', 'x_saque_wpp',        false, '¿Lo saqué del grupo de WPP?', 110, true, 'opcion',  '["Si", "No aplica"]'::jsonb),
  ('agus', 'x_saque_skool',      false, '¿Lo saqué de Skool?',          120, true, 'casilla', '[]'::jsonb),
  ('agus', 'x_concepto',         false, 'Concepto',                     130, true, 'opcion',
     '["s/d", "PIF", "Completa PIF", "1ra cuota", "2da cuota", "Fee + completa", "Upsell", "Resell"]'::jsonb),
  ('agus', 'x_grupo_creado_1_1', false, 'Grupo creado 1-1',            140, true, 'casilla', '[]'::jsonb),
  ('agus', 'x_no_responde',      false, 'No responde (!)',              150, true, 'casilla', '[]'::jsonb)
on conflict (programa_id, clave) do nothing;

-- C2. Columnas de la hoja que están vacías en todas las filas (decidido por Joaquín):
--     Referidos Semana 0-2 / 2-4 / 4-6 = número; SEGUIMIENTO 1 y 2 = fecha; AVISO BAJA = casilla (sí/no).
--     La carga de datos no les pone valor (la planilla no tiene ninguno): se completan desde el Maestro.
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, visible, tipo, opciones)
values
  ('agus', 'x_ref_0_2',        false, 'Referidos Semana 0-2', 160, true, 'numero',  '[]'::jsonb),
  ('agus', 'x_ref_2_4',        false, 'Referidos Semana 2-4', 170, true, 'numero',  '[]'::jsonb),
  ('agus', 'x_ref_4_6',        false, 'Referidos Semana 4-6', 180, true, 'numero',  '[]'::jsonb),
  ('agus', 'x_seguimiento_1',  false, 'SEGUIMIENTO 1',        190, true, 'fecha',   '[]'::jsonb),
  ('agus', 'x_seguimiento_2',  false, 'SEGUIMIENTO 2',        195, true, 'fecha',   '[]'::jsonb),
  ('agus', 'x_aviso_baja',     false, 'AVISO BAJA',           197, true, 'casilla', '[]'::jsonb)
on conflict (programa_id, clave) do nothing;

-- C3. Orden y nombres de las del sistema: solo si agus todavía no tiene NINGUNA del sistema configurada.
do $$
begin
  if exists (select 1 from public.cs_maestro_columnas where programa_id = 'agus' and sistema) then
    raise notice 'agus ya tiene columnas del sistema configuradas (orden o nombres): NO se reordenan ni se renombran.';
    return;
  end if;

  insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, visible)
  select 'agus', v.clave, true, v.etiqueta, v.orden, true
  from (values
    -- orden de la hoja
    ('nombre',               null::text,               10),
    ('fecha_inicio',         'Fecha de carga',         20),
    ('producto',             'Programa',               30),
    ('email',                'Mail',                   40),
    ('telefono',             'Número',                 50),
    ('dias_restantes',       'Días restantes',         60),
    ('aviso_1_at',           'Aviso 14-21 días',       70),
    ('aviso_2_at',           'Aviso 0-7 días',         80),
    ('renovacion_estado',    'Estado (resell)',        90),
    ('nota_csm',             'Contexto',              100),
    -- (110 a 150: las columnas nuevas de C1)
    -- el resto de las del sistema, en su orden de siempre
    ('estado',               null,                    200),
    ('testimonio',           null,                    210),
    ('renovacion_producto',  null,                    220),
    ('prioridad',            null,                    230),
    ('responsable',          null,                    240),
    ('proxima_accion',       null,                    250),
    ('proxima_accion_fecha', null,                    260),
    ('etapa',                null,                    270),
    ('acc',                  null,                    280),
    ('dev_pendientes',       null,                    290),
    ('ultimo_seguimiento_fecha',  null,               300),
    ('ultimo_seguimiento_avance', null,               310),
    ('proximo_contacto',     null,                    320),
    ('renovaciones_count',   null,                    330),
    ('onb_avance',           null,                    340),
    ('ultima_llamada',       null,                    350),
    ('en_que_esta',          null,                    360),
    ('proximos_pasos',       null,                    370),
    ('satisfaccion_ultima',  null,                    380),
    ('upsell',               null,                    390)
  ) as v(clave, etiqueta, orden)
  on conflict (programa_id, clave) do nothing;
end $$;


-- ---------------------------------------------------------------------
-- D. HOJA "FUERA DEL MAESTRO"
-- ---------------------------------------------------------------------
create table if not exists public.cs_fuera_maestro (
  id            uuid primary key default gen_random_uuid(),
  programa_id   text not null references public.cs_programas(id) on delete cascade,
  fila_origen   int  not null,                -- número de fila en la hoja (para no duplicar al volver a cargar)
  fecha_carga   date,
  producto_raw  text,                         -- el texto de PROGRAMA tal cual (seña 3 meses, 1era seña...)
  nombre        text,
  mail          text,
  numero        text,
  estado        text,
  contexto      text,
  motivo        text,
  extra         jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object'),
  created_at    timestamptz not null default now(),
  constraint cs_fuera_maestro_fila_key unique (programa_id, fila_origen)
);
comment on table public.cs_fuera_maestro is
  'Hoja "Fuera del maestro" de DCAC: filas sacadas del Maestro y su MOTIVO. Solo lectura en la app; la carga es por migración.';

alter table public.cs_fuera_maestro enable row level security;
revoke all on table public.cs_fuera_maestro from anon;
revoke all on table public.cs_fuera_maestro from authenticated;
grant select on table public.cs_fuera_maestro to authenticated;
drop policy if exists cs_fuera_maestro_ver on public.cs_fuera_maestro;
create policy cs_fuera_maestro_ver on public.cs_fuera_maestro
  for select to authenticated using (public.cs_puede_ver(programa_id));

commit;


-- =====================================================================
-- CONTROLES (correr de a uno, después del commit)
-- =====================================================================
-- C1. Productos de agus (esperado: Grupal, 1 a 1, 1 mes, 3 meses, 45 días + Skool 36500, Comunidad 90 inactivo,
--     Resell Grupal 120, Resell 1 a 1 120).
--   select nombre, duracion_dias, activo, orden from public.cs_productos where programa_id = 'agus' order by orden;
--
-- C2. Columnas de agus en orden (esperado: 10 del orden de la hoja, las 5 nuevas 110 a 150, las 6 de C2 (160 a 197:
--     ref numero x3, seguimiento fecha x2, aviso baja casilla) y el resto desde 200).
--   select orden, clave, sistema, etiqueta, tipo, visible, archivada from public.cs_maestro_columnas
--    where programa_id = 'agus' order by orden;
--
-- C3. La lista de columnas del sistema tiene 30 claves.
--   select cardinality(public.cs_maestro_claves_sistema()) as claves;     -- 30
--
-- C4. Los otros programas no cambiaron (liam y teo: mismas filas que antes de correr; ver el conteo previo).
--   select programa_id, count(*) from public.cs_maestro_columnas group by 1 order by 1;
--
-- C5. Tabla de "Fuera del maestro" creada y vacía hasta correr la migración de datos.
--   select count(*) as filas from public.cs_fuera_maestro;
--
-- C6. RLS de la tabla (esperado: 1 política de select, sin escritura para authenticated).
--   select polname, polcmd from pg_policy where polrelid = 'public.cs_fuera_maestro'::regclass;
--
-- =====================================================================
-- VUELTA ATRÁS (solo si no hay datos cargados; correr en una transacción)
-- =====================================================================
-- begin;
--   drop table if exists public.cs_fuera_maestro;
--   delete from public.cs_maestro_columnas where programa_id = 'agus';          -- solo si agus no tenía configuración antes
--   delete from public.cs_productos p where p.programa_id = 'agus' and p.nombre in ('Skool', 'Comunidad', 'Resell Grupal', 'Resell 1 a 1')
--     and not exists (select 1 from public.cs_clientes c where c.producto_id = p.id)
--     and not exists (select 1 from public.cs_renovaciones r where r.producto_id = p.id);
--   -- La lista de claves del sistema (30) puede quedarse: solo agrega claves, no rompe filas guardadas.
-- commit;
