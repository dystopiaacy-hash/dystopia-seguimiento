/* Genera la carga de datos de agus (DCAC) desde el MAESTRO DE CLIENTES - DCAC: hojas "Maestro de Clientes"
   y "Fuera del maestro". Mismo método que scripts/generar-importacion-liam.mjs (la 080 de liam).
   Sin dependencias: solo Node.

   Uso (desde la carpeta del repo):
     npm run agus:generar -- --numero 215 [archivo.xlsx | maestro.csv] [--fuera fuera.csv] [--hoy AAAA-MM-DD]
     npm run agus:inspeccionar -- [archivo.xlsx | maestro.csv]      (columnas, valores distintos, controles)

   - --numero: el número de migración que asigna el jefe (nombra el archivo y los respaldos cs_bak_<n>_agus_*).
   - Sin archivo usa los CSV de insumos del jefe (jefe/insumos/dcac-2026-10-23). Un .xlsx lee las dos hojas por nombre.
   - --hoy: fecha en que se bajó la planilla (sale sola: moda de fecha_fin - días restantes).
   - Salida: migraciones/<numero>-agus-dcac-datos.sql  (TIENE DATOS PERSONALES: está en .gitignore; no subir ni pegar en chats).
   Correr ANTES la migración de estructura (210-agus-dcac-estructura.sql). */
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { leerXlsx } from './xlsx-leer.mjs';

const INSUMOS = 'C:/Users/Admin/Downloads/jefe/insumos/dcac-2026-10-23';
const args = process.argv.slice(2);
const flag = n => { const i = args.indexOf(n); return i >= 0 ? args.splice(i, 2)[1] : null; };
const inspeccionar = args.includes('--inspeccionar');
if (inspeccionar) args.splice(args.indexOf('--inspeccionar'), 1);
const numero = flag('--numero');
let hoy = flag('--hoy');
let fueraArg = flag('--fuera');
const archivo = args[0] || `${INSUMOS}/maestro__Maestro_de_Clientes.csv`;
if (!inspeccionar && !/^\d{1,4}$/.test(numero || '')) {
  console.error('Falta --numero <número de migración> (lo asigna el jefe). Ej: --numero 215');
  process.exit(1);
}

/* ---------- lectura ---------- */
function serialAFecha(n) {
  return new Date(Date.UTC(1899, 11, 30) + Math.floor(n) * 86400000).toISOString().slice(0, 10);
}
const celdaTxt = v => v == null ? '' : typeof v === 'object' ? serialAFecha(v.fecha)
  : typeof v === 'boolean' ? (v ? 'TRUE' : 'FALSE') : String(v);

/* CSV UTF-8. Cada fila lleva su número real en la hoja (nFila, contando también las filas vacías). */
function parsearCsv(texto) {
  const t = texto.replace(/^﻿/, '');
  const filas = [];
  let fila = [], celda = '', comillas = false, n = 0;
  const cerrar = () => {
    fila.push(celda); celda = ''; n++;
    if (fila.some(x => x.trim() !== '')) filas.push(Object.assign(fila, { nFila: n }));
    fila = [];
  };
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (comillas) {
      if (c === '"' && t[i + 1] === '"') { celda += '"'; i++; }
      else if (c === '"') comillas = false;
      else celda += c;
    } else if (c === '"') comillas = true;
    else if (c === ',') { fila.push(celda); celda = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && t[i + 1] === '\n') i++; cerrar(); }
    else celda += c;
  }
  if (celda !== '' || fila.length) cerrar();
  return filas;
}

const norm = h => String(h).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '');
const q = s => (s == null || s === '' ? 'null' : `'${String(s).replace(/'/g, "''")}'`);
const qb = b => (b ? 'true' : 'false');

function leerHojas() {
  if (/\.xlsx$/i.test(archivo)) {
    const libro = leerXlsx(archivo);
    const matriz = h => (libro[h] || []).map((f, i) => Object.assign(Array.from(f || [], celdaTxt), { nFila: i + 1 }))
      .filter(f => f.some(x => x.trim() !== ''));
    const hoja = pref => Object.keys(libro).find(h => norm(h).startsWith(pref));
    const hm = hoja('maestrodeclientes'), hf = hoja('fueradelmaestro');
    if (!hm) { console.error(`No encontré la hoja "Maestro de Clientes". Hojas: ${Object.keys(libro).join(', ')}`); process.exit(1); }
    return { maestro: matriz(hm), fuera: hf ? matriz(hf) : [] };
  }
  if (!fueraArg) {
    const cand = join(dirname(archivo), 'maestro__Fuera_del_maestro.csv');
    if (existsSync(cand)) fueraArg = cand;
  }
  return {
    maestro: parsearCsv(readFileSync(archivo, 'utf8')),
    fuera: fueraArg ? parsearCsv(readFileSync(fueraArg, 'utf8')) : []
  };
}

/* ---------- valores ---------- */
const TRUE = new Set(['TRUE', 'VERDADERO', 'SI', 'SÍ', 'X', '1', 'YES']);
const aBool = v => TRUE.has(String(v ?? '').trim().toUpperCase());

function aFecha(v) {
  const s = String(v ?? '').trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);
  if (m) return `${m[3].length === 2 ? '20' + m[3] : m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  return null;
}
const dia = iso => Date.UTC(+iso.slice(0, 4), +iso.slice(5, 7) - 1, +iso.slice(8, 10)) / 86400000;
const sumar = (iso, n) => new Date((dia(iso) + n) * 86400000).toISOString().slice(0, 10);

/* PROGRAMA de la hoja -> [producto de cs_productos de agus, duración en días (null = sin vencimiento)]. */
const PRODUCTOS = {
  grupal: ['Grupal', 90], '1a1': ['1 a 1', 90], '3meses': ['3 meses', 90], '1mes': ['1 mes', 30],
  '45dias': ['45 días', 45], skool: ['Skool', null], comunidad: ['Comunidad', 90],
  resellgrupal: ['Resell Grupal', 120], resell1a1: ['Resell 1 a 1', 120]
};
const SIN_VENCIMIENTO_FIN = '2099-12-31';
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/i;

/* ESTADO de la hoja (multi-selección "A, B"): se toma el más avanzado.
   RESELL - UPSELL queda como 'resell' pero NO crea renovación (ver informe); '!' = no responde los mensajes. */
const ESTADOS = {
  norenueva: 'churn', nocontesta: 'contactado', seguimiento: 'contactado',
  resellupsell: 'resell', renueva: 'resell', upsell: 'resell', resell: 'resell', pausado: 'pausado', comunidad: null
};
const PESO = { sin_resell: 0, contactado: 1, churn: 2, resell: 3, pausado: 4 };
function parsearEstado(txt, avisos, fila) {
  let cat = 'sin_resell', noResponde = false;
  for (const crudo of String(txt || '').split(',')) {
    const t = crudo.trim();
    if (!t) continue;
    if (t === '!') { noResponde = true; continue; }
    const n = norm(t);
    if (!(n in ESTADOS)) { avisos.push(`fila ${fila}: ESTADO "${t}" sin mapeo, se ignora`); continue; }
    const c = ESTADOS[n];
    if (c && PESO[c] > PESO[cat]) cat = c;
  }
  return { cat, noResponde };
}

/* ---------- Maestro de Clientes ---------- */
const { maestro, fuera } = leerHojas();
if (maestro.length < 2) { console.error('La hoja Maestro de Clientes no tiene filas.'); process.exit(1); }
const enc = maestro[0].map(norm);
const col = (...pref) => enc.findIndex(h => pref.some(p => h.startsWith(p)));
const C = {
  fecha: col('fechadecarga'), prog: col('programa'), nombre: col('nombredelalumno', 'nombre'), mail: col('mail'),
  num: col('numero'), fin: col('fechafin'), dias: col('diasrestantes'), a1: col('aviso14'), a2: col('aviso2'),
  estado: col('estado'), ctx: col('contexto'), wpp: col('losaquedelgrupodewpp', 'losaquedewpp'),
  skool: col('losaquedeskool'), concepto: col('concepto'), grupo: col('grupocreado'),
  ref1: col('referidossemana02'), ref2: col('referidossemana24'), ref3: col('referidossemana46'),
  seg1: col('seguimiento1'), seg2: col('seguimiento2'), baja: col('avisobaja')
};
for (const k of ['fecha', 'prog', 'nombre', 'fin', 'a1', 'a2', 'estado', 'ctx', 'concepto']) {
  if (C[k] < 0) { console.error(`No encontré la columna "${k}" (encabezados: ${maestro[0].join(' | ')})`); process.exit(1); }
}
const usadas = new Set(Object.values(C).filter(i => i >= 0));
const sinMapeo = maestro[0].map((h, i) => [h, i]).filter(([h, i]) => h.trim() && !usadas.has(i));
const vacias = Object.entries({ ref1: 'Referidos Semana 0-2', ref2: 'Referidos Semana 2-4', ref3: 'Referidos Semana 4-6',
  seg1: 'SEGUIMIENTO 1', seg2: 'SEGUIMIENTO 2', baja: 'AVISO BAJA' }).filter(([k]) => C[k] >= 0);

const avisos = [];
const filas = [];
let separadores = 0, sinNombreConDatos = 0;
const g = (f, i) => (i >= 0 ? String(f[i] ?? '').trim() : '');
for (const f of maestro.slice(1)) {
  const nFila = f.nFila;
  const nombre = g(f, C.nombre).replace(/\s+/g, ' ');
  const fechaTxt = g(f, C.fecha), progTxt = g(f, C.prog);
  if (!nombre && !fechaTxt && !progTxt) {
    if (g(f, 0)) separadores++;   // ENERO, FEBRERO...: filas separadoras, no son alumnos
    continue;
  }
  if (!nombre) { sinNombreConDatos++; avisos.push(`fila ${nFila}: tiene datos pero no nombre, se omite`); continue; }
  const inicio = aFecha(fechaTxt);
  if (!inicio) { avisos.push(`fila ${nFila}: sin fecha de carga válida ("${fechaTxt}"), se omite`); continue; }
  const prod = PRODUCTOS[norm(progTxt)];
  if (!prod) { avisos.push(`fila ${nFila}: PROGRAMA "${progTxt}" ${progTxt ? 'sin mapeo' : 'vacío'}, se omite`); continue; }
  const [producto, dur] = prod;

  let fin = aFecha(g(f, C.fin));
  if (dur === null) fin = SIN_VENCIMIENTO_FIN;
  else if (!fin) { fin = sumar(inicio, dur); avisos.push(`fila ${nFila}: sin fecha fin, se calcula inicio + ${dur} días`); }
  if (fin < inicio) { avisos.push(`fila ${nFila}: fecha fin anterior al inicio, se omite`); continue; }
  const diasTxt = g(f, C.dias);
  const dias = /^-?\d+$/.test(diasTxt) ? Number(diasTxt) : null;

  const email = g(f, C.mail);
  if (email && !EMAIL.test(email)) avisos.push(`fila ${nFila}: mail inválido, se carga sin mail`);
  const { cat, noResponde } = parsearEstado(g(f, C.estado), avisos, nFila);
  const concepto = g(f, C.concepto);
  const wpp = g(f, C.wpp);
  const checks = {};
  if (concepto && concepto.toLowerCase() !== 's/d') checks.x_concepto = concepto;   // s/d = sin dato: no se guarda
  if (wpp) checks.x_saque_wpp = wpp;
  if (aBool(g(f, C.skool))) checks.x_saque_skool = true;
  if (aBool(g(f, C.grupo))) checks.x_grupo_creado_1_1 = true;
  if (noResponde) checks.x_no_responde = true;
  let ctx = g(f, C.ctx);
  if (['resell', 'upsell'].includes(ctx.toLowerCase())) ctx = '';   // ya está en Concepto

  filas.push({
    fila: nFila, nombre, telefono: g(f, C.num), email: EMAIL.test(email) ? email : '', producto, inicio, fin, dias,
    aviso1: aBool(g(f, C.a1)), aviso2: aBool(g(f, C.a2)), categoria: cat, contexto: ctx, checks,
    skool: aBool(g(f, C.skool)), wpp: ['si', 'sí'].includes(wpp.toLowerCase())
  });
}

if (!hoy) {
  const cuenta = new Map();
  for (const r of filas) if (r.dias !== null && r.producto !== 'Skool') {
    const h = sumar(r.fin, -r.dias);
    cuenta.set(h, (cuenta.get(h) || 0) + 1);
  }
  hoy = [...cuenta.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || null;
  if (!hoy) { console.error('No pude deducir la fecha de la planilla: pasá --hoy AAAA-MM-DD'); process.exit(1); }
  console.log(`(--hoy no indicado: deducido de fecha fin - días restantes = ${hoy})`);
}
if (!/^\d{4}-\d{2}-\d{2}$/.test(hoy)) { console.error('--hoy debe ser AAAA-MM-DD'); process.exit(1); }
const dispares = filas.filter(r => r.dias !== null && r.producto !== 'Skool' && sumar(r.fin, -r.dias) !== hoy).length;
if (dispares) avisos.push(`${dispares} filas con fecha fin - días restantes distinto de ${hoy} (días escritos a mano o planilla de otro día); se usa la fecha fin`);

/* ---------- controles de la planilla ---------- */
/* Decidido por Joaquín (23/10/2026): se importan TODOS los alumnos, incluidos los de enero a junio que podrían ser de
   Mauro (no se excluye ni se marca nada por eso). Repetidos exactos (mismo nombre + fecha de carga): entra UNO solo.
   "Probables repetidos" (mismo alumno y producto a 60 días o menos, otra fecha): solo se cuentan, se importan todos. */
const clave = r => `${r.nombre.toLowerCase().replace(/\s+/g, ' ')}|${r.inicio}`;
const vistos = new Set(), repetidas = [];
const unicas = filas.filter(r => { const k = clave(r); if (vistos.has(k)) { repetidas.push(r.fila); return false; } vistos.add(k); return true; });
/* Mismo alumno (nombre normalizado + producto) con otra fila a 60 días o menos: probable fila repetida a mano. */
const porAlumno = new Map();
for (const r of unicas) {
  const k = `${norm(r.nombre)}|${r.producto}`;
  (porAlumno.get(k) || porAlumno.set(k, []).get(k)).push(r);
}
const probables = [];
for (const lista of porAlumno.values()) {
  lista.sort((a, b) => a.inicio.localeCompare(b.inicio));
  for (let i = 1; i < lista.length; i++) if (dia(lista[i].inicio) - dia(lista[i - 1].inicio) <= 60) probables.push(lista[i].fila);
}

const opciones = { x_concepto: new Set(), x_saque_wpp: new Set() };
for (const r of unicas) for (const k of Object.keys(opciones)) if (r.checks[k]) opciones[k].add(r.checks[k]);

/* ---------- Fuera del maestro ---------- */
const filasFuera = [];
if (fuera.length > 1) {
  const e2 = fuera[0].map(norm);
  const c2 = (...pref) => e2.findIndex(h => pref.some(p => h.startsWith(p)));
  const F = {
    fecha: c2('fechadecarga'), prog: c2('programa'), nombre: c2('nombredelalumno', 'nombre'), mail: c2('mail'),
    num: c2('numero'), estado: c2('estado'), ctx: c2('contexto'), motivo: c2('motivo')
  };
  const resto = fuera[0].map((h, i) => [h, i]).filter(([h, i]) => h.trim() && !Object.values(F).includes(i));
  for (const f of fuera.slice(1)) {
    const extra = {};
    for (const [h, i] of resto) { const v = g(f, i); if (v && v !== 'FALSE' && v !== 'False') extra[norm(h)] = v; }
    const fila = {
      fila: f.nFila, fecha: aFecha(g(f, F.fecha)), prog: g(f, F.prog), nombre: g(f, F.nombre), mail: g(f, F.mail),
      num: g(f, F.num), estado: g(f, F.estado), ctx: g(f, F.ctx), motivo: g(f, F.motivo), extra
    };
    if (fila.nombre || fila.motivo) filasFuera.push(fila);
  }
}

/* ---------- inspección ---------- */
function resumenConsola() {
  console.log(`Maestro: ${maestro.length - 1} filas leídas; ${separadores} separadores de mes; ${filas.length} alumnos válidos `
    + `(${repetidas.length} repetidos exactos nombre+fecha, ${unicas.length} únicos); Fuera del maestro: ${filasFuera.length} filas.`);
  const porProd = {};
  for (const r of unicas) porProd[r.producto] = (porProd[r.producto] || 0) + 1;
  console.log('Por producto:', Object.entries(porProd).map(([k, v]) => `${k} ${v}`).join(', '));
  const porCat = {};
  for (const r of unicas) porCat[r.categoria] = (porCat[r.categoria] || 0) + 1;
  console.log('Estado de resell:', Object.entries(porCat).map(([k, v]) => `${k} ${v}`).join(', '));
  console.log(`Opciones de Concepto: ${[...opciones.x_concepto].join(' | ')}. De WPP: ${[...opciones.x_saque_wpp].join(' | ')}.`);
  console.log(`Probables filas repetidas (mismo alumno y producto a 60 días o menos de otra fila): ${probables.length} -> filas ${probables.join(', ')}`);
  console.log(`Columnas de la planilla sin mapeo: ${sinMapeo.map(([h]) => h).join(', ') || 'ninguna'}.`);
  console.log(`Columnas mapeadas pero vacías en todas las filas: ${vacias.filter(([k]) => !unicas.some(r => String(maestro.find(x => x.nFila === r.fila)?.[C[k]] ?? '').trim())).map(([, n]) => n).join(', ') || 'ninguna'}.`);
  const meses = {};
  for (const r of unicas) {
    if (r.checks.x_concepto === '2da cuota' || ['Resell', 'Upsell'].includes(r.checks.x_concepto) || /^resell/i.test(r.producto)) continue;
    const m = r.inicio.slice(0, 7);
    (meses[m] ||= {})[r.producto] = ((meses[m] || {})[r.producto] || 0) + 1;
  }
  console.log('Altas por mes y producto (para comparar con la hoja Resumen):');
  for (const m of Object.keys(meses).sort()) console.log(`  ${m}: ${Object.entries(meses[m]).map(([k, v]) => `${k} ${v}`).join(', ')}`);
  if (avisos.length) { console.log('A REVISAR:'); avisos.forEach(a => console.log('  - ' + a)); }
}
if (inspeccionar) { resumenConsola(); process.exit(0); }

/* ---------- SQL ---------- */
const N = numero;
const filasSql = unicas.map(r => `  (${r.fila}, ${q(r.nombre)}, ${q(r.telefono)}, ${q(r.email)}, ${q(r.producto)}, '${r.inicio}', '${r.fin}', `
  + `${qb(r.aviso1)}, ${qb(r.aviso2)}, '${r.categoria}', ${q(r.contexto)}, ${q(JSON.stringify(r.checks))}::jsonb, ${qb(r.skool)}, ${qb(r.wpp)})`).join(',\n');
const fueraSql = filasFuera.map(f => `  (${f.fila}, ${f.fecha ? `'${f.fecha}'` : 'null'}, ${q(f.prog)}, ${q(f.nombre)}, ${q(f.mail)}, ${q(f.num)}, `
  + `${q(f.estado)}, ${q(f.ctx)}, ${q(f.motivo)}, ${q(JSON.stringify(f.extra))}::jsonb)`).join(',\n');
const lista = s => [...s].map(x => q(x)).join(', ');
const archivoCorto = archivo.split(/[\\/]/).pop();

const sql = `-- =====================================================================
-- ${N}-agus-dcac-datos.sql  ·  PRODUCTO: Maestro de agus (DCAC) al día con la planilla
-- =====================================================================
-- GENERADO por scripts/generar-importacion-agus.mjs desde ${archivoCorto}
-- (${unicas.length} alumnos, ${filasFuera.length} filas de "Fuera del maestro"; planilla del ${hoy}). TIENE DATOS PERSONALES:
-- está en .gitignore (migraciones/*-agus-dcac-datos.sql). No lo subas ni lo pegues en chats.
--
-- ORDEN: antes, la migración de estructura de agus (210-agus-dcac-estructura.sql). Después este archivo, DOS veces:
--   1) tal cual: es un SIMULACRO. Termina con un error que trae el resumen y no guarda nada.
--   2) con el parámetro aplicar = 'si' (sección 0): guarda.
-- No usar entre :00, :15, :30 y :45 ni a las 9:00.
--
-- Reglas: la planilla manda (es la última foto). Se usa la FECHA FIN de la planilla (no se recalcula por producto);
-- Skool no vence (fecha fin 2099-12-31). Un alumno de la planilla que ya está en la app (mismo nombre y fecha de carga)
-- se actualiza; si no está, se crea. NO se borra ningún cliente de la app que no esté en la planilla (se lista en
-- cs_bak_${N}_agus_solo_app). Lo que pisa un dato que ya tenía la app queda en cs_bak_${N}_agus_pisados y la fila
-- anterior completa en cs_bak_${N}_agus_clientes (vuelta atrás).
-- ESTADO de la hoja: NO RENUEVA -> renovación "no renovó"; NO CONTESTA / SEGUIMIENTO -> renovación "contactado";
-- Pausado -> pausado; "!" -> casilla "No responde"; RESELL - UPSELL NO crea renovación (cambiaría la fecha fin y el
-- contador del alumno): se informa. El estado del alumno sale de la fecha fin (activo / finalizado), no del churn.
-- =====================================================================
begin;
set local lock_timeout = '8s';

lock table public.cs_clientes, public.cs_renovaciones, public.cs_maestro_columnas
  in share row exclusive mode;

-- 0. PARÁMETROS
drop table if exists pg_temp.imp_param;
create temp table imp_param (clave text primary key, valor text not null);
insert into imp_param values ('aplicar', 'no'), ('hoy', '${hoy}');   -- cambiá 'no' por 'si' para guardar

create or replace function pg_temp.imp_ts(d date) returns timestamptz
language sql stable as $$
  select least((d + time '12:00') at time zone 'America/Argentina/Buenos_Aires', now())
$$;

-- 1. PLANILLA
drop table if exists pg_temp.imp_csv;
create temp table imp_csv (
  fila int, nombre text not null, telefono text, email text, producto text not null,
  fecha_inicio date not null, fecha_fin date not null, aviso_1 boolean, aviso_2 boolean, categoria text,
  contexto text, checks jsonb not null, sacado_skool boolean, sacado_wpp boolean
);
insert into imp_csv values
${filasSql || "  (0, '', null, null, '', current_date, current_date, false, false, 'sin_resell', null, '{}'::jsonb, false, false)"};
${unicas.length ? '' : 'delete from imp_csv;'}

drop table if exists pg_temp.imp_fuera;
create temp table imp_fuera (
  fila int, fecha_carga date, producto_raw text, nombre text, mail text, numero text,
  estado text, contexto text, motivo text, extra jsonb not null
);
${filasFuera.length ? `insert into imp_fuera values\n${fueraSql};` : '-- (la planilla no trae "Fuera del maestro")'}

drop table if exists pg_temp.imp_log;
create temp table imp_log (clave text primary key, n int not null);

-- 2. CONTROLES PREVIOS (frenan sin tocar nada)
do $$
declare
  v_txt text;
begin
  if not exists (select 1 from public.cs_programas where id = 'agus') then
    raise exception 'No existe el programa agus.';
  end if;
  if to_regclass('public.cs_fuera_maestro') is null then
    raise exception 'Falta correr la migración de estructura de agus (tabla cs_fuera_maestro).';
  end if;
  select string_agg(k, ', ') into v_txt
  from unnest(array['x_saque_wpp', 'x_saque_skool', 'x_concepto', 'x_grupo_creado_1_1', 'x_no_responde']) k
  where not exists (select 1 from public.cs_maestro_columnas c
                     where c.programa_id = 'agus' and c.clave = k and not c.archivada);
  if v_txt is not null then
    raise exception 'Faltan columnas del Maestro de agus (migración de estructura): %', v_txt;
  end if;
  select string_agg(distinct s.producto, ', ') into v_txt
  from imp_csv s
  where not exists (select 1 from public.cs_productos pr where pr.programa_id = 'agus' and pr.nombre = s.producto);
  if v_txt is not null then
    raise exception 'Productos de la planilla que no están en cs_productos de agus: %. Corré la migración de estructura. Los que tiene: %', v_txt,
      (select string_agg(nombre, ', ') from public.cs_productos where programa_id = 'agus');
  end if;
end $$;

-- Opciones nuevas que trae la planilla (Concepto, WPP): se suman a la lista de la columna.
update public.cs_maestro_columnas c
   set opciones = public.cs_maestro_opciones_limpias(c.opciones || to_jsonb(array[${lista(opciones.x_concepto) || "''"}]::text[])),
       updated_at = now()
 where c.programa_id = 'agus' and c.clave = 'x_concepto' and c.tipo = 'opcion';
update public.cs_maestro_columnas c
   set opciones = public.cs_maestro_opciones_limpias(c.opciones || to_jsonb(array[${lista(opciones.x_saque_wpp) || "''"}]::text[])),
       updated_at = now()
 where c.programa_id = 'agus' and c.clave = 'x_saque_wpp' and c.tipo = 'opcion';

-- 3. FILAS RESUELTAS (una por nombre + fecha de carga). Si el alumno ya está en la app, cliente_id lo identifica.
drop table if exists pg_temp.imp;
create temp table imp as
with base as (
  select distinct on (lower(btrim(s.nombre)), s.fecha_inicio) s.*, pr.id as producto_id
  from imp_csv s
  join public.cs_productos pr on pr.programa_id = 'agus' and pr.nombre = s.producto
  order by lower(btrim(s.nombre)), s.fecha_inicio, s.fila
)
select b.*, c.id as cliente_id, (c.id is null) as era_nuevo,
       (select valor::date from imp_param where clave = 'hoy') as hoy,
       b.fecha_fin as fin,
       (select aviso_1_dias from public.cs_programas where id = 'agus') as a1_dias,
       (select aviso_2_dias from public.cs_programas where id = 'agus') as a2_dias
from base b
left join lateral (
  select x.id from public.cs_clientes x
  where x.programa_id = 'agus' and lower(btrim(x.nombre)) = lower(btrim(b.nombre)) and x.fecha_inicio = b.fecha_inicio
  order by x.created_at limit 1
) c on true;

alter table imp add column estado_alta text;
update imp set estado_alta = case when categoria = 'pausado' then 'pausado'
                                  when fin >= hoy then 'activo' else 'finalizado' end;

-- 4. RESPALDOS (con RLS y sin políticas, como los demás cs_bak_*)
create table if not exists public.cs_bak_${N}_agus_clientes as
  select now() as respaldado_at, c.* from public.cs_clientes c where false;
create table if not exists public.cs_bak_${N}_agus_pisados (
  respaldado_at timestamptz not null default now(), cliente_id uuid, campo text, valor_app text, valor_planilla text
);
create table if not exists public.cs_bak_${N}_agus_solo_app (
  respaldado_at timestamptz not null default now(), cliente_id uuid, nombre text, fecha_inicio date, estado text, producto text
);
revoke all on table public.cs_bak_${N}_agus_clientes from public, anon, authenticated;
revoke all on table public.cs_bak_${N}_agus_pisados from public, anon, authenticated;
revoke all on table public.cs_bak_${N}_agus_solo_app from public, anon, authenticated;
alter table public.cs_bak_${N}_agus_clientes enable row level security;
alter table public.cs_bak_${N}_agus_pisados enable row level security;
alter table public.cs_bak_${N}_agus_solo_app enable row level security;

-- 5. CLIENTES NUEVOS (como 040 / 080; los triggers de 001 / 039 hacen lo suyo)
do $$
declare
  v_n int;
begin
  insert into public.cs_clientes
    (programa_id, nombre, telefono, email, fecha_inicio, fecha_fin, estado, producto_id, nota_csm,
     aviso_1_at, aviso_2_at, pausado_desde, campos_extra, created_by)
  select 'agus', i.nombre, nullif(btrim(i.telefono), ''), nullif(btrim(i.email), ''), i.fecha_inicio, i.fin, i.estado_alta, i.producto_id,
         nullif(i.contexto, ''),
         case when i.aviso_1 then pg_temp.imp_ts(least(i.fin - i.a1_dias, i.hoy)) end,
         case when i.aviso_2 then pg_temp.imp_ts(least(i.fin - i.a2_dias, i.hoy)) end,
         case when i.estado_alta = 'pausado' then public.cs_hoy() end,
         i.checks, null
  from imp i
  where i.era_nuevo
  order by i.fila;
  get diagnostics v_n = row_count;
  insert into imp_log values ('clientes_nuevos', v_n);

  update imp i set cliente_id = c.id
    from public.cs_clientes c
   where i.era_nuevo and c.programa_id = 'agus'
     and lower(btrim(c.nombre)) = lower(btrim(i.nombre)) and c.fecha_inicio = i.fecha_inicio;
end $$;

-- 6. CLIENTES QUE YA ESTABAN: qué cambia, qué pisa, respaldo y una sola actualización por cliente
drop table if exists pg_temp.imp_upd;
create temp table imp_upd as
select i.*, c.telefono as t_app, c.email as e_app, c.producto_id as p_app, c.fecha_fin as f_app, c.estado as est_app,
       c.nota_csm as n_app, c.campos_extra as x_app, c.aviso_1_at as a1_app, c.aviso_2_at as a2_app,
       case
         when i.categoria = 'pausado' and c.estado in ('onboarding', 'activo', 'en_renovacion') then 'pausado'
         when i.categoria <> 'pausado' and c.estado = 'pausado' then 'activo'
         when c.estado = 'finalizado' and i.fin >= i.hoy then 'activo'
         else c.estado end as est_nuevo
from imp i
join public.cs_clientes c on c.id = i.cliente_id
where not i.era_nuevo
  and (   c.producto_id is distinct from i.producto_id
       or c.fecha_fin is distinct from i.fin
       or (nullif(btrim(i.telefono), '') is not null and c.telefono is distinct from nullif(btrim(i.telefono), ''))
       or (nullif(btrim(i.email), '') is not null and c.email is distinct from nullif(btrim(i.email), ''))
       or (nullif(i.contexto, '') is not null and position(i.contexto in coalesce(c.nota_csm, '')) = 0)
       or (i.aviso_1 and c.aviso_1_at is null) or (i.aviso_2 and c.aviso_2_at is null)
       or (c.campos_extra || i.checks) is distinct from c.campos_extra
       or (i.categoria = 'pausado' and c.estado in ('onboarding', 'activo', 'en_renovacion'))
       or (i.categoria <> 'pausado' and c.estado = 'pausado')
       or (c.estado = 'finalizado' and i.fin >= i.hoy));

drop table if exists pg_temp.imp_pisa;
create temp table imp_pisa (cliente_id uuid, campo text, valor_app text, valor_planilla text);
insert into imp_pisa
select u.cliente_id, 'telefono', u.t_app, btrim(u.telefono) from imp_upd u
 where nullif(btrim(u.telefono), '') is not null and u.t_app is not null and btrim(u.t_app) <> btrim(u.telefono)
union all
select u.cliente_id, 'email', u.e_app, btrim(u.email) from imp_upd u
 where nullif(btrim(u.email), '') is not null and u.e_app is not null and lower(btrim(u.e_app)) <> lower(btrim(u.email))
union all
select u.cliente_id, 'producto', (select nombre from public.cs_productos where id = u.p_app), u.producto from imp_upd u
 where u.p_app is not null and u.p_app is distinct from u.producto_id
union all
select u.cliente_id, 'fecha_fin', u.f_app::text, u.fin::text from imp_upd u
 where u.f_app is distinct from u.fin
union all
select u.cliente_id, 'estado', u.est_app, u.est_nuevo from imp_upd u
 where u.est_nuevo is distinct from u.est_app
union all
select u.cliente_id, 'campo ' || k.key, u.x_app ->> k.key, k.value #>> '{}' from imp_upd u
  cross join lateral jsonb_each(u.checks) k
 where u.x_app ? k.key and (u.x_app -> k.key) is distinct from k.value;

do $$
declare
  v_n int;
begin
  insert into public.cs_bak_${N}_agus_clientes
    select now(), c.* from public.cs_clientes c where c.id in (select cliente_id from imp_upd);
  insert into public.cs_bak_${N}_agus_pisados (cliente_id, campo, valor_app, valor_planilla)
    select cliente_id, campo, valor_app, valor_planilla from imp_pisa;

  update public.cs_clientes c set
    telefono   = coalesce(nullif(btrim(u.telefono), ''), c.telefono),
    email      = coalesce(nullif(btrim(u.email), ''), c.email),
    producto_id = u.producto_id,
    fecha_fin  = u.fin,
    nota_csm   = case when nullif(u.contexto, '') is null or position(u.contexto in coalesce(c.nota_csm, '')) > 0
                      then c.nota_csm
                      else u.contexto || coalesce(' · ' || c.nota_csm, '') end,
    aviso_1_at = case when u.aviso_1 and c.aviso_1_at is null
                      then pg_temp.imp_ts(least(u.fin - u.a1_dias, u.hoy)) else c.aviso_1_at end,
    aviso_2_at = case when u.aviso_2 and c.aviso_2_at is null
                      then pg_temp.imp_ts(least(u.fin - u.a2_dias, u.hoy)) else c.aviso_2_at end,
    campos_extra = c.campos_extra || u.checks,
    estado     = u.est_nuevo
  from imp_upd u
  where c.id = u.cliente_id;
  get diagnostics v_n = row_count;
  insert into imp_log values ('clientes_actualizados', v_n);
end $$;

-- 7. PIPELINE DE RENOVACIÓN (NO RENUEVA y NO CONTESTA / SEGUIMIENTO; RESELL - UPSELL no crea nada)
do $$
declare
  v_n int;
begin
  -- 7a. Alumnos nuevos
  insert into public.cs_renovaciones
    (programa_id, cliente_id, estado, iniciada_at, resultado_at, motivo, created_by)
  select 'agus', i.cliente_id,
         case i.categoria when 'churn' then 'no_renovado' else 'contactado' end,
         case when i.categoria = 'contactado' then now() else pg_temp.imp_ts(least(i.fin, i.hoy)) end,
         case when i.categoria = 'contactado' then null else pg_temp.imp_ts(least(i.fin, i.hoy)) end,
         case when i.categoria = 'churn' then 'Otro: no renueva según la planilla de DCAC (importación)' end,
         null
  from imp i
  where i.era_nuevo and i.cliente_id is not null and i.categoria in ('churn', 'contactado')
  order by i.fila;
  get diagnostics v_n = row_count;
  insert into imp_log values ('renovaciones_nuevas', v_n);

  -- 7b. Existentes con pipeline abierto y la planilla dice NO RENUEVA: se cierra como no renovado.
  update public.cs_renovaciones r set
    estado = 'no_renovado',
    motivo = coalesce(r.motivo, 'Otro: no renueva según la planilla de DCAC (importación)')
  from imp i
  where not i.era_nuevo and r.cliente_id = i.cliente_id and public.cs_ren_abierta(r.estado) and i.categoria = 'churn';
  get diagnostics v_n = row_count;
  insert into imp_log values ('pipeline_cerrado', v_n);

  -- 7c. Existentes sin pipeline abierto y la planilla dice "contactado": se abre.
  insert into public.cs_renovaciones (programa_id, cliente_id, estado, iniciada_at, created_by)
  select 'agus', i.cliente_id, 'contactado', now(), null
  from imp i
  join public.cs_clientes c on c.id = i.cliente_id
  where not i.era_nuevo and i.categoria = 'contactado' and c.estado not in ('baja', 'finalizado')
    and not exists (select 1 from public.cs_renovaciones r where r.cliente_id = i.cliente_id and public.cs_ren_abierta(r.estado));
  get diagnostics v_n = row_count;
  insert into imp_log values ('pipeline_abierto', v_n);
end $$;

-- 8. "¿Lo saqué de Skool / WPP?" = ítem de cierre completado, si ya existe
do $$
declare
  v_n int;
begin
  update public.cs_accionables a set estado = 'completado'
  from imp i
  where i.cliente_id = a.cliente_id and a.estado <> 'completado'
    and ((i.sacado_skool and a.plantilla_key like 'cierre:cierre\\_skool:%')
      or (i.sacado_wpp and a.plantilla_key like 'cierre:cierre\\_whatsapp:%'));
  get diagnostics v_n = row_count;
  insert into imp_log values ('cierres_completados', v_n);
end $$;

-- 9. FUERA DEL MAESTRO (se pisa por número de fila: volver a correr no duplica)
do $$
declare
  v_n int;
begin
  insert into public.cs_fuera_maestro (programa_id, fila_origen, fecha_carga, producto_raw, nombre, mail, numero, estado, contexto, motivo, extra)
  select 'agus', f.fila, f.fecha_carga, f.producto_raw, f.nombre, f.mail, f.numero, f.estado, f.contexto, f.motivo, f.extra
  from imp_fuera f
  on conflict (programa_id, fila_origen) do update
    set fecha_carga = excluded.fecha_carga, producto_raw = excluded.producto_raw, nombre = excluded.nombre,
        mail = excluded.mail, numero = excluded.numero, estado = excluded.estado, contexto = excluded.contexto,
        motivo = excluded.motivo, extra = excluded.extra;
  get diagnostics v_n = row_count;
  insert into imp_log values ('fuera_del_maestro', v_n);
end $$;

-- 10. LO QUE ESTÁ EN LA APP Y NO EN LA PLANILLA (no se toca; queda listado)
insert into public.cs_bak_${N}_agus_solo_app (cliente_id, nombre, fecha_inicio, estado, producto)
select c.id, c.nombre, c.fecha_inicio, c.estado, pr.nombre
from public.cs_clientes c
left join public.cs_productos pr on pr.id = c.producto_id
where c.programa_id = 'agus'
  and not exists (select 1 from imp i where i.cliente_id = c.id);

-- 11. CONTROLES DUROS + SIMULACRO
do $$
declare
  v_msg text;
  v_sin int;
begin
  select count(*) into v_sin from imp where cliente_id is null;
  if v_sin > 0 then
    raise exception '% filas de la planilla quedaron sin cliente en la base.', v_sin;
  end if;
  select format(
    'RESUMEN. Filas de la planilla: %s (únicas por nombre y fecha de carga). Clientes nuevos: %s. Actualizados: %s. '
    || 'Renovaciones nuevas: %s, pipeline cerrado: %s, abierto: %s. Cierres completados: %s. Fuera del maestro: %s filas. '
    || 'EN LA APP Y NO EN LA PLANILLA (no se tocan): %s, de las cuales %s tienen el mismo nombre que una fila de la planilla con otra fecha (posible duplicado). '
    || 'PISAN un dato que ya tenía la app: %s en %s clientes (por campo: %s). '
    || 'Planilla con RESELL - UPSELL (no crea renovación): %s.',
    (select count(*) from imp),
    (select n from imp_log where clave = 'clientes_nuevos'),
    (select n from imp_log where clave = 'clientes_actualizados'),
    (select n from imp_log where clave = 'renovaciones_nuevas'),
    (select n from imp_log where clave = 'pipeline_cerrado'),
    (select n from imp_log where clave = 'pipeline_abierto'),
    (select n from imp_log where clave = 'cierres_completados'),
    (select n from imp_log where clave = 'fuera_del_maestro'),
    (select count(*) from public.cs_bak_${N}_agus_solo_app s where s.respaldado_at >= now() - interval '1 minute'),
    (select count(*) from public.cs_bak_${N}_agus_solo_app s
      where s.respaldado_at >= now() - interval '1 minute' and exists (select 1 from imp i where lower(btrim(i.nombre)) = lower(btrim(s.nombre)))),
    (select count(*) from imp_pisa), (select count(distinct cliente_id) from imp_pisa),
    coalesce((select string_agg(x.campo || ' ' || x.n, ', ' order by x.campo) from (select campo, count(*) n from imp_pisa group by campo) x), 'ninguno'),
    (select count(*) from imp where categoria = 'resell')
  ) into v_msg;
  if (select valor from imp_param where clave = 'aplicar') <> 'si' then
    raise exception 'SIMULACRO (no se guardó nada). %', v_msg;
  end if;
  raise notice '%', v_msg;
end $$;

commit;


-- =====================================================================
-- CONTROLES (después de aplicar; de a uno)
-- =====================================================================
-- C1. Conteos de agus.
--   select count(*) as clientes,
--          count(*) filter (where estado in ('activo', 'en_renovacion')) as vivos,
--          count(*) filter (where estado = 'pausado') as pausados,
--          count(*) filter (where estado in ('finalizado', 'baja')) as finalizados
--     from public.cs_clientes where programa_id = 'agus';
--
-- C2. Por producto (comparar con la hoja Resumen).
--   select pr.nombre, count(*) as alumnos,
--          count(*) filter (where c.estado in ('activo', 'en_renovacion') and c.fecha_fin >= public.cs_hoy()) as con_fecha_fin_vigente
--     from public.cs_clientes c join public.cs_productos pr on pr.id = c.producto_id
--    where c.programa_id = 'agus' group by 1 order by 2 desc;
--
-- C3. EN LA APP Y NO EN LA PLANILLA (no se borró nada). Revisar uno por uno.
--   select * from public.cs_bak_${N}_agus_solo_app order by nombre;
--
-- C4. LO QUE PISÓ un dato que ya tenía la app (valor de la app vs valor de la planilla).
--   select c.nombre, p.campo, p.valor_app, p.valor_planilla
--     from public.cs_bak_${N}_agus_pisados p join public.cs_clientes c on c.id = p.cliente_id order by p.campo, c.nombre;
--
-- C5. Muestra de 20 alumnos con sus columnas nuevas.
--   select nombre, email, telefono, fecha_inicio, fecha_fin, estado, campos_extra
--     from public.cs_clientes where programa_id = 'agus' order by random() limit 20;
--
-- C6. Skool sin vencimiento (fecha fin 2099-12-31, estado activo).
--   select estado, min(fecha_fin), max(fecha_fin), count(*) from public.cs_clientes c
--     join public.cs_productos pr on pr.id = c.producto_id where c.programa_id = 'agus' and pr.nombre = 'Skool' group by 1;
--
-- C7. Renovaciones creadas por la carga.
--   select estado, count(*) from public.cs_renovaciones where programa_id = 'agus' group by 1;
--
-- C8. Hoja "Fuera del maestro".
--   select motivo, count(*) from public.cs_fuera_maestro where programa_id = 'agus' group by 1 order by 2 desc;
--
-- C9. Posibles duplicados contra "Clientes nuevos" de Hoy (altas desde pagos): mismo nombre normalizado más de una vez.
--   select lower(btrim(nombre)) as nombre, count(*) from public.cs_clientes
--    where programa_id = 'agus' group by 1 having count(*) > 1 order by 2 desc limit 50;
--
-- VUELTA ATRÁS (solo para esta carga; los clientes nuevos se reconocen por no estar en el respaldo de los actualizados):
-- begin;
--   -- 1) devolver los actualizados a como estaban
--   update public.cs_clientes c set telefono = b.telefono, email = b.email, producto_id = b.producto_id, fecha_fin = b.fecha_fin,
--          estado = b.estado, nota_csm = b.nota_csm, aviso_1_at = b.aviso_1_at, aviso_2_at = b.aviso_2_at, campos_extra = b.campos_extra
--     from public.cs_bak_${N}_agus_clientes b where b.id = c.id;
--   -- 2) borrar los creados por la carga: los de agus que no están en el respaldo ni en cs_bak_${N}_agus_solo_app y se crearon después de ese respaldo
--   --    (revisar la lista antes de borrar; las renovaciones y llamadas cuelgan por cascada)
--   -- select id, nombre from public.cs_clientes where programa_id = 'agus'
--   --   and id not in (select id from public.cs_bak_${N}_agus_clientes) and id not in (select cliente_id from public.cs_bak_${N}_agus_solo_app)
--   --   and created_at >= (select min(respaldado_at) - interval '5 minutes' from public.cs_bak_${N}_agus_solo_app);
-- commit;
`;

mkdirSync('migraciones', { recursive: true });
const salida = `migraciones/${N}-agus-dcac-datos.sql`;
writeFileSync(salida, sql, 'utf8');
resumenConsola();
console.log(`OK ${salida}`);
