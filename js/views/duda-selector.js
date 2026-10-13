/* Selector de dudas (106): elegir una duda existente con buscador o crear una nueva.
   Lo usan la pantalla "Dudas frecuentes" (una duda) y "Nueva llamada" (varias: "dudas que aparecieron").
   dudas = filas de cs_v_dudas ya cargadas { id, texto, alumnos }.
   valores() devuelve [{ duda_id, texto } | { texto }]: justo lo que reciben cs_duda_mencion
   y p_dudas de cs_llamada_crear. */
import { esc } from '../ui.js';
import { coincide, norm } from '../normalizar.js';
import { plural } from '../ui.js';
import { montarBuscador } from './buscador.js';

export function montarSelectorDudas(box, dudas, { multiple = false, id = 'duda-sel', placeholder = 'Buscar una duda o escribir una nueva…' } = {}) {
  box.innerHTML = '<div class="duda-chips"></div><div class="duda-bus"></div>';
  const chipsBox = box.querySelector('.duda-chips');
  let elegidas = [];

  function pintarChips() {
    chipsBox.innerHTML = elegidas.map((d, i) => `<span class="duda-chip${d.duda_id ? '' : ' duda-chip-nueva'}">
        ${esc(d.texto)}${d.duda_id ? '' : ' <em>(nueva)</em>'}
        <button type="button" data-quitar="${i}" aria-label="${esc('Quitar ' + d.texto)}">✕</button></span>`).join('');
  }

  const b = montarBuscador(box.querySelector('.duda-bus'), {
    id, placeholder, permitirCrear: true, maxlength: 300,
    buscar: q => dudas.filter(d => coincide(d.texto, q))
      .map(d => ({ id: d.id, label: d.texto, detalle: plural(d.alumnos, 'alumno') })),
    alElegir: it => {
      const nueva = it.crear ? { texto: it.texto } : { duda_id: it.id, texto: it.label };
      if (multiple) {
        const igual = elegidas.some(e => (nueva.duda_id && e.duda_id === nueva.duda_id) || norm(e.texto) === norm(nueva.texto));
        if (!igual) elegidas.push(nueva);
        b.limpiar();
        pintarChips();
      } else {
        elegidas = [nueva];
        b.poner(nueva.texto);
      }
    },
    alEscribir: () => { if (!multiple) elegidas = []; }
  });

  box.addEventListener('click', ev => {
    const q = ev.target.closest('[data-quitar]');
    if (!q) return;
    elegidas.splice(Number(q.dataset.quitar), 1);
    pintarChips();
  });

  return {
    valores() {
      if (multiple) return elegidas.slice();
      if (elegidas.length) return elegidas.slice();
      const t = b.input.value.trim();
      return t ? [{ texto: t }] : [];
    },
    limpiar() { elegidas = []; b.limpiar(); pintarChips(); },
    foco: b.foco
  };
}
