# ESTADO-APP · Dystopia Producto (Seguimiento)

<!-- Sección del chat "dystopia producto" (reestructuración de Producto). Actualizado 12/10/2026. -->

## Identidad
- Dystopia Producto (antes "Seguimiento"): app de la agencia Dystopia para que el CSM siga a los alumnos de cada cliente.
  Cubre maestro de clientes, avisos de renovación, pipeline de resell, seguimientos, accionables, Loom y onboarding/offboarding.
- Carpeta del código: `C:\Users\Admin\Downloads\dystopia-seguimiento` (repo github.com/dystopiaacy-hash/dystopia-seguimiento, rama master).
- Stack: vanilla JS con ES modules, sin build. Deploy automático en Vercel al hacer push a master.
- Supabase: proyecto `alxdjcdfpdayucassfub` (plan Pro), compartido con Marketing (crm_*), Ventas y Finanzas (fin_*). Prefijo de Producto: `cs_`.
- Clientes (programas): liam (único activo con datos reales: 133 clientes), teo, agus y lucas sin cargar. Mauro y Julia (B4) quedan AFUERA.

## Cómo trabajamos
- Claude nunca ejecuta SQL. Escribe migraciones numeradas que Joaquín corre a mano en el SQL Editor de Supabase, completas y en una sola ejecución.
- Cada migración: begin/commit, prueba de humo que se revierte sola y controles comentados al final, que se corren de a uno.
  Se prueba DOS veces contra un Postgres 16 local con el esquema real (001 a 039 + stubs de auth, cron, net y crm_*).
- Si toca tablas que lee la app o el cron: lock de todas juntas al principio y `set local lock_timeout`. Ya hubo un deadlock por no hacerlo.
  Correr evitando los minutos :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
- Código: lo escribe Claude Code. Grep primero, nunca leer archivos enteros, JS < 500 líneas y CSS < 300 por archivo.
  Sin commit ni push hasta que Joaquín pruebe. Nunca alert ni confirm del navegador: las confirmaciones van en la pantalla.
- Prueba en navegador: `npx.cmd serve . -l 3077` y entrar a `http://localhost:3077/#/p/liam/...`, logueado como fundador.
  Para probar se usan datos de prueba que después se borran. Nunca se modifican datos reales de clientes.
- Windows/PowerShell, comandos listos para copiar con el `cd`. Joaquín: bullets, sin em-dashes, tratarlo de vos, cuestionar con datos.
- `datos/` (CSV de clientes y 040-importar-liam.sql) tiene datos personales y está en .gitignore. No copiar a ningún lado.
- Discord: solo conteos, nunca nombres de alumnos.
- Migraciones de Producto en `migraciones/` de este repo. Última de Producto: **071-producto-columnas-maestro.sql** (corrida y verificada).
- Numeración COMPARTIDA entre las 4 apps. Última usada en todo el sistema: **074**, próxima **075** (verificar antes en las 3 carpetas de migraciones).

## Mapa del código
- `js/views/programa.js`: router de pestañas del programa (`#/p/:programa/<sub>`).
- `js/views/hoy.js` y `hoy-contacto.js`, `hoy-altas.js`: pantalla "Hoy" (cola del CSM), panel de contacto y "Clientes nuevos".
- `js/views/maestro.js`, `maestro-celdas.js`, `maestro-ciclo.js`: grilla Maestro editable.
- `js/views/maestro-columnas.js`, `maestro-panel.js`, `maestro-acciones.js`: columnas configurables (071) y clic en calculadas.
- `js/datos.js` (≈485 líneas, al tope), `js/datos-hoy.js`, `js/datos-columnas.js`: acceso a Supabase.
- `js/views/ficha*.js`: ficha del cliente (cabecera, ciclo, calls, seguimientos, historial).
- `migraciones/`: 001-004 (esquema, funciones, formularios), 036-039, 068-071.
- `FASE0-PRODUCTO.md` (relevamiento de planillas) y `PLAN-PRODUCTO.md` (plan por fases): leerlos antes de seguir.

## Qué hicimos últimamente
1. 071 + UI: Maestro con columnas configurables (renombrar, mover, ocultar y agregar; solo fundador). Columnas grises editables y filtro Estado. Probado logueado.
2. 070 + UI: "Clientes nuevos" en Hoy, desde las ventas de Finanzas (`cs_altas_pendientes`, sin montos). Liam tenía 1 pendiente, del 10/09: probablemente una fila de prueba.
3. 069 + UI: pantalla "Hoy" (`cs_cola_hoy` en vivo) y `cs_registrar_contacto`, que mueve el pipeline de resell en un paso.
4. 068: testimonio "coordinado", motivo de pausa, `maestro_cortado_en`, avisos de liam 21/10, referidos y FUP 1-3 en la plantilla (236 históricos).
5. FASE0-PRODUCTO.md y PLAN-PRODUCTO.md.
6. Antes de este chat: 036-039, la importación de 133 clientes de liam (040) y 417 accionables marcados como históricos.

## Pendientes (por prioridad)
1. **Respuestas de la agencia.** La reunión fue el 03/10; no sé qué respondieron (verificar con Joaquín). Preguntas:
   - A1: DCAC (agus) es una copia del archivo de Academia Apple, con 303 alumnos de Mauro mezclados. ¿Se excluyen?
   - A2: ¿qué significa "!" en ESTADO? ¿COMUNIDAD es producto o estado?
   - A3: días restantes cargados a mano en BPF. ¿Se respetan o se recalculan?
   - A4: ¿agus sigue vendiendo "1 mes", "45 días" y Skool (sin vencimiento)?
   - A5: mails de los CSM, editores y closers para los accesos.
   - A6: hoja de respuestas del form de onboarding de agus, borrada.
   - A7: pasos de onboarding antes de dar Discord y Skool.
   - A8: webhook de Discord.
2. **Fase 7: teo, agus y lucas** (depende de A1-A5). Por cada cliente:
   - productos (teo 120 d; agus 90/30/45 y Skool sin vencimiento; lucas 90), plantilla de accionables, avisos (teo 21/10, agus 21/7);
   - "Sacar de Discord" en el offboarding de teo;
   - importación generada en `datos/` como la 040.
   Falta permitir productos sin vencimiento (hoy `duracion_dias > 0` y `fecha_fin not null`).
3. **Fase 2: liam al día y corte.** El CSM siguió cargando en el Sheet después del 29/09.
   Joaquín exporta el CSV a `datos/liam-clientes-<fecha>.csv`, Claude Code genera la importación de diferencias,
   se marca `cs_programas.maestro_cortado_en` y alguien le avisa al CSM. Joaquín pidió NO cortar hasta revisar con la agencia.
4. **Fase 6: onboarding** con link único por cliente: checklist, encuesta de marketing en formularios de la app (004) y Discord/Skool al completar. Depende de A7.
5. **Fase 4: ficha de un vistazo** (barra de tiempo y línea de contactos). Sin dependencias.
6. **Fase 8: vista de cobranza** de solo lectura sobre `fin_cuotas` (solo liam tiene datos).
7. Bajar `resell_gracia_dias` de liam de 200 a 30 cuando se cierren los 19 pipelines abiertos importados.
8. Partir `js/datos.js` antes de sumarle código (está en ≈485 de 500 líneas).
- Bugs conocidos: ninguno abierto. Sin probar en navegador: arrastrar y soltar del panel de Columnas y el doble clic en el encabezado.
- Decisiones de Joaquín: fecha de corte de cada cliente y quién avisa al CSM.

## Cuidado con
- **Choque de numeración:** 072, 073 y 074 existen DOS veces, en `dystopia\dystopia\migraciones` (Marketing) y en `dystopia-finanzas\migraciones` (Finanzas/Ventas). Revisar las tres carpetas antes de numerar.
- Producto NUNCA escribe caja: la renovación guarda solo el tipo (`resell_producto`). Los pagos van por Finanzas. Para enlazar con un pago, usar `fin_pagos.clave`, NUNCA `fin_pagos.id` (cambia cada 15 min con la sync).
- Columnas del Maestro: la clave interna de las 21 del sistema no cambia, renombrar solo cambia la etiqueta.
  Las calculadas (Acc./Dev. pend., Último seguimiento, Avance, Próximo contacto, Renov., Compró) NO se editan a mano, porque romperían Métricas.
- Las del sistema sin orden guardado valen posición x 10. Sin esto, una columna nueva aparece antes de "Cliente" (bug ya arreglado).
- Agregar ítems a una plantilla de accionables genera vencidos para todos los clientes al día siguiente. Siempre insertar los vencidos como "Histórico" en la misma migración (como la 068).
- A la agencia le gusta y NO hay que tocar: métricas de renovación y satisfacción, devoluciones de Loom, accionables y días restantes.
- Las alertas (`cs_alertas`) se recalculan solo a las 9:00. La pantalla "Hoy" es en vivo.
- Un `delete` en el SQL Editor muestra "No rows returned" aunque haya borrado. Verificar con un `count`.
- Roles: fundador = Joaquín, Nacho y Valen (`crm_members`). Las funciones `security definer` chequean `cs_puede_ver` o `es_fundador` adentro.
