/* Maestro — lista de columnas (071): las definiciones de siempre (maestro-celdas.js)
   + la config del programa (cs_maestro_columnas).
     - del sistema: la config solo cambia nombre visible, orden y si se muestra.
       etiqueta null = el nombre de siempre (Aviso N sigue leyendo los días del programa).
     - nuevas (clave x_...): se dibujan según el tipo y guardan en campos_extra
       por el mismo camino de guardado por celda (data-campo + data-extra).
   Orden: por el orden guardado; una del sistema sin orden usa su posición de siempre.
   config null (071 sin correr) = el Maestro de siempre. */
import { esc, urlSegura } from '../ui.js';
import { opcionesHtml } from './comunes.js';

const txt = v => String(v ?? '').toLowerCase();

function attrs(col, f, prev) {
  return `id="mx-${esc(col.k)}-${esc(f.id)}" data-campo="${esc(col.k)}" data-extra="${esc(col.tipo)}" data-id="${esc(f.id)}"
    data-prev="${esc(prev)}" aria-label="${esc(col.lab + ' de ' + f.nombre)}"`;
}

/* Una celda por tipo. v = valor guardado ('' si no hay). */
const CELDA = {
  texto: (col, f, v) => `<input type="text" class="m-edit" maxlength="2000" autocomplete="off" value="${esc(v)}"
    title="${esc(v)}" placeholder="—" ${attrs(col, f, v)}>`,
  numero: (col, f, v) => `<input type="number" step="any" class="m-edit m-x-num" value="${esc(v)}" placeholder="—"
    ${attrs(col, f, v)}>`,
  fecha: (col, f, v) => `<input type="date" class="m-edit m-fecha" value="${esc(v)}" ${attrs(col, f, v)}>`,
  casilla: (col, f, v) => `<input type="checkbox" class="m-check"${v === true ? ' checked' : ''}
    ${attrs(col, f, v === true ? '1' : '')}>`,
  opcion: (col, f, v) => {
    const ops = [['', '—']].concat(col.opciones.map(o => [o, o]));
    if (v && !col.opciones.includes(v)) ops.push([v, v + ' (fuera de lista)']);
    return `<select class="m-edit" ${attrs(col, f, v)}>${opcionesHtml(ops, v)}</select>`;
  },
  link: (col, f, v) => {
    const href = v ? urlSegura(v) : '';
    return `<span class="m-link"><input type="url" class="m-edit" maxlength="2000" autocomplete="off" value="${esc(v)}"
      title="${esc(v)}" placeholder="https://…" ${attrs(col, f, v)}>${href
      ? `<a class="m-abrir" href="${esc(href)}" target="_blank" rel="noopener noreferrer" title="Abrir en una pestaña nueva"
          aria-label="${esc('Abrir ' + col.lab + ' de ' + f.nombre)}">↗</a>` : ''}</span>`;
  }
};

/* Valor para ordenar: los vacíos van al final. */
const ORDEN = {
  numero: v => (typeof v === 'number' ? v : Infinity),
  fecha: v => v || '9999',
  casilla: v => (v ? 0 : 1)
};
const ordenTexto = v => txt(v) || '~';

function columnaNueva(r) {
  const tipo = CELDA[r.tipo] ? r.tipo : 'texto';
  const valor = f => (f.campos_extra || {})[r.clave];
  const col = {
    k: r.clave, lab: r.etiqueta || r.clave, cls: 'm-c-x m-c-x-' + tipo, edit: true,
    sistema: false, tipo, opciones: Array.isArray(r.opciones) ? r.opciones.map(String) : [],
    visible: r.visible !== false, orden: r.orden,
    ord: f => (ORDEN[tipo] || ordenTexto)(valor(f))
  };
  col.td = f => CELDA[tipo](col, f, valor(f) ?? '');
  return col;
}

/* base: columnas(prog, productos). Devuelve:
     visibles   -> las que se dibujan, en orden
     todas      -> visibles + ocultas, en orden (para el panel y para mandar el orden)
     archivadas -> columnas nuevas archivadas (el dato sigue guardado) */
export function armarColumnas(base, config) {
  const deBase = new Set(base.map(c => c.k));
  const fila = new Map((config || []).map(r => [r.clave, r]));
  /* Una del sistema sin orden guardado vale su posición de siempre x 10 (10, 20, 30...),
     lo mismo que escribe cs_maestro_columnas_ordenar: así las nuevas caen al final. */
  const todas = base.map((c, i) => {
    const r = fila.get(c.k);
    return {
      ...c, sistema: true, original: c.lab, lab: (r && r.etiqueta) || c.lab,
      visible: c.k === 'nombre' || !r || r.visible !== false,
      orden: r && r.orden != null ? r.orden : (i + 1) * 10
    };
  });
  const archivadas = [];
  for (const r of config || []) {
    if (deBase.has(r.clave) || r.sistema || !r.tipo) continue;
    (r.archivada ? archivadas : todas).push(columnaNueva(r));
  }
  /* sort es estable: a igual orden (o nuevas sin orden, al final) queda el orden de llegada. */
  const peso = c => (c.orden != null ? c.orden : Infinity);
  const lista = todas.slice().sort((a, b) => (peso(a) === peso(b) ? 0 : peso(a) - peso(b)));
  return { visibles: lista.filter(c => c.visible), todas: lista, archivadas };
}
