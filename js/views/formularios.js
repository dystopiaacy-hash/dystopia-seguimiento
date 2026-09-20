/* Formularios del programa (#/p/:programa/formularios).
   Lista de formularios con tipo, estado y cantidad de respuestas; editor de campos;
   links por cliente; vista de respuestas con export.
   El editor de campos vive en formularios-editor.js, los links en
   formularios-links.js y la tabla de respuestas en formularios-respuestas.js. */
import { esc, badge, plural, toast, abrirModal, cerrarModal, confirmar } from '../ui.js';
import { tarjetaError } from './programa.js';
import {
  traerFormularios, traerClientes, traerRespuestasPrograma,
  crearFila, actualizarFila, borrarFila, mensajeError,
  FORM_TIPO_LABEL, CAMPO_TIPO_LABEL
} from '../datos.js';
import { guardar, opcionesHtml, mapaPorId } from './comunes.js';
import { esFundador } from '../sesion.js';
import {
  htmlCampos, leerCampos, completarKeysCampos, paraGuardar, validarCampos, mover, campoVacio
} from './formularios-editor.js';
import { abrirLinks } from './formularios-links.js';
import { abrirRespuestas } from './formularios-respuestas.js';

const TIPOS = Object.entries(FORM_TIPO_LABEL);

const COLOR_TIPO = {
  onboarding: 'var(--accent)',
  satisfaccion: 'var(--cyan)',
  checkin: 'var(--text-dim)',
  devolucion: 'var(--sem-amarillo)',
  otro: 'var(--text-faint)'
};

/* ---------- Lista ---------- */

function resumenCampos(campos) {
  const cs = campos || [];
  if (!cs.length) return 'Sin campos';
  const metrica = cs.find(c => c.es_metrica);
  const tipos = cs.map(c => CAMPO_TIPO_LABEL[c.tipo] || c.tipo);
  return `${plural(cs.length, 'campo')} · ${tipos.slice(0, 3).join(', ')}${cs.length > 3 ? '…' : ''}`
    + (metrica ? ` · métrica: ${metrica.label}` : '');
}

function tarjeta(f, n) {
  return `
    <article class="form-item${f.activo ? '' : ' form-item-off'}">
      <div class="form-item-main">
        <div class="form-item-tit">${esc(f.nombre)}</div>
        <div class="form-item-meta">
          ${badge(FORM_TIPO_LABEL[f.tipo] || f.tipo, COLOR_TIPO[f.tipo], 'status')}
          ${f.activo ? badge('Activo', 'var(--sem-verde)', 'status') : badge('Desactivado', 'var(--text-faint)', 'outline')}
          <span class="txt-gris">${esc(plural(n, 'respuesta'))}</span>
        </div>
        <div class="form-item-campos">${esc(resumenCampos(f.campos))}</div>
      </div>
      <div class="form-item-acc">
        <button type="button" class="btn btn-sm btn-accent" data-links="${esc(f.id)}">Links</button>
        <button type="button" class="btn btn-sm" data-resp="${esc(f.id)}" ${n ? '' : 'disabled'}>Respuestas</button>
        <button type="button" class="btn btn-sm" data-editar="${esc(f.id)}">Editar</button>
        <button type="button" class="btn btn-sm" data-activar="${esc(f.id)}">${f.activo ? 'Desactivar' : 'Activar'}</button>
        ${esFundador() ? `<button type="button" class="btn-icono btn-icono-danger" data-borrar="${esc(f.id)}" aria-label="Borrar formulario">✕</button>` : ''}
      </div>
    </article>`;
}

/* ---------- Editor ---------- */

/* f = fila de cs_formularios, o null para uno nuevo. */
function abrirEditor(f, programaId, onGuardar) {
  const nuevo = !f;
  let campos = nuevo ? [campoVacio()] : (f.campos || []).map(c => ({ ...c, opciones: c.opciones || [] }));

  const m = abrirModal({
    titulo: nuevo ? 'Nuevo formulario' : 'Editar formulario',
    ancho: true,
    cuerpo: `
      <div class="form-grid2">
        <div class="form-row">
          <label for="f-nombre">Nombre</label>
          <input type="text" id="f-nombre" maxlength="120" value="${esc(nuevo ? '' : f.nombre)}"
            placeholder="Satisfacción mes 1">
          <div class="hint">Lo ve el cliente arriba del formulario.</div>
        </div>
        <div class="form-row">
          <label for="f-tipo">Tipo</label>
          <select id="f-tipo">${opcionesHtml(TIPOS, nuevo ? 'satisfaccion' : f.tipo)}</select>
          <div class="hint">"Onboarding" además marca completado el accionable
            "Completar formulario de onboarding" del cliente que lo responde.</div>
        </div>
      </div>
      <label class="check-row">
        <input type="checkbox" id="f-activo" ${nuevo || f.activo ? 'checked' : ''}>
        Activo (si no, los links no abren)
      </label>
      <div class="subhead form-campos-head"><div class="field-label">Campos</div></div>
      <div id="f-campos"></div>
      <div id="f-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" data-cancelar>Cancelar</button>
          <button type="button" class="btn btn-accent" data-guardar>${nuevo ? 'Crear' : 'Guardar'}</button>`
  });

  const cont = m.el.querySelector('#f-campos');
  const errEl = m.el.querySelector('#f-error');
  const pintarCampos = () => { cont.innerHTML = htmlCampos(campos); };

  /* Cualquier repintado lee primero lo que hay en pantalla: nunca se pierde lo escrito. */
  const sincronizar = () => { campos = leerCampos(cont); };

  cont.addEventListener('change', ev => {
    const t = ev.target;
    /* Una sola métrica: marcar una desmarca las demás (acá, no en la base). */
    if (t.matches('[data-campo="es_metrica"]') && t.checked) {
      for (const o of cont.querySelectorAll('[data-campo="es_metrica"]')) if (o !== t) o.checked = false;
    }
    /* Cambiar el tipo cambia qué controles hace falta mostrar. */
    if (t.matches('[data-campo="tipo"]')) { sincronizar(); pintarCampos(); }
  });

  cont.addEventListener('click', ev => {
    const agregar = ev.target.closest('[data-agregar-c]');
    if (agregar) { sincronizar(); campos.push(campoVacio()); pintarCampos(); return; }

    const mov = ev.target.closest('[data-mover-c]');
    if (mov) { sincronizar(); campos = mover(campos, Number(mov.dataset.moverC), Number(mov.dataset.dir)); pintarCampos(); return; }

    const borrar = ev.target.closest('[data-borrar-c]');
    if (borrar) { sincronizar(); campos.splice(Number(borrar.dataset.borrarC), 1); pintarCampos(); }
  });

  m.el.querySelector('[data-cancelar]').addEventListener('click', cerrarModal);
  m.el.querySelector('[data-guardar]').addEventListener('click', async ev => {
    errEl.textContent = '';
    const nombre = m.el.querySelector('#f-nombre').value.trim();
    if (!nombre) { errEl.textContent = 'Poné un nombre.'; m.el.querySelector('#f-nombre').focus(); return; }

    const listos = completarKeysCampos(leerCampos(cont));
    const problema = validarCampos(listos);
    if (problema) { errEl.textContent = problema; return; }

    campos = listos;
    const fila = {
      nombre,
      tipo: m.el.querySelector('#f-tipo').value,
      activo: m.el.querySelector('#f-activo').checked,
      campos: paraGuardar(listos)
    };

    /* No se usa guardar() de comunes.js: si falla, el modal tiene que quedar
       abierto con todo lo escrito. El error va adentro, no en un toast que se va. */
    const btn = ev.target;
    btn.disabled = true;
    try {
      if (nuevo) await crearFila('cs_formularios', { programa_id: programaId, ...fila });
      else await actualizarFila('cs_formularios', f.id, fila);
      toast(nuevo ? 'Formulario creado.' : 'Formulario guardado.');
      cerrarModal();
      await onGuardar();
    } catch (e) {
      errEl.textContent = mensajeError(e);
    } finally {
      if (btn.isConnected) btn.disabled = false;
    }
  });

  pintarCampos();
  m.el.querySelector('#f-nombre').focus();
}

/* ---------- Vista ---------- */

export function vistaFormularios(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let forms = [], clientes = [], mapaClientes = new Map(), porFormulario = new Map();

  const recargar = () => cargar().catch(e => toast(mensajeError(e), 'error'));

  function pintar() {
    const activos = forms.filter(f => f.activo).length;
    el.innerHTML = `
      <div class="barra-acciones">
        <div class="section-title">Formularios
          <span class="aten-cuenta">${esc(plural(forms.length, 'formulario'))}${forms.length ? ` · ${activos} activo${activos === 1 ? '' : 's'}` : ''}</span>
          <span class="line"></span>
        </div>
        <button type="button" class="btn btn-accent" data-nuevo>Nuevo formulario</button>
      </div>
      ${forms.length
        ? `<div class="form-lista">${forms.map(f => tarjeta(f, (porFormulario.get(f.id) || []).length)).join('')}</div>`
        : `<div class="card empty-state">
             <div class="big">Todavía no hay formularios</div>
             <div class="small">Creá uno, armá los campos y copiá el link de cada cliente.</div>
           </div>`}
      <div class="hint form-nota">Los formularios se mandan a mano: copiás el link del cliente y se lo pasás
        por WhatsApp o mail. El cliente no necesita cuenta ni contraseña.</div>`;
  }

  const buscar = id => forms.find(f => f.id === id);

  el.addEventListener('click', async ev => {
    if (ev.target.closest('[data-nuevo]')) { abrirEditor(null, programaId, recargar); return; }

    const editar = ev.target.closest('[data-editar]');
    if (editar) { const f = buscar(editar.dataset.editar); if (f) abrirEditor(f, programaId, recargar); return; }

    const links = ev.target.closest('[data-links]');
    if (links) { const f = buscar(links.dataset.links); if (f) abrirLinks({ form: f, clientes }); return; }

    const resp = ev.target.closest('[data-resp]');
    if (resp) {
      const f = buscar(resp.dataset.resp);
      if (f) abrirRespuestas({ form: f, respuestas: porFormulario.get(f.id) || [], clientes, mapaClientes });
      return;
    }

    const activar = ev.target.closest('[data-activar]');
    if (activar) {
      const f = buscar(activar.dataset.activar);
      if (!f) return;
      await guardar(() => actualizarFila('cs_formularios', f.id, { activo: !f.activo }), {
        ok: f.activo ? 'Formulario desactivado: los links dejan de abrir.' : 'Formulario activo.',
        luego: recargar, control: activar
      });
      return;
    }

    const borrar = ev.target.closest('[data-borrar]');
    if (borrar) {
      const f = buscar(borrar.dataset.borrar);
      if (!f) return;
      const n = (porFormulario.get(f.id) || []).length;
      const ok = await confirmar({
        titulo: 'Borrar formulario',
        texto: `Se borra "${f.nombre}" y sus links dejan de funcionar.`,
        detalle: n ? `También se borran sus ${plural(n, 'respuesta')}. No se puede deshacer.`
                   : 'Todavía no tiene respuestas.',
        ok: 'Borrar'
      });
      if (!ok) return;
      await guardar(() => borrarFila('cs_formularios', f.id), {
        ok: 'Formulario borrado.', luego: recargar, control: borrar
      });
    }
  });

  async function cargar() {
    const [fs, cls, rs] = await Promise.all([
      traerFormularios(programaId), traerClientes(programaId), traerRespuestasPrograma(programaId)
    ]);
    if (!vigente()) return;
    forms = fs;
    clientes = cls;
    mapaClientes = mapaPorId(cls);
    porFormulario = new Map();
    for (const r of rs) {
      if (!porFormulario.has(r.formulario_id)) porFormulario.set(r.formulario_id, []);
      porFormulario.get(r.formulario_id).push(r);
    }
    pintar();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar los formularios', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('formularios', e)) };
}
