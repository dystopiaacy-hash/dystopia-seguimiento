/* Pestaña "Dudas frecuentes" (#/p/:programa/dudas, 106).
   Lista de dudas del programa con respuesta sugerida (y link a un recurso o SOP), origen y
   menciones (cada una guarda alumno y fecha). Orden: cantidad de alumnos DISTINTOS que la
   preguntaron; con "Nueva esta semana" y racha ("3 semanas seguidas").
   Alta rápida de mención: arriba (elige una duda existente con buscador o crea una nueva) y por
   fila. Unir dos dudas duplicadas y borrar: solo fundador (la base lo exige).
   Las menciones las carga una persona, el jefe en tanda con cs_duda_registrar, o salen de las
   "Preguntas detectadas en llamadas" de arriba (134: reglas sobre las transcripciones de Fathom,
   sin IA; dudas-candidatas.js). Sin la 106 avisa que falta la migración; sin la 134 no hay bloque. */
import { esc, fmtFecha, hoyAR, plural, abrirModal, cerrarModal, confirmar, toast, urlSegura } from '../ui.js';
import { esFundador, puedeEditarPrograma } from '../sesion.js';
import { traerClientes, mensajeError, borrarFila } from '../datos.js';
import {
  traerDudas, traerMenciones, registrarMencion, guardarDuda, unirDudas, ORIGEN_DUDA_LABEL
} from '../datos-dudas.js';
import { mensajeCs } from '../datos-faltante.js';
import { coincide } from '../normalizar.js';
import { guardar, opcionesHtml } from './comunes.js';
import { tarjetaError } from './programa.js';
import { montarSelectorAlumno } from './alumno-selector.js';
import { montarSelectorDudas } from './duda-selector.js';
import { montarCandidatas } from './dudas-candidatas.js';
import { montarPropuestasIa } from './dudas-ia.js';   // 139 (IA)

const ORIGENES = Object.entries(ORIGEN_DUDA_LABEL);

function chips(d) {
  return `${d.nueva_semana ? '<span class="duda-tag duda-tag-nueva">Nueva esta semana</span>' : ''}
    ${d.racha_semanas >= 2 ? `<span class="duda-tag duda-tag-racha">${esc(plural(d.racha_semanas, 'semana seguida', 'semanas seguidas'))}</span>` : ''}`;
}

function detalleMenciones(d, menciones, nombres, programaId) {
  const m = menciones.filter(x => x.duda_id === d.id);
  if (!m.length) return '';
  return `<details class="duda-det"><summary>${esc(plural(m.length, 'mención', 'menciones'))}</summary>
    <ul>${m.map(x => `<li><a href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(x.cliente_id)}">${esc(nombres.get(x.cliente_id) || 'Alumno')}</a>
      · ${esc(fmtFecha(x.fecha))} · ${esc(ORIGEN_DUDA_LABEL[x.origen] || x.origen)}</li>`).join('')}</ul></details>`;
}

function filaDuda(d, menciones, nombres, programaId, editar, fundador) {
  const url = d.recurso_url ? urlSegura(d.recurso_url) : '';
  return `<tr>
      <td data-label="Duda">
        <div class="duda-texto">${esc(d.texto)}</div>
        <div class="duda-tags">${chips(d)}</div>
        ${d.respuesta ? `<div class="duda-resp"><em>Respuesta sugerida:</em> ${esc(d.respuesta)}</div>` : ''}
        ${url ? `<div class="duda-resp"><a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(d.recurso_titulo || url)}</a></div>` : ''}
        ${detalleMenciones(d, menciones, nombres, programaId)}
      </td>
      <td data-label="Alumnos" class="num"><strong>${esc(d.alumnos)}</strong></td>
      <td data-label="Menciones" class="num">${esc(d.menciones)}</td>
      <td data-label="Última">${d.ultima_mencion ? esc(fmtFecha(d.ultima_mencion)) : '—'}</td>
      <td data-label="Origen">${esc(ORIGEN_DUDA_LABEL[d.origen] || d.origen)}</td>
      <td data-label="Acciones"><span class="ll-item-acc">
        ${editar ? `<button type="button" class="btn-icono" data-du-mencionar="${esc(d.id)}">Mencionar</button>
          <button type="button" class="btn-icono" data-du-editar="${esc(d.id)}">Editar</button>` : ''}
        ${fundador ? `<button type="button" class="btn-icono" data-du-unir="${esc(d.id)}">Unir con…</button>
          <button type="button" class="btn-icono btn-icono-danger" data-du-borrar="${esc(d.id)}">Borrar</button>` : ''}
      </span></td>
    </tr>`;
}

export function vistaDudas(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let dudas = [], menciones = [], clientes = [], nombres = new Map();
  const filtro = { q: '', nuevas: false };
  let alta = null;   // selectores del formulario de arriba
  const filtrosCand = { estado: 'pendiente', desde: '', hasta: '', consultor: '', soloAlta: true };   // persisten entre repintados
  const filtrosIa = { soloRepetidas: true };
  const editar = () => puedeEditarPrograma(programaId);

  function visibles() {
    return dudas.filter(d => (!filtro.nuevas || d.nueva_semana) && coincide(d.texto, filtro.q));
  }

  function pintarLista() {
    const cont = el.querySelector('#du-lista');
    if (!cont) return;
    const v = visibles();
    cont.innerHTML = !v.length
      ? `<div class="card empty-state"><div class="big">${dudas.length ? 'Ninguna duda coincide' : 'Todavía no hay dudas cargadas'}</div>
          <div class="small">${dudas.length ? 'Probá con otro texto.' : 'Registrá la primera mención con el formulario de arriba.'}</div></div>`
      : `<div class="card table-card"><table class="data-table"><thead><tr>
          <th>Duda</th><th class="num">Alumnos</th><th class="num">Menciones</th><th>Última</th><th>Origen</th><th></th>
        </tr></thead><tbody>${v.map(d => filaDuda(d, menciones, nombres, programaId, editar(), esFundador())).join('')}</tbody></table></div>
        <div class="table-foot">${esc(plural(v.length, 'duda'))}</div>`;
  }

  function pintar() {
    el.innerHTML = `
      <div id="du-ia"></div>
      <div id="du-cand"></div>
      ${editar() ? `<div class="section-title">Registrar una mención<span class="line"></span></div>
      <div class="card duda-alta">
        <div class="form-row"><label for="du-duda">Duda</label><div id="du-duda-box"></div></div>
        <div class="form-grid3">
          <div class="form-row"><label for="du-alumno">Alumno que la preguntó</label><div id="du-alumno-box"></div></div>
          <div class="form-row"><label for="du-fecha">Fecha</label>
            <input type="date" id="du-fecha" value="${esc(hoyAR())}" max="${esc(hoyAR())}"></div>
          <div class="form-row"><label for="du-origen">Origen</label>
            <select id="du-origen">${opcionesHtml(ORIGENES, 'discord')}</select></div>
        </div>
        <div id="du-error" class="login-error"></div>
        <button type="button" class="btn btn-accent" id="du-registrar">Registrar mención</button>
      </div>` : ''}
      <div class="section-title">Dudas frecuentes<span class="line"></span></div>
      <div class="filter-row">
        <input type="search" id="du-q" class="search-input" placeholder="Buscar una duda…" value="${esc(filtro.q)}" aria-label="Buscar una duda">
        <label class="check-row check-inline"><input type="checkbox" id="du-nuevas"${filtro.nuevas ? ' checked' : ''}> Nuevas esta semana</label>
      </div>
      <div id="du-lista"></div>`;
    if (editar()) {
      alta = {
        duda: montarSelectorDudas(el.querySelector('#du-duda-box'), dudas, { id: 'du-duda' }),
        alumno: montarSelectorAlumno(el.querySelector('#du-alumno-box'), clientes, { id: 'du-alumno' })
      };
    }
    pintarLista();
    montarPropuestasIa(el.querySelector('#du-ia'), {
      programaId, filtros: filtrosIa, clientes: () => clientes, recargar: cargar
    }).catch(e => console.error('dudas ia', e));
    montarCandidatas(el.querySelector('#du-cand'), {
      programaId, filtros: filtrosCand, dudas: () => dudas, clientes: () => clientes, recargar: cargar
    }).catch(e => console.error('dudas candidatas', e));
  }

  async function cargar() {
    const [d, m, c] = await Promise.all([traerDudas(programaId), traerMenciones(programaId), traerClientes(programaId)]);
    if (!vigente()) return;
    if (d === undefined || m === undefined) {
      el.innerHTML = tarjetaError('Falta correr la migración 106', 'Esta pestaña se activa cuando la migración 106 está corrida.');
      return;
    }
    dudas = d;
    menciones = m;
    clientes = c;
    nombres = new Map(c.map(x => [x.id, x.nombre]));
    pintar();
  }

  /* Una mención sobre una duda ya elegida (botón "Mencionar" de la fila). */
  function modalMencionar(d) {
    abrirModal({
      titulo: 'Nueva mención',
      cuerpo: `<p class="hint">${esc(d.texto)}</p>
        <div class="form-row"><label for="mm-alumno">Alumno *</label><div id="mm-alumno-box"></div></div>
        <div class="form-grid2">
          <div class="form-row"><label for="mm-fecha">Fecha</label>
            <input type="date" id="mm-fecha" value="${esc(hoyAR())}" max="${esc(hoyAR())}"></div>
          <div class="form-row"><label for="mm-origen">Origen</label>
            <select id="mm-origen">${opcionesHtml(ORIGENES, 'discord')}</select></div>
        </div>
        <div id="mm-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="mm-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="mm-ok">Registrar</button>`
    });
    const sel = montarSelectorAlumno(document.getElementById('mm-alumno-box'), clientes, { id: 'mm-alumno' });
    sel.foco();
    document.getElementById('mm-cancelar').onclick = cerrarModal;
    document.getElementById('mm-ok').onclick = () => {
      const a = sel.cliente();
      const err = t => { document.getElementById('mm-error').textContent = t; };
      if (!a) return err('Elegí un alumno de la lista.');
      const fecha = document.getElementById('mm-fecha').value;
      if (!fecha || fecha > hoyAR()) return err('La fecha es obligatoria y no puede ser futura.');
      const origen = document.getElementById('mm-origen').value;
      cerrarModal();
      guardar(() => registrarMencion(programaId, { dudaId: d.id, clienteId: a.id, fecha, origen }),
        { ok: 'Mención registrada.', luego: () => cargar() });
    };
  }

  function modalEditar(d) {
    abrirModal({
      titulo: 'Editar duda',
      cuerpo: `
        <div class="form-row"><label for="de-texto">Duda *</label>
          <input type="text" id="de-texto" maxlength="300" autocomplete="off" value="${esc(d.texto)}"></div>
        <div class="form-row"><label for="de-resp">Respuesta sugerida</label>
          <textarea id="de-resp" rows="4" maxlength="2000">${esc(d.respuesta || '')}</textarea></div>
        <div class="form-grid2">
          <div class="form-row"><label for="de-titulo">Título del recurso o SOP</label>
            <input type="text" id="de-titulo" maxlength="200" autocomplete="off" value="${esc(d.recurso_titulo || '')}"></div>
          <div class="form-row"><label for="de-url">Link del recurso o SOP</label>
            <input type="url" id="de-url" maxlength="1000" autocomplete="off" value="${esc(d.recurso_url || '')}" placeholder="https://…"></div>
        </div>
        <div id="de-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="de-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="de-ok">Guardar</button>`
    });
    document.getElementById('de-cancelar').onclick = cerrarModal;
    document.getElementById('de-ok').onclick = () => {
      const err = t => { document.getElementById('de-error').textContent = t; };
      const datos = {
        texto: document.getElementById('de-texto').value, respuesta: document.getElementById('de-resp').value,
        recurso_titulo: document.getElementById('de-titulo').value, recurso_url: document.getElementById('de-url').value
      };
      if (!datos.texto.trim()) return err('El texto de la duda es obligatorio.');
      if (datos.recurso_url.trim() && !urlSegura(datos.recurso_url.trim())) return err('El link tiene que empezar con http:// o https://.');
      cerrarModal();
      guardar(() => guardarDuda(d.id, datos), { luego: () => cargar() });
    };
  }

  /* Unir: la duda elegida (origen) se funde en otra (destino). Solo fundador. */
  function modalUnir(origen) {
    abrirModal({
      titulo: 'Unir dudas',
      cuerpo: `<p class="hint">Se junta «${esc(origen.texto)}» con la duda que elijas: sus menciones pasan a esa y esta se borra.</p>
        <div class="form-row"><label for="un-destino">Unir con *</label><div id="un-destino-box"></div></div>
        <div id="un-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="un-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="un-ok">Unir</button>`
    });
    const sel = montarSelectorDudas(document.getElementById('un-destino-box'),
      dudas.filter(d => d.id !== origen.id), { id: 'un-destino', placeholder: 'Buscar la duda que queda…' });
    sel.foco();
    document.getElementById('un-cancelar').onclick = cerrarModal;
    document.getElementById('un-ok').onclick = () => {
      const [v] = sel.valores();
      if (!v || !v.duda_id) { document.getElementById('un-error').textContent = 'Elegí una duda de la lista (no se puede crear una nueva).'; return; }
      cerrarModal();
      guardar(() => unirDudas(origen.id, v.duda_id), { ok: 'Dudas unidas.', luego: () => cargar() });
    };
  }

  el.addEventListener('input', ev => {
    if (ev.target.id !== 'du-q') return;
    filtro.q = ev.target.value;
    pintarLista();
  });
  el.addEventListener('change', ev => {
    if (ev.target.id !== 'du-nuevas') return;
    filtro.nuevas = ev.target.checked;
    pintarLista();
  });

  el.addEventListener('click', async ev => {
    const por = id => dudas.find(d => d.id === id);
    const b = sel => ev.target.closest(sel);

    if (b('#du-registrar')) {
      if (!editar() || !alta) return;
      const err = t => { el.querySelector('#du-error').textContent = t; };
      const [v] = alta.duda.valores();
      const a = alta.alumno.cliente();
      const fecha = el.querySelector('#du-fecha').value;
      if (!v) return err('Elegí una duda o escribí una nueva.');
      if (!a) return err('Elegí un alumno de la lista.');
      if (!fecha || fecha > hoyAR()) return err('La fecha es obligatoria y no puede ser futura.');
      err('');
      const origen = el.querySelector('#du-origen').value;
      const r = await guardar(() => registrarMencion(programaId,
        { dudaId: v.duda_id || null, texto: v.texto, clienteId: a.id, fecha, origen }),
      { ok: v.duda_id ? 'Mención registrada.' : 'Duda creada y mención registrada.', control: b('#du-registrar') });
      if (r !== null) await cargar();
      return;
    }
    const m = b('[data-du-mencionar]');
    if (m) { const d = por(m.dataset.duMencionar); if (d && editar()) modalMencionar(d); return; }
    const e = b('[data-du-editar]');
    if (e) { const d = por(e.dataset.duEditar); if (d && editar()) modalEditar(d); return; }
    const u = b('[data-du-unir]');
    if (u) { const d = por(u.dataset.duUnir); if (d && esFundador()) modalUnir(d); return; }
    const x = b('[data-du-borrar]');
    if (x) {
      const d = por(x.dataset.duBorrar);
      if (!d || !esFundador()) return;
      const ok = await confirmar({
        titulo: 'Borrar duda', texto: `Se borra «${d.texto}».`,
        detalle: `También se borran sus ${plural(d.menciones, 'mención', 'menciones')}. No se puede deshacer.`, ok: 'Borrar'
      });
      if (ok) {
        try {
          await borrarFila('cs_dudas', d.id);
          toast('Duda borrada.');
        } catch (err) {
          toast(mensajeCs(err, mensajeError(err)), 'error');
        }
        await cargar();
      }
    }
  });

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las dudas', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('dudas', e)) };
}
