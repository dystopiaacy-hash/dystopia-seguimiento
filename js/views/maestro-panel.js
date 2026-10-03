/* Maestro — panel lateral "Columnas" (071). Solo fundador: lo abre maestro.js.
   Ordenar (arrastrar o flechas), renombrar en el lugar, mostrar u ocultar, y en
   las columnas nuevas: opciones, archivar y recuperar. "+ Nueva columna" abajo.
   Cada cambio es una llamada a la base; al volver se recarga la config, se
   repinta la planilla (sin perder el scroll) y se repinta el panel. Los cambios
   van en cola: uno a la vez, en el orden en que se pidieron. */
import { esc, toast } from '../ui.js';
import {
  TIPO_COLUMNA_LABEL, guardarColumna, crearColumna, ordenarColumnas, archivarColumna,
  renombrarOpcion, errorColumnas
} from '../datos-columnas.js';
import { opcionesHtml, repintarConservandoFoco } from './comunes.js';

const OJO = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>';
const OJO_NO = OJO.replace('</svg>', '<path d="M4 4l16 16"/></svg>');

/* Lo que se manda como etiqueta: en las del sistema, null = nombre original. */
const etiquetaDe = c => (c.sistema ? (c.lab === c.original ? null : c.lab) : c.lab);
const lineas = t => Array.from(new Set(String(t || '').split('\n').map(s => s.trim()).filter(Boolean)));

function editorOpciones(c) {
  const filas = c.opciones.map((o, i) => `
    <li class="mc-op"><input type="text" class="mc-input" id="mc-o-${esc(c.k)}-${i}" maxlength="60" value="${esc(o)}"
        data-mc-opcion="${esc(o)}" aria-label="${esc('Opción ' + o)}">
      <button type="button" class="btn btn-sm btn-ghost" data-mc="op-quitar" data-opcion="${esc(o)}"
        title="Quitar la opción" aria-label="${esc('Quitar la opción ' + o)}">✕</button></li>`).join('');
  return `<div class="mc-opciones">
      <ul>${filas || '<li class="mc-vacio">Sin opciones todavía.</li>'}</ul>
      <div class="mc-op"><input type="text" class="mc-input" id="mc-oa-${esc(c.k)}" maxlength="60" placeholder="Nueva opción"
          data-mc-agregar aria-label="Nueva opción">
        <button type="button" class="btn btn-sm" data-mc="op-agregar">Agregar</button></div>
      <div class="mc-nota">Renombrar una opción cambia también los clientes que ya la tienen.</div>
    </div>`;
}

function itemHtml(c, i, total, abierta) {
  const nombre = c.k === 'nombre';
  const extra = c.sistema ? '' : `
    <div class="mc-extra"><span class="mc-tipo">${esc(TIPO_COLUMNA_LABEL[c.tipo] || c.tipo)}</span>
      ${c.tipo === 'opcion' ? `<button type="button" class="btn btn-sm btn-ghost" data-mc="opciones" aria-expanded="${abierta}">
        Opciones (${c.opciones.length})</button>` : ''}
      <button type="button" class="btn btn-sm btn-ghost" data-mc="archivar">Archivar</button></div>
    ${abierta ? editorOpciones(c) : ''}`;
  return `<li class="mc-item${c.visible ? '' : ' mc-oculta'}" data-clave="${esc(c.k)}">
      <div class="mc-fila">
        <span class="mc-asa" draggable="true" title="Arrastrar para mover" aria-hidden="true">⠿</span>
        <input type="text" class="mc-input mc-nombre" id="mc-n-${esc(c.k)}" maxlength="60" value="${esc(c.lab)}"
          placeholder="${esc(c.sistema ? c.original : 'Nombre')}" data-mc-nombre aria-label="${esc('Nombre de la columna ' + c.lab)}">
        <button type="button" class="btn btn-sm btn-ghost mc-ic" data-mc="subir" ${i === 0 ? 'disabled' : ''}
          title="Subir" aria-label="${esc('Subir ' + c.lab)}">↑</button>
        <button type="button" class="btn btn-sm btn-ghost mc-ic" data-mc="bajar" ${i === total - 1 ? 'disabled' : ''}
          title="Bajar" aria-label="${esc('Bajar ' + c.lab)}">↓</button>
        ${nombre ? '<span class="mc-ic mc-sin-ojo" title="Cliente siempre se muestra"></span>'
          : `<button type="button" class="btn btn-sm btn-ghost mc-ic" data-mc="ojo" aria-pressed="${c.visible}"
              title="${c.visible ? 'Ocultar' : 'Mostrar'}" aria-label="${esc((c.visible ? 'Ocultar ' : 'Mostrar ') + c.lab)}">${c.visible ? OJO : OJO_NO}</button>`}
      </div>${extra}</li>`;
}

function cuerpoHtml({ todas, archivadas }, ui) {
  const arch = archivadas.map(c => `
    <li class="mc-fila" data-clave="${esc(c.k)}"><span class="mc-arch-nombre">${esc(c.lab)}</span>
      <span class="mc-tipo">${esc(TIPO_COLUMNA_LABEL[c.tipo] || c.tipo)}</span>
      <button type="button" class="btn btn-sm" data-mc="recuperar">Recuperar</button></li>`).join('');
  const n = ui.nueva;
  return `
    <p class="mc-nota">Arrastrá o usá las flechas para ordenar. Vale para todo el equipo de este programa.
      En las del sistema, dejar el nombre vacío vuelve al original.</p>
    <ul class="mc-lista">${todas.map((c, i) => itemHtml(c, i, todas.length, ui.opciones === c.k)).join('')}</ul>
    ${archivadas.length ? `<details class="mc-archivadas"${ui.archivadas ? ' open' : ''}>
      <summary>Archivadas (${archivadas.length})</summary><ul>${arch}</ul></details>` : ''}
    <div class="mc-nueva">
      ${n ? `<div class="form-row"><label for="mc-nv-nombre">Nombre</label>
          <input type="text" id="mc-nv-nombre" maxlength="60" value="${esc(n.nombre)}" data-mc-nueva="nombre"></div>
        <div class="form-row"><label for="mc-nv-tipo">Tipo</label>
          <select id="mc-nv-tipo" data-mc-nueva="tipo">${opcionesHtml(Object.entries(TIPO_COLUMNA_LABEL), n.tipo)}</select></div>
        ${n.tipo === 'opcion' ? `<div class="form-row"><label for="mc-nv-ops">Opciones (una por línea)</label>
          <textarea id="mc-nv-ops" rows="4" data-mc-nueva="opciones">${esc(n.opciones)}</textarea></div>` : ''}
        <div class="mc-acciones"><button type="button" class="btn" data-mc="nueva-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" data-mc="crear">Crear columna</button></div>`
      : '<button type="button" class="btn" data-mc="nueva">+ Nueva columna</button>'}
    </div>`;
}

/* estado() -> { todas, archivadas } vigente; recargar() vuelve a pedir la config y repinta la planilla. */
export function abrirPanelColumnas({ programaId, estado, recargar, alCerrar = null }) {
  const ui = { opciones: null, archivadas: false, nueva: null };
  const overlay = document.createElement('div');
  overlay.className = 'mc-overlay';
  overlay.innerHTML = `<aside class="mc-panel" role="dialog" aria-modal="true" aria-label="Columnas del Maestro">
      <div class="mc-head"><h2>Columnas</h2>
        <button type="button" class="modal-close" data-mc="cerrar" aria-label="Cerrar">✕</button></div>
      <div class="mc-body"></div></aside>`;
  const body = overlay.querySelector('.mc-body');
  const col = k => estado().todas.find(c => c.k === k);
  const claveDe = nodo => { const li = nodo.closest('[data-clave]'); return li ? li.dataset.clave : ''; };

  function pintar() {
    if (!overlay.isConnected) return;
    const y = body.scrollTop;
    repintarConservandoFoco(body, () => { body.innerHTML = cuerpoHtml(estado(), ui); });
    body.scrollTop = y;
  }

  let cola = Promise.resolve();
  function operar(fn, ok) {
    cola = cola.then(async () => {
      overlay.classList.add('mc-ocupado');
      try {
        await fn();
        if (ok) toast(ok);
      } catch (e) {
        toast(errorColumnas(e), 'error');
      }
      try { await recargar(); } catch (e) { console.error('columnas', e); }
      overlay.classList.remove('mc-ocupado');
      pintar();
    });
    return cola;
  }

  const guardarCol = (c, cambios, ok) => operar(() => guardarColumna(programaId, c.k,
    { etiqueta: etiquetaDe(c), visible: c.visible, ...cambios }), ok);

  function mover(origen, destino, despues) {
    const antes = estado().todas.map(c => c.k);
    const claves = antes.filter(k => k !== origen);
    const i = claves.indexOf(destino);
    if (i < 0 || !antes.includes(origen)) return;
    claves.splice(i + (despues ? 1 : 0), 0, origen);
    if (claves.join() !== antes.join()) operar(() => ordenarColumnas(programaId, claves));
  }

  function cerrar() {
    if (!overlay.isConnected) return;
    overlay.remove();
    document.removeEventListener('keydown', onKey);
    window.removeEventListener('hashchange', cerrar);
    if (alCerrar) alCerrar();
  }
  const onKey = e => { if (e.key === 'Escape') cerrar(); };
  /* El panel cuelga de body: si se cambia de pantalla, se va con ella. */
  window.addEventListener('hashchange', cerrar);

  overlay.addEventListener('mousedown', e => { if (e.target === overlay) cerrar(); });

  overlay.addEventListener('click', ev => {
    const b = ev.target.closest('[data-mc]');
    if (!b) return;
    const accion = b.dataset.mc, k = claveDe(b), c = col(k);
    if (accion === 'cerrar') return cerrar();
    if (accion === 'nueva') { ui.nueva = { nombre: '', tipo: 'texto', opciones: '' }; pintar(); body.querySelector('#mc-nv-nombre').focus(); return; }
    if (accion === 'nueva-cancelar') { ui.nueva = null; pintar(); return; }
    if (accion === 'crear') {
      const nombre = ui.nueva.nombre.trim(), ops = lineas(ui.nueva.opciones);
      if (!nombre) { toast('La columna necesita nombre.', 'error'); body.querySelector('#mc-nv-nombre').focus(); return; }
      if (ui.nueva.tipo === 'opcion' && !ops.length) { toast('Cargá al menos una opción.', 'error'); return; }
      /* El formulario se cierra recién si la base la creó: un error no pierde lo escrito. */
      operar(async () => { await crearColumna(programaId, nombre, ui.nueva.tipo, ops); ui.nueva = null; },
        `Columna "${nombre}" creada.`);
      return;
    }
    if (accion === 'recuperar') { operar(() => archivarColumna(programaId, k, false), 'Columna recuperada.'); return; }
    if (!c) return;
    if (accion === 'subir' || accion === 'bajar') {
      const claves = estado().todas.map(x => x.k), i = claves.indexOf(k), j = i + (accion === 'subir' ? -1 : 1);
      if (j >= 0 && j < claves.length) mover(k, claves[j], accion === 'bajar');
    } else if (accion === 'ojo') {
      guardarCol(c, { visible: !c.visible });
    } else if (accion === 'opciones') {
      ui.opciones = ui.opciones === k ? null : k;
      pintar();
    } else if (accion === 'archivar') {
      ui.archivadas = true;
      operar(() => archivarColumna(programaId, k, true), 'Columna archivada. Los datos quedan guardados: se recupera desde Archivadas.');
    } else if (accion === 'op-quitar') {
      guardarCol(c, { opciones: c.opciones.filter(o => o !== b.dataset.opcion) }, 'Opción quitada.');
    } else if (accion === 'op-agregar') {
      const inp = b.parentElement.querySelector('[data-mc-agregar]'), v = inp.value.trim();
      if (!v) { inp.focus(); return; }
      if (c.opciones.includes(v)) { toast('Esa opción ya está.', 'error'); return; }
      inp.value = '';
      guardarCol(c, { opciones: c.opciones.concat(v) }, 'Opción agregada.');
    }
  });

  overlay.addEventListener('change', ev => {
    const t = ev.target, c = col(claveDe(t));
    if (!c) return;
    const v = t.value.trim();
    if (t.matches('[data-mc-nombre]')) {
      if (!v && !c.sistema) { t.value = c.lab; return; }
      const etiqueta = c.sistema && (!v || v === c.original) ? null : v;
      if ((etiqueta || c.original) === c.lab) { t.value = c.lab; return; }
      operar(() => guardarColumna(programaId, c.k, { etiqueta, visible: c.visible }), 'Columna renombrada.');
    } else if (t.matches('[data-mc-opcion]')) {
      const viejo = t.dataset.mcOpcion;
      if (!v || v === viejo) { t.value = viejo; return; }
      if (c.opciones.includes(v)) { t.value = viejo; toast('Esa opción ya está.', 'error'); return; }
      operar(() => renombrarOpcion(programaId, c.k, viejo, v), 'Opción renombrada.');
    }
  });

  overlay.addEventListener('input', ev => {
    const campo = ev.target.dataset.mcNueva;
    if (!campo || !ui.nueva) return;
    ui.nueva[campo] = ev.target.value;
    if (campo === 'tipo') pintar();
  });

  overlay.addEventListener('toggle', ev => {
    if (ev.target.matches('.mc-archivadas')) ui.archivadas = ev.target.open;
  }, true);

  overlay.addEventListener('keydown', ev => {
    if (ev.key !== 'Enter' || ev.target.tagName !== 'INPUT') return;
    ev.preventDefault();
    if (ev.target.matches('[data-mc-agregar]')) ev.target.parentElement.querySelector('[data-mc="op-agregar"]').click();
    else if (ev.target.id === 'mc-nv-nombre') body.querySelector('[data-mc="crear"]').click();
    else ev.target.blur();
  });

  /* Arrastrar y soltar: se agarra del asa, se suelta arriba o abajo de otra fila. */
  let arrastrando = '';
  const limpiarMarcas = () => {
    for (const li of body.querySelectorAll('.mc-drop-antes,.mc-drop-despues,.mc-arrastrando')) {
      li.classList.remove('mc-drop-antes', 'mc-drop-despues', 'mc-arrastrando');
    }
  };
  const destinoDe = ev => {
    const li = ev.target.closest('.mc-item');
    if (!li) return null;
    const r = li.getBoundingClientRect();
    return { li, despues: ev.clientY > r.top + r.height / 2 };
  };
  overlay.addEventListener('dragstart', ev => {
    const asa = ev.target.closest ? ev.target.closest('.mc-asa') : null;
    if (!asa) return;
    const li = asa.closest('.mc-item');
    arrastrando = li.dataset.clave;
    ev.dataTransfer.effectAllowed = 'move';
    ev.dataTransfer.setData('text/plain', arrastrando);
    ev.dataTransfer.setDragImage(li, 12, 12);
    li.classList.add('mc-arrastrando');
  });
  overlay.addEventListener('dragover', ev => {
    const d = arrastrando && destinoDe(ev);
    if (!d) return;
    ev.preventDefault();
    ev.dataTransfer.dropEffect = 'move';
    for (const li of body.querySelectorAll('.mc-drop-antes,.mc-drop-despues')) li.classList.remove('mc-drop-antes', 'mc-drop-despues');
    if (d.li.dataset.clave !== arrastrando) d.li.classList.add(d.despues ? 'mc-drop-despues' : 'mc-drop-antes');
  });
  overlay.addEventListener('drop', ev => {
    const d = arrastrando && destinoDe(ev);
    if (!d) return;
    ev.preventDefault();
    const origen = arrastrando;
    arrastrando = '';
    limpiarMarcas();
    if (d.li.dataset.clave !== origen) mover(origen, d.li.dataset.clave, d.despues);
  });
  overlay.addEventListener('dragend', () => { arrastrando = ''; limpiarMarcas(); });

  document.addEventListener('keydown', onKey);
  document.body.appendChild(overlay);
  pintar();
  overlay.querySelector('[data-mc="cerrar"]').focus();
  return { cerrar, pintar };
}
