/* Ficha de cliente — bloque "Riesgo de abandono" (139, IA).
   Indicador bajo / medio / alto con el motivo en una línea, qué hacer y si es buen momento de pedir referido o
   testimonio. Lo arma Haiku cada mañana (8:27) solo si algo cambió desde la última vez; "Evaluar ahora" lo fuerza.
   Lo ven y lo usan el fundador y quien edita el programa (el rol cliente no: la base no se lo muestra).
   Carga sus datos por su cuenta: sin la 139 o sin permiso el bloque no aparece y la ficha sigue igual. */
import { esc, fmtFechaHora, toast } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { traerRiesgo, evaluarRiesgo } from '../datos-riesgo.js';

const NIVEL = {
  alto: ['Riesgo alto', 'ia-riesgo-alto'],
  medio: ['Riesgo medio', 'ia-riesgo-medio'],
  bajo: ['Riesgo bajo', 'ia-riesgo-bajo']
};

/* Lo último cargado: sobrevive a los repintados de la ficha (se pierde al cambiar de alumno). */
let cache = { id: null, fila: undefined, error: false };

function cuerpo(ctx) {
  if (cache.id !== ctx.c.id) return '<div class="loading-inline">Cargando…</div>';
  if (cache.error) return '<div class="hint">No se pudo cargar el riesgo de abandono.</div>';
  const boton = '<button type="button" class="btn btn-sm" data-riesgo-evaluar>Evaluar ahora</button>';
  const f = cache.fila;
  if (!f) {
    return `<div class="est-val txt-gris">Todavía no se evaluó. Se evalúa solo cada mañana si el alumno está activo.</div>
      <div class="est-pie"><span></span>${boton}</div>`;
  }
  const [etiqueta, clase] = NIVEL[f.nivel] || [f.nivel, ''];
  const momentos = [f.buen_momento_referido ? 'pedir un referido' : '', f.buen_momento_testimonio ? 'pedir un testimonio' : '']
    .filter(Boolean);
  return `
    <div class="ia-riesgo-linea"><span class="est-chip ${clase}">${esc(etiqueta)}</span>
      <span class="est-val">${esc(f.motivo)}</span></div>
    ${f.accion ? `<div class="est-val"><strong>Qué hacer:</strong> ${esc(f.accion)}</div>` : ''}
    ${momentos.length ? `<div class="est-val"><span class="est-chip est-listo">Buen momento para ${esc(momentos.join(' y '))}</span></div>` : ''}
    <div class="est-pie">
      <span>Evaluado el ${esc(fmtFechaHora(f.evaluado_en))} · armado con IA a partir de las llamadas, pagos y satisfacción</span>
      ${boton}
    </div>`;
}

export function html(ctx) {
  if (!puedeEditarPrograma(ctx.p.id)) return '';
  return `
    <div class="section-title">Riesgo de abandono (IA)<span class="line"></span></div>
    <div class="card est-card" data-riesgo-box>${cuerpo(ctx)}</div>`;
}

function repintar(cont, ctx) {
  const box = cont && cont.querySelector('[data-riesgo-box]');
  if (box && box.isConnected) box.innerHTML = cuerpo(ctx);
}

export function montar(cont, ctx) {
  if (!puedeEditarPrograma(ctx.p.id) || cache.id === ctx.c.id) return;
  const id = ctx.c.id;
  traerRiesgo(id)
    .then(fila => {
      cache = { id, fila, error: false };
      if (fila === undefined) { const t = cont.querySelector('[data-riesgo-box]'); if (t) t.parentElement.hidden = true; }
      repintar(cont, ctx);
    })
    .catch(e => { console.error('riesgo', e); cache = { id, fila: undefined, error: true }; repintar(cont, ctx); });
}

export async function manejar(ev, ctx) {
  if (ev.type !== 'click') return false;
  const b = ev.target.closest('[data-riesgo-evaluar]');
  if (!b) return false;
  const cont = b.closest('[data-riesgo-box]').parentElement;
  b.disabled = true;
  b.textContent = 'Evaluando…';
  try {
    const r = await evaluarRiesgo(ctx.c.id);
    toast(r && r.estado === 'no_evaluable' ? 'Solo se evalúan alumnos activos, en onboarding o en renovación.' : 'Riesgo evaluado.');
    cache = { id: ctx.c.id, fila: await traerRiesgo(ctx.c.id), error: false };
  } catch (e) {
    toast(mensajeError(e), 'error');
  }
  repintar(cont, ctx);
  return true;
}
