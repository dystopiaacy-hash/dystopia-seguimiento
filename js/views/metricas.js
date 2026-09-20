/* Métricas del programa (#/p/:programa/metricas).
   La fuente es cs_v_metricas_mensuales: altas, renovados, no renovados,
   devoluciones entregadas, horas promedio de entrega, satisfacción promedio y n
   de respuestas ya vienen calculadas por la vista y acá no se recalculan.
   Lo único que se arma en JS es lo que la vista no tiene: la grilla de meses del
   rango (la vista solo devuelve meses con eventos), los clientes con programa
   vigente en cada mes, la distribución de semáforo de hoy y el agrupado de
   motivos de no renovación por su prefijo.
   Gráficos: js/graficos.js (SVG a mano, mismo método que Dystopia). */
import { esc, plural, toast, hoyAR, descargarCSV } from '../ui.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerClientes, traerMetricasMensuales, traerRenovacionesPrograma,
  mensajeError, esVivo, ESTADO_LABEL, MOTIVO_NO_RENOVACION
} from '../datos.js';
import { num, filtroSelect } from './comunes.js';
import {
  CHART_PALETTE, lineaSvg, barrasSvg, barrasAgrupadasSvg, barraApilada,
  tarjetaGrafico, leyenda, fmtCompact
} from '../graficos.js';

const RANGOS = [['3', 'Últimos 3 meses'], ['6', 'Últimos 6 meses'], ['12', 'Últimos 12 meses']];
const RANGO_POR_DEFECTO = '6';
/* El rango elegido se recuerda mientras la pestaña esté abierta. */
const RANGOS_ELEGIDOS = new Map();

const COL_ALTAS = CHART_PALETTE[0];
const COL_RENOVADOS = 'var(--sem-verde)';
const COL_NO_RENOVADOS = 'var(--sem-rojo)';

/* ---------- Grilla de meses ---------- */

const fmtMes = new Intl.DateTimeFormat('es-AR', { timeZone: 'UTC', month: 'short', year: '2-digit' });

function etiquetaMes(y, m) {
  return fmtMes.format(new Date(Date.UTC(y, m - 1, 1))).replace(/\./g, '');
}

const dosDig = n => String(n).padStart(2, '0');

/* Los últimos n meses cerrados en el mes actual de Buenos Aires, del más viejo al
   más nuevo. clave = primer día del mes ('YYYY-MM-01'), como la columna `mes`. */
function mesesRango(n) {
  const [y, m] = hoyAR().split('-').map(Number);
  const out = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(Date.UTC(y, m - 1 - i, 1));
    const yy = d.getUTCFullYear(), mm = d.getUTCMonth() + 1;
    out.push({
      clave: `${yy}-${dosDig(mm)}-01`,
      fin: `${yy}-${dosDig(mm)}-${dosDig(new Date(Date.UTC(yy, mm, 0)).getUTCDate())}`,
      label: etiquetaMes(yy, mm)
    });
  }
  return out;
}

/* mes -> fila de la vista. Los meses sin eventos no vienen: quedan en null. */
function porMes(filas) {
  const m = new Map();
  for (const f of filas || []) m.set(String(f.mes).slice(0, 10), f);
  return m;
}

const valor = (mapa, clave, col) => {
  const f = mapa.get(clave);
  return f && f[col] != null ? Number(f[col]) : null;
};
const cuenta = (mapa, clave, col) => {
  const f = mapa.get(clave);
  return f ? Number(f[col]) || 0 : 0;
};

/* ---------- Lo que la vista no calcula ---------- */

/* Clientes con el programa vigente en el mes: su ventana fecha_inicio→fecha_fin
   se cruza con el mes. Las fechas son 'YYYY-MM-DD', así que se comparan como texto.
   OJO: una baja anticipada no tiene fecha propia en la base, así que un cliente
   dado de baja sigue contando hasta su fecha_fin original. */
function vigentesPorMes(clientes, meses) {
  return meses.map(m => clientes.filter(c =>
    c.fecha_inicio && c.fecha_fin && c.fecha_inicio <= m.fin && c.fecha_fin >= m.clave).length);
}

/* Motivos agrupados por su prefijo ("Precio: muy caro" -> "Precio"), que es como
   los arma armarMotivo() al cerrar una renovación.
   Las categorías son las de MOTIVO_NO_RENOVACION y nada más: un motivo viejo o
   escrito a mano, sin prefijo conocido, cae en "Sin clasificar". Si se usara el
   texto libre como categoría, cada renovación inventaría su propia barra y el
   gráfico pasaría a ser una lista de frases sueltas. */
function motivosNoRenovacion(renovaciones, desde) {
  const cuentas = new Map(Object.values(MOTIVO_NO_RENOVACION).map(t => [t, 0]));
  cuentas.set('Sin clasificar', 0);
  for (const r of renovaciones || []) {
    if (r.estado !== 'no_renovado') continue;
    if (desde && !(r.resultado_at && String(r.resultado_at).slice(0, 10) >= desde)) continue;
    const prefijo = String(r.motivo || '').split(':')[0].trim();
    const clave = cuentas.has(prefijo) && prefijo !== 'Sin clasificar' ? prefijo : 'Sin clasificar';
    cuentas.set(clave, cuentas.get(clave) + 1);
  }
  const filas = Array.from(cuentas, ([label, value]) => ({ label, value }))
    .filter(f => f.value > 0)
    .sort((a, b) => b.value - a.value);
  return filas.map((f, i) => ({ ...f, color: CHART_PALETTE[i % CHART_PALETTE.length] }));
}

function distribucionSemaforo(clientes) {
  const vivos = clientes.filter(esVivo);
  const n = nivel => vivos.filter(c => c.semaforo === nivel).length;
  return [
    { label: 'Rojo · hay que actuar ya', value: n('rojo'), color: 'var(--sem-rojo)' },
    { label: 'Amarillo · mirar pronto', value: n('amarillo'), color: 'var(--sem-amarillo)' },
    { label: 'Verde · al día', value: n('verde'), color: 'var(--sem-verde)' }
  ];
}

/* ---------- Formatos ---------- */

const fmtSat = v => (v == null ? '—' : Number(v).toFixed(1).replace('.', ','));
const fmtHs = v => fmtCompact(v) + ' h';

/* ---------- Gráficos ---------- */

function graficos(prog, clientes, mapa, meses, renovaciones) {
  const claves = meses.map(m => m.clave);
  const labels = meses.map(m => m.label);
  const desde = meses[0].clave;

  const vigentes = vigentesPorMes(clientes, meses);
  const activos = tarjetaGrafico('Clientes con programa vigente por mes',
    'Cuenta los clientes cuyo programa estaba en curso en ese mes.',
    lineaSvg(labels.map((label, i) => ({ label, value: vigentes[i] })), {
      color: CHART_PALETTE[0], aria: 'Clientes con programa vigente por mes',
      fmt: v => fmtCompact(Math.round(v))
    }));

  const series = [
    { label: 'Altas', color: COL_ALTAS, valores: claves.map(k => cuenta(mapa, k, 'altas')) },
    { label: 'Renovados', color: COL_RENOVADOS, valores: claves.map(k => cuenta(mapa, k, 'renovados')) },
    { label: 'No renovados', color: COL_NO_RENOVADOS, valores: claves.map(k => cuenta(mapa, k, 'no_renovados')) }
  ];
  const hayMovimiento = series.some(s => s.valores.some(v => v > 0));
  const altas = tarjetaGrafico('Altas, renovaciones y bajas por renovación',
    'Altas por fecha de inicio; renovados y no renovados por fecha de cierre.',
    hayMovimiento
      ? barrasAgrupadasSvg(labels, series, { aria: 'Altas, renovados y no renovados por mes' }) + leyenda(series)
      : barrasAgrupadasSvg([], [], { vacio: 'No hubo altas ni renovaciones cerradas en este rango.' }));

  const sat = tarjetaGrafico('Satisfacción promedio por mes (0 a 10)',
    'De las respuestas de formularios con puntaje. El n de cada mes está en el globo.',
    lineaSvg(labels.map((label, i) => {
      const v = valor(mapa, claves[i], 'satisfaccion_prom');
      const n = cuenta(mapa, claves[i], 'respuestas');
      return {
        label, value: v,
        titulo: v == null ? `${label}: sin respuestas` : `${label}: ${fmtSat(v)} · n = ${plural(n, 'respuesta')}`
      };
    }), { color: CHART_PALETTE[4], max: 10, fmt: fmtSat, aria: 'Satisfacción promedio por mes' }));

  const slaHoras = num(prog.sla_devolucion_horas);
  const entrega = tarjetaGrafico('Tiempo promedio de entrega de devoluciones',
    `Horas desde que se solicitó hasta que se entregó. SLA del programa: ${plural(slaHoras, 'hora')}.`,
    lineaSvg(labels.map((label, i) => {
      const v = valor(mapa, claves[i], 'horas_prom_entrega_devolucion');
      const n = cuenta(mapa, claves[i], 'devoluciones_entregadas');
      return {
        label, value: v,
        titulo: v == null ? `${label}: sin devoluciones entregadas`
          : `${label}: ${fmtHs(v)} promedio · ${plural(n, 'devolución', 'devoluciones')}`
      };
    }), {
      color: CHART_PALETTE[1], fmt: fmtHs, aria: 'Horas promedio de entrega de devoluciones',
      ref: slaHoras > 0 ? { valor: slaHoras, label: `SLA ${slaHoras} h` } : null
    }));

  const semaforo = tarjetaGrafico('Distribución de semáforo (hoy)',
    'Clientes en onboarding, activos y en renovación. No depende del rango elegido.',
    barraApilada(distribucionSemaforo(clientes), { vacio: 'No hay clientes vivos en este programa.' }));

  const motivos = motivosNoRenovacion(renovaciones, desde);
  const motivosCard = tarjetaGrafico('Motivos de no renovación',
    'Renovaciones cerradas como "no renovó" en el rango, agrupadas por motivo.',
    barrasSvg(motivos, {
      aria: 'Motivos de no renovación', fmt: v => fmtCompact(Math.round(v)),
      vacio: 'Ninguna renovación se cerró como "no renovó" en este rango.'
    }));

  return `
    <div class="chart-grid-2">${activos}${altas}</div>
    <div class="chart-grid-2">${sat}${entrega}</div>
    <div class="chart-grid-2">${semaforo}${motivosCard}</div>`;
}

/* ---------- Export CSV ---------- */

/* Solo nombre, email y métricas. Nada de teléfono, notas, etapa ni fechas:
   el CSV sale de la app y estos son datos de personas (Ley 25.326). */
const COLUMNAS_CSV = [
  ['Nombre', c => c.nombre],
  ['Email', c => c.email || ''],
  ['Estado', c => ESTADO_LABEL[c.estado] || c.estado],
  ['Semáforo', c => c.semaforo],
  ['Días restantes', c => c.dias_restantes],
  ['% del programa', c => c.pct_programa],
  ['Accionables BPF pendientes', c => c.acc_bpf_pendientes],
  ['Accionables BPF vencidos', c => c.acc_bpf_vencidos],
  ['Accionables cliente pendientes', c => c.acc_cliente_pendientes],
  ['Accionables cliente vencidos', c => c.acc_cliente_vencidos],
  ['Devoluciones pendientes', c => c.dev_pendientes],
  ['Devoluciones fuera de SLA', c => c.dev_vencidas_sla],
  ['Días sin chequeo', c => c.dias_sin_chequeo],
  ['Renovaciones', c => c.renovaciones_count]
];

function exportar(programaId, clientes) {
  const filas = [COLUMNAS_CSV.map(c => c[0])];
  for (const c of clientes) filas.push(COLUMNAS_CSV.map(col => col[1](c)));
  descargarCSV(`metricas-${programaId}-${hoyAR()}.csv`, filas);
  toast(`CSV con ${plural(clientes.length, 'cliente')}.`);
}

/* ---------- Vista ---------- */

export function vistaMetricas(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let prog = null, clientes = [], renovaciones = [], mapa = new Map();

  const rango = () => RANGOS_ELEGIDOS.get(programaId) || RANGO_POR_DEFECTO;

  function pintar() {
    const meses = mesesRango(Number(rango()));
    const vivos = clientes.filter(esVivo).length;
    el.innerHTML = `
      <div class="barra-acciones met-barra">
        <div class="section-title">Métricas<span class="line"></span></div>
        ${filtroSelect('met-rango', 'Rango', RANGOS, rango())}
        <button type="button" class="btn btn-sm" id="met-csv">Exportar CSV</button>
      </div>
      <div class="hint met-resumen">${esc(
        `${plural(clientes.length, 'cliente')} en total · ${vivos} vivos · desde ${meses[0].label} hasta ${meses[meses.length - 1].label}`
      )}</div>
      ${graficos(prog, clientes, mapa, meses, renovaciones)}`;

    el.querySelector('#met-rango').addEventListener('change', ev => {
      RANGOS_ELEGIDOS.set(programaId, ev.target.value);
      cargar().catch(e => toast(mensajeError(e), 'error'));
    });
    el.querySelector('#met-csv').addEventListener('click', () => {
      if (!clientes.length) { toast('No hay clientes para exportar.', 'error'); return; }
      exportar(programaId, clientes);
    });
  }

  async function cargar() {
    const meses = mesesRango(Number(rango()));
    const [p, cls, mm, rens] = await Promise.all([
      traerPrograma(programaId), traerClientes(programaId),
      traerMetricasMensuales(programaId, meses[0].clave), traerRenovacionesPrograma(programaId)
    ]);
    if (!vigente()) return;
    if (!p) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    prog = p; clientes = cls; renovaciones = rens; mapa = porMes(mm);
    pintar();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las métricas', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('metricas', e)) };
}
