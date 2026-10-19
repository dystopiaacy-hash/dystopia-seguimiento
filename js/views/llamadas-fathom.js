/* Pantalla "Llamadas" (#/p/:programa/llamadas, 124): las llamadas grabadas en Fathom, divididas en secciones
   (consultorías semanales, 1 a 1, clases, ventas, internas, sin clasificar: ver llamadas-secciones.js) con filtros
   por programa y consultor. Estados: alumno (asignada a una ficha), pendiente (con invitados
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
import { traerHorarios, traerConsultoriasRegistradas } from '../datos-consultorias.js';
import { SECCIONES, armarItems, extraItem } from './llamadas-secciones.js';

const PAGINA = 100;   // filas por tanda: en celular cada una es una tarjeta

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

function filaLlamada(l, puedeAsignar, alumnos, extra = '') {
  const url = urlSegura(l.grabacion_share_url || l.grabacion_url || '');
  const meta = [TIPO_LLAMADA_LABEL[l.tipo], l.duracion_min ? `${l.duracion_min} min` : ''].filter(Boolean).join(' · ');
  const porNombre = l.estado === 'alumno' && l.asignada_por === 'nombre';
  let acciones = '';
  if (l.estado === 'consultoria') {
    acciones = '';                       // consultoría ya registrada: no se asigna a un alumno
  } else if (l.estado === 'alumno') {
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
  const estadoTxt = l.estado === 'consultoria' ? extra
    : porNombre
    ? `<span class="fa-estado fa-alumno fa-por-nombre">Alumno · por nombre</span>
       <div class="hint">Asignada por coincidencia de nombre: confirmala o corregila.</div>${extra}`
    : tipoNoAlumno
      ? `<span class="fa-estado fa-clasificada">${esc(tipoNoAlumno)}</span><div class="hint">No es de un alumno.</div>${extra}`
      : `<span class="fa-estado fa-${esc(l.estado)}">${esc(ESTADO_FATHOM_LABEL[l.estado] || l.estado)}</span>${extra}`;
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
  let llamadas = [], consultores = [], alumnos = [], horarios = [], registradas = [], items = [];
  let seccion = '', mostrar = PAGINA;
  const filtro = { estado: '', programa: '', consultor: '', desde: '', hasta: '' };
  /* Propuestas de la IA (186): sección propia arriba de la lista; aceptar / corregir recargan todo. */
  const propuestas = crearPropuestas({ llamadas: () => llamadas, alumnos: () => alumnos, alCambiar: () => cargar() });

  const nombreConsultor = id => { const c = consultores.find(x => x.id === id); return c ? c.nombre : id; };
  const nombrePrograma = id => { const p = (yo.programas || []).find(x => x.id === id); return p ? p.nombre : id; };
  /* Todos los filtros menos la sección (así los contadores de cada sección respetan programa, consultor y fechas). */
  const pasa = it => (!filtro.consultor || (it.l.consultor || '') === filtro.consultor)
    && (!filtro.programa || (filtro.programa === '_sin' ? !it.programa : it.programa === filtro.programa))
    && (!filtro.estado || (filtro.estado === 'por_nombre' ? it.l.estado === 'alumno' && it.l.asignada_por === 'nombre'
      : it.l.estado === filtro.estado))
    && (!filtro.desde || it.l.fecha >= filtro.desde)
    && (!filtro.hasta || it.l.fecha <= filtro.hasta);
  const hayFiltro = () => Object.values(filtro).some(Boolean);

  function pintar() {
    const puedeAsignar = esFundador() || llamadas.some(l => l.estado !== 'alumno');
    const filtrados = items.filter(pasa);
    const cuenta = k => filtrados.filter(it => it.seccion === k).length;
    const actual = SECCIONES.find(s => s.key === seccion) || SECCIONES[0];
    const lista = filtrados.filter(it => it.seccion === actual.key);
    const visibles = lista.slice(0, mostrar);
    const tabs = SECCIONES.map(s => `<button type="button" class="tab-btn${s.key === actual.key ? ' active' : ''}" data-fa-sec="${s.key}">
        ${esc(s.label)} <span class="fa-n">${cuenta(s.key)}</span></button>`).join('');
    const progs = [...new Set(items.map(it => it.programa).filter(Boolean))].sort();
    const hayLibres = items.some(it => !it.programa);
    const cons = consultores.length ? consultores.map(c => [c.id, c.nombre + (c.activo ? '' : ' (inactivo)')])
      : [...new Set(items.map(it => it.l.consultor).filter(Boolean))].sort().map(c => [c, c]);
    const opt = (v, t, sel) => `<option value="${esc(v)}"${sel === v ? ' selected' : ''}>${esc(t)}</option>`;
    el.innerHTML = `
      <div id="fa-prop-box" class="pi-seccion"></div>
      <div class="section-title">Llamadas<span class="line"></span></div>
      <div class="hint">Las reuniones grabadas en Fathom, separadas por tipo. Se asignan solas por el mail del invitado
        (principal o extra); si no coincide, por nombre o alias (queda «por nombre» para que la confirmes o corrijas). Al
        asignar o confirmar a mano, los mails y nombres de la llamada quedan como del alumno y la próxima se asigna sola.
        Los contadores respetan los filtros de abajo.</div>
      ${yo.rol === 'cliente' ? `<div class="hint">Ves solo las llamadas de tu programa: las de tus alumnos y las pendientes
        que tienen a un alumno tuyo como posible o propuesto. El resto lo ven el fundador y el consultor.</div>` : ''}
      <nav class="tabs fa-secciones" aria-label="Tipo de llamada">${tabs}</nav>
      <div class="fa-filtros">
        <label>Programa <select id="fa-f-programa">
          ${opt('', 'Todos', filtro.programa)}${progs.map(p => opt(p, nombrePrograma(p), filtro.programa)).join('')}
          ${hayLibres ? opt('_sin', 'Sin programa claro', filtro.programa) : ''}
        </select></label>
        <label>Consultor <select id="fa-f-consultor">
          ${opt('', 'Todos', filtro.consultor)}${cons.map(([id, n]) => opt(id, n, filtro.consultor)).join('')}
        </select></label>
        <label>Estado <select id="fa-f-estado">
          ${opt('', 'Todos', filtro.estado)}${opt('pendiente', 'Pendiente', filtro.estado)}
          ${opt('por_nombre', 'Alumno asignado por nombre', filtro.estado)}${opt('no_alumno', 'No es alumno', filtro.estado)}
        </select></label>
        <label>Desde <input type="date" id="fa-f-desde" value="${esc(filtro.desde)}"></label>
        <label>Hasta <input type="date" id="fa-f-hasta" value="${esc(filtro.hasta)}"></label>
        ${hayFiltro() ? '<button type="button" class="btn btn-sm" id="fa-f-limpiar">Limpiar filtros</button>' : ''}
      </div>
      <div class="hint">${esc(actual.ayuda)}</div>
      <div class="card fa-tabla">${visibles.length ? `<div class="table-wrap"><table class="tabla tabla-cards">
          <thead><tr><th>Fecha</th><th>Con quién</th><th>Llamada</th><th>Estado</th><th></th></tr></thead>
          <tbody>${visibles.map(it => filaLlamada(it.l, puedeAsignar, alumnos, extraItem(it, nombreConsultor))).join('')}</tbody></table></div>
          <div class="hint">${esc(plural(lista.length, 'llamada'))}${visibles.length < lista.length ? `, mostrando ${visibles.length}.
            <button type="button" class="btn btn-sm" id="fa-mas">Mostrar más</button>` : '.'}</div>`
        : `<div class="muted-empty">${items.length
            ? (hayFiltro() ? 'Ninguna llamada de esta sección coincide con los filtros.' : 'No hay llamadas en esta sección.')
            : 'Todavía no hay llamadas para mostrar.'}</div>`}</div>`;
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
      /* Horarios y consultorías registradas (157): si faltan o fallan, la pantalla sigue sin esa sección. */
      const opcional = async f => { try { return await f(); } catch { return undefined; } };
      const [ls, cs, al, hs, regs] = await Promise.all([traerLlamadasFathom(), traerConsultores(), alumnosAsignables(),
        opcional(traerHorarios), opcional(traerConsultoriasRegistradas), propuestas.cargar()]);
      if (!vigente()) return;
      if (ls === undefined || cs === undefined) {
        el.innerHTML = tarjetaError('Falta correr la migración 124', 'Esta pantalla se activa cuando la migración 124 está corrida.');
        return;
      }
      llamadas = ls;
      alumnos = al;
      horarios = hs || [];
      registradas = regs || [];
      /* Consultores activos, y los inactivos solo si tienen llamadas visibles. */
      consultores = cs.filter(c => c.activo || llamadas.some(l => l.consultor === c.id));
      if (filtro.consultor && !consultores.some(c => c.id === filtro.consultor)) filtro.consultor = '';
      items = armarItems({ llamadas, registradas, horarios, props: propuestas.lista(), alumnos });
      /* Primera vez: abre la primera sección que tenga algo. */
      if (!seccion) seccion = (SECCIONES.find(s => items.some(it => it.seccion === s.key)) || SECCIONES[0]).key;
      pintar();
    } catch (e) {
      if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las llamadas', mensajeError(e));
    }
  }

  el.addEventListener('change', ev => {
    const t = ev.target;
    if (t.id === 'fa-f-estado') filtro.estado = t.value;
    else if (t.id === 'fa-f-programa') filtro.programa = t.value;
    else if (t.id === 'fa-f-consultor') filtro.consultor = t.value;
    else if (t.id === 'fa-f-desde') filtro.desde = t.value;
    else if (t.id === 'fa-f-hasta') filtro.hasta = t.value;
    else return;
    mostrar = PAGINA;
    pintar();
  });

  el.addEventListener('click', async ev => {
    const bT = ev.target.closest('[data-fa-sec]');
    if (bT) { seccion = bT.dataset.faSec; mostrar = PAGINA; pintar(); return; }
    if (ev.target.closest('#fa-mas')) { mostrar += PAGINA; pintar(); return; }
    if (ev.target.closest('#fa-f-limpiar')) {
      filtro.estado = filtro.programa = filtro.consultor = filtro.desde = filtro.hasta = ''; mostrar = PAGINA; pintar(); return;
    }
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
