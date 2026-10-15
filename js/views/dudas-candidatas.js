/* "Preguntas detectadas en llamadas" (134), arriba de la pestaña Dudas frecuentes.
   Candidatas = oraciones del ALUMNO en llamadas de Fathom que parecen preguntas (reglas, sin IA).
   Cada una se agrega a una duda existente (suma una mención con alumno y fecha), da lugar a una
   duda nueva (texto editable) o se descarta. Sugiere dudas parecidas por palabras compartidas.
   Ver: todo el que ve el programa. Gestionar: fundador, cliente del programa o edición.
   Reprocesar: solo fundador. Sin la 134 el bloque no se muestra. */
import { esc, fmtFecha, plural, abrirModal, cerrarModal, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { mensajeCs } from '../datos-faltante.js';
import {
  traerCandidatas, estadoCandidatas, nombresConsultores, agregarCandidata, crearDesdeCandidata,
  descartarCandidatas, reabrirCandidata, reprocesarDudas, puedeGestionarDudas
} from '../datos-dudas-candidatas.js';
import { parecidas } from '../dudas-similitud.js';
import { montarSelectorDudas } from './duda-selector.js';
import { opcionesHtml } from './comunes.js';

const MAX_FILAS = 100;
const ESTADOS = [['pendiente', 'Pendientes'], ['agregada', 'Agregadas'], ['descartada', 'Descartadas'], ['', 'Todas']];

/* ctx: { programaId, filtros, dudas(), clientes(), recargar() } — filtros persiste entre repintados. */
export async function montarCandidatas(cont, ctx) {
  const { programaId, filtros } = ctx;
  const gestionar = puedeGestionarDudas(programaId);
  let filas, info, consultores;
  const sel = new Set();
  let verTodas = false;

  const nombreAlumno = id => (ctx.clientes().find(c => c.id === id) || {}).nombre || 'Alumno';
  const nombreConsultor = id => (id && consultores.get(id)) || id || '—';
  const textoDuda = id => (ctx.dudas().find(d => d.id === id) || {}).texto || '';

  async function cargar() {
    const [f, i, c] = await Promise.all([traerCandidatas(programaId, filtros), estadoCandidatas(programaId), nombresConsultores()]);
    if (!cont.isConnected) return false;
    if (f === undefined) { cont.innerHTML = ''; return false; }
    filas = f; info = i; consultores = c;
    return true;
  }

  function opcionesConsultor() {
    const ids = [...new Set([...consultores.keys(), ...filas.map(f => f.consultor).filter(Boolean)])];
    return [['', 'Todos los consultores'], ...ids.map(id => [id, nombreConsultor(id)])];
  }

  function filaHtml(f) {
    const sug = f.estado === 'pendiente' ? parecidas(f.texto, ctx.dudas(), { max: 1 })[0] : null;
    const alumno = `<a href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(f.cliente_id)}">${esc(nombreAlumno(f.cliente_id))}</a>`;
    let acciones = '';
    if (gestionar && f.estado === 'pendiente') {
      acciones = `<button type="button" class="btn-icono" data-cd-agregar="${esc(f.id)}">Agregar a una duda</button>
        <button type="button" class="btn-icono" data-cd-crear="${esc(f.id)}">Crear duda nueva</button>
        <button type="button" class="btn-icono btn-icono-danger" data-cd-descartar="${esc(f.id)}">Descartar</button>`;
    } else if (gestionar && f.estado === 'descartada') {
      acciones = `<button type="button" class="btn-icono" data-cd-reabrir="${esc(f.id)}">Reabrir</button>`;
    } else if (f.estado === 'agregada') {
      acciones = `<span class="hint">Agregada${f.duda_id ? ` a «${esc(textoDuda(f.duda_id) || 'una duda')}»` : ''}</span>`;
    }
    return `<tr>
      ${gestionar ? `<td data-label=""><input type="checkbox" data-cd-sel="${esc(f.id)}" aria-label="Elegir"${sel.has(f.id) ? ' checked' : ''}${f.estado === 'pendiente' ? '' : ' disabled'}></td>` : ''}
      <td data-label="Fecha">${esc(fmtFecha(f.fecha))}</td>
      <td data-label="Alumno">${alumno}</td>
      <td data-label="Consultor">${esc(nombreConsultor(f.consultor))}</td>
      <td data-label="Pregunta"><div class="duda-texto">${esc(f.texto)}</div>
        ${sug ? `<div class="duda-resp">Parecida a: «${esc(sug.duda.texto)}»
          ${gestionar ? `<button type="button" class="btn-icono" data-cd-igual="${esc(f.id)}|${esc(sug.duda.id)}">Agregar a esa</button>` : ''}</div>` : ''}</td>
      <td data-label="Acciones"><span class="ll-item-acc">${acciones}</span></td>
    </tr>`;
  }

  function pintarLista() {
    const caja = cont.querySelector('#cd-lista');
    if (!caja) return;
    if (!filas.length) {
      caja.innerHTML = `<div class="card empty-state"><div class="big">No hay preguntas con estos filtros</div>
        <div class="small">${info && info.llamadas
          ? 'Las llamadas de Fathom con transcripción se leen solas; si cargaste llamadas viejas, el fundador puede apretar «Reprocesar».'
          : 'Todavía no hay llamadas de Fathom con transcripción en este programa.'}</div></div>`;
      return;
    }
    const v = verTodas ? filas : filas.slice(0, MAX_FILAS);
    caja.innerHTML = `<div class="card table-card"><table class="data-table"><thead><tr>
        ${gestionar ? '<th></th>' : ''}<th>Fecha</th><th>Alumno</th><th>Consultor</th><th>Pregunta</th><th></th>
      </tr></thead><tbody>${v.map(filaHtml).join('')}</tbody></table></div>
      <div class="table-foot">${esc(plural(filas.length, 'pregunta'))}${filas.length > v.length
        ? ` · <button type="button" class="btn-icono" id="cd-mas">Ver las ${filas.length}</button>` : ''}
        ${gestionar && filtros.estado === 'pendiente'
          ? ` · <button type="button" class="btn-icono btn-icono-danger" id="cd-desc-sel"${sel.size ? '' : ' disabled'}>Descartar ${esc(plural(sel.size, 'elegida'))}</button>` : ''}</div>`;
  }

  function pintar() {
    const resumen = info
      ? `${plural(info.pendientes, 'pendiente')} · ${plural(info.agregadas, 'agregada')} · ${plural(info.descartadas, 'descartada')}
         · ${plural(info.llamadas, 'llamada leída', 'llamadas leídas')}${info.sin_procesar ? ` (${info.sin_procesar} sin procesar)` : ''}`
      : '';
    cont.innerHTML = `
      <div class="section-title">Preguntas detectadas en llamadas<span class="line"></span></div>
      <p class="hint">Oraciones del alumno que terminan en «?» o empiezan con una palabra de pregunta (cómo, qué, cuándo, dónde, por qué, cuánto, se puede…),
        sacadas de las transcripciones de Fathom. Sin IA: revisalas y agregalas a una duda, creá una nueva o descartalas. ${esc(resumen)}</p>
      <div class="filter-row">
        <select id="cd-estado" aria-label="Estado">${opcionesHtml(ESTADOS, filtros.estado)}</select>
        <span class="flabel">Desde</span><input type="date" id="cd-desde" value="${esc(filtros.desde)}">
        <span class="flabel">Hasta</span><input type="date" id="cd-hasta" value="${esc(filtros.hasta)}">
        <select id="cd-consultor" aria-label="Consultor">${opcionesHtml(opcionesConsultor(), filtros.consultor)}</select>
        ${esFundador() ? '<button type="button" class="btn" id="cd-reprocesar">Reprocesar llamadas</button>' : ''}
        <span class="hint" id="cd-progreso"></span>
      </div>
      <div id="cd-lista"></div>`;
    pintarLista();
  }

  async function refrescar() {
    if (await cargar()) pintar();
  }

  async function ejecutar(fn, ok) {
    try {
      await fn();
      if (ok) toast(ok);
    } catch (e) {
      toast(mensajeCs(e, mensajeError(e)), 'error');
    }
    sel.clear();
    await ctx.recargar();   // repinta dudas (conteos) y esta sección
  }

  /* Duda nueva: texto editable + sugerencias en vivo de dudas parecidas. */
  function modalCrear(f) {
    abrirModal({
      titulo: 'Crear duda nueva',
      cuerpo: `<p class="hint">${esc(nombreAlumno(f.cliente_id))} · ${esc(fmtFecha(f.fecha))}. Podés editar el texto: queda como la duda y esta pregunta suma una mención.</p>
        <div class="form-row"><label for="cn-texto">Duda *</label>
          <input type="text" id="cn-texto" maxlength="300" autocomplete="off" value="${esc(f.texto)}"></div>
        <div id="cn-sug"></div>
        <div id="cn-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="cn-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="cn-ok">Crear duda</button>`
    });
    const input = document.getElementById('cn-texto');
    const caja = document.getElementById('cn-sug');
    const pintarSug = () => {
      const p = parecidas(input.value, ctx.dudas(), { max: 3 });
      caja.innerHTML = p.length
        ? `<p class="hint">Ya hay dudas parecidas. ¿Es la misma?</p>
           ${p.map(x => `<div class="duda-resp">«${esc(x.duda.texto)}» · ${esc(plural(x.duda.alumnos, 'alumno'))}
             <button type="button" class="btn-icono" data-cn-igual="${esc(x.duda.id)}">Agregar a esta</button></div>`).join('')}` : '';
    };
    pintarSug();
    input.addEventListener('input', pintarSug);
    caja.addEventListener('click', ev => {
      const b = ev.target.closest('[data-cn-igual]');
      if (!b) return;
      cerrarModal();
      ejecutar(() => agregarCandidata(f.id, b.dataset.cnIgual), 'Pregunta agregada a la duda.');
    });
    document.getElementById('cn-cancelar').onclick = cerrarModal;
    document.getElementById('cn-ok').onclick = () => {
      const t = input.value.trim();
      if (!t) { document.getElementById('cn-error').textContent = 'El texto de la duda es obligatorio.'; return; }
      cerrarModal();
      ejecutar(async () => {
        const r = await crearDesdeCandidata(f.id, t);
        toast(r && r.nueva ? 'Duda creada y mención registrada.' : 'Ya existía esa duda: se sumó la mención.');
      }, null);
    };
    input.focus();
  }

  /* Agregar a una existente: buscador (solo dudas existentes) + las más parecidas arriba. */
  function modalAgregar(f) {
    const p = parecidas(f.texto, ctx.dudas(), { max: 3 });
    abrirModal({
      titulo: 'Agregar a una duda existente',
      cuerpo: `<p class="hint">«${esc(f.texto)}»<br>${esc(nombreAlumno(f.cliente_id))} · ${esc(fmtFecha(f.fecha))}</p>
        ${p.length ? `<p class="hint">Parecidas:</p>${p.map(x => `<div class="duda-resp">«${esc(x.duda.texto)}»
          <button type="button" class="btn-icono" data-ag-igual="${esc(x.duda.id)}">Agregar a esta</button></div>`).join('')}` : ''}
        <div class="form-row"><label for="ag-duda">Otra duda</label><div id="ag-duda-box"></div></div>
        <div id="ag-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="ag-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="ag-ok">Agregar</button>`
    });
    const buscador = montarSelectorDudas(document.getElementById('ag-duda-box'), ctx.dudas(),
      { id: 'ag-duda', placeholder: 'Buscar una duda existente…' });
    const hecho = id => { cerrarModal(); ejecutar(() => agregarCandidata(f.id, id), 'Pregunta agregada a la duda.'); };
    document.querySelectorAll('[data-ag-igual]').forEach(b => { b.onclick = () => hecho(b.dataset.agIgual); });
    document.getElementById('ag-cancelar').onclick = cerrarModal;
    document.getElementById('ag-ok').onclick = () => {
      const [v] = buscador.valores();
      if (!v || !v.duda_id) { document.getElementById('ag-error').textContent = 'Elegí una duda de la lista (para una nueva, usá «Crear duda nueva»).'; return; }
      hecho(v.duda_id);
    };
  }

  cont.addEventListener('change', async ev => {
    const t = ev.target;
    if (t.id === 'cd-estado') filtros.estado = t.value;
    else if (t.id === 'cd-desde') filtros.desde = t.value;
    else if (t.id === 'cd-hasta') filtros.hasta = t.value;
    else if (t.id === 'cd-consultor') filtros.consultor = t.value;
    else if (t.dataset && t.dataset.cdSel) {
      if (t.checked) sel.add(t.dataset.cdSel); else sel.delete(t.dataset.cdSel);
      pintarLista();
      return;
    } else return;
    sel.clear();
    await refrescar();
  });

  cont.addEventListener('click', async ev => {
    const b = sel => ev.target.closest(sel);
    const por = id => filas.find(f => f.id === id);
    if (b('#cd-mas')) { verTodas = true; pintarLista(); return; }
    if (b('#cd-desc-sel')) {
      if (gestionar && sel.size) await ejecutar(() => descartarCandidatas([...sel]), 'Preguntas descartadas.');
      return;
    }
    if (b('#cd-reprocesar')) {
      if (!esFundador()) return;
      const boton = b('#cd-reprocesar');
      const prog = cont.querySelector('#cd-progreso');
      boton.disabled = true;
      try {
        const r = await reprocesarDudas(programaId, p => {
          prog.textContent = `Procesadas ${p.procesadas} · nuevas ${p.nuevas} · faltan ${p.restantes}`;
        });
        toast(`Reprocesado: ${plural(r.procesadas, 'llamada')}, ${plural(r.nuevas, 'pregunta nueva', 'preguntas nuevas')}.`);
      } catch (e) {
        toast(mensajeCs(e, mensajeError(e)), 'error');
      }
      await ctx.recargar();
      return;
    }
    const a = b('[data-cd-agregar]');
    if (a) { const f = por(a.dataset.cdAgregar); if (f && gestionar) modalAgregar(f); return; }
    const c = b('[data-cd-crear]');
    if (c) { const f = por(c.dataset.cdCrear); if (f && gestionar) modalCrear(f); return; }
    const d = b('[data-cd-descartar]');
    if (d) { if (gestionar) await ejecutar(() => descartarCandidatas([d.dataset.cdDescartar]), 'Pregunta descartada.'); return; }
    const r = b('[data-cd-reabrir]');
    if (r) { if (gestionar) await ejecutar(() => reabrirCandidata(r.dataset.cdReabrir), 'Pregunta reabierta.'); return; }
    const ig = b('[data-cd-igual]');
    if (ig && gestionar) {
      const [cid, did] = ig.dataset.cdIgual.split('|');
      await ejecutar(() => agregarCandidata(cid, did), 'Pregunta agregada a la duda.');
    }
  });

  if (await cargar()) pintar();
}
