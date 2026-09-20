/* Constructor de formularios — links por cliente.
   El link lleva dos tokens: el del formulario (cs_formularios.token) y el del
   cliente (cs_clientes.token_publico). Con ese par, cs_form_publico decide si el
   link sirve; la app no tiene que chequear nada acá.
   El dominio sale de window.location.origin: el mismo link funciona en local y
   en Vercel sin configurar nada. */
import { esc, abrirModal, toast } from '../ui.js';
import { opcionesHtml } from './comunes.js';
import { esVivo } from '../datos.js';

/* /form lo resuelve cleanUrls de vercel.json (y el fallback .html de http-server
   en local): no se escribe /form.html para que el link que se manda por WhatsApp
   no tenga extensión. */
export function linkFormulario(form, cliente) {
  return `${window.location.origin}/form`
    + `?f=${encodeURIComponent(form.token)}&c=${encodeURIComponent(cliente.token_publico)}`;
}

/* Copia al portapapeles. navigator.clipboard solo existe en https y en localhost:
   si no está o falla, se devuelve false y quien llama deja el texto seleccionado
   para copiar a mano. */
export async function copiar(texto) {
  try {
    await navigator.clipboard.writeText(texto);
    return true;
  } catch {
    return false;
  }
}

function seleccionar(el) {
  el.focus();
  el.select();
  try { el.setSelectionRange(0, el.value.length); } catch { /* ídem */ }
}

export function abrirLinks({ form, clientes }) {
  /* Un cliente en baja no puede abrir el link (lo rechaza cs_form_publico), así que
     no se ofrece. Los vivos primero; los finalizados quedan al final por si hace
     falta mandarles un formulario de cierre. */
  const utiles = (clientes || []).filter(c => c.estado !== 'baja');
  const vivos = utiles.filter(esVivo);
  const resto = utiles.filter(c => !esVivo(c));
  const pares = [['', 'Elegí un cliente…']]
    .concat(vivos.map(c => [c.id, c.nombre]))
    .concat(resto.map(c => [c.id, `${c.nombre} (${c.estado})`]));

  const m = abrirModal({
    titulo: `Links · ${form.nombre}`,
    cuerpo: `
      ${form.activo ? '' : `
        <div class="aviso-inline">Este formulario está <strong>desactivado</strong>:
          los links no van a abrir hasta que lo actives.</div>`}
      <div class="form-row">
        <label for="lk-cli">Cliente</label>
        <select id="lk-cli">${opcionesHtml(pares, '')}</select>
      </div>
      <div class="form-row">
        <label for="lk-url">Link para ese cliente</label>
        <input type="text" id="lk-url" readonly value="" placeholder="Elegí un cliente arriba">
        <div class="hint">Cada cliente tiene su propio link: no se los pases cruzados.</div>
      </div>
      <div class="link-acc">
        <button type="button" class="btn btn-accent" id="lk-copiar" disabled>Copiar link</button>
      </div>
      <div class="divider-soft"></div>
      <div class="form-row">
        <label for="lk-todos">Todos los clientes activos (${vivos.length})</label>
        <textarea id="lk-todos" rows="5" readonly
          placeholder="Sin clientes activos">${esc(vivos.map(c => `${c.nombre}: ${linkFormulario(form, c)}`).join('\n'))}</textarea>
        <div class="hint">Un cliente por línea, listo para pegar en WhatsApp.</div>
      </div>
      <div class="link-acc">
        <button type="button" class="btn" id="lk-copiar-todos" ${vivos.length ? '' : 'disabled'}>Copiar todos</button>
      </div>`
  });

  const sel = m.el.querySelector('#lk-cli');
  const url = m.el.querySelector('#lk-url');
  const btn = m.el.querySelector('#lk-copiar');
  const todos = m.el.querySelector('#lk-todos');

  sel.addEventListener('change', () => {
    const c = utiles.find(x => x.id === sel.value);
    url.value = c ? linkFormulario(form, c) : '';
    btn.disabled = !c;
    if (c) seleccionar(url);
  });

  async function copiarDe(el, ok) {
    if (!el.value) return;
    if (await copiar(el.value)) toast(ok);
    else { seleccionar(el); toast('No se pudo copiar solo: está seleccionado, apretá Ctrl+C.', 'error'); }
  }

  btn.addEventListener('click', () => copiarDe(url, 'Link copiado.'));
  m.el.querySelector('#lk-copiar-todos').addEventListener('click', () => copiarDe(todos, 'Links copiados.'));
  sel.focus();
  return m;
}
