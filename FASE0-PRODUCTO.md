# FASE 0 · PRODUCTO (Seguimiento)

Relevamiento del 02/10/2026. Solo lectura: xlsx de los maestros, planillas
de Finanzas y formularios de onboarding vía Chrome, migraciones 001 a 039
del repo. Sin nombres de alumnos en este documento.

Alcance: **liam, teo, agus, lucas**. Mauro (Academia Apple) y Julia (B4)
quedan afuera, decisión del 02/10.

---

## 1. Diferencia clave con Ventas y Finanzas

- **Producto no tiene sync.** Ningún maestro se lee cada 15 min. Liam se
  importó una sola vez (040) y el resto nunca entró.
- Consecuencia buena: no hay que "proteger el corte en la sync". El corte
  es solo avisarle al CSM "desde hoy cargás en la app".
- Consecuencia mala: **liam ya está divergiendo.** El maestro de BPF se
  modificó el 01/10, después de la importación del 29/09. Lo que cargó el
  CSM desde el 29 no está en la app. Ver decisión D1.

---

## 2. Qué planillas alimentan Producto y quién las escribe

| cliente | planilla | dueño del archivo | quién escribe | estado |
|---|---|---|---|---|
| liam | Maestro de Clientes BPF (1 hoja) | cuenta de Liam | CSM de liam, a mano | **viva**, editada 01/10 |
| teo | MAESTRO DE CLIENTES - NEC ("Hoja 1") | Nacho, carpeta PRODUCTO - NEC | CSM de teo | viva, editada 30/09 |
| agus | MAESTRO DE CLIENTES - DCAC | Nacho | CSM de agus | viva, editada 30/09, **contaminada** (ver 5.1) |
| lucas | Maestro de Clientes - auletta | Nacho, CCYVDAA - Producto | CSM de lucas | **abandonada** desde 06/07 |
| lucas | PAGOS (Finanzas) col. L a O | Finanzas | fórmula + CSM | M a O nunca usadas |
| liam | Cuotas (Finanzas, gid 677639895) | Morello | a mano | 7 alumnos |
| teo | CUOTAS (CRM, gid 93797201) | | nadie | vacía, solo estructura y KPIs |

- Ningún maestro tiene filas que entren solas. Las fechas con hora en
  BPF (82 de 134) son de un pegado masivo, no de una automatización.
- No hay indicios de GHL ni de otra automatización escribiendo filas.
  Apps Script no lo pude verificar (el historial no abrió con la cuenta
  de Nacho). Antes de cortar cada cliente, mirar Extensiones > Apps Script.

---

## 3. Mapa columna por columna

Leyenda del destino: **✓** ya existe en la app · **+** falta · **✗** no se migra.

### 3.1 liam · Maestro BPF (134 filas reales)

| col | encabezado | uso real | destino |
|---|---|---|---|
| A | Tipo de Cliente | desplegable, 5 valores | ✓ `cs_clientes.producto_id` → `cs_productos` |
| B, C | NOMBRE, APELLIDO | | ✓ `nombre` (se juntan) |
| D | Celular | 80 de 134 | ✓ `telefono` |
| E | Días Restantes | fórmula **editada a mano fila por fila** (ver 5.3) | ✓ calculado de `fecha_fin` |
| F, G, H, I | 21D, 10D, 5D, 0D | checkboxes: 62, 49, **1**, 0 marcados | ✓ `aviso_1_at`, `aviso_2_at` (ver D2) |
| J | ESTADO DE LA LLAMADA | 7 valores, mapeo ya hecho en 040 | ✓ `cs_renovaciones.estado` + `resell_producto` |
| K | Contexto Actual Renovacion | texto, 18 filas | ✓ `cs_seguimientos.resumen` |
| L | ¿Lo saqué de App? | 0 marcados | ✗ |
| M, N | ¿Lo saqué de Skool / WPP? | 26 / 21 | ✓ accionables de cierre (039) |
| O | TESTIMONIO | PITCHIADO 7, GRABADO 3, NO QUIERE 2 | ✓ `testimonio` · **falta "coordinado"** (D3) |
| P | JoinedDate | | ✓ `fecha_inicio` |
| Q | ¿Le pedí referidos? (primeras 2 sem) | 33 de 87 | + accionable de plantilla (verificar D4) |
| R, S, T | FUP 1 (sem 2-4), FUP 3 (4-8), FUP 3 (8-12) | 12, 0, 0 | + accionables de plantilla (D4) |

Desplegables: A `BPF Grupal, BPF 1-1 4/6/12 Meses, Gestion de Capital`.
J tiene **4 listas distintas según la fila**: algunas suman
`Resell 9 meses (cuotas)` y `Resell 9 meses (3 de 400)`. O tiene
`COORDINADO`, que nadie usó todavía.

### 3.2 teo · NEC (121 filas reales en 305)

| col | encabezado | uso real | destino |
|---|---|---|---|
| A | FECHA DE CARGA | 11/03 a 19/09 | ✓ `fecha_inicio` |
| B | PROGRAMA | GRUPAL 103, 1 a 1 18 | ✓ producto |
| C, D | Nombre, Número | número 73 de 121 | ✓ |
| E | CONCEPTO | FEE, PIF, 1RA CUOTA... | ✗ es de Finanzas (D5) |
| F, G, H | Semana 2 / 4 / 6 | 2, 1, 1 marcados | + accionables de plantilla |
| I | Días restantes | `A+120-HOY` para todos | ✓ duración 120 |
| J, K | Aviso 21 días, Pitch 10-5 | **0 marcados** | ✓ avisos |
| L, M | ESTADO, CONTEXTO | **0 filas** | ✓ renovación + seguimiento |
| N, O, P | Saqué de WPP / DS / Skool | 0 / 2 / 2 | ✓ cierre · **+ "Sacar de Discord"** |

### 3.3 agus · DCAC (780 filas, ver contaminación en 5.1)

| col | encabezado | uso real | destino |
|---|---|---|---|
| A | FECHA DE CARGA | 02/01 a 18/09 | ✓ `fecha_inicio` |
| B | PROGRAMA | **20 variantes** (ver 4.2) | ✓ producto + catálogo de alias |
| C, D | Nombre, Número | número 253 de 780 | ✓ |
| E, F, G | Referidos semana 0-2 / 2-4 / 4-6 | **vacías** | + accionables (si los quieren) |
| H | Días restantes WPP | fórmula por programa (1 mes 30, 3 meses / GRUPAL / 1 a 1 90, 45 días, Skool "No aplica") | ✓ duración por producto |
| I, J | Aviso 1 (21 d), Aviso 2 (7 d) | 83 y 63 marcados | ✓ avisos con 21 y 7 |
| K | ESTADO | multi-selección (ver 4.3) | ✓ renovación |
| L | Contexto | 40 filas | ✓ seguimiento |
| M, N | ¿Lo saqué de WPP / Skool? | 99 / 0 | ✓ cierre |
| P a S | Grupo creado 1-1, Call 1-1 #1 a #3 | **vacías** | ✓ `cs_calls` |

### 3.4 lucas · Maestro auletta (149) y PAGOS L a O (127)

- Maestro: FECHA, PROGRAMA (GRUPAL 85, 1 a 1 64), Nombre, Número,
  CONCEPTO, Días restantes (90 días), Aviso 30-21, Pitch 10-5, ESTADO.
  Avisos y estado: **1 fila** cargada en total. Última carga 06/07.
- PAGOS L a O: días restantes con fórmula (90 días), avisos y ESTADO
  vacíos en las 127 filas.
- Conclusión: lucas **no tiene seguimiento real**. Se arranca de cero en
  la app con la lista de alumnos (D9).

### 3.5 Cuotas

- **liam (Cuotas):** 7 alumnos, hasta 3 cuotas con Monto, Fecha y Estado
  (`pagado`, `pendiente`, `Pausado`) + Contexto. El color de la celda tiene
  significado (rojo vencida, amarillo por vencer, verde pagada, gris
  pausado) y se pierde al leerla. Fechas en 4 formatos, algunas sin año.
  Hoy la sincroniza Finanzas a `fin_cuotas`.
- **teo (CUOTAS):** vacía. Sirve como referencia: total a cobrar, cobrado,
  no paga, % de cobro en cuotas y en dinero.
- **lucas:** no tiene hoja de cuotas.
- Ninguna cuota apunta al pago que la saldó.

---

## 4. Vocabularios a normalizar

Mismo criterio que la 064: el texto crudo se guarda y al lado va el valor
de catálogo.

### 4.1 Producto por cliente (propuesta de `cs_productos`)

| cliente | productos | duración |
|---|---|---|
| liam | ya cargados (039) | 120 / 180 / 365 / 120 / 365 |
| teo | Grupal, 1 a 1 | 120 y 120 |
| agus | Grupal, 1 a 1, 1 mes, 3 meses, 45 días, Skool | 90, 90, 30, 90, 45, sin vencimiento |
| lucas | Grupal, 1 a 1 | 90 y 90 |

- **Skool en agus no vence.** Hoy `duracion_dias > 0` es obligatorio: hace
  falta permitir "sin vencimiento" (D6).

### 4.2 Alias de PROGRAMA en agus

`seña`, `seña 3 meses`, `Seña 1 mes`, `1era seña 3 meses`,
`1era cuota 3 meses`, `Primera cuota 3 meses`, `1 cuota 3 meses`,
`2da cuota 3 meses`, `Completa 3 meses`, `completa 1 mes`, `skool` / `Skool`.
Mezclan **producto** con **estado de pago**. El producto va a
`cs_productos` y el pago queda para Finanzas.

### 4.3 ESTADO (renovación)

| valor en planilla | clientes | mapeo propuesto |
|---|---|---|
| RESELL - UPSELL / RENUEVA / UPSELL | todos | renovado (+ tipo) |
| NO RENUEVA | agus, teo | no_renovado |
| NO CONTESTA | agus, teo | contactado, sin respuesta |
| SEGUIMIENTO | agus | contactado |
| Pausado / PAUSADO | agus, teo | estado del cliente `pausado` |
| COMUNIDAD / comunidad | agus | producto Comunidad, no estado (A2) |
| `!` | agus | **desconocido** (A2) |

- En agus el ESTADO es **multi-selección**: "SEGUIMIENTO, NO RENUEVA",
  "NO CONTESTA, NO RENUEVA". Se toma el estado final (el más avanzado) y
  el resto va como historial.

---

## 5. Valores raros y problemas de datos

### 5.1 DCAC es una copia del archivo de Academia Apple

- Las dos planillas tienen la hoja con el **mismo gid (1448206904)**, cosa
  que solo pasa al duplicar un archivo.
- **303 filas** de DCAC coinciden en nombre y fecha con alumnos de mauro,
  entre enero y junio (las GRUPAL / 1 a 1 / COMUNIDAD de ese período).
- Si se importa así, agus hereda unos 300 clientes que no son suyos (A1).

### 5.2 Planillas que nadie llena

| campo | liam | teo | agus | lucas |
|---|---|---|---|---|
| Aviso 1 | 62 | 0 | 83 | 0 |
| Aviso 2 | 49 | 0 | 63 | 0 |
| Estado renovación | 91 | 0 | 122 | 1 |
| Seguimientos / FUP | 12 | 2 | 0 | 0 |
| Referidos | 33 | | 0 | |

- Copiar la grilla a la app no cambia esto. La carga tiene que **empujar**
  la tarea al CSM, no esperar que entre a completar columnas (sección 8).

### 5.3 Días restantes cargados a mano en liam

- Sobre 108 filas de "BPF 1-1 4 Meses": 49 con 120 días, **21 con 90**,
  29 con fórmula por regex, y sueltas con 30, 40, 150, 180, 200, 230 y
  "120 + 60".
- Lo más probable: extensiones y pausas cargadas en la fórmula. La app hoy
  calcula por producto y no las ve (A3).

### 5.4 Otros

- 2 filas con `#REF!` en la fórmula de días (fuera de alcance, eran de AA).
- agus: 2 fechas de carga escritas como texto.
- Teléfonos en 4 formatos (número sin prefijo, con 54 9, con guiones).

---

## 6. Onboarding hoy

- **Encuesta:** un Google Form por cliente, misma plantilla de 21 a 23
  preguntas. Datos de contacto y el resto de marketing y venta: perfil,
  canal, formato, temas, motivo de compra, objeciones, objetivo. Teo suma
  facturación y nicho.
- **Respuestas:**

  | cliente | respuestas | período | observación |
  |---|---|---|---|
  | liam | 55 | 21/07 a 01/10 | menos de la mitad de los clientes |
  | lucas | 23 | 13/07 a 25/09 | |
  | agus | ? | | **la hoja vinculada está borrada** (410) |
  | teo | ? | | no encontré la hoja de respuestas |

- Valentín usa las respuestas de liam para marketing (análisis de 44
  respuestas, 29/09) y hay transcripciones de las calls 1-1 de onboarding.
  No es un rediseño del form.
- **Entrega de Discord y Skool:** no existe en ningún lado. Es manual y no
  queda registro.

---

## 7. Qué ya cubre la app y qué falta

| necesidad | hoy en la app | falta |
|---|---|---|
| Alta de cliente con producto y fechas | ✓ 001, 039 | alta desde un pago de Finanzas (D4) |
| Maestro tipo planilla | ✓ 037 `cs_v_maestro` | |
| Avisos de renovación | ✓ 2 avisos por programa (039) | días configurables por cliente: 21/10, 21/7, 30-21/10-5 |
| Pipeline de resell | ✓ 037 | |
| Seguimientos | ✓ 038 | |
| Pausa | ✓ 039 | registrar el motivo |
| Testimonio | ✓ 039 | estado `coordinado` |
| Offboarding | ✓ WPP, Skool, testimonio | **Discord** (teo) |
| Accionables tipo FUP y referidos | plantilla por programa | cargar plantillas de teo, agus y lucas |
| Producto sin vencimiento | ✗ | Skool de agus |
| Onboarding: encuesta | formularios públicos (004) | pasar el form a la app o importar respuestas (D7) |
| Onboarding: checklist de accesos | ✗ | link único, pasos, Discord y Skool al completar |
| Cobranza de cuotas | ✗ | vista de solo lectura sobre `fin_cuotas` (D8) |
| Responsable del accionable | `bpf` o `cliente` | `bpf` es nombre de liam: generalizar a "equipo" |
| Clientes de teo, agus y lucas | ✗ | importación (como la 040) |
| Accesos del CSM | roles de `crm_members` | cuentas de los CSM por cliente (A5) |

---

## 8. Propuesta de carga: más rápida que la planilla

Hoy el CSM abre la planilla, busca la fila, marca un checkbox y escribe en
"Contexto". La app tiene que ahorrarle la búsqueda y el tipeo.

**1. Pantalla "Hoy" (la de entrada del CSM)**
- Una cola de tarjetas ordenada por urgencia: avisos de 21 y 10 días que
  vencen hoy, seguimientos con fecha cumplida, renovaciones sin contacto,
  onboarding sin terminar y offboarding pendiente.
- Cada tarjeta tiene sus botones: **Hecho**, **Registrar contacto** y
  **Reprogramar**. Un aviso de 21 días se resuelve en un clic, sin buscar
  la fila.
- Contador arriba ("12 para hoy, 3 atrasados"). Es lo que hoy ninguna
  planilla muestra.

**2. Registrar contacto en 5 segundos**
- Panel lateral, no un formulario aparte. Canal como chips (WhatsApp, call,
  mail), resultado como chips (contestó, no contesta, quiere renovar, no
  renueva) y una línea de texto opcional.
- El resultado mueve solo el pipeline de resell. Se termina el "SEGUIMIENTO,
  NO CONTESTA, NO RENUEVA" en una misma celda.
- Próximo contacto con botones +3 / +7 / +14 días.

**3. Alta sin doble tipeo**
- Hoy el CSM copia nombre, número y concepto desde Pagos. En la app,
  cuando Finanzas registra una venta nueva, aparece en "Hoy" como
  **"cliente nuevo para dar de alta"**, con los datos del pago ya
  cargados. Se elige el producto y listo.

**4. Ficha de un vistazo**
- Arriba: barra de tiempo del programa (inicio, avisos, fin, pausas) en
  vez de "Días restantes = -275" en rojo.
- Debajo: línea de tiempo de contactos y checklist de onboarding y
  offboarding con progreso.

**5. El maestro queda, pero como vista**
- La grilla de 037 sigue para ver todo junto y filtrar, con chips de color
  por estado. Se edita poco y en celda. La carga diaria va por "Hoy".

**6. Atajos**
- `J` / `K` para moverse en la cola, `C` para registrar contacto, `H` para
  hecho. El CSM que trabaja 40 alumnos por día no toca el mouse.

---

## 9. Decisiones

### Tuyas

- **D1. Liam está divergiendo.** El CSM sigue cargando en el Sheet desde
  la importación. Recomiendo cortar liam ya y hacer una sola importación
  de diferencias (lo editado desde el 29/09).
- **D2. Segundo aviso de liam.** En la app es 5 días, pero en la planilla
  el CSM marcó 10D 49 veces y 5D una sola. Recomiendo 21 y 10.
- **D3.** Agregar `coordinado` al testimonio, que está en el desplegable
  de BPF.
- **D4.** Alta de clientes desde los pagos de venta nueva de Finanzas.
  Además: confirmar si FUP y referidos ya están en la plantilla de liam.
  Lo verifico con una query.
- **D5.** CONCEPTO (FEE, PIF, cuotas) no se importa: es de Finanzas. Si
  hace falta verlo en la ficha, se lee de `fin_pagos` por la clave.
- **D6.** Producto sin vencimiento (Skool de agus).
- **D7. Encuesta de onboarding:** pasarla a formularios de la app (004) o
  seguir con Google Forms e importar. Recomiendo pasarla: la de agus hoy
  no guarda en ningún lado y Valentín la usa para marketing.
- **D8. Cuotas:** solo liam tiene datos (7 alumnos). Recomiendo una vista
  de cobranza de solo lectura sobre `fin_cuotas`, sin pantalla propia.
- **D9. Lucas:** arranca de cero desde la lista de alumnos del maestro de
  auletta más los pagos posteriores al 06/07. No hay historia que migrar.

### De la agencia (un solo mensaje)

- **A1.** DCAC tiene 303 alumnos de Academia Apple copiados. ¿Los borran
  ellos o los excluimos en la importación?
- **A2.** ¿Qué significa `!` en ESTADO? ¿COMUNIDAD es un producto o un
  estado?
- **A3.** En BPF hay días restantes cargados a mano (90, 150, 200, 230,
  "+60"). ¿Son extensiones o pausas? ¿Se respetan o se recalcula por
  producto?
- **A4.** agus cambió en julio de "1 mes / 3 meses" a "GRUPAL / 1 a 1".
  ¿Siguen vendiendo 1 mes, 45 días y Skool?
- **A5.** Nombre y mail del CSM de cada cliente, para crearles el acceso.
- **A6.** El form de onboarding de agus perdió su hoja de respuestas.
  ¿Desde cuándo? ¿Teo dónde guarda las suyas?
- **A7.** Pasos de onboarding: ¿qué tiene que completar el alumno antes
  de recibir Discord y Skool?
- **A8.** Webhook del canal de Discord (sigue pendiente).

---

## 10. Próximo paso

Con D1 a D9 respondidas armo PLAN-PRODUCTO.md por fases. La primera
migración es la **068**.
