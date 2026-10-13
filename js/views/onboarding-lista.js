/* Pestaña "Onboarding" del programa (#/p/:programa/onboarding).
   Una fila por alumno (no finalizado ni dado de baja): producto, Resell, alta,
   avance (pasos obligatorios hechos de total), paso en el que quedó, último
   movimiento y accesos que faltan. Filtros: todos, sin empezar, en curso, completos.
   Abrir un alumno muestra TODAS sus respuestas, agrupadas por paso, en lectura.
   Los datos salen de cs_onboarding_lista (096); las respuestas, de cs_onboarding_ficha
   (solo quien tiene cs_puede_ver). "Nuevo cliente" usa el alta de siempre y deja a
   mano el link de onboarding. Todo lo que viene de la base pasa por esc(). */
import { esc, fmtFecha, fmtFechaHora, plural, badge, toast, abrirModal, cerrarModal } from '../ui.js';
import { soloLectura } from '../sesion.js';
import { tarjetaError } from './programa.js';
import { traerPrograma, mensajeError } from '../datos.js';
import { traerListaOnboarding, traerOnboardingCliente } from '../datos-onboarding.js';
import { abrirModalNuevoCliente } from './cliente-nuevo.js';
import { generarYCopiar, mensajeOnboarding } from './onboarding-link.js';
import { respuestasHtml } from './onboarding-respuestas.js';

const ESTADO = {
  sin_link: ['Sin link', 'var(--text-faint)'],
  pendiente: ['Link sin abrir', 'var(--text-dim)'],
  en_curso: ['En curso', 'var(--sem-amarillo)'],
  completado: ['Completo', 'var(--sem-verde)'],
  sin_plantilla: ['Sin onboarding', 'var(--text-faint)']
};

/* Filtros: qué estados de la base entran en cada uno. */
const FILTROS = [
  ['todos', 'Todos', null],
  ['sin_empezar', 'Sin empezar', ['sin_link', 'pendiente']],
  ['en_curso', 'En curso', ['en_curso']],
  ['completos', 'Completos', ['completado']]
];

/* Primero lo que requiere mirar: en curso, después sin empezar, al final completos. */
const PRIORIDAD = { en_curso: 0, pendiente: 1, sin_link: 2, completado: 3, sin_plantilla: 4 };

const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

function celdaAvance(a) {
  if (a.total == null) return '<span class="txt-gris">—</span>';
  const pct = a.total ? Math.round((a.hechos / a.total) * 100) : 0;
  return `<span class="prog-cell" title="${esc(a.hechos)} de ${esc(a.total)} pasos obligatorios">
      <span class="prog-track"><span class="prog-fill prog-verde" style="width:${pct}%"></span></span>
      <span class="prog-dias">${esc(a.hechos)} de ${esc(a.total)}</span>
    </span>`;
}

/* skool / wpp: null = ese dato no existe en el Maestro del programa (no se muestra). */
function celdaAccesos(a) {
  const datos = [['Skool', a.skool], ['WhatsApp', a.wpp]].filter(([, v]) => v !== null && v !== undefined);
  if (!datos.length) return '<span class="txt-gris">—</span>';
  const faltan = datos.filter(([, v]) => !v).map(([n]) => n);
  return faltan.length
    ? `<span class="txt-amarillo">Falta ${esc(faltan.join(' y '))}</span>`
    : '<span class="onb-ok">Completos</span>';
}

function filaHtml(a, base, editable) {
  const [lab, color] = ESTADO[a.onboarding] || [a.onboarding, 'var(--text-dim)'];
  const puedeLink = editable && !['sin_plantilla', 'completado'].includes(a.onboarding);
  const celdas = [
    ['Alumno', `<a class="cli-nombre" href="${base}/c/${encodeURIComponent(a.cliente_id)}">${esc(a.nombre)}</a>`, 'col-nombre'],
    ['Producto', a.producto ? esc(a.producto) : '<span class="txt-gris">Sin producto</span>', ''],
    ['Resell', a.resell ? badge('Resell', 'var(--accent)', 'status') : '<span class="txt-gris">—</span>', ''],
    ['Alta', a.fecha_alta ? esc(fmtFecha(a.fecha_alta)) : '—', ''],
    ['Estado', badge(lab, color, 'status'), ''],
    ['Avance', celdaAvance(a), 'col-prog'],
    ['Quedó en', a.paso_actual ? esc(a.paso_actual)
      : (a.onboarding === 'completado' ? '<span class="txt-gris">Terminó</span>' : '<span class="txt-gris">—</span>'), ''],
    ['Último movimiento', a.ultimo_movimiento ? esc(fmtFechaHora(a.ultimo_movimiento)) : '<span class="txt-gris">—</span>', ''],
    ['Accesos', celdaAccesos(a), ''],
    ['', `<span class="onb-fila-acc">
        ${a.onboarding === 'sin_link' || a.onboarding === 'sin_plantilla' ? '' :
          `<button type="button" class="btn btn-sm" data-onb-ver="${esc(a.cliente_id)}">Ver respuestas</button>`}
        ${puedeLink ? `<button type="button" class="btn btn-sm" data-onb-link="${esc(a.cliente_id)}">Link</button>` : ''}
      </span>`, '']
  ];
  return `<tr>${celdas.map(([lab2, html, cls]) =>
    `<td class="${cls}" data-label="${esc(lab2)}">${html}</td>`).join('')}</tr>`;
}

function tablaHtml(filas, base, editable, total, hayFiltro) {
  if (!filas.length) {
    return `<div class="card empty-state">
        <div class="big">${total ? 'Ningún alumno coincide con el filtro' : 'Todavía no hay alumnos en este programa'}</div>
        <div class="small">${total ? 'Probá con "Todos".' : 'Creá el primero con "Nuevo cliente".'}</div>
      </div>`;
  }
  const cab = ['Alumno', 'Producto', 'Resell', 'Alta', 'Estado', 'Avance', 'Quedó en', 'Último movimiento', 'Accesos', '']
    .map(t => `<th scope="col">${esc(t)}</th>`).join('');
  return `
    <div class="card table-card tabla-clientes onb-tabla"><table class="data-table">
      <thead><tr>${cab}</tr></thead>
      <tbody>${filas.map(a => filaHtml(a, base, editable)).join('')}</tbody>
    </table></div>
    <div class="table-foot">${hayFiltro ? `${filas.length} de ${plural(total, 'alumno')}` : plural(total, 'alumno')}</div>`;
}

function resumenHtml(alumnos) {
  const n = k => alumnos.filter(a => k.includes(a.onboarding)).length;
  return `<div class="hint">${esc(plural(n(['en_curso']), 'alumno'))} en curso ·
    ${esc(plural(n(['sin_link', 'pendiente']), 'alumno'))} sin empezar ·
    ${esc(plural(n(['completado']), 'alumno'))} con el onboarding completo</div>`;
}

export function vistaOnboarding(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  const f = { filtro: 'todos', q: '' };
  let alumnos = [];
  let timer = null;
  const base = '#/p/' + encodeURIComponent(programaId);
  const editable = !soloLectura();

  function filtrados() {
    const def = FILTROS.find(x => x[0] === f.filtro);
    const q = norm(f.q).trim();
    return alumnos
      .filter(a => !def[2] || def[2].includes(a.onboarding))
      .filter(a => !q || norm(a.nombre).includes(q))
      .sort((a, b) => (PRIORIDAD[a.onboarding] ?? 9) - (PRIORIDAD[b.onboarding] ?? 9)
        || String(b.fecha_alta || '').localeCompare(String(a.fecha_alta || ''))
        || String(a.nombre).localeCompare(String(b.nombre), 'es'));
  }

  function cuenta(def) {
    return def[2] ? alumnos.filter(a => def[2].includes(a.onboarding)).length : alumnos.length;
  }

  function pintarTabla() {
    const cont = el.querySelector('#onb-tabla');
    if (!cont) return;
    const hay = f.filtro !== 'todos' || !!f.q.trim();
    cont.innerHTML = tablaHtml(filtrados(), base, editable, alumnos.length, hay);
  }

  function pintarTodo() {
    const foco = document.activeElement && document.activeElement.id === 'onb-q';
    const pos = foco ? document.activeElement.selectionStart : null;
    el.innerHTML = `
      <div class="barra-acciones">
        <div class="section-title">Onboarding<span class="line"></span></div>
        ${editable ? '<button type="button" class="btn btn-accent btn-sm" id="onb-nuevo">Nuevo cliente</button>' : ''}
      </div>
      ${resumenHtml(alumnos)}
      <div class="filter-row onb-filtros">
        <span class="onb-chips" role="group" aria-label="Filtrar por estado">
          ${FILTROS.map(d => `<button type="button" class="btn btn-sm${f.filtro === d[0] ? ' btn-accent' : ''}"
            data-onb-filtro="${esc(d[0])}" aria-pressed="${f.filtro === d[0]}">${esc(d[1])} (${cuenta(d)})</button>`).join('')}
        </span>
        <input type="search" id="onb-q" class="search-input" placeholder="Buscar alumno…" value="${esc(f.q)}" aria-label="Buscar alumno">
      </div>
      <div id="onb-tabla"></div>`;
    pintarTabla();
    if (foco) {
      const inp = el.querySelector('#onb-q');
      if (inp) {
        inp.focus();
        if (pos != null) inp.setSelectionRange(pos, pos);
      }
    }
  }

  async function verRespuestas(clienteId) {
    const a = alumnos.find(x => x.cliente_id === clienteId);
    let o;
    try {
      o = await traerOnboardingCliente(clienteId);
    } catch (e) {
      toast(mensajeOnboarding(e), 'error');
      return;
    }
    const cuerpo = !o
      ? '<div class="muted-empty">Este alumno todavía no tiene onboarding.</div>'
      : (respuestasHtml(o, true) || '<div class="muted-empty">Todavía no respondió ningún formulario.</div>');
    abrirModal({
      titulo: a ? `Respuestas de ${a.nombre}` : 'Respuestas',
      ancho: true,
      cuerpo: `<div class="onb-resp-modal">${cuerpo}
        ${a ? `<p class="hint"><a href="${base}/c/${encodeURIComponent(clienteId)}">Abrir la ficha</a></p>` : ''}</div>`,
      pie: '<button type="button" class="btn btn-accent" data-cerrar="1">Cerrar</button>'
    });
    const b = document.querySelector('[data-cerrar="1"]');
    if (b) b.onclick = cerrarModal;
  }

  async function cargar() {
    const filas = await traerListaOnboarding(programaId);
    if (!vigente()) return;
    if (filas === undefined) {
      el.innerHTML = tarjetaError('Falta la migración 096',
        'La pestaña Onboarding necesita la migración 096 aplicada en la base.');
      return;
    }
    alumnos = filas;
    pintarTodo();
  }

  el.addEventListener('click', async ev => {
    const filtro = ev.target.closest('[data-onb-filtro]');
    if (filtro && el.contains(filtro)) {
      f.filtro = filtro.dataset.onbFiltro;
      pintarTodo();
      return;
    }
    const ver = ev.target.closest('[data-onb-ver]');
    if (ver && el.contains(ver)) {
      ver.disabled = true;
      await verRespuestas(ver.dataset.onbVer);
      if (ver.isConnected) ver.disabled = false;
      return;
    }
    const link = ev.target.closest('[data-onb-link]');
    if (link && el.contains(link)) {
      link.disabled = true;
      const a = alumnos.find(x => x.cliente_id === link.dataset.onbLink);
      await generarYCopiar(link.dataset.onbLink, a ? a.nombre : '');
      if (vigente()) cargar().catch(e => console.error('onboarding', e));
      return;
    }
    if (ev.target.closest('#onb-nuevo')) {
      try {
        const p = await traerPrograma(programaId);
        if (!p) { toast('No se pudo cargar el programa.', 'error'); return; }
        abrirModalNuevoCliente(p, () => cargar().catch(e => console.error('onboarding', e)));
      } catch (e) {
        toast(mensajeError(e), 'error');
      }
    }
  });

  el.addEventListener('input', ev => {
    if (ev.target.id !== 'onb-q') return;
    f.q = ev.target.value;
    clearTimeout(timer);
    timer = setTimeout(pintarTabla, 150);
  });

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar el onboarding', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('onboarding', e)) };
}
