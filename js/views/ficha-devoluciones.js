/* Ficha de cliente — devoluciones de portafolio.
   Cada una muestra hace cuánto espera (rojo si pasó el SLA del programa), el campo
   para pegar el link de Loom y el embed si el link valida como Loom.
   "Marcar entregada" exige link: es lo mismo que pide el CHECK de la base. */
import { esc, plural, fmtFechaHora, abrirModal, cerrarModal, confirmar, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import { actualizarFila, borrarFila, crearFila, horasAtraso, DEV_LABEL } from '../datos.js';
import { num, opcionesHtml, guardar, badgeDev, pillEspera, campoLoom, embedLoom } from './comunes.js';

function tarjeta(d, p) {
  return `
    <div class="dev-item">
      <div class="dev-top">
        <span class="dev-titulo">${esc(d.titulo)}</span>
        ${badgeDev(d.estado)}
        ${pillEspera(d, p.sla_devolucion_horas)}
      </div>
      <div class="dev-meta">
        Solicitada el ${esc(fmtFechaHora(d.solicitada_at))}${d.entregada_at ? ` · entregada el ${esc(fmtFechaHora(d.entregada_at))}` : ''}
      </div>
      <div class="dev-controles">
        <select data-dev-estado="${esc(d.id)}" aria-label="Estado de la devolución">
          ${opcionesHtml(Object.entries(DEV_LABEL), d.estado)}
        </select>
        ${campoLoom(d)}
        ${d.estado !== 'entregada'
          ? `<button type="button" class="btn btn-sm btn-accent" data-dev-entregar="${esc(d.id)}">Marcar entregada</button>`
          : ''}
        ${esFundador() ? `<button type="button" class="btn-icono btn-icono-danger" data-dev-borrar="${esc(d.id)}">Borrar</button>` : ''}
      </div>
      ${embedLoom(d.loom_url)}
      ${d.notas ? `<div class="dev-notas">${esc(d.notas)}</div>` : ''}
    </div>`;
}

export function html(ctx) {
  const devs = ctx.devoluciones || [];
  const pend = devs.filter(d => d.estado !== 'entregada').length;
  const fuera = devs.filter(d => num(horasAtraso(d, ctx.p.sla_devolucion_horas)) > 0).length;
  return `
    <div class="section-title">Devoluciones
      <span class="aten-cuenta${pend ? ' txt-rojo' : ''}">${esc(plural(pend, 'pendiente'))}${fuera ? ` · ${esc(plural(fuera, 'fuera de SLA', 'fuera de SLA'))}` : ''} · ${esc(plural(devs.length, 'en total', 'en total'))}</span>
      <span class="line"></span>
      <button type="button" class="btn btn-sm" data-accion="dev-nueva">Nueva devolución</button>
    </div>
    <div class="card card-list dev-lista">
      ${devs.length ? devs.map(d => tarjeta(d, ctx.p)).join('') : '<div class="muted-empty">No hay devoluciones cargadas para este cliente.</div>'}
    </div>`;
}

/* ---------- Acciones ---------- */

function modalNueva(ctx, api) {
  abrirModal({
    titulo: 'Nueva devolución',
    cuerpo: `
      <div class="form-row"><label for="dv-titulo">Título *</label>
        <input type="text" id="dv-titulo" maxlength="200" autocomplete="off"
          placeholder="Ej: Revisión de portafolio inicial"></div>
      <div class="hint">El SLA del programa es de ${esc(plural(num(ctx.p.sla_devolucion_horas), 'hora'))} desde ahora.</div>
      <div id="dv-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="dv-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="dv-ok">Crear</button>`
  });
  document.getElementById('dv-cancelar').onclick = cerrarModal;
  document.getElementById('dv-titulo').focus();
  document.getElementById('dv-ok').onclick = () => {
    const titulo = document.getElementById('dv-titulo').value.trim();
    if (!titulo) { document.getElementById('dv-error').textContent = 'El título es obligatorio.'; return; }
    cerrarModal();
    guardar(() => crearFila('cs_devoluciones', {
      programa_id: ctx.p.id, cliente_id: ctx.c.id, titulo
    }), { ok: 'Devolución creada.', luego: () => api.refrescar() });
  };
}

function linkDe(id) {
  const inp = document.querySelector(`[data-loom-input="${CSS.escape(id)}"]`);
  return inp ? inp.value.trim() : '';
}

export async function manejar(ev, ctx, api) {
  if (ev.type === 'change') {
    const sel = ev.target.closest('[data-dev-estado]');
    if (!sel) return false;
    const id = sel.dataset.devEstado;
    const estado = sel.value;
    const link = linkDe(id);
    if (estado === 'entregada' && !link) {
      toast('Pegá el link de Loom antes de marcarla entregada.', 'error');
      await api.refrescar();
      return true;
    }
    const cambios = estado === 'entregada' ? { estado, loom_url: link } : { estado };
    await guardar(() => actualizarFila('cs_devoluciones', id, cambios), { luego: () => api.refrescar(), control: sel });
    return true;
  }

  const nueva = ev.target.closest('[data-accion="dev-nueva"]');
  if (nueva) { modalNueva(ctx, api); return true; }

  const guardarLink = ev.target.closest('[data-loom-guardar]');
  if (guardarLink) {
    const id = guardarLink.dataset.loomGuardar;
    const link = linkDe(id);
    await guardar(() => actualizarFila('cs_devoluciones', id, { loom_url: link || null }), {
      ok: link ? 'Link guardado.' : 'Link borrado.', luego: () => api.refrescar(), control: guardarLink
    });
    return true;
  }

  const entregar = ev.target.closest('[data-dev-entregar]');
  if (entregar) {
    const id = entregar.dataset.devEntregar;
    const link = linkDe(id);
    if (!link) {
      toast('Pegá el link de Loom antes de marcarla entregada.', 'error');
      const inp = document.querySelector(`[data-loom-input="${CSS.escape(id)}"]`);
      if (inp) inp.focus();
      return true;
    }
    await guardar(() => actualizarFila('cs_devoluciones', id, { estado: 'entregada', loom_url: link }), {
      ok: 'Devolución entregada.', luego: () => api.refrescar(), control: entregar
    });
    return true;
  }

  const borrar = ev.target.closest('[data-dev-borrar]');
  if (borrar) {
    const d = (ctx.devoluciones || []).find(x => x.id === borrar.dataset.devBorrar);
    if (!d) return true;
    const ok = await confirmar({
      titulo: 'Borrar devolución',
      texto: `Se borra "${d.titulo}".`,
      detalle: 'No se puede deshacer.',
      ok: 'Borrar'
    });
    if (!ok) return true;
    await guardar(() => borrarFila('cs_devoluciones', d.id), {
      ok: 'Devolución borrada.', luego: () => api.refrescar(), control: borrar
    });
    return true;
  }
  return false;
}
