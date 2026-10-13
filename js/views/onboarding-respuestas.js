/* Respuestas de los formularios del onboarding, en lectura, agrupadas por paso.
   Las usan el bloque "Onboarding" de la ficha y la pestaña Onboarding.
   o = salida de cs_onboarding_ficha (pasos + respuestas). Solo las ve quien tiene
   cs_puede_ver: incluyen el diagnóstico financiero. Todo pasa por esc(). */
import { esc } from '../ui.js';

/* "Otros" con texto libre (096): el texto viaja en la clave "<key>_otro". */
function conOtro(c, vals, texto) {
  const otro = c.otro && vals[c.key + '_otro'];
  if (!otro) return texto;
  return texto.split(', ').map(t => (t === c.otro ? `${t}: ${otro}` : t)).join(', ');
}

function valorTexto(c, vals) {
  const v = vals[c.key];
  if (Array.isArray(v)) return conOtro(c, vals, v.join(', '));
  if (c.tipo === 'escala_1_10') return `${v} / 10`;
  return conOtro(c, vals, String(v));
}

const hayValor = (vals, k) => vals[k] !== undefined && vals[k] !== null && vals[k] !== '';

/* abierto = true despliega todos los pasos (pestaña); false los deja plegados (ficha). */
export function respuestasHtml(o, abierto = false) {
  const bloques = [];
  for (const p of o.pasos || []) {
    if (p.tipo !== 'formulario') continue;
    const r = o.respuestas && o.respuestas[p.key];
    if (!r) continue;
    const vals = r.respuestas || {};
    const cuerpo = (p.secciones || []).map(s => {
      const filas = s.campos.filter(c => hayValor(vals, c.key))
        .map(c => `<dt>${esc(c.label)}</dt><dd>${esc(valorTexto(c, vals))}</dd>`).join('');
      return filas ? `${s.titulo ? `<div class="sec">${esc(s.titulo)}</div>` : ''}<dl>${filas}</dl>` : '';
    }).join('');
    bloques.push(`<details class="onb-resp"${abierto ? ' open' : ''}>
      <summary>${esc(p.titulo)} ${r.completo ? '' : '<span class="pend">(borrador, sin enviar)</span>'}</summary>
      ${cuerpo || '<div class="muted-empty">Sin respuestas todavía.</div>'}
    </details>`);
  }
  return bloques.join('');
}
