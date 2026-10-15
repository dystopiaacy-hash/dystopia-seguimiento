/* Genera la carga de alumnos de Teo (125, DATOS) leyendo las planillas xlsx directo.
   Sin dependencias: solo Node (lector propio en scripts/xlsx-leer.mjs).

   Uso (desde la carpeta del repo):
     node scripts/generar-alumnos-teo.mjs [--dir <carpeta>] [--hoy AAAA-MM-DD] [--duracion 120] [--inspeccionar]

   - --dir: carpeta con los 3 xlsx (por defecto, insumos del jefe, planillas-2026-10-14/teo).
   - --hoy: fecha contra la que se decide activo/finalizado (por defecto, hoy).
   - --duracion: dias del programa (por defecto 120). fecha_fin = primer pago + duracion.
   - --inspeccionar: solo muestra hojas, encabezados detectados y conteos. No escribe nada.
   - Salida: migraciones/125-producto-alumnos-teo-datos.sql (en .gitignore: tiene datos
     personales). No lo subas, no lo pegues en chats.

   Fuentes (ver jefe/insumos/teo-alumnos-fuente.md):
     Finanzas / Pagos        -> lista de alumnos (nombre, telefono, fecha, programa, closer, setter)
     MAESTRO / Hoja 1        -> respaldo de nombre, telefono y fecha; marcas de "saque del WPP/DS/Skool"
     CRM Ventas / DATA ONBOARDING -> mails (cruce por nombre normalizado)
   Idempotente en la base: clave = 'teo-xlsx|<nombre normalizado>' en pago_clave; ademas no inserta
   a quien ya existe en teo con el mismo nombre normalizado. Nunca pisa alumnos existentes. */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { leerXlsx } from './xlsx-leer.mjs';

const QUI = dirname(fileURLToPath(import.meta.url));
const DIR_INSUMO = 'C:/Users/Admin/Downloads/jefe/insumos/planillas-2026-10-14/teo';
const SALIDA = join(QUI, '..', 'migraciones', '125-producto-alumnos-teo-datos.sql');
const PROGRAMA = 'teo';

/* ---------- argumentos ---------- */
const args = process.argv.slice(2);
const flag = n => { const i = args.indexOf(n); return i >= 0 ? args.splice(i, 2)[1] : null; };
const inspeccionar = args.includes('--inspeccionar');
if (inspeccionar) args.splice(args.indexOf('--inspeccionar'), 1);
const DIR = flag('--dir') || DIR_INSUMO;
const DURACION = Number(flag('--duracion') || 120);   // PARAMETRO EDITABLE: dias del programa
let hoy = flag('--hoy');
if (!hoy) { const d = new Date(); hoy = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; }
if (!/^\d{4}-\d{2}-\d{2}$/.test(hoy)) { console.error('--hoy debe ser AAAA-MM-DD'); process.exit(1); }
if (!Number.isInteger(DURACION) || DURACION < 1 || DURACION > 1000) { console.error('--duracion debe ser un entero entre 1 y 1000'); process.exit(1); }

/* ---------- alumnos que hay que agregar a mano ---------- */
/* Carlos Favre: es alumno de la grupal aunque CRM Ventas lo tenga como lead ("en seguimiento").
   No esta en Pagos ni en Maestro. Se carga a mano: inicio = --hoy, activo, plan Grupal.
   Si algun dia aparece en Pagos, el cruce por nombre lo une y esta fila no se usa. */
const ALUMNOS_MANUALES = [
  { nombre: 'Carlos Favre', plan: 'Grupal', nota: 'Alumno de la grupal; en CRM Ventas figuraba como lead (carga manual del script).' },
];

/* ---------- utilidades ---------- */
const serialAFecha = n => new Date(Date.UTC(1899, 11, 30) + Math.floor(n) * 86400000).toISOString().slice(0, 10);
const txt = v => v == null ? '' : typeof v === 'object' && v.fecha != null ? serialAFecha(v.fecha)
  : typeof v === 'boolean' ? (v ? 'TRUE' : 'FALSE') : String(v);
/* Normalizado: minusculas, sin acentos, sin simbolos, sin espacios dobles (igual criterio que cs_norm_nombre). */
const norm = s => txt(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
  .replace(/[^a-z0-9]+/g, ' ').trim();
const limpiarNombre = s => txt(s).replace(/\s+/g, ' ').trim();
const tel8 = s => { const d = txt(s).replace(/\D/g, ''); return d.length >= 8 ? d.slice(-8) : ''; };
const RX_MAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const mailOk = s => { const m = txt(s).trim().toLowerCase(); return RX_MAIL.test(m) ? m : ''; };
const sqlTxt = s => s == null || s === '' ? 'null' : `'${String(s).replace(/'/g, "''")}'`;
const esFecha = s => /^\d{4}-\d{2}-\d{2}$/.test(s);
const sumarDias = (f, n) => new Date(Date.parse(f + 'T00:00:00Z') + n * 86400000).toISOString().slice(0, 10);

/* Fecha de una celda: serial de Excel (ya viene { fecha }) o texto dd/mm/aaaa, aaaa-mm-dd. */
function fechaDe(v) {
  if (v == null || v === '') return '';
  if (typeof v === 'object' && v.fecha != null) return serialAFecha(v.fecha);
  if (typeof v === 'number' && v > 30000 && v < 80000) return serialAFecha(v);
  const t = String(v).trim();
  let m = /^(\d{4})-(\d{2})-(\d{2})/.exec(t);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = /^(\d{1,2})[\/.-](\d{1,2})[\/.-](\d{2,4})/.exec(t);
  if (m) {
    const y = m[3].length === 2 ? '20' + m[3] : m[3];
    return `${y}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  }
  return '';
}

/* Hoja -> filas (arrays de celdas crudas), buscando el archivo por parte del nombre. */
function abrir(parte) {
  const f = join(DIR, parte);
  if (!existsSync(f)) { console.error(`No encuentro ${f}`); process.exit(1); }
  return leerXlsx(f);
}
const hojaDe = (libro, nombre) => {
  const k = Object.keys(libro).find(h => norm(h) === norm(nombre));
  if (!k) { console.error(`Falta la hoja "${nombre}". Hojas: ${Object.keys(libro).join(' | ')}`); process.exit(1); }
  return (libro[k] || []).map((f, i) => Object.assign(Array.from(f || []), { nFila: i + 1 }));
};

/* Encabezados: primera fila con >= 3 celdas de texto; columnas por nombre normalizado.
   `candidatos` = { campo: [regex...] }; `respaldo` = { campo: indice } (letras de la fuente). */
function columnas(filas, candidatos, respaldo) {
  const i = filas.findIndex(f => f && f.filter(c => typeof c === 'string' && c.trim()).length >= 3);
  const enc = (filas[i] || []).map(c => norm(c));
  const col = {};
  for (const [campo, rxs] of Object.entries(candidatos)) {
    let j = -1;
    for (const rx of rxs) { j = enc.findIndex(h => h && rx.test(h)); if (j >= 0) break; }
    col[campo] = j >= 0 ? j : (respaldo[campo] ?? -1);
  }
  return { col, filaEnc: i, enc };
}
const celda = (f, j) => (j >= 0 && f ? f[j] : undefined);

/* ---------- lectura ---------- */
const libFin = abrir('North Ecom - Finanzas 2026.xlsx');
const libMae = abrir('MAESTRO DE CLIENTES - NEC.xlsx');
const libCrm = abrir('CRM Ventas NEC.xlsx');

const pagosF = hojaDe(libFin, 'Pagos');
const cPag = columnas(pagosF, {
  fecha: [/^fecha/], programa: [/^programa/], nombre: [/nombre del alumno/, /^nombre/], telefono: [/^numero/, /telefono/],
  pago: [/^pago$/], concepto: [/^concepto/], closer: [/^closer/], setter: [/^setter/], metodo: [/metodo/],
}, { fecha: 0, programa: 1, nombre: 2, telefono: 3, pago: 4, concepto: 5, closer: 6, setter: 7, metodo: 10 });

const maeF = hojaDe(libMae, 'Hoja 1');
const cMae = columnas(maeF, {
  fecha: [/^fecha/], programa: [/^programa/], nombre: [/nombre del alumno/, /^nombre/], telefono: [/^numero/, /telefono/],
  dias: [/dias restantes/], estado: [/^estado/], wpp: [/wpp/], ds: [/\bds\b|discord/], skool: [/skool/],
}, { fecha: 0, programa: 1, nombre: 2, telefono: 3, dias: 8, estado: 11, wpp: 13, ds: 14, skool: 15 });

const onbF = hojaDe(libCrm, 'DATA ONBOARDING');
const cOnb = columnas(onbF, {
  nombre: [/^nombre$/], apellido: [/^apellido/], telefono: [/telefono/], mail: [/^mail/, /e ?mail/, /correo/],
}, { nombre: 1, apellido: 2, telefono: 3, mail: 4 });

const crmDataF = Object.keys(libCrm).some(h => norm(h) === 'data') ? hojaDe(libCrm, 'DATA') : [];
const cCrm = columnas(crmDataF, { nombre: [/nombre completo/, /^nombre/], telefono: [/telefono/] }, { nombre: 0, telefono: 7 });

if (inspeccionar) {
  const mostrar = (t, f, c) => {
    console.log(`\n== ${t}: ${f.filter(x => x && x.length).length} filas, encabezado en fila ${c.filaEnc + 1}`);
    console.log('   encabezados: ' + c.enc.map((h, i) => `[${i}] ${h}`).filter(x => !/\] $/.test(x)).join(' | '));
    console.log('   columnas usadas: ' + Object.entries(c.col).map(([k, v]) => `${k}=${v}`).join(', '));
  };
  mostrar('Finanzas / Pagos', pagosF, cPag);
  mostrar('Maestro / Hoja 1', maeF, cMae);
  mostrar('CRM / DATA ONBOARDING', onbF, cOnb);
  if (crmDataF.length) mostrar('CRM / DATA', crmDataF, cCrm);
  process.exit(0);
}
for (const [t, c, campos] of [['Pagos', cPag, ['nombre', 'fecha']], ['Maestro', cMae, ['nombre', 'fecha']], ['DATA ONBOARDING', cOnb, ['nombre', 'mail']]]) {
  const falta = campos.filter(k => c.col[k] < 0);
  if (falta.length) { console.error(`${t}: no encontre las columnas ${falta.join(', ')}. Corre con --inspeccionar.`); process.exit(1); }
}

/* ---------- 1. filas de pago / maestro -> registros por nombre ---------- */
const reg = [];   // { nom, nombre, tel, fecha, plan, closer, setter, concepto, metodo, fuente, sacado }
const planDe = p => {
  const n = norm(p);
  if (!n) return '';
  if (/\b1 ?(a|x|:)? ?1\b|uno a uno|individual|one/.test(n) || /^1a1/.test(n)) return '1 a 1';
  if (/grup/.test(n)) return 'Grupal';
  if (/comunidad/.test(n)) return 'Comunidad';
  return limpiarNombre(p);
};
for (const f of pagosF.slice(cPag.filaEnc + 1)) {
  const nombre = limpiarNombre(celda(f, cPag.col.nombre));
  if (!norm(nombre)) continue;
  reg.push({
    nom: norm(nombre), nombre, tel: txt(celda(f, cPag.col.telefono)).trim(), fecha: fechaDe(celda(f, cPag.col.fecha)),
    plan: planDe(celda(f, cPag.col.programa)), closer: limpiarNombre(celda(f, cPag.col.closer)),
    setter: limpiarNombre(celda(f, cPag.col.setter)), concepto: limpiarNombre(celda(f, cPag.col.concepto)),
    metodo: limpiarNombre(celda(f, cPag.col.metodo)), fuente: 'pagos', sacado: false,
  });
}
const nPagos = reg.length;
const marcado = v => { const n = norm(v); return n !== '' && !/^(0|no|false|nada|n a)$/.test(n); };
for (const f of maeF.slice(cMae.filaEnc + 1)) {
  const nombre = limpiarNombre(celda(f, cMae.col.nombre));
  if (!norm(nombre)) continue;
  reg.push({
    nom: norm(nombre), nombre, tel: txt(celda(f, cMae.col.telefono)).trim(), fecha: fechaDe(celda(f, cMae.col.fecha)),
    plan: planDe(celda(f, cMae.col.programa)), closer: '', setter: '', concepto: '', metodo: '', fuente: 'maestro',
    sacado: marcado(celda(f, cMae.col.ds)) || marcado(celda(f, cMae.col.skool)),
  });
}
const nMaestro = reg.length - nPagos;

/* ---------- 2. unir variantes de nombre (misma persona) ---------- */
/* Reglas, de mas a menos segura. Nunca une si hay mas de un candidato posible:
   a) mismo nombre normalizado;
   b) mismo telefono (8 digitos) Y mismo primer y ultimo token (segundo nombre de mas o de menos);
   c) mismo primer y ultimo token y los tokens del mas corto estan dentro del mas largo (>= 2 tokens). */
const nombresUnicos = [...new Set(reg.map(r => r.nom))];
const telDe = new Map();   // nom -> Set(tel8)
for (const r of reg) { const t = tel8(r.tel); if (t) (telDe.get(r.nom) ?? telDe.set(r.nom, new Set()).get(r.nom)).add(t); }
const toks = n => n.split(' ');
const padre = new Map(nombresUnicos.map(n => [n, n]));
const raiz = n => { while (padre.get(n) !== n) n = padre.get(n); return n; };
const uniones = [];
function candidatosDe(n) {
  const a = toks(n);
  const out = [];
  for (const m of nombresUnicos) {
    if (m === n) continue;
    const b = toks(m);
    if (a[0] !== b[0] || a[a.length - 1] !== b[b.length - 1] || a.length < 2 || b.length < 2) continue;
    const [corto, largo] = a.length <= b.length ? [a, b] : [b, a];
    if (!corto.every(t => largo.includes(t))) continue;
    out.push(m);
  }
  return out;
}
for (const n of nombresUnicos) {
  const c = candidatosDe(n);
  if (c.length !== 1) continue;                      // 0 = nada que unir; >1 = ambiguo, no se une
  if (candidatosDe(c[0]).length !== 1) continue;     // el otro tambien tiene que ser univoco
  const m = c[0];
  if (raiz(n) === raiz(m)) continue;
  const tn = telDe.get(n), tm = telDe.get(m);
  const mismoTel = tn && tm && [...tn].some(t => tm.has(t));
  const telDistinto = tn && tm && !mismoTel;         // telefonos distintos: probablemente dos personas
  if (telDistinto) continue;
  padre.set(raiz(m), raiz(n));
  uniones.push(`${n}  <=>  ${m}  (${mismoTel ? 'mismo telefono' : 'nombre incluido'})`);
}

/* ---------- 3. una persona por grupo ---------- */
const grupos = new Map();
for (const r of reg) (grupos.get(raiz(r.nom)) ?? grupos.set(raiz(r.nom), []).get(raiz(r.nom))).push(r);

const personas = [];
for (const [, rs] of grupos) {
  const masFrecuente = (arr) => {
    const c = new Map();
    for (const x of arr.filter(Boolean)) c.set(x, (c.get(x) || 0) + 1);
    return [...c.entries()].sort((a, b) => b[1] - a[1] || b[0].length - a[0].length)[0]?.[0] ?? '';
  };
  /* nombre canonico: el mas frecuente de Pagos (la fuente base), si no el de Maestro; empate = el mas largo */
  const dePagos = rs.filter(r => r.fuente === 'pagos').map(r => r.nombre);
  const nombre = masFrecuente(dePagos.length ? dePagos : rs.map(r => r.nombre));
  const fechas = rs.map(r => r.fecha).filter(esFecha).sort();
  const pagosOrd = rs.filter(r => r.fuente === 'pagos' && esFecha(r.fecha)).sort((a, b) => a.fecha.localeCompare(b.fecha));
  const planes = [...new Set(rs.map(r => r.plan).filter(Boolean))];
  /* plan vigente: el del ultimo pago; si no hay pagos, el de Maestro */
  const plan = (pagosOrd.length ? pagosOrd[pagosOrd.length - 1].plan : '') || planes[0] || '';
  const tel = rs.map(r => r.tel).find(t => tel8(t)) || '';
  personas.push({
    clave: 'teo-xlsx|' + norm(nombre).replace(/ /g, '-'),
    nombre, nom: norm(nombre), nomsVariantes: [...new Set(rs.map(r => r.nom))],
    telefono: tel, fecha_inicio: fechas[0] || '',
    ultimo_pago: pagosOrd.length ? pagosOrd[pagosOrd.length - 1].fecha : '',
    plan, planes,
    closer: masFrecuente(rs.map(r => r.closer)), setter: masFrecuente(rs.map(r => r.setter)),
    conceptos: [...new Set(rs.map(r => r.concepto).filter(Boolean))].slice(0, 6),
    metodos: [...new Set(rs.map(r => r.metodo).filter(Boolean))].slice(0, 4),
    n_pagos: pagosOrd.length, en_pagos: pagosOrd.length > 0, en_maestro: rs.some(r => r.fuente === 'maestro'),
    sacado: rs.some(r => r.sacado), manual: false, nota: '', email: '',
  });
}

/* ---------- 4. alumnos manuales ---------- */
const crmTel = new Map();   // nombre normalizado -> telefono (CRM DATA), solo para completar
for (const f of crmDataF.slice(cCrm.filaEnc + 1)) {
  const n = norm(celda(f, cCrm.col.nombre));
  const t = txt(celda(f, cCrm.col.telefono)).trim();
  if (n && tel8(t) && !crmTel.has(n)) crmTel.set(n, t);
}
const manualesAplicados = [];
for (const m of ALUMNOS_MANUALES) {
  const nom = norm(m.nombre);
  const ya = personas.find(p => p.nom === nom || p.nomsVariantes.includes(nom));
  if (ya) { manualesAplicados.push(`${m.nombre}: ya estaba en las planillas, se usa esa fila`); continue; }
  personas.push({
    clave: 'teo-xlsx|' + nom.replace(/ /g, '-'), nombre: m.nombre, nom, nomsVariantes: [nom],
    telefono: crmTel.get(nom) || '', fecha_inicio: hoy, ultimo_pago: '', plan: m.plan, planes: [m.plan],
    closer: '', setter: '', conceptos: [], metodos: [], n_pagos: 0, en_pagos: false, en_maestro: false,
    sacado: false, manual: true, nota: m.nota, email: '',
  });
  manualesAplicados.push(`${m.nombre}: agregado a mano`);
}

/* ---------- 5. mails: DATA ONBOARDING cruzado por nombre normalizado ---------- */
const onb = [];
for (const f of onbF.slice(cOnb.filaEnc + 1)) {
  const nombre = limpiarNombre(`${txt(celda(f, cOnb.col.nombre))} ${txt(celda(f, cOnb.col.apellido))}`);
  const mail = mailOk(celda(f, cOnb.col.mail));
  if (!norm(nombre) && !mail) continue;
  onb.push({ nom: norm(nombre), nombre, mail, bruto: txt(celda(f, cOnb.col.mail)).trim(), tel: txt(celda(f, cOnb.col.telefono)).trim() });
}
const porNombre = new Map();   // cualquier variante normalizada -> persona
for (const p of personas) for (const v of new Set([p.nom, ...p.nomsVariantes])) porNombre.set(v, p);
function personaDeOnboarding(o) {
  const exacto = porNombre.get(o.nom);
  if (exacto) return { p: exacto, como: 'nombre exacto' };
  /* mismo primer y ultimo token y tokens incluidos, con UN solo candidato; el telefono no puede contradecir */
  const a = toks(o.nom);
  if (a.length < 2) return null;
  const cs = personas.filter(p => [p.nom, ...p.nomsVariantes].some(v => {
    const b = toks(v);
    if (b.length < 2 || a[0] !== b[0] || a[a.length - 1] !== b[b.length - 1]) return false;
    const [c, l] = a.length <= b.length ? [a, b] : [b, a];
    return c.every(t => l.includes(t));
  }));
  if (cs.length === 1) {
    const t = tel8(o.tel), pt = tel8(cs[0].telefono);
    if (t && pt && t !== pt) return null;
    return { p: cs[0], como: 'nombre incluido' };
  }
  return null;
}
const sinAlumno = [];
const mailsPorPersona = new Map();
let onbSinMail = 0;
for (const o of onb) {
  if (!o.mail) { onbSinMail++; continue; }
  const r = personaDeOnboarding(o);
  if (!r) { sinAlumno.push(o); continue; }
  const l = mailsPorPersona.get(r.p) ?? mailsPorPersona.set(r.p, []).get(r.p);
  if (!l.includes(o.mail)) l.push(o.mail);
}
for (const [p, mails] of mailsPorPersona) p.email = mails[mails.length - 1];   // el mas reciente (el form va en orden)
const mailsDeDosNombres = new Map();
for (const p of personas) if (p.email) (mailsDeDosNombres.get(p.email) ?? mailsDeDosNombres.set(p.email, []).get(p.email)).push(p);

/* ---------- 6. estado y fechas ---------- */
const sinFecha = [];
for (const p of personas) {
  if (!esFecha(p.fecha_inicio)) { sinFecha.push(p); p.fecha_inicio = hoy; p.sinFecha = true; }
  if (p.fecha_inicio > hoy) p.fecha_inicio = hoy;          // el trigger y el CHECK piden fin >= inicio; no futuras
  p.fecha_fin = sumarDias(p.fecha_inicio, DURACION);
  const vigente = p.fecha_fin >= hoy;
  /* "Lo saque del WPP/DS/Skool" antes de que termine = baja; despues de terminar, finalizado. */
  p.estado = p.sacado && vigente ? 'baja' : vigente ? 'activo' : 'finalizado';
}
personas.sort((a, b) => a.nom.localeCompare(b.nom));

/* ---------- 7. controles (consola) ---------- */
const claves = new Map();
for (const p of personas) claves.set(p.clave, (claves.get(p.clave) || 0) + 1);
const clavesRepetidas = [...claves.entries()].filter(([, n]) => n > 1);
const conMail = personas.filter(p => p.email).length;
const porEstado = personas.reduce((a, p) => (a[p.estado] = (a[p.estado] || 0) + 1, a), {});
const porPlan = personas.reduce((a, p) => (a[p.plan || '(sin plan)'] = (a[p.plan || '(sin plan)'] || 0) + 1, a), {});
const mailsRepetidos = [...mailsDeDosNombres.entries()].filter(([, ps]) => ps.length > 1);

console.log(`Filas leidas: Pagos ${nPagos}, Maestro ${nMaestro}, DATA ONBOARDING ${onb.length} (${onbSinMail} sin mail valido).`);
console.log(`Alumnos a cargar: ${personas.length} (${personas.filter(p => p.manual).length} manuales).`);
console.log(`Con mail: ${conMail}. Sin mail: ${personas.length - conMail}.`);
console.log(`Por estado: ${JSON.stringify(porEstado)}   Por plan: ${JSON.stringify(porPlan)}`);
console.log(`Variantes de nombre unidas: ${uniones.length}`);
uniones.forEach(u => console.log('   ' + u));
console.log(`Claves repetidas: ${clavesRepetidas.length}${clavesRepetidas.length ? ' <- REVISAR: ' + clavesRepetidas.map(c => c[0]).join(', ') : ''}`);
console.log(`Mails compartidos por 2 alumnos o mas: ${mailsRepetidos.length}`);
console.log(`Respuestas de onboarding sin alumno en las planillas: ${sinAlumno.length} (quedan comentadas en el .sql)`);
console.log(`Sin fecha de pago (se uso --hoy): ${sinFecha.length}`);
manualesAplicados.forEach(m => console.log('   manual: ' + m));
if (clavesRepetidas.length) { console.error('Hay claves repetidas: no se escribe el archivo.'); process.exit(1); }

/* ---------- 8. SQL ---------- */
const lineaValores = p => {
  const extra = {
    origen: p.manual ? 'carga_manual_script' : 'planillas_nec_2026-10',
    plan_original: p.planes, closer: p.closer || null, setter: p.setter || null,
    conceptos: p.conceptos, metodos_pago: p.metodos, n_pagos: p.n_pagos, ultimo_pago: p.ultimo_pago || null,
    en_finanzas: p.en_pagos, en_maestro: p.en_maestro, sin_fecha_de_pago: !!p.sinFecha,
  };
  for (const k of Object.keys(extra)) if (extra[k] == null || (Array.isArray(extra[k]) && !extra[k].length)) delete extra[k];
  const notas = p.nota || (p.sinFecha ? 'Sin fecha de pago en las planillas: el inicio es la fecha de la carga.' : '');
  return `  (${[
    sqlTxt(p.clave), sqlTxt(p.nombre), sqlTxt(p.email), sqlTxt(p.telefono), `date '${p.fecha_inicio}'`, `date '${p.fecha_fin}'`,
    sqlTxt(p.estado), sqlTxt(p.plan), sqlTxt(notas), `${sqlTxt(JSON.stringify(extra))}::jsonb`,
  ].join(', ')})`;
};

const sql = `-- =====================================================================
-- 125-producto-alumnos-teo-datos.sql  ·  PRODUCTO: carga de alumnos de Teo (North Ecom)
-- =====================================================================
-- GENERADO por scripts/generar-alumnos-teo.mjs el ${hoy} (datos de las planillas de Teo).
-- TIENE DATOS PERSONALES (nombres, telefonos, mails): esta en .gitignore. No lo subas, no lo
-- pegues en chats, no lo copies a otro lado.
--
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion). Evitar :00, :15, :30, :45 y las 9:00.
-- Requiere que el programa teo exista (113 o 001). Si la 113 corrio, usa los productos Grupal / 1 a 1
-- de teo (cs_productos) para producto_id; si no, deja producto_id null y guarda el plan como texto.
--
-- Contenido: ${personas.length} alumnos (${conMail} con mail), duracion ${DURACION} dias, estado al ${hoy}:
--   ${Object.entries(porEstado).map(([k, v]) => `${k} ${v}`).join(', ')}.
-- Clave anti-duplicado: cs_clientes.pago_clave = 'teo-xlsx|<nombre-normalizado>'.
-- Idempotente: no inserta a quien ya tenga esa clave NI a quien ya exista en teo con el mismo nombre
-- normalizado (cs_norm_nombre). Nunca actualiza ni pisa alumnos existentes. La 2da corrida inserta 0.
-- Fecha de fin = primer pago + ${DURACION} dias (parametro --duracion del script). Estado: activo si la
-- fecha de fin no paso, finalizado si paso, baja si la planilla marca que lo sacaron del WPP/DS/Skool
-- antes de terminar. Se insertan ya con su estado: no se dispara offboarding ni call de onboarding.
-- Si la plantilla de teo tiene accionables de dia 0, los activos los reciben (trigger normal).
-- =====================================================================
${sinAlumno.length ? `--
-- RESPUESTAS DE ONBOARDING QUE NO MATCHEARON NINGUN ALUMNO (${sinAlumno.length}). Revisar a mano:
-- pueden ser socios/parejas de un alumno, o alumnos que no estan en Pagos ni en Maestro.
${sinAlumno.map(o => `--   ${o.nombre || '(sin nombre)'} · ${o.mail}`).join('\n')}
` : ''}${mailsRepetidos.length ? `--
-- MAILS COMPARTIDOS (cada alumno quedo con su mail; el sync los resuelve por nombre):
${mailsRepetidos.map(([m, ps]) => `--   ${m}: ${ps.map(p => p.nombre).join(' / ')}`).join('\n')}
` : ''}
begin;

set local lock_timeout = '8s';

do $$
begin
  if not exists (select 1 from public.cs_programas where id = '${PROGRAMA}') then
    raise exception 'cs 125: no existe el programa ${PROGRAMA}';
  end if;
  if to_regprocedure('public.cs_norm_nombre(text)') is null then
    raise exception 'cs 125: falta cs_norm_nombre (migracion 070)';
  end if;
end $$;

-- Lock de todo lo que toca el insert (triggers incluidos), junto.
lock table public.cs_clientes, public.cs_accionables, public.cs_calls, public.cs_historial
  in share row exclusive mode;

create temp table imp125 (
  clave text primary key, nombre text not null, email text, telefono text,
  fecha_inicio date not null, fecha_fin date not null, estado text not null,
  plan text, notas text, campos_extra jsonb not null
) on commit drop;

insert into imp125 (clave, nombre, email, telefono, fecha_inicio, fecha_fin, estado, plan, notas, campos_extra) values
${personas.map(lineaValores).join(',\n')};

do $$
declare
  v_n int;
begin
  select count(*) into v_n from imp125;
  if v_n <> ${personas.length} then
    raise exception 'cs 125: se esperaban ${personas.length} filas y hay %', v_n;
  end if;
  if exists (select 1 from imp125 where email is not null and email !~* '^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$') then
    raise exception 'cs 125: hay mails con formato invalido';
  end if;
  if exists (select 1 from imp125 where fecha_fin < fecha_inicio) then
    raise exception 'cs 125: hay fechas de fin anteriores al inicio';
  end if;
end $$;

insert into public.cs_clientes
  (programa_id, nombre, email, telefono, fecha_inicio, fecha_fin, estado, plan, producto_id, notas, pago_clave, campos_extra)
select '${PROGRAMA}', i.nombre, lower(btrim(i.email)), i.telefono, i.fecha_inicio, i.fecha_fin, i.estado, i.plan,
       (select pr.id from public.cs_productos pr
         where pr.programa_id = '${PROGRAMA}' and public.cs_norm_nombre(pr.nombre) = public.cs_norm_nombre(i.plan)
         order by pr.orden limit 1),
       i.notas, i.clave, i.campos_extra
from imp125 i
where not exists (
  select 1 from public.cs_clientes c
  where c.programa_id = '${PROGRAMA}'
    and (c.pago_clave = i.clave or public.cs_norm_nombre(c.nombre) = public.cs_norm_nombre(i.nombre)))
order by i.nombre;

-- Control dentro de la transaccion: todo alumno del archivo existe en teo (nuevo o ya estaba).
do $$
declare
  v_falta text;
begin
  select string_agg(i.nombre, ', ') into v_falta
  from imp125 i
  where not exists (
    select 1 from public.cs_clientes c
    where c.programa_id = '${PROGRAMA}'
      and (c.pago_clave = i.clave or public.cs_norm_nombre(c.nombre) = public.cs_norm_nombre(i.nombre)));
  if v_falta is not null then
    raise exception 'cs 125: alumnos que no quedaron cargados: %', v_falta;
  end if;
end $$;

commit;


-- =====================================================================
-- CONTROLES (de a uno, despues de correr)
-- =====================================================================
-- C1. Esperado: ${personas.length} alumnos con clave teo-xlsx (la 1ra vez; la 2da corrida no cambia nada),
--     ${conMail} con mail.
-- select count(*) as alumnos, count(email) as con_mail from public.cs_clientes
-- where programa_id = 'teo' and pago_clave like 'teo-xlsx|%';

-- C2. Por estado y plan. Esperado estado: ${Object.entries(porEstado).map(([k, v]) => `${k} ${v}`).join(', ')}.
-- select estado, plan, count(*) from public.cs_clientes where programa_id = 'teo' group by 1, 2 order by 1, 2;

-- C3. Duplicados por nombre normalizado. Esperado: 0 filas.
-- select public.cs_norm_nombre(nombre) as nom, count(*) from public.cs_clientes
-- where programa_id = 'teo' group by 1 having count(*) > 1;

-- C4. Mails repetidos entre alumnos. Esperado: ${mailsRepetidos.length} (parejas/socios que comparten mail).
-- select lower(email) as mail, count(*) from public.cs_clientes
-- where programa_id = 'teo' and email is not null group by 1 having count(*) > 1;

-- C5. Sin telefono ni mail (no se podran matchear por mail; solo por nombre).
-- select count(*) from public.cs_clientes where programa_id = 'teo' and email is null;

-- C6. Productos asignados (null = la 113 no corrio o el plan no tiene producto: Comunidad).
-- select plan, producto_id is not null as con_producto, count(*) from public.cs_clientes
-- where programa_id = 'teo' and pago_clave like 'teo-xlsx|%' group by 1, 2 order by 1, 2;

-- C7. Que no se dispararon accionables de cierre ni calls de onboarding por esta carga.
-- select count(*) filter (where a.plantilla_key like 'cierre:%') as cierre
-- from public.cs_accionables a join public.cs_clientes c on c.id = a.cliente_id
-- where c.programa_id = 'teo' and c.pago_clave like 'teo-xlsx|%';   -- esperado 0

-- =====================================================================
-- VUELTA ATRAS (comentada): borra SOLO lo que cargo este archivo.
-- =====================================================================
-- begin;
-- delete from public.cs_clientes where programa_id = 'teo' and pago_clave like 'teo-xlsx|%';
-- commit;
`;

mkdirSync(dirname(SALIDA), { recursive: true });
writeFileSync(SALIDA, sql, 'utf8');
console.log(`\nEscrito ${SALIDA}`);
