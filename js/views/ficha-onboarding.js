/* Ficha de cliente — Onboarding por link (093).
   Muestra el avance paso a paso, los datos de contacto que difieren de la ficha
   (la CSM decide: no se pisa nada solo) y las respuestas de los formularios.
   Las respuestas incluyen el diagnóstico financiero: solo las ve quien ya tiene
   acceso al programa (cs_puede_ver) y no viajan en ninguna vista ni lista.
   ctx.onboarding: undefined = 093 sin correr (no se muestra el bloque),
   null = todavía sin link, objeto = cs_onboarding_ficha. */
import { esc, fmtFechaHora, badge } from '../ui.js';
import { soloLectura } from '../sesion.js';
import { resolverDiferenciaOnboarding } from '../datos-onboarding.js';
import { guardar } from './comunes.js';
import { generarYCopiar, mensajeOnboarding } from './onboarding-link.js';
import { respuestasHtml } from './onboarding-respuestas.js';

const ESTADO = {
  pendiente: ['Sin empezar', 'var(--text-dim)'],
  en_curso: ['En curso', 'var(--sem-amarillo)'],
  completado: ['Completado', 'var(--success)']
};
const CAMPO_DIF = { nombre: 'Nombre', email: 'Email', telefono: 'Teléfono' };

const hecho = (o, key) => !!(o.progreso && o.progreso[key] && o.progreso[key].completado_at);

function filaPaso(o, p) {
  let detalle = '';
  if (p.tipo === 'acceso') {
    const hechos = Object.keys((o.progreso[p.key] && o.progreso[p.key].enlaces) || {}).length;
    detalle = ` <span class="pend">(${hechos} de ${p.enlaces.length} confirmados por el alumno)</span>`;
  } else if (p.tipo === 'video') {
    /* "Visto" = llegó al tiempo del video; un video opcional se puede seguir de largo. */
    const pr = o.progreso[p.key] || {};
    const s = Math.round(Number(pr.segundos) || 0);
    const t = s ? `${s} s de video registrados` : 'sin tiempo registrado';
    if (pr.visto_at) detalle = ` <span class="pend">(lo vio: ${t})</span>`;
    else if (hecho(o, p.key)) detalle = ` <span class="pend">(siguió sin verlo: ${t})</span>`;
    else if (s) detalle = ` <span class="pend">(${t})</span>`;
  }
  if (p.obligatorio === false) detalle += ' <span class="pend">· opcional</span>';
  const ok = hecho(o, p.key);
  /* Completó el onboarding antes de que existiera este paso (096): no le corresponde. */
  if (!ok && o.estado === 'completado') {
    return `<li><span class="pend" aria-hidden="true">–</span>
      <span>${esc(p.titulo)} <span class="pend">(paso agregado después: no lo hizo)</span></span></li>`;
  }
  return `<li><span class="${ok ? 'ok' : 'pend'}" aria-hidden="true">${ok ? '✓' : '○'}</span>
    <span>${esc(p.titulo)}${detalle}</span></li>`;
}

function diferenciasHtml(o, editable) {
  const pend = Object.entries(o.diferencias || {}).filter(([, d]) => d && d.estado === 'pendiente');
  if (!pend.length) return '';
  return `<div class="onb-difs">
    <div class="hint">El alumno cargó datos distintos a los de la ficha. No se pisó nada: elegí cuál vale.</div>
    ${pend.map(([campo, d]) => `<div class="onb-dif" data-campo="${esc(campo)}">
      <strong>${esc(CAMPO_DIF[campo] || campo)}</strong><br>
      En la ficha: ${d.ficha ? esc(d.ficha) : '<span class="txt-gris">vacío</span>'}<br>
      Cargó el alumno: ${esc(d.alumno)}
      ${editable ? `<div class="onb-dif-acc">
        <button type="button" class="btn btn-sm btn-accent" data-accion="onb-dif" data-campo="${esc(campo)}" data-res="aplicar">Usar el del alumno</button>
        <button type="button" class="btn btn-sm" data-accion="onb-dif" data-campo="${esc(campo)}" data-res="descartar">Dejar el de la ficha</button>
      </div>` : ''}
    </div>`).join('')}
  </div>`;
}

export function html(ctx) {
  const o = ctx.onboarding;
  if (o === undefined) return '';
  const editable = o ? !!o.puede_editar : !soloLectura();
  const boton = editable
    ? '<button type="button" class="btn btn-sm btn-accent" data-accion="onb-link">Link de onboarding</button>' : '';

  if (!o) {
    return `
      <div class="section-title">Onboarding<span class="line"></span></div>
      <div class="card onb-bloque">
        <div class="muted-empty">Todavía no se generó el link de onboarding de este alumno.</div>
        ${boton ? `<div class="onb-linkbox">${boton}</div>` : ''}
      </div>`;
  }

  const [lab, color] = ESTADO[o.estado] || [o.estado, 'var(--text-dim)'];
  const fechas = [
    o.abierto_at ? `Abrió el link: ${fmtFechaHora(o.abierto_at)}` : 'Todavía no abrió el link',
    o.completado_at ? `Completó: ${fmtFechaHora(o.completado_at)}`
      : `El link vence: ${fmtFechaHora(o.vence_at)}`
  ];
  /* Se listan todos (los opcionales con su marca); "hechos de total" cuenta solo los obligatorios. */
  const visibles = o.pasos.filter(p => p.tipo !== 'final');
  const hayOpcionales = visibles.some(p => p.obligatorio === false);
  return `
    <div class="section-title">Onboarding<span class="line"></span></div>
    <div class="card onb-bloque">
      <div class="onb-estado">
        ${badge(lab, color, 'status')}
        <strong>${esc(o.hechos)} de ${esc(o.total)} pasos${hayOpcionales ? ' obligatorios' : ''}</strong>
        <span class="txt-gris">${esc(o.plantilla)}</span>
        ${boton}
      </div>
      <div class="hint">${fechas.map(esc).join(' · ')}</div>
      <ul class="onb-pasos">${visibles.map(p => filaPaso(o, p)).join('')}</ul>
      <div class="hint">Las confirmaciones "ya lo hice" las marca el alumno. Si algo no es cierto, se corrige
        desde las casillas del Maestro.</div>
      ${diferenciasHtml(o, editable)}
      ${respuestasHtml(o)}
    </div>`;
}

export async function manejar(ev, ctx, api) {
  if (ev.type !== 'click') return false;
  const btn = ev.target.closest('[data-accion]');
  if (!btn) return false;

  if (btn.dataset.accion === 'onb-link') {
    btn.disabled = true;
    await generarYCopiar(ctx.c.id, ctx.c.nombre);
    await api.refrescar();
    return true;
  }

  if (btn.dataset.accion === 'onb-dif') {
    const campo = btn.dataset.campo;
    const res = btn.dataset.res;
    await guardar(async () => {
      try {
        await resolverDiferenciaOnboarding(ctx.c.id, campo, res);
      } catch (e) {
        throw new Error(mensajeOnboarding(e));
      }
    }, { ok: res === 'aplicar' ? 'Dato actualizado en la ficha.' : 'Se dejó el dato de la ficha.',
         luego: () => api.refrescar(), control: btn });
    return true;
  }
  return false;
}
