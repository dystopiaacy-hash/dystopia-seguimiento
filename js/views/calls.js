/* Calls del programa (#/p/:programa/calls).
   Filtros por tipo y estado. Las de onboarding sin agendar van primero y en rojo:
   son las que frenan el arranque de un cliente. */
import { esc, plural, toast } from '../ui.js';
import { queryActual } from '../router.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerClientes, traerCallsPrograma, actualizarFila,
  mensajeError, CALL_TIPO_LABEL, CALL_ESTADO_LABEL
} from '../datos.js';
import {
  filtroSelect, opcionesHtml, guardar, linkCliente, mapaPorId, textoTipoCall,
  paraInputFechaHora, desdeInputFechaHora
} from './comunes.js';

function filtrosIniciales() {
  const q = queryActual();
  return {
    tipo: q.get('tipo') || '',
    estado: q.get('estado') || '',
    q: q.get('q') || ''
  };
}

function urgente(c) {
  return c.tipo === 'onboarding' && c.estado === 'pendiente_agendar';
}

function aplicar(filas, f, mapaClientes) {
  const texto = f.q.trim().toLowerCase();
  return filas.filter(c => {
    if (f.tipo && c.tipo !== f.tipo) return false;
    if (f.estado && c.estado !== f.estado) return false;
    if (texto) {
      const cli = mapaClientes.get(c.cliente_id);
      if (!(cli && cli.nombre.toLowerCase().includes(texto))) return false;
    }
    return true;
  });
}

/* Onboarding sin agendar arriba; después por fecha (las sin fecha, primero). */
function ordenar(filas) {
  return filas.slice().sort((a, b) => {
    if (urgente(a) !== urgente(b)) return urgente(a) ? -1 : 1;
    if (!a.fecha && b.fecha) return -1;
    if (a.fecha && !b.fecha) return 1;
    return String(b.fecha || '').localeCompare(String(a.fecha || ''));
  });
}

function fila(c, programaId, mapaClientes) {
  return `
    <tr${urgente(c) ? ' class="fila-roja"' : ''}>
      <td data-label="Cliente">${linkCliente(programaId, mapaClientes.get(c.cliente_id))}</td>
      <td data-label="Tipo">${esc(textoTipoCall(c.tipo))}${urgente(c) ? ' <span class="txt-rojo">· sin agendar</span>' : ''}</td>
      <td data-label="Estado">
        <select data-call-estado="${esc(c.id)}" aria-label="Estado de la call">
          ${opcionesHtml(Object.entries(CALL_ESTADO_LABEL), c.estado)}
        </select>
      </td>
      <td data-label="Fecha">
        <input type="datetime-local" data-call-fecha="${esc(c.id)}" value="${esc(paraInputFechaHora(c.fecha))}"
          aria-label="Fecha y hora de la call">
      </td>
      <td data-label="Notas" class="col-notas">${c.notas ? esc(c.notas) : '<span class="txt-gris">—</span>'}</td>
    </tr>`;
}

function tabla(filas, programaId, mapaClientes, total) {
  if (!filas.length) {
    return `<div class="card empty-state">
        <div class="big">${total ? 'Ninguna call coincide con los filtros' : 'Todavía no hay calls en este programa'}</div>
        <div class="small">${total ? 'Probá con "Limpiar".' : 'La call de onboarding se crea sola al dar de alta un cliente.'}</div>
      </div>`;
  }
  return `
    <div class="card table-card tabla-clientes tabla-calls">
      <table class="data-table">
        <thead><tr>
          <th scope="col">Cliente</th><th scope="col">Tipo</th><th scope="col">Estado</th>
          <th scope="col">Fecha</th><th scope="col">Notas</th>
        </tr></thead>
        <tbody>${filas.map(c => fila(c, programaId, mapaClientes)).join('')}</tbody>
      </table>
    </div>
    <div class="table-foot">${filas.length} de ${plural(total, 'call')}</div>`;
}

export function vistaCalls(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  const f = filtrosIniciales();
  let calls = [], mapaClientes = new Map();
  let timerBusqueda = null;

  function pintarTabla() {
    const cont = el.querySelector('#calls-tabla');
    if (cont) cont.innerHTML = tabla(ordenar(aplicar(calls, f, mapaClientes)), programaId, mapaClientes, calls.length);
  }

  function pintarTodo() {
    const foco = document.activeElement && document.activeElement.id === 'c-q';
    const pos = foco ? document.getElementById('c-q').selectionStart : null;
    const sinAgendar = calls.filter(urgente).length;
    el.innerHTML = `
      <div class="barra-acciones">
        <div class="section-title">Calls
          <span class="aten-cuenta${sinAgendar ? ' txt-rojo' : ''}">${sinAgendar ? esc(plural(sinAgendar, 'onboarding sin agendar', 'onboardings sin agendar')) : 'Ningún onboarding sin agendar'}</span>
          <span class="line"></span>
        </div>
      </div>
      <div class="filter-row filtros-clientes">
        <input type="search" id="c-q" class="search-input" placeholder="Buscar por cliente…" value="${esc(f.q)}" aria-label="Buscar call">
        ${filtroSelect('c-tipo', 'Tipo', [['', 'Todos']].concat(Object.entries(CALL_TIPO_LABEL)), f.tipo)}
        ${filtroSelect('c-estado', 'Estado', [['', 'Todos']].concat(Object.entries(CALL_ESTADO_LABEL)), f.estado)}
        <button type="button" class="btn btn-ghost btn-sm" id="c-limpiar">Limpiar</button>
      </div>
      <div id="calls-tabla"></div>`;
    conectar();
    pintarTabla();
    if (foco) {
      const inp = document.getElementById('c-q');
      inp.focus();
      if (pos != null) inp.setSelectionRange(pos, pos);
    }
  }

  function conectar() {
    const on = (id, ev, fn) => { const e = document.getElementById(id); if (e) e.addEventListener(ev, fn); };
    on('c-tipo', 'change', e => { f.tipo = e.target.value; pintarTabla(); });
    on('c-estado', 'change', e => { f.estado = e.target.value; pintarTabla(); });
    on('c-q', 'input', e => {
      f.q = e.target.value;
      clearTimeout(timerBusqueda);
      timerBusqueda = setTimeout(pintarTabla, 150);
    });
    on('c-limpiar', 'click', () => { Object.assign(f, { tipo: '', estado: '', q: '' }); pintarTodo(); });
  }

  const recargar = () => cargar().catch(e => toast(mensajeError(e), 'error'));

  el.addEventListener('change', async ev => {
    const sel = ev.target.closest('[data-call-estado]');
    if (sel) {
      const id = sel.dataset.callEstado;
      const call = calls.find(c => c.id === id);
      const input = el.querySelector(`[data-call-fecha="${CSS.escape(id)}"]`);
      const fecha = desdeInputFechaHora(input ? input.value : '') || (call && call.fecha) || null;
      if (sel.value === 'agendada' && !fecha) {
        toast('Poné la fecha antes de marcarla agendada.', 'error');
        await recargar();
        return;
      }
      const cambios = sel.value === 'agendada' ? { estado: sel.value, fecha } : { estado: sel.value };
      await guardar(() => actualizarFila('cs_calls', id, cambios), { luego: recargar, control: sel });
      return;
    }

    const inp = ev.target.closest('[data-call-fecha]');
    if (inp) {
      const id = inp.dataset.callFecha;
      const call = calls.find(c => c.id === id);
      const fecha = desdeInputFechaHora(inp.value);
      if (!fecha && call && call.estado === 'agendada') {
        toast('Una call agendada necesita fecha. Cambiale el estado primero.', 'error');
        await recargar();
        return;
      }
      await guardar(() => actualizarFila('cs_calls', id, { fecha }), { luego: recargar, control: inp });
    }
  });

  async function cargar() {
    const [prog, cls, cs] = await Promise.all([
      traerPrograma(programaId), traerClientes(programaId), traerCallsPrograma(programaId)
    ]);
    if (!vigente()) return;
    if (!prog) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    mapaClientes = mapaPorId(cls);
    calls = cs;
    pintarTodo();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las calls', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('calls', e)) };
}
