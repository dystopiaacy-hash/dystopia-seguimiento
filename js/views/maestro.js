/* Maestro de clientes del CSM (#/p/:programa/maestro).
   Una planilla con todos los clientes del programa, sobre cs_v_maestro (037).
   cs_clientes sigue siendo la única fuente de verdad: las celdas editables escriben
   ahí (y en cs_renovaciones para el resell); las calculadas vienen de la vista.
   Sin botón de guardar: cada celda se guarda sola (maestro-celdas.js).
   Tiempo real: app.js llama a refrescar() cuando cambia cs_clientes o
   cs_renovaciones del programa; se repinta conservando el campo con foco y lo
   que tiene escrito (mismo patrón que la ficha). En celular, tarjetas. */
import { esc, plural } from '../ui.js';
import { tarjetaError } from './programa.js';
import { filtroSelect, opcionesHtml, repintarConservandoFoco, mapaPorId } from './comunes.js';
import {
  traerPrograma, traerMaestro, mensajeError, renAbierta,
  REN_ABIERTOS, REN_LABEL, PRIORIDAD_LABEL
} from '../datos.js';
import { columnas, manejarCambio, manejarTecla } from './maestro-celdas.js';
import { manejarClick } from './maestro-ciclo.js';

/* ---------- Filtros ---------- */

const FILTROS_VACIOS = { resell: '', prioridad: '', responsable: '', q: '' };

function responsables(filas) {
  return Array.from(new Set(filas.map(f => (f.responsable || '').trim()).filter(Boolean)))
    .sort((a, b) => a.localeCompare(b, 'es'));
}

const opcionesResponsable = filas =>
  [['', 'Todos'], ['sin', 'Sin asignar']].concat(responsables(filas).map(v => [v, v]));

function pasa(fila, f) {
  const r = fila.renovacion_estado || '';
  if (f.resell === 'sin' && r) return false;
  if (f.resell === 'abierta' && !renAbierta(r)) return false;
  if (f.resell && !['sin', 'abierta'].includes(f.resell) && r !== f.resell) return false;
  if (f.prioridad === 'sin' && fila.prioridad) return false;
  if (f.prioridad && f.prioridad !== 'sin' && fila.prioridad !== f.prioridad) return false;
  if (f.responsable === 'sin' && (fila.responsable || '').trim()) return false;
  if (f.responsable && f.responsable !== 'sin' && (fila.responsable || '').trim() !== f.responsable) return false;
  const q = f.q.trim().toLowerCase();
  return !q || (fila.nombre || '').toLowerCase().includes(q);
}

function ordenar(filas, cols, orden) {
  const col = cols.find(c => c.k === orden.k) || cols[0];
  const dir = orden.desc ? -1 : 1;
  return filas.slice().sort((a, b) => {
    const va = col.ord(a), vb = col.ord(b);
    if (va < vb) return -dir;
    if (va > vb) return dir;
    return (a.nombre || '').localeCompare(b.nombre || '', 'es');
  });
}

function barraFiltros(f, filas) {
  const resell = [['', 'Todos'], ['abierta', 'En pipeline (abiertos)'], ['sin', 'Sin pipeline']]
    .concat(REN_ABIERTOS.concat(['renovado', 'no_renovado']).map(e => [e, REN_LABEL[e]]));
  const prio = [['', 'Todas']].concat(Object.entries(PRIORIDAD_LABEL), [['sin', 'Sin prioridad']]);
  const resp = opcionesResponsable(filas);
  return `
    <div class="barra-acciones">
      <div class="section-title">Maestro de clientes<span class="line"></span></div>
    </div>
    <div class="filter-row filtros-clientes">
      <input type="search" id="mx-q" class="search-input" placeholder="Buscar por nombre…" value="${esc(f.q)}" aria-label="Buscar cliente">
      ${filtroSelect('mx-f-resell', 'Resell', resell, f.resell)}
      ${filtroSelect('mx-f-prio', 'Prioridad', prio, f.prioridad)}
      ${filtroSelect('mx-f-resp', 'Responsable', resp, f.responsable)}
      <button type="button" class="btn btn-ghost btn-sm" id="mx-limpiar">Limpiar</button>
    </div>
    <div class="m-leyenda"><span class="m-ley-edit">Blanco: se edita acá, se guarda solo</span>
      <span class="m-ley-calc">Gris: se calcula solo</span></div>`;
}

/* ---------- Tabla ---------- */

function tablaHtml(filas, cols, orden, total, hayFiltro) {
  if (!filas.length) {
    return `<div class="card empty-state">
        <div class="big">${total ? 'Ningún cliente coincide con los filtros' : 'Todavía no hay clientes en este programa'}</div>
        <div class="small">${total ? 'Probá con "Limpiar" para ver los ' + plural(total, 'cliente') + '.' : 'Se cargan desde Clientes.'}</div>
      </div>`;
  }
  const th = cols.map(c => {
    const on = orden.k === c.k;
    const flecha = on ? (orden.desc ? ' ↓' : ' ↑') : '';
    return `<th class="th-sort${on ? ' th-sort-on' : ''} ${c.edit ? 'm-th-edit' : ''} ${esc(c.cls)}" data-col="${esc(c.k)}"
      scope="col" title="Ordenar por ${esc(c.lab)}">${esc(c.lab)}${flecha}</th>`;
  }).join('');
  const tr = filas.map(fila => `<tr data-fila="${esc(fila.id)}">${cols.map(c =>
    `<td class="${c.edit ? 'm-td-edit ' : ''}${esc(c.cls)}" data-label="${esc(c.lab)}">${c.td(fila)}</td>`).join('')}</tr>`).join('');
  const abiertos = filas.filter(fl => renAbierta(fl.renovacion_estado)).length;
  return `
    <div class="card table-card tabla-clientes tabla-maestro" id="mx-scroll">
      <table class="data-table"><thead><tr>${th}</tr></thead><tbody>${tr}</tbody></table>
    </div>
    <div class="table-foot">${hayFiltro ? `${filas.length} de ${plural(total, 'cliente')}` : plural(total, 'cliente')}
      · ${plural(abiertos, 'en pipeline', 'en pipeline')}</div>`;
}

/* ---------- Vista ---------- */

export function vistaMaestro(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  const f = { ...FILTROS_VACIOS };
  const orden = { k: 'prioridad', desc: false };
  let prog = null, filas = [], cols = [];
  let timerBusqueda = null;

  const ctx = {
    get prog() { return prog; },
    porId: new Map(),
    refrescar: () => cargar().catch(e => console.error('maestro', e)),
    repintar: () => pintarTabla()
  };

  const hayFiltro = () => !!(f.resell || f.prioridad || f.responsable || f.q.trim());

  /* Repinta conservando: el campo con foco y su texto (realtime no pisa lo que se
     escribe), el scroll vertical de .main y el horizontal de la planilla. */
  function conservando(pintar) {
    const main = document.querySelector('.main');
    const y = main ? main.scrollTop : 0;
    const sc = el.querySelector('#mx-scroll');
    const x = sc ? sc.scrollLeft : 0;
    repintarConservandoFoco(el, pintar);
    if (main) main.scrollTop = y;
    const sc2 = el.querySelector('#mx-scroll');
    if (sc2) sc2.scrollLeft = x;
  }

  function pintarTabla() {
    const cont = el.querySelector('#mx-tabla');
    if (!cont) return;
    const visibles = ordenar(filas.filter(fl => pasa(fl, f)), cols, orden);
    conservando(() => { cont.innerHTML = tablaHtml(visibles, cols, orden, filas.length, hayFiltro()); });
  }

  function pintarTodo() {
    const lista = responsables(filas).map(v => `<option value="${esc(v)}"></option>`).join('');
    conservando(() => {
      el.innerHTML = barraFiltros(f, filas)
        + `<datalist id="mx-responsables">${lista}</datalist><div id="mx-tabla"></div>`;
    });
    pintarTabla();
  }

  /* ---------- Eventos (delegados: el HTML se repinta seguido) ---------- */

  const FILTRO_POR_ID = { 'mx-f-resell': 'resell', 'mx-f-prio': 'prioridad', 'mx-f-resp': 'responsable' };

  el.addEventListener('change', async ev => {
    const clave = FILTRO_POR_ID[ev.target.id];
    if (clave) { f[clave] = ev.target.value; pintarTabla(); return; }
    await manejarCambio(ev, ctx);
  });

  el.addEventListener('input', ev => {
    if (ev.target.id !== 'mx-q') return;
    f.q = ev.target.value;
    clearTimeout(timerBusqueda);
    timerBusqueda = setTimeout(pintarTabla, 150);
  });

  el.addEventListener('keydown', manejarTecla);

  el.addEventListener('click', async ev => {
    if (await manejarClick(ev, ctx)) return;
    if (ev.target.closest('#mx-limpiar')) {
      Object.assign(f, FILTROS_VACIOS);
      pintarTodo();
      return;
    }
    const th = ev.target.closest('th[data-col]');
    if (!th || !el.contains(th)) return;
    const k = th.dataset.col;
    if (orden.k === k) orden.desc = !orden.desc;
    else { orden.k = k; orden.desc = false; }
    pintarTabla();
  });

  async function cargar() {
    const [p, datos] = await Promise.all([traerPrograma(programaId), traerMaestro(programaId)]);
    if (!vigente()) return;
    if (!p) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    prog = p;
    filas = datos;
    ctx.porId = mapaPorId(filas);
    cols = columnas(prog);
    /* Si la barra ya está, alcanza con la tabla + las opciones de responsable. */
    if (el.querySelector('#mx-tabla')) {
      const dl = el.querySelector('#mx-responsables');
      if (dl) dl.innerHTML = responsables(filas).map(v => `<option value="${esc(v)}"></option>`).join('');
      const sel = el.querySelector('#mx-f-resp');
      if (sel && document.activeElement !== sel) sel.innerHTML = opcionesHtml(opcionesResponsable(filas), f.responsable);
      pintarTabla();
    } else {
      pintarTodo();
    }
  }

  cargar().catch(e => {
    if (!vigente()) return;
    const falta = /cs_v_maestro/.test(e && e.message || '')
      ? 'Falta correr la migración 037 (maestro del CSM).' : mensajeError(e);
    el.innerHTML = tarjetaError('No se pudo cargar el maestro', falta);
  });
  return { refrescar: ctx.refrescar };
}
