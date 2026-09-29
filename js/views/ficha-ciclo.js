/* Ficha de cliente — producto y ciclo (039): producto del catálogo, testimonio,
   pausa / reanudación y los dos avisos de renovación.
   ctx.c trae las columnas de 039 (ficha.js las suma a la fila de cs_v_clientes)
   y ctx.productos el catálogo del programa. */
import { esc, fmtFecha, fechaISO_AR, plural, hoyAR, badge, abrirModal, confirmar, toast } from '../ui.js';
import { actualizarFila } from '../datos.js';
import {
  TESTIMONIO_LABEL, opcionesProducto, diasPausado, finVigente, pausarCliente, reanudarCliente,
  fechaSugeridaAviso, registrarAviso
} from '../ciclo.js';
import { opcionesHtml, guardar } from './comunes.js';

const CERRADO = ['finalizado', 'baja'];

function campoProducto(ctx) {
  const { c, productos } = ctx;
  if (!productos || !productos.length) return '';
  const ops = [['', 'Sin producto']].concat(opcionesProducto(productos, c.producto_id));
  return `
    <div class="form-row">
      <label for="f-producto">Producto</label>
      <select id="f-producto" data-ciclo="producto_id">${opcionesHtml(ops, c.producto_id || '')}</select>
      <div class="hint">Cambiarlo no mueve la fecha de fin: la mueve la renovación.</div>
    </div>`;
}

function campoTestimonio(c) {
  return `
    <div class="form-row">
      <label for="f-testimonio">Testimonio</label>
      <select id="f-testimonio" data-ciclo="testimonio">
        ${opcionesHtml(Object.entries(TESTIMONIO_LABEL), c.testimonio || 'sin_pedir')}</select>
    </div>`;
}

function bloquePausa(c) {
  if (c.estado === 'pausado') {
    const d = diasPausado(c);
    return `
      <div class="banner banner-pausa">
        <span>Pausado desde el ${esc(fmtFecha(c.pausado_desde))} (${esc(plural(d, 'día'))}).
          Los días del programa no corren: al reanudar, la fecha de fin pasa del
          ${esc(fmtFecha(c.fecha_fin))} al ${esc(fmtFecha(finVigente(c)))}.</span>
        <button type="button" class="btn btn-sm btn-accent" data-accion="reanudar">Reanudar</button>
      </div>`;
  }
  if (CERRADO.includes(c.estado)) return '';
  return `<button type="button" class="btn btn-sm" data-accion="pausar">Pausar cliente…</button>`;
}

/* Un aviso: fecha en que se hizo (editable) o botón para registrarlo hoy. */
function filaAviso(ctx, n) {
  const { c, p } = ctx;
  const dias = n === 1 ? p.aviso_1_dias : p.aviso_2_dias;
  if (dias == null) return '';
  const at = n === 1 ? c.aviso_1_at : c.aviso_2_at;
  const hecho = at ? fechaISO_AR(at) : '';
  const sugerida = fechaSugeridaAviso(c, p, n);
  const tarde = !hecho && sugerida && sugerida <= hoyAR() && !CERRADO.includes(c.estado) && c.estado !== 'pausado';
  return `
    <div class="aviso-fila">
      <span class="aviso-nombre">Aviso ${esc(String(dias))} días</span>
      ${hecho
        ? badge('Hecho el ' + fmtFecha(hecho), 'var(--sem-verde)', 'status')
        : badge(tarde ? 'Pendiente' : 'Todavía no', tarde ? 'var(--sem-amarillo)' : 'var(--text-faint)', 'status')}
      <input type="date" id="f-aviso-${n}" data-aviso="${n}" value="${esc(hecho)}" max="${esc(hoyAR())}"
        aria-label="Fecha del aviso de ${esc(String(dias))} días">
      ${hecho ? '' : `<button type="button" class="btn btn-sm" data-aviso-hoy="${n}">Hecho hoy</button>`}
      <span class="hint">${sugerida ? 'Corresponde el ' + esc(fmtFecha(sugerida)) : ''}</span>
    </div>`;
}

export function html(ctx) {
  const { c } = ctx;
  return `
    <div class="card ficha-ciclo">
      <div class="ficha-campos">
        ${campoProducto(ctx)}
        ${campoTestimonio(c)}
      </div>
      <div class="ciclo-pausa">${bloquePausa(c)}</div>
      <div class="ciclo-avisos">
        <div class="field-label">Avisos de renovación (se reinician con cada renovación)</div>
        ${filaAviso(ctx, 1)}${filaAviso(ctx, 2)}
      </div>
    </div>`;
}

/* ---------- Acciones ---------- */

function modalPausa(ctx, api) {
  const c = ctx.c;
  const m = abrirModal({
    titulo: 'Pausar cliente',
    cuerpo: `
      <p class="conf-detalle">${esc(c.nombre)} · fin actual ${esc(fmtFecha(c.fecha_fin))}</p>
      <div class="form-row"><label for="pz-desde">Pausado desde</label>
        <input type="date" id="pz-desde" value="${esc(hoyAR())}" max="${esc(hoyAR())}"
          min="${esc(c.fecha_inicio || '')}"></div>
      <div class="hint">Mientras está pausado no corren sus días ni se generan avisos de renovación.
        Al reanudar, la fecha de fin se corre sola por los días pausados.</div>`,
    pie: `<button type="button" class="btn" data-pz="0">Cancelar</button>
          <button type="button" class="btn btn-accent" data-pz="1">Pausar</button>`
  });
  m.el.querySelector('[data-pz="0"]').addEventListener('click', () => m.cerrar());
  const ok = m.el.querySelector('[data-pz="1"]');
  ok.addEventListener('click', async () => {
    const desde = m.el.querySelector('#pz-desde').value;
    if (!desde) { toast('Poné desde cuándo está pausado.', 'error'); return; }
    if (desde > hoyAR()) { toast('La pausa no puede empezar en el futuro.', 'error'); return; }
    if (c.fecha_inicio && desde < c.fecha_inicio) { toast('La pausa no puede ser anterior al inicio.', 'error'); return; }
    const r = await guardar(() => pausarCliente(c.id, desde), {
      ok: 'Cliente pausado.', luego: () => api.refrescar(), control: ok
    });
    if (r !== null) m.cerrar();
  });
}

export async function manejar(ev, ctx, api) {
  const c = ctx.c;

  if (ev.type === 'change') {
    const sel = ev.target.closest('[data-ciclo]');
    if (sel) {
      const campo = sel.dataset.ciclo;
      await guardar(() => actualizarFila('cs_clientes', c.id, { [campo]: sel.value || null }), {
        ok: 'Guardado.', luego: () => api.refrescar(), control: sel
      });
      return true;
    }
    const inp = ev.target.closest('[data-aviso]');
    if (inp) {
      if (inp.value && inp.value > hoyAR()) {
        toast('El aviso no puede tener fecha futura.', 'error');
        await api.refrescar();
        return true;
      }
      await guardar(() => registrarAviso(c.id, Number(inp.dataset.aviso), inp.value || null), {
        ok: inp.value ? 'Aviso registrado.' : 'Aviso borrado.', luego: () => api.refrescar(), control: inp
      });
      return true;
    }
    return false;
  }

  const hoy = ev.target.closest('[data-aviso-hoy]');
  if (hoy) {
    await guardar(() => registrarAviso(c.id, Number(hoy.dataset.avisoHoy)), {
      ok: 'Aviso registrado.', luego: () => api.refrescar(), control: hoy
    });
    return true;
  }

  const btn = ev.target.closest('[data-accion]');
  if (!btn) return false;

  if (btn.dataset.accion === 'pausar') { modalPausa(ctx, api); return true; }

  if (btn.dataset.accion === 'reanudar') {
    const ok = await confirmar({
      titulo: 'Reanudar cliente',
      texto: `${c.nombre} vuelve a estar activo.`,
      detalle: `La fecha de fin se corre ${plural(diasPausado(c), 'día')}: queda el ${fmtFecha(finVigente(c))}.`,
      ok: 'Reanudar', peligro: false
    });
    if (!ok) return true;
    await guardar(() => reanudarCliente(c.id), {
      ok: 'Cliente reanudado.', luego: () => api.refrescar(), control: btn
    });
    return true;
  }
  return false;
}
