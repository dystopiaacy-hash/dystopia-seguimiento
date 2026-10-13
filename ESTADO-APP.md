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
- Dato histórico: la numeración es compartida entre las 4 apps. Última usada en todo el sistema al 12/10/2026: **074**. Producto tiene asignada la **093** (onboarding por link, ya en producción), la **096** (cambios de la reunión con Nacho, ya en producción) y la **097** (ajustes tras probar la 096, sin correr).

## Mapa del código
- `js/views/programa.js`: router de pestañas del programa (`#/p/:programa/<sub>`).
- `js/views/hoy.js` y `hoy-contacto.js`, `hoy-altas.js`: pantalla "Hoy" (cola del CSM), panel de contacto y "Clientes nuevos".
- `js/views/maestro.js`, `maestro-celdas.js`, `maestro-ciclo.js`: grilla Maestro editable.
- `js/views/maestro-columnas.js`, `maestro-panel.js`, `maestro-acciones.js`: columnas configurables (071) y clic en calculadas.
- `js/views/seleccion-masiva.js`: selección múltiple, edición masiva y borrado masivo (Clientes y Maestro).
- `js/datos.js` (≈485 líneas, al tope), `js/datos-hoy.js`, `js/datos-columnas.js`: acceso a Supabase.
- `js/views/ficha*.js`: ficha del cliente (cabecera, ciclo, calls, seguimientos, historial, llamadas y recursos de la 102).
- `js/datos-llamadas.js`, `js/views/llamada-semaforo.js`, `js/views/hoy-llamadas.js`: llamadas, accionables por llamada, recursos y semáforo de última llamada (102).
- `migraciones/`: 001-004 (esquema, funciones, formularios), 036-039, 068-071.
- `FASE0-PRODUCTO.md` (relevamiento de planillas) y `PLAN-PRODUCTO.md` (plan por fases): leerlos antes de seguir.

## Qué hicimos últimamente
0000000000000000000. 13/10/2026, tarea "accionables por llamada, semáforo de última llamada y recursos por alumno" (SQL, JS y navegador SIN PROBAR: el agente no pudo correr SQL, node ni navegador, `node --check` quedó sin correr; migración 102 asignada por el jefe, NO corrida):
   - Relevamiento (reutilizado, no duplicado): `cs_calls` (calls de onboarding/seguimiento/renovación con estado y fecha), `cs_seguimientos` (contactos con canal, resumen, etapa, avance y `proximo_contacto`; su último mueve `ultimo_chequeo_at` y `dias_sin_chequeo`), `cs_accionables` (plantilla del programa con vencimiento y responsable BPF/cliente; alimenta "Acc. pend." y métricas, NO se tocó), el Maestro (`proxima_accion`, `nota_csm`, "Último seguimiento"), el semáforo general de `cs_v_clientes` (alertas, otra cosa) y la pantalla Hoy (`cs_cola_hoy`). No existía: llamadas con título por alumno, accionables agrupados por llamada con subtareas y quién/cuándo, recursos por alumno, ni semáforo por días desde la última llamada.
   - `migraciones/102-producto-llamadas-accionables-recursos.sql`: tablas `cs_llamadas`, `cs_llamada_accionables` (padre_id = un nivel de subtareas; `hecho_at`, `hecho_por`, `hecho_por_nombre` los escribe un trigger desde `auth.uid()`) y `cs_llamada_recursos` (tipo doc/sheet/slides/drive/youtube/loom/otro, solo http(s), llamada opcional que queda en null si se borra la llamada). RLS como la 079: ver `cs_puede_ver`, crear/editar `cs_puede_editar`, borrar `cs_puede_borrar()` (solo fundador). Vista `cs_v_ultima_llamada` (security_invoker) = la más reciente entre `cs_llamadas`, `cs_calls` realizadas y `cs_seguimientos` con canal call o reunion. Suma `'ultima_llamada'` a `cs_maestro_claves_sistema()` (lista de la 093 + una; respaldo en `cs_bak_102_funciones`). No toca `cs_v_clientes`, `cs_v_maestro`, cron ni datos existentes. Controles C1 a C7 (C7 = humo que se revierte solo) y vuelta atrás comentados al final.
   - JS nuevo: `js/datos-llamadas.js` (lecturas, altas en bloque, `detectarRecurso` por dominio, `parsearAccionables`, `parsearLinks`), `views/ficha-llamadas.js` (sección "Accionables por llamada": avance "N de M" con barra, pendientes por llamada de la más nueva a la más vieja, completados plegados con quién y cuándo, "Nueva llamada" con accionables y links pegados), `views/ficha-recursos.js` (buscador en vivo, agrupado por tipo, pestaña nueva), `views/llamada-semaforo.js` (nivel, celda y columna compartidas), `views/hoy-llamadas.js` (tarjeta en Hoy), `css/llamadas.css`.
   - Tocados: `js/config.js` (`LLAMADA_AMARILLO_DESDE = 15`, `LLAMADA_ROJO_DESDE = 21`: único lugar de los umbrales), `views/ficha.js` (carga y dos bloques nuevos, hook opcional `montar`), `views/clientes.js` y `views/maestro.js` (columna "Última llamada", solo si existe la vista), `views/hoy.js` (cuarto contenedor), `index.html` (css).
   - Semáforo: verde menos de 15 días, amarillo 15 a 20, rojo 21 o más, gris "sin llamadas". Solo alumnos vivos (onboarding, activo, en renovación); el resto muestra "—". Tarjeta de Hoy: "Sin llamada hace 21 días o más" (lee la constante) con contador y lista, y plegados los vivos sin ninguna llamada registrada.
   - "En qué está" / "Próximos pasos": NO hay campos equivalentes con ese sentido. Hay `nota_csm` ("Nota") y `proxima_accion`/`proxima_accion_fecha` en el Maestro, que ya se muestran; no se agregó ni inventó nada. El resumen del último seguimiento no está en `cs_v_maestro`.
   - Permisos en pantalla: crear/editar/marcar = `puedeEditarPrograma(programa)`; borrar accionable, llamada o recurso = `esFundador()`; cliente@ ve las llamadas con pendientes y no tiene formularios. La base lo impone igual.
   - Alta de llamada: no hay transacción desde el navegador (llamada, luego accionables, luego links). Si falla un paso, la llamada queda creada y el toast muestra el error; se completa desde su grupo.
000000000000000000. 13/10/2026, tarea "el rol producto configura las columnas" (SQL y JS SIN PROBAR: el agente no pudo correr SQL, node ni navegador; migración 100 asignada por el jefe, NO corrida):
   - Antes: la config ya era UNA por programa y compartida (`cs_maestro_columnas.programa_id`, sin localStorage ni por usuario). Frenaba: las 5 funciones de estructura de la 071 llamaban a `cs_maestro_exigir_fundador()` (42501) y `maestro.js` mostraba el panel solo con `esFundador()`.
   - `migraciones/100-producto-columnas-rol-producto.sql`: `cs_maestro_exigir_edicion(programa)` = `cs_puede_editar` (fundador o nivel `edicion` en ESE programa); la usan guardar (renombrar/ocultar/opciones), crear, ordenar y opcion_renombrar (cuerpo igual a la 071). `cs_maestro_columna_archivar` NO cambia: sigue solo fundador. La tabla solo tiene select para authenticated: no hay otra vía por API.
   - No pisa ni mueve datos: no escribe en `cs_maestro_columnas` ni `cs_clientes`; la config actual del fundador queda igual. Respaldo de las 4 definiciones viejas en `cs_bak_100_funciones`. Sin políticas RLS nuevas. Controles C1 a C6 y vuelta atrás comentados al final.
   - JS: `maestro.js` (`puedeConfigurar` = `puedeEditarPrograma(programaId)`, pasa `puedeBorrar: esFundador()`), `maestro-panel.js` (sin "Archivar", "Recuperar" ni sección Archivadas si no `puedeBorrar`), comentario en `datos-columnas.js`.
   - Única pantalla con columnas configurables: Maestro. Clientes y las demás tablas tienen columnas fijas.
00000000000000000. 13/10/2026, tarea "tarjeta Onboarding pendientes del Dashboard no coincidía con la pestaña Onboarding" (JS SIN PROBAR en navegador y `node --check` NO corrido: el agente no pudo ejecutarlo; sin migración, la 098 NO se usó):
   - Antes: `cs_v_kpis_programa.onboarding_pendientes` = alumnos vivos con `onboarding_estado = 'pendiente_agendar'` (el flujo viejo de agendar, 037). Con el onboarding por link daba 0 aunque la pestaña tenga 116 "Sin empezar".
   - Ahora: sin empezar (`sin_link` + `pendiente`) + en curso, con la definición compartida en `js/onboarding-estados.js` (`contarOnboarding`), sobre un único `cs_onboarding_lista` (el mismo pedido de la pestaña). Detalle debajo: "N sin empezar · M en curso". No cuenta completos ni sin onboarding.
   - La tarjeta ya era clicable: ahora lleva a `#/p/:programa/onboarding` (antes `clientes?onboarding=pendiente_agendar`). Si `cs_onboarding_lista` falla o falta la 096, cae al número viejo de la vista, sin detalle.
   - Se sacó de la tarjeta el aviso "demorados / SLA" (medía `pendiente_agendar`, ya no aplica) y su resaltado de alerta.
   - Tocados: `js/views/dashboard.js`, `js/views/onboarding-lista.js` (solo importa la definición compartida; mismo comportamiento), `js/onboarding-estados.js` (nuevo).
   - No tocado: el cron diario (036/038/039) sigue mandando a Discord "Onboarding pendientes" con el número viejo de la vista; Hoy y el panel del fundador no muestran esta cuenta.
0000000000000000. 13/10/2026, tarea "qué ve y qué puede hacer cada usuario de Liam" (SOLO LECTURA del código, sin cambios de código ni migración, la 098 NO se usó; nada probado en navegador ni en la base):
   - Fuentes leídas: `sesion.js`, `solo-lectura.js`, `layout.js`, `programa.js`, `app.js`, `nav-areas.js`, migraciones 001, 070, 071, 079, 093, 096, 097.
   - Modelo real: entra a Producto el fundador (crm_members.rol = 'fundador') o quien tenga fila en `cs_accesos` (079). El rol de área (producto, cliente, ventas...) NO da acceso por sí solo. Borrar = solo `es_fundador()`; escribir = `cs_puede_editar` (fundador o nivel 'edicion').
   - Producto no guarda ni muestra montos: ninguna tabla `cs_*` tiene plata y `cs_altas_pendientes` devuelve fecha, alumno, teléfono, programa y concepto, sin importes.
   - Resultado del relevamiento entregado en el resumen de la tarea. Sin verificar contra la base real si la 079 está corrida (ver Pendientes).
000000000000000. 13/10/2026, tarea "pulido visual de la selección masiva" (solo presentación, sin migración, la 098 NO se usó; sin probar en navegador):
   - Barra `.sel-barra` (`css/seleccion.css`): fondo opaco `var(--surface)`, texto `var(--text)`, borde `1px var(--accent)` y filo superior de 3px `var(--accent)`, sombra `var(--shadow-md)`. Posición, tamaño y z-index igual.
   - Títulos del resultado (`seleccion-masiva.js`): 0 aplicados = "Cambio masivo: no se aplicó"; 0 borrados = "Borrado: no se borró"; si hubo algunos, "resultado parcial" como antes.
   - Campo de confirmación del borrado: placeholder "Cantidad" (antes repetía el número a escribir).
00000000000000. 13/10/2026, tarea "tres arreglos de seguridad de uso en la selección masiva" (JS y CSS SIN PROBAR en navegador; sin migración, la 098 NO se usó):
   - Barra flotante: `.sel-barra` pasa a `position:fixed` abajo y centrada (`css/seleccion.css`, z-index 50, ancho `min(960px, 100vw - 32px)`, `max-height:60vh`). Ya no ocupa lugar en el flujo: marcar la primera casilla no mueve la tabla.
     Para no tapar la última fila, `pintarBarra` mide la barra (ResizeObserver) y le pone `padding-bottom` al contenedor de la vista mientras está visible.
   - La selección se vacía al cambiar cualquier filtro o la búsqueda, y al "Limpiar filtros": `sel.alCambiarFiltro()` en `clientes.js` y `maestro.js`. Se sacó el texto "fuera del filtro actual" (`textoFuera`, `#sel-fuera`).
   - Confirmaciones de edición masiva y borrado: `listaNombres` muestra los primeros 20 nombres y "y N más". Se mantiene escribir la cantidad para borrar.
   - Tocados: `js/views/seleccion-masiva.js`, `clientes.js`, `maestro.js`, `css/seleccion.css`. Cambiar de programa sigue limpiando la selección (no se tocó).
0000000000000. 13/10/2026, tarea "selección múltiple y edición masiva de clientes" (JS y CSS SIN PROBAR: el agente no pudo correr node ni navegador, `node --check` quedó sin correr; sin migración, la 098 NO se usó):
   - `js/views/seleccion-masiva.js` (nuevo): casilla por fila + casilla de encabezado ("todos los filtrados", respeta filtros y búsqueda) + barra con "N seleccionados", "Limpiar selección", campo, valor, "Aplicar…" y "Borrar seleccionados". Integrado en `clientes.js` y `maestro.js`; CSS en `css/seleccion.css` (link en `index.html`).
   - Permisos: `puedeEditarPrograma(id)` nueva en `sesion.js` (fundador o nivel `edicion` en ESE programa). Sin eso (cliente@, solo lectura) no hay casillas ni barra. "Borrar seleccionados" solo si `esFundador()`.
   - Campos, sin camino paralelo (alumno por alumno, en serie): Estado, Etapa, Responsable, Producto, Testimonio y Fecha de fin van por `guardarCampoCliente` (el mismo del Maestro: update de `cs_clientes`, mismos triggers); Resell por `guardarCampoExtra(id, 'x_resell', true|false)` (igual que la ficha).
     Reglas de la ficha repetidas: estados elegibles sin en_renovacion/pausado; fecha de fin obligatoria y no anterior al inicio (falla ese alumno, no se manda); Producto no mueve la fecha de fin.
     La confirmación muestra campo, valor, cuántos cambian y sus nombres; avisa del offboarding (finalizado/baja), de los pausados que se reanudan y de los que ya tienen el valor (se saltean si la vista trae la columna).
   - Resultado: al terminar recarga los datos; si alguno falla, un modal lista nombre y motivo, y quedan seleccionados solo esos para reintentar.
   - Borrado: `borrarFila('cs_clientes', id)` por alumno (mismo camino que "Borrar cliente" de la ficha; la base lo exige con `cs_puede_borrar()`). Confirmación con la lista de nombres y hay que escribir la cantidad. Un delete que la base filtra no da error: se verifica recargando y los que siguen figuran como no borrados.
   - La selección vive en la vista: se pierde al cambiar de programa o de pestaña; los que ya no existen salen solos al recargar.
000000000000. 13/10/2026, tarea "precarga de contacto traía solo la primera palabra del nombre" (JS, releído a mano, sin navegador ni node; sin migración, la 098 NO se usó):
   - `js/onboarding-formulario.js` `precargarContacto`: si el paso tiene un campo con `contacto = apellido`, nombre = primera palabra y apellido = el resto (Grupal, como antes);
     si NO hay campo apellido (Datos de contacto del 1 a 1), el campo `contacto = nombre` recibe el nombre completo. Sigue siendo solo si el campo está vacío y solo sin borrador en memoria.
   - "Nombre y apellido" de Diagnóstico y Perfil inversor (1 a 1): no tienen `contacto` en la plantilla (093 líneas 1605 y 1639), así que NO se precargan. No se tocó.
00000000000. 13/10/2026, tarea "función de lectura para Ventas y ajustes del onboarding tras probar en producción" (SQL, JS y navegador SIN PROBAR: el agente no pudo correr SQL, node ni navegador; migración 097 asignada por el jefe, NO corrida; 096 ya en producción):
   - `migraciones/097-producto-onboarding-ajustes-prueba.sql` + `097b-...-control.sql`. Un solo bloque, guardas `v_esperado_*`, respaldo en `cs_bak_097_plantillas` y `cs_bak_097_funciones`.
     Pisa: el tipo de UN campo de la plantilla 1a1 de liam (respaldada) y 3 funciones (respaldadas: cs_ob_limpiar, cs_ob_armar_estado, cs_onboarding_lista). Crea 1 función. No borra nada ni toca alumnos, onboardings ni respuestas.
   - Ventas: `cs_onboarding_link_estado_closer(p_programa, p_telefono, p_nombre)`, solo lectura, misma búsqueda y mismo permiso (`cs_ob_es_closer`) que `cs_onboarding_link_closer`; jsonb con alta, inactivo, tiene_link, estado, vence_at, vencido, alumno, producto, con_onboarding. Sin token.
   - `problemas_principales` del 1 a 1 pasa a casillas (la Grupal ya lo era desde la 093). Texto viejo: `cs_ob_limpiar` lo toma como una opción, el front lo normaliza al reabrir un borrador, y la ficha/pestaña muestran texto o lista (`onboarding-respuestas.js`).
   - "Otros" sin texto: error en el front (junto al campo) y en `cs_ob_limpiar` al enviar el paso (en borrador no frena).
   - Teléfono: regla única (solo dígitos, + ( ) . espacios y guiones, 8 a 15 dígitos) para todo campo `contacto = telefono` (1 a 1 y Grupal), en `onboarding-formulario.js` y en `cs_ob_limpiar` al enviar. Antes no había validación de teléfono en ninguno de los dos.
   - Precarga del contacto: `cs_ob_armar_estado` devuelve `contacto` {nombre, email, telefono} mientras quede un paso con campos de contacto sin completar; la landing los precarga si el campo está vacío (nombre = primera palabra, apellido = el resto).
   - Pestaña Onboarding: filtro "Sin onboarding" y cuenta en el resumen; Accesos evalúa solo lo que pide la plantilla (`cs_onboarding_lista`: skool/wpp null si la plantilla no tiene ese enlace); el modal "Respuestas de…" se cierra al cambiar de ruta (hashchange).
   - Video (punto 8): CONFIRMADO por lectura que el contador suma tiempo con la pestaña visible (latido cada 10 s), no reproducción. NO se cambió: el iframe de Loom no tiene un evento de play documentado/verificado acá. Opciones en Pendientes.
   - 096b Q07 (comprobación 3b): `cs_onboarding_lista` se consulta con la sesión de un usuario con acceso (cs_accesos de liam o fundador) y se vuelve a la del closer. La función no cambió.
   - 097b (líneas; correr de a una): Q00 10-17 · Q01 20-28 · Q02 31-39 · Q03 42-48 · Q04 51-139 ("HUMO OK: 10") · Q05 142-268 ("HUMO OK: 10"; necesita un ventas/closer asignado a liam) · Q06 271-327 ("HUMO OK: 2") · Q07 330-359 (error "RESULTADO: ...").
0000000000. 12/10/2026, tarea "cambios al onboarding de la reunión con Nacho" (SQL, JS y navegador SIN PROBAR: el agente no pudo correr SQL, node ni navegador; migración 096 asignada por el jefe, NO corrida; 093 ya está en producción y NO se toca):
   - `migraciones/096-producto-onboarding-cambios-nacho.sql` + `096b-...-control.sql`. Un solo bloque, autochequeo con `v_esperado_*` al inicio, respaldo en `cs_bak_096_plantillas` y `cs_bak_096_funciones`.
     Pisa: `pasos` de la plantilla 1a1 de liam (respaldada) y 5 funciones (respaldadas). No borra nada.
   - Paso nuevo `como_nos_conociste` en la 1a1 de liam, entre `perfil_inversor` y `hoja_de_ruta`: preguntas 6 a 21 del form de Liam, textos y tipos del original (con sus tipeos; única corrección: ejemplo de la 18 "Vi un video de Liam donde entendí..."). Obligatorio: 1 a 1 pasa de 4 a 5. Grupal intacta.
     Dudas de fidelidad resueltas literal: P16 queda opción única (el original lo es aunque la ayuda diga "Podes elegir varias"; cambiar `opcion` por `casillas` en `problemas_principales` si se prefiere) y P13 sin "3 a 6 meses".
   - Alumnos con link: el progreso va por clave de paso, así que el paso nuevo les aparece pendiente sin perder nada. Los ya COMPLETADOS quedan completados (avance 5 de 5, `cs_ob_hechos_est`); reabrir uno a mano: utilidad B de la 096b.
   - "Otros" con texto libre: campo `"otro": "<opción>"` en opcion/casillas, texto en `<key>_otro` (`cs_validar_onboarding_otros`, `cs_ob_limpiar`, front y ficha).
   - Landing: botón "Volver al paso anterior" (todos menos el primero); borradores en memoria + `guardarBorrador` al volver; un formulario enviado muestra "ya enviado" sin respuestas y deja avanzar.
   - Resell: casilla `x_resell` (campos_extra) en `cs_maestro_columnas` de cada programa, OCULTA (disponible). Ficha (`ficha-ciclo.js`), modal Nuevo cliente, pestaña Onboarding y RPC del closer. No había dato equivalente (`renovaciones_count` cuenta renovaciones dentro de la app).
   - Ventas (closer): `cs_closer_productos(programa)` y `cs_onboarding_alta_closer(programa, nombre, producto, telefono, email, resell)`. Duplicado (nombre en cualquier orden o teléfono, entre activos) = error `ALUMNO_YA_EXISTE`, no devuelve el link del otro: se pide con `cs_onboarding_link_closer`.
   - Pestaña "Onboarding" (`views/onboarding-lista.js`, ruta `#/p/:programa/onboarding`, en `layout.js` SECCIONES; `nav-areas.js` NO se tocó): `cs_onboarding_lista(programa)`; filtros todos/sin empezar/en curso/completos; abrir alumno = todas las respuestas por paso (`views/onboarding-respuestas.js`, compartido con la ficha).
     "Nuevo cliente" usa `cliente-nuevo.js` y deja el botón "Link de onboarding" en el resumen. `cs_onboarding_lista` agregada a las RPC de lectura de `solo-lectura.js`.
   - Dominio: base del link en `js/config.js` (`ONBOARDING_BASE_URL`, vacía = `window.location.origin`), usada solo por `urlOnboarding` en `js/datos-onboarding.js`. Login: `signInWithPassword` (mail y contraseña), sin redirects ni OAuth ni link mágico en el código.
   - 096b (líneas; correr de a una): Q00 15-54 · Q01 57-68 · Q02 71-85 · Q03 88-100 · Q04 103-112 · Q05 115-121 · Q06 124-136 · Q07 139-316 (humo closer, "HUMO OK: 11", o 10 si liam no tiene productos sin onboarding) · Q08 319-494 (humo recorrido, "HUMO OK: 10") · B y C comentadas 498-end.
000000000. 12/10/2026, tarea "tres ajustes a la 093 tras probarla con PGlite" (SQL SIN PROBAR por este agente; el jefe vuelve a correr el banco; 093 sigue NO corrida en producción, mismo número):
   - Privacidad: `cs_ob_armar_estado` ya no devuelve respuestas de formularios ENVIADOS (completo = true o paso con completado_at). Solo el borrador en curso, para retomar. La landing solo usaba
     `estado.respuestas[p.key]` (onboarding-publico.js:197) para precargar el formulario en curso: no hizo falta tocar el front. Riesgo ACEPTADO: quien tiene el link (el closer siempre) ve el borrador mientras el alumno lo llena.
   - Contador: `cs_onboarding_link` (fundador/producto, el botón de la ficha) reinicia `escrituras` a 0 en un onboarding no completado, conserva token y avance. El closer no lo reinicia.
     Cuenta de un recorrido 1 a 1: 1 (bienvenida) + 1 (contacto) + 6 (diagnóstico: 5 borradores + envío) + 1 (perfil) + 1 (hoja de ruta) + 3 (accesos) = 13 de 400. Los latidos de video NO cuentan (cs_ob_latido no toca `escrituras`)
     y el borrador se guarda solo al tocar "Siguiente", no por reloj. Se deja 400 (~30 veces lo normal).
   - `select *`: el front nuevo no lee `cs_onboardings` directo (todo va por RPC); no hay `*` ni `select()` vacío. Las funciones `security invoker` (avance, hoy) nombran columnas con permiso. Las `security definer` usan `select *` como dueño (ok).
   - Closer: alumno finalizado/baja ahora da P0002 `ALUMNO_INACTIVO: ...` con hint `ALUMNO_INACTIVO` (antes ALUMNO_SIN_ALTA). Misma firma. Respuesta OK sin cambios: `{token, estado, vence_at, alumno}`, estado `pendiente|en_curso|completado`.
   - Anotado sin cambiar: el CHECK de `crm_members.rol` (075 de Marketing) no incluye `closer` en la lista reconstruida: hoy la vía del closer solo la usa el rol `ventas`.
   - 093b: Q07 17 -> 20 comprobaciones (borrador visible, enviado no vuelve, tope), Q10 7 -> 9 (token del closer no lee enviados; ALUMNO_INACTIVO), Q11 nuevo (reinicio del contador, 4 comprobaciones).
00000000. 12/10/2026, tarea "arreglar la 093 por segunda vez y revisarla a fondo" (SQL SIN PROBAR: sin Postgres local; revisión por lectura; 093 sigue NO corrida, conserva el número):
   - Error de la 2ª corrida: `invalid regular expression: invalid repetition count(s)` en `cs_validar_onboarding_pasos`: `[^\s]{4,500}` (máximo 255 en las regex de PostgreSQL).
     Ahora `~ '^https://[^\s]+$'` + `char_length(url) between 12 and 500`. Revisadas TODAS las regex de 093 y 093b: el resto usa {0,39}, {1,60}, {0,3}, {32}, {64}, {1,40} (bien).
   - Como las funciones PL/pgSQL no se verifican al crearse, la 093 ya había pasado todas las `create function`: lo que nunca corrió es el SQL de adentro. Se repasó función por función
     (columnas, tipos, casts, ambigüedad variable/columna, `%` de los `raise`, `case`, delimitadores) y el JSON de las dos plantillas contra el validador a mano. No apareció otro error de ejecución.
   - Autochequeo al principio (antes de crear nada, sin tablas nuevas): versión de Postgres, tablas, columnas, funciones (cs_puede_*, cs_norm_*, cs_hoy, auth.uid) e índices únicos que usa la 093.
     Mensajes que empiezan con `cs 093:`. Se sacó el `select` de diagnóstico previo al `begin` (lo cubre Q01).
   - Validación con motivo: `cs_validar_onboarding_pasos_motivo(jsonb) -> text` (null = válido; si no, "paso 3 (diagnostico), campo x: regla"). `cs_validar_onboarding_pasos(jsonb)` queda como
     wrapper booleano para el CHECK. Las dos plantillas se cargan desde un DO que las pasa por el motivo y, si falla, `raise exception 'cs 093: la plantilla 1a1 de liam no pasa la validación: <motivo>'`.
   - Otros arreglos: `cs_onboarding_diferencia_resolver` aplicar `email` con un mail mal formado daba el error crudo del CHECK de cs_clientes: ahora mensaje claro (22023).
   - Closer, alumno todavía sin alta en Producto: SQLSTATE `P0002`, message `ALUMNO_SIN_ALTA: el alumno todavía no está dado de alta en Producto. Lo da de alta la CSM desde Clientes nuevos.` y `hint = 'ALUMNO_SIN_ALTA'`.
     En supabase-js: `error.hint === 'ALUMNO_SIN_ALTA'` (o `error.message.startsWith('ALUMNO_SIN_ALTA')`). Firma y respuesta OK de `cs_onboarding_link_closer(p_programa, p_telefono, p_nombre)` sin cambios.
     Otros errores de esa RPC: 42501 sin permiso, 22023 faltan datos, 23505 más de un alumno coincide.
   - Decisiones de Joaquín: el botón "Link de onboarding" del closer va en la app de VENTAS, en la llamada cerrada (lo hace otra tarea); el closer NO da altas: si el alumno no está, espera a la CSM.
   - 093b: Q00 nuevo (qué objetos de la 093 existen, no depende de las tablas nuevas), Q03 +2 filas (funciones del validador), Q10 chequea el error fijo `ALUMNO_SIN_ALTA`.
   - Dudas que quedan (no resolubles por lectura): (1) `a.attnum = any (i.indkey)` del autochequeo (idioma estándar, 093 línea 140); (2) nombres exactos de producto de liam (si no coinciden queda SIN ASIGNAR, ver Q01);
     (3) que los closers tengan rol `ventas` o `closer` en crm_members (Q09); (4) un alumno finalizado/baja se ve como "sin alta" para el closer; (5) el SQL de adentro de las funciones recién corre en Q07/Q10.
   - Controles de la 093b (líneas exactas, comentario inicial a `;`; correr de a una): Q00 14-72 (todo SÍ y RESUMEN "APLICADA COMPLETA"; antes de la 093 "NO APLICADA") · Q01 75-84 (4 productos con onboarding, Gestión de Capital SIN ASIGNAR) ·
     Q02 87-102 (1a1: 7 pasos, 4 obligatorios, 2 videos opcionales, 38 preguntas; grupal: 4, 2, 1, 22) · Q03 105-162 (ok = true en todas) · Q04 165-176 (4 tablas, rls true, 1 política select) ·
     Q05 179-189 (5 casillas y onb_avance = true) · Q06 192-202 (0 filas antes de probar) · Q07 205-473 (error "HUMO OK: 17 comprobaciones...") · Q08 476-490 (tras prueba real con alumno "PRUEBA ONBOARDING") ·
     Q09 493-505 (informativo: closers y clientes asignados) · Q10 508-631 (error "HUMO OK: 7 comprobaciones...").
0000000. 12/10/2026, tarea "video opcional + grupales unificados" (SQL y navegador SIN PROBAR; 093 sigue NO corrida y conserva el número):
   - Obligatoriedad como dato del paso: `"obligatorio": false` (por defecto true; solo válido en `video` y `texto`). En Liam, los dos Loom (bienvenida y "Hoja de ruta") de 1a1 y el de bienvenida de grupal quedan opcionales.
     Para volver a exigir un video: `jsonb_set(pasos, '{0,obligatorio}', 'true')` (utilidad B2 de la 093b). La base exige que un video obligatorio tenga `duracion_seg` o `minimo_seg`.
   - Un paso opcional se muestra en su lugar con su botón habilitado de entrada, no bloquea a los siguientes (`cs_ob_bloqueado`: solo mira obligatorios pendientes antes) y no cuenta en el avance.
   - Cuenta: `cs_ob_total` y `cs_ob_hechos` cuentan solo obligatorios. 1a1 = 4 (contacto, diagnóstico, perfil, accesos); grupal = 2 (formulario, accesos). El alumno ve "Paso n de N" con todos los pasos (posición).
   - El tiempo de video se sigue guardando (latido). `visto_at` = llegó al 90 % de `duracion_seg` (o a `minimo_seg`); un video opcional seguido de largo queda completado pero NO visto, y no marca `x_ob_video`.
   - Se sacó el mínimo provisorio de 54 s: sin duración conocida no hay mínimo (solo se guardan los segundos, tope 1 h). "Hoja de ruta" no tiene duración: se le sacó la casilla `x_ob_video`
     (que queda solo con el video de bienvenida, 360 s) hasta que se conozca la duración. Etiqueta de la casilla: "Onboarding: video visto".
   - Grupal Anual y Grupal 4 meses comparten el producto "BPF Grupal" y la plantilla `grupal`: no se crea producto ni plantilla aparte.
   - Textos de los videos: ya no dicen "tenés que verlo"; botón "Continuar". Front: `onboarding-video.js`, `onboarding-publico.js`, `views/ficha-onboarding.js`.
   - 093b: Q02 (4 y 2 obligatorios, + columna de videos opcionales), Q03 (+ cs_ob_bloqueado), Q07 (alumno A ve el video, alumno B lo saltea; avance 4 de 4), utilidades B y B2.
000000. 12/10/2026, tarea "arreglar la 093 + permiso del closer" (SQL SIN PROBAR: sin Postgres local ni acceso a Supabase; 093 sigue NO corrida):
   - La 093 falló al correrse (nada se aplicó): `if char_length(v_txt) > case when ... then ... end then` en `cs_ob_limpiar`. Ahora el límite va en una variable (`v_lim`).
     Revisada entera: no quedan `case` dentro de condiciones de `if`/`elsif`/`while`/`exit when` en 093 ni 093b; el `case` de `cs_ob_contacto` es sentencia PL/pgSQL pura.
   - Agregado a la 093: requisito de `crm_members`/`crm_asignaciones` (y sus columnas) y `lock table cs_programas, cs_productos, cs_clientes in share row exclusive mode`
     antes de crear las tablas con FK (regla del deadlock).
   - Permiso del closer: `cs_ob_generar_link(uuid)` (interna, sin chequeo), `cs_onboarding_link(uuid)` (misma firma, ahora chequea cs_puede_editar y la llama) y
     `cs_onboarding_link_closer(p_programa, p_telefono, p_nombre)`: rol `ventas` o `closer` con el programa en `crm_asignaciones`; encuentra al alumno por últimos 8 dígitos del
     teléfono o nombre normalizado (regla de la 070); una sola coincidencia o error; NO crea al alumno; devuelve token, estado, vence_at y primer nombre.
     No da lectura de respuestas, ni del programa, ni del Maestro. No hay front en este repo ni se tocó Ventas.
   - 093b: Q03 suma 4 filas del closer; Q09 (quién puede generar el link, informativo) y Q10 (humo del closer, se deshace sola). Líneas exactas en el resumen de la tarea.
   - Ficha: el aviso del modal de contacto ya no dice "ningún dato financiero va a la base" (`views/ficha-cabecera.js`).
   - Formulario Grupal pregunta 18 (`ultimo_empujon`): sin ayuda; no se inventaron los ejemplos (comentario en el seed).
00000. 12/10/2026, tarea "Fase 6: onboarding por link, empezando por Liam" (SQL, JS y navegador SIN PROBAR: el agente no pudo ejecutar SQL, node ni el navegador; migración 093 asignada por el jefe, NO corrida):
   - `migraciones/093-producto-onboarding-link.sql` + `093b-producto-onboarding-control.sql` (controles Q01 a Q08, sueltos; Q07 es una prueba de humo que se deshace sola).
   - Tablas: `cs_onboarding_plantillas` (pasos como jsonb validado: video, formulario, acceso, texto, final), `cs_onboarding_plantilla_productos` (producto -> plantilla),
     `cs_onboardings` (uno por alumno: token de 64 hex, avance, diferencias de contacto), `cs_onboarding_respuestas` (sensibles: solo cs_puede_ver).
     No se reutilizó cs_formularios/cs_respuestas (004): su validador no tiene casillas, escala 1 a 10 ni secciones. Sí: cs_clientes, cs_productos, campos_extra, x_unio_school (079), cs_norm_* (070) y el accionable `formulario_onboarding`.
   - RPC públicas (anon, por token): `cs_ob_estado`, `cs_ob_latido`, `cs_ob_avanzar`, `cs_ob_confirmar`. De la app: `cs_onboarding_link` (cs_puede_editar), `cs_onboarding_ficha`, `cs_onboarding_diferencia_resolver`, `cs_onboarding_avance`, `cs_onboarding_hoy`.
     anon no tiene permiso sobre ninguna tabla; el token no es legible por la app (permiso por columna).
   - Liam cargado: plantilla `1a1` (bienvenida, contacto, diagnóstico de 6 secciones, perfil, hoja de ruta, accesos, final) y `grupal` (bienvenida, formulario de 22 preguntas, Skool, final), asignadas por nombre exacto de producto: BPF 1-1 4/6/12 Meses -> 1a1; BPF Grupal -> grupal. "Gestión de Capital" queda sin onboarding.
   - Video: tiempo en pantalla medido en el servidor con latidos cada 10 s (90 % de la duración). No prueba que lo haya mirado. (Hoy opcional: ver la entrada de arriba.)
   - JS nuevo: `onboarding.html`, `js/onboarding-publico.js`, `onboarding-video.js`, `onboarding-formulario.js`, `css/onboarding.css`, `js/datos-onboarding.js`,
     `views/ficha-onboarding.js` (bloque en la ficha), `views/onboarding-link.js` (botón y copiado), `views/hoy-onboarding.js` (aviso en Hoy), `views/maestro-onboarding.js` (columna "Onboarding").
     Tocados: `ficha.js`, `hoy.js`, `hoy-altas.js` (botón en el aviso al crear cliente), `maestro.js`, `solo-lectura.js`, `index.html`.
   - Casillas del Maestro de liam: x_ob_video, x_ob_formularios, x_ob_wpp, x_ob_escribio (+ x_unio_school de la 079). Las marca el alumno al confirmar; la CSM las corrige a mano.
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
000000000. **Llamadas, accionables y recursos (13/10):** correr la 102 en el banco de pruebas (de a una: C1 a C6, C7 humo = error "HUMO OK: 6 comprobaciones", C4 muestra de qué fuente sale hoy la última llamada de liam) y después en producción; `node --check` de `datos-llamadas.js`, `llamada-semaforo.js`, `ficha-llamadas.js`, `ficha-recursos.js`, `hoy-llamadas.js`, `ficha.js`, `clientes.js`, `maestro.js`, `hoy.js`, `config.js` (no se pudo correr); probar en navegador con un alumno DE PRUEBA: nueva llamada con accionables (una subtarea con 2 espacios) y links, marcar/desmarcar (quién y cuándo), borrar como fundador, `producto@` sin botón Borrar, `cliente@` solo ve, buscador de recursos, columna en Clientes, Maestro y Hoy. Decisiones abiertas: umbrales 15/21 o 7/10 (una línea en `js/config.js`); si "llamada" debe incluir `cs_calls` realizadas y seguimientos por call o reunión (hoy sí; se cambia solo en la vista); si "En qué está" y "Próximos pasos" necesitan campo propio (hoy NO existen); si 101 u otra migración redefine `cs_maestro_claves_sistema()`, la 102 la pisa: correr la 102 después y con la lista vigente.
00000000. **Columnas para producto (13/10):** correr la 100 (de a una Q: C1 y C4 antes y después), `node --check` de `maestro.js`, `maestro-panel.js`, `datos-columnas.js` (no se pudo correr), y probar en navegador con `producto@`: mover, ocultar, renombrar, crear columna y cargar un dato, recargar y verlo desde otro usuario; que no aparezca Archivar; `cliente@` sin botón Columnas. Ojo: la regla es `cs_puede_editar`, no el rol literal: cualquier usuario con nivel `edicion` en `cs_accesos` del programa configura columnas.
0000000. **Tarjeta Onboarding pendientes (13/10):** `node --check` de `dashboard.js`, `onboarding-lista.js`, `onboarding-estados.js` y mirar en navegador que la tarjeta de liam coincida con "Sin empezar" + "En curso" de la pestaña (116 + los en curso). Decidir si el mensaje de Discord del cron (usa `onboarding_pendientes` viejo de la vista, 0 con el flujo nuevo) pasa a la misma definición: requiere migración, pedir número.
000000. **Permisos de Liam (13/10):** antes de habilitar al equipo, correr el control 03/04/04b de la 079 y confirmar que cada mail tiene el acceso esperado (cliente@ = lectura, producto@ = edición, ventas@/finanzas@/contenido@ sin fila). Confirmar con Joaquín: mail real del fundador (dystopia.acy@gmail.com vs fundador@agencia.dystopia de la 079), si cliente@ debe ver respuestas del onboarding (datos personales y financieros del alumno) y si la lectura de `token_publico` por cliente@ es aceptable.
00000. **Pulido selección masiva (13/10):** mirar en navegador la barra sobre filas a mitad de scroll (contraste del texto y controles), el modal "no se aplicó" con un cambio que falle en todos y el placeholder "Cantidad" del borrado.
0000. **Selección masiva (arreglos 13/10):** `node --check` de los 3 JS y probar en el navegador: marcar/desmarcar no mueve filas ni encabezado (Clientes y Maestro, también con scroll horizontal), barra legible en pantalla angosta y sin tapar la última fila, cambiar filtro/búsqueda deja 0 seleccionados, confirmaciones con tope de 20 y "y N más". Ojo: el toast (z-index 200, abajo al centro) tapa la barra unos segundos.
000. **Edición masiva:** correr `node --check` de `seleccion-masiva.js`, `clientes.js`, `maestro.js`, `sesion.js` y probar en el navegador con alumnos DE PRUEBA (nunca reales): marcar varios en Clientes y en Maestro, los 7 campos, recargar y ver que persiste; "todos los filtrados" con filtro y búsqueda; fundador vs `producto@` vs `cliente@`; borrar con la cantidad. Sin commit hasta probar.
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
   - A7: pasos de onboarding antes de dar Discord y Skool. (Resuelta en la reunión del 07/10 con Nacho: video, formularios y accesos en orden, por link; ver Fase 6.)
   - A8: webhook de Discord.
2. **Fase 7: teo, agus y lucas** (depende de A1-A5). Por cada cliente:
   - productos (teo 120 d; agus 90/30/45 y Skool sin vencimiento; lucas 90), plantilla de accionables, avisos (teo 21/10, agus 21/7);
   - "Sacar de Discord" en el offboarding de teo;
   - importación generada en `datos/` como la 040.
   Falta permitir productos sin vencimiento (hoy `duracion_dias > 0` y `fecha_fin not null`).
3. **Fase 2: liam al día y corte.** El CSM siguió cargando en el Sheet después del 29/09.
   Joaquín exporta el CSV a `datos/liam-clientes-<fecha>.csv`, Claude Code genera la importación de diferencias,
   se marca `cs_programas.maestro_cortado_en` y alguien le avisa al CSM. Joaquín pidió NO cortar hasta revisar con la agencia.
4. **Fase 6: onboarding por link.** Hecho para Liam (093, sin correr ni probar). A7 queda respondida: el contenido se define por programa (plantilla) y el link se genera por alumno.
   Falta: correr 093 y la 093b (Q01 a Q07), probar con un alumno de prueba, confirmar los links transcriptos de capturas, la duración del Loom "Hoja de ruta" (hoy sin duración: opcional, solo guarda segundos y no marca la casilla; ver utilidad B de la 093b),
   decidir cuándo activar la obligatoriedad de los videos (cambiar el dato `obligatorio`, utilidad B2), Discord de teo/agus, y cargar teo/agus/lucas (solo datos).
   El closer (`ventas`/`closer`) puede generar el link por `cs_onboarding_link_closer` (en la 093). DECIDIDO: el botón "Link de onboarding" va en la app de Ventas, en la llamada cerrada
   (lo implementa la app de Ventas); el closer NO da altas: si el alumno no está en Producto, la RPC devuelve `ALUMNO_SIN_ALTA` (P0002) y espera a la CSM ("Clientes nuevos").
   Falta confirmar que `closer` también carga ventas de sus clientes (si no, sacarlo de la lista de roles de la RPC). Respuestas exportables para Valentín: no hecho.
   Riesgos aceptados: el que tiene el link ve el borrador en curso; `crm_members.rol` quizá no admita `closer` (075). Q07 ahora da "HUMO OK: 20", Q10 "HUMO OK: 9", Q11 "HUMO OK: 4".
   La 093 corregida hay que correrla de nuevo ENTERA (3ª vez); después Q00, Q01 a Q07 y Q09/Q10/Q11 (Q10 necesita un usuario ventas/closer asignado a liam). Si falla, el mensaje dice `cs 093:` + paso y regla.
4b. **096 (cambios de Nacho):** probarla en el banco de pruebas (necesita 093 aplicada completa, 071, 079, 070, 039 y crm_members/crm_asignaciones), correr Q00 a Q08 de la 096b, y recién ahí en producción.
   Pendiente de decisión: la pantalla de Ventas (otra app) usa `cs_closer_productos` / `cs_onboarding_alta_closer`; reabrir completados para que llenen el paso nuevo (utilidad B); decidir si P16 va como casillas;
   mostrar la columna Resell en el Maestro (hoy oculta, la muestra el fundador desde Columnas); la pestaña Onboarding lista también a los ~133 alumnos históricos como "sin empezar" (no tienen link). Dominio `producto.dystopia.com.ar`: ver Cuidado con.
4c. **097 (ajustes tras probar la 096):** correrla en el banco de pruebas (necesita 093 y 096 aplicadas) y después Q00 a Q07 de la 097b. Pendiente: pasar el contrato de `cs_onboarding_link_estado_closer` a la app de Ventas;
   decidir qué hacer con el tiempo de video (hoy mide tiempo en pantalla; contar reproducción real exige un evento de play del reproductor de Loom, o cambiar de reproductor/usar la API de player.js si Loom la soporta: no verificado);
   la 097 no cambia el texto "Podes elegir varias" de la pregunta (ya coincide con casillas).
5. **Fase 4: ficha de un vistazo** (barra de tiempo y línea de contactos). Sin dependencias.
6. **Fase 8: vista de cobranza** de solo lectura sobre `fin_cuotas` (solo liam tiene datos).
7. Bajar `resell_gracia_dias` de liam de 200 a 30 cuando se cierren los 19 pipelines abiertos importados.
8. Partir `js/datos.js` antes de sumarle código (está en ≈485 de 500 líneas).
- Bugs conocidos: ninguno abierto. Sin probar en navegador: arrastrar y soltar del panel de Columnas y el doble clic en el encabezado.
- Sin pendientes nuevos por el cambio de regla de numeración (no existe CLAUDE.md en el repo).
- Decisiones de Joaquín: fecha de corte de cada cliente y quién avisa al CSM.

## Cuidado con
- **Cambio de dominio (`producto.dystopia.com.ar`):** las sesiones de Supabase viven en el localStorage del origen: al pasar de dominio hay que volver a loguearse. El link de onboarding sale de `window.location.origin` (o de `ONBOARDING_BASE_URL` en `js/config.js`):
  los links ya mandados con `vercel.app` siguen funcionando mientras ese dominio siga activo. `js/nav-areas.js` tiene URLs fijas `*.vercel.app` de las 4 apps (no se tocó). En Supabase Auth hay que agregar el dominio nuevo a Site URL / Redirect URLs solo si el proyecto manda mails de reset o link mágico (esta app no los usa). CORS de la API de Supabase no restringe origen.
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
