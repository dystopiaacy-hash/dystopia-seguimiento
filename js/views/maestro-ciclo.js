/* Maestro — columnas de producto y ciclo (039): producto, testimonio, los dos avisos
   de renovación y el estado con pausar / reanudar. Separado de maestro-celdas.js
   por tamaño; usa los mismos helpers (attrs de celda editable, guardado por celda).
   Testimonio, producto, la fecha de cada aviso y el estado se guardan por el camino
   común (data-campo -> maestro-celdas.js). Finalizado y baja disparan el offboarding:
   piden confirmación adentro de la celda antes de guardar.
   "Hoy" de los avisos, pausa y la confirmación son botones: los maneja manejarClick. */
import { esc, fmtFecha, fechaISO_AR, hoyAR, plural, badge, confirmar } from '../ui.js';
import { ESTADO_LABEL, ESTADO_COLOR, esVivo, guardarCampoCliente } from '../datos.js';
import {
  TESTIMONIO_LABEL, pausarCliente, reanudarCliente, registrarAviso, fechaSugeridaAviso,
  diasPausado, finVigente, opcionesProducto
} from '../ciclo.js';
import { opcionesHtml, guardar } from './comunes.js';

const CERRADO = ['finalizado', 'baja'];
const TESTIMONIO_ORDEN = { sin_pedir: 0, pitchiado: 1, coordinado: 2, grabado: 3, no_quiere: 4 };
const txt = v => (v || '').toLowerCase();

/* Estados que se eligen a mano. Pausado va con sus botones; en_renovacion lo pone la base. */
const ESTADOS_A_MANO = ['onboarding', 'activo', 'finalizado', 'baja'];
/* cliente -> estado elegido que espera el "Sí" (sobrevive a un repintado de realtime). */
const porConfirmar = new Map();
export const limpiarConfirmaciones = () => porConfirmar.clear();

function attrs(campo, f, prev, etiqueta) {
  return `id="mx-${esc(campo)}-${esc(f.id)}" data-campo="${esc(campo)}" data-id="${esc(f.id)}"
    data-prev="${esc(prev)}" aria-label="${esc(etiqueta + ' de ' + f.nombre)}"`;
}

function selTestimonio(f) {
  const v = f.testimonio || 'sin_pedir';
  return `<select class="m-edit m-testimonio" ${attrs('testimonio', f, v, 'Testimonio')}>
      ${opcionesHtml(Object.entries(TESTIMONIO_LABEL), v)}</select>`;
}

/* Activos + el actual. Una vista vieja sin producto_id lo deja en solo lectura. */
function selProducto(f, productos) {
  if (!('producto_id' in f)) return f.producto ? esc(f.producto) : '<span class="txt-gris">—</span>';
  const v = f.producto_id || '';
  return `<select class="m-edit" ${attrs('producto_id', f, v, 'Producto')}>
      ${opcionesHtml([['', '—']].concat(opcionesProducto(productos, v)), v)}</select>`;
}

function celdaEstado(f) {
  const pend = porConfirmar.get(f.id);
  if (pend) {
    return `<span class="m-estado m-estado-conf" role="group" aria-label="${esc('Confirmar estado de ' + f.nombre)}">
      <span>¿${esc(ESTADO_LABEL[pend] || pend)}? Dispara el offboarding.</span>
      <button type="button" class="btn btn-sm btn-danger" data-mx-estado-ok="${esc(f.id)}">Sí</button>
      <button type="button" class="btn btn-sm" data-mx-estado-no="${esc(f.id)}">No</button></span>`;
  }
  if (f.estado === 'pausado') {
    const tit = `Pausado desde el ${fmtFecha(f.pausado_desde)} (${plural(diasPausado(f), 'día')})`;
    return `<span class="m-estado" title="${esc(tit)}">${badge(ESTADO_LABEL[f.estado], ESTADO_COLOR[f.estado], 'status')}
      <button type="button" class="btn btn-sm btn-ghost" data-mx-reanudar="${esc(f.id)}">Reanudar</button></span>`;
  }
  const ops = ESTADOS_A_MANO.map(e => [e, ESTADO_LABEL[e] || e]);
  if (!ESTADOS_A_MANO.includes(f.estado)) ops.unshift([f.estado, ESTADO_LABEL[f.estado] || f.estado]);
  const sel = `<select class="m-edit m-estado-sel" style="color:${esc(ESTADO_COLOR[f.estado] || 'inherit')}"
      ${attrs('estado', f, f.estado, 'Estado')}>${opcionesHtml(ops, f.estado)}</select>`;
  if (!esVivo(f)) return sel;
  return `<span class="m-estado">${sel}
    <button type="button" class="btn btn-sm btn-ghost" data-mx-pausar="${esc(f.id)}">Pausar</button></span>`;
}

/* La fecha se edita siempre. Sin registrar: además el botón que lo registra hoy
   (amarillo si ya pasó la fecha que corresponde). */
function celdaAviso(f, prog, n) {
  const campo = n === 1 ? 'aviso_1_at' : 'aviso_2_at';
  const v = f[campo] ? fechaISO_AR(f[campo]) : '';
  const inp = `<input type="date" class="m-edit m-fecha" value="${esc(v)}" ${attrs(campo, f, v, 'Fecha del aviso ' + n)}>`;
  if (v || CERRADO.includes(f.estado)) return inp;
  const sug = fechaSugeridaAviso(f, prog, n);
  const tarde = sug && sug <= hoyAR() && f.estado !== 'pausado';
  return `<span class="m-aviso">${inp}<button type="button" class="btn btn-sm${tarde ? ' m-aviso-tarde' : ''}" data-mx-aviso="${n}"
    data-id="${esc(f.id)}" title="${esc('Registrar el aviso hoy' + (sug ? ' · corresponde el ' + fmtFecha(sug) : ''))}">Hoy</button></span>`;
}

/* Columnas para sumar a las de maestro-celdas (mismo formato). */
export function columnasCiclo(prog, productos) {
  return {
    producto: { k: 'producto', lab: 'Producto', cls: 'm-c-producto', edit: true, ord: f => txt(f.producto) || '~',
      td: f => selProducto(f, productos) },
    testimonio: { k: 'testimonio', lab: 'Testimonio', cls: 'm-c-testimonio', edit: true,
      ord: f => TESTIMONIO_ORDEN[f.testimonio] ?? 9, td: selTestimonio },
    aviso1: { k: 'aviso_1_at', lab: `Aviso ${prog.aviso_1_dias ?? 21}`, cls: 'm-c-aviso', edit: true,
      ord: f => f.aviso_1_at || '~', td: f => celdaAviso(f, prog, 1) },
    aviso2: { k: 'aviso_2_at', lab: `Aviso ${prog.aviso_2_dias ?? 5}`, cls: 'm-c-aviso', edit: true,
      ord: f => f.aviso_2_at || '~', td: f => celdaAviso(f, prog, 2) },
    estado: { k: 'estado', lab: 'Estado', cls: 'm-c-estado', edit: true, ord: f => ESTADO_LABEL[f.estado] || f.estado,
      td: celdaEstado }
  };
}

/* change del select de estado. true si queda esperando la confirmación en la celda. */
export function pedirConfirmacionEstado(ctl, fila, ctx) {
  if (ctl.dataset.campo !== 'estado' || !CERRADO.includes(ctl.value) || ctl.value === ctl.dataset.prev) return false;
  porConfirmar.set(fila.id, ctl.value);
  ctx.repintar();
  const no = document.querySelector(`[data-mx-estado-no="${CSS.escape(fila.id)}"]`);
  if (no) no.focus();
  return true;
}

/* click en la planilla. Devuelve true si era un botón de ciclo. */
export async function manejarClick(ev, ctx) {
  const b = ev.target.closest('[data-mx-aviso],[data-mx-pausar],[data-mx-reanudar],[data-mx-estado-ok],[data-mx-estado-no]');
  if (!b) return false;
  const id = b.dataset.id || b.dataset.mxPausar || b.dataset.mxReanudar || b.dataset.mxEstadoOk || b.dataset.mxEstadoNo;
  const f = ctx.porId.get(id);
  if (!f) return true;

  if (b.dataset.mxEstadoNo) {
    porConfirmar.delete(id);
    ctx.repintar();
    return true;
  }

  if (b.dataset.mxEstadoOk) {
    const estado = porConfirmar.get(id);
    porConfirmar.delete(id);
    if (!estado) { ctx.repintar(); return true; }
    await guardar(() => guardarCampoCliente(id, 'estado', estado), {
      ok: `${f.nombre}: ${ESTADO_LABEL[estado] || estado}.`, luego: ctx.refrescar, control: b
    });
    return true;
  }

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
