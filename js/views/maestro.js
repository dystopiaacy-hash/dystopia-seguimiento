/* Maestro de clientes del CSM (#/p/:programa/maestro).
   Una planilla con todos los clientes del programa, sobre cs_v_maestro (037).
   cs_clientes sigue siendo la única fuente de verdad: las celdas editables escriben
   ahí (y en cs_renovaciones para el resell); las calculadas vienen de la vista.
   Sin botón de guardar: cada celda se guarda sola (maestro-celdas.js).
   Tiempo real: app.js llama a refrescar() cuando cambia cs_clientes o
   cs_renovaciones del programa; se repinta conservando el campo con foco y lo
   que tiene escrito (mismo patrón que la ficha). En celular, tarjetas.
   Columnas configurables (071): la lista sale de maestro-columnas.js (definiciones
   + config del programa). El fundador las cambia desde el botón "Columnas"
   (maestro-panel.js) o con doble clic en un encabezado. Sin la 071, la planilla
   de siempre y sin botón. */
import { esc, plural, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import { tarjetaError } from './programa.js';
import { filtroSelect, opcionesHtml, repintarConservandoFoco, mapaPorId } from './comunes.js';
import {
  traerPrograma, traerMaestro, mensajeError, renAbierta,
  REN_ABIERTOS, REN_LABEL, PRIORIDAD_LABEL, ESTADO_LABEL
} from '../datos.js';
import { traerProductos } from '../ciclo.js';
import { traerColumnasMaestro, guardarColumna, errorColumnas } from '../datos-columnas.js';
import { columnas, manejarCambio, manejarTecla } from './maestro-celdas.js';
import { manejarClick, limpiarConfirmaciones } from './maestro-ciclo.js';
import { armarColumnas } from './maestro-columnas.js';
import { manejarIr } from './maestro-acciones.js';
import { abrirPanelColumnas } from './maestro-panel.js';

/* ---------- Filtros ---------- */

const FILTROS_VACIOS = { resell: '', prioridad: '', responsable: '', estado: '', q: '' };
const ESTADOS_FILTRO = ['onboarding', 'activo', 'en_renovacion', 'pausado', 'finalizado', 'baja'];

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
  if (f.estado && fila.estado !== f.estado) return false;
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

const opcionesLista = valores => valores.map(v => `<option value="${esc(v)}"></option>`).join('');
const etapasDe = prog => (Array.isArray(prog && prog.etapas) ? prog.etapas : []).filter(Boolean).map(String);

function barraFiltros(f, filas, conColumnas) {
  const resell = [['', 'Todos'], ['abierta', 'En pipeline (abiertos)'], ['sin', 'Sin pipeline']]
    .concat(REN_ABIERTOS.concat(['renovado', 'no_renovado']).map(e => [e, REN_LABEL[e]]));
  const prio = [['', 'Todas']].concat(Object.entries(PRIORIDAD_LABEL), [['sin', 'Sin prioridad']]);
  const resp = opcionesResponsable(filas);
  return `
    <div class="barra-acciones">
      <div class="section-title">Maestro de clientes<span class="line"></span></div>
      ${conColumnas ? '<button type="button" class="btn btn-sm" id="mx-columnas">Columnas</button>' : ''}
    </div>
    <div class="filter-row filtros-clientes">
      <input type="search" id="mx-q" class="search-input" placeholder="Buscar por nombre…" value="${esc(f.q)}" aria-label="Buscar cliente">
      ${filtroSelect('mx-f-resell', 'Resell', resell, f.resell)}
      ${filtroSelect('mx-f-prio', 'Prioridad', prio, f.prioridad)}
      ${filtroSelect('mx-f-resp', 'Responsable', resp, f.responsable)}
      ${filtroSelect('mx-f-estado', 'Estado', [['', 'Todos']].concat(ESTADOS_FILTRO.map(e => [e, ESTADO_LABEL[e] || e])), f.estado)}
      <button type="button" class="btn btn-ghost btn-sm" id="mx-limpiar">Limpiar</button>
    </div>
    <div class="m-leyenda"><span class="m-ley-edit">Blanco: se edita acá, se guarda solo</span>
      <span class="m-ley-calc">Gris: se calcula solo, el clic abre lo que lo cambia</span></div>`;
}

/* ---------- Tabla ---------- */

/* opt.config: el fundador puede renombrar con doble clic. opt.ren: clave que se está renombrando. */
function thHtml(c, orden, opt) {
  const cls = `${c.edit ? 'm-th-edit' : ''} ${esc(c.cls)}`;
  if (opt.ren === c.k) {
    return `<th class="m-th-ren ${cls}" scope="col"><input type="text" id="mx-th-ren" class="m-edit" maxlength="60"
      value="${esc(c.lab)}" placeholder="${esc(c.sistema ? c.original : 'Nombre')}" data-col-ren="${esc(c.k)}"
      aria-label="${esc('Nombre de la columna ' + c.lab)}"></th>`;
  }
  const on = orden.k === c.k;
  const flecha = on ? (orden.desc ? ' ↓' : ' ↑') : '';
  return `<th class="th-sort${on ? ' th-sort-on' : ''} ${cls}" data-col="${esc(c.k)}" scope="col"
    title="${esc('Ordenar por ' + c.lab + (opt.config ? ' · doble clic para renombrar' : ''))}">${esc(c.lab)}${flecha}</th>`;
}

function tablaHtml(filas, cols, orden, total, hayFiltro, opt) {
  if (!filas.length) {
    return `<div class="card empty-state">
        <div class="big">${total ? 'Ningún cliente coincide con los filtros' : 'Todavía no hay clientes en este programa'}</div>
        <div class="small">${total ? 'Probá con "Limpiar" para ver los ' + plural(total, 'cliente') + '.' : 'Se cargan desde Clientes.'}</div>
      </div>`;
  }
  const th = cols.map(c => thHtml(c, orden, opt)).join('');
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
  /* Columnas (071). config null = sin 071. armado = { visibles, todas, archivadas }. */
  let productos = [], config = null, armado = { visibles: [], todas: [], archivadas: [] };
  let panel = null, renombrando = '', timerOrden = null;
  limpiarConfirmaciones();

  const puedeConfigurar = () => config !== null && esFundador();

  function armar() {
    armado = armarColumnas(columnas(prog, productos), config);
    cols = armado.visibles;
  }

  const ctx = {
    get prog() { return prog; },
    porId: new Map(),
    refrescar: () => cargar().catch(e => console.error('maestro', e)),
    repintar: () => pintarTabla()
  };

  const hayFiltro = () => !!(f.resell || f.prioridad || f.responsable || f.estado || f.q.trim());

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
    conservando(() => {
      cont.innerHTML = tablaHtml(visibles, cols, orden, filas.length, hayFiltro(),
        { config: puedeConfigurar(), ren: renombrando });
    });
  }

  function pintarTodo() {
    conservando(() => {
      el.innerHTML = barraFiltros(f, filas, puedeConfigurar())
        + `<datalist id="mx-responsables">${opcionesLista(responsables(filas))}</datalist>
           <datalist id="mx-etapas">${opcionesLista(etapasDe(prog))}</datalist><div id="mx-tabla"></div>`;
    });
    pintarTabla();
  }

  /* ---------- Columnas (071) ---------- */

  /* Después de cada cambio de estructura: config nueva y repintado (conserva el scroll). */
  async function recargarColumnas() {
    const nueva = await traerColumnasMaestro(programaId);
    if (!vigente() || nueva === null) return;
    config = nueva;
    armar();
    pintarTabla();
  }

  /* Doble clic en un encabezado: el nombre se edita ahí mismo. */
  async function renombrar(k, texto) {
    const c = armado.todas.find(x => x.k === k);
    const v = texto.trim();
    renombrando = '';
    const etiqueta = c && c.sistema && (!v || v === c.original) ? null : v;
    if (!c || (!v && !c.sistema) || (etiqueta || c.original) === c.lab) { pintarTabla(); return; }
    try {
      await guardarColumna(programaId, k, { etiqueta, visible: c.visible });
      toast('Columna renombrada.');
    } catch (e) {
      toast(errorColumnas(e), 'error');
    }
    await recargarColumnas();
    if (panel) panel.pintar();
  }

  /* ---------- Eventos (delegados: el HTML se repinta seguido) ---------- */

  const FILTRO_POR_ID = { 'mx-f-resell': 'resell', 'mx-f-prio': 'prioridad', 'mx-f-resp': 'responsable', 'mx-f-estado': 'estado' };

  el.addEventListener('change', async ev => {
    if (ev.target.id === 'mx-th-ren') { await renombrar(ev.target.dataset.colRen, ev.target.value); return; }
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

  el.addEventListener('keydown', ev => {
    if (ev.target.id !== 'mx-th-ren') return manejarTecla(ev);
    if (ev.key === 'Enter') { ev.preventDefault(); ev.target.blur(); }
    if (ev.key === 'Escape') { renombrando = ''; pintarTabla(); }
  });

  /* Salió del encabezado sin cambiar nada: vuelve a ser un título. El timeout deja
     pasar un repintado de realtime, que devuelve el foco al mismo campo. */
  el.addEventListener('focusout', ev => {
    if (ev.target.id !== 'mx-th-ren') return;
    setTimeout(() => {
      if (!renombrando || (document.activeElement && document.activeElement.id === 'mx-th-ren')) return;
      renombrando = '';
      pintarTabla();
    }, 0);
  });

  el.addEventListener('dblclick', ev => {
    const th = ev.target.closest('th[data-col]');
    if (!th || !puedeConfigurar()) return;
    clearTimeout(timerOrden);
    renombrando = th.dataset.col;
    pintarTabla();
    const inp = el.querySelector('#mx-th-ren');
    if (inp) { inp.focus(); inp.select(); }
  });

  el.addEventListener('click', async ev => {
    if (await manejarClick(ev, ctx)) return;
    if (manejarIr(ev, ctx)) return;
    if (ev.target.closest('#mx-limpiar')) {
      Object.assign(f, FILTROS_VACIOS);
      pintarTodo();
      return;
    }
    if (ev.target.closest('#mx-columnas')) {
      if (!puedeConfigurar()) return;
      panel = abrirPanelColumnas({
        programaId, estado: () => armado, recargar: recargarColumnas, alCerrar: () => { panel = null; }
      });
      return;
    }
    const th = ev.target.closest('th[data-col]');
    if (!th || !el.contains(th)) return;
    const k = th.dataset.col;
    const aplicar = () => {
      if (orden.k === k) orden.desc = !orden.desc;
      else { orden.k = k; orden.desc = false; }
      pintarTabla();
    };
    /* Con doble clic para renombrar, el orden espera un instante: el segundo clic lo cancela. */
    clearTimeout(timerOrden);
    if (puedeConfigurar()) timerOrden = setTimeout(aplicar, 230);
    else aplicar();
  });

  async function cargar() {
    /* Productos y config no frenan la planilla: sin ellos se ve como siempre. */
    const [p, datos, prods, conf] = await Promise.all([
      traerPrograma(programaId), traerMaestro(programaId),
      traerProductos(programaId).catch(e => { console.error('productos', e); return productos; }),
      traerColumnasMaestro(programaId).catch(e => { console.error('columnas', e); return config; })
    ]);
    if (!vigente()) return;
    if (!p) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    prog = p;
    filas = datos;
    productos = prods;
    config = conf;
    ctx.porId = mapaPorId(filas);
    armar();
    if (panel) panel.pintar();
    /* Si la barra ya está, alcanza con la tabla + las opciones de responsable. */
    if (el.querySelector('#mx-tabla')) {
      const dl = el.querySelector('#mx-responsables');
      if (dl) dl.innerHTML = opcionesLista(responsables(filas));
      const de = el.querySelector('#mx-etapas');
      if (de) de.innerHTML = opcionesLista(etapasDe(prog));
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
