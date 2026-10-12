/* Maestro — columna calculada "Onboarding" (093): avance del onboarding por link,
   "3 de 6". Se calcula de cs_onboarding_avance; no se edita en la planilla (el clic
   abre el bloque Onboarding de la ficha). Las casillas por paso (x_ob_*, x_unio_school)
   son columnas normales de tipo casilla y sí se corrigen a mano.
   La columna solo existe si algún alumno del programa tiene onboarding. */
import { esc } from '../ui.js';
import { traerAvanceOnboarding } from '../datos-onboarding.js';

const ORDEN = { completado: 2, en_curso: 1, pendiente: 0 };

/* Pega onb_hechos / onb_total / onb_estado en cada fila. Nunca tira. */
export async function sumarAvanceOnboarding(programaId, filas) {
  let avance = [];
  try {
    avance = await traerAvanceOnboarding(programaId);
  } catch (e) {
    console.error('avance onboarding', e);
  }
  const por = new Map(avance.map(a => [a.cliente_id, a]));
  for (const f of filas) {
    const a = por.get(f.id);
    f.onb_hechos = a ? a.hechos : null;
    f.onb_total = a ? a.total : null;
    f.onb_estado = a ? a.estado : null;
  }
  return avance.length > 0;
}

function celda(f) {
  if (f.onb_total == null) return '<span class="txt-gris">—</span>';
  const txt = `${f.onb_hechos} de ${f.onb_total}`;
  const cls = f.onb_estado === 'completado' ? 'onb-ok' : f.onb_hechos ? '' : 'txt-gris';
  return `<button type="button" class="m-ir" data-mx-ir="onboarding" data-id="${esc(f.id)}"
    title="Abrir el onboarding en la ficha"><span class="${cls}">${esc(txt)}${f.onb_estado === 'completado' ? ' ✓' : ''}</span></button>`;
}

export function columnaOnboarding() {
  return {
    k: 'onb_avance', lab: 'Onboarding', cls: 'm-calc',
    ord: f => (f.onb_total == null ? -1 : (ORDEN[f.onb_estado] ?? 0) * 100 + f.onb_hechos),
    td: celda
  };
}
