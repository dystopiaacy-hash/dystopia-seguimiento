/* Devoluciones del programa (#/p/:programa/devoluciones).
   Tablero de 3 columnas (pendiente, en proceso, entregada) con contador y porcentaje
   arriba de cada una; la de pendientes en rojo cuando hay alguna.
   El atraso contra el SLA se calcula con la misma función que usan el dashboard y la
   ficha (horasAtraso sobre solicitada_at + sla_devolucion_horas). */
import { esc, fmtFecha, fmtFechaHora, fmtPct, plural, toast } from '../ui.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerClientes, traerDevolucionesPrograma, actualizarFila,
  horasAtraso, mensajeError, DEV_LABEL
} from '../datos.js';
import {
  num, guardar, pillEspera, campoLoom, embedLoom, linkCliente, mapaPorId, repintarConservandoFoco
} from './comunes.js';

const COLUMNAS = [
  ['pendiente', 'Pendientes'],
  ['en_proceso', 'En proceso'],
  ['entregada', 'Entregadas']
];

function tarjeta(d, p, mapaClientes) {
  const fuera = num(horasAtraso(d, p.sla_devolucion_horas)) > 0;
  return `
    <article class="dev-card${fuera ? ' dev-card-roja' : ''}">
      <div class="dev-card-cli">${linkCliente(p.id, mapaClientes.get(d.cliente_id))}</div>
      <div class="dev-card-tit">${esc(d.titulo)}</div>
      <div class="dev-card-meta">
        ${pillEspera(d, p.sla_devolucion_horas)}
        <span class="txt-gris">${esc(d.estado === 'entregada' ? fmtFecha(d.entregada_at) : fmtFechaHora(d.solicitada_at))}</span>
      </div>
      <div class="dev-card-acciones">
        ${campoLoom(d)}
        ${d.estado !== 'entregada'
          ? `<button type="button" class="btn btn-sm btn-accent" data-dev-entregar="${esc(d.id)}">Marcar entregada</button>
             ${d.estado === 'pendiente'
               ? `<button type="button" class="btn btn-sm" data-dev-proceso="${esc(d.id)}">Pasar a en proceso</button>`
               : `<button type="button" class="btn btn-sm" data-dev-pendiente="${esc(d.id)}">Volver a pendiente</button>`}`
          : `<button type="button" class="btn btn-sm" data-dev-reabrir="${esc(d.id)}">Reabrir</button>`}
      </div>
      ${embedLoom(d.loom_url)}
    </article>`;
}

function columna(estado, label, filas, total, p, mapaClientes) {
  const pct = total ? fmtPct(100 * filas.length / total, 0) : '—';
  const rojo = estado === 'pendiente' && filas.length > 0;
  return `
    <section class="dev-col">
      <header class="dev-col-head${rojo ? ' txt-rojo' : ''}">
        <span class="dev-col-tit">${esc(label)}</span>
        <span class="dev-col-num">${filas.length}</span>
        <span class="dev-col-pct">${esc(pct)}</span>
      </header>
      ${filas.length
        ? filas.map(d => tarjeta(d, p, mapaClientes)).join('')
        : `<div class="muted-empty">${esc(estado === 'pendiente' ? 'No hay devoluciones pendientes.' : estado === 'en_proceso' ? 'Ninguna en proceso.' : 'Todavía no se entregó ninguna.')}</div>`}
    </section>`;
}

/* Las más urgentes arriba: primero las que ya pasaron el SLA, después por antigüedad. */
function ordenarAbiertas(filas, sla) {
  return filas.slice().sort((a, b) => num(horasAtraso(b, sla)) - num(horasAtraso(a, sla)));
}

function tablero(devs, p, mapaClientes, q) {
  const texto = q.trim().toLowerCase();
  const filtradas = !texto ? devs : devs.filter(d => {
    const cli = mapaClientes.get(d.cliente_id);
    return `${d.titulo || ''} ${cli ? cli.nombre : ''}`.toLowerCase().includes(texto);
  });
  const total = filtradas.length;
  return `
    <div class="dev-tablero">
      ${COLUMNAS.map(([estado, label]) => {
        const filas = filtradas.filter(d => d.estado === estado);
        const ordenadas = estado === 'entregada'
          ? filas.slice().sort((a, b) => String(b.entregada_at || '').localeCompare(String(a.entregada_at || '')))
          : ordenarAbiertas(filas, p.sla_devolucion_horas);
        return columna(estado, label, ordenadas, total, p, mapaClientes);
      }).join('')}
    </div>`;
}

export function vistaDevoluciones(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let p = null, devs = [], mapaClientes = new Map();
  let busqueda = '';
  let timerBusqueda = null;

  /* Un refresco no puede borrar un link que alguien está pegando: se conserva el campo
     con foco (los inputs de Loom tienen id propio). */
  function pintarTablero() {
    const cont = el.querySelector('#dev-tablero');
    if (cont) repintarConservandoFoco(el, () => { cont.innerHTML = tablero(devs, p, mapaClientes, busqueda); });
  }

  function pintarTodo() {
    const foco = document.activeElement && document.activeElement.id === 'd-q';
    const pos = foco ? document.getElementById('d-q').selectionStart : null;
    const pend = devs.filter(d => d.estado !== 'entregada').length;
    const fuera = devs.filter(d => num(horasAtraso(d, p.sla_devolucion_horas)) > 0).length;
    el.innerHTML = `
      <div class="barra-acciones">
        <div class="section-title">Devoluciones
          <span class="aten-cuenta${pend ? ' txt-rojo' : ''}">${esc(plural(pend, 'pendiente'))}${fuera ? ` · ${esc(plural(fuera, 'fuera de SLA', 'fuera de SLA'))}` : ''}</span>
          <span class="line"></span>
        </div>
      </div>
      <div class="filter-row">
        <input type="search" id="d-q" class="search-input" placeholder="Buscar por cliente o título…" value="${esc(busqueda)}" aria-label="Buscar devolución">
        <span class="hint">SLA del programa: ${esc(plural(num(p.sla_devolucion_horas), 'hora'))}</span>
      </div>
      <div id="dev-tablero"></div>`;
    const inp = document.getElementById('d-q');
    inp.addEventListener('input', e => {
      busqueda = e.target.value;
      clearTimeout(timerBusqueda);
      timerBusqueda = setTimeout(pintarTablero, 150);
    });
    pintarTablero();
    if (foco) {
      inp.focus();
      if (pos != null) inp.setSelectionRange(pos, pos);
    }
  }

  function linkDe(id) {
    const inp = el.querySelector(`[data-loom-input="${CSS.escape(id)}"]`);
    return inp ? inp.value.trim() : '';
  }

  const recargar = () => cargar().catch(e => toast(mensajeError(e), 'error'));

  el.addEventListener('click', async ev => {
    const guardarLink = ev.target.closest('[data-loom-guardar]');
    if (guardarLink) {
      const id = guardarLink.dataset.loomGuardar;
      const link = linkDe(id);
      await guardar(() => actualizarFila('cs_devoluciones', id, { loom_url: link || null }), {
        ok: link ? 'Link guardado.' : 'Link borrado.', luego: recargar, control: guardarLink
      });
      return;
    }

    const entregar = ev.target.closest('[data-dev-entregar]');
    if (entregar) {
      const id = entregar.dataset.devEntregar;
      const link = linkDe(id);
      if (!link) {
        toast('Pegá el link de Loom antes de marcarla entregada.', 'error');
        const inp = el.querySelector(`[data-loom-input="${CSS.escape(id)}"]`);
        if (inp) inp.focus();
        return;
      }
      await guardar(() => actualizarFila('cs_devoluciones', id, { estado: 'entregada', loom_url: link }), {
        ok: 'Devolución entregada.', luego: recargar, control: entregar
      });
      return;
    }

    const mover = ev.target.closest('[data-dev-proceso], [data-dev-pendiente], [data-dev-reabrir]');
    if (mover) {
      const id = mover.dataset.devProceso || mover.dataset.devPendiente || mover.dataset.devReabrir;
      const estado = mover.dataset.devProceso ? 'en_proceso' : mover.dataset.devPendiente ? 'pendiente' : 'en_proceso';
      await guardar(() => actualizarFila('cs_devoluciones', id, { estado }), {
        ok: `Pasó a ${DEV_LABEL[estado].toLowerCase()}.`, luego: recargar, control: mover
      });
    }
  });

  async function cargar() {
    const [prog, cls, ds] = await Promise.all([
      traerPrograma(programaId), traerClientes(programaId), traerDevolucionesPrograma(programaId)
    ]);
    if (!vigente()) return;
    if (!prog) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    p = prog;
    mapaClientes = mapaPorId(cls);
    devs = ds;
    pintarTodo();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las devoluciones', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('devoluciones', e)) };
}
