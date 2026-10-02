# PLAN · PRODUCTO (Seguimiento)

Base: FASE0-PRODUCTO.md (02/10). Decisiones D1 a D9 aprobadas como se
recomendaron. Una fase por sesión de Claude Code, con /clear entre fases.

Reglas de siempre:
- Claude nunca ejecuta SQL. Cada migración va probada dos veces contra un
  Postgres local con el esquema real, con controles al final (de a uno) y
  smoke test que se revierte solo.
- Si toca tablas que lee el cron o la app: `begin`, lock de todas las
  tablas juntas al principio y `lock_timeout`. Evitar los minutos :00,
  :15, :30 y :45.
- Código: grep primero, nunca archivos enteros, JS < 500 líneas y CSS < 300
  por archivo. Probado en el mock antes del commit. Sin push hasta que
  Joaquín pruebe.
- datos/ no sale de la máquina de Joaquín: la importación la genera Claude
  Code ahí.
- Discord: solo conteos.

---

## Fase 1 · Ajustes de esquema (068) · no necesita a la agencia

- Días de aviso por **producto**, con el programa como valor por defecto.
  liam pasa a 21 y 10.
- `cs_productos.duracion_dias` puede ser null: producto sin vencimiento
  (Skool de agus). Sin fecha de fin, no genera avisos ni renovación.
- Testimonio suma `coordinado`.
- Pausa con motivo.
- Offboarding: ítem "Sacar de Discord" disponible para las plantillas.
- Catálogo de alias para importar: texto crudo de la planilla → valor de
  la app (producto, estado de renovación, testimonio). Mismo patrón que
  `fin_catalogo_alias` (064).
- `cs_programas.maestro_cortado_en`: marca desde cuándo el CSM carga solo
  en la app. Se muestra en Config.
- Lo que dependa de la consulta de plantilla de liam (FUP y referidos):
  se suma acá si falta.

## Fase 2 · Liam al día y corte (069) · necesita a Joaquín

- Joaquín exporta el maestro BPF actual a `datos/` (gitignored).
- Claude Code genera `datos/069-diferencias-liam.sql` en su máquina:
  solo lo que cambió desde el 29/09 (clientes nuevos, estados, avisos,
  testimonio, contexto como seguimiento).
- Se corre, se controla y ese mismo día se marca el corte de liam. Alguien
  le avisa al CSM: "desde hoy, en la app".

## Fase 3 · Pantalla "Hoy" (070 + UI)

- RPC `cs_cola_hoy(programa)`: avisos que vencen, seguimientos con fecha
  cumplida, renovaciones sin contacto, onboarding y offboarding
  pendientes, ordenados por urgencia.
- Tarjetas con Hecho, Registrar contacto y Reprogramar.
- Panel lateral de contacto: chips de canal y resultado. El resultado
  mueve el pipeline de resell. Próximo contacto con +3, +7 y +14.
- Atajos J, K, C y H.
- Se prueba con liam (datos reales) antes de sumar clientes.

## Fase 4 · Ficha de un vistazo (UI)

- Barra de tiempo del programa (inicio, avisos, pausas, fin).
- Línea de tiempo de contactos y checklists con progreso.
- No toca métricas, Loom, accionables ni días restantes: se reordena, no
  se reemplaza.

## Fase 5 · Alta desde Finanzas (071) · depende de los catálogos de 064

- Vista: pagos de categoría venta nueva sin cliente de Producto asociado.
- Aparecen en "Hoy" como "cliente nuevo para dar de alta" con los datos del
  pago. Se elige el producto y se crea.
- `cs_clientes.pago_clave` apunta a `fin_pagos.clave` (062). Nunca a
  `fin_pagos.id`.
- Producto no escribe caja.

## Fase 6 · Onboarding (072) · necesita A7

- Checklist de pasos por programa, link único por cliente.
- Encuesta de marketing como formulario de la app (004), con las preguntas
  del Google Form de cada cliente.
- Discord y Skool se marcan como entregados recién con todo completo.
- Respuestas exportables para el análisis de Valentín.

## Fase 7 · teo, agus y lucas (073 en adelante) · necesita A1 a A5

- Por cliente: programa, productos, avisos, plantilla de accionables y
  offboarding.
- Importación como la 040, generada en datos/. agus sin las 303 filas de
  Academia Apple. lucas desde la lista de alumnos, sin historia.
- Accesos de los CSM (crm_members).
- Corte por cliente, con aviso al CSM.

## Fase 8 · Cobranza de cuotas (solo lectura)

- Vista sobre `fin_cuotas` en la ficha de liam y en "Hoy" (cuota vencida).
- Sin escribir: el cobro lo carga Finanzas.

## Pendientes que no son fases

- Bajar `resell_gracia_dias` de liam de 200 a 30 cuando el CSM cierre los
  19 pipelines abiertos.
- Webhook de Discord de la agencia (A8).
