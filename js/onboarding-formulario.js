/* Onboarding público: paso de formulario, una sección por pantalla.
   Tipos: texto, parrafo, opcion (una sola), casillas (varias), escala_1_10.
   Cada "Siguiente" guarda un borrador en el servidor (si falla no frena: el envío
   final lleva todo). Las obligatorias se validan acá para decir qué falta; la base
   vuelve a validar todo (cs_ob_limpiar).
   Todo lo que viene de la base pasa por esc() antes de ir al DOM. */
import { esc } from './ui.js';

const idDe = k => 'ob-c-' + String(k).replace(/[^A-Za-z0-9_-]/g, '_');
const vacio = v => v == null || v === '' || (Array.isArray(v) && !v.length);

/* "Otros" con texto libre (096): el campo declara c.otro = texto de la opción; el
   texto va en la clave "<key>_otro" y solo cuenta si esa opción está elegida. */
const otroElegido = (c, v) => !!c.otro && (Array.isArray(v) ? v.includes(c.otro) : v === c.otro);

function cajaOtro(c, v, vOtro) {
  if (!c.otro) return '';
  return `<input type="text" class="pub-otro" data-k="${esc(c.key + '_otro')}" maxlength="300"
    value="${esc(vOtro || '')}" placeholder="Escribí tu respuesta" autocomplete="off"
    aria-label="${esc(c.otro + ': ' + c.label)}"${otroElegido(c, v) ? '' : ' hidden'}>`;
}

function control(c, v, vOtro) {
  const id = idDe(c.key);
  const req = c.requerido ? ' aria-required="true"' : '';
  switch (c.tipo) {
    case 'parrafo':
      return `<textarea id="${id}" data-k="${esc(c.key)}" rows="4" maxlength="2000"${req}>${esc(v || '')}</textarea>`;
    case 'opcion':
      return `<div class="pub-opciones" role="radiogroup" aria-label="${esc(c.label)}">
        ${c.opciones.map(o => `<label class="pub-opcion">
          <input type="radio" name="${id}" data-k="${esc(c.key)}" value="${esc(o)}"${v === o ? ' checked' : ''}>
          <span>${esc(o)}</span></label>`).join('')}</div>${cajaOtro(c, v, vOtro)}`;
    case 'casillas': {
      const sel = Array.isArray(v) ? v : [];
      return `<div class="pub-opciones" role="group" aria-label="${esc(c.label)}">
        ${c.opciones.map(o => `<label class="pub-opcion">
          <input type="checkbox" data-k="${esc(c.key)}" data-multi="1" value="${esc(o)}"${sel.includes(o) ? ' checked' : ''}>
          <span>${esc(o)}</span></label>`).join('')}</div>${cajaOtro(c, v, vOtro)}`;
    }
    case 'escala_1_10': {
      const ext = Array.isArray(c.extremos) ? c.extremos : [];
      return `<div class="ob-escala" role="group" aria-label="${esc(c.label)}">
        ${Array.from({ length: 10 }, (_, i) => i + 1).map(n => `
          <button type="button" class="pub-esc-btn${Number(v) === n ? ' on' : ''}" data-k="${esc(c.key)}"
            data-valor="${n}" aria-pressed="${Number(v) === n}">${n}</button>`).join('')}
      </div>
      ${ext.length ? `<div class="pub-escala-pie"><span>1 · ${esc(ext[0] || '')}</span><span>10 · ${esc(ext[1] || '')}</span></div>` : ''}`;
    }
    default:
      return `<input type="text" id="${id}" data-k="${esc(c.key)}" maxlength="300" value="${esc(v || '')}" autocomplete="off"${req}>`;
  }
}

function campoHtml(c, v, vOtro) {
  return `<div class="pub-campo" data-campo="${esc(c.key)}">
    <label class="pub-label" for="${idDe(c.key)}">${esc(c.label)}${c.requerido ? ' <span class="pub-req" title="Obligatorio">*</span>' : ''}</label>
    ${c.ayuda ? `<div class="ob-ayuda">${esc(c.ayuda)}</div>` : ''}
    ${control(c, v, vOtro)}
    <div class="pub-error" data-error="${esc(c.key)}"></div>
  </div>`;
}

/* box: contenedor del paso. resp0: borrador guardado { key: valor }.
   api: { rpc, token, aplicar, mensaje, borrador }. api.borrador(key) es una memoria
   de la página ({ valores, sec }) que sobrevive a "Volver": lo escrito en este paso
   no se pierde al ir a un paso anterior y regresar. */
export function pasoFormulario(box, paso, resp0, api) {
  const secciones = paso.secciones || [];
  const mem = api.borrador ? api.borrador(paso.key) : { valores: null, sec: null };
  const valores = mem.valores || { ...(resp0 || {}) };
  mem.valores = valores;
  let sec = 0, enviando = false;

  /* Retoma donde estaba; si no, en la primera sección con una obligatoria sin responder. */
  const falta = c => c.requerido && vacio(valores[c.key]);
  const primera = secciones.findIndex(s => s.campos.some(falta));
  sec = mem.sec != null
    ? Math.min(mem.sec, Math.max(0, secciones.length - 1))
    : (primera < 0 ? 0 : primera);

  function payload() {
    const out = {};
    for (const s of secciones) for (const c of s.campos) {
      const v = valores[c.key];
      if (vacio(v)) continue;
      out[c.key] = typeof v === 'string' ? v.trim() : v;
      /* El texto de "Otros" solo viaja si esa opción está elegida. */
      const otro = valores[c.key + '_otro'];
      if (otroElegido(c, v) && typeof otro === 'string' && otro.trim()) out[c.key + '_otro'] = otro.trim();
    }
    return out;
  }

  function marcar(key, texto) {
    const e = box.querySelector(`[data-error="${CSS.escape(key)}"]`);
    if (e) e.textContent = texto;
    const campo = box.querySelector(`[data-campo="${CSS.escape(key)}"]`);
    if (campo) campo.classList.toggle('pub-campo-mal', !!texto);
  }

  /* Devuelve la primera key con error (y marca todas las de la sección). */
  function validarSeccion(i) {
    let primero = null;
    for (const c of secciones[i].campos) {
      const v = valores[c.key];
      let msg = '';
      if (vacio(v) || (typeof v === 'string' && !v.trim())) {
        if (c.requerido) msg = 'Falta completar esto.';
      } else if (c.contacto === 'email' && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(v).trim())) {
        msg = 'Revisá el mail: tiene que tener la forma nombre@dominio.com';
      }
      marcar(c.key, msg);
      if (msg && !primero) primero = c.key;
    }
    return primero;
  }

  function pintar(aviso = '') {
    const s = secciones[sec];
    const ultima = sec === secciones.length - 1;
    mem.sec = sec;
    box.innerHTML = `
      <h2 class="ob-titulo">${esc(paso.titulo)}</h2>
      ${sec === 0 && paso.texto ? `<p class="ob-texto">${esc(paso.texto)}</p>` : ''}
      ${paso.tiempo && sec === 0 ? `<div class="ob-meta">Tiempo estimado: ${esc(paso.tiempo)}</div>` : ''}
      ${secciones.length > 1 ? `<div class="ob-sec-prog">Sección ${sec + 1} de ${secciones.length}${s.titulo ? ' · ' + esc(s.titulo) : ''}</div>` : (s.titulo ? `<div class="ob-sec-prog">${esc(s.titulo)}</div>` : '')}
      ${s.texto ? `<p class="ob-texto">${esc(s.texto)}</p>` : ''}
      ${aviso ? `<div class="pub-aviso" role="alert">${esc(aviso)}</div>` : ''}
      <form id="ob-form" novalidate>
        ${s.campos.map(c => campoHtml(c, valores[c.key], valores[c.key + '_otro'])).join('')}
        <div class="ob-nav">
          ${sec > 0 ? '<button type="button" class="btn" data-nav="atras">Anterior</button>' : '<span></span>'}
          <button type="submit" class="btn btn-accent" id="ob-adelante">${ultima ? 'Enviar' : 'Siguiente'}</button>
        </div>
      </form>`;
    box.scrollIntoView({ block: 'start' });
  }

  function leer(ev) {
    const t = ev.target;
    const k = t.dataset && t.dataset.k;
    if (!k || t.type === 'button') return;
    if (t.dataset.multi) {
      const cur = Array.isArray(valores[k]) ? valores[k].slice() : [];
      const i = cur.indexOf(t.value);
      if (t.checked && i < 0) cur.push(t.value);
      if (!t.checked && i >= 0) cur.splice(i, 1);
      valores[k] = cur;
    } else {
      valores[k] = t.value;
    }
    marcar(k, '');
    /* Mostrar u ocultar la caja de "Otros" según lo elegido. */
    const campo = secciones.flatMap(s => s.campos).find(c => c.key === k && c.otro);
    if (campo) {
      const caja = box.querySelector(`[data-k="${CSS.escape(k + '_otro')}"]`);
      if (caja) caja.hidden = !otroElegido(campo, valores[k]);
    }
  }
  box.addEventListener('input', leer);
  box.addEventListener('change', leer);

  box.addEventListener('click', ev => {
    const b = ev.target.closest('.pub-esc-btn');
    if (b) {
      const k = b.dataset.k;
      valores[k] = Number(b.dataset.valor);
      for (const o of box.querySelectorAll(`.pub-esc-btn[data-k="${CSS.escape(k)}"]`)) {
        const on = o === b;
        o.classList.toggle('on', on);
        o.setAttribute('aria-pressed', String(on));
      }
      marcar(k, '');
      return;
    }
    if (ev.target.closest('[data-nav="atras"]')) { sec = Math.max(0, sec - 1); pintar(); }
  });

  box.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (enviando) return;
    const mal = validarSeccion(sec);
    if (mal) {
      const el = box.querySelector(`[data-campo="${CSS.escape(mal)}"]`);
      if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return;
    }
    const ultima = sec === secciones.length - 1;
    enviando = true;
    const btn = box.querySelector('#ob-adelante');
    if (btn) { btn.disabled = true; btn.textContent = ultima ? 'Enviando…' : 'Guardando…'; }

    if (!ultima) {
      /* Borrador: si falla, se sigue igual (el envío final lleva todo). */
      try {
        await api.rpc('cs_ob_avanzar', { p_token: api.token, p_paso: paso.key, p_respuestas: payload(), p_completar: false });
      } catch (e) { console.error('borrador', e); }
      enviando = false;
      sec += 1;
      pintar();
      return;
    }

    /* Envío final: se revisan todas las secciones antes de mandar. */
    for (let i = 0; i < secciones.length; i++) {
      const faltaAlguna = secciones[i].campos.some(c => c.requerido && (vacio(valores[c.key])
        || (typeof valores[c.key] === 'string' && !valores[c.key].trim())));
      if (faltaAlguna) {
        enviando = false;
        sec = i;
        pintar('Falta completar algo obligatorio en esta sección.');
        validarSeccion(i);
        return;
      }
    }
    try {
      const estado = await api.rpc('cs_ob_avanzar', { p_token: api.token, p_paso: paso.key, p_respuestas: payload(), p_completar: true });
      api.aplicar(estado);
    } catch (e) {
      enviando = false;
      pintar(api.mensaje(e));
    }
  });

  pintar();
  return {
    destruir() {},
    /* Al tocar "Volver": manda lo cargado como borrador, sin esperar ni frenar
       (la memoria de la página ya lo conserva; esto lo protege si cierran la pestaña). */
    guardarBorrador() {
      const p = payload();
      if (enviando || !Object.keys(p).length) return;
      api.rpc('cs_ob_avanzar', { p_token: api.token, p_paso: paso.key, p_respuestas: p, p_completar: false })
        .catch(e => console.error('borrador', e));
    }
  };
}
