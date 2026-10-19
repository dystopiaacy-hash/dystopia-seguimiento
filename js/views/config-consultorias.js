/* Configuración general — "Consultorías grupales" (157). Solo fundador.
   Horarios recurrentes de las clases / consultorías grupales: cliente (programa), consultor (cuenta de Fathom),
   día de la semana, hora de inicio (hora Argentina), duración, tolerancia en minutos y activo. Las reuniones de
   Fathom no tienen nombre identificable: una reunión del consultor que arranca dentro de la tolerancia de un horario
   activo, ese día de la semana, se guarda como consultoría grupal de ese cliente (no como llamada de un alumno).
   "Reclasificar llamadas ya sincronizadas" aplica los horarios actuales a lo que ya entró.
   Sin la 157 el bloque avisa que falta la migración. */
import { esc, toast, plural } from '../ui.js';
import { esFundador, yo } from '../sesion.js';
import { faltaObjeto, mensajeCs } from '../datos-faltante.js';
import { opcionesHtml } from './comunes.js';
import { montarConsultorProgramas } from './config-consultor-programas.js';
import {
  DIAS_SEMANA, traerHorarios, traerConsultores, guardarHorario, reclasificarConsultorias
} from '../datos-consultorias.js';

export const htmlConsultorias = () => `
  <div class="conf-seccion">
    <div class="section-title">Consultorías grupales<span class="line"></span></div>
    <div class="card" id="cf-consultorias"><div class="loading-inline">Cargando…</div></div>
  </div>`;

const hhmm = h => String(h || '').slice(0, 5);

function filaHtml(h, programas, consultores) {
  const id = h.id || 'nuevo';
  const progs = programas.map(p => [p.id, p.nombre]);
  const cons = consultores.map(c => [c.id, c.nombre + (c.activo ? '' : ' (inactivo)')]);
  return `<div class="cf-consultor cc-fila" data-cc="${esc(id)}">
    <label>Cliente <select data-k="programa_id">${opcionesHtml(progs, h.programa_id)}</select></label>
    <label>Consultor <select data-k="consultor">${opcionesHtml(cons, h.consultor)}</select></label>
    <label>Día <select data-k="dia_semana">${opcionesHtml(DIAS_SEMANA, h.dia_semana)}</select></label>
    <label>Hora (ART) <input type="time" data-k="hora" value="${esc(hhmm(h.hora))}" required></label>
    <label title="Solo informativa: el match usa el arranque, una clase de 40 min a 3 h cuenta igual">Duración habitual (min) <input type="number" data-k="duracion_min" min="15" max="480" step="5" value="${esc(h.duracion_min)}"></label>
    <label title="Minutos antes o después de la hora en que una reunión cuenta para ESTE horario">Tolerancia (min) <input type="number" data-k="tolerancia_min" min="0" max="240" step="5" value="${esc(h.tolerancia_min)}"></label>
    <label class="cc-activo"><input type="checkbox" data-k="activo"${h.activo ? ' checked' : ''}> Activo</label>
    <label>Nota <input type="text" data-k="nota" maxlength="200" value="${esc(h.nota || '')}"></label>
    <button type="button" class="btn btn-sm btn-accent" data-cc-guardar="${esc(id)}">${h.id ? 'Guardar' : 'Agregar horario'}</button>
  </div>`;
}

const leerFila = fila => {
  const v = {};
  for (const el of fila.querySelectorAll('[data-k]')) v[el.dataset.k] = el.type === 'checkbox' ? el.checked : el.value;
  return v;
};

function validar(v) {
  if (!v.programa_id) throw new Error('Elegí el cliente.');
  if (!v.consultor) throw new Error('Elegí el consultor.');
  if (!/^\d{2}:\d{2}$/.test(v.hora || '')) throw new Error('Cargá la hora de inicio (formato 18:00).');
  const dur = Number(v.duracion_min), tol = Number(v.tolerancia_min);
  if (!Number.isInteger(dur) || dur < 15 || dur > 480) throw new Error('La duración tiene que ser de 15 a 480 minutos.');
  if (!Number.isInteger(tol) || tol < 0 || tol > 240) throw new Error('La tolerancia tiene que ser de 0 a 240 minutos.');
}

export async function montarConsultorias(box, vigente) {
  if (!box) return;
  if (!esFundador()) { box.innerHTML = '<div class="hint">Solo el fundador configura las consultorías.</div>'; return; }

  async function pintar() {
    let horarios, consultores;
    try {
      horarios = await traerHorarios();
      consultores = horarios === undefined ? [] : await traerConsultores();
    } catch (e) {
      if (vigente() && box.isConnected) box.innerHTML = `<div class="hint">${esc(mensajeCs(e))}</div>`;
      return;
    }
    if (!vigente() || !box.isConnected) return;
    if (horarios === undefined) {
      box.innerHTML = '<div class="hint">Falta correr la migración 157 (grupales y consultorías).</div>';
      return;
    }
    const programas = (yo.programas || []).filter(p => p.activo !== false);
    const nuevo = { programa_id: programas[0] ? programas[0].id : '', consultor: consultores[0] ? consultores[0].id : '',
      dia_semana: 5, hora: '18:00', duracion_min: 60, tolerancia_min: 30, activo: true, nota: '' };
    box.innerHTML = `
      <div class="hint">Las reuniones de Fathom no tienen un nombre que las identifique: se reconocen por <strong>día y hora</strong>.
        Si una reunión del consultor arranca dentro de la tolerancia (minutos antes o después de la hora), en ese día, se guarda
        como consultoría grupal de ese cliente: se anota quién asistió, lo que dijo cada alumno y sus preguntas, y NO cuenta como
        llamada 1 a 1. La hora es de Argentina. Para una clase más de la semana, agregá otra fila.</div>
      <div id="cc-lista">${horarios.length
        ? horarios.map(h => filaHtml(h, programas, consultores)).join('')
        : '<div class="muted-empty">Todavía no hay horarios cargados.</div>'}</div>
      <div class="section-title">Agregar un horario<span class="line"></span></div>
      ${filaHtml(nuevo, programas, consultores)}
      <div class="cf-hist">
        <button type="button" class="btn btn-sm" id="cc-reclasificar">Reclasificar llamadas ya sincronizadas</button>
        <span class="hint" id="cc-resultado">Después de cambiar horarios: aplica los horarios actuales a las reuniones que ya entraron
          (las pendientes o internas que caen en un horario pasan a consultoría grupal, de a 25 por vez). No toca llamadas ya asignadas
          a un alumno, ni las que una persona confirmó, ni las consultorías ya registradas. No borra nada y se puede repetir.</span>
      </div>
      <div id="cc-programas"></div>`;
    montarConsultorProgramas(box.querySelector('#cc-programas'), vigente);
  }

  box.addEventListener('click', async ev => {
    const g = ev.target.closest('[data-cc-guardar]');
    const r = ev.target.closest('#cc-reclasificar');
    if (!g && !r) return;
    const b = g || r;
    b.disabled = true;
    try {
      if (g) {
        const v = leerFila(g.closest('.cc-fila'));
        validar(v);
        await guardarHorario({ ...v, id: g.dataset.ccGuardar === 'nuevo' ? null : g.dataset.ccGuardar });
        toast('Horario guardado. Si ya había reuniones en ese horario, usá «Reclasificar».');
        await pintar();
      } else {
        const el = box.querySelector('#cc-resultado');
        const res = await reclasificarConsultorias(p => {
          if (el) el.textContent = `Reclasificando… ${p.hechas} hechas, quedan ${p.quedan}.`;
        });
        const n = res.pendientes_reclasificadas || 0;
        if (el) el.textContent = `Listo: ${plural(n, 'pendiente pasó a consultoría', 'pendientes pasaron a consultoría')}`
          + `${res.quedan > 0 ? ` (quedan ${res.quedan}: volvé a apretar)` : ''}. `
          + `No se tocaron ${res.omitidas_de_alumno || 0} llamadas ya asignadas a un alumno ni ${res.omitidas_confirmadas || 0} confirmadas por una persona. `
          + `Consultorías en total: ${res.consultorias || 0}.`;
        toast('Reclasificación terminada.');
      }
    } catch (e) {
      const unico = e && e.code === '23505';
      toast(unico ? 'Ya existe un horario igual (mismo cliente, consultor, día y hora).'
        : faltaObjeto(e) ? 'Falta correr la migración 157.' : (e.message && !e.code ? e.message : mensajeCs(e)), 'error');
    } finally {
      if (b.isConnected) b.disabled = false;
    }
  });

  await pintar();
}
