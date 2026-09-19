/* Punto de entrada de la app interna: gate de sesión, login, rol, layout y router.
   Login y logout replican a Dystopia: signInWithPassword, mismo mensaje de error,
   logout = signOut + reload. */
import { sb } from './supabase.js';
import { esc } from './ui.js';
import { ruta, rutaNoEncontrada, iniciarRouter, reemplazar, resolver } from './router.js';
import { limpiar, suscribir, onChange } from './state.js';
import { yo, cargarSesion, cargarProgramas, esFundador, programa, rutaInicio } from './sesion.js';
import { renderLayout, renderNav, setHeader, setLive } from './layout.js';
import { vistaPanel } from './views/panel.js';
import { vistaPrograma } from './views/programa.js';

const app = document.getElementById('app');
let appIniciada = false;
let rutasRegistradas = false;
let escuchandoCambios = false;

/* Tablas que escucha el realtime (cs_integraciones queda afuera a propósito). */
const TABLAS_RT = ['cs_programas', 'cs_clientes', 'cs_accionables', 'cs_devoluciones', 'cs_calls',
  'cs_renovaciones', 'cs_formularios', 'cs_respuestas', 'cs_chequeos', 'cs_alertas'];

async function salir() {
  limpiar();
  await sb.auth.signOut();
  location.reload();
}

function renderLogin() {
  app.innerHTML = `
    <div class="login-wrap">
      <form id="login-form" class="card login-card">
        <div class="brand-mark">DYS<span>TOPIA</span></div>
        <div class="form-row"><label for="login-email">Email</label><input id="login-email" type="email" autocomplete="username" required></div>
        <div class="form-row"><label for="login-password">Contraseña</label><input id="login-password" type="password" autocomplete="current-password" required></div>
        <div id="login-error" class="login-error"></div>
        <button type="submit" class="btn btn-accent">Ingresar</button>
      </form>
    </div>`;
  const form = document.getElementById('login-form');
  form.onsubmit = async ev => {
    ev.preventDefault();
    const errEl = document.getElementById('login-error');
    const btn = form.querySelector('button[type=submit]');
    errEl.textContent = '';
    btn.disabled = true;
    const { error } = await sb.auth.signInWithPassword({
      email: document.getElementById('login-email').value.trim(),
      password: document.getElementById('login-password').value
    });
    if (error) {
      errEl.textContent = error.message === 'Invalid login credentials' ? 'Email o contraseña incorrectos.' : error.message;
      btn.disabled = false;
      return;
    }
    iniciarApp();
  };
  document.getElementById('login-email').focus();
}

/* Pantalla sin layout para: sin acceso, o error al cargar la sesión. */
function renderAviso(titulo, texto, { reintentar = false } = {}) {
  app.innerHTML = `
    <div class="login-wrap">
      <div class="card login-card aviso-card">
        <div class="brand-mark">DYS<span>TOPIA</span></div>
        <div class="aviso-titulo">${esc(titulo)}</div>
        <p class="aviso-texto">${esc(texto)}</p>
        <div class="aviso-acciones">
          ${reintentar ? '<button type="button" class="btn" id="btn-reintentar">Reintentar</button>' : ''}
          <button type="button" class="btn btn-accent" id="btn-salir">Salir</button>
        </div>
      </div>
    </div>`;
  document.getElementById('btn-salir').onclick = salir;
  const r = document.getElementById('btn-reintentar');
  if (r) r.onclick = () => location.reload();
}

/* ---------- Vistas y refresco en vivo ---------- */
let genVista = 0;
let vista = null;   // { refrescar } de la vista actual, si tiene

function montar(render) {
  const gen = ++genVista;
  const vigente = () => gen === genVista;
  vista = render(document.getElementById('view'), vigente) || null;
}

/* Muchos eventos juntos (un trigger que toca 5 filas) = un solo refresco. */
let timerRefresco = null;
let programasCambiaron = false;
function programarRefresco(tabla) {
  if (tabla === 'cs_programas') programasCambiaron = true;
  clearTimeout(timerRefresco);
  timerRefresco = setTimeout(async () => {
    if (programasCambiaron) {
      programasCambiaron = false;
      try { await cargarProgramas(); } catch (e) { console.error('programas', e); }
      resolver();
      return;
    }
    if (vista && vista.refrescar) vista.refrescar();
  }, 500);
}

function registrarRutas() {
  if (rutasRegistradas) return;
  rutasRegistradas = true;

  ruta('', () => reemplazar(rutaInicio()));

  ruta('panel', () => {
    if (!esFundador()) return reemplazar(rutaInicio());
    renderNav({ panel: true });
    montar((el, vigente) => vistaPanel(el, vigente));
  });

  const irPrograma = (params, sub = '') => {
    const p = programa(params.programa);
    renderNav({ programaId: p && p.id, sub: params.clienteId ? 'clientes' : sub });
    montar(el => vistaPrograma(el, { p, sub: params.clienteId ? 'clientes' : sub, clienteId: params.clienteId }));
  };
  ruta('p/:programa', params => irPrograma(params));
  ruta('p/:programa/c/:clienteId', params => irPrograma(params));
  ruta('p/:programa/:sub', params => irPrograma(params, params.sub));

  rutaNoEncontrada(path => {
    renderNav({});
    setHeader('No existe esta sección');
    montar(el => {
      el.innerHTML = `
        <div class="card empty-state">
          <div class="big">No existe esta sección</div>
          <div class="small">${esc(path)} · <a href="#/">Volver al inicio</a></div>
        </div>`;
    });
  });
}

async function iniciarApp() {
  if (appIniciada) return;
  appIniciada = true;
  app.innerHTML = '<div class="loading">Cargando…</div>';
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { appIniciada = false; renderLogin(); return; }

  let puede;
  try {
    puede = await cargarSesion(session.user);
  } catch (e) {
    console.error('sesion', e);
    renderAviso('No se pudo cargar tu sesión', e.message || String(e), { reintentar: true });
    return;
  }
  if (!puede) {
    renderAviso('Sin acceso a esta app',
      `${yo.email} no tiene acceso a Seguimiento. Si creés que es un error, pedíselo al fundador.`);
    return;
  }

  renderLayout(app, salir);
  registrarRutas();
  setLive('CONECTANDO');
  suscribir(TABLAS_RT, setLive);
  if (!escuchandoCambios) { onChange(tabla => programarRefresco(tabla)); escuchandoCambios = true; }
  iniciarRouter();
}

/* Si la sesión se cierra (en otra pestaña o por expiración), volver al login. */
sb.auth.onAuthStateChange(evento => {
  if (evento === 'SIGNED_OUT' && appIniciada) {
    appIniciada = false;
    limpiar();
    renderLogin();
  }
});

(async function init() {
  const { data: { session } } = await sb.auth.getSession();
  if (session) iniciarApp(); else renderLogin();
})();
