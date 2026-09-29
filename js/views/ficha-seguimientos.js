/* Ficha de cliente — Seguimientos (cs_seguimientos, 038).
   Formulario corto arriba (canal, resumen, etapa, avance, próximo contacto) y la
   línea de tiempo abajo, el último primero. Reemplaza al viejo "Registrar chequeo":
   el trigger mueve ultimo_chequeo_at, la etapa del cliente si viene, y deja el
   avance en el historial. */
import { esc, fmtFecha, fmtFechaHora, badge, hoyAR, toast } from '../ui.js';
import {
  registrarSeguimiento, nombreUsuario, esVivo, CANAL_LABEL, AVANCE_LABEL, AVANCE_COLOR
} from '../datos.js';
import { guardar } from './comunes.js';
import { formSeguimiento, anotarCambio, leerSeguimiento, limpiarBorrador } from './seguimiento-form.js';

const PRE = 'seg-f';
const VISIBLES = 8;
const EXPANDIDOS = new Set();   // clienteId con la lista completa abierta

function proximo(s, esUltimo, vivo) {
  if (!s.proximo_contacto) return '';
  const vencido = esUltimo && vivo && s.proximo_contacto < hoyAR();
  return `<span class="seg-prox${vencido ? ' seg-prox-vencido' : ''}"
    title="${vencido ? 'Venció y no hubo un seguimiento después' : 'Próximo contacto'}">
    Próximo contacto: ${esc(fmtFecha(s.proximo_contacto))}${vencido ? ' · vencido' : ''}</span>`;
}

function filaSeguimiento(s, esUltimo, vivo) {
  return `
    <div class="seg-row">
      <div class="seg-row-top">
        <span class="seg-fecha" title="Cargado ${esc(fmtFechaHora(s.created_at))}">${esc(fmtFecha(s.fecha))}</span>
        ${badge(CANAL_LABEL[s.canal] || s.canal, 'var(--text-dim)', 'outline')}
        ${s.avance ? badge(AVANCE_LABEL[s.avance] || s.avance, AVANCE_COLOR[s.avance], 'status') : ''}
        ${s.etapa ? `<span class="seg-etapa">Etapa: ${esc(s.etapa)}</span>` : ''}
        <span class="seg-quien">${esc(nombreUsuario(s.usuario))}</span>
      </div>
      <div class="seg-resumen">${esc(s.resumen)}</div>
      ${proximo(s, esUltimo, vivo)}
    </div>`;
}

function lista(ctx) {
  const todos = ctx.seguimientos || [];
  if (!todos.length) return '<div class="muted-empty">Todavía no hay seguimientos cargados.</div>';
  const abierto = EXPANDIDOS.has(ctx.c.id);
  const vivo = esVivo(ctx.c);
  const filas = (abierto ? todos : todos.slice(0, VISIBLES))
    .map((s, i) => filaSeguimiento(s, i === 0, vivo)).join('');
  const resto = todos.length - VISIBLES;
  const boton = resto > 0
    ? `<button type="button" class="btn btn-sm" data-accion="seg-ver-todos">${abierto ? 'Ver menos' : `Ver ${resto} más`}</button>`
    : '';
  return filas + boton;
}

export function html(ctx) {
  return `
    <div class="section-title">Seguimientos<span class="line"></span></div>
    <div class="card seg-card">
      ${formSeguimiento({ pre: PRE, p: ctx.p, c: ctx.c })}
      <div class="seg-acciones">
        <button type="button" class="btn btn-accent btn-sm" data-accion="guardar-seguimiento">Guardar seguimiento</button>
      </div>
    </div>
    <div class="card card-list seg-lista">${lista(ctx)}</div>`;
}

export async function manejar(ev, ctx, api) {
  if (ev.type === 'submit') return false;
  if (ev.type === 'change') return anotarCambio(ev);

  const btn = ev.target.closest('[data-accion]');
  if (!btn) return false;

  if (btn.dataset.accion === 'seg-ver-todos') {
    if (EXPANDIDOS.has(ctx.c.id)) EXPANDIDOS.delete(ctx.c.id); else EXPANDIDOS.add(ctx.c.id);
    await api.refrescar();
    return true;
  }

  if (btn.dataset.accion === 'guardar-seguimiento') {
    const raiz = btn.closest('.seg-card');
    const { error, foco, datos } = leerSeguimiento(raiz, PRE);
    if (error) {
      toast(error, 'error');
      if (foco) foco.focus();
      return true;
    }
    const r = await guardar(() => registrarSeguimiento(ctx.c, datos), { ok: 'Seguimiento guardado.', control: btn });
    if (r !== null) limpiarBorrador(ctx.c.id);
    await api.refrescar();
    return true;
  }
  return false;
}
