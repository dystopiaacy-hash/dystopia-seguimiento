/* Gráficos SVG armados a mano, mismo método que Dystopia (sin librerías ni canvas).
   El CSS ya existe en componentes.css, extraído de Dystopia en la Fase 0:
   .chart-svg, .chart-axis, .chart-gridline, .chart-tick, .bar-val, .bar-lab,
   .bar-g, .line-hit, .line-last.

   REGLA DE LA FASE: con cero datos —o con un solo punto en una línea— no se
   dibuja un gráfico deformado. Se devuelve un estado vacío que dice por qué.

   Todo texto que entra al SVG pasa por esc(): los labels salen de la base. */
import { esc } from './ui.js';

/* Paleta de gráficos de Dystopia, tal cual (no cambiar los hex acá sin cambiarlos allá). */
export const CHART_PALETTE = ['#4F46E5', '#0EA5A4', '#F0605D', '#F59E0B', '#8B5CF6', '#65A30D', '#0284C7', '#DB2777'];

let CHART_UID = 0;

/* Techo "redondo" del eje Y (1, 2, 2.5, 5, 10 × potencia de 10). */
export function niceMax(v) {
  if (!(v > 0)) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  const m = v / p;
  return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p;
}

export function fmtCompact(n) {
  n = Number(n) || 0;
  if (Math.abs(n) < 10000) return n.toLocaleString('es-AR', { maximumFractionDigits: 1 });
  return new Intl.NumberFormat('es-AR', { notation: 'compact', maximumFractionDigits: 1 }).format(n);
}

const nn = v => (v == null || v === '' || isNaN(Number(v)) ? null : Number(v));
const f1 = x => Number(x).toFixed(1);

/* ---------- Envoltorios ---------- */

/* Estado vacío con el mismo aspecto que el resto de la app. */
export function graficoVacio(texto) {
  return `<div class="empty-state grafico-vacio"><div class="small">${esc(texto)}</div></div>`;
}

/* cuerpo = HTML ya armado (SVG + leyenda). titulo y sub se escapan acá. */
export function tarjetaGrafico(titulo, sub, cuerpo) {
  return `<div class="card chart-card">
      <div class="chart-title">${esc(titulo)}</div>
      ${sub ? `<div class="chart-sub">${esc(sub)}</div>` : ''}
      ${cuerpo}
    </div>`;
}

/* Leyenda horizontal para los gráficos de más de una serie. */
export function leyenda(series) {
  return `<div class="chart-leyenda">${series.map(s =>
    `<span><span class="chart-leyenda-dot" style="background:${esc(s.color)}"></span>${esc(s.label)}</span>`
  ).join('')}</div>`;
}

/* ---------- Línea ---------- */

/* puntos = [{ label, value, titulo? }]; value null = mes sin datos (queda hueco).
   opts: { color, fmt, aria, vacio, max, width, height, ref: { valor, label } }
   `ref` dibuja una línea horizontal punteada (la del SLA de devoluciones). */
export function lineaSvg(puntos, opts = {}) {
  const lista = puntos || [];
  const fmt = opts.fmt || fmtCompact;
  const color = opts.color || CHART_PALETTE[0];
  const conDato = lista.filter(p => nn(p.value) != null);
  if (conDato.length < 2) {
    return graficoVacio(opts.vacio
      || (conDato.length === 1
        ? 'Solo hay un mes con datos: hacen falta dos para ver una evolución.'
        : 'Todavía no hay datos en este rango.'));
  }

  const W = opts.width || 640, H = opts.height || 230, L = 46, R = 22, T = 22, B = 30;
  const ref = opts.ref && nn(opts.ref.valor) != null ? Number(opts.ref.valor) : null;
  const tope = Math.max(...conDato.map(p => Number(p.value)), ref == null ? 0 : ref);
  const max = nn(opts.max) != null ? Number(opts.max) : niceMax(tope);
  const x = i => L + i * (W - L - R) / (lista.length - 1);
  const y = v => T + (1 - Math.min(1, Math.max(0, v / max))) * (H - T - B);

  /* Tramos de meses consecutivos con dato: cada hueco corta la línea en vez de
     inventar un valor intermedio. */
  const tramos = [];
  let actual = [];
  lista.forEach((p, i) => {
    const v = nn(p.value);
    if (v == null) { if (actual.length) tramos.push(actual); actual = []; return; }
    actual.push({ i, v });
  });
  if (actual.length) tramos.push(actual);

  const id = 'lg' + (++CHART_UID);
  const trazos = tramos.map(t => {
    if (t.length === 1) {
      return `<circle cx="${f1(x(t[0].i))}" cy="${f1(y(t[0].v))}" r="3.5" fill="${esc(color)}"/>`;
    }
    const d = t.map((q, k) => (k ? 'L' : 'M') + f1(x(q.i)) + ' ' + f1(y(q.v))).join(' ');
    const area = d + ` L${f1(x(t[t.length - 1].i))} ${H - B} L${f1(x(t[0].i))} ${H - B} Z`;
    return `<path d="${area}" fill="url(#${id})"/>
      <path d="${d}" fill="none" stroke="${esc(color)}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;
  }).join('');

  const ticks = [0, max / 2, max].map(t =>
    `<line x1="${L}" x2="${W - R}" y1="${f1(y(t))}" y2="${f1(y(t))}" class="chart-gridline"/>
     <text x="${L - 8}" y="${f1(y(t) + 4)}" text-anchor="end" class="chart-tick">${esc(fmt(t))}</text>`).join('');

  /* El label de la referencia va a la izquierda: a la derecha está siempre el
     valor del último punto y los dos textos se pisaban. */
  const lineaRef = ref == null ? '' : `
    <line x1="${L}" x2="${W - R}" y1="${f1(y(ref))}" y2="${f1(y(ref))}" class="chart-ref"/>
    <text x="${L + 4}" y="${f1(y(ref) - 6)}" text-anchor="start" class="chart-ref-lab">${esc(opts.ref.label || fmt(ref))}</text>`;

  const idx = [0, Math.floor((lista.length - 1) / 2), lista.length - 1].filter((v, i, a) => a.indexOf(v) === i);
  const xl = idx.map(i => `<text x="${f1(x(i))}" y="${H - 8}"
      text-anchor="${i === 0 ? 'start' : i === lista.length - 1 ? 'end' : 'middle'}"
      class="chart-tick">${esc(lista[i].label)}</text>`).join('');

  const w = (W - L - R) / (lista.length - 1);
  const hits = lista.map((p, i) => {
    const v = nn(p.value);
    const txt = p.titulo || `${p.label}: ${v == null ? 'sin datos' : fmt(v)}`;
    return `<rect x="${f1(x(i) - w / 2)}" y="${T}" width="${f1(w)}" height="${H - T - B}"
      fill="transparent" class="line-hit"><title>${esc(txt)}</title></rect>`;
  }).join('');

  const ult = conDato[conDato.length - 1];
  const ui = lista.indexOf(ult);
  return `<svg class="chart-svg" viewBox="0 0 ${W} ${H}" width="${W}" role="img" aria-label="${esc(opts.aria || 'Evolución')}">
    <defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${esc(color)}" stop-opacity=".22"/><stop offset="1" stop-color="${esc(color)}" stop-opacity="0"/>
    </linearGradient></defs>
    ${ticks}${lineaRef}${trazos}
    <circle cx="${f1(x(ui))}" cy="${f1(y(Number(ult.value)))}" r="5" fill="${esc(color)}" stroke="#fff" stroke-width="2"/>
    <text x="${f1(x(ui) - 8)}" y="${f1(y(Number(ult.value)) - 11)}" text-anchor="end" class="line-last">${esc(fmt(Number(ult.value)))}</text>
    ${xl}${hits}
  </svg>`;
}

/* ---------- Barras verticales ---------- */

/* data = [{ label, value, color }]. Ancho fijo por barra: con una sola barra el
   SVG no se estira, queda una barra angosta centrada en su lugar. */
export function barrasSvg(data, opts = {}) {
  const lista = (data || []).filter(d => d);
  if (!lista.length) return graficoVacio(opts.vacio || 'Todavía no hay datos en este rango.');
  const fmt = opts.fmt || fmtCompact;
  const W = Math.min(960, Math.max(360, lista.length * 104)), H = 240, top = 26, bottom = 40, side = 12;
  const max = niceMax(Math.max(...lista.map(d => Number(d.value) || 0)));
  const slot = (W - 2 * side) / lista.length;
  const bw = Math.min(40, slot * 0.56);
  const base = H - bottom;

  const barras = lista.map((d, i) => {
    const v = Number(d.value) || 0;
    const hgt = Math.max(v > 0 ? 2 : 0, (v / max) * (base - top));
    const bx = side + i * slot + (slot - bw) / 2, by = base - hgt;
    const rr = Math.min(4, hgt, bw / 2);
    const path = hgt > 0
      ? `M${f1(bx)} ${base} V${f1(by + rr)} Q${f1(bx)} ${f1(by)} ${f1(bx + rr)} ${f1(by)} H${f1(bx + bw - rr)} Q${f1(bx + bw)} ${f1(by)} ${f1(bx + bw)} ${f1(by + rr)} V${base} Z`
      : '';
    const maxChars = Math.max(4, Math.floor(slot / 6.4));
    const etiqueta = String(d.label == null ? '' : d.label);
    const lab = etiqueta.length > maxChars ? etiqueta.slice(0, maxChars - 1) + '…' : etiqueta;
    return `<g class="bar-g"><title>${esc(etiqueta)}: ${esc(fmt(v))}</title>
      <rect x="${f1(side + i * slot)}" y="${top - 20}" width="${f1(slot)}" height="${base - top + 20}" fill="transparent"/>
      ${path ? `<path d="${path}" fill="${esc(d.color || CHART_PALETTE[0])}"/>` : ''}
      <text x="${f1(bx + bw / 2)}" y="${f1(by - 7)}" text-anchor="middle" class="bar-val">${esc(fmt(v))}</text>
      <text x="${f1(bx + bw / 2)}" y="${base + 18}" text-anchor="middle" class="bar-lab">${esc(lab)}</text>
    </g>`;
  }).join('');

  return `<svg class="chart-svg" viewBox="0 0 ${W} ${H}" width="${W}" role="img" aria-label="${esc(opts.aria || 'Barras')}">
    <line x1="${side}" x2="${W - side}" y1="${base}" y2="${base}" class="chart-axis"/>
    ${barras}
  </svg>`;
}

/* ---------- Barras agrupadas ---------- */

/* grupos = ['ene 26', …]; series = [{ label, color, valores: [n, …] }].
   Con un solo grupo tampoco se deforma: el grupo conserva su ancho. */
export function barrasAgrupadasSvg(grupos, series, opts = {}) {
  const gs = grupos || [], ss = (series || []).filter(s => s && s.valores);
  if (!gs.length || !ss.length) return graficoVacio(opts.vacio || 'Todavía no hay datos en este rango.');
  const fmt = opts.fmt || fmtCompact;
  const anchoGrupo = Math.max(48, ss.length * 16 + 24);
  const W = Math.min(960, Math.max(360, gs.length * anchoGrupo + 40));
  const H = 240, top = 24, bottom = 40, side = 26, base = H - bottom;
  const max = niceMax(Math.max(0, ...ss.flatMap(s => s.valores.map(v => Number(v) || 0))));
  const slot = (W - 2 * side) / gs.length;
  const bw = Math.min(18, (slot * 0.74) / ss.length);
  const conTexto = bw >= 14 && slot / ss.length >= 22;
  const y = v => top + (1 - v / max) * (base - top);

  const ticks = [0, max / 2, max].map(t =>
    `<line x1="${side}" x2="${W - side}" y1="${f1(y(t))}" y2="${f1(y(t))}" class="chart-gridline"/>
     <text x="${side - 6}" y="${f1(y(t) + 4)}" text-anchor="end" class="chart-tick">${esc(fmt(t))}</text>`).join('');

  const paso = slot < 52 ? Math.ceil(52 / slot) : 1;
  const cuerpo = gs.map((g, i) => {
    const x0 = side + i * slot + (slot - bw * ss.length) / 2;
    const barras = ss.map((s, k) => {
      const v = Number(s.valores[i]) || 0;
      const hgt = Math.max(v > 0 ? 2 : 0, (v / max) * (base - top));
      const bx = x0 + k * bw, by = base - hgt;
      const ancho = Math.max(2, bw - 3);
      return `<g class="bar-g"><title>${esc(g)} · ${esc(s.label)}: ${esc(fmt(v))}</title>
        <rect x="${f1(bx)}" y="${top}" width="${f1(bw)}" height="${base - top}" fill="transparent"/>
        ${hgt > 0 ? `<rect x="${f1(bx)}" y="${f1(by)}" width="${f1(ancho)}" height="${f1(hgt)}" rx="2" fill="${esc(s.color)}"/>` : ''}
        ${conTexto && v > 0 ? `<text x="${f1(bx + ancho / 2)}" y="${f1(by - 5)}" text-anchor="middle" class="bar-val bar-val-sm">${esc(fmt(v))}</text>` : ''}
      </g>`;
    }).join('');
    const lab = i % paso === 0
      ? `<text x="${f1(side + i * slot + slot / 2)}" y="${base + 18}" text-anchor="middle" class="bar-lab">${esc(g)}</text>`
      : '';
    return barras + lab;
  }).join('');

  return `<svg class="chart-svg" viewBox="0 0 ${W} ${H}" width="${W}" role="img" aria-label="${esc(opts.aria || 'Barras por mes')}">
    ${ticks}
    <line x1="${side}" x2="${W - side}" y1="${base}" y2="${base}" class="chart-axis"/>
    ${cuerpo}
  </svg>`;
}

/* ---------- Barra apilada (distribución de un total) ---------- */

/* segmentos = [{ label, value, color }]. HTML, no SVG: es una sola barra con
   leyenda, y así hereda el ancho de la tarjeta sin escalar el texto. */
export function barraApilada(segmentos, opts = {}) {
  const lista = (segmentos || []).map(s => ({ ...s, value: Number(s.value) || 0 }));
  const total = lista.reduce((a, s) => a + s.value, 0);
  if (!total) return graficoVacio(opts.vacio || 'Todavía no hay clientes para distribuir.');
  const pct = v => Math.round((1000 * v) / total) / 10;
  const barra = lista.filter(s => s.value > 0).map(s =>
    `<span style="flex-grow:${s.value};background:${esc(s.color)}" title="${esc(`${s.label}: ${s.value} (${pct(s.value)}%)`)}"></span>`
  ).join('');
  const filas = lista.map(s => `
    <div class="apilada-fila">
      <span class="dot" style="background:${esc(s.color)}"></span>
      <span class="apilada-label">${esc(s.label)}</span>
      <span class="apilada-val">${s.value}</span>
      <span class="apilada-pct">${esc(String(pct(s.value)).replace('.', ',') + '%')}</span>
    </div>`).join('');
  return `<div class="apilada">
      <div class="apilada-barra" role="img" aria-label="${esc(lista.map(s => `${s.label}: ${s.value}`).join(', '))}">${barra}</div>
      <div class="apilada-total">${total} en total</div>
      <div class="apilada-leyenda">${filas}</div>
    </div>`;
}
