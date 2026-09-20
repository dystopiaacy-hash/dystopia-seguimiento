/* Página pública de formularios (form.html?f=<token>&c=<token_publico>).
   Sin login. Lo único que hace contra la base son las DOS RPC de la migración 004:
   cs_form_publico (trae nombre del formulario, campos y primer nombre del cliente)
   y cs_enviar_respuesta. No lee ninguna tabla ni ninguna otra función.

   Cliente de supabase propio, con persistSession en false: aunque quien abra el
   link ya esté logueado en la app (mismo origen, misma localStorage), esta página
   no toca esa sesión y entra siempre como anon. Así se comporta igual para todos.

   Todo lo que se muestra viene de la base o de lo que la persona escribe: pasa por
   esc() antes de ir al DOM, sin excepción.

   Si el envío falla, NO se limpia nada: los valores quedan escritos en pantalla. */
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { esc } from './ui.js';

if (!window.supabase || !window.supabase.createClient) {
  throw new Error('supabase-js no cargó (revisar el <script> de jsdelivr en form.html).');
}

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
});

const root = document.getElementById('form-root');
const params = new URLSearchParams(location.search);
const fToken = params.get('f') || '';
const cToken = params.get('c') || '';

/* Los dos mensajes fijos de 004. Si la base devuelve otra cosa (caída de red,
   error inesperado), se muestra tal cual: son los únicos casos en que el texto
   no sale de esta lista. */
const MSG_LINK = 'Link inválido o formulario no disponible';

let form = null;          // { nombre_formulario, campos, nombre_cliente }
let valores = {};         // key -> valor escrito, sobrevive a un envío fallido
let enviando = false;

/* ---------- Pantallas ---------- */

function pantalla(titulo, texto) {
  root.innerHTML = `
    <div class="empty-state">
      <div class="big">${esc(titulo)}</div>
      ${texto ? `<div class="small">${esc(texto)}</div>` : ''}
    </div>`;
}

function gracias() {
  root.innerHTML = `
    <div class="empty-state pub-gracias">
      <div class="pub-tick" aria-hidden="true">✓</div>
      <div class="big">¡Listo, gracias!</div>
      <div class="small">Ya recibimos tus respuestas. Podés cerrar esta página.</div>
    </div>`;
}

/* ---------- Campos ---------- */

function idDe(key) {
  return 'c-' + key.replace(/[^A-Za-z0-9_-]/g, '_');
}

function control(c) {
  const id = idDe(c.key);
  const v = valores[c.key];
  const req = c.requerido ? ' required aria-required="true"' : '';
  switch (c.tipo) {
    case 'parrafo':
      return `<textarea id="${id}" data-k="${esc(c.key)}" rows="4" maxlength="2000"${req}>${esc(v || '')}</textarea>`;
    case 'numero':
      return `<input type="number" inputmode="decimal" step="any" id="${id}" data-k="${esc(c.key)}" value="${esc(v || '')}"${req}>`;
    case 'escala_0_10':
      return `<div class="pub-escala" role="group" aria-label="${esc(c.label)}">
        ${Array.from({ length: 11 }, (_, n) => `
          <button type="button" class="pub-esc-btn${String(v) === String(n) ? ' on' : ''}"
            data-k="${esc(c.key)}" data-valor="${n}" aria-pressed="${String(v) === String(n)}">${n}</button>`).join('')}
        <input type="hidden" id="${id}" data-k="${esc(c.key)}" value="${esc(v == null ? '' : v)}">
      </div>
      <div class="pub-escala-pie"><span>0 · nada</span><span>10 · muchísimo</span></div>`;
    case 'opcion':
      return `<div class="pub-opciones" role="group" aria-label="${esc(c.label)}">
        ${(c.opciones || []).map((o, i) => `
          <label class="pub-opcion">
            <input type="radio" name="${id}" data-k="${esc(c.key)}" value="${esc(o)}"
              ${String(v) === String(o) ? 'checked' : ''}${i === 0 ? req : ''}>
            <span>${esc(o)}</span>
          </label>`).join('')}
      </div>`;
    case 'si_no':
      return `<div class="pub-opciones" role="group" aria-label="${esc(c.label)}">
        ${[['si', 'Sí'], ['no', 'No']].map(([val, txt], i) => `
          <label class="pub-opcion">
            <input type="radio" name="${id}" data-k="${esc(c.key)}" value="${val}"
              ${String(v) === val ? 'checked' : ''}${i === 0 ? req : ''}>
            <span>${txt}</span>
          </label>`).join('')}
      </div>`;
    default:
      return `<input type="text" id="${id}" data-k="${esc(c.key)}" maxlength="300" value="${esc(v || '')}"${req}>`;
  }
}

function campoHtml(c) {
  return `
    <div class="pub-campo" data-campo="${esc(c.key)}">
      <label class="pub-label" for="${idDe(c.key)}">${esc(c.label)}${c.requerido ? ' <span class="pub-req" title="Obligatorio">*</span>' : ''}</label>
      ${control(c)}
      <div class="pub-error" data-error="${esc(c.key)}"></div>
    </div>`;
}

/* ---------- Render ---------- */

function pintarFormulario(avisoGeneral = '') {
  const campos = form.campos || [];
  root.innerHTML = `
    <div class="pub-head">
      <div class="pub-hola">Hola ${esc(form.nombre_cliente)} 👋</div>
      <h1 class="pub-titulo">${esc(form.nombre_formulario)}</h1>
      <div class="pub-sub">Tus respuestas las lee el equipo. Te lleva un minuto.</div>
    </div>
    ${avisoGeneral ? `<div class="pub-aviso" role="alert">${esc(avisoGeneral)}</div>` : ''}
    <form id="pub-form" novalidate>
      ${campos.map(campoHtml).join('')}
      <button type="submit" class="btn btn-accent pub-enviar">Enviar respuestas</button>
      <div class="pub-pie">No pedimos datos de tu cuenta ni de tu dinero. Solo lo que escribas acá.</div>
    </form>`;

  const f = root.querySelector('#pub-form');

  /* Cada cambio se guarda en memoria: si el envío falla y hay que repintar,
     no se pierde nada de lo escrito. */
  f.addEventListener('input', ev => {
    const k = ev.target.dataset.k;
    if (k) { valores[k] = ev.target.value; limpiarError(k); }
  });
  f.addEventListener('change', ev => {
    const k = ev.target.dataset.k;
    if (k) { valores[k] = ev.target.value; limpiarError(k); }
  });

  /* Escala 0 a 10: botones en vez de un select, para que se pueda tocar con el pulgar. */
  f.addEventListener('click', ev => {
    const b = ev.target.closest('.pub-esc-btn');
    if (!b) return;
    const k = b.dataset.k;
    valores[k] = b.dataset.valor;
    for (const otro of f.querySelectorAll(`.pub-esc-btn[data-k="${CSS.escape(k)}"]`)) {
      const on = otro === b;
      otro.classList.toggle('on', on);
      otro.setAttribute('aria-pressed', String(on));
    }
    const hidden = f.querySelector(`input[type="hidden"][data-k="${CSS.escape(k)}"]`);
    if (hidden) hidden.value = b.dataset.valor;
    limpiarError(k);
  });

  f.addEventListener('submit', ev => { ev.preventDefault(); enviar(); });
}

function limpiarError(key) {
  const el = root.querySelector(`[data-error="${CSS.escape(key)}"]`);
  if (el) el.textContent = '';
  const campo = root.querySelector(`[data-campo="${CSS.escape(key)}"]`);
  if (campo) campo.classList.remove('pub-campo-mal');
}

function marcarError(key, texto) {
  const el = root.querySelector(`[data-error="${CSS.escape(key)}"]`);
  if (el) el.textContent = texto;
  const campo = root.querySelector(`[data-campo="${CSS.escape(key)}"]`);
  if (campo) campo.classList.add('pub-campo-mal');
}

/* ---------- Validación en el navegador ----------
   Mismas reglas que cs_enviar_respuesta (004), pero acá SÍ se dice qué campo
   falló: la definición de los campos ya es pública. La base vuelve a validar
   todo; esto es para que la persona no tenga que adivinar. */
function validar() {
  let primero = null;
  for (const c of form.campos || []) {
    const bruto = valores[c.key];
    const v = typeof bruto === 'string' ? bruto.trim() : bruto;
    limpiarError(c.key);

    if (v == null || v === '') {
      if (c.requerido) { marcarError(c.key, 'Falta completar esto.'); primero = primero || c.key; }
      continue;
    }
    if (c.tipo === 'numero' && !/^-?\d+(\.\d+)?$/.test(v)) {
      marcarError(c.key, 'Poné un número.'); primero = primero || c.key;
    } else if (c.tipo === 'escala_0_10' && !(/^\d+(\.\d+)?$/.test(v) && Number(v) >= 0 && Number(v) <= 10)) {
      marcarError(c.key, 'Elegí un puntaje de 0 a 10.'); primero = primero || c.key;
    } else if (c.tipo === 'opcion' && !(c.opciones || []).includes(v)) {
      marcarError(c.key, 'Elegí una de las opciones.'); primero = primero || c.key;
    } else if (c.tipo === 'si_no' && v !== 'si' && v !== 'no') {
      marcarError(c.key, 'Elegí Sí o No.'); primero = primero || c.key;
    }
  }
  return primero;
}

/* Solo las keys del formulario y solo las contestadas. La base ignora el resto
   igual, pero no tiene sentido mandarlo. */
function armarPayload() {
  const out = {};
  for (const c of form.campos || []) {
    const bruto = valores[c.key];
    const v = typeof bruto === 'string' ? bruto.trim() : bruto;
    if (v != null && v !== '') out[c.key] = String(v);
  }
  return out;
}

/* ---------- Envío ---------- */

async function enviar() {
  if (enviando) return;
  const mal = validar();
  if (mal) {
    const el = root.querySelector(`[data-campo="${CSS.escape(mal)}"]`);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    return;
  }

  const btn = root.querySelector('.pub-enviar');
  enviando = true;
  if (btn) { btn.disabled = true; btn.textContent = 'Enviando…'; }

  const { error } = await sb.rpc('cs_enviar_respuesta', {
    p_form_token: fToken,
    p_cliente_token: cToken,
    p_respuestas: armarPayload()
  });

  enviando = false;
  if (!error) { gracias(); return; }

  /* Falló: se repinta el formulario CON todo lo que la persona escribió
     (valores no se toca en ningún momento) y el motivo arriba de todo. */
  pintarFormulario(mensajePublico(error));
  root.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

/* El texto que se le muestra a la persona. Los dos mensajes de 004 ya están
   escritos para ella; lo demás se traduce a algo entendible. */
function mensajePublico(error) {
  const msg = (error && error.message) || '';
  if (/^(Link inválido|Revisá los campos)/.test(msg)) return msg;
  if (/failed to fetch|networkerror/i.test(msg)) {
    return 'No se pudo conectar. Revisá tu internet y probá de nuevo: no perdiste nada de lo que escribiste.';
  }
  return 'No se pudo enviar. Probá de nuevo en un momento: no perdiste nada de lo que escribiste.';
}

/* ---------- Arranque ---------- */

async function iniciar() {
  if (!fToken || !cToken) { pantalla(MSG_LINK, 'Pedile el link de nuevo a quien te lo mandó.'); return; }

  const { data, error } = await sb.rpc('cs_form_publico', {
    p_form_token: fToken,
    p_cliente_token: cToken
  });

  if (error || !data) {
    const msg = (error && error.message) || MSG_LINK;
    pantalla(/failed to fetch|networkerror/i.test(msg) ? 'Sin conexión' : MSG_LINK,
             /failed to fetch|networkerror/i.test(msg)
               ? 'Revisá tu internet y volvé a abrir el link.'
               : 'Pedile el link de nuevo a quien te lo mandó.');
    return;
  }

  form = data;
  document.title = `${form.nombre_formulario} — Dystopia`;
  if (!(form.campos || []).length) { pantalla(MSG_LINK, 'Este formulario todavía no tiene preguntas.'); return; }
  pintarFormulario();
}

iniciar();
