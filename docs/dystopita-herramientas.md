# Herramientas de Dystopita (Producto y Marketing, migración 159)

Complementa `dystopia-finanzas/docs/dystopita-herramientas.md` (Ventas y Finanzas, migración 158). La Edge Function `ia-preguntar` (este repo) ofrece al modelo las herramientas de las 4 apps y las ejecuta con el **token del usuario**. Todas son funciones SQL **SECURITY INVOKER**, de **solo lectura**, que devuelven un resumen corto en `jsonb` (las `cs_chat_*` de la 140/141 devuelven filas). Nunca devuelven teléfonos, emails ni nombres de alumnos en los conteos.

Parámetros comunes: `p_cliente` (liam, agus, teo; vacío = todos los que el usuario ve), `p_desde` / `p_hasta` (`YYYY-MM-DD`, inclusive; sin fechas = este mes hasta hoy, zona Argentina; máximo ~26 meses). Errores: `42501` = el rol no ve ese dato (mensaje en castellano), `22023` = parámetro inválido o cliente que no existe o no ve.

## Puerta de entrada

`ia_chat_acceso()` devuelve el rol de quien pregunta si es uno de los 9 con usuario (fundador, producto, cliente, ventas, finanzas, closer, setter, contenido, editor); si no, `null` y `ia-preguntar` responde 403. No decide qué ve cada uno: lo decide cada herramienta y la RLS. Sin la 159 corrida, la función cae a `cs_chat_puede` (fundador, producto, cliente).

## Quién ve qué

| Familia | fundador | producto | cliente | contenido / editor | ventas | finanzas | closer / setter |
|---|---|---|---|---|---|---|---|
| Producto (`cs_chat_*`, `ia_chat_alumnos_resumen`) | todo | sus programas | su programa | 42501 | 42501 | 42501 | 42501 |
| Marketing (`ia_chat_mkt_*`) | todo | 42501 | su cliente | sus clientes | 42501 | 42501 | 42501 |
| Ventas y Finanzas (158) | ver doc de Finanzas | | | | | | |

Producto no ve Marketing en el chat: la RLS le da 0 filas de `crm_publicaciones` y `crm_ia_analisis` (decisión de la 152: solo lee el análisis por pieza con la pantalla propia, sin métricas).

## Producto

### `ia_chat_alumnos_resumen(p_cliente, p_desde, p_hasta)` · tool `alumnos_cantidad`
Alumnos por cliente. Devuelve `{ periodo, programa, total, por_programa[], nota }`; cada bloque trae `alumnos`, `vivos` (onboarding + activo + en_renovacion), `onboarding`, `activos` (solo estado activo), `en_renovacion`, `pausados` (aparte: no cuentan como vivos), `finalizados`, `bajas`, `vivos_grupal`, `vivos_vip`, `vivos_sin_dato` (modalidad de la 157; sin dato se trata como 1 a 1), `altas_en_periodo` (fecha de inicio en el periodo) y `vencen_en_periodo` (fecha de fin en el periodo).
Ejemplo: "¿cuántos alumnos activos tiene teo?" → `p_cliente = 'teo'` → `total.activos` y `total.vivos`. Requiere la 157 (`cs_v_modalidad`).

Las otras tres de Producto no cambian: `alumnos_atrasados` (`cs_chat_atrasados`), `en_que_esta_alumno` (`cs_chat_en_que_esta`), `por_renovar_o_deuda` (`cs_chat_renovar_o_deuda`).

## Marketing

Rol exigido: `crm_rol_mkt()` en fundador, cliente o editor (contenido cuenta como editor).

### `ia_chat_mkt_piezas(p_cliente, p_desde, p_hasta, p_plataforma)` · tool `mkt_piezas_publicadas`
Piezas **publicadas** (`estado_publicacion = 'PUBLICADO'`, misma regla que el Dashboard) con fecha de publicación en el periodo. `p_plataforma`: instagram, tiktok, youtube, linkedin o carrusel.
Devuelve `{ periodo, cliente, plataforma, total, por_cliente[], por_plataforma[], por_mes[], top_por_vistas[5], nota }`; cada bloque trae `piezas`, `con_metricas` (las que tienen vistas), `views`, `comments`, `likes`, `guardados`, `enviados`, `promedio_views`.

### `ia_chat_mkt_pendientes(p_cliente, p_etapa)` · tool `mkt_pendientes_produccion`
Pendientes de producción hoy (sin filtro de fecha; mismas definiciones que `crm_dashboard`): por grabar (grabación PENDIENTE o EN PROCESO), por editar (GRABADO y edición vacía / PENDIENTE / EN PROCESO) y por publicar (edición EDITADO y publicación vacía / PENDIENTE / LISTO PARA PUBLICAR / PROGRAMADO). Con `p_etapa` (`grabar`, `editar`, `publicar`) suma hasta 15 piezas de esa etapa.
Devuelve `{ cliente, total{por_grabar, por_editar, por_publicar}, por_cliente[], etapa, piezas[], nota }`.

### `ia_chat_mkt_analisis(p_cliente, p_semana)` · tool `mkt_analisis_semanal`
Análisis semanal de la IA de Marketing (`crm_ia_analisis`, 138): el más reciente de cada cliente, o el de la semana (lunes a domingo) que contiene `p_semana`. Hasta 6 clientes, texto recortado a 3000 caracteres.
Devuelve `{ cliente, semana_pedida, analisis[{cliente_id, semana, estado, texto, nota}], nota }`.

## Qué hace `ia-preguntar` con esto

- Gate: `ia_chat_acceso()` (cualquier rol con usuario). Las consultas se llaman con el token del usuario; con la secret key no hay `auth.uid()` y cortan con `42501`.
- 14 herramientas en total: 4 de Producto, 3 de Marketing, 3 de Ventas y 4 de Finanzas. Las tools de Ventas y Finanzas usan los nombres de la tabla de `dystopia-finanzas/docs/dystopita-herramientas.md`.
- El widget manda `{ pregunta, programa, app }` (`app`: `producto`, `marketing`, `ventas` o `finanzas`). Es solo contexto para el prompt: no restringe herramientas ni clientes. `ia_uso` registra la app (`marketing` se guarda como `crm`) con `funcion = 'chat_interno'`.
- Si una herramienta devuelve `42501` o `22023`, el modelo recibe el mensaje y lo explica; si la función SQL no existe todavía (migración sin correr) recibe "esa consulta todavía no está instalada".
- Resultados de más de 14.000 caracteres se recortan con una marca.

## Orden de despliegue

1. Correr 157 (Fathom / modalidad), 158 (Ventas y Finanzas) y 159, en ese orden, evitando :00/:15/:30/:45 y las 9:00.
2. `supabase functions deploy ia-preguntar --no-verify-jwt`.
3. Copiar a las otras apps los archivos compartidos del widget (ver ESTADO-APP.md).
