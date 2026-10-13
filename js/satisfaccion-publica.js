/* Página pública de satisfacción (satisfaccion.html?t=<token de 64 hex>).
   Sin login. Lo único que hace contra la base son las dos RPC de la migración 106:
   cs_satisf_estado y cs_satisf_responder. No lee ninguna tabla y no puede leer nada más.
   Una sola respuesta por link: el servidor rechaza la segunda.

   Cliente de supabase propio con persistSession en false: aunque quien abra el link esté
   logueado en la app (mismo origen), esta página siempre entra como anon.
   Todo lo que viene de la base pasa por esc() antes de ir al DOM. */
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { esc } from './ui.js';

if (!window.supabase || !window.supabase.createClient) {
  throw new Error('supabase-js no cargó (revisar el <script> de jsdelivr en satisfaccion.html).');
}

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
});

const root = document.getElementById('sat-root');
const token = (new URLSearchParams(location.search).get('t') || '').trim().toLowerCase();

function mensajeError(error) {
  const msg = (error && error.message) || '';
  if (error && error.code === 'P0001' && msg) return msg;
  if (/failed to fetch|networkerror|load failed/i.test(msg)) {
    return 'No se pudo conectar. Revisá tu internet y probá de nuevo: no perdiste lo que escribiste.';
  }
  return 'No se pudo enviar. Probá de nuevo en un momento.';
}

function pantalla(titulo, texto) {
  root.innerHTML = `<div class="sat-fin"><h1>${esc(titulo)}</h1><p>${esc(texto)}</p></div>`;
}

function formulario(info) {
  const nombre = info.alumno ? `, ${info.alumno}` : '';
  root.innerHTML = `
    <form id="sat-form" novalidate>
      <div class="sat-head">
        <div class="sat-programa">${esc(info.programa || '')}</div>
        <h1>¿Cómo vas${esc(nombre)}?</h1>
        <p class="sat-sub">Son tres preguntas y tu respuesta nos ayuda a mejorar${info.momento ? ` (${esc(info.momento)})` : ''}.</p>
      </div>

      <fieldset class="sat-campo">
        <legend>Del 1 al 10, ¿qué tan satisfecho/a estás hasta ahora? *</legend>
        <div class="sat-escala" role="radiogroup" aria-label="Puntaje de 1 a 10">
          ${Array.from({ length: 10 }, (_, i) => `
            <label class="sat-num"><input type="radio" name="puntaje" value="${i + 1}"><span>${i + 1}</span></label>`).join('')}
        </div>
        <div class="sat-extremos"><span>Nada</span><span>Muchísimo</span></div>
      </fieldset>

      <div class="form-row"><label for="sat-mejor">¿Qué fue lo mejor hasta ahora?</label>
        <textarea id="sat-mejor" name="mejor" rows="3" maxlength="2000"></textarea></div>
      <div class="form-row"><label for="sat-mejorar">¿Qué mejorarías?</label>
        <textarea id="sat-mejorar" name="mejorar" rows="3" maxlength="2000"></textarea></div>

      <fieldset class="sat-campo">
        <legend>¿Darías un testimonio sobre tu experiencia? *</legend>
        <div class="sat-opciones">
          <label class="sat-op"><input type="radio" name="testimonio" value="si"><span>Sí</span></label>
          <label class="sat-op"><input type="radio" name="testimonio" value="no"><span>No</span></label>
        </div>
      </fieldset>

      <div id="sat-error" class="login-error" role="alert"></div>
      <button type="submit" class="btn btn-accent sat-enviar" id="sat-enviar">Enviar</button>
    </form>`;

  const form = document.getElementById('sat-form');
  const err = t => { document.getElementById('sat-error').textContent = t; };
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    const puntaje = form.elements.puntaje.value;
    const testimonio = form.elements.testimonio.value;
    if (!puntaje) return err('Elegí un puntaje del 1 al 10.');
    if (!testimonio) return err('Contanos si darías un testimonio.');
    err('');
    const boton = document.getElementById('sat-enviar');
    boton.disabled = true;
    const { error } = await sb.rpc('cs_satisf_responder', {
      p_token: token, p_puntaje: Number(puntaje),
      p_mejor: form.elements.mejor.value, p_mejorar: form.elements.mejorar.value,
      p_testimonio: testimonio === 'si'
    });
    if (error) {
      boton.disabled = false;
      err(mensajeError(error));
      return;
    }
    pantalla('¡Gracias!', 'Recibimos tu respuesta.');
  });
}

async function iniciar() {
  if (!/^[0-9a-f]{64}$/.test(token)) {
    return pantalla('Link inválido', 'Revisá que el link esté completo o pedinos uno nuevo.');
  }
  const { data, error } = await sb.rpc('cs_satisf_estado', { p_token: token });
  if (error) {
    return pantalla('No se pudo abrir', 'Probá de nuevo en un momento.');
  }
  if (!data || !data.valido) {
    return pantalla('Link inválido', 'Revisá que el link esté completo o pedinos uno nuevo.');
  }
  if (data.respondido) {
    return pantalla('Ya lo respondiste', 'Gracias, tu respuesta ya quedó registrada.');
  }
  formulario(data);
}

iniciar().catch(() => pantalla('No se pudo abrir', 'Probá de nuevo en un momento.'));
