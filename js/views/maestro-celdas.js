/* Columnas y celdas del Maestro (#/p/:programa/maestro).
   Dos clases de columna:
     - editables (edit: true): prioridad, responsable, próxima acción, fecha comprometida,
       nota y estado de resell. Se guardan de a una celda, con toast.
     - calculadas: salen tal cual de cs_v_maestro (que a su vez lee cs_v_clientes).
       Solo lectura y con otro fondo.
   Cada control editable lleva id propio (mx-<campo>-<cliente>) para que un refresco
   de realtime no pise lo que se está escribiendo (repintarConservandoFoco), y
   data-prev con el último valor guardado para volver atrás si falla. */
import { esc, fmtFecha, fmtNum, plural, toast, badge, nivelPorDias, diasRestantes } from '../ui.js';
import {
  guardarCampoCliente, iniciarRenovacion, moverRenovacion, mensajeError,
  renAbierta, REN_ABIERTOS, REN_LABEL, RESELL_PRODUCTO_LABEL, PRIORIDAD_LABEL,
  ESTADO_LABEL, ESTADO_COLOR, AVANCE_LABEL, AVANCE_COLOR
} from '../datos.js';
import { opcionesHtml, num } from './comunes.js';
import { modalCerrarRenovacion } from './renovaciones.js';

const PRIO_ORDEN = { alta: 0, media: 1, baja: 2 };
const AVANCE_ORDEN = { trabado: 0, demorado: 1, bien: 2 };
const RESELL_ORDEN = Object.fromEntries(
  REN_ABIERTOS.concat(['renovado', 'no_renovado']).map((e, i) => [e, i]));
const txt = v => (v || '').toLowerCase();

/* ---------- Controles editables ---------- */

const idCtl = (campo, f) => `mx-${campo}-${f.id}`;

function attrs(campo, f, prev, etiqueta) {
  return `id="${esc(idCtl(campo, f))}" data-campo="${esc(campo)}" data-id="${esc(f.id)}"
    data-prev="${esc(prev == null ? '' : prev)}" aria-label="${esc(etiqueta + ' de ' + f.nombre)}"`;
}

function selPrioridad(f) {
  const v = f.prioridad || '';
  return `<select class="m-edit m-prio m-prio-${esc(v || 'sin')}" ${attrs('prioridad', f, v, 'Prioridad')}>
      ${opcionesHtml([['', '—']].concat(Object.entries(PRIORIDAD_LABEL)), v)}</select>`;
}

function inpTexto(campo, f, etiqueta, max, extra = '') {
  const v = f[campo] || '';
  return `<input type="text" class="m-edit" maxlength="${max}" autocomplete="off" value="${esc(v)}"
    title="${esc(v)}" placeholder="—" ${extra} ${attrs(campo, f, v, etiqueta)}>`;
}

function inpFecha(f) {
  const v = f.proxima_accion_fecha || '';
  const d = v ? diasRestantes(v) : null;
  const cls = d == null ? '' : d < 0 ? ' m-vencida' : d === 0 ? ' m-hoy' : '';
  const tit = d == null ? '' : d < 0 ? `Venció hace ${plural(-d, 'día')}` : d === 0 ? 'Es hoy' : `En ${plural(d, 'día')}`;
  return `<input type="date" class="m-edit m-fecha${cls}" value="${esc(v)}" title="${esc(tit)}"
    ${attrs('proxima_accion_fecha', f, v, 'Fecha comprometida')}>`;
}

/* Estado de resell. El value de cada opción dice qué hacer:
     '' / estado actual  -> nada
     mover:<estado>      -> pasa la renovación abierta a otra etapa abierta
     abrir:<estado>      -> abre un pipeline nuevo en esa etapa
     cerrar:<resultado>  -> abre el modal de cierre (renovó exige producto) */
function selResell(f) {
  const cur = f.renovacion_estado || '';
  let ops;
  if (renAbierta(cur)) {
    ops = REN_ABIERTOS.map(e => [e === cur ? cur : 'mover:' + e, REN_LABEL[e]])
      .concat([['cerrar:renovado', 'Cerrar: renovó…'], ['cerrar:no_renovado', 'Cerrar: no renovó…']]);
  } else {
    const actual = cur ? `${REN_LABEL[cur] || cur} (cerrada)` : 'Sin pipeline';
    ops = [[cur, actual]].concat(REN_ABIERTOS.map(e => ['abrir:' + e, 'Abrir: ' + REN_LABEL[e]]));
  }
  return `<select class="m-edit m-resell m-resell-${esc(cur || 'sin')}" ${attrs('resell', f, cur, 'Estado de resell')}>
      ${opcionesHtml(ops, cur)}</select>`;
}

/* ---------- Celdas calculadas ---------- */

function celdaCliente(f, base) {
  const motivos = (f.motivos_semaforo || []).join(' · ') || 'Sin alertas';
  return `<span class="m-cli"><span class="sem-dot sem-${esc(f.semaforo || 'gris')}" title="${esc(motivos)}"></span>
      <a class="cli-nombre" href="${base}/c/${encodeURIComponent(f.id)}">${esc(f.nombre)}</a></span>`;
}

function celdaDias(f, prog) {
  if (f.dias_restantes == null) return '<span class="txt-gris">—</span>';
  const d = num(f.dias_restantes);
  const nivel = nivelPorDias(d, { amarillo: num(prog && prog.aviso_renovacion_dias), rojo: -1 });
  const tit = d < 0 ? `Venció hace ${plural(-d, 'día')} (fin ${fmtFecha(f.fecha_fin)})` : `Fin ${fmtFecha(f.fecha_fin)}`;
  return `<span class="m-num sem-txt-${esc(nivel)}" title="${esc(tit)}">${esc(d)} d</span>`;
}

function celdaConteo(pend, venc, frase) {
  if (!pend) return '<span class="txt-gris">0</span>';
  const tit = venc ? `${pend} pendientes · ${venc} ${frase}` : `${pend} pendientes, ninguno ${frase}`;
  return `<span class="cuenta${venc ? ' txt-rojo' : ''}" title="${esc(tit)}">${fmtNum(pend)}${venc ? `<span class="cuenta-venc">${venc}</span>` : ''}</span>`;
}

function celdaSeguimiento(f) {
  if (!f.ultimo_seguimiento_fecha) return '<span class="txt-gris">Nunca</span>';
  return `<span title="${esc('Último contacto hace ' + plural(num(f.dias_sin_chequeo), 'día'))}">${esc(fmtFecha(f.ultimo_seguimiento_fecha))}</span>`;
}

function celdaAvance(f) {
  if (!f.ultimo_seguimiento_avance) return '<span class="txt-gris">—</span>';
  return badge(AVANCE_LABEL[f.ultimo_seguimiento_avance] || f.ultimo_seguimiento_avance,
    AVANCE_COLOR[f.ultimo_seguimiento_avance], 'status');
}

/* Rojo si venció y no hubo un seguimiento después (cs_v_maestro.proximo_contacto_vencido). */
function celdaProximo(f) {
  if (!f.proximo_contacto) return '<span class="txt-gris">—</span>';
  return f.proximo_contacto_vencido
    ? `<span class="m-prox-vencido" title="Venció y no hubo un seguimiento después">${esc(fmtFecha(f.proximo_contacto))}</span>`
    : esc(fmtFecha(f.proximo_contacto));
}

function celdaProducto(f) {
  if (f.renovacion_estado !== 'renovado' || !f.renovacion_producto) return '<span class="txt-gris">—</span>';
  return esc(RESELL_PRODUCTO_LABEL[f.renovacion_producto] || f.renovacion_producto);
}

/* ---------- Columnas ---------- */
/* k, etiqueta, clase, edit, valor para ordenar, celda HTML. */
export function columnas(prog) {
  const base = '#/p/' + encodeURIComponent(prog.id);
  return [
    { k: 'nombre', lab: 'Cliente', cls: 'col-nombre', ord: f => txt(f.nombre),
      td: f => celdaCliente(f, base) },
    { k: 'prioridad', lab: 'Prioridad', cls: 'm-c-prio', edit: true, ord: f => PRIO_ORDEN[f.prioridad] ?? 9, td: selPrioridad },
    { k: 'responsable', lab: 'Responsable', cls: 'm-c-resp', edit: true, ord: f => txt(f.responsable) || '~',
      td: f => inpTexto('responsable', f, 'Responsable', 80, 'list="mx-responsables"') },
    { k: 'proxima_accion', lab: 'Próxima acción', cls: 'm-c-accion', edit: true, ord: f => txt(f.proxima_accion) || '~',
      td: f => inpTexto('proxima_accion', f, 'Próxima acción', 200) },
    { k: 'proxima_accion_fecha', lab: 'Fecha comprometida', cls: 'm-c-fecha', edit: true,
      ord: f => f.proxima_accion_fecha || '9999', td: inpFecha },
    { k: 'nota_csm', lab: 'Nota', cls: 'm-c-nota', edit: true, ord: f => txt(f.nota_csm) || '~',
      td: f => inpTexto('nota_csm', f, 'Nota', 500) },
    { k: 'renovacion_estado', lab: 'Resell', cls: 'm-c-resell', edit: true,
      ord: f => RESELL_ORDEN[f.renovacion_estado] ?? 9, td: selResell },
    { k: 'renovacion_producto', lab: 'Compró', cls: 'm-calc', ord: f => f.renovacion_producto || '~', td: celdaProducto },
    { k: 'estado', lab: 'Estado', cls: 'm-calc', ord: f => ESTADO_LABEL[f.estado] || f.estado,
      td: f => badge(ESTADO_LABEL[f.estado] || f.estado, ESTADO_COLOR[f.estado], 'status') },
    { k: 'etapa', lab: 'Etapa', cls: 'm-calc', ord: f => txt(f.etapa) || '~',
      td: f => (f.etapa ? esc(f.etapa) : '<span class="txt-gris">—</span>') },
    { k: 'dias_restantes', lab: 'Días', cls: 'm-calc num', ord: f => (f.dias_restantes == null ? 99999 : num(f.dias_restantes)),
      td: f => celdaDias(f, prog) },
    { k: 'acc', lab: 'Acc. pend.', cls: 'm-calc num', ord: f => num(f.acc_bpf_pendientes) + num(f.acc_cliente_pendientes),
      td: f => celdaConteo(num(f.acc_bpf_pendientes) + num(f.acc_cliente_pendientes),
        num(f.acc_bpf_vencidos) + num(f.acc_cliente_vencidos), 'vencidos') },
    { k: 'dev_pendientes', lab: 'Dev. pend.', cls: 'm-calc num', ord: f => num(f.dev_pendientes),
      td: f => celdaConteo(num(f.dev_pendientes), num(f.dev_vencidas_sla), 'fuera de SLA') },
    { k: 'ultimo_seguimiento_fecha', lab: 'Último seguimiento', cls: 'm-calc', ord: f => f.ultimo_seguimiento_fecha || '',
      td: celdaSeguimiento },
    { k: 'ultimo_seguimiento_avance', lab: 'Avance', cls: 'm-calc',
      ord: f => AVANCE_ORDEN[f.ultimo_seguimiento_avance] ?? 9, td: celdaAvance },
    { k: 'proximo_contacto', lab: 'Próximo contacto', cls: 'm-calc', ord: f => f.proximo_contacto || '9999',
      td: celdaProximo },
    { k: 'renovaciones_count', lab: 'Renov.', cls: 'm-calc num', ord: f => num(f.renovaciones_count),
      td: f => esc(num(f.renovaciones_count)) }
  ];
}

/* ---------- Guardado por celda ---------- */

function marcar(ctl, estado) {
  const td = ctl.closest('td');
  if (!td) return;
  td.classList.remove('m-guardando', 'm-ok', 'm-error');
  if (estado) td.classList.add('m-' + estado);
  if (estado === 'ok' || estado === 'error') {
    setTimeout(() => td.classList.remove('m-' + estado), estado === 'ok' ? 1200 : 2500);
  }
}

/* Falló: la celda vuelve al último valor guardado y el error se muestra claro. */
function revertir(ctl, e, ctx) {
  ctl.value = ctl.dataset.prev;
  marcar(ctl, 'error');
  const msg = e && e.code === '23505'
    ? 'Este cliente ya tiene una renovación abierta: se actualizó la planilla.'
    : mensajeError(e);
  toast(msg, 'error');
  /* Si un refresco repintó mientras se guardaba, este control ya no está en pantalla. */
  if (!ctl.isConnected || (e && e.code === '23505')) ctx.refrescar();
}

async function guardarCampo(ctl, fila, ctx) {
  const campo = ctl.dataset.campo;
  const valor = ctl.value.trim();
  if (valor === ctl.dataset.prev) return;
  marcar(ctl, 'guardando');
  ctl.disabled = true;
  try {
    await guardarCampoCliente(fila.id, campo, valor);
    fila[campo] = valor || null;
    ctl.dataset.prev = valor;
    if (ctl.value !== valor) ctl.value = valor;
    ctl.title = ctl.type === 'date' ? '' : valor;
    marcar(ctl, 'ok');
    toast('Guardado.');
    if (campo === 'prioridad' || campo === 'proxima_accion_fecha') ctx.repintar();
  } catch (e) {
    revertir(ctl, e, ctx);
  } finally {
    ctl.disabled = false;
  }
}

async function guardarResell(ctl, fila, ctx) {
  const [accion, estado] = ctl.value.split(':');
  if (!estado) return;
  if (accion === 'cerrar') {
    /* La celda no cambia hasta que el modal guarde: ahí refresca la planilla. */
    ctl.value = ctl.dataset.prev;
    modalCerrarRenovacion({ id: fila.renovacion_id }, fila, ctx.prog, ctx.refrescar, { resultado: estado });
    return;
  }
  marcar(ctl, 'guardando');
  ctl.disabled = true;
  try {
    if (accion === 'mover') await moverRenovacion(fila.renovacion_id, estado);
    else await iniciarRenovacion(fila, estado);
    fila.renovacion_estado = estado;
    marcar(ctl, 'ok');
    toast(accion === 'abrir' ? `Pipeline abierto: ${REN_LABEL[estado]}.` : `Resell: ${REN_LABEL[estado]}.`);
    ctx.refrescar();
  } catch (e) {
    revertir(ctl, e, ctx);
  } finally {
    ctl.disabled = false;
  }
}

/* change de un control editable. Devuelve true si el evento era de una celda. */
export async function manejarCambio(ev, ctx) {
  const ctl = ev.target.closest('[data-campo]');
  if (!ctl) return false;
  const fila = ctx.porId.get(ctl.dataset.id);
  if (!fila) return true;
  if (ctl.dataset.campo === 'resell') await guardarResell(ctl, fila, ctx);
  else await guardarCampo(ctl, fila, ctx);
  return true;
}

/* Enter guarda (sale del campo, dispara change); Escape descarta lo escrito. */
export function manejarTecla(ev) {
  const ctl = ev.target.closest('input[data-campo]');
  if (!ctl) return;
  if (ev.key === 'Enter') { ev.preventDefault(); ctl.blur(); }
  if (ev.key === 'Escape') { ctl.value = ctl.dataset.prev; ctl.blur(); }
}

