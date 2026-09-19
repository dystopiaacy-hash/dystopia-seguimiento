/* Punto de entrada de la app interna: gate de sesión, login, layout y router.
   Login y logout replican a Dystopia: signInWithPassword, mismo mensaje de error,
   logout = signOut + reload. */
import { sb } from './supabase.js';
import { esc } from './ui.js';
import { ruta, rutaNoEncontrada, iniciarRouter } from './router.js';
import { limpiar } from './state.js';

const app = document.getElementById('app');
let appIniciada = false;

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

function renderLayout(session) {
  app.innerHTML = `
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">DYS<span>TOPIA</span></div>
        <div class="brand-sub">Seguimiento de clientes</div>
      </div>
      <nav class="nav-list" id="nav"></nav>
      <div class="sidebar-foot">
        <span id="user-email">${esc(session.user.email)}</span>
        <button type="button" class="refresh-btn" id="btn-logout">Salir</button>
      </div>
    </aside>
    <main class="main"><div class="main-inner" id="view"></div></main>`;
  document.getElementById('btn-logout').onclick = async () => {
    limpiar();
    await sb.auth.signOut();
    location.reload();
  };
}

function registrarRutas() {
  const view = () => document.getElementById('view');
  ruta('', () => {
    view().innerHTML = `
      <div class="empty-state">
        <div class="big">Dystopia Seguimiento</div>
        <div class="small">Esqueleto (Fase 0). Las vistas se agregan en las fases siguientes.</div>
      </div>`;
  });
  rutaNoEncontrada(path => {
    view().innerHTML = `
      <div class="empty-state">
        <div class="big">No existe esta sección</div>
        <div class="small">${esc(path)} · <a href="#/">Volver al inicio</a></div>
      </div>`;
  });
}

async function iniciarApp() {
  if (appIniciada) return;
  appIniciada = true;
  app.innerHTML = '<div class="loading">Cargando…</div>';
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { appIniciada = false; renderLogin(); return; }
  renderLayout(session);
  registrarRutas();
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
