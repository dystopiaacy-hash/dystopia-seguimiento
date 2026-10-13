/* "Referidos para pedir" y alta rápida de wins en la pestaña Hoy (106).
   Cada win cargado deja un pendiente "Pedir referido a <alumno>" que queda acá hasta marcarlo
   como pedido o descartarlo. "Registrar win" abre el alta rápida con buscador de alumno
   (acentos y mayúsculas no importan). Sin la 106 (o si falla) no muestra nada. */
import { esc, fmtFecha, toast } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { traerClientes } from '../datos.js';
import { traerReferidosPendientes, resolverReferido, WIN_TIPO_LABEL } from '../datos-wins.js';
import { mensajeCs } from '../datos-faltante.js';
import { abrirModalWin } from './win-modal.js';

function fila(w, nombre, programaId, editar, ocupada) {
  const dis = ocupada ? ' disabled' : '';
  const href = `#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(w.cliente_id)}`;
  return `<article class="hoy-alta">
    <div class="hoy-card-main">
      <div class="hoy-card-top">
        <span class="hoy-alta-nombre">Pedir referido a ${esc(nombre)}</span>
        <span class="hoy-tipo">${esc(WIN_TIPO_LABEL[w.tipo] || w.tipo)} · ${esc(fmtFecha(w.fecha))}</span>
      </div>
      <div class="hoy-detalle">${esc(w.texto)}</div>
    </div>
    <div class="hoy-card-acc">
      ${editar ? `<button type="button" class="btn btn-sm btn-accent" data-ref="pedido" data-id="${esc(w.id)}"${dis}>Pedí el referido</button>
        <button type="button" class="btn btn-sm" data-ref="descartado" data-id="${esc(w.id)}"${dis}>Descartar</button>` : ''}
      <a class="btn btn-sm" href="${href}?sec=wins">Abrir ficha</a>
    </div>
  </article>`;
}

export function montarWinsHoy(box, programaId, vigente, alCambiar) {
  let wins = [], nombres = new Map(), clientes = [], hay = false, pedido = 0;
  const ocupadas = new Set();
  const editar = () => puedeEditarPrograma(programaId);

  function pintar() {
    if (!hay || (!wins.length && !editar())) { box.innerHTML = ''; return; }
    box.innerHTML = `<section class="hoy-grupo">
      <div class="section-title">Referidos para pedir <span class="hoy-grupo-n">${wins.length}</span><span class="line"></span>
        ${editar() ? '<button type="button" class="btn btn-sm" data-win-nuevo>Registrar win</button>' : ''}</div>
      ${wins.length ? wins.map(w => fila(w, nombres.get(w.cliente_id) || 'el alumno', programaId, editar(), ocupadas.has(w.id))).join('')
        : '<div class="muted-empty">No hay referidos pendientes de pedir.</div>'}
    </section>`;
  }

  async function cargar() {
    const n = ++pedido;
    let w = null, cli = [];
    try {
      w = await traerReferidosPendientes(programaId);
      if (w) cli = await traerClientes(programaId);
    } catch (e) {
      console.error('wins hoy', e);
    }
    if (!vigente() || n !== pedido) return;
    hay = !!w;
    wins = w || [];
    clientes = cli;
    nombres = new Map(cli.map(c => [c.id, c.nombre]));
    pintar();
    alCambiar();
  }

  box.addEventListener('click', async ev => {
    if (ev.target.closest('[data-win-nuevo]')) {
      if (editar()) abrirModalWin({ programaId, clientes, alGuardar: cargar });
      return;
    }
    const b = ev.target.closest('[data-ref]');
    if (!b || !editar()) return;
    ocupadas.add(b.dataset.id);
    pintar();
    try {
      await resolverReferido(b.dataset.id, b.dataset.ref);
      toast(b.dataset.ref === 'pedido' ? 'Referido marcado como pedido.' : 'Descartado.');
    } catch (e) {
      toast(mensajeCs(e), 'error');
    } finally {
      ocupadas.delete(b.dataset.id);
    }
    await cargar();
  });

  cargar();
  return { cantidad: () => wins.length, cargar };
}
