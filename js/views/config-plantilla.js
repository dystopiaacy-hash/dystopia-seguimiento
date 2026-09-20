/* Config — etapas y plantilla de accionables: HTML, lectura del DOM y validación.
   La validación de acá es la MISMA que el CHECK cs_validar_plantilla de 001
   (array de objetos con key y titulo no vacíos, responsable bpf|cliente,
   dia_offset y vence_en_dias enteros >= 0, keys únicas). Se valida antes de
   mandar para dar un error entendible; si igual falla, manda el CHECK. */
import { esc } from '../ui.js';
import { opcionesHtml } from './comunes.js';
import { RESPONSABLE_LABEL } from '../datos.js';

/* ---------- Etapas ---------- */

export function htmlEtapas(etapas) {
  const filas = (etapas || []).map((e, i) => `
    <div class="etapa-item">
      <span class="etapa-n">${i + 1}</span>
      <input type="text" data-etapa="${i}" value="${esc(e)}" maxlength="60" aria-label="Etapa ${i + 1}">
      <button type="button" class="btn-icono" data-mover-etapa="${i}" data-dir="-1"
        ${i === 0 ? 'disabled' : ''} aria-label="Subir">↑</button>
      <button type="button" class="btn-icono" data-mover-etapa="${i}" data-dir="1"
        ${i === (etapas || []).length - 1 ? 'disabled' : ''} aria-label="Bajar">↓</button>
      <button type="button" class="btn-icono btn-icono-danger" data-borrar-etapa="${i}" aria-label="Borrar">✕</button>
    </div>`).join('');
  return `
    ${filas || '<div class="muted-empty">Sin etapas. El selector de etapa de la ficha queda vacío.</div>'}
    <div class="hint">El orden es el del ciclo del cliente. Si renombrás una etapa, los clientes
      que ya la tienen guardada siguen con el nombre viejo hasta que los edites.</div>
    <button type="button" class="btn btn-sm" data-agregar-etapa>Agregar etapa</button>`;
}

export function leerEtapas(raiz) {
  return Array.from(raiz.querySelectorAll('[data-etapa]'))
    .map(i => i.value.trim())
    .filter(Boolean);
}

/* ---------- Plantilla de accionables ---------- */

const COLS = [
  ['key', 'Key', 'text'],
  ['titulo', 'Título', 'text'],
  ['descripcion', 'Descripción', 'text'],
  ['dia_offset', 'Día', 'num'],
  ['vence_en_dias', 'Vence en', 'num']
];

function celda(i, [campo, label, tipo], item) {
  const v = item[campo] == null ? '' : item[campo];
  if (tipo === 'num') {
    return `<td data-label="${esc(label)}" class="col-num">
      <input type="number" min="0" step="1" data-pl="${i}" data-campo="${campo}"
        value="${esc(v)}" aria-label="${esc(label)} del ítem ${i + 1}"></td>`;
  }
  return `<td data-label="${esc(label)}">
    <input type="text" data-pl="${i}" data-campo="${campo}" value="${esc(v)}"
      maxlength="200" aria-label="${esc(label)} del ítem ${i + 1}"></td>`;
}

export function htmlPlantilla(items) {
  const filas = (items || []).map((it, i) => `
    <tr>
      ${COLS.map(c => celda(i, c, it)).join('')}
      <td data-label="Responsable">
        <select data-pl="${i}" data-campo="responsable" aria-label="Responsable del ítem ${i + 1}">
          ${opcionesHtml(Object.entries(RESPONSABLE_LABEL), it.responsable || 'bpf')}
        </select></td>
      <td class="col-acc">
        <button type="button" class="btn-icono btn-icono-danger" data-borrar-pl="${i}" aria-label="Borrar ítem">✕</button></td>
    </tr>`).join('');
  return `
    <table class="plantilla-tabla">
      <thead><tr>
        ${COLS.map(c => `<th scope="col">${esc(c[1])}</th>`).join('')}
        <th scope="col">Responsable</th><th scope="col" aria-label="Borrar"></th>
      </tr></thead>
      <tbody>${filas}</tbody>
    </table>
    ${items && items.length ? '' : '<div class="muted-empty">Sin ítems: los clientes nuevos arrancan sin accionables automáticos.</div>'}
    <div class="hint">"Día" = días desde el inicio del programa en que aparece el ítem.
      "Vence en" = días después de ese día. La key identifica al ítem para no duplicarlo:
      si la cambiás, a los clientes que ya lo tienen se les vuelve a crear con la key nueva.</div>
    <button type="button" class="btn btn-sm" data-agregar-pl>Agregar ítem</button>`;
}

export function leerPlantilla(raiz) {
  const items = [];
  for (const el of raiz.querySelectorAll('[data-pl]')) {
    const i = Number(el.dataset.pl);
    if (!items[i]) items[i] = {};
    const v = el.value.trim();
    if (el.dataset.campo === 'dia_offset' || el.dataset.campo === 'vence_en_dias') {
      if (v !== '') items[i][el.dataset.campo] = Number(v);
    } else if (v !== '') {
      items[i][el.dataset.campo] = v;
    }
  }
  return items.filter(Boolean);
}

/* Slug para la key cuando el usuario no la escribió: minúsculas, sin acentos, con _. */
export function slug(s) {
  return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
}

/* Completa las keys vacías a partir del título (sin pisar las que ya están). */
export function completarKeys(items) {
  const usadas = new Set(items.map(it => it.key).filter(Boolean));
  return items.map(it => {
    if (it.key) return it;
    let base = slug(it.titulo) || 'item';
    let k = base, n = 2;
    while (usadas.has(k)) k = `${base}_${n++}`;
    usadas.add(k);
    return { ...it, key: k };
  });
}

/* Devuelve '' si está bien, o el primer problema en castellano. */
export function validarPlantilla(items) {
  const keys = new Set();
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    const n = `Ítem ${i + 1}`;
    if (!it.titulo) return `${n}: falta el título.`;
    if (!it.key) return `${n}: falta la key.`;
    if (keys.has(it.key)) return `${n}: la key "${it.key}" está repetida.`;
    keys.add(it.key);
    if (!['bpf', 'cliente'].includes(it.responsable)) return `${n}: el responsable tiene que ser BPF o Cliente.`;
    for (const campo of ['dia_offset', 'vence_en_dias']) {
      const v = it[campo];
      if (v === undefined) continue;
      if (!Number.isInteger(v) || v < 0) {
        return `${n}: "${campo === 'dia_offset' ? 'Día' : 'Vence en'}" tiene que ser un número entero de 0 o más.`;
      }
    }
  }
  return '';
}
