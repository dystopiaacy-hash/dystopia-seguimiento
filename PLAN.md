# PLAN: Dystopia Seguimiento (seguimiento de clientes por programa)

Este archivo es la especificación completa del proyecto. Está dividido en fases.
En cada sesión de Claude Code se trabaja UNA sola fase. Leé únicamente la
sección "REGLAS GENERALES" y la sección de la fase que se te indique.
No leas el resto del archivo salvo que la fase lo pida explícitamente.

====================================================================
REGLAS GENERALES (leer siempre)
====================================================================

CONTEXTO
- Soy Joaquín, trabajo en operaciones en una agencia de marketing (Dystopia).
- La agencia tiene 5 cuentas (clientes de la agencia): liam (Liam Wickham,
  Blueprint Financiero, "BPF"), agus (Agus Friedrichs), teo (Teo North),
  mauro (Mauro Escribano), lucas (Lucas Auletta).
- Cada cuenta vende un programa (mentoría o consultoría) a sus propios
  clientes finales.
- Esta app sirve para ver en tiempo real en qué punto está cada cliente final
  de cada programa: accionables, devoluciones de portafolio, calls, tiempo
  restante de programa, renovaciones, formularios y métricas.
- Se arranca SOLO con liam (BPF). Las otras 4 cuentas quedan creadas pero
  inactivas, y se configuran después usando liam como referencia.

VOCABULARIO (usarlo igual en código, SQL y UI)
- "Programa" = una cuenta de la agencia (liam, agus, etc.). Tabla cs_programas.
- "Cliente" = cliente final de un programa (un cliente de Liam). Tabla cs_clientes.
- "Equipo" o "BPF" = el equipo del programa (Liam y su gente).
- "Accionable BPF" = tarea que tiene que hacer el equipo del programa.
- "Accionable cliente" = tarea que tiene que hacer el cliente final.
- "Devolución" = feedback de portafolio entregado en un video de Loom.

YA EXISTE OTRA APP: DYSTOPIA (CRM DE CONTENIDO)
- Carpeta: C:\Users\Admin\Downloads\dystopia\dystopia
- Un solo index.html (~200KB), Vercel + Supabase + GitHub.
- Supabase: https://alxdjcdfpdayucassfub.supabase.co
- Tablas crm_* (crm_state, crm_clients, crm_members, crm_asignaciones,
  crm_revenue) y funciones SECURITY DEFINER es_fundador(), rol_actual(),
  tiene_acceso(text). Roles: fundador, cliente, editor.
- ESTA APP NUEVA USA EL MISMO PROYECTO DE SUPABASE (misma auth, mismos
  usuarios, mismas funciones de rol). Todas sus tablas y funciones llevan
  prefijo cs_ ("client success").
- PROHIBIDO modificar, alterar, borrar o recrear cualquier objeto crm_*,
  es_fundador, rol_actual o tiene_acceso. Solo se leen/usan.
- PROHIBIDO leer el index.html de Dystopia completo. Solo grep y lecturas
  parciales con offset/limit, y solo en la fase que lo pida.

PROYECTO NUEVO
- Carpeta: C:\Users\Admin\Downloads\dystopia-seguimiento
- Sin build step. HTML + CSS + JS con ES modules nativos, servidos estáticos.
- NO un solo archivo gigante: el index.html de Dystopia creció a 200KB y
  leerlo quema tokens. Acá cada archivo JS se mantiene por debajo de ~500
  líneas. Si uno crece más, se divide.
- Sistema operativo: Windows. Los comandos de terminal que me pases, en
  PowerShell.

REGLAS DE TRABAJO
1. Trabajá solo la fase indicada. Al terminarla, PARÁ y esperá mi OK.
2. Nunca ejecutes SQL. Todo cambio de base de datos va en un archivo
   numerado en /migraciones que corro yo en el SQL Editor de Supabase.
   Cada archivo SQL termina con una QUERY DE CONTROL que verifique el
   resultado (conteos, existencia de objetos, políticas creadas).
3. Todo SQL es idempotente cuando se pueda (create ... if not exists,
   create or replace, drop policy if exists antes de create policy).
4. Antes de cualquier migración que no sea puramente aditiva, pedime
   backup explícito y decime qué exportar.
5. Para leer archivos existentes: grep primero, después leé solo la zona
   con offset y limit. Nunca leas un archivo completo de más de 300 líneas.
6. Al terminar cada fase entregá:
   a) Lista de archivos creados/modificados.
   b) Decisiones que tomaste por tu cuenta (y por qué).
   c) Supuestos que hay que validar con la agencia.
   d) Qué quedó pendiente.
   e) Checklist corto de prueba para que yo verifique.
7. Si algo de este plan tiene un problema de diseño o un riesgo, decímelo
   ANTES de implementarlo, no después.
8. Nada de librerías nuevas salvo supabase-js (misma versión que Dystopia).
   Sin frameworks de CSS. Gráficos con el mismo método que use Dystopia.
9. Toda fecha "de negocio" (hoy, días restantes, vencimientos) se calcula
   en zona America/Argentina/Buenos_Aires, no en UTC.
10. Todo texto que venga de la base o de formularios públicos se escapa
    antes de insertarlo en el DOM (función esc() única). Nunca innerHTML
    con datos sin escapar. Los formularios públicos son input de extraños.

DATOS SENSIBLES (Ley 25.326)
- Los clientes de BPF son personas con datos financieros.
- NO se guardan montos, tenencias ni composición de portafolios en la base.
  El portafolio vive en el Loom y en la herramienta que ya use BPF. En la
  base solo va el link del Loom, el estado y notas operativas.
- Datos personales mínimos por cliente: nombre, email, teléfono. Nada más.
- Hasta que Supabase y Vercel estén en planes pagos a nombre de la agencia,
  la app se usa SOLO con datos demo (Fase 2 incluye seed y script de borrado).

====================================================================
FASE 0: INSPECCIÓN Y ESQUELETO
====================================================================

Objetivo: no romper nada de Dystopia y extraer su diseño.

0.1 Diseño de Dystopia (solo lectura, con grep):
- Ubicá con grep el bloque <style> de C:\Users\Admin\Downloads\dystopia\dystopia\index.html
  (líneas de inicio y fin). Leé SOLO ese bloque en tramos con offset/limit.
- Extraé a css/app.css del proyecto nuevo:
  - Variables :root (colores, radios, sombras, espaciados, tipografías).
  - Import de fuentes.
  - Estilos base: body, sidebar, header, tabs, cards, KPI cards, badges de
    estado, tablas/listados, botones, inputs, selects, modales, toasts,
    login, responsive.
- Grep en Dystopia cómo carga supabase-js (URL/versión) y cómo dibuja
  gráficos (SVG propio, canvas, librería). Anotalo en tu resumen.
- Grep la función de login y el gate de sesión para replicar el mismo
  comportamiento (signInWithPassword, pantalla de login, logout).
- Mantené exactamente la paleta. No cambies ni un hex. Si Dystopia usa
  colores por plataforma (Instagram índigo, TikTok turquesa, YouTube coral),
  no los necesitamos; sí necesitamos los colores de estado. Si no existen
  rojo/amarillo/verde de semáforo en la paleta, proponé 3 tonos coherentes
  con ella y marcalo como decisión tuya.

0.2 Esqueleto del proyecto nuevo:
```
dystopia-seguimiento/
  index.html            shell de la app (login + layout + <main>)
  form.html             página pública de formularios
  vercel.json           cleanUrls + headers de seguridad básicos
  .gitignore
  PLAN.md               este archivo
  css/app.css
  js/config.js          SUPABASE_URL y publishable key
  js/supabase.js        cliente único
  js/router.js          hash routing
  js/state.js           caché en memoria + suscripción realtime
  js/ui.js              esc(), formatos, badges, semáforo, modal, toast
  js/views/             una vista por archivo (se crean en fases siguientes)
  js/form-publico.js
  migraciones/
```
- vercel.json: cleanUrls true, headers X-Content-Type-Options nosniff,
  Referrer-Policy strict-origin-when-cross-origin, X-Frame-Options DENY
  (salvo form.html si más adelante se embebe; por ahora DENY en todo).

0.3 SQL de inspección (NO ejecutar, pasármelo para que lo corra yo):
Creá migraciones/000_inspeccion.sql con consultas que devuelvan:
- Definición completa y argumentos de es_fundador, rol_actual, tiene_acceso.
- Columnas de crm_clients, crm_members, crm_asignaciones.
- Filas de crm_clients (solo id y nombre).
- Valores posibles de rol en crm_members (select distinct).
- Si las extensiones pg_cron y pg_net están instaladas.
- Lista de tablas en public (para confirmar que no existe nada cs_).
- Versión de Postgres (para confirmar soporte de security_invoker en vistas).

PARÁ ACÁ. Mostrame: resumen del diseño extraído, cómo carga supabase y
gráficos Dystopia, árbol de archivos creado, y el SQL de inspección.
Esperá a que te pegue los resultados.

====================================================================
FASE 1: ESQUEMA DE BASE DE DATOS
====================================================================

Usá los resultados de la inspección para ajustar nombres reales de columnas
y firmas de funciones. Si algo no coincide con lo que asume este plan,
avisame antes de escribir el SQL.

Archivo: migraciones/001_esquema_cs.sql

1.1 Helpers (SECURITY DEFINER, set search_path = public, stable):
- cs_hoy() returns date: fecha actual en America/Argentina/Buenos_Aires.
- cs_puede_ver(p_programa text) returns boolean:
  es_fundador() OR (rol_actual() = 'cliente' AND tiene_acceso(p_programa)).
  Los editores de Dystopia NO ven nada de esta app.
- cs_puede_borrar() returns boolean: es_fundador().

1.2 Tablas (todas con RLS activada):

cs_programas
- id text PK (mismo id que crm_clients: liam, agus, teo, mauro, lucas)
- nombre text not null, marca text
- activo boolean default false
- duracion_default_dias int default 90
- aviso_renovacion_dias int default 30
- sla_devolucion_horas int default 72
- sla_onboarding_dias int default 3
- dias_sin_chequeo_alerta int default 7
- satisfaccion_umbral_bajo numeric default 6
- etapas jsonb default '["Onboarding","Diagnóstico","Armado de portafolio","Seguimiento","Renovación"]'
- plantilla_accionables jsonb default '[]'
  (array de {key, titulo, descripcion, responsable: 'bpf'|'cliente', dia_offset int, vence_en_dias int})
- created_at timestamptz default now()

cs_integraciones (SOLO fundador, ni lectura para cliente)
- programa_id text PK FK cs_programas
- discord_webhook_url text
- discord_activo boolean default false
- updated_at timestamptz

cs_clientes
- id uuid PK default gen_random_uuid()
- programa_id text not null FK
- nombre text not null, email text, telefono text
- fecha_inicio date not null
- fecha_fin date not null (default calculado por trigger: fecha_inicio + duracion_default_dias si viene null)
- estado text check in ('onboarding','activo','en_renovacion','finalizado','baja') default 'onboarding'
- etapa text
- responsable text (persona del equipo BPF que lo lleva, texto libre)
- plan text
- notas text
- token_publico uuid unique default gen_random_uuid()  (para links de formularios)
- ultimo_chequeo_at timestamptz
- renovaciones_count int default 0
- created_at, updated_at timestamptz, created_by uuid default auth.uid()

cs_accionables
- id uuid PK, programa_id text not null, cliente_id uuid FK on delete cascade
- responsable text check in ('bpf','cliente') not null
- titulo text not null, descripcion text
- estado text check in ('pendiente','en_proceso','completado') default 'pendiente'
- vence date, completado_at timestamptz
- origen text check in ('manual','plantilla','sistema') default 'manual'
- plantilla_key text
- unique (cliente_id, plantilla_key)  (evita duplicar accionables de plantilla)
- created_at, updated_at, created_by

cs_devoluciones
- id uuid PK, programa_id text, cliente_id uuid FK cascade
- titulo text not null (ej: "Revisión de portafolio mes 1")
- solicitada_at timestamptz default now()
- estado text check in ('pendiente','en_proceso','entregada') default 'pendiente'
- loom_url text check (loom_url is null or loom_url ~* '^https://(www\.)?loom\.com/')
- entregada_at timestamptz
- notas text
- created_at, updated_at, created_by
- Regla (trigger): no se puede pasar a 'entregada' sin loom_url. Al pasar a
  'entregada' se setea entregada_at = now(). Si vuelve a otro estado, se
  limpia entregada_at.

cs_calls
- id uuid PK, programa_id text, cliente_id uuid FK cascade
- tipo text check in ('onboarding','seguimiento','renovacion','otra')
- estado text check in ('pendiente_agendar','agendada','realizada','no_show','cancelada') default 'pendiente_agendar'
- fecha timestamptz, notas text
- created_at, updated_at

cs_renovaciones
- id uuid PK, programa_id text, cliente_id uuid FK cascade
- iniciada_at timestamptz default now()
- estado text check in ('en_proceso','renovado','no_renovado') default 'en_proceso'
- resultado_at timestamptz
- nueva_fecha_fin date (obligatoria si estado = 'renovado')
- motivo text
- Solo una renovación 'en_proceso' por cliente (índice único parcial).
- Triggers:
  - Insert en_proceso -> cliente.estado = 'en_renovacion'.
  - Pasa a renovado -> cliente.estado = 'activo', cliente.fecha_fin = nueva_fecha_fin,
    renovaciones_count + 1, resultado_at = now().
  - Pasa a no_renovado -> resultado_at = now(); cliente.estado vuelve a 'activo'
    hasta que venza fecha_fin (el cron lo pasa a 'finalizado').

cs_formularios
- id uuid PK, programa_id text
- nombre text not null
- tipo text check in ('onboarding','satisfaccion','checkin','devolucion','otro')
- campos jsonb not null default '[]'
  (array de {key, label, tipo: 'texto'|'parrafo'|'numero'|'escala_0_10'|'opcion'|'si_no',
   opciones: [], requerido: bool, es_metrica: bool})
  Como máximo un campo con es_metrica = true y debe ser escala_0_10.
- activo boolean default true
- token uuid unique default gen_random_uuid()
- created_at, updated_at

cs_respuestas
- id uuid PK, programa_id text, formulario_id uuid FK cascade
- cliente_id uuid FK set null (nullable)
- respuestas jsonb not null
- puntaje numeric (extraído del campo es_metrica, 0 a 10)
- created_at timestamptz default now()
- Sin políticas de insert para authenticated ni anon: se inserta SOLO vía RPC.
- authenticated puede leer según cs_puede_ver.

cs_chequeos
- id uuid PK, programa_id text, cliente_id uuid FK cascade
- usuario uuid default auth.uid(), nota text, created_at
- Trigger: actualiza cs_clientes.ultimo_chequeo_at.

cs_historial
- id bigserial PK, tabla text, registro_id uuid, programa_id text,
  campo text, valor_anterior text, valor_nuevo text,
  usuario uuid default auth.uid(), at timestamptz default now()
- Triggers AFTER UPDATE que registren cambios de 'estado' (y de fecha_fin en
  cs_clientes) en: cs_clientes, cs_accionables, cs_devoluciones, cs_calls,
  cs_renovaciones. Sirve para calcular días reales en cada estado (lección
  de Dystopia: no calcular días parados desde la fecha de creación).
- Solo lectura para usuarios (select con cs_puede_ver), sin insert/update/delete directo.

cs_alertas
- id uuid PK, programa_id text, cliente_id uuid FK cascade (nullable)
- tipo text check in ('renovacion_proxima','devolucion_vencida','onboarding_demorado',
  'accionable_bpf_vencido','sin_chequeo','satisfaccion_baja','programa_vencido')
- mensaje text
- clave_dedupe text unique  (ej: 'renovacion_proxima:<cliente_id>:<fecha_fin>')
- resuelta boolean default false, resuelta_at timestamptz
- notificada_discord_at timestamptz
- created_at timestamptz default now()

1.3 Triggers comunes:
- updated_at automático en todas las tablas que lo tengan.
- programa_id de tablas hijas: trigger BEFORE INSERT que lo copie desde
  cs_clientes si viene null, y que rechace si no coincide con el del cliente.
- Al insertar un cs_clientes:
  - Crear call de onboarding en 'pendiente_agendar'.
  - Aplicar plantilla_accionables del programa para ítems con dia_offset = 0.

1.4 RLS (patrón para todas las tablas cs_ con programa_id):
- select: cs_puede_ver(programa_id)
- insert: cs_puede_ver(programa_id)
- update: cs_puede_ver(programa_id) en using y with check
- delete: cs_puede_borrar()
- cs_programas: select con cs_puede_ver(id); insert/update/delete solo fundador.
- cs_integraciones: todo solo fundador.
- cs_historial y cs_respuestas: solo select.
- cs_alertas: select y update (para marcar resuelta) con cs_puede_ver; insert
  solo desde funciones SECURITY DEFINER.
- REVOKE de anon en todas las tablas cs_.

1.5 Vistas (con security_invoker = on para que respeten RLS; confirmar
versión de Postgres en la inspección):

cs_v_clientes: una fila por cliente con:
- todos los campos de cs_clientes
- dias_restantes (fecha_fin - cs_hoy()), dias_transcurridos, pct_programa (0 a 100)
- acc_bpf_pendientes, acc_bpf_vencidos, acc_cliente_pendientes, acc_cliente_vencidos
- dev_pendientes, dev_vencidas_sla (pendiente/en_proceso con solicitada_at + sla_devolucion_horas < now())
- onboarding_estado (estado de la call de onboarding más reciente)
- renovacion_estado (en_proceso / renovado / no_renovado / null)
- dias_sin_chequeo
- semaforo: 'rojo' | 'amarillo' | 'verde' con estas reglas:
  ROJO si cualquiera:
    - dev_vencidas_sla > 0
    - acc_bpf_vencidos > 0
    - onboarding pendiente_agendar y cs_hoy() - fecha_inicio > sla_onboarding_dias
    - dias_restantes <= aviso_renovacion_dias y sin renovación en_proceso ni renovado,
      y estado no en ('finalizado','baja')
  AMARILLO si cualquiera (y no es rojo):
    - dias_restantes <= aviso_renovacion_dias con renovación en_proceso
    - dias_sin_chequeo > dias_sin_chequeo_alerta
    - acc_cliente_vencidos > 0
    - dev_pendientes > 0 (dentro de SLA)
  VERDE en otro caso.
- motivos_semaforo text[] con el porqué (se muestra en la UI).

cs_v_kpis_programa: una fila por programa con:
- clientes_activos (estado en onboarding, activo, en_renovacion)
- onboarding_pendientes (calls onboarding en pendiente_agendar)
- acc_bpf_pendientes, acc_bpf_vencidos, acc_cliente_pendientes
- dev_pendientes, dev_entregadas, dev_total, pct_dev_pendientes, pct_dev_entregadas,
  dev_vencidas_sla
- por_vencer (dias_restantes entre 0 y aviso_renovacion_dias)
- en_renovacion
- tasa_renovacion = renovado / (renovado + no_renovado) histórico, null si 0
- satisfaccion_prom_90d (promedio puntaje últimos 90 días)
- nps_90d = % puntaje >= 9 menos % puntaje <= 6 (últimos 90 días), null si no hay datos
- respuestas_90d (n, para mostrar la base del cálculo)
- clientes_rojo, clientes_amarillo, clientes_verde
- sin_chequeo (dias_sin_chequeo > umbral)

cs_v_metricas_mensuales: por programa y mes: altas, renovados, no_renovados,
devoluciones entregadas, tiempo promedio de entrega de devolución en horas,
satisfacción promedio. Para gráficos de tendencia.

1.6 Realtime:
- Agregar todas las tablas cs_ (menos cs_integraciones) a la publicación
  supabase_realtime (idempotente: solo si no están ya).

1.7 Query de control al final del archivo:
- Conteo de tablas cs_ creadas (esperado: 12).
- Políticas por tabla cs_ (ninguna tabla cs_ sin políticas, salvo las
  intencionales).
- rowsecurity = true en todas las cs_.
- Conteo de filas de crm_clients y crm_members ANTES y DESPUÉS igual
  (poné el conteo previo en un comentario para que lo compare).
- Vistas creadas con security_invoker.

PARÁ ACÁ. Mostrame el SQL completo y un resumen de decisiones. Yo lo corro
y te paso el resultado de la query de control.

====================================================================
FASE 2: APP BASE (LOGIN, LAYOUT, PANEL GENERAL) + DATOS DEMO
====================================================================

2.1 migraciones/002_seed_demo.sql
- Insertar los 5 programas (liam activo = true, los otros 4 activo = false)
  con los nombres reales de las cuentas.
- Para liam: plantilla_accionables de ejemplo:
  - bpf, dia 0: "Agendar call de onboarding" (vence en 2 días)
  - bpf, dia 0: "Enviar accesos y bienvenida" (vence en 1 día)
  - cliente, dia 0: "Completar formulario de onboarding" (vence en 3 días)
  - cliente, dia 7: "Enviar portafolio actual para revisión" (vence en 5 días)
  - bpf, dia 30: "Enviar formulario de satisfacción mes 1" (vence en 3 días)
  - bpf, dia 60: "Enviar formulario de satisfacción mes 2" (vence en 3 días)
- 14 clientes DEMO en liam (nombres "Cliente Demo 01"..., emails
  demo01@ejemplo.com), repartidos para que se vean todos los casos:
  onboarding pendiente demorado, activos al día, con devolución vencida,
  con accionable BPF vencido, a 20 días de terminar sin renovación, en
  renovación, renovado, no renovado y finalizado, sin chequeo hace 10 días.
- Devoluciones demo con links https://www.loom.com/share/demo... en las
  entregadas.
- Respuestas de satisfacción demo con puntajes variados (incluir 2 bajos).
- Un formulario de onboarding y uno de satisfacción de ejemplo en liam.
- Marcá todo lo demo de forma identificable (email @ejemplo.com).
- migraciones/002b_borrar_demo.sql: borra SOLO los datos demo (por email
  @ejemplo.com y formularios demo), con query de control.

2.2 Login y sesión
- Mismo comportamiento y estética que el login de Dystopia.
- Tras login, cargar el rol: si el usuario no es fundador ni cliente con
  acceso a algún programa, mostrar "Sin acceso a esta app" y botón de salir.

2.3 Layout (replicando Dystopia)
- Sidebar: logo "DYSTOPIA" + subtítulo "Seguimiento", navegación:
  Panel general, y lista de programas con punto de estado (verde si activo,
  gris si inactivo). Un usuario rol cliente solo ve su/s programa/s y entra
  directo a él.
- Header con título de la vista, indicador "En vivo" (punto verde cuando la
  suscripción realtime está conectada, gris si cae), usuario y logout.

2.4 Router (hash)
- #/panel
- #/p/:programa  (dashboard del programa)
- #/p/:programa/clientes
- #/p/:programa/c/:clienteId
- #/p/:programa/accionables
- #/p/:programa/devoluciones
- #/p/:programa/calls
- #/p/:programa/renovaciones
- #/p/:programa/revision
- #/p/:programa/formularios
- #/p/:programa/metricas
- #/p/:programa/config  (solo fundador)

2.5 Vista Panel general (#/panel), solo fundador
- Fila de KPIs sumando todos los programas activos: clientes activos,
  clientes en rojo, devoluciones pendientes, por vencer, tasa de renovación
  global, satisfacción global.
- Una tarjeta por programa: nombre, activo/inactivo, clientes activos,
  conteo rojo/amarillo/verde (barra apilada fina), devoluciones pendientes
  en rojo si > 0, por vencer. Programas inactivos en gris con botón
  "Configurar" que lleva a config.

PARÁ ACÁ. Checklist de prueba: login, rol cliente vs fundador, panel con
datos demo, que un editor de Dystopia no vea nada.

====================================================================
FASE 3: PROGRAMA, CLIENTES Y FICHA DE CLIENTE
====================================================================

3.1 Dashboard del programa (#/p/:programa)
Orden de arriba hacia abajo (lo urgente primero):
a) Fila de KPI cards (número grande):
   - Clientes activos
   - Onboarding pendientes (rojo si hay demorados)
   - Accionables BPF pendientes (con "X vencidos" en rojo debajo)
   - Accionables cliente pendientes
   - Devoluciones pendientes: número Y porcentaje sobre el total, EN ROJO si
     > 0. Debajo, entregadas en número y porcentaje.
   - Por vencer (<= aviso_renovacion_dias)
   - Tasa de renovación %
   - Satisfacción promedio 90d y NPS (mostrar "n = X respuestas"; si n < 5
     mostrar "muestra chica" en gris)
   Cada KPI es clickeable y lleva a la lista filtrada correspondiente.
b) "Requiere atención": lista de clientes en rojo y amarillo con sus
   motivos_semaforo, ordenada rojo primero y por antigüedad del problema.
   Acción rápida por fila: ir a la ficha.
c) Alertas no resueltas (cs_alertas) con botón "Resolver".
d) Pestañas del programa: Clientes, Accionables, Devoluciones, Calls,
   Renovaciones, Revisión, Formularios, Métricas, Config.

3.2 Lista de clientes (#/p/:programa/clientes)
- Tabla: semáforo, nombre, estado, etapa, responsable, barra de progreso de
  programa con días restantes, acc BPF pend, acc cliente pend, dev pend,
  onboarding, último chequeo.
- Filtros: estado, semáforo, responsable, etapa, "por vencer". Búsqueda por
  nombre/email. Orden por columna. Números alineados a la derecha.
- Botón "Nuevo cliente": modal con nombre, email, teléfono, fecha inicio
  (default hoy), duración (default del programa, editable), responsable,
  plan, etapa inicial. Al crear, mostrar que se generaron la call de
  onboarding y los accionables de plantilla.

3.3 Ficha de cliente (#/p/:programa/c/:id)
- Header: nombre, semáforo con motivos, estado (editable), etapa (select
  con las etapas del programa), responsable, datos de contacto, botón
  "Registrar chequeo" (con nota opcional).
- Bloque tiempo: fecha inicio, fecha fin (editable), barra de progreso,
  días restantes grande. Si días restantes <= aviso: banner "Iniciar
  proceso de renovación" con botón que crea la renovación en_proceso.
- Accionables en dos columnas: "BPF" y "Cliente". Cada item: checkbox para
  completar inline, estado, vencimiento (rojo si vencido), editar/borrar
  (borrar solo fundador). Agregar accionable rápido en cada columna.
- Devoluciones: lista con título, estado, fecha solicitada, horas en espera
  (rojo si pasó SLA). Campo para pegar el link de Loom. Si el link es de
  Loom válido, mostrar embed (convertir /share/ID a /embed/ID en un iframe
  con sandbox adecuado y loading lazy). Botón "Marcar entregada" (exige
  link).
- Calls: lista con tipo, estado, fecha; cambiar estado inline.
- Renovaciones: historial y la en curso.
- Formularios respondidos: lista con fecha, formulario y puntaje; click
  abre la respuesta completa.
- Historial: timeline de cs_historial y cs_chequeos del cliente.
- Notas.

3.4 Vistas de lista transversales
- Accionables: todos los del programa, filtros por responsable, estado,
  vencidos, cliente. Completar inline.
- Devoluciones: tablero de 3 columnas (pendiente, en proceso, entregada)
  con contador y porcentaje arriba de cada columna; pendiente en rojo.
  Tarjeta con cliente, título, horas en espera, pegar Loom.
- Calls: filtros por tipo y estado; destacar onboarding pendiente_agendar.

3.5 Tiempo real
- state.js se suscribe a postgres_changes de las tablas cs_ filtradas por
  programa_id del programa abierto.
- Ante cualquier cambio: refetch con debounce de 500 ms de los KPIs y de la
  vista actual. No refetch completo de todo.
- Si la conexión realtime cae, indicador en gris y reintento; mientras
  tanto, refetch cada 60 segundos.

3.6 Principios de UI
- Estados legibles de un vistazo: badges con peso distinto según etapa.
- Rojo reservado para "hay que actuar ya". No usarlo decorativamente.
- Usable en notebook de 13" sin scroll horizontal y usable en celular
  (las tablas pasan a tarjetas en mobile).
- Estados vacíos con texto útil ("No hay devoluciones pendientes").
- Confirmación antes de borrar. Toast al guardar. Errores de Supabase
  mostrados en lenguaje claro, nunca silenciados.

PARÁ ACÁ.

====================================================================
FASE 4: RENOVACIONES, ALERTAS, REVISIÓN Y MÉTRICAS
====================================================================

4.1 Funciones SQL (migraciones/003_funciones_cs.sql), SECURITY DEFINER,
set search_path = public:
- cs_aplicar_plantillas(): para cada cliente activo, crea los accionables
  de plantilla cuyo dia_offset <= días transcurridos y que no existan
  (usa plantilla_key para no duplicar). vence = fecha_inicio + dia_offset
  + vence_en_dias.
- cs_cerrar_vencidos(): clientes con fecha_fin < cs_hoy(), estado no
  finalizado/baja y sin renovación renovada posterior -> estado 'finalizado'.
  Renovaciones en_proceso de esos clientes -> no_renovado con motivo
  "Vencido sin respuesta".
- cs_generar_alertas(): inserta en cs_alertas (con clave_dedupe, on conflict
  do nothing) para: renovacion_proxima, devolucion_vencida,
  onboarding_demorado, accionable_bpf_vencido, sin_chequeo,
  programa_vencido. Resuelve automáticamente las alertas cuya condición ya
  no se cumple.
- cs_correr_diario(): llama en orden a las tres anteriores. Callable por
  fundador desde la UI (botón "Correr chequeo ahora" en Config) y por cron.
- Query de control al final.

4.2 Renovaciones (#/p/:programa/renovaciones)
- Tres bloques: "Iniciar renovación" (por vencer sin proceso, en rojo),
  "En proceso" (con días restantes), "Cerradas" (renovado/no renovado).
- Cerrar renovación: modal con resultado; si renovado, nueva fecha fin
  (default fecha_fin actual + duración del programa) ; si no, motivo
  (select: precio, resultados, tiempo, otro + texto).
- Arriba: tasa de renovación histórica y del último trimestre.

4.3 Revisión (#/p/:programa/revision): el chequeo diario/semanal
- Modo guiado: recorre uno por uno los clientes en rojo, luego amarillo,
  luego los que no se chequean hace más de dias_sin_chequeo_alerta.
- Por cliente muestra: motivos, accionables abiertos, devoluciones
  pendientes, próxima acción sugerida. Botones: "Chequeado" (con nota),
  "Saltar", "Abrir ficha".
- Barra de progreso de la revisión del día.
- Decisión de cadencia: chequeo diario de rojos y amarillos (5 a 10 min),
  y chequeo semanal completo de todos los clientes los lunes. La vista
  tiene dos modos: "Diario" y "Semanal completo".

4.4 Métricas (#/p/:programa/metricas)
- Con cs_v_metricas_mensuales, selector de rango (últimos 3, 6, 12 meses).
- Gráficos (mismo método que Dystopia):
  - Clientes activos por mes (línea)
  - Altas vs renovados vs no renovados por mes (barras)
  - Satisfacción promedio por mes (línea, con n)
  - Tiempo promedio de entrega de devoluciones en horas (línea, con la
    línea del SLA marcada)
  - Distribución de semáforo actual (barra apilada)
  - Motivos de no renovación (barras)
- Botón exportar CSV de clientes con sus métricas (sin datos sensibles
  más allá de nombre y email).

4.5 Config (#/p/:programa/config), solo fundador
- Editar: duración default, aviso de renovación, SLAs, umbral de chequeo,
  umbral de satisfacción baja, etapas (lista ordenable), plantilla de
  accionables (tabla editable).
- Activar/desactivar programa.
- Integración Discord (webhook y activo), campo tipo password con botón
  "Probar" (se implementa en Fase 6).
- Botón "Correr chequeo ahora".

PARÁ ACÁ.

====================================================================
FASE 5: FORMULARIOS
====================================================================

5.1 SQL (migraciones/004_formularios_publicos.sql)
- cs_form_publico(p_form_token uuid, p_cliente_token uuid) returns jsonb,
  SECURITY DEFINER, grant execute a anon:
  devuelve {nombre_formulario, campos, nombre_cliente (solo primer nombre)}
  si el formulario está activo y el cliente existe, pertenece al mismo
  programa y no está en baja. Si no, error genérico ("Link inválido") sin
  revelar qué falló.
- cs_enviar_respuesta(p_form_token uuid, p_cliente_token uuid, p_respuestas jsonb)
  SECURITY DEFINER, grant execute a anon:
  - Mismas validaciones que arriba.
  - Tamaño máximo de p_respuestas: 20 KB.
  - Valida requeridos y tipos contra campos. Ignora keys que no existan.
  - Rate limit: máximo 5 respuestas por cliente por formulario por día.
  - Extrae puntaje del campo es_metrica.
  - Inserta en cs_respuestas.
  - Si puntaje <= satisfaccion_umbral_bajo, inserta alerta satisfaccion_baja.
  - Si el formulario es de tipo onboarding, marca como completado el
    accionable de cliente de plantilla "Completar formulario de onboarding"
    si existe.
- Query de control.

5.2 Constructor de formularios (#/p/:programa/formularios)
- Lista de formularios con tipo, activo, cantidad de respuestas.
- Editor simple: agregar/ordenar/borrar campos, tipo, opciones, requerido,
  marcar la métrica (máximo uno, escala 0 a 10).
- Por formulario: "Copiar link para un cliente" (select de cliente -> copia
  https://<dominio>/form?f=<token>&c=<token_publico>). También "Copiar
  links de todos los clientes activos" como texto (nombre: link) para
  mandar por WhatsApp.
- Vista de respuestas: tabla por formulario, filtro por cliente y fecha,
  export CSV.

5.3 Página pública (form.html + js/form-publico.js)
- Sin login. Usa la publishable key y SOLO las dos RPC.
- Misma estética de la app, pero limpia y mobile first.
- Saludo con primer nombre, campos, validación en el cliente, envío,
  pantalla de gracias. Errores claros.
- No carga ningún otro dato ni tabla.

5.4 Decisión de alcance: los formularios se envían a mano (link por
WhatsApp o mail). Integrar GoHighLevel (webhook de sus formularios a
Supabase) queda como pendiente futuro, no se hace ahora.

PARÁ ACÁ.

====================================================================
FASE 6: NOTIFICACIONES A DISCORD Y DEPLOY
====================================================================

6.1 SQL (migraciones/005_discord_cron.sql). Requiere pg_net y pg_cron
habilitadas (decime cómo habilitarlas desde el dashboard si la inspección
mostró que no están).
- cs_discord_post(p_programa text, p_contenido text): SECURITY DEFINER,
  lee el webhook de cs_integraciones, corta a 1900 caracteres, envía con
  net.http_post. Si discord_activo = false o no hay webhook, no hace nada.
  No ejecutable por anon ni authenticated (solo desde otras funciones).
- cs_probar_discord(p_programa text): solo fundador, manda mensaje de prueba.
- cs_digest_diario(): por cada programa activo con Discord activo, arma
  un mensaje:
    "Seguimiento BPF - <fecha>
     Activos: X | Rojo: X | Amarillo: X
     Devoluciones pendientes: X (X%) | Vencidas SLA: X
     Onboarding pendientes: X
     Por vencer (30d): X | Renovaciones en proceso: X
     Nuevas alertas:
     - <cliente>: <motivo>  (máximo 10, "y X más")"
  y marca notificada_discord_at en las alertas incluidas.
- cs_resumen_semanal(): lunes, con tasa de renovación, satisfacción 90d y
  NPS, devoluciones entregadas en la semana y tiempo promedio de entrega.
- Notificación inmediata: trigger en cs_alertas AFTER INSERT para tipo
  satisfaccion_baja -> cs_discord_post al momento.
- pg_cron (horarios en UTC, ART = UTC-3):
  - cs_correr_diario() + cs_digest_diario(): todos los días 12:00 UTC (9:00 ART)
  - cs_resumen_semanal(): lunes 12:10 UTC
  Con cron.schedule idempotente (unschedule si existe antes de crear).
- Query de control: jobs de cron listados.
- Decisión: un canal de Discord nuevo por programa ("seguimiento-bpf"),
  separado de los canales de pagos y agendas que ya existen, porque el
  cliente de la agencia está en esos canales y no todo el seguimiento
  interno tiene que verlo. VALIDAR con la agencia.

6.2 Deploy
- Comandos PowerShell para: git init, primer commit, crear repo privado en
  GitHub (instrucciones para hacerlo desde la web), push.
- Pasos para crear el proyecto en Vercel importando el repo (Framework:
  Other, sin build command, output = raíz).
- Recordatorio: Vercel Hobby prohíbe uso comercial y Supabase free no tiene
  backups. Antes de cargar clientes reales de BPF: planes pagos a nombre de
  la agencia y correr 002b_borrar_demo.sql.

PARÁ ACÁ. Checklist final de prueba end to end: crear cliente, ver
accionables generados, completar, pegar Loom, entregar devolución, responder
formulario público con puntaje bajo, ver alerta y mensaje en Discord, iniciar
y cerrar renovación, ver métricas actualizadas en vivo en otra pestaña.

====================================================================
FASE 7 (FUTURA, NO EJECUTAR HASTA QUE SE PIDA): OTROS PROGRAMAS
====================================================================
- Cada programa nuevo (agus, teo, mauro, lucas) se habilita desde Config:
  duración, etapas, SLAs, plantilla de accionables y formularios propios,
  usando liam como referencia.
- Si un programa necesita algo que no entra en el modelo (por ejemplo,
  mauro y lucas no tienen "portafolios"), evaluar si "devoluciones" se
  renombra por programa (campo etiqueta_devolucion en cs_programas) antes
  de crear tablas nuevas.
