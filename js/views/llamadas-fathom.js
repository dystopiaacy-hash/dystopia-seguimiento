/* Pantalla "Llamadas" (#/p/:programa/llamadas, 124): las llamadas grabadas en Fathom, una pestaña
   por consultor (cuenta de Fathom). Estados: alumno (asignada a una ficha), pendiente (con invitados
   externos, sin alumno) y no es alumno (marcada a mano: prospecto, socio, etc.).
   Es una lista global: no depende del programa desde el que se mira. La pantalla NO decide quién ve
   qué: muestra lo que la RLS devuelve. Llamadas de alumno: quien tiene acceso al programa;
   pendientes y "no es alumno": solo fundador y cliente. Asignar y marcar: la base lo exige igual
   (cs_fathom_asignar / cs_fathom_marcar_no_alumno). Sin la 124 avisa que falta la migración. */
import { esc, fmtFecha, plural, abrirModal, cerrarModal, confirmar, urlSegura, toast } from '../ui.js';
import { limpiarMarkdown } from '../texto-limpio.js';
import { yo, esFundador } from '../sesion.js';
import { mensajeError } from '../datos.js';
import {
  traerLlamadasFathom, traerConsultores, traerAlumnosAsignables, asignarLlamada, marcarNoAlumno,
  reabrirLlamada, confirmarLlamada, corregirLlamada, resumenAprendido,
  TIPO_LLAMADA_LABEL, ESTADO_FATHOM_LABEL, CLASIFICACION_LABEL, MOTIVO_LABEL
} from '../datos-fathom.js';
import { guardar } from './comunes.js';
import { tarjetaError } from './programa.js';
import { montarSelectorAlumno } from './alumno-selector.js';
import { crearPropuestas } from './llamadas-propuestas.js';

/* Alumnos de los programas habilitados a los que el usuario puede asignar (cs_fathom_alumnos, 126:
   solo id, nombre, programa y estado; sirve también al consultor, que no ve las fichas). */
async function alumnosAsignables() {
  let lista = [];
  try { lista = await traerAlumnosAsignables(); } catch { /* sin la función: ninguno */ }
  const prog = id => { const p = yo.programas.find(x => x.id === id); return p ? p.nombre : id; };
  return lista.map(c => ({
    id: c.id, nombre: `${c.nombre} · ${prog(c.programa_id)}`, estado: c.estado, programa_id: c.programa_id
  }));
}

/* Avisa el resultado de asignar / confirmar / corregir y, aparte, un alias que no se pudo guardar
   (choca con otro alumno): ese aviso es de error y se queda visible. */
function avisarResultado(base, r) {
  toast(base);
  const conf = r && Array.isArray(r.alias_conflictos) ? r.alias_conflictos : [];
  if (r && r.alias_guardados) toast(resumenAprendido({ alias_guardados: r.alias_guardados }));
  if (conf.length) toast(resumenAprendido({ alias_conflictos: conf }), 'error');
}

const bloque = (titulo, texto) => texto
  ? `<details class="fa-det"><summary>${esc(titulo)}</summary><div class="fa-texto">${esc(limpiarMarkdown(texto))}</div></details>` : '';

function conQuien(l, alumnos) {
  if (l.estado === 'alumno') {
    const href = `#/p/${encodeURIComponent(l.programa_id)}/c/${encodeURIComponent(l.cliente_id)}`;
    return `<a href="${esc(href)}">${esc(l.alumno_nombre || 'Alumno')}</a>`;
  }
  const inv = Array.isArray(l.invitados) ? l.invitados : [];
  const motivo = l.estado === 'pendiente' && l.motivo && l.motivo !== 'sin_alumno'
    ? `<div class="hint">${esc(MOTIVO_LABEL[l.motivo] || l.motivo)}</div>` : '';
  /* Candidatos: alumnos que coinciden por mail o por nombre y no se pudo decidir cuál. */
  const cand = (Array.isArray(l.candidatos) ? l.candidatos : [])
    .map(id => alumnos.find(a => a.id === id)).filter(Boolean);
  const posibles = cand.length
    ? `<div class="hint">Posibles: ${cand.map(a => esc(a.nombre)).join(' · ')}</div>` : '';
  return (inv.length ? inv.map(esc).join('<br>') : '—') + motivo + posibles;
}

function filaLlamada(l, puedeAsignar, alumnos) {
  const url = urlSegura(l.grabacion_share_url || l.grabacion_url || '');
  const meta = [TIPO_LLAMADA_LABEL[l.tipo], l.duracion_min ? `${l.duracion_min} min` : ''].filter(Boolean).join(' · ');
  const porNombre = l.estado === 'alumno' && l.asignada_por === 'nombre';
  let acciones = '';
  if (l.estado === 'alumno') {
    /* La base valida el permiso de cada acción; el botón aparece si hay alumnos a quién corregir. */
    if (alumnos.length) {
      acciones = `<span class="ll-item-acc">
        ${porNombre ? `<button type="button" class="btn btn-sm btn-accent" data-fa-confirmar="${esc(l.id)}">Confirmar</button>` : ''}
        <button type="button" class="btn btn-sm" data-fa-corregir="${esc(l.id)}">Corregir</button>
      </span>`;
    }
  } else if (puedeAsignar) {
    acciones = `<span class="ll-item-acc">
      <button type="button" class="btn btn-sm btn-accent" data-fa-asignar="${esc(l.id)}">Asignar a alumno</button>
      ${l.estado === 'pendiente' || l.estado === 'interna'
        ? `<button type="button" class="btn btn-sm" data-fa-noalumno="${esc(l.id)}">No es alumno</button>`
        : `<button type="button" class="btn btn-sm" data-fa-reabrir="${esc(l.id)}">Volver a pendiente</button>`}
    </span>`;
  }
  /* 187: una llamada "no es alumno" que alguien clasificó (clase, venta, interna, otra) muestra su tipo. */
  const tipoNoAlumno = l.estado === 'no_alumno' ? CLASIFICACION_LABEL[l.clasificacion] : '';
  const estadoTxt = porNombre
    ? `<span class="fa-estado fa-alumno fa-por-nombre">Alumno · por nombre</span>
       <div class="hint">Asignada por coincidencia de nombre: confirmala o corregila.</div>`
    : tipoNoAlumno
      ? `<span class="fa-estado fa-clasificada">${esc(tipoNoAlumno)}</span><div class="hint">No es de un alumno.</div>`
      : `<span class="fa-estado fa-${esc(l.estado)}">${esc(ESTADO_FATHOM_LABEL[l.estado] || l.estado)}</span>`;
  return `<tr>
      <td data-label="Fecha">${esc(fmtFecha(l.fecha))}</td>
      <td data-label="Con quién">${conQuien(l, alumnos)}</td>
      <td data-label="Llamada">
        <div class="duda-texto">${esc(l.titulo || 'Sin título')}</div>
        ${meta ? `<div class="hint">${esc(meta)}</div>` : ''}
        ${bloque('Resumen', l.en_que_esta || l.resumen)}
        ${bloque('Próximos pasos', l.proximos_pasos)}
        ${url ? `<div class="duda-resp"><a href="${esc(url)}" target="_blank" rel="noopener noreferrer">Ver grabación en Fathom</a></div>` : ''}
      </td>
      <td data-label="Estado">${estadoTxt}</td>
      <td data-label="" class="acciones">${acciones}</td>
    </tr>`;
}

export function vistaLlamadas(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  /* puedeAsignar: se enciende si el usuario ve alguna pendiente/no_alumno (fundador, consultor y cliente;
     el cliente solo las de su programa). La base valida cada acción. */
  let llamadas = [], consultores = [], alumnos = [], tab = null;
  const filtro = { estado: '', desde: '', hasta: '' };
  /* Propuestas de la IA (186): sección propia arriba de la lista; aceptar / corregir recargan todo. */
  const propuestas = crearPropuestas({ llamadas: () => llamadas, alumnos: () => alumnos, alCambiar: () => cargar() });

  const delTab = () => llamadas.filter(l => (l.consultor || '') === tab);
  /* Las internas (127) quedan ocultas salvo que el filtro de estado sea "Internas". */
  const visibles = () => delTab().filter(l =>
    (filtro.estado
      ? (filtro.estado === 'por_nombre' ? l.estado === 'alumno' && l.asignada_por === 'nombre'
        : filtro.estado.startsWith('c_') ? l.estado === 'no_alumno' && l.clasificacion === filtro.estado.slice(2)
        : filtro.estado === 'no_alumno' ? l.estado === 'no_alumno' && !l.clasificacion
        : l.estado === filtro.estado)
      : l.estado !== 'interna')
    && (!filtro.desde || l.fecha >= filtro.desde)
    && (!filtro.hasta || l.fecha <= filtro.hasta));

  function pintar() {
    const puedeAsignar = esFundador() || llamadas.some(l => l.estado !== 'alumno');
    const cuenta = id => llamadas.filter(l => (l.consultor || '') === id && l.estado !== 'interna').length;
    const nInternas = delTab().filter(l => l.estado === 'interna').length;
    const tabs = consultores.map(c => `<button type="button" class="tab-btn${c.id === tab ? ' active' : ''}" data-fa-tab="${esc(c.id)}">
        ${esc(c.nombre)}${c.activo ? '' : ' (inactivo)'} <span class="fa-n">${cuenta(c.id)}</span></button>`).join('');
    const lista = visibles();
    const total = delTab().filter(l => filtro.estado || l.estado !== 'interna').length;
    const act = consultores.find(c => c.id === tab);
    el.innerHTML = `
      <div id="fa-prop-box" class="pi-seccion"></div>
      <div class="section-title">Llamadas<span class="line"></span></div>
      <div class="hint">Todas las reuniones grabadas en Fathom, separadas por consultor. «Alumno» son las que ya están
        en la ficha de un alumno; «Pendiente» tienen a alguien o un nombre en el título pero no coinciden con ningún
        alumno; «Interna» no tiene a nadie de afuera (solo vos o el equipo; ocultas, se ven con el filtro «Internas»);
        «No es alumno» las marcó una persona (prospecto, socio, etc.).
        Se asignan solas por el mail del invitado (principal o extra); si no coincide, por nombre o alias (queda marcada
        «por nombre» para que la confirmes o corrijas). Al asignar o confirmar a mano, los mails de la llamada y los
        nombres (invitado o título) quedan como del alumno y la próxima se asigna sola.</div>
      ${yo.rol === 'cliente' ? `<div class="hint">Ves solo las llamadas de tu programa: las de tus alumnos y las pendientes
        que tienen a un alumno tuyo como posible o propuesto. El resto lo ven el fundador y el consultor.</div>` : ''}
      ${consultores.length ? `<nav class="tabs tabs-inline" aria-label="Consultores">${tabs}</nav>` : ''}
      <div class="fa-filtros">
        <label>Estado <select id="fa-f-estado">
          <option value="">Todos (sin internas)</option>
          ${Object.entries({
            ...ESTADO_FATHOM_LABEL, interna: 'Internas', por_nombre: 'Alumno asignado por nombre',
            ...Object.fromEntries(Object.entries(CLASIFICACION_LABEL).map(([k, v]) => ['c_' + k, v + ' (clasificada)']))
          })
            .map(([k, v]) => `<option value="${k}"${filtro.estado === k ? ' selected' : ''}>${esc(v)}</option>`).join('')}
        </select></label>
        <label>Desde <input type="date" id="fa-f-desde" value="${esc(filtro.desde)}"></label>
        <label>Hasta <input type="date" id="fa-f-hasta" value="${esc(filtro.hasta)}"></label>
        ${filtro.estado || filtro.desde || filtro.hasta ? '<button type="button" class="btn btn-sm" id="fa-f-limpiar">Limpiar filtros</button>' : ''}
      </div>
      <div class="card">${lista.length ? `<div class="table-wrap"><table class="tabla tabla-cards">
          <thead><tr><th>Fecha</th><th>Con quién</th><th>Llamada</th><th>Estado</th><th></th></tr></thead>
          <tbody>${lista.map(l => filaLlamada(l, puedeAsignar, alumnos)).join('')}</tbody></table></div>
          <div class="hint">${esc(plural(lista.length, 'llamada'))}${total !== lista.length ? ` de ${total}` : ''}.
            ${!filtro.estado && nInternas ? `${esc(plural(nInternas, 'interna oculta', 'internas ocultas'))}: filtrá por «Internas» para verlas.` : ''}</div>`
        : `<div class="muted-empty">${total
            ? 'Ninguna llamada coincide con los filtros.'
            : `Todavía no hay llamadas${act ? ' de ' + esc(act.nombre) : ''} para mostrar.`}</div>`}</div>`;
    propuestas.pintar(el.querySelector('#fa-prop-box'));
  }

  function modalAsignar(l) {
    abrirModal({
      titulo: 'Asignar a alumno',
      cuerpo: `<p class="hint">${esc(fmtFecha(l.fecha))} · ${esc(l.titulo || 'Sin título')}</p>
        <div class="form-row"><label for="fa-alumno">Alumno *</label><div id="fa-alumno-box"></div></div>
        <div class="hint">${yo.rol === 'cliente' ? 'Solo aparecen alumnos de tu programa.' : 'Solo aparecen alumnos de los programas habilitados para Fathom.'}</div>
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
      guardar(async () => avisarResultado('Llamada asignada.', await asignarLlamada(l.id, a.id)),
        { ok: '', luego: cargar });
    };
  }

  /* Corregir: pasar la llamada a otro alumno o devolverla a pendiente. Los mails de la llamada se
     mueven con ella (los aprendidos del alumno anterior se deshacen). La base frena si ya tiene
     accionables hechos o cargados a mano. */
  function modalCorregir(l) {
    abrirModal({
      titulo: 'Corregir alumno de la llamada',
      cuerpo: `<p class="hint">${esc(fmtFecha(l.fecha))} · ${esc(l.titulo || 'Sin título')}<br>
          Hoy figura de: <strong>${esc(l.alumno_nombre || 'Alumno')}</strong></p>
        <div class="form-row"><label for="fc-alumno">Pasar a *</label><div id="fc-alumno-box"></div></div>
        <label class="check-row"><input type="checkbox" id="fc-pendiente"> No es de ningún alumno: volver a pendiente
          (la sincronización no la vuelve a asignar sola)</label>
        <div id="fc-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="fc-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="fc-ok">Corregir</button>`
    });
    const sel = montarSelectorAlumno(document.getElementById('fc-alumno-box'), alumnos, { id: 'fc-alumno' });
    sel.foco();
    document.getElementById('fc-cancelar').onclick = cerrarModal;
    document.getElementById('fc-ok').onclick = () => {
      const aPendiente = document.getElementById('fc-pendiente').checked;
      const a = sel.cliente();
      if (!aPendiente && !a) { document.getElementById('fc-error').textContent = 'Elegí un alumno o marcá "volver a pendiente".'; return; }
      cerrarModal();
      guardar(async () => avisarResultado('Llamada corregida.', await corregirLlamada(l.id, aPendiente ? null : a.id)),
        { ok: '', luego: cargar });
    };
  }

  async function cargar() {
    try {
      const [ls, cs, al] = await Promise.all([traerLlamadasFathom(), traerConsultores(), alumnosAsignables(), propuestas.cargar()]);
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
    const bC = ev.target.closest('[data-fa-corregir]');
    if (bC) {
      const l = llamadas.find(x => x.id === bC.dataset.faCorregir);
      if (l) modalCorregir(l);
      return;
    }
    const bOk = ev.target.closest('[data-fa-confirmar]');
    if (bOk) {
      await guardar(async () => avisarResultado('Confirmada: los mails y nombres de la llamada quedan como del alumno.',
        await confirmarLlamada(bOk.dataset.faConfirmar)), { ok: '', luego: cargar, control: bOk });
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
