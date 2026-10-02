/* Maestro — columnas de producto y ciclo (039): producto, testimonio, los dos avisos
   de renovación y el estado con pausar / reanudar. Separado de maestro-celdas.js
   por tamaño; usa los mismos helpers (attrs de celda editable, guardado por celda).
   Testimonio se guarda por el camino común (data-campo -> guardarCampoCliente).
   Avisos y pausa son botones: los maneja manejarClick. */
import { esc, fmtFecha, fechaISO_AR, hoyAR, plural, badge, confirmar } from '../ui.js';
import { ESTADO_LABEL, ESTADO_COLOR, esVivo } from '../datos.js';
import {
  TESTIMONIO_LABEL, pausarCliente, reanudarCliente, registrarAviso, fechaSugeridaAviso,
  diasPausado, finVigente
} from '../ciclo.js';
import { opcionesHtml, guardar } from './comunes.js';

const CERRADO = ['finalizado', 'baja'];
const TESTIMONIO_ORDEN = { sin_pedir: 0, pitchiado: 1, coordinado: 2, grabado: 3, no_quiere: 4 };
const txt = v => (v || '').toLowerCase();

function selTestimonio(f) {
  const v = f.testimonio || 'sin_pedir';
  return `<select class="m-edit m-testimonio" id="mx-testimonio-${esc(f.id)}" data-campo="testimonio"
      data-id="${esc(f.id)}" data-prev="${esc(v)}" aria-label="${esc('Testimonio de ' + f.nombre)}">
      ${opcionesHtml(Object.entries(TESTIMONIO_LABEL), v)}</select>`;
}

function celdaEstado(f) {
  const b = badge(ESTADO_LABEL[f.estado] || f.estado, ESTADO_COLOR[f.estado], 'status');
  if (f.estado === 'pausado') {
    const tit = `Pausado desde el ${fmtFecha(f.pausado_desde)} (${plural(diasPausado(f), 'día')})`;
    return `<span class="m-estado" title="${esc(tit)}">${b}
      <button type="button" class="btn btn-sm btn-ghost" data-mx-reanudar="${esc(f.id)}">Reanudar</button></span>`;
  }
  if (!esVivo(f)) return b;
  return `<span class="m-estado">${b}
    <button type="button" class="btn btn-sm btn-ghost" data-mx-pausar="${esc(f.id)}">Pausar</button></span>`;
}

/* Hecho: la fecha. Pendiente: botón (amarillo si ya pasó la fecha que corresponde). */
function celdaAviso(f, prog, n) {
  const at = n === 1 ? f.aviso_1_at : f.aviso_2_at;
  if (at) return `<span title="Aviso registrado">${esc(fmtFecha(fechaISO_AR(at)))}</span>`;
  if (CERRADO.includes(f.estado)) return '<span class="txt-gris">—</span>';
  const sug = fechaSugeridaAviso(f, prog, n);
  const tarde = sug && sug <= hoyAR() && f.estado !== 'pausado';
  return `<button type="button" class="btn btn-sm${tarde ? ' m-aviso-tarde' : ''}" data-mx-aviso="${n}"
    data-id="${esc(f.id)}" title="${esc(sug ? 'Corresponde el ' + fmtFecha(sug) : '')}">Registrar</button>`;
}

/* Columnas para sumar a las de maestro-celdas (mismo formato). */
export function columnasCiclo(prog) {
  return {
    producto: { k: 'producto', lab: 'Producto', cls: 'm-calc', ord: f => txt(f.producto) || '~',
      td: f => (f.producto ? esc(f.producto) : '<span class="txt-gris">—</span>') },
    testimonio: { k: 'testimonio', lab: 'Testimonio', cls: 'm-c-testimonio', edit: true,
      ord: f => TESTIMONIO_ORDEN[f.testimonio] ?? 9, td: selTestimonio },
    aviso1: { k: 'aviso_1_at', lab: `Aviso ${prog.aviso_1_dias ?? 21}`, cls: 'm-calc m-c-aviso',
      ord: f => f.aviso_1_at || '~', td: f => celdaAviso(f, prog, 1) },
    aviso2: { k: 'aviso_2_at', lab: `Aviso ${prog.aviso_2_dias ?? 5}`, cls: 'm-calc m-c-aviso',
      ord: f => f.aviso_2_at || '~', td: f => celdaAviso(f, prog, 2) },
    estado: { k: 'estado', lab: 'Estado', cls: 'm-calc', ord: f => ESTADO_LABEL[f.estado] || f.estado,
      td: celdaEstado }
  };
}

/* click en la planilla. Devuelve true si era un botón de ciclo. */
export async function manejarClick(ev, ctx) {
  const b = ev.target.closest('[data-mx-aviso],[data-mx-pausar],[data-mx-reanudar]');
  if (!b) return false;
  const id = b.dataset.id || b.dataset.mxPausar || b.dataset.mxReanudar;
  const f = ctx.porId.get(id);
  if (!f) return true;

  if (b.dataset.mxAviso) {
    const n = Number(b.dataset.mxAviso);
    await guardar(() => registrarAviso(f.id, n), {
      ok: `Aviso ${n === 1 ? ctx.prog.aviso_1_dias : ctx.prog.aviso_2_dias} registrado hoy.`,
      luego: ctx.refrescar, control: b
    });
    return true;
  }

  if (b.dataset.mxPausar) {
    const ok = await confirmar({
      titulo: 'Pausar cliente',
      texto: `${f.nombre} queda pausado desde hoy.`,
      detalle: 'Sus días no corren y no se generan avisos de renovación. Para otra fecha de inicio de la pausa, usá la ficha.',
      ok: 'Pausar', peligro: false
    });
    if (ok) await guardar(() => pausarCliente(f.id), { ok: 'Cliente pausado.', luego: ctx.refrescar, control: b });
    return true;
  }

  const ok = await confirmar({
    titulo: 'Reanudar cliente',
    texto: `${f.nombre} vuelve a estar activo.`,
    detalle: `La fecha de fin se corre ${plural(diasPausado(f), 'día')}: queda el ${fmtFecha(finVigente(f))}.`,
    ok: 'Reanudar', peligro: false
  });
  if (ok) await guardar(() => reanudarCliente(f.id), { ok: 'Cliente reanudado.', luego: ctx.refrescar, control: b });
  return true;
}
