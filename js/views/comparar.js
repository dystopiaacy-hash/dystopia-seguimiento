/* Comparar (#/p/:programa/comparar): dos meses del programa, número grande A contra B y variación %.
   Misma idea que Marketing > Contenido > Comparar. Fuentes (nada nuevo en la base):
   - Alumnos activos: clientes con el programa vigente en el mes (fecha_inicio a fecha_fin), igual que Métricas.
     OJO: una baja anticipada no tiene fecha propia, así que cuenta hasta su fecha_fin original.
   - Altas, bajas (= renovaciones cerradas como "no renovado") y renovaciones: cs_v_metricas_mensuales.
   - Seguimientos hechos: filas de cs_seguimientos con fecha en el mes (datos-comparar.js).
   - Cuotas al día / atrasadas: la base solo guarda el estado de HOY (cs_estado_pagos_alumno), no por mes.
     Se muestra solo si el mes es el actual; en meses cerrados dice "Sin datos". */
import { esc, hoyAR, toast } from '../ui.js';
import { tarjetaError } from './programa.js';
import { traerClientes, traerMetricasMensuales, mensajeError, esVivo } from '../datos.js';
import { contarSeguimientos } from '../datos-comparar.js';
import { traerEstadoPagos, nivelPagos } from '../datos-pagos.js';

const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const dos = n => String(n).padStart(2, '0');
const ELEGIDOS = new Map();   // programa -> { a, b } mientras la pestaña esté abierta
const N_MESES = 18;

/* Meses 'YYYY-MM' desde el actual hacia atrás. */
function ultimosMeses(n) {
  const [y, m] = hoyAR().split('-').map(Number);
  return Array.from({ length: n }, (_, i) => {
    const d = new Date(Date.UTC(y, m - 1 - i, 1));
    return `${d.getUTCFullYear()}-${dos(d.getUTCMonth() + 1)}`;
  });
}
const textoMes = ym => { const [y, m] = ym.split('-').map(Number); return `${MESES[m - 1]} ${y}`; };
const inicioMes = ym => `${ym}-01`;
const finMes = ym => { const [y, m] = ym.split('-').map(Number); return `${ym}-${dos(new Date(Date.UTC(y, m, 0)).getUTCDate())}`; };
const esMesActual = ym => ym === hoyAR().slice(0, 7);

/* Variación de b respecto de a. null si no hay base (a es 0 o falta un dato). */
function variacion(a, b) {
  if (a == null || b == null) return null;
  if (a === 0) return b === 0 ? { pct: 0, abs: 0 } : { pct: null, abs: b };
  return { pct: ((b - a) / a) * 100, abs: b - a };
}

function chipVariacion(v, subeEsMalo) {
  if (!v) return '<span class="cmp-chip cmp-nd">Sin comparación</span>';
  if (v.abs === 0) return '<span class="cmp-chip cmp-igual">Sin cambios</span>';
  const sube = v.abs > 0;
  const mal = subeEsMalo ? sube : !sube;
  const clase = mal ? 'delta-mal' : 'delta-bien';
  const signo = sube ? '+' : '−';
  const texto = v.pct == null ? `${signo}${Math.abs(v.abs)} (sin base)` : `${signo}${Math.abs(v.pct).toFixed(1).replace('.', ',').replace(',0', '')}%`;
  return `<span class="cmp-chip kpi-delta ${clase}">${texto}</span>`;
}

const fmt = v => (v == null ? 'Sin datos' : Number(v).toLocaleString('es-AR'));

/* Una tarjeta: etiqueta, A y B grandes, barras A/B y variación. */
function tarjeta({ titulo, ayuda, a, b, subeEsMalo = false, nota = '' }) {
  const max = Math.max(a || 0, b || 0, 1);
  const barra = (v, k) => `<div class="cmp-barra" aria-hidden="true"><span class="cmp-barra-${k}" style="width:${v == null ? 0 : Math.round((v / max) * 100)}%"></span></div>`;
  const val = (v, k, mes) => `<div class="cmp-val"><div class="cmp-val-et"><span class="cmp-tag cmp-tag-${k}">${k.toUpperCase()}</span> ${esc(mes)}</div>
    <div class="cmp-num${v == null ? ' cmp-num-nd' : ''}">${fmt(v)}</div>${barra(v, k)}</div>`;
  return { html: (m1, m2) => `<section class="cmp-card" role="group" aria-label="${esc(titulo)}: ${esc(m1)} ${fmt(a)}, ${esc(m2)} ${fmt(b)}">
    <div class="cmp-card-tit">${esc(titulo)}</div>
    ${ayuda ? `<div class="cmp-card-ayuda">${esc(ayuda)}</div>` : ''}
    <div class="cmp-vals">${val(a, 'a', m1)}${val(b, 'b', m2)}</div>
    <div class="cmp-card-pie">${chipVariacion(variacion(a, b), subeEsMalo)}${nota ? `<span class="cmp-nota">${esc(nota)}</span>` : ''}</div>
  </section>`, sinDato: a == null || b == null, titulo };
}

/* Cuotas del estado de hoy: al día y atrasadas entre los alumnos vivos con vínculo. */
function resumenPagos(clientes, mapa) {
  if (!mapa) return null;
  let aldia = 0, atras = 0;
  for (const c of clientes.filter(esVivo)) {
    const n = nivelPagos(mapa.get(c.id));
    if (n === 'al_dia') aldia++;
    else if (n === 'atrasado') atras++;
  }
  return { aldia, atras };
}

async function datosMes(programaId, ym, clientes, metricas, pagos) {
  const f = metricas.get(inicioMes(ym)) || {};
  const ini = inicioMes(ym), fin = finMes(ym);
  const n = k => Number(f[k]) || 0;
  const vigentes = clientes.filter(c => c.fecha_inicio && c.fecha_fin && c.fecha_inicio <= fin && c.fecha_fin >= ini).length;
  let seguimientos = null;
  try { seguimientos = await contarSeguimientos(programaId, ini, fin); } catch (e) { console.error('comparar seguimientos', e); }
  const hoy = esMesActual(ym);
  return {
    activos: vigentes, altas: n('altas'), bajas: n('no_renovados'), renovaciones: n('renovados'), seguimientos,
    aldia: hoy && pagos ? pagos.aldia : null, atrasadas: hoy && pagos ? pagos.atras : null
  };
}

function armar(a, b, ma, mb) {
  const T = [
    tarjeta({ titulo: 'Alumnos activos', ayuda: 'Con el programa vigente en el mes', a: a.activos, b: b.activos }),
    tarjeta({ titulo: 'Altas nuevas', a: a.altas, b: b.altas }),
    tarjeta({ titulo: 'Bajas', ayuda: 'Renovaciones cerradas como "no renovó"', a: a.bajas, b: b.bajas, subeEsMalo: true }),
    tarjeta({ titulo: 'Renovaciones', ayuda: 'Cerradas como "renovó"', a: a.renovaciones, b: b.renovaciones }),
    tarjeta({ titulo: 'Seguimientos hechos', ayuda: 'Cargados por el CSM en el mes', a: a.seguimientos, b: b.seguimientos }),
    tarjeta({ titulo: 'Cuotas al día', ayuda: 'Solo existe el estado de hoy', a: a.aldia, b: b.aldia, nota: 'Foto de hoy' }),
    tarjeta({ titulo: 'Cuotas atrasadas', ayuda: 'Solo existe el estado de hoy', a: a.atrasadas, b: b.atrasadas, subeEsMalo: true, nota: 'Foto de hoy' })
  ];
  const sin = T.filter(t => t.sinDato).map(t => t.titulo);
  const aviso = sin.length
    ? `<div class="cmp-franja"><span><strong>Sin datos:</strong> ${esc(sin.join(', '))}. ${sin.some(s => s.startsWith('Cuotas'))
        ? 'La base guarda el estado de pagos de hoy, no el de cada mes: las cuotas solo se comparan cuando el mes es el actual.' : ''}</span></div>`
    : '';
  return `<div class="cmp-grid">${T.map(t => t.html(textoMes(ma), textoMes(mb))).join('')}</div>${aviso}`;
}

export function vistaComparar(el, programaId, vigente) {
  const meses = ultimosMeses(N_MESES);
  const sel = ELEGIDOS.get(programaId) || { a: meses[1], b: meses[0] };
  ELEGIDOS.set(programaId, sel);
  let clientes = [], pagos = null, cargado = false;

  const opts = v => meses.map(m => `<option value="${m}"${m === v ? ' selected' : ''}>${esc(textoMes(m))}${esMesActual(m) ? ' (en curso)' : ''}</option>`).join('');
  el.innerHTML = `<div class="cmp-controles card">
      <label class="cmp-sel"><span class="cmp-tag cmp-tag-a">A</span><span class="cmp-sel-et">Mes A</span><select id="cmp-a" aria-label="Mes A">${opts(sel.a)}</select></label>
      <button type="button" class="btn btn-sm" id="cmp-swap" title="Intercambiar A y B" aria-label="Intercambiar A y B">⇄</button>
      <label class="cmp-sel"><span class="cmp-tag cmp-tag-b">B</span><span class="cmp-sel-et">Mes B</span><select id="cmp-b" aria-label="Mes B">${opts(sel.b)}</select></label>
      <div class="cmp-hint">Los números grandes son de cada mes; el chip es la variación de B respecto de A.</div>
    </div>
    <div id="cmp-res"><div class="loading-inline">Cargando…</div></div>`;
  const res = el.querySelector('#cmp-res');

  async function pintar() {
    if (!cargado) return;
    res.innerHTML = '<div class="loading-inline">Calculando…</div>';
    try {
      const orden = [sel.a, sel.b].sort();
      const filas = await traerMetricasMensuales(programaId, inicioMes(orden[0]));
      const mapa = new Map(filas.map(f => [String(f.mes).slice(0, 10), f]));
      const [da, db] = await Promise.all([sel.a, sel.b].map(m => datosMes(programaId, m, clientes, mapa, pagos)));
      if (!vigente()) return;
      res.innerHTML = armar(da, db, sel.a, sel.b);
    } catch (e) {
      if (vigente()) res.innerHTML = tarjetaError('No se pudo armar la comparación', mensajeError(e));
    }
  }

  const poner = (k, v) => { sel[k] = v; pintar(); };
  el.querySelector('#cmp-a').onchange = ev => poner('a', ev.target.value);
  el.querySelector('#cmp-b').onchange = ev => poner('b', ev.target.value);
  el.querySelector('#cmp-swap').onclick = () => {
    [sel.a, sel.b] = [sel.b, sel.a];
    el.querySelector('#cmp-a').value = sel.a;
    el.querySelector('#cmp-b').value = sel.b;
    pintar();
  };

  (async () => {
    clientes = await traerClientes(programaId);
    if (!vigente()) return;
    try { pagos = resumenPagos(clientes, await traerEstadoPagos(clientes.map(c => c.id))); } catch (e) { console.error('comparar pagos', e); }
    cargado = true;
    await pintar();
  })().catch(e => {
    if (vigente()) res.innerHTML = tarjetaError('No se pudo cargar Comparar', mensajeError(e));
    else toast(mensajeError(e), 'error');
  });
  return { refrescar: () => pintar() };
}
