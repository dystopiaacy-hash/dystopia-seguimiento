# Posibles fichas duplicadas del programa teo (propuesta, sin migración)

Estado: **completado con datos reales** (consulta corrida el 16/10/2026 sin cambios, solo SELECT). No se escribió ninguna migración: Joaquín decide primero.

## Cómo se buscaron los pares
Dentro de `cs_clientes` con `programa_id = 'teo'` (todos los estados, incluidos finalizado y baja), se junta un par si cumple AL MENOS una regla:
- `nombre`: mismo `cs_norm_nombre`.
- `email`: comparten algún mail (el principal o los de `cs_clientes_mails`).
- `telefono`: mismo `cs_norm_tel` (últimos 8 dígitos).
- `apellido_ini3`: mismo último término del nombre y las primeras 3 letras del primero (Kari/Karina, Mateo/Matteo, Soledad/Soledas).
- `parecido(x)`: similitud de trigramas del nombre completo normalizado >= 0.55 (equivale a distancia de edición chica; sin extensiones). Umbral en el CTE `cfg`: bajarlo trae más pares y más ruido.

## Criterio para proponer cuál ficha queda
En este orden, y siempre mirando la salida real:
1. Vigente: estado vivo (onboarding / activo / en_renovacion) con `fecha_fin` futura, frente a otra finalizado / baja o vencida.
2. Más historia útil: más `llamadas`, `vinculos_pagos` / `pagos`, `renovaciones_renovado`, `wins`.
3. Nombre bien escrito (el que coincide con el nombre del pago en Finanzas, si hay pagos vinculados).
4. Si empatan: la más antigua (`fecha_inicio`), porque suele ser la que ya tiene historial colgando.

## Cómo se clasifica
- **Seguro**: mismo email o mismo teléfono Y nombre casi igual (tipeo), sin superposición de fechas con vigencia en las dos.
- **Dudoso (pueden ser 2 personas)**: solo coincide el nombre parecido; o mismo teléfono/email pero nombres distintos (familiares, pareja, socios); o las dos están vigentes a la vez con productos o fechas distintas.

## Resumen (corrida 16/10/2026 por el jefe, consulta sin cambios, umbral 0.55)
- Pares encontrados: 25 (sobre 39 fichas distintas; varias fichas aparecen en más de un par).
- Seguros: 4 (pares 3, 4, 7, 19).
  - Par 3: queda `0eec993e` (pablo exequiel soraire), se cierra `7035e559`.
  - Par 4: queda `b9919b53` (Dayana Bustos/Maximiliano Juarez), se cierra `19c20b52`. La regla telefono no disparó (la B tiene dos teléfonos en el campo) pero el teléfono coincide a ojo.
  - Par 7: queda `1c8e3a88` (maria Florencia Martelleti, activa), se cierra `292f1982`.
  - Par 19: queda `4cafd013` (Pereyra Federico, activo), se cierra `90bc7cd1`.
- Dudosos: 21.
  - Ruido evidente, no fusionar: pares 5 y 6 (Agustín vs Agustín Muñoz / Agustin Naab), 24 (Gabriela vs Gabriel).
  - Probables dobles cargas pero el criterio no alcanza (solo nombre, o las dos vigentes): 1 (Gutierrez), 9-10-25 (trío Emiliozzi, quedaría `dd14d0fa`), 11 (Vazquez), 13-14-16 (trío Mizrahi, quedaría `220e7427`), 17 (Teo Sirichilo/Sirichiglio, mismas fechas exactas, quedaría `c5d4b039`), 18 (Soledad Rivero, mismo teléfono pero las dos activas, quedaría `e9b7d212`), 21 (Acosta), 23 (Inés y Lea).
  - Pueden ser personas distintas o grupos: 2 (Juan Ignacio / ... y Butros Asís), 8 y 15 (mismo teléfono que "Fer y Flor"), 12 (Teo Sorichiglio vs Sirichiglio, las dos activas con fechas distintas), 20 (Walter y Juan / walter y jose), 22 (Facundo Lacombe / ... Patrick Palma).
- Patrón a decidir: muchos pares son "Grupal finalizado" + "1 a 1 activo" de la misma persona (upgrade o renovación). Si en teo esas fichas son una por contrato a propósito, esos pares no son duplicados.
- Ninguna ficha de estos pares tiene llamadas (salvo `0eec993e`, 1), wins ni renovaciones: lo único que se movería son vínculos de pagos, accionables y teléfonos/mails.

## Un bloque por par

### Par 1 · DUDOSO · motivos: apellido_ini3, parecido(0.83)

| | Ficha A (`021dcdf6`) | Ficha B (`7622f87f`) |
|---|---|---|
| Nombre | Mateo Gutierrez | Matteo Gutierrez |
| Email | — | — |
| Teléfono | — | 54 9 11 6419 8662 |
| Estado | activo | finalizado |
| Fecha inicio / fin | 2026-09-28 / 2027-03-28 | 2026-05-21 / 2026-09-21 |
| Producto | 1 a 1 | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 1 (1) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-09-28 | 2026-05-21 |

- **Propongo que quede:** ficha `021dcdf6`
- **Por qué:** vigente (activo hasta 28/03/2027) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos y teléfono de 7622f87f
- **Duda:** solo coincide el nombre (sin mail ni teléfono en común). Muy probable misma persona: termina Grupal el 21/09 y arranca 1 a 1 el 28/09 (renovación/upgrade).

### Par 2 · DUDOSO · motivos: telefono

| | Ficha A (`0b5ac238`) | Ficha B (`d5d48d1c`) |
|---|---|---|
| Nombre | Juan Ignacio | Juan Ignacio Campoli y Butros Asís |
| Email | — | — |
| Teléfono | 3548415058 | 54 9 3548 41 5058 |
| Estado | finalizado | finalizado |
| Fecha inicio / fin | 2026-05-04 / 2026-09-04 | 2026-05-25 / 2026-09-25 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 2 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-04 | 2026-05-25 |

- **Propongo que quede:** ficha `0b5ac238`
- **Por qué:** ninguna vigente; más pagos (2 contra 1)
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de d5d48d1c
- **Duda:** la B son dos personas ("Juan Ignacio Campoli y Butros Asís"); mismo teléfono puede ser el de uno solo. Las dos Grupal superpuestas (04/05 y 25/05). Si se fusiona, conviene quedarse con el nombre completo.

### Par 3 · SEGURO · motivos: telefono, parecido(0.65)

| | Ficha A (`0eec993e`) | Ficha B (`7035e559`) |
|---|---|---|
| Nombre | pablo exequiel soraire | pablo exequiel |
| Email | — | — |
| Teléfono | 3813926885 | 3813926885 |
| Estado | finalizado | finalizado |
| Fecha inicio / fin | 2026-05-07 / 2026-09-07 | 2026-05-11 / 2026-09-11 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 1 (2026-07-16) | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 2 / 0 | 1 / 1 / 0 |
| Último pago | 2026-06-01 | 2026-05-11 |

- **Propongo que quede:** ficha `0eec993e`
- **Por qué:** ninguna vigente; más historia (1 llamada, 2 pagos) y nombre completo
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de 7035e559
- **Duda:** ninguna: mismo teléfono, nombre completo vs nombre sin apellido, las dos finalizadas.

### Par 4 · SEGURO · motivos: apellido_ini3, parecido(0.89)

| | Ficha A (`19c20b52`) | Ficha B (`b9919b53`) |
|---|---|---|
| Nombre | dayana bustos y Maximiliano Juárez | Dayana Bustos/Maximiliano Juarez |
| Email | — | — |
| Teléfono | 3541 595609 | 3541-595609/3541-521856 |
| Estado | finalizado | finalizado |
| Fecha inicio / fin | 2026-05-16 / 2026-09-16 | 2026-04-06 / 2026-08-06 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-16 | 2026-04-06 |

- **Propongo que quede:** ficha `b9919b53`
- **Por qué:** ninguna vigente; empatan en historia; la más antigua (06/04)
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de 19c20b52
- **Duda:** la regla telefono no disparó porque la B tiene dos teléfonos en el campo, pero el primero (3541-595609) es el de la A. Es la misma pareja; lo marco seguro a ojo. Fechas distintas (abr y may): puede ser una segunda inscripción.

### Par 5 · DUDOSO · motivos: parecido(0.57)

| | Ficha A (`1c66894c`) | Ficha B (`cfa5b801`) |
|---|---|---|
| Nombre | Agustín | Agustín Muñoz |
| Email | — | agustinmunoz1811@gmail.com |
| Teléfono | 54 9 2944 260488 | 3777232993 |
| Estado | activo | activo |
| Fecha inicio / fin | 2026-07-03 / 2026-11-03 | 2026-09-25 / 2027-01-25 |
| Producto | 1 a 1 | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 2 (1) | 1 (1) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 2 / 0 |
| Último pago | 2026-07-03 | 2026-09-30 |

- **Propongo que quede:** ninguna fusión por ahora
- **Por qué:** —
- **Qué hay que mover desde la que se cierra:** —
- **Duda:** RUIDO: "Agustín" sin apellido contra "Agustín Muñoz", teléfonos distintos, las dos vigentes a la vez. No fusionar.

### Par 6 · DUDOSO · motivos: parecido(0.62)

| | Ficha A (`1c66894c`) | Ficha B (`cfe7b58c`) |
|---|---|---|
| Nombre | Agustín | Agustin Naab |
| Email | — | naabagustin@gmail.com |
| Teléfono | 54 9 2944 260488 | 54 9 11 3652 7476 |
| Estado | activo | activo |
| Fecha inicio / fin | 2026-07-03 / 2026-11-03 | 2026-07-10 / 2026-11-10 |
| Producto | 1 a 1 | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 2 (1) | 1 (1) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-07-03 | 2026-07-10 |

- **Propongo que quede:** ninguna fusión por ahora
- **Por qué:** —
- **Qué hay que mover desde la que se cierra:** —
- **Duda:** RUIDO: "Agustín" contra "Agustin Naab", teléfonos distintos, productos distintos, las dos vigentes. No fusionar.

### Par 7 · SEGURO · motivos: telefono, parecido(0.88)

| | Ficha A (`1c8e3a88`) | Ficha B (`292f1982`) |
|---|---|---|
| Nombre | maria Florencia Martelleti | María Florencia Martelletti |
| Email | — | — |
| Teléfono | 54 9 11 3159 7050 | 54 9 11 3159 7050 |
| Estado | activo | finalizado |
| Fecha inicio / fin | 2026-05-26 / 2026-11-26 | 2026-05-22 / 2026-09-22 |
| Producto | 1 a 1 | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-26 | 2026-05-22 |

- **Propongo que quede:** ficha `1c8e3a88`
- **Por qué:** vigente (activo hasta 26/11) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de 292f1982
- **Duda:** misma persona (tipeo Martelleti/Martelletti, mismo teléfono). Ojo: Grupal 22/05 y 1 a 1 26/05 fueron vigentes a la vez; confirmar que no son dos compras distintas que se quieren mantener separadas. Ver también pares 8 y 15 (mismo teléfono que "Fer y Flor").

### Par 8 · DUDOSO · motivos: telefono

| | Ficha A (`1c8e3a88`) | Ficha B (`ec41a3d4`) |
|---|---|---|
| Nombre | maria Florencia Martelleti | Fer y Flor |
| Email | — | — |
| Teléfono | 54 9 11 3159 7050 | 54 9 11 3159 7050 |
| Estado | activo | activo |
| Fecha inicio / fin | 2026-05-26 / 2026-11-26 | 2026-06-18 / 2026-10-18 |
| Producto | 1 a 1 | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 1 (1) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-26 | 2026-06-18 |

- **Propongo que quede:** ninguna fusión por ahora
- **Por qué:** —
- **Qué hay que mover desde la que se cierra:** —
- **Duda:** mismo teléfono, nombres distintos ("Fer y Flor" = probablemente Florencia y su pareja). Las dos vigentes 1 a 1 con fechas distintas. Decide Joaquín.

### Par 9 · DUDOSO · motivos: apellido_ini3, parecido(0.68)

| | Ficha A (`1cfdc187`) | Ficha B (`dd14d0fa`) |
|---|---|---|
| Nombre | Karina Emiliozzi | Kari Emiliozzi |
| Email | — | — |
| Teléfono | — | — |
| Estado | finalizado | activo |
| Fecha inicio / fin | 2026-04-30 / 2026-08-30 | 2026-05-25 / 2026-11-25 |
| Producto | Grupal | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 2 / 0 | 1 / 1 / 0 |
| Último pago | 2026-04-30 | 2026-05-25 |

- **Propongo que quede:** ficha `dd14d0fa`
- **Por qué:** vigente (activo hasta 25/11) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de 1cfdc187
- **Duda:** solo nombre (sin mail ni teléfono). Muy probable misma persona (Kari/Karina). Trío con e0eb229f (pares 10 y 25): si se aprueba, queda dd14d0fa para las tres.

### Par 10 · DUDOSO · motivos: parecido(0.83)

| | Ficha A (`1cfdc187`) | Ficha B (`e0eb229f`) |
|---|---|---|
| Nombre | Karina Emiliozzi | Karina Emiliozi |
| Email | — | — |
| Teléfono | — | — |
| Estado | finalizado | finalizado |
| Fecha inicio / fin | 2026-04-30 / 2026-08-30 | 2026-03-27 / 2026-07-27 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 2 / 0 | 1 / 1 / 0 |
| Último pago | 2026-04-30 | 2026-03-27 |

- **Propongo que quede:** ficha `1cfdc187`
- **Por qué:** ninguna vigente; más pagos (2 contra 1)
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de e0eb229f
- **Duda:** solo nombre (tipeo Emiliozzi/Emiliozi). Trío: en conjunto queda dd14d0fa (par 9).

### Par 11 · DUDOSO · motivos: parecido(0.65)

| | Ficha A (`1d46c295`) | Ficha B (`6c4b50be`) |
|---|---|---|
| Nombre | Tomàs Vasquez | Tomas Vazquez |
| Email | — | — |
| Teléfono | — | — |
| Estado | activo | finalizado |
| Fecha inicio / fin | 2026-07-11 / 2026-11-11 | 2026-04-23 / 2026-08-23 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 1 (1) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 4 / 0 |
| Último pago | 2026-07-11 | 2026-04-29 |

- **Propongo que quede:** ficha `1d46c295`
- **Por qué:** vigente (activo hasta 11/11) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos (4 pagos) de 6c4b50be
- **Duda:** solo nombre (Vasquez/Vazquez), sin teléfono. Probable misma persona que renovó Grupal.

### Par 12 · DUDOSO · motivos: parecido(0.68)

| | Ficha A (`1ede642b`) | Ficha B (`c5d4b039`) |
|---|---|---|
| Nombre | Teo Sorichiglio | Teo Sirichiglio |
| Email | — | — |
| Teléfono | — | — |
| Estado | activo | activo |
| Fecha inicio / fin | 2026-09-17 / 2027-01-17 | 2026-08-29 / 2026-12-29 |
| Producto | 1 a 1 | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 1 (1) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-09-17 | 2026-08-29 |

- **Propongo que quede:** ninguna fusión por ahora
- **Por qué:** —
- **Qué hay que mover desde la que se cierra:** —
- **Duda:** las dos vigentes 1 a 1 con fechas distintas (17/09 y 29/08), Sorichiglio vs Sirichiglio. Trío con 3779d1ba (par 17). Confirmar con Joaquín.

### Par 13 · DUDOSO · motivos: parecido(0.55)

| | Ficha A (`220e7427`) | Ficha B (`345b1abf`) |
|---|---|---|
| Nombre | Meir Mizrahi | Shelomo Meir Mizrahi |
| Email | — | — |
| Teléfono | — | 54 9 11 3180 2463 |
| Estado | activo | finalizado |
| Fecha inicio / fin | 2026-08-05 / 2026-12-05 | 2026-05-21 / 2026-09-21 |
| Producto | 1 a 1 | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-08-05 | 2026-05-21 |

- **Propongo que quede:** ficha `220e7427`
- **Por qué:** vigente (activo hasta 05/12) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos y teléfono de 345b1abf
- **Duda:** solo nombre ("Meir Mizrahi" vs "Shelomo Meir Mizrahi"). Trío con 8616c138 (pares 14 y 16). Probable misma persona.

### Par 14 · DUDOSO · motivos: parecido(0.55)

| | Ficha A (`220e7427`) | Ficha B (`8616c138`) |
|---|---|---|
| Nombre | Meir Mizrahi | Shemolo Meir Mizrahi |
| Email | — | — |
| Teléfono | — | — |
| Estado | activo | finalizado |
| Fecha inicio / fin | 2026-08-05 / 2026-12-05 | 2026-05-04 / 2026-09-04 |
| Producto | 1 a 1 | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-08-05 | 2026-05-04 |

- **Propongo que quede:** ficha `220e7427`
- **Por qué:** vigente frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de 8616c138
- **Duda:** solo nombre. Trío Mizrahi: queda 220e7427.

### Par 15 · DUDOSO · motivos: telefono

| | Ficha A (`292f1982`) | Ficha B (`ec41a3d4`) |
|---|---|---|
| Nombre | María Florencia Martelletti | Fer y Flor |
| Email | — | — |
| Teléfono | 54 9 11 3159 7050 | 54 9 11 3159 7050 |
| Estado | finalizado | activo |
| Fecha inicio / fin | 2026-05-22 / 2026-09-22 | 2026-06-18 / 2026-10-18 |
| Producto | Grupal | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 1 (1) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-22 | 2026-06-18 |

- **Propongo que quede:** ninguna fusión por ahora
- **Por qué:** —
- **Qué hay que mover desde la que se cierra:** —
- **Duda:** mismo teléfono, nombres distintos (Martelletti vs "Fer y Flor"). Mismo grupo que los pares 7 y 8.

### Par 16 · DUDOSO · motivos: apellido_ini3, parecido(0.62)

| | Ficha A (`345b1abf`) | Ficha B (`8616c138`) |
|---|---|---|
| Nombre | Shelomo Meir Mizrahi | Shemolo Meir Mizrahi |
| Email | — | — |
| Teléfono | 54 9 11 3180 2463 | — |
| Estado | finalizado | finalizado |
| Fecha inicio / fin | 2026-05-21 / 2026-09-21 | 2026-05-04 / 2026-09-04 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-21 | 2026-05-04 |

- **Propongo que quede:** ficha `8616c138`
- **Por qué:** ninguna vigente; empatan; la más antigua (04/05)
- **Qué hay que mover desde la que se cierra:** vínculo de pagos y teléfono de 345b1abf
- **Duda:** tipeo Shelomo/Shemolo, pero sin mail ni teléfono en común (la B no tiene teléfono). Dos Grupal superpuestas (04/05 y 21/05). En el trío queda 220e7427.

### Par 17 · DUDOSO · motivos: parecido(0.58)

| | Ficha A (`3779d1ba`) | Ficha B (`c5d4b039`) |
|---|---|---|
| Nombre | Teo Sirichilo | Teo Sirichiglio |
| Email | — | — |
| Teléfono | — | — |
| Estado | activo | activo |
| Fecha inicio / fin | 2026-08-29 / 2026-12-29 | 2026-08-29 / 2026-12-29 |
| Producto | 1 a 1 | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 0 / 0 / 0 | 1 / 1 / 0 |
| Último pago | — | 2026-08-29 |

- **Propongo que quede:** ficha `c5d4b039`
- **Por qué:** empatan en vigencia, fechas y producto idénticos; c5d4b039 tiene el pago vinculado y 3779d1ba nada
- **Qué hay que mover desde la que se cierra:** nada (3779d1ba no tiene historia)
- **Duda:** solo nombre (sin mail ni teléfono), pero mismas fechas exactas y mismo producto: casi seguro doble carga. Revisar junto con 1ede642b (par 12).

### Par 18 · DUDOSO · motivos: telefono, apellido_ini3, parecido(0.67)

| | Ficha A (`3a115941`) | Ficha B (`e9b7d212`) |
|---|---|---|
| Nombre | Soledas Rivero | Soledad Rivero |
| Email | — | soledaddrivero13@gmail.com |
| Teléfono | 54 9 3435 619943 | 5493435619943 |
| Estado | activo | activo |
| Fecha inicio / fin | 2026-06-25 / 2026-10-25 | 2026-07-04 / 2026-11-04 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 2 (1) | 2 (1) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-06-25 | 2026-07-04 |

- **Propongo que quede:** ficha `e9b7d212`
- **Por qué:** las dos vigentes; empatan en historia; nombre bien escrito ("Soledad", "Soledas" es tipeo) y tiene email
- **Qué hay que mover desde la que se cierra:** vínculo de pagos y 2 accionables (1 abierto) de 3a115941
- **Duda:** por criterio queda dudoso porque las dos están vigentes a la vez (Grupal 25/06 y 04/07), pero mismo teléfono + tipeo: casi seguro misma persona cargada dos veces.

### Par 19 · SEGURO · motivos: telefono, parecido(0.74)

| | Ficha A (`4cafd013`) | Ficha B (`90bc7cd1`) |
|---|---|---|
| Nombre | Pereyra Federico | Pereyra Federico Uriel |
| Email | — | — |
| Teléfono | 54 9 2255 62 9456 | 54 9 2255 62 9456 |
| Estado | activo | finalizado |
| Fecha inicio / fin | 2026-07-01 / 2026-11-01 | 2026-06-11 / 2026-10-11 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 2 (1) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-07-01 | 2026-06-11 |

- **Propongo que quede:** ficha `4cafd013`
- **Por qué:** vigente (activo hasta 01/11) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de 90bc7cd1
- **Duda:** ninguna: mismo teléfono, mismo nombre con/sin segundo nombre.

### Par 20 · DUDOSO · motivos: apellido_ini3, parecido(0.63)

| | Ficha A (`7d87b1fd`) | Ficha B (`c7ccd35a`) |
|---|---|---|
| Nombre | Walter y Juan Herrero | walter y jose herrero |
| Email | — | — |
| Teléfono | — | — |
| Estado | activo | activo |
| Fecha inicio / fin | 2026-09-14 / 2027-01-14 | 2026-08-26 / 2026-12-26 |
| Producto | 1 a 1 | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 1 (1) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-09-14 | 2026-08-26 |

- **Propongo que quede:** ninguna fusión por ahora
- **Por qué:** —
- **Qué hay que mover desde la que se cierra:** —
- **Duda:** "Walter y Juan" vs "walter y jose": nombres del segundo distintos, las dos vigentes 1 a 1 con fechas distintas. Pueden ser dos inscripciones distintas. Decide Joaquín.

### Par 21 · DUDOSO · motivos: apellido_ini3, parecido(0.61)

| | Ficha A (`87cba207`) | Ficha B (`ff3f84de`) |
|---|---|---|
| Nombre | Santiago Acosta | Santi Acosta |
| Email | — | — |
| Teléfono | 54 9 3416 48 5459 | — |
| Estado | finalizado | activo |
| Fecha inicio / fin | 2026-05-27 / 2026-09-27 | 2026-07-12 / 2026-11-12 |
| Producto | Grupal | 1 a 1 |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 1 (1) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 5 / 0 | 1 / 3 / 0 |
| Último pago | 2026-06-13 | 2026-07-27 |

- **Propongo que quede:** ficha `ff3f84de`
- **Por qué:** vigente (activo hasta 12/11) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos (5 pagos) y teléfono de 87cba207
- **Duda:** solo nombre (Santiago/Santi Acosta), sin teléfono en la B. Probable misma persona que pasó de Grupal a 1 a 1.

### Par 22 · DUDOSO · motivos: parecido(0.55)

| | Ficha A (`a24af8ed`) | Ficha B (`e9954587`) |
|---|---|---|
| Nombre | facundo lacombe | Facundo Lacombe Patrick Palma |
| Email | — | — |
| Teléfono | — | 3876 04-6672 |
| Estado | finalizado | finalizado |
| Fecha inicio / fin | 2026-05-07 / 2026-09-07 | 2026-04-14 / 2026-08-14 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-07 | 2026-04-14 |

- **Propongo que quede:** ficha `e9954587`
- **Por qué:** ninguna vigente; empatan; la más antigua (14/04)
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de a24af8ed
- **Duda:** la B parece dos personas ("Facundo Lacombe" + "Patrick Palma"). Fechas distintas (abr y may).

### Par 23 · DUDOSO · motivos: parecido(0.63)

| | Ficha A (`b07c4dea`) | Ficha B (`d0ab664b`) |
|---|---|---|
| Nombre | Inés y Leandro | inés y Lea |
| Email | — | — |
| Teléfono | — | — |
| Estado | finalizado | activo |
| Fecha inicio / fin | 2026-03-27 / 2026-07-27 | 2026-06-20 / 2026-10-20 |
| Producto | 1 a 1 | (sin producto) |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 1 (1) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-03-27 | 2026-06-20 |

- **Propongo que quede:** ficha `d0ab664b`
- **Por qué:** vigente (activo hasta 20/10) frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de b07c4dea; de paso, cargarle producto a d0ab664b (está sin producto)
- **Duda:** solo nombre ("Inés y Leandro" / "inés y Lea"). Probable misma pareja renovada.

### Par 24 · DUDOSO · motivos: parecido(0.70)

| | Ficha A (`b14fcf17`) | Ficha B (`fd7da09a`) |
|---|---|---|
| Nombre | Gabriela | Gabriel |
| Email | — | — |
| Teléfono | — | 0221 409-6943 |
| Estado | finalizado | finalizado |
| Fecha inicio / fin | 2026-04-10 / 2026-08-10 | 2026-03-28 / 2026-07-28 |
| Producto | Grupal | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 2 / 0 |
| Último pago | 2026-04-10 | 2026-03-30 |

- **Propongo que quede:** ninguna fusión por ahora
- **Por qué:** —
- **Qué hay que mover desde la que se cierra:** —
- **Duda:** RUIDO: "Gabriela" vs "Gabriel" sin apellido; casi seguro dos personas. No fusionar.

### Par 25 · DUDOSO · motivos: parecido(0.55)

| | Ficha A (`dd14d0fa`) | Ficha B (`e0eb229f`) |
|---|---|---|
| Nombre | Kari Emiliozzi | Karina Emiliozi |
| Email | — | — |
| Teléfono | — | — |
| Estado | activo | finalizado |
| Fecha inicio / fin | 2026-05-25 / 2026-11-25 | 2026-03-27 / 2026-07-27 |
| Producto | 1 a 1 | Grupal |
| Llamadas (última) | 0 | 0 |
| Wins | 0 | 0 |
| Accionables (abiertos) | 0 (0) | 0 (0) |
| Renovaciones (renovado) | 0 (0) | 0 (0) |
| Vínculos de pagos / pagos / cuotas | 1 / 1 / 0 | 1 / 1 / 0 |
| Último pago | 2026-05-25 | 2026-03-27 |

- **Propongo que quede:** ficha `dd14d0fa`
- **Por qué:** vigente frente a finalizada
- **Qué hay que mover desde la que se cierra:** vínculo de pagos de e0eb229f
- **Duda:** trío Emiliozzi (pares 9 y 10): queda dd14d0fa.


## Cuando Joaquín decida
Usar el mismo patrón de las migraciones **164** y **165** (el número lo asigna el jefe; no elegirlo):
- **Migración A (como la 164):** transacción única, lock de las tablas juntas, guarda por prefijo de uuid (cada prefijo resuelve exactamente una ficha, los pares son los aprobados, programa teo), respaldos `cs_bak_<n>_*` con RLS, la sobrante pasa a `finalizado` con `campos_extra.cierre<n>` (trigger `cs_trg_after_cierre` apagado durante el UPDATE, sin offboarding), se mueven seguimientos, renovaciones cerradas, accionables manuales, mails extra, alias, vínculo `fin_cs_vinculo` y notas. Verificación dentro de la transacción, controles y vuelta atrás comentados.
- **Migración B (como la 165):** mover llamadas y todo lo que cuelga de ellas (accionables y recursos de llamada, transcripciones, candidatas a duda, wins, satisfacción, menciones, onboardings, consultorías) de la cerrada a la vigente, con los triggers `*_before` apagados solo dentro de la transacción, una sentencia con CTEs, respaldo e informe de duplicadas.
- Ojo: en la 164 los pares se cerraban a mano por prefijo; acá pasar los prefijos salidos de la columna `ficha` de la consulta, nunca nombres.
- Las 164 y 165 están sin correr: si siguen sin correr cuando se decida, numerar la de teo después de ellas y no mezclar programas.
