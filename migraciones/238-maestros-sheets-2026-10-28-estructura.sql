-- =====================================================================
-- 238-maestros-sheets-2026-10-28-estructura.sql  ·  PRODUCTO: Maestros de BPF (liam) y NEC (teo) como los sheets del 28/10
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución). Evitar :00, :15, :30 y :45 (sync de Finanzas) y las 9:00.
-- Requiere: 039 (cs_productos), 071 (cs_maestro_columnas), 079 (x_saque_app de liam), 113 (programas teo / agus)
-- y la 210 CORRIDA (suma 'telefono', 'email' y 'fecha_inicio' a las claves del sistema). Si la 210 no se corrió, aborta sin tocar nada.
--
-- Fuente: insumos/sheets-2026-10-28 (MAESTRO_DE_CLIENTES_-_NEC, Maestro_de_Clientes_BPF, MAESTRO_DE_CLIENTES_-_DCAC).
--
-- Qué hace:
--   A. Productos de liam que trae el sheet y la app no tiene: "BPF Resell 8 Meses" y "BPF Downsell 8 Meses" (240 días, confirmado).
--      Sin ellos la carga de datos de liam (243) aborta. La 243 los da de alta de nuevo si faltaran (on conflict do nothing).
--   B. Respaldo de las columnas de liam y teo en cs_maestro_columnas_respaldo_238 (antes de reordenar / renombrar).
--   C. teo (NEC): columnas nuevas = Concepto (opción), Semana 2 / 4 / 6 (casillas), ¿Lo saqué del WPP / DS / skool? (casillas).
--   D. Orden y nombres del Maestro, igual al sheet:
--        liam: Programa | Alumno | Celular | Días restantes | 21D | 10D | 5D | 0D | Estado de la llamada | Contexto actual renovación |
--              ¿Lo saqué de Skool? | ¿Lo saqué del WPP? | ¿Lo saqué de la App? | Testimonio | JoinedDate |
--              ¿Le pedí referidos? | FUP 1 | FUP 2 | FUP 3 | (resto de siempre, después)
--        teo:  Fecha de carga | Programa | Alumno | Número | Concepto | Semana 2 | 4 | 6 | Días restantes | Aviso a los 21 días |
--              Pitch llamada 10-5 días | Estado (resell) | Contexto | ¿Lo saqué del WPP? | del DS? | de skool? | (resto)
--      Las demás columnas (Estado, Prioridad, Responsable, x_unio_school, etc.) NO se borran ni se ocultan: quedan después
--      (orden 1000 en adelante). NOMBRE y APELLIDO de BPF quedan en UNA columna Alumno (la app guarda un solo nombre).
--      Skool, WPP, referidos y FUP 1 / 2 / 3 de BPF siguen siendo accionables de la plantilla (no se rompe esa lógica): las columnas
--      x_acc_* del Maestro los MUESTRAN (tildado = accionable completado; tildar o destildar en el Maestro completa o reabre el
--      accionable; si el alumno no tiene ese accionable, la casilla guarda en campos_extra). 5D y 0D no existen como accionable en la
--      plantilla: son casillas comunes (x_aviso_5d / x_aviso_0d).
--   E. Tabla cs_llamadas_producto = pestaña "Llamadas Producto" de BPF, EDITABLE (la app reemplaza al sheet): ver con cs_puede_ver y
--      editar con cs_puede_editar, igual que el resto del Maestro. La carga inicial va en la 245.
--
-- No toca: datos de clientes, agus (el Maestro de DCAC no cambió de estructura: ver resumen), la sync, accionables.
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
  v_falta text;
begin
  select string_agg(x.t, ', ') into v_falta
  from (values ('cs_programas'), ('cs_productos'), ('cs_clientes'), ('cs_maestro_columnas')) as x(t)
  where to_regclass('public.' || x.t) is null;
  if v_falta is not null then
    raise exception 'cs 238: faltan tablas: %', v_falta;
  end if;
  if (select count(*) from public.cs_programas where id in ('liam', 'teo')) <> 2 then
    raise exception 'cs 238: tienen que existir los programas liam y teo.';
  end if;
  if to_regprocedure('public.cs_puede_ver(text)') is null or to_regprocedure('public.cs_puede_editar(text)') is null then
    raise exception 'cs 238: falta cs_puede_ver / cs_puede_editar (079).';
  end if;
  if not ('telefono' = any (public.cs_maestro_claves_sistema()) and 'fecha_inicio' = any (public.cs_maestro_claves_sistema())) then
    raise exception 'cs 238: falta correr la 210 (cs_maestro_claves_sistema sin telefono / fecha_inicio).';
  end if;
  if to_regclass('public.cs_maestro_columnas_respaldo_238') is not null then
    if exists (select 1 from public.cs_maestro_columnas_respaldo_238) then
      raise exception 'cs 238: ya se corrió (el respaldo tiene filas). No se repite.';
    end if;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- A. PRODUCTOS DE LIAM
-- ---------------------------------------------------------------------
insert into public.cs_productos (programa_id, nombre, duracion_dias, orden, activo)
values
  ('liam', 'BPF Resell 8 Meses',   240, 6, true),
  ('liam', 'BPF Downsell 8 Meses', 240, 7, true)
on conflict (programa_id, nombre) do nothing;


-- ---------------------------------------------------------------------
-- B. RESPALDO DE COLUMNAS (liam y teo)
-- ---------------------------------------------------------------------
create table if not exists public.cs_maestro_columnas_respaldo_238 as
  select now() as respaldado_at, c.* from public.cs_maestro_columnas c where false;
alter table public.cs_maestro_columnas_respaldo_238 enable row level security;     -- sin políticas: solo el dueño
revoke all on table public.cs_maestro_columnas_respaldo_238 from anon, authenticated;

insert into public.cs_maestro_columnas_respaldo_238
  select now(), c.* from public.cs_maestro_columnas c where c.programa_id in ('liam', 'teo');


-- ---------------------------------------------------------------------
-- C. COLUMNAS NUEVAS DE LIAM (BPF) Y TEO (NEC)
-- ---------------------------------------------------------------------
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, visible, tipo, opciones)
values
  ('liam', 'x_aviso_5d',      false, '5D', 70, true, 'casilla', '[]'::jsonb),
  ('liam', 'x_aviso_0d',      false, '0D', 80, true, 'casilla', '[]'::jsonb),
  ('liam', 'x_acc_skool',     false, '¿Lo saqué de Skool?', 110, true, 'casilla', '[]'::jsonb),
  ('liam', 'x_acc_wpp',       false, '¿Lo saqué del WPP?',  120, true, 'casilla', '[]'::jsonb),
  ('liam', 'x_acc_referidos', false, '¿Le pedí referidos? (primeras 2 semanas)', 160, true, 'casilla', '[]'::jsonb),
  ('liam', 'x_acc_fup_1',     false, 'FUP 1 (semana 2-4)',  170, true, 'casilla', '[]'::jsonb),
  ('liam', 'x_acc_fup_2',     false, 'FUP 2 (semana 4-8)',  180, true, 'casilla', '[]'::jsonb),
  ('liam', 'x_acc_fup_3',     false, 'FUP 3 (semana 8-12)', 190, true, 'casilla', '[]'::jsonb),
  ('teo', 'x_concepto',   false, 'Concepto', 50, true, 'opcion',
     '["FEE", "FEE DE PIF", "FEE 1 RA CUOTA", "REFUERZA FEE", "1RA CUOTA", "2DA CUOTA", "PIF", "COMPLETA PIF", "UPSELL / RESELL"]'::jsonb),
  ('teo', 'x_semana_2',   false, 'Semana 2', 60, true, 'casilla', '[]'::jsonb),
  ('teo', 'x_semana_4',   false, 'Semana 4', 70, true, 'casilla', '[]'::jsonb),
  ('teo', 'x_semana_6',   false, 'Semana 6', 80, true, 'casilla', '[]'::jsonb),
  ('teo', 'x_saque_wpp',  false, '¿Lo saqué del WPP?',  140, true, 'casilla', '[]'::jsonb),
  ('teo', 'x_saque_ds',   false, '¿Lo saqué del DS?',   150, true, 'casilla', '[]'::jsonb),
  ('teo', 'x_saque_skool', false, '¿Lo saqué de skool?', 160, true, 'casilla', '[]'::jsonb)
on conflict (programa_id, clave) do nothing;


-- ---------------------------------------------------------------------
-- D. ORDEN Y NOMBRES (igual al sheet)
-- ---------------------------------------------------------------------
-- D1. Columnas del sistema (clave, etiqueta o null = la que ya tiene / el nombre de siempre, orden)
create temp table pg_temp.plan_238 (programa_id text, clave text, etiqueta text, orden int) on commit drop;
insert into pg_temp.plan_238 values
  ('liam', 'producto',           'Programa',                    10),
  ('liam', 'nombre',             null,                          20),
  ('liam', 'telefono',           'Celular',                     30),
  ('liam', 'dias_restantes',     'Días restantes',              40),
  ('liam', 'aviso_1_at',         '21D',                         50),
  ('liam', 'aviso_2_at',         '10D',                         60),
  ('liam', 'x_aviso_5d',         null,                          70),
  ('liam', 'x_aviso_0d',         null,                          80),
  ('liam', 'renovacion_estado',  'Estado de la llamada',        90),
  ('liam', 'nota_csm',           'Contexto actual renovación', 100),
  ('liam', 'x_acc_skool',        null,                         110),
  ('liam', 'x_acc_wpp',          null,                         120),
  ('liam', 'x_saque_app',        null,                         130),    -- ya existe (079): solo se ordena
  ('liam', 'testimonio',         null,                         140),
  ('liam', 'fecha_inicio',       'JoinedDate',                 150),
  ('liam', 'x_acc_referidos',    null,                         160),
  ('liam', 'x_acc_fup_1',        null,                         170),
  ('liam', 'x_acc_fup_2',        null,                         180),
  ('liam', 'x_acc_fup_3',        null,                         190),
  ('teo',  'fecha_inicio',       'Fecha de carga',              10),
  ('teo',  'producto',           'Programa',                    20),
  ('teo',  'nombre',             null,                          30),
  ('teo',  'telefono',           'Número',                      40),
  ('teo',  'x_concepto',         null,                          50),
  ('teo',  'x_semana_2',         null,                          60),
  ('teo',  'x_semana_4',         null,                          70),
  ('teo',  'x_semana_6',         null,                          80),
  ('teo',  'dias_restantes',     'Días restantes',              90),
  ('teo',  'aviso_1_at',         'Aviso a los 21 días',        100),
  ('teo',  'aviso_2_at',         'Pitch llamada 10-5 días',    110),
  ('teo',  'renovacion_estado',  'Estado (resell)',            120),
  ('teo',  'nota_csm',           'Contexto',                   130),
  ('teo',  'x_saque_wpp',        null,                         140),
  ('teo',  'x_saque_ds',         null,                         150),
  ('teo',  'x_saque_skool',      null,                         160);

-- D2. Lo que NO está en el sheet queda después, en el orden que ya tenía (1000 en adelante).
update public.cs_maestro_columnas c
   set orden = 1000 + n.rn, updated_at = now()
  from (select m.id, row_number() over (partition by m.programa_id order by m.orden nulls last, m.clave) as rn
          from public.cs_maestro_columnas m
         where m.programa_id in ('liam', 'teo')
           and not exists (select 1 from pg_temp.plan_238 p where p.programa_id = m.programa_id and p.clave = m.clave)) n
 where c.id = n.id;

-- D3. Las del sheet: las del sistema se crean o actualizan (visibles); las x_ ya existen (079, 238 C) y solo se ordenan.
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, visible)
select p.programa_id, p.clave, true, p.etiqueta, p.orden, true
  from pg_temp.plan_238 p
 where p.clave = any (public.cs_maestro_claves_sistema())
on conflict (programa_id, clave) do update
  set etiqueta = coalesce(excluded.etiqueta, public.cs_maestro_columnas.etiqueta),
      orden = excluded.orden, visible = true, updated_at = now();

update public.cs_maestro_columnas c
   set orden = p.orden, visible = true, updated_at = now()
  from pg_temp.plan_238 p
 where p.programa_id = c.programa_id and p.clave = c.clave and not c.sistema;

do $$
declare
  v_falta text;
begin
  select string_agg(p.programa_id || '.' || p.clave, ', ') into v_falta
  from pg_temp.plan_238 p
  where not exists (select 1 from public.cs_maestro_columnas c where c.programa_id = p.programa_id and c.clave = p.clave);
  if v_falta is not null then
    raise exception 'cs 238: columnas del plan que no quedaron en cs_maestro_columnas: % (¿falta la 079 en liam?)', v_falta;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- E. HOJA "LLAMADAS PRODUCTO" (BPF)
-- ---------------------------------------------------------------------
create table if not exists public.cs_llamadas_producto (
  id               uuid primary key default gen_random_uuid(),
  programa_id      text not null references public.cs_programas(id) on delete cascade,
  fila_origen      int  not null,                -- número de fila en la hoja (para no duplicar al volver a cargar)
  encargado        text,                         -- ENCARGADO DE LA LLAMADA
  fecha_agendada   date,                         -- FECHA AGENDADA
  fecha_llamada_txt text,                        -- FECHA LLAMADA, tal cual ("Friday, October 16, 2026 6:30 PM")
  nombre           text,                         -- NOMBRE COMPLETO
  telefono         text,
  email            text,
  show_up          text,                         -- SHOW UP
  estado_llamada   text,                         -- ESTADO DE LA LLAMADA
  contexto         text,
  tipo_venta       text,                         -- TIPO DE VENTA (CHURN / RESELL)
  cc_dia_1         text,
  cc_seguimiento   text,
  cc_trato_cerrado text,
  monto_restante   text,                         -- MONTO RESTANTE A PAGAR
  phatom           text,                         -- PHATOM
  cliente_id       uuid references public.cs_clientes(id) on delete set null,   -- si se pudo emparejar con un alumno
  extra            jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object'),   -- columnas sin nombre
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint cs_llamadas_producto_fila_key unique (programa_id, fila_origen)
);
comment on table public.cs_llamadas_producto is
  'Hoja "Llamadas Producto" del Maestro de BPF: llamadas de resell / churn. Editable en la app (reemplaza al sheet); la carga inicial es la 245.';

alter table public.cs_llamadas_producto enable row level security;
revoke all on table public.cs_llamadas_producto from anon;
revoke all on table public.cs_llamadas_producto from authenticated;
grant select, insert, update, delete on table public.cs_llamadas_producto to authenticated;

-- Mismos permisos que el Maestro: ve quien ve el programa, escribe quien lo edita (fundador o nivel 'edicion').
drop policy if exists cs_llamadas_producto_ver on public.cs_llamadas_producto;
create policy cs_llamadas_producto_ver on public.cs_llamadas_producto
  for select to authenticated using (public.cs_puede_ver(programa_id));
drop policy if exists cs_llamadas_producto_alta on public.cs_llamadas_producto;
create policy cs_llamadas_producto_alta on public.cs_llamadas_producto
  for insert to authenticated with check (public.cs_puede_editar(programa_id));
drop policy if exists cs_llamadas_producto_edicion on public.cs_llamadas_producto;
create policy cs_llamadas_producto_edicion on public.cs_llamadas_producto
  for update to authenticated using (public.cs_puede_editar(programa_id)) with check (public.cs_puede_editar(programa_id));
drop policy if exists cs_llamadas_producto_baja on public.cs_llamadas_producto;
create policy cs_llamadas_producto_baja on public.cs_llamadas_producto
  for delete to authenticated using (public.cs_puede_editar(programa_id));

commit;


-- =====================================================================
-- CONTROLES (correr de a uno, después del commit)
-- =====================================================================
-- C1. Productos de liam (esperado: los 5 de la 039 + BPF Resell 8 Meses y BPF Downsell 8 Meses, 240 días).
--   select nombre, duracion_dias, activo, orden from public.cs_productos where programa_id = 'liam' order by orden;
--
-- C2. Columnas de liam y teo en orden (esperado: las del sheet primero, con sus nombres; el resto desde 1001).
--   select programa_id, orden, clave, sistema, etiqueta, tipo, visible from public.cs_maestro_columnas
--    where programa_id in ('liam', 'teo') order by programa_id, orden;
--
-- C3. Respaldo (esperado: una fila por cada columna que liam y teo tenían antes; comparar con el conteo previo).
--   select programa_id, count(*) from public.cs_maestro_columnas_respaldo_238 group by 1;
--
-- C4. agus no cambió (mismas filas que antes).
--   select programa_id, count(*) from public.cs_maestro_columnas group by 1 order by 1;
--
-- C5. Tabla de Llamadas Producto creada, vacía hasta la 245, con RLS (4 políticas: select con cs_puede_ver; insert, update y delete con cs_puede_editar).
--   select count(*) from public.cs_llamadas_producto;
--   select polname, polcmd from pg_policy where polrelid = 'public.cs_llamadas_producto'::regclass;
--
-- =====================================================================
-- VUELTA ATRÁS (solo si no hay datos cargados en cs_llamadas_producto; en una transacción)
-- =====================================================================
-- begin;
--   delete from public.cs_maestro_columnas where programa_id in ('liam', 'teo');
--   insert into public.cs_maestro_columnas (id, programa_id, clave, sistema, etiqueta, orden, visible, tipo, opciones, archivada, created_at, updated_at)
--     select id, programa_id, clave, sistema, etiqueta, orden, visible, tipo, opciones, archivada, created_at, updated_at
--       from public.cs_maestro_columnas_respaldo_238;
--   drop table if exists public.cs_llamadas_producto;
--   delete from public.cs_productos p where p.programa_id = 'liam' and p.nombre in ('BPF Resell 8 Meses', 'BPF Downsell 8 Meses')
--     and not exists (select 1 from public.cs_clientes c where c.producto_id = p.id)
--     and not exists (select 1 from public.cs_renovaciones r where r.producto_id = p.id);
-- commit;
