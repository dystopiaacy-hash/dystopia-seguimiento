/* Buscador con lista desplegable (106). Pieza común del selector de alumno y del selector de dudas.
   Busca con js/normalizar.js (acentos y mayúsculas no importan; todas las palabras escritas
   tienen que estar). No guarda estado de negocio: avisa lo elegido por callback.
     buscar(consulta)  -> [{ id, label, detalle? }]   (se muestran los primeros 8)
     permitirCrear     -> agrega "Crear «texto»" cuando no hay una igual
     alElegir(item)    -> item = una fila de buscar() o { crear: true, texto }
     alEscribir()      -> el usuario tocó el texto (lo elegido antes ya no vale) */
import { esc } from '../ui.js';
import { norm } from '../normalizar.js';

export function montarBuscador(box, { id, placeholder = '', buscar, permitirCrear = false, alElegir, alEscribir = null, maxlength = 300 }) {
  box.classList.add('bus');
  box.innerHTML = `
    <input type="text" id="${esc(id)}" class="bus-input" autocomplete="off" maxlength="${maxlength}"
      placeholder="${esc(placeholder)}" role="combobox" aria-expanded="false" aria-autocomplete="list">
    <div class="bus-lista" hidden role="listbox"></div>`;
  const inp = box.querySelector('input');
  const lista = box.querySelector('.bus-lista');
  let opciones = [];

  function ocultar() {
    lista.hidden = true;
    inp.setAttribute('aria-expanded', 'false');
  }

  function pintar() {
    const q = inp.value;
    opciones = buscar(q).slice(0, 8);
    let html = opciones.map((o, i) => `<button type="button" class="bus-op" role="option" data-i="${i}">
        <span>${esc(o.label)}</span>${o.detalle ? `<span class="bus-det">${esc(o.detalle)}</span>` : ''}</button>`).join('');
    const t = q.trim();
    if (permitirCrear && t && !opciones.some(o => norm(o.label) === norm(t))) {
      html += `<button type="button" class="bus-op bus-crear" data-crear="1">Crear «${esc(t)}»</button>`;
    }
    lista.innerHTML = html;
    lista.hidden = !html;
    inp.setAttribute('aria-expanded', html ? 'true' : 'false');
  }

  inp.addEventListener('input', () => { if (alEscribir) alEscribir(); pintar(); });
  inp.addEventListener('focus', pintar);
  inp.addEventListener('blur', () => ocultar());
  inp.addEventListener('keydown', ev => { if (ev.key === 'Escape') ocultar(); });
  /* mousedown (no click): el blur del campo cerraría la lista antes del click. */
  lista.addEventListener('mousedown', ev => {
    const b = ev.target.closest('.bus-op');
    if (!b) return;
    ev.preventDefault();
    if (b.dataset.crear) alElegir({ crear: true, texto: inp.value.trim() });
    else alElegir(opciones[Number(b.dataset.i)]);
    ocultar();
  });

  return {
    input: inp,
    poner: texto => { inp.value = texto; },
    limpiar: () => { inp.value = ''; ocultar(); },
    foco: () => inp.focus()
  };
}
