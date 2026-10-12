/* Genera la actualización del Maestro de liam (080) leyendo el xlsx directo.
   Sin dependencias: solo Node (lector de xlsx propio en scripts/xlsx-leer.mjs).

   Uso (desde la carpeta del repo):
     npm run liam:generar -- [archivo.xlsx|.csv] [--hoy AAAA-MM-DD] [--hoja <nombre>]
     npm run liam:inspeccionar -- [archivo.xlsx]     (hojas, encabezados y valores distintos)

   - Sin archivo usa el xlsx de insumos del jefe. Un .csv (UTF-8) también se acepta.
   - --hoy es la fecha en que se guardó la planilla: "Días Restantes" es una fórmula contra HOY(),
     así que fin = hoy + días. Si falta, usa la fecha de modificación del archivo.
   - --hoja: por defecto, la hoja con encabezados de Maestro (nombre + días restantes).
   - Salida: datos/080-actualizar-liam-<hoy>.sql (datos/ está en .gitignore: tiene datos personales).
   Reglas de Nacho: los días cargados a mano se respetan (no se recalculan por producto);
   "!" en ESTADO = no responde los mensajes; COMUNIDAD es un producto, no un estado. */
import { readFileSync, writeFileSync, statSync, mkdirSync } from 'node:fs';
import { leerXlsx } from './xlsx-leer.mjs';

const XLSX_INSUMO = 'C:/Users/Admin/Downloads/jefe/insumos/liam-septiembre/Maestro de Clientes BPF.xlsx';
const args = process.argv.slice(2);
const flag = n => { const i = args.indexOf(n); return i >= 0 ? args.splice(i, 2)[1] : null; };
const inspeccionar = args.includes('--inspeccionar');
if (inspeccionar) args.splice(args.indexOf('--inspeccionar'), 1);
const hojaPedida = flag('--hoja');
let hoy = flag('--hoy');
const archivo = args[0] || XLSX_INSUMO;
if (!hoy) {
  const m = statSync(archivo).mtime;
  hoy = `${m.getFullYear()}-${String(m.getMonth() + 1).padStart(2, '0')}-${String(m.getDate()).padStart(2, '0')}`;
  console.log(`(--hoy no indicado: uso la fecha de modificación del archivo, ${hoy})`);
}
if (!/^\d{4}-\d{2}-\d{2}$/.test(hoy)) { console.error('--hoy debe ser AAAA-MM-DD'); process.exit(1); }

/* ---------- xlsx -> matriz de textos ---------- */
function serialAFecha(n) {
  const d = new Date(Date.UTC(1899, 11, 30) + Math.floor(n) * 86400000);
  return d.toISOString().slice(0, 10);
}
const celdaTxt = v => v == null ? '' : typeof v === 'object' ? serialAFecha(v.fecha)
  : typeof v === 'boolean' ? (v ? 'TRUE' : 'FALSE') : String(v);

function filasDeXlsx(ruta) {
  const libro = leerXlsx(ruta);
  /* Cada fila guarda su número real en la hoja (f.nFila), para los avisos. */
  const matriz = h => (libro[h] || []).map((f, i) => Object.assign(Array.from(f || [], celdaTxt), { nFila: i + 1 }))
    .filter(f => f.some(x => x.trim() !== ''));
  if (inspeccionar) {
    for (const h of Object.keys(libro)) {
      const m = matriz(h);
      console.log(`\n== Hoja "${h}": ${m.length} filas`);
      if (!m.length) continue;
      const ini = m.findIndex(f => f.filter(x => x.trim()).length >= 4);
      const enc = m[Math.max(ini, 0)];
      console.log(`Encabezados (fila ${Math.max(ini, 0) + 1}): ${enc.map((x, i) => `[${i}] ${x}`).join(' | ')}`);
      enc.forEach((nombre, i) => {
        if (!nombre.trim()) return;
        const cuenta = new Map();
        m.slice(ini + 1).forEach(f => { const v = (f[i] || '').trim(); if (v) cuenta.set(v, (cuenta.get(v) || 0) + 1); });
        const tipos = [...cuenta.entries()].sort((a, b) => b[1] - a[1]);
        const esLibre = /^(nombre|apellido|celular|telefono|numero|contexto|notas?)/i.test(nombre.trim()) || tipos.length > 25;
        console.log(`  - ${nombre}: ${cuenta.size} distintos, ${[...cuenta.values()].reduce((a, b) => a + b, 0)} con dato`
          + (esLibre ? '' : ` -> ${tipos.map(([v, c]) => `${v} (${c})`).join(', ')}`));
      });
    }
    process.exit(0);
  }
  const esMaestro = f => { const n = f.map(x => norm(x)); return n.includes('nombre') && n.includes('diasrestantes'); };
  const nombres = hojaPedida ? [hojaPedida] : Object.keys(libro);
  for (const h of nombres) {
    const m = matriz(h);
    const ini = m.findIndex(esMaestro);
    if (ini >= 0) { console.log(`Hoja "${h}", encabezados en la fila ${ini + 1}.`); return m.slice(ini); }
  }
  console.error(`No encontré una hoja con encabezados "Nombre" y "Días restantes". Hojas: ${Object.keys(libro).join(', ')}`);
  process.exit(1);
}

/* ---------- CSV ---------- */
function parsearCsv(texto) {
  const t = texto.replace(/^﻿/, '');
  const delim = (t.split('\n')[0].match(/;/g) || []).length > (t.split('\n')[0].match(/,/g) || []).length ? ';' : ',';
  const filas = [];
  let fila = [], celda = '', comillas = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (comillas) {
      if (c === '"' && t[i + 1] === '"') { celda += '"'; i++; }
      else if (c === '"') comillas = false;
      else celda += c;
    } else if (c === '"') comillas = true;
    else if (c === delim) { fila.push(celda); celda = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && t[i + 1] === '\n') i++;
      fila.push(celda); celda = '';
      if (fila.some(x => x.trim() !== '')) filas.push(fila);
      fila = [];
    } else celda += c;
  }
  if (celda !== '' || fila.length) { fila.push(celda); if (fila.some(x => x.trim() !== '')) filas.push(fila); }
  return filas;
}

const norm = h => String(h).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '');
const slug = h => String(h).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
  .replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40) || 'col';
const q = s => (s == null || s === '' ? 'null' : `'${String(s).replace(/'/g, "''")}'`);
const qb = b => (b ? 'true' : 'false');

const TRUE = new Set(['TRUE', 'VERDADERO', 'SI', 'SÍ', 'X', '✓', '✔', '1', 'YES']);
const FALSE = new Set(['FALSE', 'FALSO', 'NO', '0', '']);
function aBool(v) {
  const u = String(v ?? '').trim().toUpperCase();
  if (TRUE.has(u)) return true;
  if (FALSE.has(u)) return false;
  return null;   // no es booleano
}

function aFecha(v) {
  const s = String(v ?? '').trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);   // d/m/a (planilla argentina)
  if (m) {
    const a = m[3].length === 2 ? '20' + m[3] : m[3];
    return `${a}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  }
  return null;
}

/* ---------- columnas ---------- */
const CONOCIDAS = {
  producto: ['tipodecliente', 'tipocliente', 'programa', 'producto'],
  nombre: ['nombre'], apellido: ['apellido'],
  telefono: ['celular', 'telefono', 'numero'],
  dias: ['diasrestantes'],
  aviso1: ['21d'], aviso2: ['10d'],
  estado: ['estadodelallamada', 'estado'],
  contexto: ['contextoactualrenovacion', 'contextoactual', 'contexto'],
  testimonio: ['testimonio'],
  inicio: ['joineddate', 'fechadeinicio', 'fechadecarga', 'fecha'],
  skool: ['losaquedeskool'], wpp: ['losaquedewpp', 'losaquedewhatsapp']
};
/* Checks que ya conoce la migración 079 (clave fija). */
const CHECKS_FIJOS = [
  { test: n => n.startsWith('seunio'), clave: 'x_unio_school', etiqueta: 'Se unió a la School' },
  { test: n => n === 'losaquedeapp', clave: 'x_saque_app', etiqueta: '¿Lo saqué de la App?' }
];
/* Pasos que ya son accionables de la plantilla: no se duplican como columna. */
const ES_ACCIONABLE = n => n.startsWith('lepedireferidos') || n.startsWith('fup') || n === '5d' || n === '0d';

const filas = /\.csv$/i.test(archivo) ? parsearCsv(readFileSync(archivo, 'utf8')) : filasDeXlsx(archivo);
if (filas.length < 2) { console.error('La planilla no tiene filas.'); process.exit(1); }
const enc = filas[0].map(norm);
const idx = clave => enc.findIndex(h => CONOCIDAS[clave].includes(h));
const col = Object.fromEntries(Object.keys(CONOCIDAS).map(k => [k, idx(k)]));
for (const k of ['producto', 'nombre', 'dias', 'inicio']) {
  if (col[k] < 0) { console.error(`No encontré la columna "${k}" (encabezados: ${filas[0].join(' | ')})`); process.exit(1); }
}

const datos = filas.slice(1);
const asignadas = new Set(Object.values(col).filter(i => i >= 0));
const cols = [];   // checks: { i, clave, etiqueta }
const ignoradas = [];
enc.forEach((n, i) => {
  if (asignadas.has(i) || n === '') return;
  const fijo = CHECKS_FIJOS.find(c => c.test(n));
  if (fijo) { cols.push({ i, clave: fijo.clave, etiqueta: fijo.etiqueta }); return; }
  if (ES_ACCIONABLE(n)) return;
  const vals = datos.map(f => String(f[i] ?? '').trim()).filter(v => v !== '');
  if (vals.length && vals.every(v => aBool(v) !== null)) {
    cols.push({ i, clave: 'x_' + slug(filas[0][i]), etiqueta: filas[0][i].trim().slice(0, 60) });
  } else ignoradas.push(filas[0][i]);
});

/* ---------- filas ---------- */
const avisos = [];   // lo que hay que revisar a mano
const mas60 = [];    // "+60" y similares: sin definición, se conserva la fecha de fin actual
const out = [];
datos.forEach((f, n) => {
  const g = i => (i >= 0 ? String(f[i] ?? '').trim() : '');
  const fila = f.nFila || n + 2;
  const nombre = [g(col.nombre), g(col.apellido)].filter(Boolean).join(' ').replace(/\s+/g, ' ');
  if (!nombre) return;
  const inicio = aFecha(g(col.inicio));
  if (!inicio) { avisos.push(`fila ${fila}: sin fecha de inicio válida ("${g(col.inicio)}"), se omite`); return; }

  let producto = g(col.producto);
  let estado = g(col.estado);
  const checks = {};
  if (estado === '!') { checks.x_no_responde = true; estado = ''; }
  if (estado.toUpperCase() === 'COMUNIDAD') { producto = 'COMUNIDAD'; estado = ''; }
  const canon = ['Pausado', 'Churn', 'En seguimiento', 'CALL'].find(c => c.toLowerCase() === estado.toLowerCase());
  if (canon) estado = canon;
  estado = estado.replace(/^(resell|upsell|downsell)/i, m => m[0].toUpperCase() + m.slice(1).toLowerCase());
  if (/^gestion de capital$/i.test(producto)) producto = 'Gestión de Capital';
  if (!producto) { avisos.push(`fila ${fila}: sin tipo de cliente, se omite`); return; }

  const diasTxt = g(col.dias);
  let dias = null;
  if (/^-?\d+$/.test(diasTxt)) dias = Number(diasTxt);
  else if (/^\+\s*\d+$/.test(diasTxt)) mas60.push({ fila, valor: diasTxt });
  else if (diasTxt) avisos.push(`fila ${fila}: días restantes "${diasTxt}" no es un número: se conserva la fecha de fin actual (decidir a mano). `
    + `Producto "${producto}", inicio ${inicio}, estado "${estado}"`);

  for (const c of cols) if (aBool(f[c.i]) === true) checks[c.clave] = true;

  out.push({
    fila, nombre, telefono: g(col.telefono), producto, inicio, dias,
    aviso1: aBool(g(col.aviso1)) === true, aviso2: aBool(g(col.aviso2)) === true,
    estado, contexto: g(col.contexto), testimonio: g(col.testimonio).toUpperCase(),
    skool: aBool(g(col.skool)) === true, wpp: aBool(g(col.wpp)) === true, checks
  });
});

const columnasNuevas = [...cols.map(c => ({ clave: c.clave, etiqueta: c.etiqueta })),
  ...(out.some(r => r.checks.x_no_responde) ? [{ clave: 'x_no_responde', etiqueta: 'No responde los mensajes (!)' }] : [])]
  .filter((c, i, a) => a.findIndex(x => x.clave === c.clave) === i);

/* ---------- SQL ---------- */
const filasSql = out.map(r => `  (${r.fila}, ${q(r.nombre)}, ${q(r.telefono)}, ${q(r.producto)}, '${r.inicio}', ${r.dias ?? 'null'}, `
  + `${qb(r.aviso1)}, ${qb(r.aviso2)}, ${q(r.estado)}, ${q(r.contexto)}, ${q(r.testimonio)}, ${qb(r.skool)}, ${qb(r.wpp)}, `
  + `${q(JSON.stringify(r.checks))}::jsonb)`).join(',\n');
const colsSql = columnasNuevas.map((c, i) => `  (${i + 1}, ${q(c.clave)}, ${q(c.etiqueta)})`).join(',\n');

const sql = `-- =====================================================================
-- 080-actualizar-liam-${hoy}.sql  ·  PRODUCTO: Maestro de liam al día (última foto del Sheet)
-- =====================================================================
-- GENERADO por scripts/generar-importacion-liam.mjs desde ${archivo.split(/[\\\\/]/).pop()}
-- (${out.length} filas, fecha de la planilla ${hoy}). TIENE DATOS PERSONALES: está en
-- .gitignore (datos/*.sql). No lo subas ni lo pegues en chats.
--
-- ORDEN: 079 primero. Después este archivo, DOS veces:
--   1) tal cual: es un SIMULACRO. Termina con un error que trae el resumen y no
--      guarda nada.
--   2) con el parámetro aplicar = 'si' (sección 0): guarda.
-- No usar entre :00, :15, :30 y :45 ni a las 9:00.
--
-- Reglas: la planilla manda (es la última foto). Los días restantes cargados a mano
-- se respetan: fecha_fin = ${hoy} + días, no se recalcula por producto.
-- Clientes que ya están (mismo nombre y fecha de inicio): se actualizan teléfono,
-- producto, fecha de fin, testimonio, nota, avisos, checks, pausa y pipeline abierto.
-- Clientes nuevos: se crean como en 040. NO se borra ningún cliente que ya no esté
-- en la planilla (se informa). Renovaciones ya cerradas como "renovado" no se tocan:
-- si la planilla dice Resell/Upsell/Downsell y la app no lo tiene, se informa.
-- =====================================================================
begin;
set local lock_timeout = '8s';

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
  fila int, nombre text not null, telefono text, producto text not null, fecha_inicio date not null,
  dias int, aviso_1 boolean, aviso_2 boolean, estado_resell text, contexto text, testimonio text,
  sacado_skool boolean, sacado_wpp boolean, checks jsonb not null
);
insert into imp_csv values
${filasSql || '  (0, \'\', null, \'\', current_date, null, false, false, null, null, null, false, false, \'{}\'::jsonb)'};
${out.length ? '' : 'delete from imp_csv;'}

drop table if exists pg_temp.imp_cols;
create temp table imp_cols (pos int, clave text, etiqueta text);
${columnasNuevas.length ? `insert into imp_cols values\n${colsSql};` : '-- (la planilla no trae checks nuevos)'}

drop table if exists pg_temp.imp_log;
create temp table imp_log (clave text primary key, n int not null);

-- 2. CONTROLES PREVIOS (frenan sin tocar nada)
do $$
declare
  v_txt text;
begin
  if not exists (select 1 from public.cs_programas where id = 'liam') then
    raise exception 'No existe el programa liam.';
  end if;
  if to_regclass('public.cs_accesos') is null then
    raise exception 'Falta correr 079-producto-accesos-checks-corte.sql.';
  end if;
  select string_agg(distinct s.producto, ', ') into v_txt
  from imp_csv s
  where not exists (select 1 from public.cs_productos pr where pr.programa_id = 'liam' and pr.nombre = s.producto);
  if v_txt is not null then
    raise exception 'Productos de la planilla que no están en cs_productos de liam: %. Crealos en Configuración y volvé a correr. Los que tiene: %', v_txt,
      (select string_agg(nombre, ', ') from public.cs_productos where programa_id = 'liam');
  end if;
  select string_agg(distinct coalesce(estado_resell, ''), ', ') into v_txt
  from imp_csv
  where coalesce(estado_resell, '') <> ''
    and not (estado_resell in ('Pausado', 'Churn', 'En seguimiento', 'CALL')
             or estado_resell like 'Resell%' or estado_resell like 'Upsell%' or estado_resell like 'Downsell%');
  if v_txt is not null then
    raise exception 'ESTADO sin mapeo: %', v_txt;
  end if;
  select string_agg(distinct testimonio, ', ') into v_txt
  from imp_csv where coalesce(testimonio, '') not in ('', 'PITCHIADO', 'GRABADO', 'NO QUIERE', 'COORDINADO');
  if v_txt is not null then
    raise exception 'TESTIMONIO sin mapeo: %', v_txt;
  end if;
end $$;

-- 3. FILAS RESUELTAS (una por nombre + fecha de inicio)
drop table if exists pg_temp.imp;
create temp table imp as
with base as (
  select distinct on (lower(btrim(s.nombre)), s.fecha_inicio) s.*,
         pr.id as producto_id, pr.duracion_dias,
         case
           when coalesce(s.estado_resell, '') = '' then 'sin_resell'
           when s.estado_resell = 'Pausado' then 'pausado'
           when s.estado_resell = 'Churn' then 'churn'
           when s.estado_resell = 'En seguimiento' then 'contactado'
           when s.estado_resell = 'CALL' then 'call_agendada'
           when s.estado_resell like 'Resell%' then 'resell'
           when s.estado_resell like 'Upsell%' then 'upsell'
           when s.estado_resell like 'Downsell%' then 'downsell'
         end as categoria
  from imp_csv s
  join public.cs_productos pr on pr.programa_id = 'liam' and pr.nombre = s.producto
  order by lower(btrim(s.nombre)), s.fecha_inicio, s.fila
), r as (
  select b.*, c.id as cliente_id, c.estado as estado_actual, c.fecha_fin as fin_actual,
         (select valor::date from imp_param where clave = 'hoy') as hoy,
         (c.id is null) as era_nuevo
  from base b
  left join public.cs_clientes c
    on c.programa_id = 'liam' and lower(btrim(c.nombre)) = lower(btrim(b.nombre)) and c.fecha_inicio = b.fecha_inicio
), f as (
  select r.*,
         case when r.dias is not null then r.hoy + r.dias
              when r.cliente_id is not null then r.fin_actual
              else r.fecha_inicio + r.duracion_dias end as fin
  from r
)
select f.*,
       case f.categoria when 'pausado' then 'pausado'
                        when 'churn' then 'finalizado'
                        else case when f.fin >= f.hoy then 'activo' else 'finalizado' end end as estado_alta,
       case coalesce(f.testimonio, '') when 'PITCHIADO' then 'pitchiado' when 'GRABADO' then 'grabado'
                                       when 'NO QUIERE' then 'no_quiere' when 'COORDINADO' then 'coordinado'
                                       else null end as testimonio_db,
       (select aviso_1_dias from public.cs_programas where id = 'liam') as a1_dias,
       (select aviso_2_dias from public.cs_programas where id = 'liam') as a2_dias
from f;

-- 4. COLUMNAS DE CHECKS NUEVAS (las que traía la planilla)
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, tipo)
select 'liam', k.clave, false, k.etiqueta,
       coalesce((select max(c.orden) from public.cs_maestro_columnas c where c.programa_id = 'liam'), 1000) + 10 + k.pos,
       'casilla'
from imp_cols k
on conflict (programa_id, clave) do nothing;

-- 5. CLIENTES NUEVOS (como 040; los triggers de 001/039 hacen lo suyo)
do $$
declare
  v_n int;
begin
  insert into public.cs_clientes
    (programa_id, nombre, telefono, fecha_inicio, fecha_fin, estado, producto_id, testimonio,
     nota_csm, aviso_1_at, aviso_2_at, pausado_desde, campos_extra, created_by)
  select 'liam', i.nombre, nullif(btrim(i.telefono), ''), i.fecha_inicio, i.fin, i.estado_alta, i.producto_id,
         coalesce(i.testimonio_db, 'sin_pedir'), nullif(i.contexto, ''),
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
   where i.era_nuevo and c.programa_id = 'liam'
     and lower(btrim(c.nombre)) = lower(btrim(i.nombre)) and c.fecha_inicio = i.fecha_inicio;
end $$;

-- 6. CLIENTES QUE YA ESTABAN: una sola actualización por cliente
do $$
declare
  v_n int;
begin
  update public.cs_clientes c set
    telefono   = coalesce(nullif(btrim(i.telefono), ''), c.telefono),
    producto_id = i.producto_id,
    fecha_fin  = i.fin,
    testimonio = coalesce(i.testimonio_db, c.testimonio),
    nota_csm   = case when nullif(i.contexto, '') is null or position(i.contexto in coalesce(c.nota_csm, '')) > 0
                      then c.nota_csm
                      else i.contexto || coalesce(' · ' || c.nota_csm, '') end,
    aviso_1_at = case when i.aviso_1 and c.aviso_1_at is null
                      then pg_temp.imp_ts(least(i.fin - i.a1_dias, i.hoy)) else c.aviso_1_at end,
    aviso_2_at = case when i.aviso_2 and c.aviso_2_at is null
                      then pg_temp.imp_ts(least(i.fin - i.a2_dias, i.hoy)) else c.aviso_2_at end,
    campos_extra = c.campos_extra || i.checks,
    estado     = case
                   when i.categoria = 'pausado' and c.estado in ('onboarding', 'activo', 'en_renovacion') then 'pausado'
                   when i.categoria <> 'pausado' and c.estado = 'pausado' then 'activo'
                   when c.estado = 'finalizado' and i.fin >= i.hoy and i.categoria <> 'churn' then 'activo'
                   else c.estado end
  from imp i
  where not i.era_nuevo and c.id = i.cliente_id
    and (   c.producto_id is distinct from i.producto_id
         or c.fecha_fin is distinct from i.fin
         or c.testimonio is distinct from coalesce(i.testimonio_db, c.testimonio)
         or (nullif(btrim(i.telefono), '') is not null and c.telefono is distinct from nullif(btrim(i.telefono), ''))
         or (nullif(i.contexto, '') is not null and position(i.contexto in coalesce(c.nota_csm, '')) = 0)
         or (i.aviso_1 and c.aviso_1_at is null) or (i.aviso_2 and c.aviso_2_at is null)
         or (c.campos_extra || i.checks) is distinct from c.campos_extra
         or (i.categoria = 'pausado' and c.estado in ('onboarding', 'activo', 'en_renovacion'))
         or (i.categoria <> 'pausado' and c.estado = 'pausado')
         or (c.estado = 'finalizado' and i.fin >= i.hoy and i.categoria <> 'churn'));
  get diagnostics v_n = row_count;
  insert into imp_log values ('clientes_actualizados', v_n);
end $$;

-- 7. PIPELINE DE RESELL
do $$
declare
  v_n int;
begin
  -- 7a. Nuevos: igual que 040 (sin renovaciones previas).
  insert into public.cs_renovaciones
    (programa_id, cliente_id, estado, iniciada_at, resultado_at, nueva_fecha_fin,
     resell_producto, producto_id, motivo, created_by)
  select 'liam', i.cliente_id,
         case i.categoria when 'churn' then 'no_renovado' when 'contactado' then 'contactado'
                          when 'call_agendada' then 'call_agendada' else 'renovado' end,
         case when i.categoria in ('contactado', 'call_agendada') then now()
              else pg_temp.imp_ts(least(i.fin, i.hoy)) end,
         case when i.categoria in ('contactado', 'call_agendada') then null
              else pg_temp.imp_ts(least(i.fin, i.hoy)) end,
         case when i.categoria in ('resell', 'upsell', 'downsell')
              then case when i.dias is not null then i.fin else (i.fin + interval '9 months')::date end end,
         case i.categoria when 'resell' then 'mismo_programa' when 'upsell' then 'upgrade'
                          when 'downsell' then 'downgrade' end,
         case when i.categoria = 'upsell' then i.producto_id end,
         case when i.categoria = 'churn' then 'Otro: churn según la planilla de BPF (importación)' end,
         null
  from imp i
  where i.era_nuevo and i.cliente_id is not null
    and i.categoria in ('churn', 'contactado', 'call_agendada', 'resell', 'upsell', 'downsell')
  order by i.fila;
  get diagnostics v_n = row_count;
  insert into imp_log values ('renovaciones_nuevas_clientes_nuevos', v_n);

  -- 7b. Existentes con pipeline abierto y la planilla dice Churn: se cierra como no renovado.
  -- (Los cambios de etapa entre contactado, call, propuesta... no se tocan: el pipeline
  -- de la app puede estar más adelantado que la planilla.)
  update public.cs_renovaciones r set
    estado = 'no_renovado',
    motivo = coalesce(r.motivo, 'Otro: churn según la planilla de BPF (importación)')
  from imp i
  where not i.era_nuevo and r.cliente_id = i.cliente_id and public.cs_ren_abierta(r.estado)
    and i.categoria = 'churn';
  get diagnostics v_n = row_count;
  insert into imp_log values ('pipeline_movido', v_n);

  -- 7c. Existentes sin pipeline abierto y la planilla dice "en seguimiento" o "call": se abre.
  insert into public.cs_renovaciones (programa_id, cliente_id, estado, iniciada_at, created_by)
  select 'liam', i.cliente_id, case i.categoria when 'call_agendada' then 'call_agendada' else 'contactado' end, now(), null
  from imp i
  where not i.era_nuevo and i.categoria in ('contactado', 'call_agendada')
    and i.estado_actual not in ('baja', 'finalizado')
    and not exists (select 1 from public.cs_renovaciones r
                    where r.cliente_id = i.cliente_id and public.cs_ren_abierta(r.estado));
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

-- 9. CONTROLES DUROS + SIMULACRO
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
    'RESUMEN. Filas de la planilla: %s. Clientes nuevos: %s. Actualizados: %s. Pipeline movido: %s, abierto: %s. '
    || 'Cierres completados: %s. En la app y NO en la planilla (no se tocan): %s. '
    || 'Planilla dice Resell/Upsell/Downsell y la app no tiene renovación cerrada como renovado (revisar a mano): %s. '
    || 'NUEVOS (si alguno ya estaba con otro nombre o fecha, corregilo en el CSV): %s',
    (select count(*) from imp),
    (select n from imp_log where clave = 'clientes_nuevos'),
    (select n from imp_log where clave = 'clientes_actualizados'),
    (select n from imp_log where clave = 'pipeline_movido'),
    (select n from imp_log where clave = 'pipeline_abierto'),
    (select n from imp_log where clave = 'cierres_completados'),
    (select count(*) from public.cs_clientes c where c.programa_id = 'liam'
        and not exists (select 1 from imp i where i.cliente_id = c.id)),
    (select count(*) from imp i where i.categoria in ('resell', 'upsell', 'downsell') and not i.era_nuevo
        and not exists (select 1 from public.cs_renovaciones r where r.cliente_id = i.cliente_id and r.estado = 'renovado')),
    coalesce((select string_agg(x.nombre, ', ') from (select nombre from imp where era_nuevo order by fila limit 15) x), '(ninguno)')
  ) into v_msg;
  if (select valor from imp_param where clave = 'aplicar') <> 'si' then
    raise exception 'SIMULACRO (no se guardó nada). %', v_msg;
  end if;
  raise notice '%', v_msg;
end $$;

commit;

-- 10. QUERY DE CONTROL (después de aplicar)
select 'clientes liam' as control, count(*)::text as valor from public.cs_clientes where programa_id = 'liam'
union all
select 'activos', count(*)::text from public.cs_clientes where programa_id = 'liam' and estado in ('activo', 'en_renovacion')
union all
select 'pausados', count(*)::text from public.cs_clientes where programa_id = 'liam' and estado = 'pausado'
union all
select 'finalizados o baja', count(*)::text from public.cs_clientes where programa_id = 'liam' and estado in ('finalizado', 'baja')
union all
select 'con algun check marcado', count(*)::text from public.cs_clientes
 where programa_id = 'liam' and campos_extra <> '{}'::jsonb
union all
select 'columnas casilla', count(*)::text from public.cs_maestro_columnas
 where programa_id = 'liam' and tipo = 'casilla' and not archivada;
`;

const salida = `datos/080-actualizar-liam-${hoy}.sql`;
mkdirSync('datos', { recursive: true });
writeFileSync(salida, sql, 'utf8');

/* Estimación contra la importación anterior (040): mismo nombre + fecha de inicio = ya está. */
const BASE = 'datos/liam-clientes.csv';
try {
  const k = (n, d) => `${String(n).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\s+/g, ' ').trim()}|${d}`;
  const b = parsearCsv(readFileSync(BASE, 'utf8'));
  const h = b[0].map(norm);
  const [iN, iA, iF] = [h.indexOf('nombre'), h.indexOf('apellido'), h.indexOf('fechainicio')];
  const yaEstan = new Set(b.slice(1).map(f => k([f[iN], f[iA]].filter(Boolean).join(' ').replace(/\s+/g, ' '), aFecha(f[iF]))));
  const claves = new Set(out.map(r => k(r.nombre, r.inicio)));
  const nuevas = [...claves].filter(c => !yaEstan.has(c)).length;
  console.log(`Estimado contra ${BASE} (${yaEstan.size} filas): actualiza ${claves.size - nuevas}, crea ${nuevas}, `
    + `en la base y no en la planilla ${[...yaEstan].filter(c => !claves.has(c)).length}.`);
} catch (e) { console.log(`(sin estimación contra la base: ${e.message})`); }
const dup = out.length - new Set(out.map(r => `${r.nombre.toLowerCase()}|${r.inicio}`)).size;
console.log(`Filas válidas: ${out.length}. Repetidas (mismo nombre+inicio, se toma la primera): ${dup}.`);
console.log(`Con días restantes numéricos: ${out.filter(r => r.dias !== null).length}. "+N" sin definición: ${mas60.length}`
  + (mas60.length ? ` (filas ${mas60.map(m => `${m.fila}="${m.valor}"`).join(', ')})` : '') + '.');
console.log(`OK ${salida}`);
console.log(`Filas leídas: ${out.length}. Checks (columnas casilla): ${columnasNuevas.map(c => c.etiqueta).join(', ') || 'ninguno nuevo'}.`);
if (ignoradas.length) console.log(`Columnas ignoradas (no son casillas ni conocidas): ${ignoradas.join(', ')}`);
if (avisos.length) { console.log('A REVISAR:'); avisos.forEach(a => console.log('  - ' + a)); }
