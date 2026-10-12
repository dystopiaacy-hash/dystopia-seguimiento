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
- Numeración de migraciones: el número de cada migración lo asigna el jefe. No elijas números por tu cuenta: si necesitás una migración y no te dieron número, frená y pedilo en el resumen.
- Dato histórico: la numeración es compartida entre las 4 apps. Última usada en todo el sistema al 12/10/2026: **074**.

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
0000. 12/10/2026, tarea "unificar nav-areas.js": `AREAS` con los roles definidos por el jefe (marketing: fundador, cliente, editor, contenido · ventas: fundador, cliente, closer, setter, ventas, finanzas · producto: fundador, cliente, producto · finanzas: fundador, cliente, closer, setter, finanzas, ventas); cabecera reducida a una línea. Solo cambió `js/nav-areas.js`; sin migración.
   - Pantalla "Sin acceso" de Producto (`sesion.js`/`app.js`): no usa la lista de roles; entra `fundador` o quien tenga fila en `cs_accesos`. Coherente en la práctica (producto/cliente con cs_accesos), pero no es el mismo criterio que `AREAS`.
000. 12/10/2026, segunda tarea "generar 080 y convivencia de roles" (SQL y navegador SIN PROBAR; el generador sí corrió con `npm run`):
   - `scripts/generar-importacion-liam.mjs` ahora lee el xlsx directo (`scripts/xlsx-leer.mjs`, sin dependencias; sin argumentos usa el xlsx de `jefe\insumos\liam-septiembre`).
     `package.json` nuevo (solo scripts, sin dependencias): `npm run liam:inspeccionar` y `npm run liam:generar -- [archivo] [--hoy AAAA-MM-DD] [--hoja nombre]`.
   - Generado `datos/080-actualizar-liam-2026-10-12.sql` (en .gitignore): 179 filas, 178 únicas. Estimado contra el CSV del 29/09: actualiza 130, crea 48, 3 en la app y no en la planilla.
     No hay "+60" ni "!" ni COMUNIDAD en este xlsx. 1 fila con días "a" (fila 59, Churn): conserva la fecha actual.
     La única casilla nueva es "¿Lo saqué de la App?" (x_saque_app, 2 marcados). "Se unió a la School" no existe como columna en el xlsx.
   - 079 ya NO escribe en `crm_members` (la 075 de Finanzas da de alta los 6 usuarios con rol de área). Controles 04 y 04b nuevos: rol de área de cada mail y que ventas/finanzas/contenido no tengan fila en cs_accesos.
   - `js/nav-areas.js`: roles nuevos (contenido, ventas, producto, finanzas) en cada área; se mantienen editor/closer/setter. Replicar igual en las otras 3 apps.
   - Verificado por lectura: el front y las policies solo usan `rol === 'fundador'`; cualquier otro valor entra por cs_accesos. Ninguna policy o función abre acceso por `rol` o `crm_asignaciones`.
00. 12/10/2026, tarea "Liam listo para testear" (SIN PROBAR: el agente no pudo ejecutar nada, ni SQL, ni node, ni el navegador):
   - `migraciones/079-producto-accesos-checks-corte.sql`: tabla `cs_accesos` (usuario, programa, nivel lectura|edicion); `cs_puede_ver` pasa a leerla;
     `cs_puede_editar` nueva y todas las políticas de insert/update de cs_* la usan; parchea `cs_crear_cliente_desde_pago` y `cs_descartar_alta`;
     alta por mail (fundador@agencia = fundador en crm_members, cliente@liam = lectura, producto@liam = edicion; ventas/finanzas/contenido sin acceso);
     columnas casilla `x_unio_school` y `x_saque_app` en el Maestro de liam; `maestro_cortado_en` de liam = ahora.
   - JS: `sesion.js` (acceso por cs_accesos, `soloLectura()`), `solo-lectura.js` (bloquea insert/update/delete/rpc de escritura en el cliente), `app.js`, `css/layout.css`.
   - `scripts/generar-importacion-liam.mjs`: CSV exportado del xlsx -> `datos/080-actualizar-liam-<fecha>.sql` (simulacro por defecto, aplicar con 'si').
   - Por qué desaparecieron los checks: 040 convirtió las casillas de la planilla en accionables de cierre o en texto de nota_csm, y el Maestro solo muestra el contador "Acc. pend.".
     Referidos y FUP son accionables de plantilla desde 068; "Se unió a la School" nunca existió como columna en la app.
   - Producto no tiene sync con Sheets: "apagar la sync" es la marca `maestro_cortado_en`.
0. Regla de numeración de migraciones reemplazada: ahora el número lo asigna el jefe (sin cambios de código ni migraciones).
1. 071 + UI: Maestro con columnas configurables (renombrar, mover, ocultar y agregar; solo fundador). Columnas grises editables y filtro Estado. Probado logueado.
2. 070 + UI: "Clientes nuevos" en Hoy, desde las ventas de Finanzas (`cs_altas_pendientes`, sin montos). Liam tenía 1 pendiente, del 10/09: probablemente una fila de prueba.
3. 069 + UI: pantalla "Hoy" (`cs_cola_hoy` en vivo) y `cs_registrar_contacto`, que mueve el pipeline de resell en un paso.
4. 068: testimonio "coordinado", motivo de pausa, `maestro_cortado_en`, avisos de liam 21/10, referidos y FUP 1-3 en la plantilla (236 históricos).
5. FASE0-PRODUCTO.md y PLAN-PRODUCTO.md.
6. Antes de este chat: 036-039, la importación de 133 clientes de liam (040) y 417 accionables marcados como históricos.

## Pendientes (por prioridad)
00. Copiar el `js/nav-areas.js` unificado idéntico a Marketing, Ventas y Finanzas (el jefe decide); confirmar si el acceso a Producto debe seguir por `cs_accesos` y no por rol.
0. **Liam hoy (12/10):** orden: 075 (Finanzas) -> 079 -> 080 simulacro -> 080 con aplicar = 'si' -> probar con cada usuario -> push.
   Ya no hace falta exportar CSV: `npm run liam:generar` lee el xlsx. Si el xlsx cambia, volver a generar (el archivo lleva la fecha en el nombre).
   Decisiones: cómo se lee un "+60" (hoy no aparece en el xlsx; el generador lo informa y conserva la fecha actual);
   las 48 altas "nuevas" de la 080 pueden coincidir con "Clientes nuevos" de Hoy (070): revisar que no se dupliquen;
   si Skool/WPP/referidos/FUP deben verse también como casilla (hoy son accionables); mecanismo de accesos común con las otras 3 apps (cs_accesos es propio de Producto).
1. **Respuestas de la agencia.** (Contestadas el 08/10, ver `jefe\insumos\liam-septiembre\respuestas-nacho.md`: DCAC no puede tener alumnos de Mauro (error a revisar), "!" y COMUNIDAD, días a mano, agus ya no vende 1 mes/45 días pero se respeta, hoja del form de agus y corte de liam. Sin cerrar: mails de CSM y pasos de onboarding.) La reunión fue el 03/10; no sé qué respondieron (verificar con Joaquín). Preguntas:
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
- Sin pendientes nuevos por el cambio de regla de numeración (no existe CLAUDE.md en el repo).
- Decisiones de Joaquín: fecha de corte de cada cliente y quién avisa al CSM.

## Cuidado con
- **Choque de numeración:** 072, 073 y 074 existen DOS veces, en `dystopia\dystopia\migraciones` (Marketing) y en `dystopia-finanzas\migraciones` (Finanzas/Ventas). Ya corridos; no se renumeran.
- Producto NUNCA escribe caja: la renovación guarda solo el tipo (`resell_producto`). Los pagos van por Finanzas. Para enlazar con un pago, usar `fin_pagos.clave`, NUNCA `fin_pagos.id` (cambia cada 15 min con la sync).
- Columnas del Maestro: la clave interna de las 21 del sistema no cambia, renombrar solo cambia la etiqueta.
  Las calculadas (Acc./Dev. pend., Último seguimiento, Avance, Próximo contacto, Renov., Compró) NO se editan a mano, porque romperían Métricas.
- Las del sistema sin orden guardado valen posición x 10. Sin esto, una columna nueva aparece antes de "Cliente" (bug ya arreglado).
- Agregar ítems a una plantilla de accionables genera vencidos para todos los clientes al día siguiente. Siempre insertar los vencidos como "Histórico" en la misma migración (como la 068).
- A la agencia le gusta y NO hay que tocar: métricas de renovación y satisfacción, devoluciones de Loom, accionables y días restantes.
- Las alertas (`cs_alertas`) se recalculan solo a las 9:00. La pantalla "Hoy" es en vivo.
- Un `delete` en el SQL Editor muestra "No rows returned" aunque haya borrado. Verificar con un `count`.
- Roles: fundador = Joaquín, Nacho y Valen (`crm_members`). Las funciones `security definer` chequean `cs_puede_ver` o `es_fundador` adentro.
