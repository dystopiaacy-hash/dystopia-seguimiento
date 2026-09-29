/* Formulario de seguimiento (cs_seguimientos, 038). Lo comparten la ficha (bloque
   Seguimientos) y la Revisión ("Chequeado").
   Obligatorio: canal y resumen. Opcional: etapa, avance y próximo contacto; en la
   Revisión van plegados para no frenar el flujo rápido.
   Lo que se va escribiendo vive en BORRADORES (memoria, por cliente): un refresco
   de realtime repinta todo y repintarConservandoFoco solo salva el campo con foco,
   así que el resto se vuelve a pintar desde el borrador. */
import { esc, hoyAR } from '../ui.js';
import { CANAL_LABEL, AVANCE_LABEL } from '../datos.js';
import { opcionesHtml } from './comunes.js';

const BORRADORES = new Map();   // clienteId -> { canal, resumen, etapa, avance, proximo_contacto }

function borrador(clienteId) {
  if (!BORRADORES.has(clienteId)) {
    BORRADORES.set(clienteId, { canal: '', resumen: '', etapa: '', avance: '', proximo_contacto: '' });
  }
  return BORRADORES.get(clienteId);
}

export function limpiarBorrador(clienteId) {
  BORRADORES.delete(clienteId);
}

function opcionesEtapa(p, c) {
  const etapas = (Array.isArray(p.etapas) ? p.etapas : []).filter(Boolean).map(String);
  const actual = c.etapa ? ` (hoy: ${c.etapa})` : '';
  return [['', 'Sin cambio' + actual]].concat(etapas.map(e => [e, e]));
}

function chipsCanal(pre, valor) {
  return Object.entries(CANAL_LABEL).map(([v, t]) => `
    <label class="seg-chip">
      <input type="radio" name="${esc(pre)}-canal" value="${esc(v)}" data-seg="canal"${v === valor ? ' checked' : ''}>
      <span>${esc(t)}</span>
    </label>`).join('');
}

/* pre: prefijo de ids (uno por pantalla). compacto: pliega lo opcional. */
export function formSeguimiento({ pre, p, c, compacto = false }) {
  const b = borrador(c.id);
  const opcionales = `
    <div class="seg-opc">
      <div class="form-row">
        <label for="${pre}-etapa">Etapa</label>
        <select id="${pre}-etapa" data-seg="etapa">${opcionesHtml(opcionesEtapa(p, c), b.etapa)}</select>
      </div>
      <div class="form-row">
        <label for="${pre}-avance">Avance</label>
        <select id="${pre}-avance" data-seg="avance">${opcionesHtml(
          [['', 'Sin marcar']].concat(Object.entries(AVANCE_LABEL)), b.avance)}</select>
      </div>
      <div class="form-row">
        <label for="${pre}-proximo">Próximo contacto</label>
        <input type="date" id="${pre}-proximo" data-seg="proximo_contacto" min="${esc(hoyAR())}"
          value="${esc(b.proximo_contacto)}">
      </div>
    </div>`;
  const hayOpcional = b.etapa || b.avance || b.proximo_contacto;
  return `
    <div class="seg-form" data-seg-cliente="${esc(c.id)}">
      <div class="form-row">
        <span class="seg-lab" id="${pre}-canal-lab">Canal *</span>
        <div class="seg-chips" role="radiogroup" aria-labelledby="${pre}-canal-lab">${chipsCanal(pre, b.canal)}</div>
      </div>
      <div class="form-row">
        <label for="${pre}-resumen">Resumen *</label>
        <textarea id="${pre}-resumen" data-seg="resumen" maxlength="2000" rows="${compacto ? 2 : 3}"
          placeholder="Qué se habló, cómo viene, qué quedó pendiente">${esc(b.resumen)}</textarea>
      </div>
      ${compacto
        ? `<details class="seg-mas"${hayOpcional ? ' open' : ''}>
             <summary>Etapa, avance y próximo contacto (opcional)</summary>${opcionales}</details>`
        : opcionales}
    </div>`;
}

/* Guarda en el borrador lo que cambió. true si el evento era de este formulario. */
export function anotarCambio(ev) {
  const campo = ev.target.closest('[data-seg]');
  const form = campo && campo.closest('[data-seg-cliente]');
  if (!form) return false;
  borrador(form.dataset.segCliente)[campo.dataset.seg] = campo.value;
  return true;
}

/* Lee el formulario ya pintado. { error } o { datos } listo para registrarSeguimiento. */
export function leerSeguimiento(raiz, pre) {
  const canal = raiz.querySelector(`input[name="${pre}-canal"]:checked`);
  const val = id => {
    const el = raiz.querySelector('#' + pre + '-' + id);
    return el ? el.value.trim() : '';
  };
  const datos = {
    canal: canal ? canal.value : '',
    resumen: val('resumen'),
    etapa: val('etapa'),
    avance: val('avance'),
    proximo_contacto: val('proximo')
  };
  if (!datos.canal) return { error: 'Elegí por dónde fue el contacto.', foco: raiz.querySelector(`input[name="${pre}-canal"]`) };
  if (!datos.resumen) return { error: 'Escribí un resumen del contacto.', foco: raiz.querySelector('#' + pre + '-resumen') };
  if (datos.proximo_contacto && datos.proximo_contacto < hoyAR()) {
    return { error: 'El próximo contacto no puede ser una fecha pasada.', foco: raiz.querySelector('#' + pre + '-proximo') };
  }
  return { datos };
}
