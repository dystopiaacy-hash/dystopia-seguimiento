/* Accionables de todo el programa (#/p/:programa/accionables).
   Filtros por responsable, estado, vencidos y cliente, más búsqueda por título.
   El checkbox completa el accionable al momento. */
import { esc, plural, diasRestantes, toast } from '../ui.js';
import { queryActual } from '../router.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerClientes, traerAccionablesPrograma, actualizarFila,
  mensajeError, ACC_LABEL, RESPONSABLE_LABEL
} from '../datos.js';
import {
  num, filtroSelect, guardar, badgeAcc, celdaVence, linkCliente, mapaPorId
} from './comunes.js';

const ABIERTOS = ['pendiente', 'en_proceso'];

function filtrosIniciales() {
  const q = queryActual();
  return {
    responsable: q.get('responsable') || '',
    estado: q.get('estado') || 'abiertos',
    cliente: q.get('cliente') || '',
    vencidos: q.get('vencidos') === '1',
    q: q.get('q') || ''
  };
}

function vencido(a) {
  return a.estado !== 'completado' && !!a.vence && num(diasRestantes(a.vence)) < 0;
}

function aplicar(filas, f) {
  const texto = f.q.trim().toLowerCase();
  return filas.filter(a => {
    if (f.responsable && a.responsable !== f.responsable) return false;
    if (f.estado === 'abiertos') { if (!ABIERTOS.includes(a.estado)) return false; }
    else if (f.estado && a.estado !== f.estado) return false;
    if (f.cliente && a.cliente_id !== f.cliente) return false;
    if (f.vencidos && !vencido(a)) return false;
    if (texto && !(a.titulo || '').toLowerCase().includes(texto)) return false;
    return true;
  });
}

function ordenar(filas) {
  const peso = a => (a.estado === 'completado' ? 1 : 0);
  return filas.slice().sort((a, b) =>
    (peso(a) - peso(b)) ||
    String(a.vence || '9999-12-31').localeCompare(String(b.vence || '9999-12-31')) ||
    String(a.created_at || '').localeCompare(String(b.created_at || '')));
}

function barraFiltros(f, clientes) {
  const opcionesCliente = [['', 'Todos']].concat(
    clientes.slice().sort((a, b) => a.nombre.localeCompare(b.nombre, 'es')).map(c => [c.id, c.nombre]));
  return `
    <div class="filter-row filtros-clientes">
      <input type="search" id="a-q" class="search-input" placeholder="Buscar por título…" value="${esc(f.q)}" aria-label="Buscar accionable">
      ${filtroSelect('a-resp', 'Responsable', [['', 'Todos']].concat(Object.entries(RESPONSABLE_LABEL)), f.responsable)}
      ${filtroSelect('a-estado', 'Estado', [['abiertos', 'Pendientes y en proceso'], ['', 'Todos']]
        .concat(Object.entries(ACC_LABEL)), f.estado)}
      ${filtroSelect('a-cliente', 'Cliente', opcionesCliente, f.cliente)}
      <label class="check-row check-inline"><input type="checkbox" id="a-vencidos"${f.vencidos ? ' checked' : ''}> Solo vencidos</label>
      <button type="button" class="btn btn-ghost btn-sm" id="a-limpiar">Limpiar</button>
    </div>`;
}

function tabla(filas, mapaClientes, programaId, total) {
  if (!filas.length) {
    return `<div class="card empty-state">
        <div class="big">${total ? 'Ningún accionable coincide con los filtros' : 'Todavía no hay accionables en este programa'}</div>
        <div class="small">${total ? 'Probá con "Limpiar".' : 'Se crean desde la ficha de cada cliente o con la plantilla del programa.'}</div>
      </div>`;
  }
  const tr = filas.map(a => `
    <tr${vencido(a) ? ' class="fila-roja"' : ''}>
      <td class="col-check" data-label="Hecho">
        <input type="checkbox" data-acc-check="${esc(a.id)}"${a.estado === 'completado' ? ' checked' : ''}
          aria-label="Completar ${esc(a.titulo)}"></td>
      <td data-label="Accionable" class="col-titulo">${esc(a.titulo)}</td>
      <td data-label="Cliente">${linkCliente(programaId, mapaClientes.get(a.cliente_id))}</td>
      <td data-label="Responsable">${esc(RESPONSABLE_LABEL[a.responsable] || a.responsable)}</td>
      <td data-label="Estado">${badgeAcc(a.estado)}</td>
      <td data-label="Vence">${celdaVence(a)}</td>
    </tr>`).join('');
  return `
    <div class="card table-card tabla-clientes tabla-acc">
      <table class="data-table">
        <thead><tr>
          <th scope="col" class="col-check">Hecho</th><th scope="col">Accionable</th><th scope="col">Cliente</th>
          <th scope="col">Responsable</th><th scope="col">Estado</th><th scope="col">Vence</th>
        </tr></thead>
        <tbody>${tr}</tbody>
      </table>
    </div>
    <div class="table-foot">${filas.length} de ${plural(total, 'accionable')}</div>`;
}

export function vistaAccionables(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  const f = filtrosIniciales();
  let clientes = [], accionables = [], mapaClientes = new Map();
  let timerBusqueda = null;

  function pintarTabla() {
    const cont = el.querySelector('#acc-tabla');
    if (!cont) return;
    cont.innerHTML = tabla(ordenar(aplicar(accionables, f)), mapaClientes, programaId, accionables.length);
  }

  function pintarTodo() {
    const foco = document.activeElement && document.activeElement.id === 'a-q';
    const pos = foco ? document.getElementById('a-q').selectionStart : null;
    el.innerHTML = `
      <div class="barra-acciones"><div class="section-title">Accionables del programa<span class="line"></span></div></div>
      ${barraFiltros(f, clientes)}
      <div id="acc-tabla"></div>`;
    conectar();
    pintarTabla();
    if (foco) {
      const inp = document.getElementById('a-q');
      inp.focus();
      if (pos != null) inp.setSelectionRange(pos, pos);
    }
  }

  function conectar() {
    const on = (id, ev, fn) => { const e = document.getElementById(id); if (e) e.addEventListener(ev, fn); };
    on('a-resp', 'change', e => { f.responsable = e.target.value; pintarTabla(); });
    on('a-estado', 'change', e => { f.estado = e.target.value; pintarTabla(); });
    on('a-cliente', 'change', e => { f.cliente = e.target.value; pintarTabla(); });
    on('a-vencidos', 'change', e => { f.vencidos = e.target.checked; pintarTabla(); });
    on('a-q', 'input', e => {
      f.q = e.target.value;
      clearTimeout(timerBusqueda);
      timerBusqueda = setTimeout(pintarTabla, 150);
    });
    on('a-limpiar', 'click', () => {
      Object.assign(f, { responsable: '', estado: 'abiertos', cliente: '', vencidos: false, q: '' });
      pintarTodo();
    });
  }

  el.addEventListener('change', async ev => {
    const chk = ev.target.closest('[data-acc-check]');
    if (!chk) return;
    const estado = chk.checked ? 'completado' : 'pendiente';
    await guardar(() => actualizarFila('cs_accionables', chk.dataset.accCheck, { estado }), {
      ok: chk.checked ? 'Accionable completado.' : 'Accionable reabierto.',
      luego: () => cargar().catch(e => toast(mensajeError(e), 'error')),
      control: chk
    });
  });

  async function cargar() {
    const [prog, cls, acc] = await Promise.all([
      traerPrograma(programaId), traerClientes(programaId), traerAccionablesPrograma(programaId)
    ]);
    if (!vigente()) return;
    if (!prog) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    clientes = cls;
    mapaClientes = mapaPorId(cls);
    accionables = acc;
    pintarTodo();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar los accionables', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('accionables', e)) };
}
