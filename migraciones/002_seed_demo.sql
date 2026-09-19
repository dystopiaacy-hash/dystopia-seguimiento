-- =====================================================================
-- 002_seed_demo.sql  —  Dystopia Seguimiento, FASE 2: datos DEMO
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Requiere 001_esquema_cs.sql. Todo va en una transacción.
--
-- Qué hace:
--   1. UPDATE de cs_programas.plantilla_accionables de liam (los 5 programas
--      ya existen desde 001: acá NO se insertan).
--   2. 14 clientes DEMO en liam ("Cliente Demo 01..14", demoNN@ejemplo.com),
--      uno o más por cada caso del semáforo.
--   3. Accionables, calls, devoluciones, renovaciones, chequeos, 2 formularios
--      "(demo)" y respuestas de satisfacción (2 puntajes bajos).
--
-- Convivencia con los triggers de 001 (no se desactiva ninguno):
--   - Un cliente insertado en 'onboarding' o 'activo' YA genera sus accionables
--     de día 0 (y la call de onboarding si es 'onboarding'). Acá no se insertan
--     de nuevo: se completan o se dejan pendientes con UPDATE.
--   - Los ítems de plantilla con dia_offset > 0 no los genera ningún trigger:
--     se insertan acá con plantilla_key (la unique (cliente_id, plantilla_key)
--     impide duplicados).
--   - Renovaciones cerradas: se insertan 'en_proceso' y después UPDATE a
--     'renovado' / 'no_renovado', así corren los triggers que mueven al cliente
--     (estado, fecha_fin, renovaciones_count).
--   - Fechas que los triggers pisan con now():
--       * accionables.completado_at y renovaciones.resultado_at: al cambiar de
--         estado por UPDATE el trigger pone now(). Se corrige con un segundo
--         UPDATE (con el estado ya cerrado, el trigger respeta el valor dado).
--       * devoluciones.entregada_at, chequeos.created_at, solicitada_at,
--         iniciada_at: en INSERT el trigger respeta el valor explícito
--         (coalesce), así que se cargan directo con la fecha pasada.
--       * cs_clientes.ultimo_chequeo_at lo calcula el trigger de cs_chequeos
--         desde created_at del chequeo: "sin chequeo hace 10 días" = un chequeo
--         con created_at = now() - 10 días.
--       * cs_historial.at: todo lo que escriben los triggers queda con now().
--         Al final se re-fechan SOLO las filas de esta transacción (at = now(),
--         que dentro de una transacción es constante).
--   - auth.uid() es null en el SQL Editor: created_by, cs_chequeos.usuario y
--     cs_historial.usuario quedan en null (columnas nullables, sin NOT NULL ni
--     trigger que lo exija). La UI debe mostrar null como "sistema".
--   - El SQL Editor corre como postgres (BYPASSRLS): la RLS no interviene.
--
-- No se insertan alertas (cs_alertas): las genera la función de la Fase 4 con
-- su propio formato de clave_dedupe. 002b borra también las que se generen.
--
-- Supone la configuración default de liam (90 días, aviso 30, SLA devolución
-- 72 h, SLA onboarding 3 días, alerta sin chequeo 7 días). Si no coincide,
-- aborta sin tocar nada.
--
-- Si ya hay datos demo, aborta: correr 002b_borrar_demo.sql antes de re-sembrar.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Guardas
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.cs_programas where id = 'liam') then
    raise exception 'No existe el programa liam. ¿Corriste 001_esquema_cs.sql?';
  end if;
  if exists (select 1 from public.cs_clientes where email ilike '%@ejemplo.com')
     or exists (select 1 from public.cs_formularios where nombre like '%(demo)') then
    raise exception 'Ya hay datos demo cargados. Corré 002b_borrar_demo.sql antes de volver a sembrar.';
  end if;
  if exists (
    select 1 from public.cs_programas
    where id = 'liam'
      and (duracion_default_dias, aviso_renovacion_dias, sla_devolucion_horas,
           sla_onboarding_dias, dias_sin_chequeo_alerta) <> (90, 30, 72, 3, 7)
  ) then
    raise exception 'La configuración de liam no es la default (90/30/72/3/7): los casos demo no darían el semáforo esperado.';
  end if;
end $$;

-- Helpers temporales (desaparecen al cerrar la sesión).
-- id del cliente demo N
create or replace function pg_temp.demo(n int) returns uuid
language sql stable as $$
  select id from public.cs_clientes where email = format('demo%s@ejemplo.com', lpad(n::text, 2, '0'))
$$;
-- fecha de negocio + hora en Buenos Aires -> timestamptz, nunca en el futuro
create or replace function pg_temp.ts(d date, h int default 11) returns timestamptz
language sql stable as $$
  select least((d + make_time(h, 0, 0)) at time zone 'America/Argentina/Buenos_Aires', now())
$$;

-- ---------------------------------------------------------------------
-- 1. Plantilla de accionables de liam (UPDATE, el programa ya existe)
--    vence de ítems con dia_offset > 0 = fecha_inicio + dia_offset + vence_en_dias
-- ---------------------------------------------------------------------
update public.cs_programas
   set plantilla_accionables = '[
     {"key":"agendar_onboarding",    "titulo":"Agendar call de onboarding",              "responsable":"bpf",     "dia_offset":0,  "vence_en_dias":2},
     {"key":"enviar_accesos",        "titulo":"Enviar accesos y bienvenida",             "responsable":"bpf",     "dia_offset":0,  "vence_en_dias":1},
     {"key":"formulario_onboarding", "titulo":"Completar formulario de onboarding",      "responsable":"cliente", "dia_offset":0,  "vence_en_dias":3},
     {"key":"portafolio_inicial",    "titulo":"Enviar portafolio actual para revisión",  "responsable":"cliente", "dia_offset":7,  "vence_en_dias":5},
     {"key":"satisfaccion_mes_1",    "titulo":"Enviar formulario de satisfacción mes 1", "responsable":"bpf",     "dia_offset":30, "vence_en_dias":3},
     {"key":"satisfaccion_mes_2",    "titulo":"Enviar formulario de satisfacción mes 2", "responsable":"bpf",     "dia_offset":60, "vence_en_dias":3}
   ]'::jsonb
 where id = 'liam';

-- ---------------------------------------------------------------------
-- 2. Clientes demo
--    ini = días desde el inicio; fin = días hasta el fin (null = default 90 días).
--    Todos entran como 'onboarding' o 'activo'; el trigger genera la plantilla
--    de día 0 y, en 'onboarding', la call de onboarding.
-- ---------------------------------------------------------------------
insert into public.cs_clientes
  (programa_id, nombre, email, telefono, fecha_inicio, fecha_fin, estado, etapa, responsable, plan, notas, created_at)
select 'liam',
       format('Cliente Demo %s', lpad(v.n::text, 2, '0')),
       format('demo%s@ejemplo.com', lpad(v.n::text, 2, '0')),
       format('+54 9 11 0000-00%s', lpad(v.n::text, 2, '0')),
       public.cs_hoy() - v.ini,
       case when v.fin is null then null else public.cs_hoy() + v.fin end,
       v.estado, v.etapa, 'Equipo BPF', 'Mentoría 90 días', v.notas,
       pg_temp.ts(public.cs_hoy() - v.ini, 10)
from (values
  ( 1,   6, null::int, 'onboarding', 'Onboarding',           'DEMO · Onboarding demorado: la call sigue sin agendar.'),
  ( 2,   1, null,      'onboarding', 'Onboarding',           'DEMO · Onboarding en curso, dentro del plazo.'),
  ( 3,  20, null,      'activo',     'Armado de portafolio', 'DEMO · Activo al día.'),
  ( 4,  45, null,      'activo',     'Seguimiento',          'DEMO · Activo al día.'),
  ( 5,  10, null,      'activo',     'Diagnóstico',          'DEMO · Activo al día (accionable del cliente pendiente, en fecha).'),
  ( 6,  32, null,      'activo',     'Seguimiento',          'DEMO · Devolución fuera de SLA.'),
  ( 7,  15, null,      'activo',     'Armado de portafolio', 'DEMO · Devolución pendiente dentro del SLA.'),
  ( 8,  35, null,      'activo',     'Seguimiento',          'DEMO · Accionable BPF vencido (satisfacción mes 1).'),
  ( 9,  70, 20,        'activo',     'Seguimiento',          'DEMO · A 20 días de terminar sin renovación.'),
  (10,  80, 10,        'activo',     'Renovación',           'DEMO · En renovación.'),
  (11,  95, -5,        'activo',     'Seguimiento',          'DEMO · Renovado.'),
  (12,  82, 8,         'activo',     'Renovación',           'DEMO · No renovó: sigue hasta que vence.'),
  (13, 120, -30,       'activo',     'Renovación',           'DEMO · No renovó y el programa ya terminó (finalizado).'),
  (14,  25, null,      'activo',     'Seguimiento',          'DEMO · Sin chequeo hace 10 días.')
) as v(n, ini, fin, estado, etapa, notas);

-- Lo que generó el trigger (accionables día 0, calls de onboarding) queda con
-- created_at = now(): se alinea con el alta del cliente.
update public.cs_accionables a
   set created_at = c.created_at
  from public.cs_clientes c
 where a.cliente_id = c.id and c.email like 'demo%@ejemplo.com';

update public.cs_calls x
   set created_at = c.created_at
  from public.cs_clientes c
 where x.cliente_id = c.id and c.email like 'demo%@ejemplo.com';

-- ---------------------------------------------------------------------
-- 3. Accionables
-- ---------------------------------------------------------------------
-- 3a. Ítems de plantilla con dia_offset > 0 ya "llegados" (inicio + offset <= hoy).
--     Completados, salvo: demo05 portafolio_inicial (en fecha) y
--     demo08 satisfaccion_mes_1 (BPF vencido).
insert into public.cs_accionables
  (programa_id, cliente_id, responsable, titulo, estado, vence, completado_at, origen, plantilla_key, created_at)
select c.programa_id, c.id, e->>'responsable', e->>'titulo',
       case when x.pend then 'pendiente' else 'completado' end,
       c.fecha_inicio + (e->>'dia_offset')::int + (e->>'vence_en_dias')::int,
       case when not x.pend then pg_temp.ts(c.fecha_inicio + (e->>'dia_offset')::int + 1, 16) end,
       'plantilla', e->>'key',
       pg_temp.ts(c.fecha_inicio + (e->>'dia_offset')::int, 9)
from public.cs_clientes c
join public.cs_programas p on p.id = c.programa_id
cross join lateral jsonb_array_elements(p.plantilla_accionables) e
cross join lateral (
  select (c.email, e->>'key') in (('demo05@ejemplo.com', 'portafolio_inicial'),
                                  ('demo08@ejemplo.com', 'satisfaccion_mes_1')) as pend
) x
where c.email like 'demo%@ejemplo.com'
  and c.estado <> 'onboarding'
  and (e->>'dia_offset')::int > 0
  and c.fecha_inicio + (e->>'dia_offset')::int <= public.cs_hoy();

-- 3b. Día 0 (generados por el trigger): se completan todos menos
--     demo01 (agendar call + formulario quedan vencidos) y demo02 (en plazo).
update public.cs_accionables a
   set estado = 'completado'
  from public.cs_clientes c
 where a.cliente_id = c.id
   and c.email like 'demo%@ejemplo.com'
   and a.origen = 'plantilla'
   and a.estado <> 'completado'
   and c.email <> 'demo02@ejemplo.com'
   and (c.email, a.plantilla_key) not in (('demo01@ejemplo.com', 'agendar_onboarding'),
                                          ('demo01@ejemplo.com', 'formulario_onboarding'),
                                          ('demo05@ejemplo.com', 'portafolio_inicial'),
                                          ('demo08@ejemplo.com', 'satisfaccion_mes_1'));

-- El trigger puso completado_at = now(); segundo UPDATE con la fecha real
-- (el día antes del vencimiento). Con el estado ya 'completado' el trigger la respeta.
update public.cs_accionables a
   set completado_at = pg_temp.ts(a.vence - 1, 16)
  from public.cs_clientes c
 where a.cliente_id = c.id
   and c.email like 'demo%@ejemplo.com'
   and a.estado = 'completado'
   and a.completado_at = now();

-- 3c. Manuales (para que no todo sea de plantilla).
insert into public.cs_accionables (programa_id, cliente_id, responsable, titulo, estado, vence, completado_at, origen, created_at)
values
  ('liam', pg_temp.demo(3), 'bpf',     'Grabar devolución del armado de portafolio', 'pendiente',  public.cs_hoy() + 3, null,
   'manual', now() - interval '2 days'),
  ('liam', pg_temp.demo(4), 'cliente', 'Mirar el Loom de la última devolución',      'completado', public.cs_hoy() - 7, pg_temp.ts(public.cs_hoy() - 8, 19),
   'manual', pg_temp.ts(public.cs_hoy() - 9, 10));

-- ---------------------------------------------------------------------
-- 4. Calls (demo01 y demo02 ya tienen su call de onboarding del trigger)
-- ---------------------------------------------------------------------
-- Onboarding realizada para todos los que no están en onboarding.
insert into public.cs_calls (programa_id, cliente_id, tipo, estado, fecha, notas, created_at)
select c.programa_id, c.id, 'onboarding', 'realizada', pg_temp.ts(c.fecha_inicio + 2, 15), null, c.created_at
from public.cs_clientes c
where c.email like 'demo%@ejemplo.com' and c.estado <> 'onboarding';

insert into public.cs_calls (programa_id, cliente_id, tipo, estado, fecha, notas, created_at)
select 'liam', pg_temp.demo(v.n), v.tipo, v.estado, v.fecha, v.notas, v.creada
from (values
  ( 3, 'seguimiento', 'agendada',  date_trunc('hour', now()) + interval '2 days',  null::text,               now() - interval '3 days'),
  ( 4, 'seguimiento', 'realizada', pg_temp.ts(public.cs_hoy() - 14, 17),           null,                     pg_temp.ts(public.cs_hoy() - 20)),
  ( 4, 'seguimiento', 'agendada',  date_trunc('hour', now()) + interval '5 days',  null,                     now() - interval '1 day'),
  ( 6, 'seguimiento', 'no_show',   pg_temp.ts(public.cs_hoy() - 4, 18),            'No se conectó.',         pg_temp.ts(public.cs_hoy() - 9)),
  ( 9, 'seguimiento', 'realizada', pg_temp.ts(public.cs_hoy() - 12, 16),           null,                     pg_temp.ts(public.cs_hoy() - 16)),
  (14, 'seguimiento', 'realizada', pg_temp.ts(public.cs_hoy() - 11, 15),           null,                     pg_temp.ts(public.cs_hoy() - 15)),
  (10, 'renovacion',  'agendada',  date_trunc('hour', now()) + interval '1 day',   null,                     now() - interval '3 days'),
  (11, 'renovacion',  'realizada', pg_temp.ts(public.cs_hoy() - 8, 16),            null,                     pg_temp.ts(public.cs_hoy() - 12)),
  (12, 'renovacion',  'realizada', pg_temp.ts(public.cs_hoy() - 3, 16),            null,                     pg_temp.ts(public.cs_hoy() - 6)),
  (13, 'renovacion',  'realizada', pg_temp.ts(public.cs_hoy() - 33, 16),           null,                     pg_temp.ts(public.cs_hoy() - 40))
) as v(n, tipo, estado, fecha, notas, creada);

-- ---------------------------------------------------------------------
-- 5. Devoluciones (entregadas con Loom demo; entregada_at explícito en INSERT)
--    demo06: pendiente hace 5 días (SLA 72 h vencido) -> rojo
--    demo07: en_proceso hace 1 día (dentro del SLA)   -> amarillo
-- ---------------------------------------------------------------------
insert into public.cs_devoluciones (programa_id, cliente_id, titulo, solicitada_at, estado, loom_url, entregada_at, created_at)
select 'liam', pg_temp.demo(v.n), v.titulo, v.sol, v.estado, v.loom,
       case when v.estado = 'entregada' then v.ent end, v.sol
from (values
  ( 3, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 12, 10),  'entregada',  'https://www.loom.com/share/demo-03-a', pg_temp.ts(public.cs_hoy() - 10, 18)),
  ( 4, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 36, 10),  'entregada',  'https://www.loom.com/share/demo-04-a', pg_temp.ts(public.cs_hoy() - 34, 18)),
  ( 4, 'Rebalanceo mes 1',               pg_temp.ts(public.cs_hoy() - 10, 10),  'entregada',  'https://www.loom.com/share/demo-04-b', pg_temp.ts(public.cs_hoy() -  9, 12)),
  ( 6, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 21, 10),  'entregada',  'https://www.loom.com/share/demo-06-a', pg_temp.ts(public.cs_hoy() - 19, 18)),
  ( 6, 'Rebalanceo mes 1',               now() - interval '5 days',             'pendiente',  null::text,                             null::timestamptz),
  ( 7, 'Revisión de portafolio inicial', now() - interval '1 day',              'en_proceso', null,                                   null),
  ( 8, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 26, 10),  'entregada',  'https://www.loom.com/share/demo-08-a', pg_temp.ts(public.cs_hoy() - 24, 18)),
  ( 9, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 60, 10),  'entregada',  'https://www.loom.com/share/demo-09-a', pg_temp.ts(public.cs_hoy() - 58, 18)),
  ( 9, 'Rebalanceo mes 1',               pg_temp.ts(public.cs_hoy() - 30, 10),  'entregada',  'https://www.loom.com/share/demo-09-b', pg_temp.ts(public.cs_hoy() - 29, 18)),
  (10, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 70, 10),  'entregada',  'https://www.loom.com/share/demo-10-a', pg_temp.ts(public.cs_hoy() - 68, 18)),
  (10, 'Rebalanceo mes 2',               pg_temp.ts(public.cs_hoy() - 20, 10),  'entregada',  'https://www.loom.com/share/demo-10-b', pg_temp.ts(public.cs_hoy() - 17, 18)),
  (11, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 85, 10),  'entregada',  'https://www.loom.com/share/demo-11-a', pg_temp.ts(public.cs_hoy() - 83, 18)),
  (11, 'Rebalanceo mes 2',               pg_temp.ts(public.cs_hoy() - 40, 10),  'entregada',  'https://www.loom.com/share/demo-11-b', pg_temp.ts(public.cs_hoy() - 38, 18)),
  (12, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 72, 10),  'entregada',  'https://www.loom.com/share/demo-12-a', pg_temp.ts(public.cs_hoy() - 70, 18)),
  (13, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 110, 10), 'entregada',  'https://www.loom.com/share/demo-13-a', pg_temp.ts(public.cs_hoy() - 108, 18)),
  (13, 'Rebalanceo mes 2',               pg_temp.ts(public.cs_hoy() - 60, 10),  'entregada',  'https://www.loom.com/share/demo-13-b', pg_temp.ts(public.cs_hoy() - 57, 18)),
  (14, 'Revisión de portafolio inicial', pg_temp.ts(public.cs_hoy() - 16, 10),  'entregada',  'https://www.loom.com/share/demo-14-a', pg_temp.ts(public.cs_hoy() - 12, 18))
) as v(n, titulo, sol, estado, loom, ent);

-- ---------------------------------------------------------------------
-- 6. Renovaciones: INSERT en_proceso y después UPDATE (corren los triggers)
-- ---------------------------------------------------------------------
insert into public.cs_renovaciones (programa_id, cliente_id, iniciada_at, created_at)
select 'liam', pg_temp.demo(v.n), v.ini, v.ini
from (values
  (10, now() - interval '3 days'),
  (11, pg_temp.ts(public.cs_hoy() - 12)),
  (12, pg_temp.ts(public.cs_hoy() - 6)),
  (13, pg_temp.ts(public.cs_hoy() - 40))
) as v(n, ini);
-- (el trigger pasó a los 4 clientes a 'en_renovacion')

-- demo11: renovado. fecha_fin pasa de hoy-5 a hoy+85 y renovaciones_count = 1.
update public.cs_renovaciones
   set estado = 'renovado', nueva_fecha_fin = public.cs_hoy() + 85
 where cliente_id = pg_temp.demo(11) and estado = 'en_proceso';

-- demo12: no renovado con fecha_fin futura -> vuelve a 'activo' hasta que venza.
-- demo13: no renovado con fecha_fin vencida -> pasa directo a 'finalizado'.
update public.cs_renovaciones
   set estado = 'no_renovado', motivo = 'Prefiere seguir por su cuenta.'
 where cliente_id = pg_temp.demo(12) and estado = 'en_proceso';
update public.cs_renovaciones
   set estado = 'no_renovado', motivo = 'Motivos económicos.'
 where cliente_id = pg_temp.demo(13) and estado = 'en_proceso';

-- resultado_at quedó en now(); ya cerradas, el trigger respeta el valor dado.
update public.cs_renovaciones r
   set resultado_at = v.res
  from (values
    (11, pg_temp.ts(public.cs_hoy() - 6, 17)),
    (12, pg_temp.ts(public.cs_hoy() - 2, 17)),
    (13, pg_temp.ts(public.cs_hoy() - 31, 17))
  ) as v(n, res)
 where r.cliente_id = pg_temp.demo(v.n) and r.estado in ('renovado', 'no_renovado');

-- ---------------------------------------------------------------------
-- 7. Chequeos (el trigger actualiza ultimo_chequeo_at desde created_at)
--    demo14: último chequeo hace 10 días -> amarillo. demo01/02: sin chequeos.
-- ---------------------------------------------------------------------
insert into public.cs_chequeos (programa_id, cliente_id, nota, created_at)
select 'liam', pg_temp.demo(v.n), v.nota, v.at
from (values
  ( 3, 'Todo en orden.',                      now() - interval '2 days'),
  ( 4, null::text,                            now() - interval '20 days'),
  ( 4, 'Muy comprometido.',                   now() - interval '1 day'),
  ( 5, null,                                  now() - interval '3 days'),
  ( 6, 'Pidió rebalanceo, está esperando.',   now() - interval '1 day'),
  ( 7, null,                                  now() - interval '2 days'),
  ( 8, null,                                  now() - interval '1 day'),
  ( 9, null,                                  now() - interval '3 days'),
  (10, 'Interesado en renovar.',              now() - interval '1 day'),
  (11, null,                                  now() - interval '2 days'),
  (12, null,                                  now() - interval '2 days'),
  (13, 'Cierre del programa.',                pg_temp.ts(public.cs_hoy() - 32, 12)),
  (14, null,                                  now() - interval '24 days'),
  (14, 'Último contacto.',                    now() - interval '10 days')
) as v(n, nota, at);

-- ---------------------------------------------------------------------
-- 8. Formularios demo (se identifican por el sufijo "(demo)" en el nombre)
-- ---------------------------------------------------------------------
insert into public.cs_formularios (programa_id, nombre, tipo, campos, activo, created_at)
values
  ('liam', 'Onboarding (demo)', 'onboarding', '[
     {"key":"objetivo",       "label":"¿Cuál es tu objetivo principal con el programa?", "tipo":"opcion",
      "opciones":["Ordenar mis finanzas","Empezar a invertir","Mejorar lo que ya tengo"], "requerido":true},
     {"key":"experiencia",    "label":"¿Qué experiencia tenés invirtiendo?", "tipo":"opcion",
      "opciones":["Ninguna","Básica","Intermedia","Avanzada"], "requerido":true},
     {"key":"disponibilidad", "label":"¿Qué días y horarios te quedan cómodos para las calls?", "tipo":"texto", "requerido":false},
     {"key":"expectativas",   "label":"¿Qué esperás lograr en estos 90 días?", "tipo":"parrafo", "requerido":false}
   ]'::jsonb, true, pg_temp.ts(public.cs_hoy() - 130)),
  ('liam', 'Satisfacción mensual (demo)', 'satisfaccion', '[
     {"key":"puntaje",      "label":"Del 0 al 10, ¿qué tan satisfecho/a estás con el programa?", "tipo":"escala_0_10", "requerido":true, "es_metrica":true},
     {"key":"lo_mejor",     "label":"¿Qué es lo que más valorás?", "tipo":"parrafo", "requerido":false},
     {"key":"mejorar",      "label":"¿Qué mejorarías?",            "tipo":"parrafo", "requerido":false},
     {"key":"recomendaria", "label":"¿Recomendarías el programa?",  "tipo":"si_no",   "requerido":true}
   ]'::jsonb, true, pg_temp.ts(public.cs_hoy() - 130));

-- ---------------------------------------------------------------------
-- 9. Respuestas. puntaje va null: lo extrae el trigger del campo es_metrica.
--    Satisfacción: 12 respuestas, 2 bajas (4 y 5). Onboarding: 3.
-- ---------------------------------------------------------------------
insert into public.cs_respuestas (programa_id, formulario_id, cliente_id, respuestas, created_at)
select 'liam', f.id, pg_temp.demo(v.n),
       jsonb_build_object('puntaje', v.p, 'lo_mejor', v.mejor, 'mejorar', v.mejorar,
                          'recomendaria', case when v.p >= 7 then 'si' else 'no' end),
       v.at
from (values
  ( 4, 9,  'Las devoluciones en video.',        '',                                   pg_temp.ts(public.cs_hoy() - 13, 20)),
  ( 6, 4,  '',                                  'Que las devoluciones lleguen a tiempo.', now() - interval '2 hours'),
  ( 9, 8,  'La claridad de las explicaciones.', '',                                   pg_temp.ts(public.cs_hoy() - 38, 20)),
  ( 9, 7,  '',                                  'Más calls de seguimiento.',          pg_temp.ts(public.cs_hoy() - 8, 20)),
  (10, 9,  'El acompañamiento.',                '',                                   pg_temp.ts(public.cs_hoy() - 48, 20)),
  (10, 8,  '',                                  '',                                   pg_temp.ts(public.cs_hoy() - 18, 20)),
  (11, 10, 'Todo.',                             '',                                   pg_temp.ts(public.cs_hoy() - 63, 20)),
  (11, 9,  'Las devoluciones.',                 '',                                   pg_temp.ts(public.cs_hoy() - 33, 20)),
  (12, 7,  '',                                  '',                                   pg_temp.ts(public.cs_hoy() - 50, 20)),
  (12, 5,  '',                                  'Esperaba más contenido práctico.',   pg_temp.ts(public.cs_hoy() - 20, 20)),
  (13, 7,  '',                                  '',                                   pg_temp.ts(public.cs_hoy() - 88, 20)),
  (13, 7,  '',                                  '',                                   pg_temp.ts(public.cs_hoy() - 58, 20))
) as v(n, p, mejor, mejorar, at)
join public.cs_formularios f on f.programa_id = 'liam' and f.nombre = 'Satisfacción mensual (demo)';

insert into public.cs_respuestas (programa_id, formulario_id, cliente_id, respuestas, created_at)
select 'liam', f.id, c.id,
       jsonb_build_object('objetivo', v.obj, 'experiencia', v.exp, 'disponibilidad', 'Martes y jueves a la tarde',
                          'expectativas', 'Tener un plan claro y sostenerlo.'),
       pg_temp.ts(c.fecha_inicio + 2, 21)
from (values
  ( 3, 'Empezar a invertir',      'Básica'),
  ( 4, 'Mejorar lo que ya tengo', 'Intermedia'),
  ( 5, 'Ordenar mis finanzas',    'Ninguna')
) as v(n, obj, exp)
join public.cs_clientes c on c.id = pg_temp.demo(v.n)
join public.cs_formularios f on f.programa_id = 'liam' and f.nombre = 'Onboarding (demo)';

-- ---------------------------------------------------------------------
-- 10. Re-fechar cs_historial: SOLO filas escritas en esta transacción
--     (at = now() es constante dentro de la transacción).
-- ---------------------------------------------------------------------
-- Valor inicial (INSERT) -> fecha de creación del registro.
update public.cs_historial h
   set at = x.creado
  from (
    select id, created_at as creado from public.cs_clientes
    union all select id, created_at from public.cs_accionables
    union all select id, created_at from public.cs_devoluciones
    union all select id, created_at from public.cs_calls
    union all select id, created_at from public.cs_renovaciones
  ) x
 where h.registro_id = x.id and h.at = now() and h.valor_anterior is null;

-- Accionables completados por UPDATE -> completado_at.
update public.cs_historial h
   set at = a.completado_at
  from public.cs_accionables a
 where h.tabla = 'cs_accionables' and h.registro_id = a.id and h.at = now()
   and h.valor_nuevo = 'completado' and a.completado_at is not null;

-- Renovaciones cerradas -> resultado_at.
update public.cs_historial h
   set at = r.resultado_at
  from public.cs_renovaciones r
 where h.tabla = 'cs_renovaciones' and h.registro_id = r.id and h.at = now()
   and r.resultado_at is not null;

-- Cambios del cliente provocados por su renovación:
-- a 'en_renovacion' cuando se inició; el resto (activo/finalizado/fecha_fin) al resolverse.
update public.cs_historial h
   set at = case when h.valor_nuevo = 'en_renovacion' then r.iniciada_at
                 else coalesce(r.resultado_at, r.iniciada_at) end
  from public.cs_renovaciones r
 where h.tabla = 'cs_clientes' and h.registro_id = r.cliente_id and h.at = now()
   and h.valor_anterior is not null;

commit;


-- =====================================================================
-- QUERY DE CONTROL (mirar la columna ok: todo debe dar true)
-- =====================================================================
with v as (
  select * from public.cs_v_clientes where email like 'demo%@ejemplo.com'
),
casos(orden, caso, email, estado_esp, semaforo_esp) as (values
  ( 1, 'Onboarding pendiente demorado',          'demo01@ejemplo.com', 'onboarding',    'rojo'),
  ( 2, 'Onboarding en curso (en plazo)',         'demo02@ejemplo.com', 'onboarding',    'verde'),
  ( 3, 'Activo al día',                          'demo03@ejemplo.com', 'activo',        'verde'),
  ( 4, 'Activo al día',                          'demo04@ejemplo.com', 'activo',        'verde'),
  ( 5, 'Activo al día (acc. cliente en fecha)',  'demo05@ejemplo.com', 'activo',        'verde'),
  ( 6, 'Devolución vencida (fuera de SLA)',      'demo06@ejemplo.com', 'activo',        'rojo'),
  ( 7, 'Devolución pendiente dentro de SLA',     'demo07@ejemplo.com', 'activo',        'amarillo'),
  ( 8, 'Accionable BPF vencido',                 'demo08@ejemplo.com', 'activo',        'rojo'),
  ( 9, 'A 20 días de terminar sin renovación',   'demo09@ejemplo.com', 'activo',        'rojo'),
  (10, 'En renovación',                          'demo10@ejemplo.com', 'en_renovacion', 'amarillo'),
  (11, 'Renovado',                               'demo11@ejemplo.com', 'activo',        'verde'),
  (12, 'No renovado (sigue hasta vencer)',       'demo12@ejemplo.com', 'activo',        'verde'),
  (13, 'Finalizado (no renovó)',                 'demo13@ejemplo.com', 'finalizado',    'verde'),
  (14, 'Sin chequeo hace 10 días',               'demo14@ejemplo.com', 'activo',        'amarillo')
),
vivos as (
  select count(*) filter (where semaforo = 'rojo')     as rojo,
         count(*) filter (where semaforo = 'amarillo') as amarillo,
         count(*) filter (where semaforo = 'verde')    as verde
  from v where estado in ('onboarding', 'activo', 'en_renovacion')
)
select * from (
  select 0 as orden, 'RESUMEN' as tipo, 'Clientes vivos por semáforo' as caso, null::text as cliente,
         null::text as estado, null::text as semaforo,
         format('rojo=%s · amarillo=%s · verde=%s (esperado 4 · 3 · 6)', rojo, amarillo, verde) as detalle,
         (rojo, amarillo, verde) = (4::bigint, 3::bigint, 6::bigint) as ok
  from vivos

  union all
  select c.orden, 'CASO', c.caso, v.nombre, v.estado, v.semaforo,
         concat_ws(' | ', nullif(array_to_string(v.motivos_semaforo, ' | '), ''),
                   format('días restantes %s', v.dias_restantes)),
         coalesce(v.estado = c.estado_esp and v.semaforo = c.semaforo_esp, false)
  from casos c left join v on v.email = c.email

  union all
  select 20, 'CHEQUEO', 'Renovado: fecha_fin movida y renovaciones_count = 1', null, null, null,
         format('fecha_fin=%s · renovaciones_count=%s', fecha_fin, renovaciones_count),
         fecha_fin = public.cs_hoy() + 85 and renovaciones_count = 1
  from public.cs_clientes where email = 'demo11@ejemplo.com'

  union all
  select 21, 'CHEQUEO', 'Sin chequeo: dias_sin_chequeo = 10', null, null, null,
         format('dias_sin_chequeo=%s', dias_sin_chequeo), dias_sin_chequeo = 10
  from v where email = 'demo14@ejemplo.com'

  union all
  select 22, 'CHEQUEO', 'Onboarding: 1 call y 3 accionables de día 0 por cliente (sin duplicar)', null, null, null,
         string_agg(format('%s: calls=%s acc=%s', c.nombre,
                    (select count(*) from public.cs_calls x where x.cliente_id = c.id and x.tipo = 'onboarding'),
                    (select count(*) from public.cs_accionables x where x.cliente_id = c.id and x.origen = 'plantilla')),
                    ' · ' order by c.nombre),
         bool_and((select count(*) from public.cs_calls x where x.cliente_id = c.id and x.tipo = 'onboarding') = 1
              and (select count(*) from public.cs_accionables x where x.cliente_id = c.id and x.origen = 'plantilla') = 3)
  from public.cs_clientes c where c.email in ('demo01@ejemplo.com', 'demo02@ejemplo.com')

  union all
  select 23, 'CHEQUEO', 'Respuestas de satisfacción: 12, con 2 puntajes < 6', null, null, null,
         format('respuestas=%s · bajas=%s · promedio=%s', count(*), count(*) filter (where r.puntaje < 6),
                round(avg(r.puntaje), 2)),
         count(*) = 12 and count(*) filter (where r.puntaje < 6) = 2
  from public.cs_respuestas r
  join public.cs_formularios f on f.id = r.formulario_id and f.nombre = 'Satisfacción mensual (demo)'
  where r.puntaje is not null

  union all
  select 24, 'CHEQUEO', 'Devoluciones entregadas con Loom demo', null, null, null,
         format('entregadas=%s · pendientes/en proceso=%s',
                count(*) filter (where d.estado = 'entregada'), count(*) filter (where d.estado <> 'entregada')),
         bool_and(d.estado <> 'entregada' or d.loom_url like 'https://www.loom.com/share/demo-%')
  from public.cs_devoluciones d join public.cs_clientes c on c.id = d.cliente_id
  where c.email like 'demo%@ejemplo.com'

  union all
  select 25, 'CHEQUEO', 'Programas: 5, solo liam activo, plantilla de liam con 6 ítems', null, null, null,
         string_agg(format('%s%s', id, case when activo then '*' else '' end), ', ' order by id),
         count(*) = 5 and count(*) filter (where activo) = 1 and bool_or(id = 'liam' and activo)
           and (select jsonb_array_length(plantilla_accionables) from public.cs_programas where id = 'liam') = 6
  from public.cs_programas

  union all
  select 26, 'INFO', 'Filas con created_by null (auth.uid() es null en el SQL Editor)', null, null, null,
         format('clientes=%s de %s', count(*) filter (where created_by is null), count(*)), true
  from public.cs_clientes where email like 'demo%@ejemplo.com'
) t
order by orden;
