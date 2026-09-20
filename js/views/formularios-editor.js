/* Constructor de formularios — editor de campos: HTML, lectura del DOM y validación.
   La validación de acá es la MISMA que el CHECK cs_validar_campos de 001 (key y
   label no vacíos, tipo de la lista, 'opcion' con al menos una opción, keys únicas,
   como mucho un es_metrica y que sea escala_0_10). Se valida antes de mandar para
   dar un error entendible; si igual falla, manda el CHECK.
   Mismo patrón que config-plantilla.js, y reusa su slug()/completarKeys(). */
import { esc } from '../ui.js';
import { opcionesHtml } from './comunes.js';
import { slug } from './config-plantilla.js';
import { CAMPO_TIPO_LABEL } from '../datos.js';

const TIPOS = Object.entries(CAMPO_TIPO_LABEL);

/* Las opciones se editan como texto separado por comas y se guardan como array. */
export function opcionesATexto(op) {
  return Array.isArray(op) ? op.join(', ') : '';
}
function textoAOpciones(t) {
  return String(t || '').split(',').map(s => s.trim()).filter(Boolean);
}

export function campoVacio() {
  return { key: '', label: '', tipo: 'texto', requerido: false, es_metrica: false, opciones: [] };
}

/* ---------- HTML ---------- */

function fila(c, i, total) {
  const esOpcion = c.tipo === 'opcion';
  const esEscala = c.tipo === 'escala_0_10';
  return `
    <div class="campo-item" data-campo-fila="${i}">
      <div class="campo-n">${i + 1}</div>
      <div class="campo-cuerpo">
        <div class="campo-linea">
          <input type="text" data-c="${i}" data-campo="label" value="${esc(c.label || '')}"
            maxlength="120" placeholder="Pregunta que ve el cliente" aria-label="Pregunta del campo ${i + 1}">
          <select data-c="${i}" data-campo="tipo" aria-label="Tipo del campo ${i + 1}">
            ${opcionesHtml(TIPOS, c.tipo || 'texto')}
          </select>
        </div>
        ${esOpcion ? `
        <div class="campo-linea">
          <input type="text" data-c="${i}" data-campo="opciones" value="${esc(opcionesATexto(c.opciones))}"
            maxlength="300" placeholder="Opciones separadas por coma: whatsapp, mail, llamada"
            aria-label="Opciones del campo ${i + 1}">
        </div>` : ''}
        <div class="campo-linea campo-flags">
          <label class="check-row">
            <input type="checkbox" data-c="${i}" data-campo="requerido" ${c.requerido ? 'checked' : ''}>
            Obligatorio
          </label>
          <label class="check-row${esEscala ? '' : ' check-off'}" title="${esEscala ? 'Este puntaje alimenta las métricas y las alertas de satisfacción baja' : 'Solo una escala 0 a 10 puede ser la métrica'}">
            <input type="checkbox" data-c="${i}" data-campo="es_metrica"
              ${c.es_metrica ? 'checked' : ''} ${esEscala ? '' : 'disabled'}>
            Es la métrica
          </label>
          <span class="campo-key" title="Identificador interno: no cambia aunque cambies la pregunta">${esc(c.key || '(se genera solo)')}</span>
        </div>
      </div>
      <div class="campo-acc">
        <button type="button" class="btn-icono" data-mover-c="${i}" data-dir="-1" ${i === 0 ? 'disabled' : ''} aria-label="Subir">↑</button>
        <button type="button" class="btn-icono" data-mover-c="${i}" data-dir="1" ${i === total - 1 ? 'disabled' : ''} aria-label="Bajar">↓</button>
        <button type="button" class="btn-icono btn-icono-danger" data-borrar-c="${i}" aria-label="Borrar campo">✕</button>
      </div>
    </div>`;
}

export function htmlCampos(campos) {
  const cs = campos || [];
  return `
    <div id="campos-lista">${cs.map((c, i) => fila(c, i, cs.length)).join('')}</div>
    ${cs.length ? '' : '<div class="muted-empty">Sin campos todavía. Un formulario sin campos no se puede responder.</div>'}
    <div class="hint">La métrica es el puntaje que se guarda aparte: alimenta Métricas y dispara la alerta
      de satisfacción baja. Solo puede haber una, y tiene que ser una escala 0 a 10.</div>
    <button type="button" class="btn btn-sm" data-agregar-c>Agregar campo</button>`;
}

/* ---------- Lectura del DOM ---------- */

/* Devuelve los campos tal como están en pantalla, respetando el orden. */
export function leerCampos(raiz) {
  const campos = [];
  for (const el of raiz.querySelectorAll('[data-c]')) {
    const i = Number(el.dataset.c);
    if (!campos[i]) campos[i] = campoVacio();
    const campo = el.dataset.campo;
    if (campo === 'requerido') campos[i].requerido = el.checked;
    else if (campo === 'es_metrica') campos[i].es_metrica = el.checked;
    else if (campo === 'opciones') campos[i].opciones = textoAOpciones(el.value);
    else campos[i][campo] = el.value.trim();
  }
  return campos.filter(Boolean).map(c => (c.tipo === 'opcion' ? c : { ...c, opciones: [] }));
}

/* Las keys las completa la app, no la persona: son el identificador que usa
   cs_enviar_respuesta para guardar cada respuesta. Una key que ya existe NO se
   toca aunque cambie la pregunta: si cambiara, las respuestas viejas quedarían
   colgadas de una key que ya no está en campos. */
export function completarKeysCampos(campos) {
  const usadas = new Set(campos.map(c => c.key).filter(Boolean));
  return campos.map(c => {
    if (c.key) return c;
    const base = slug(c.label) || 'campo';
    let k = base, n = 2;
    while (usadas.has(k)) k = `${base}_${n++}`;
    usadas.add(k);
    return { ...c, key: k };
  });
}

/* Lo que se manda a la base: sin flags en false ni opciones vacías, para que
   cs_formularios.campos quede igual de limpio que el seed de 002. */
export function paraGuardar(campos) {
  return campos.map(c => {
    const o = { key: c.key, label: c.label, tipo: c.tipo };
    if (c.tipo === 'opcion') o.opciones = c.opciones;
    if (c.requerido) o.requerido = true;
    if (c.es_metrica) o.es_metrica = true;
    return o;
  });
}

/* ---------- Validación (espejo de cs_validar_campos) ---------- */

/* Devuelve '' si está bien, o el primer problema en castellano. */
export function validarCampos(campos) {
  if (!campos.length) return 'Agregá al menos un campo: un formulario vacío no se puede responder.';
  const keys = new Set();
  let metricas = 0;
  for (let i = 0; i < campos.length; i++) {
    const c = campos[i];
    const n = `Campo ${i + 1}`;
    if (!c.label) return `${n}: falta la pregunta.`;
    if (!c.key) return `${n}: falta el identificador interno.`;
    if (keys.has(c.key)) return `${n}: el identificador "${c.key}" está repetido.`;
    keys.add(c.key);
    if (!CAMPO_TIPO_LABEL[c.tipo]) return `${n}: el tipo no es válido.`;
    if (c.tipo === 'opcion' && !c.opciones.length) {
      return `${n}: es de tipo Opción y no tiene ninguna opción cargada.`;
    }
    if (c.es_metrica) {
      metricas++;
      if (c.tipo !== 'escala_0_10') return `${n}: la métrica tiene que ser una escala 0 a 10.`;
    }
  }
  if (metricas > 1) return 'Solo puede haber una métrica por formulario.';
  return '';
}

/* ---------- Mover / borrar ---------- */

export function mover(campos, i, dir) {
  const j = i + dir;
  if (j < 0 || j >= campos.length) return campos;
  const copia = campos.slice();
  [copia[i], copia[j]] = [copia[j], copia[i]];
  return copia;
}
