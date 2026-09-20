/* Ficha de cliente — accionables en dos columnas (BPF y Cliente).
   El checkbox completa el accionable al momento; editar y borrar abren modal
   (borrar solo lo ve el fundador). Cada columna tiene alta rápida. */
import { esc, plural, abrirModal, cerrarModal, confirmar, diasRestantes } from '../ui.js';
import { esFundador } from '../sesion.js';
import { actualizarFila, borrarFila, crearFila, ACC_LABEL, RESPONSABLE_LABEL } from '../datos.js';
import { num, opcionesHtml, guardar, badgeAcc, celdaVence } from './comunes.js';

const ABIERTOS = ['pendiente', 'en_proceso'];

function ordenar(filas) {
  return filas.slice().sort((a, b) => {
    const va = a.vence || '9999-12-31';
    const vb = b.vence || '9999-12-31';
    if (va !== vb) return va < vb ? -1 : 1;
    return (a.created_at || '').localeCompare(b.created_at || '');
  });
}

function item(a) {
  const vencido = a.estado !== 'completado' && a.vence && num(diasRestantes(a.vence)) < 0;
  return `
    <div class="acc-item${vencido ? ' acc-vencido' : ''}">
      <label class="acc-check">
        <input type="checkbox" data-acc-check="${esc(a.id)}"${a.estado === 'completado' ? ' checked' : ''}
          aria-label="Completar ${esc(a.titulo)}">
        <span class="acc-titulo">${esc(a.titulo)}</span>
      </label>
      <div class="acc-meta">
        ${badgeAcc(a.estado)}
        <span class="acc-vence">${celdaVence(a)}</span>
        ${a.origen === 'plantilla' ? '<span class="txt-gris" title="Lo creó la plantilla del programa">plantilla</span>' : ''}
        <button type="button" class="btn-icono" data-acc-editar="${esc(a.id)}" title="Editar">Editar</button>
        ${esFundador() ? `<button type="button" class="btn-icono btn-icono-danger" data-acc-borrar="${esc(a.id)}" title="Borrar">Borrar</button>` : ''}
      </div>
      ${a.descripcion ? `<div class="acc-desc">${esc(a.descripcion)}</div>` : ''}
    </div>`;
}

function columna(resp, filas) {
  const abiertos = ordenar(filas.filter(a => ABIERTOS.includes(a.estado)));
  const hechos = filas.filter(a => a.estado === 'completado')
    .sort((a, b) => (b.completado_at || '').localeCompare(a.completado_at || ''));
  const vencidos = abiertos.filter(a => a.vence && num(diasRestantes(a.vence)) < 0).length;

  return `
    <div class="card acc-col">
      <div class="acc-col-head">
        <span class="acc-col-tit">${esc(RESPONSABLE_LABEL[resp])}</span>
        <span class="acc-col-cuenta${vencidos ? ' txt-rojo' : ''}">${esc(plural(abiertos.length, 'pendiente'))}${vencidos ? ` · ${esc(plural(vencidos, 'vencido'))}` : ''}</span>
      </div>
      ${abiertos.length
        ? `<div class="acc-lista">${abiertos.map(item).join('')}</div>`
        : '<div class="muted-empty">No hay accionables pendientes de esta parte.</div>'}
      ${hechos.length
        ? `<details class="acc-hechos"><summary>${esc(plural(hechos.length, 'completado'))}</summary>
             <div class="acc-lista">${hechos.map(item).join('')}</div></details>`
        : ''}
      <form class="acc-alta" data-acc-alta="${esc(resp)}">
        <input type="text" name="titulo" maxlength="200" autocomplete="off" required
          placeholder="Agregar accionable de ${esc(RESPONSABLE_LABEL[resp])}…" aria-label="Nuevo accionable de ${esc(RESPONSABLE_LABEL[resp])}">
        <input type="date" name="vence" aria-label="Vencimiento (opcional)">
        <button type="submit" class="btn btn-sm">Agregar</button>
      </form>
    </div>`;
}

export function html(ctx) {
  const acc = ctx.accionables || [];
  return `
    <div class="section-title">Accionables<span class="line"></span></div>
    <div class="acc-grid">
      ${columna('bpf', acc.filter(a => a.responsable === 'bpf'))}
      ${columna('cliente', acc.filter(a => a.responsable === 'cliente'))}
    </div>`;
}

/* ---------- Acciones ---------- */

function modalEditar(a, ctx, api) {
  abrirModal({
    titulo: 'Editar accionable',
    cuerpo: `
      <div class="form-row"><label for="a-titulo">Título *</label>
        <input type="text" id="a-titulo" maxlength="200" value="${esc(a.titulo)}" autocomplete="off"></div>
      <div class="form-row"><label for="a-desc">Descripción</label>
        <textarea id="a-desc" maxlength="1000">${esc(a.descripcion || '')}</textarea></div>
      <div class="form-grid2">
        <div class="form-row"><label for="a-resp">Responsable</label>
          <select id="a-resp">${opcionesHtml(Object.entries(RESPONSABLE_LABEL), a.responsable)}</select></div>
        <div class="form-row"><label for="a-estado">Estado</label>
          <select id="a-estado">${opcionesHtml(Object.entries(ACC_LABEL), a.estado)}</select></div>
      </div>
      <div class="form-row"><label for="a-vence">Vence</label>
        <input type="date" id="a-vence" value="${esc(a.vence || '')}"></div>
      <div id="a-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="a-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="a-ok">Guardar</button>`
  });
  document.getElementById('a-cancelar').onclick = cerrarModal;
  document.getElementById('a-titulo').focus();
  document.getElementById('a-ok').onclick = () => {
    const titulo = document.getElementById('a-titulo').value.trim();
    if (!titulo) { document.getElementById('a-error').textContent = 'El título es obligatorio.'; return; }
    const cambios = {
      titulo,
      descripcion: document.getElementById('a-desc').value.trim() || null,
      responsable: document.getElementById('a-resp').value,
      estado: document.getElementById('a-estado').value,
      vence: document.getElementById('a-vence').value || null
    };
    cerrarModal();
    guardar(() => actualizarFila('cs_accionables', a.id, cambios), { luego: () => api.refrescar() });
  };
}

export async function manejar(ev, ctx, api) {
  if (ev.type === 'submit') {
    const form = ev.target.closest('[data-acc-alta]');
    if (!form) return false;
    ev.preventDefault();
    const titulo = form.elements.titulo.value.trim();
    if (!titulo) return true;
    const fila = {
      programa_id: ctx.p.id,
      cliente_id: ctx.c.id,
      responsable: form.dataset.accAlta,
      titulo,
      vence: form.elements.vence.value || null
    };
    await guardar(() => crearFila('cs_accionables', fila), {
      ok: 'Accionable agregado.', luego: () => api.refrescar(), control: form.querySelector('button')
    });
    return true;
  }

  if (ev.type === 'change') {
    const chk = ev.target.closest('[data-acc-check]');
    if (!chk) return false;
    const estado = chk.checked ? 'completado' : 'pendiente';
    await guardar(() => actualizarFila('cs_accionables', chk.dataset.accCheck, { estado }), {
      ok: chk.checked ? 'Accionable completado.' : 'Accionable reabierto.',
      luego: () => api.refrescar(), control: chk
    });
    return true;
  }

  const editar = ev.target.closest('[data-acc-editar]');
  if (editar) {
    const a = (ctx.accionables || []).find(x => x.id === editar.dataset.accEditar);
    if (a) modalEditar(a, ctx, api);
    return true;
  }

  const borrar = ev.target.closest('[data-acc-borrar]');
  if (borrar) {
    const a = (ctx.accionables || []).find(x => x.id === borrar.dataset.accBorrar);
    if (!a) return true;
    const ok = await confirmar({
      titulo: 'Borrar accionable',
      texto: `Se borra "${a.titulo}".`,
      detalle: 'No se puede deshacer.',
      ok: 'Borrar'
    });
    if (!ok) return true;
    await guardar(() => borrarFila('cs_accionables', a.id), {
      ok: 'Accionable borrado.', luego: () => api.refrescar(), control: borrar
    });
    return true;
  }
  return false;
}
