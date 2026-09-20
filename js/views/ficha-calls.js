/* Ficha de cliente — calls y renovaciones.
   Las calls cambian de estado y de fecha en la misma fila (una call agendada necesita
   fecha: lo pide el CHECK de la base y se avisa antes de intentarlo).
   De renovaciones se muestran las cerradas y la que está en curso. El modal de
   cierre es el mismo de la vista Renovaciones (se importa, no se duplica). */
import { esc, fmtFecha, fmtFechaHora, plural, abrirModal, cerrarModal, confirmar, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import {
  actualizarFila, borrarFila, crearFila, iniciarRenovacion,
  CALL_TIPO_LABEL, CALL_ESTADO_LABEL, REN_LABEL
} from '../datos.js';
import {
  opcionesHtml, guardar, badgeCall, badgeRen, textoTipoCall,
  paraInputFechaHora, desdeInputFechaHora
} from './comunes.js';
import { modalCerrarRenovacion } from './renovaciones.js';

/* ---------- Calls ---------- */

function filaCall(c) {
  const pendiente = c.tipo === 'onboarding' && c.estado === 'pendiente_agendar';
  return `
    <div class="call-item${pendiente ? ' call-urgente' : ''}">
      <span class="call-tipo">${esc(textoTipoCall(c.tipo))}</span>
      <span class="call-badge">${badgeCall(c.estado)}</span>
      <select data-call-estado="${esc(c.id)}" aria-label="Estado de la call">
        ${opcionesHtml(Object.entries(CALL_ESTADO_LABEL), c.estado)}
      </select>
      <input type="datetime-local" data-call-fecha="${esc(c.id)}" value="${esc(paraInputFechaHora(c.fecha))}"
        aria-label="Fecha y hora de la call">
      ${esFundador() ? `<button type="button" class="btn-icono btn-icono-danger" data-call-borrar="${esc(c.id)}">Borrar</button>` : ''}
      ${c.notas ? `<div class="call-notas">${esc(c.notas)}</div>` : ''}
    </div>`;
}

function bloqueCalls(ctx) {
  const calls = ctx.calls || [];
  const sinAgendar = calls.filter(c => c.estado === 'pendiente_agendar').length;
  return `
    <div class="section-title">Calls
      <span class="aten-cuenta${sinAgendar ? ' txt-rojo' : ''}">${esc(plural(calls.length, 'call'))}${sinAgendar ? ` · ${esc(plural(sinAgendar, 'sin agendar', 'sin agendar'))}` : ''}</span>
      <span class="line"></span>
      <button type="button" class="btn btn-sm" data-accion="call-nueva">Nueva call</button>
    </div>
    <div class="card card-list call-lista">
      ${calls.length ? calls.map(filaCall).join('') : '<div class="muted-empty">Este cliente no tiene calls cargadas.</div>'}
    </div>`;
}

/* ---------- Renovaciones ---------- */

function filaRenovacion(r) {
  const detalle = [
    `Iniciada el ${fmtFechaHora(r.iniciada_at)}`,
    r.resultado_at ? `cerrada el ${fmtFechaHora(r.resultado_at)}` : '',
    r.nueva_fecha_fin ? `nueva fecha de fin ${fmtFecha(r.nueva_fecha_fin)}` : ''
  ].filter(Boolean).join(' · ');
  return `
    <div class="ren-item${r.estado === 'en_proceso' ? ' ren-curso' : ''}">
      <span class="ren-badge">${badgeRen(r.estado)}</span>
      <span class="ren-detalle">${esc(detalle)}</span>
      ${r.motivo ? `<span class="ren-motivo">${esc(r.motivo)}</span>` : ''}
      ${r.estado === 'en_proceso'
        ? `<button type="button" class="btn btn-sm btn-accent" data-ren-cerrar="${esc(r.id)}">Cerrar renovación</button>`
        : ''}
      ${esFundador() ? `<button type="button" class="btn-icono btn-icono-danger" data-ren-borrar="${esc(r.id)}">Borrar</button>` : ''}
    </div>`;
}

function bloqueRenovaciones(ctx) {
  const rens = ctx.renovaciones || [];
  const enCurso = rens.some(r => r.estado === 'en_proceso');
  const cerrable = !enCurso && !['finalizado', 'baja'].includes(ctx.c.estado);
  return `
    <div class="section-title">Renovaciones
      <span class="aten-cuenta">${esc(plural(rens.length, 'renovación', 'renovaciones'))}</span>
      <span class="line"></span>
      ${cerrable ? '<button type="button" class="btn btn-sm" data-accion="iniciar-renovacion-ren">Iniciar proceso de renovación</button>' : ''}
    </div>
    <div class="card card-list ren-lista">
      ${rens.length ? rens.map(filaRenovacion).join('') : '<div class="muted-empty">Este cliente todavía no tuvo renovaciones.</div>'}
    </div>`;
}

export function html(ctx) {
  return bloqueCalls(ctx) + bloqueRenovaciones(ctx);
}

/* ---------- Acciones ---------- */

function modalNuevaCall(ctx, api) {
  abrirModal({
    titulo: 'Nueva call',
    cuerpo: `
      <div class="form-grid2">
        <div class="form-row"><label for="cl-tipo">Tipo</label>
          <select id="cl-tipo">${opcionesHtml(Object.entries(CALL_TIPO_LABEL), 'seguimiento')}</select></div>
        <div class="form-row"><label for="cl-fecha">Fecha y hora (opcional)</label>
          <input type="datetime-local" id="cl-fecha"></div>
      </div>
      <div class="form-row"><label for="cl-notas">Notas</label>
        <textarea id="cl-notas" maxlength="1000"></textarea></div>
      <div class="hint">Sin fecha queda como "Sin agendar".</div>`,
    pie: `<button type="button" class="btn" id="cl-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="cl-ok">Crear</button>`
  });
  document.getElementById('cl-cancelar').onclick = cerrarModal;
  document.getElementById('cl-ok').onclick = () => {
    const fecha = desdeInputFechaHora(document.getElementById('cl-fecha').value);
    const fila = {
      programa_id: ctx.p.id,
      cliente_id: ctx.c.id,
      tipo: document.getElementById('cl-tipo').value,
      estado: fecha ? 'agendada' : 'pendiente_agendar',
      fecha,
      notas: document.getElementById('cl-notas').value.trim() || null
    };
    cerrarModal();
    guardar(() => crearFila('cs_calls', fila), { ok: 'Call creada.', luego: () => api.refrescar() });
  };
}

export async function manejar(ev, ctx, api) {
  if (ev.type === 'change') {
    const sel = ev.target.closest('[data-call-estado]');
    if (sel) {
      const id = sel.dataset.callEstado;
      const call = (ctx.calls || []).find(c => c.id === id);
      const input = document.querySelector(`[data-call-fecha="${CSS.escape(id)}"]`);
      const fecha = desdeInputFechaHora(input ? input.value : '') || (call && call.fecha) || null;
      if (sel.value === 'agendada' && !fecha) {
        toast('Poné la fecha antes de marcarla agendada.', 'error');
        await api.refrescar();
        if (input) input.focus();
        return true;
      }
      const cambios = sel.value === 'agendada' ? { estado: sel.value, fecha } : { estado: sel.value };
      await guardar(() => actualizarFila('cs_calls', id, cambios), { luego: () => api.refrescar(), control: sel });
      return true;
    }

    const inp = ev.target.closest('[data-call-fecha]');
    if (inp) {
      const id = inp.dataset.callFecha;
      const call = (ctx.calls || []).find(c => c.id === id);
      const fecha = desdeInputFechaHora(inp.value);
      if (!fecha && call && call.estado === 'agendada') {
        toast('Una call agendada necesita fecha. Cambiale el estado primero.', 'error');
        await api.refrescar();
        return true;
      }
      await guardar(() => actualizarFila('cs_calls', id, { fecha }), { luego: () => api.refrescar(), control: inp });
      return true;
    }
    return false;
  }

  if (ev.target.closest('[data-accion="call-nueva"]')) { modalNuevaCall(ctx, api); return true; }

  const iniciar = ev.target.closest('[data-accion="iniciar-renovacion-ren"]');
  if (iniciar) {
    const ok = await confirmar({
      titulo: 'Iniciar proceso de renovación',
      texto: `Se abre una renovación en proceso para ${ctx.c.nombre}.`,
      detalle: 'El cliente pasa a estado "En renovación" hasta que la cierres.',
      ok: 'Iniciar', peligro: false
    });
    if (!ok) return true;
    await guardar(() => iniciarRenovacion(ctx.c), {
      ok: 'Renovación iniciada.', luego: () => api.refrescar(), control: iniciar
    });
    return true;
  }

  const borrarCall = ev.target.closest('[data-call-borrar]');
  if (borrarCall) {
    const c = (ctx.calls || []).find(x => x.id === borrarCall.dataset.callBorrar);
    if (!c) return true;
    const ok = await confirmar({
      titulo: 'Borrar call',
      texto: `Se borra la call de ${textoTipoCall(c.tipo)}${c.fecha ? ' del ' + fmtFechaHora(c.fecha) : ''}.`,
      detalle: 'No se puede deshacer.',
      ok: 'Borrar'
    });
    if (!ok) return true;
    await guardar(() => borrarFila('cs_calls', c.id), {
      ok: 'Call borrada.', luego: () => api.refrescar(), control: borrarCall
    });
    return true;
  }

  const cerrarRen = ev.target.closest('[data-ren-cerrar]');
  if (cerrarRen) {
    const r = (ctx.renovaciones || []).find(x => x.id === cerrarRen.dataset.renCerrar);
    if (r) modalCerrarRenovacion(r, ctx.c, ctx.p, () => api.refrescar());
    return true;
  }

  const borrarRen = ev.target.closest('[data-ren-borrar]');
  if (borrarRen) {
    const r = (ctx.renovaciones || []).find(x => x.id === borrarRen.dataset.renBorrar);
    if (!r) return true;
    const ok = await confirmar({
      titulo: 'Borrar renovación',
      texto: `Se borra la renovación ${(REN_LABEL[r.estado] || r.estado).toLowerCase()} iniciada el ${fmtFecha(r.iniciada_at)}.`,
      detalle: r.estado === 'en_proceso'
        ? 'El cliente vuelve a "Activo" (o a "Finalizado" si el programa ya venció).'
        : 'No se puede deshacer. El estado del cliente no vuelve atrás.',
      ok: 'Borrar'
    });
    if (!ok) return true;
    await guardar(() => borrarFila('cs_renovaciones', r.id), {
      ok: 'Renovación borrada.', luego: () => api.refrescar(), control: borrarRen
    });
    return true;
  }
  return false;
}
