/* Pantalla "Llamadas" (#/p/:programa/llamadas, 124): las llamadas grabadas en Fathom, una pestaña
   por consultor (cuenta de Fathom). Estados: alumno (asignada a una ficha), pendiente (con invitados
   externos, sin alumno) y no es alumno (marcada a mano: prospecto, socio, etc.).
   Es una lista global: no depende del programa desde el que se mira. La pantalla NO decide quién ve
   qué: muestra lo que la RLS devuelve. Llamadas de alumno: quien tiene acceso al programa;
   pendientes y "no es alumno": solo fundador y cliente. Asignar y marcar: la base lo exige igual
   (cs_fathom_asignar / cs_fathom_marcar_no_alumno). Sin la 124 avisa que falta la migración. */
import { esc, fmtFecha, plural, abrirModal, cerrarModal, confirmar, urlSegura } from '../ui.js';
import { yo, esFundador } from '../sesion.js';
import { traerClientes, mensajeError } from '../datos.js';
import {
  traerLlamadasFathom, traerConsultores, traerProgramasHabilitados, asignarLlamada, marcarNoAlumno,
  reabrirLlamada, TIPO_LLAMADA_LABEL, ESTADO_FATHOM_LABEL, MOTIVO_LABEL
} from '../datos-fathom.js';
import { guardar } from './comunes.js';
import { tarjetaError } from './programa.js';
import { montarSelectorAlumno } from './alumno-selector.js';

/* Alumnos de los programas habilitados que el usuario ve (la RLS recorta los que no). */
async function alumnosAsignables() {
  let hab = [];
  try { hab = await traerProgramasHabilitados(); } catch { /* sin la función: ninguno */ }
  const progs = yo.programas.filter(p => hab.includes(p.id));
  const listas = await Promise.all(progs.map(p => traerClientes(p.id)));
  return listas.flatMap((l, i) => l.map(c => ({
    id: c.id, nombre: `${c.nombre} · ${progs[i].nombre}`, estado: c.estado, programa_id: c.programa_id
  })));
}

const bloque = (titulo, texto) => texto
  ? `<details class="fa-det"><summary>${esc(titulo)}</summary><div class="fa-texto">${esc(texto)}</div></details>` : '';

function conQuien(l) {
  if (l.estado === 'alumno') {
    const href = `#/p/${encodeURIComponent(l.programa_id)}/c/${encodeURIComponent(l.cliente_id)}`;
    return `<a href="${esc(href)}">${esc(l.alumno_nombre || 'Alumno')}</a>`;
  }
  const inv = Array.isArray(l.invitados) ? l.invitados : [];
  const motivo = l.estado === 'pendiente' && l.motivo && l.motivo !== 'sin_alumno'
    ? `<div class="hint">${esc(MOTIVO_LABEL[l.motivo] || l.motivo)}</div>` : '';
  return (inv.length ? inv.map(esc).join('<br>') : '—') + motivo;
}

function filaLlamada(l, puedeAsignar) {
  const url = urlSegura(l.grabacion_share_url || l.grabacion_url || '');
  const meta = [TIPO_LLAMADA_LABEL[l.tipo], l.duracion_min ? `${l.duracion_min} min` : ''].filter(Boolean).join(' · ');
  const acciones = !puedeAsignar || l.estado === 'alumno' ? '' : `<span class="ll-item-acc">
      <button type="button" class="btn btn-sm btn-accent" data-fa-asignar="${esc(l.id)}">Asignar a alumno</button>
      ${l.estado === 'pendiente'
        ? `<button type="button" class="btn btn-sm" data-fa-noalumno="${esc(l.id)}">No es alumno</button>`
        : `<button type="button" class="btn btn-sm" data-fa-reabrir="${esc(l.id)}">Volver a pendiente</button>`}
    </span>`;
  return `<tr>
      <td data-label="Fecha">${esc(fmtFecha(l.fecha))}</td>
      <td data-label="Con quién">${conQuien(l)}</td>
      <td data-label="Llamada">
        <div class="duda-texto">${esc(l.titulo || 'Sin título')}</div>
        ${meta ? `<div class="hint">${esc(meta)}</div>` : ''}
        ${bloque('Resumen', l.en_que_esta || l.resumen)}
        ${bloque('Próximos pasos', l.proximos_pasos)}
        ${url ? `<div class="duda-resp"><a href="${esc(url)}" target="_blank" rel="noopener noreferrer">Ver grabación en Fathom</a></div>` : ''}
      </td>
      <td data-label="Estado"><span class="fa-estado fa-${esc(l.estado)}">${esc(ESTADO_FATHOM_LABEL[l.estado] || l.estado)}</span></td>
      <td data-label="" class="acciones">${acciones}</td>
    </tr>`;
}

export function vistaLlamadas(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  /* puedeAsignar: se enciende si el usuario ve alguna pendiente/no_alumno (solo fundador y cliente
     las ven; la base valida cada acción). */
  let llamadas = [], consultores = [], alumnos = [], tab = null;
  const filtro = { estado: '', desde: '', hasta: '' };

  const delTab = () => llamadas.filter(l => (l.consultor || '') === tab);
  const visibles = () => delTab().filter(l =>
    (!filtro.estado || l.estado === filtro.estado)
    && (!filtro.desde || l.fecha >= filtro.desde)
    && (!filtro.hasta || l.fecha <= filtro.hasta));

  function pintar() {
    const puedeAsignar = esFundador() || llamadas.some(l => l.estado !== 'alumno');
    const cuenta = id => llamadas.filter(l => (l.consultor || '') === id).length;
    const tabs = consultores.map(c => `<button type="button" class="tab-btn${c.id === tab ? ' active' : ''}" data-fa-tab="${esc(c.id)}">
        ${esc(c.nombre)}${c.activo ? '' : ' (inactivo)'} <span class="fa-n">${cuenta(c.id)}</span></button>`).join('');
    const lista = visibles();
    const total = delTab().length;
    const act = consultores.find(c => c.id === tab);
    el.innerHTML = `
      <div class="section-title">Llamadas<span class="line"></span></div>
      <div class="hint">Reuniones grabadas en Fathom, separadas por consultor. «Alumno» son las que ya están en la
        ficha de un alumno; «Pendiente» tienen invitados externos pero no coinciden con ningún alumno;
        «No es alumno» las marcó una persona (prospecto, socio, etc.). Las reuniones sin invitados externos no se traen.</div>
      ${consultores.length ? `<nav class="tabs tabs-inline" aria-label="Consultores">${tabs}</nav>` : ''}
      <div class="fa-filtros">
        <label>Estado <select id="fa-f-estado">
          <option value="">Todos</option>
          ${Object.entries(ESTADO_FATHOM_LABEL).map(([k, v]) => `<option value="${k}"${filtro.estado === k ? ' selected' : ''}>${esc(v)}</option>`).join('')}
        </select></label>
        <label>Desde <input type="date" id="fa-f-desde" value="${esc(filtro.desde)}"></label>
        <label>Hasta <input type="date" id="fa-f-hasta" value="${esc(filtro.hasta)}"></label>
        ${filtro.estado || filtro.desde || filtro.hasta ? '<button type="button" class="btn btn-sm" id="fa-f-limpiar">Limpiar filtros</button>' : ''}
      </div>
      <div class="card">${lista.length ? `<div class="table-wrap"><table class="tabla tabla-cards">
          <thead><tr><th>Fecha</th><th>Con quién</th><th>Llamada</th><th>Estado</th><th></th></tr></thead>
          <tbody>${lista.map(l => filaLlamada(l, puedeAsignar)).join('')}</tbody></table></div>
          <div class="hint">${esc(plural(lista.length, 'llamada'))}${total !== lista.length ? ` de ${total}` : ''}.</div>`
        : `<div class="muted-empty">${total
            ? 'Ninguna llamada coincide con los filtros.'
            : `Todavía no hay llamadas${act ? ' de ' + esc(act.nombre) : ''} para mostrar.`}</div>`}</div>`;
  }

  function modalAsignar(l) {
    abrirModal({
      titulo: 'Asignar a alumno',
      cuerpo: `<p class="hint">${esc(fmtFecha(l.fecha))} · ${esc(l.titulo || 'Sin título')}</p>
        <div class="form-row"><label for="fa-alumno">Alumno *</label><div id="fa-alumno-box"></div></div>
        <div class="hint">Solo aparecen alumnos de los programas habilitados para Fathom.</div>
        <div id="fa-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="fa-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="fa-ok">Asignar</button>`
    });
    const sel = montarSelectorAlumno(document.getElementById('fa-alumno-box'), alumnos, { id: 'fa-alumno' });
    sel.foco();
    document.getElementById('fa-cancelar').onclick = cerrarModal;
    document.getElementById('fa-ok').onclick = () => {
      const a = sel.cliente();
      if (!a) { document.getElementById('fa-error').textContent = 'Elegí un alumno de la lista.'; return; }
      cerrarModal();
      guardar(() => asignarLlamada(l.id, a.id), { ok: 'Llamada asignada.', luego: cargar });
    };
  }

  async function cargar() {
    try {
      const [ls, cs, al] = await Promise.all([traerLlamadasFathom(), traerConsultores(), alumnosAsignables()]);
      if (!vigente()) return;
      if (ls === undefined || cs === undefined) {
        el.innerHTML = tarjetaError('Falta correr la migración 124', 'Esta pantalla se activa cuando la migración 124 está corrida.');
        return;
      }
      llamadas = ls;
      alumnos = al;
      /* Pestañas: consultores activos, y los inactivos solo si tienen llamadas visibles. */
      consultores = cs.filter(c => c.activo || llamadas.some(l => l.consultor === c.id));
      if (!consultores.some(c => c.id === tab)) tab = consultores.length ? consultores[0].id : null;
      pintar();
    } catch (e) {
      if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las llamadas', mensajeError(e));
    }
  }

  el.addEventListener('change', ev => {
    const t = ev.target;
    if (t.id === 'fa-f-estado') filtro.estado = t.value;
    else if (t.id === 'fa-f-desde') filtro.desde = t.value;
    else if (t.id === 'fa-f-hasta') filtro.hasta = t.value;
    else return;
    pintar();
  });

  el.addEventListener('click', async ev => {
    const bT = ev.target.closest('[data-fa-tab]');
    if (bT) { tab = bT.dataset.faTab; pintar(); return; }
    if (ev.target.closest('#fa-f-limpiar')) { filtro.estado = filtro.desde = filtro.hasta = ''; pintar(); return; }
    const bA = ev.target.closest('[data-fa-asignar]');
    if (bA) {
      const l = llamadas.find(x => x.id === bA.dataset.faAsignar);
      if (l) modalAsignar(l);
      return;
    }
    const bR = ev.target.closest('[data-fa-reabrir]');
    if (bR) {
      await guardar(() => reabrirLlamada(bR.dataset.faReabrir), { ok: 'Vuelve a estar pendiente.', luego: cargar, control: bR });
      return;
    }
    const bN = ev.target.closest('[data-fa-noalumno]');
    if (bN) {
      const l = llamadas.find(x => x.id === bN.dataset.faNoalumno);
      if (!l) return;
      const ok = await confirmar({
        titulo: 'No es alumno',
        texto: `Se marca la llamada del ${fmtFecha(l.fecha)}${l.titulo ? ' «' + l.titulo + '»' : ''} como "no es alumno".`,
        detalle: 'No se crea nada en ninguna ficha y la sincronización no la va a asignar sola. Se puede volver a pendiente.',
        ok: 'Marcar'
      });
      if (ok) await guardar(() => marcarNoAlumno(l.id), { ok: 'Marcada como "no es alumno".', luego: cargar, control: bN });
    }
  });

  return cargar();
}
