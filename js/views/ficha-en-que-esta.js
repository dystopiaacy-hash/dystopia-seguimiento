/* Ficha de cliente — bloque "En qué está" automático (137, IA).
   Texto de 3 a 5 líneas armado con los resúmenes de las llamadas de Fathom: se actualiza solo
   (10:27 y 19:27) y con el botón "Actualizar" (fundador y edición del programa). El rol cliente
   solo lo lee. Carga sus datos por su cuenta: sin la 137 el bloque avisa y la ficha sigue igual. */
import { esc, fmtFecha, fmtFechaHora, toast } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { traerEnQueEsta, actualizarEnQueEsta } from '../datos-ia.js';
import { limpiarMarkdown } from '../texto-limpio.js';

/* Lo último cargado: sobrevive a los repintados de la ficha (se pierde al cambiar de alumno). */
let cache = { id: null, fila: undefined, error: false };

function cuerpo(ctx) {
  if (cache.id !== ctx.c.id) return '<div class="loading-inline">Cargando…</div>';
  if (cache.error) return '<div class="hint">No se pudo cargar el resumen automático.</div>';
  if (cache.fila === undefined) return '<div class="hint">Falta correr la migración 137 (IA).</div>';
  const puede = puedeEditarPrograma(ctx.p.id);
  const boton = puede
    ? '<button type="button" class="btn btn-sm" data-ia-actualizar>Actualizar</button>' : '';
  const f = cache.fila;
  if (!f) {
    return `<div class="est-val txt-gris">Todavía no hay un resumen automático: se arma cuando el alumno tiene llamadas de Fathom con resumen.</div>
      <div class="est-pie"><span></span>${boton}</div>`;
  }
  const reu = Array.isArray(f.reuniones) ? f.reuniones : [];
  const lista = reu.map(r => esc(fmtFecha(r.fecha)) + (r.titulo ? ' · ' + esc(r.titulo) : '')).join('<br>');
  return `
    <div class="est-val" style="white-space:pre-line">${esc(limpiarMarkdown(f.texto))}</div>
    <div class="est-pie">
      <span>Actualizado el ${esc(fmtFechaHora(f.actualizado_en))} · armado con IA a partir de ${reu.length} ${reu.length === 1 ? 'reunión' : 'reuniones'} de Fathom</span>
      ${boton}
    </div>
    ${reu.length ? `<details class="hint"><summary>Reuniones usadas</summary>${lista}</details>` : ''}`;
}

export function html(ctx) {
  return `
    <div class="section-title">En qué está (automático)<span class="line"></span></div>
    <div class="card est-card" data-ia-box>${cuerpo(ctx)}</div>`;
}

function repintar(cont, ctx) {
  const box = cont && cont.querySelector('[data-ia-box]');
  if (box && box.isConnected) box.innerHTML = cuerpo(ctx);
}

export function montar(cont, ctx) {
  if (cache.id === ctx.c.id) return;
  const id = ctx.c.id;
  traerEnQueEsta(id)
    .then(fila => { cache = { id, fila, error: false }; repintar(cont, ctx); })
    .catch(e => { console.error('en que esta', e); cache = { id, fila: undefined, error: true }; repintar(cont, ctx); });
}

export async function manejar(ev, ctx) {
  if (ev.type !== 'click') return false;
  const b = ev.target.closest('[data-ia-actualizar]');
  if (!b) return false;
  const cont = b.closest('[data-ia-box]').parentElement;
  b.disabled = true;
  b.textContent = 'Actualizando…';
  try {
    const r = await actualizarEnQueEsta(ctx.c.id);
    toast(r && r.estado === 'sin_resumenes'
      ? 'Este alumno todavía no tiene llamadas de Fathom con resumen.' : 'Resumen actualizado.');
    cache = { id: ctx.c.id, fila: await traerEnQueEsta(ctx.c.id), error: false };
  } catch (e) {
    toast(mensajeError(e), 'error');
  }
  repintar(cont, ctx);
  return true;
}
