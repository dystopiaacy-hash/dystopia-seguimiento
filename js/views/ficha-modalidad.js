/* Ficha de cliente — bloque "Modalidad y consultorías" (157).
   Grupal: UNA sola llamada 1 a 1 (el onboarding) y después clases / consultorías grupales; no se alerta por falta
   de 1 a 1 y "días sin llamada" mira la última consultoría a la que asistió. VIP / 1 a 1: llamadas 1 a 1 periódicas.
   La modalidad se deduce del producto / plan; si no se puede, o está mal, se elige acá (la elección manual manda).
   Ven todos los que ven la ficha; cambiar la modalidad: fundador y quien edita el programa.
   ctx.modalidad = { modalidad, modalidad_manual, modalidad_auto, origen } (undefined = 157 sin correr: no se muestra);
   ctx.consultorias = [{ fecha, titulo, hablo, ... }] (undefined = sin permiso o sin la 157). */
import { esc, fmtFecha, plural } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { opcionesHtml, guardar } from './comunes.js';
import { MODALIDAD_LABEL, guardarModalidad } from '../datos-consultorias.js';

const MAX_LISTA = 8;

function explicacion(m) {
  if (m.modalidad === 'grupal') {
    return 'Alumno grupal: tiene una sola llamada 1 a 1 (el onboarding) y después asiste a las consultorías grupales. '
      + 'No se alerta por falta de 1 a 1: "días sin llamada" mira la última consultoría a la que asistió; sin datos de asistencia, no alerta.';
  }
  if (m.modalidad === 'vip') return 'Alumno VIP / 1 a 1: tiene llamadas 1 a 1 periódicas; "días sin llamada" cuenta desde la última.';
  return 'No se pudo deducir del producto o plan del alumno: por ahora se lo trata como 1 a 1. Elegí la modalidad si corresponde.';
}

export function html(ctx) {
  const m = ctx.modalidad;
  if (!m) return '';
  const editar = puedeEditarPrograma(ctx.p.id);
  const auto = m.modalidad_auto ? MODALIDAD_LABEL[m.modalidad_auto] : 'sin dato';
  const pares = [['', `Automática (${auto})`], ['grupal', MODALIDAD_LABEL.grupal], ['vip', MODALIDAD_LABEL.vip]];
  const efectiva = m.modalidad ? MODALIDAD_LABEL[m.modalidad] : 'Sin dato';
  const origen = m.origen === 'manual' ? 'elegida a mano' : m.origen === 'automatica' ? 'deducida del producto / plan' : 'sin dato';
  const ult = ctx.estado && ctx.estado.ultima ? ctx.estado.ultima : null;
  const cons = Array.isArray(ctx.consultorias) ? ctx.consultorias : null;
  const lista = cons && cons.length ? `<ul class="est-lista">${cons.slice(0, MAX_LISTA).map(c => `<li>${esc(fmtFecha(c.fecha))}
      ${c.titulo ? '· ' + esc(c.titulo) : ''} <span class="cc-clase">${c.hablo ? '· habló' : '· asistió'}</span></li>`).join('')}</ul>
      ${cons.length > MAX_LISTA ? `<div class="hint">y ${esc(plural(cons.length - MAX_LISTA, 'consultoría más', 'consultorías más'))}</div>` : ''}` : '';
  return `
    <div class="section-title">Modalidad y consultorías<span class="line"></span></div>
    <div class="card est-card">
      <div class="est-grid">
        <div class="est-bloque">
          <div class="est-lab">Modalidad</div>
          <div class="est-val">${editar
            ? `<select data-modalidad-sel aria-label="Modalidad del alumno">${opcionesHtml(pares, m.modalidad_manual || '')}</select>`
            : esc(efectiva)}</div>
          <div class="hint">${esc(efectiva)} · ${esc(origen)}</div>
        </div>
        ${m.modalidad === 'grupal' ? `<div class="est-bloque">
          <div class="est-lab">Onboarding</div>
          <div class="est-val">${ult && ult.onboarding ? esc(fmtFecha(ult.onboarding)) : '<span class="txt-gris">Sin cargar</span>'}</div>
        </div>` : ''}
      </div>
      <div class="hint">${esc(explicacion(m))}</div>
      ${m.modalidad === 'grupal' || (cons && cons.length) ? `<div class="est-bloque">
        <div class="est-lab">Consultorías grupales</div>
        ${lista || '<div class="est-val txt-gris">Sin datos de asistencia todavía</div>'}
      </div>` : ''}
    </div>`;
}

export async function manejar(ev, ctx, api) {
  if (ev.type !== 'change') return false;
  const s = ev.target.closest('[data-modalidad-sel]');
  if (!s) return false;
  await guardar(() => guardarModalidad(ctx.c.id, s.value), {
    ok: 'Modalidad guardada.', control: s, luego: () => api.refrescar()
  });
  return true;
}
