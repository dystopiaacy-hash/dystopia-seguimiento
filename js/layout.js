/* Layout de la app interna (replica Dystopia): sidebar con marca, navegación
   y pie (email + Salir); header con título de la vista, "En vivo" y rol. */
import { esc } from './ui.js';
import { yo, esFundador, etiquetaRol } from './sesion.js';

/* Secciones de un programa: [sub-ruta, etiqueta, soloFundador] */
export const SECCIONES = [
  ['', 'Dashboard', false],
  ['clientes', 'Clientes', false],
  ['accionables', 'Accionables', false],
  ['devoluciones', 'Devoluciones', false],
  ['calls', 'Calls', false],
  ['renovaciones', 'Renovaciones', false],
  ['revision', 'Revisión', false],
  ['formularios', 'Formularios', false],
  ['metricas', 'Métricas', false],
  ['config', 'Configuración', true]
];

export function renderLayout(app, onSalir) {
  app.innerHTML = `
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">DYS<span>TOPIA</span></div>
        <div class="brand-sub">Seguimiento</div>
      </div>
      <nav class="nav-list" id="nav" aria-label="Navegación"></nav>
      <div class="sidebar-foot">
        <span id="user-email" title="${esc(yo.email)}">${esc(yo.email)}</span>
        <button type="button" class="refresh-btn" id="btn-logout">Salir</button>
      </div>
    </aside>
    <main class="main">
      <div class="main-inner">
        <header class="topbar view-head">
          <div class="client-head">
            <h1 id="view-title"></h1>
            <div class="consultora" id="view-sub"></div>
          </div>
          <div class="view-head-meta">
            <span class="live-pill" id="live" data-on="0" title="Conectando…"><span class="live-dot"></span>En vivo</span>
            <span class="badge">${esc(etiquetaRol())}</span>
          </div>
        </header>
        <div id="view"></div>
      </div>
    </main>`;
  document.getElementById('btn-logout').onclick = onSalir;
}

export function setHeader(titulo, sub = '') {
  document.getElementById('view-title').textContent = titulo || '';
  document.getElementById('view-sub').textContent = sub || '';
  document.title = titulo ? `${titulo} — Seguimiento` : 'Dystopia — Seguimiento';
}

/* estado = status del canal realtime de supabase-js. */
export function setLive(estado) {
  const el = document.getElementById('live');
  if (!el) return;
  const on = estado === 'SUBSCRIBED';
  el.dataset.on = on ? '1' : '0';
  el.title = on ? 'Conectado: los cambios aparecen solos'
    : estado === 'CONECTANDO' ? 'Conectando…'
    : 'Sin conexión en vivo: recargá la página si no vuelve';
}

function href(path) {
  return '#/' + path;
}

/* activo = { panel: true } | { programaId, sub } */
export function renderNav(activo = {}) {
  const nav = document.getElementById('nav');
  if (!nav) return;
  let html = '';
  if (esFundador()) {
    html += `
      <a class="nav-item${activo.panel ? ' active' : ''}" href="${href('panel')}">
        <span class="nav-icon">◆</span>
        <span class="nav-text"><div class="nav-name">Panel general</div><div class="nav-niche">Todos los programas</div></span>
      </a>`;
  }
  html += `<div class="nav-eyebrow">${yo.programas.length === 1 ? 'Programa' : 'Programas'}</div>`;
  for (const p of yo.programas) {
    const id = encodeURIComponent(p.id);
    const esEste = activo.programaId === p.id;
    html += `
      <a class="nav-item${esEste && !activo.sub ? ' active' : ''}${p.activo ? '' : ' inactivo'}" href="${href('p/' + id)}">
        <span class="nav-dot ${p.activo ? 'sem-verde' : 'sem-gris'}" title="${p.activo ? 'Activo' : 'Inactivo'}"></span>
        <span class="nav-text"><div class="nav-name">${esc(p.nombre)}</div><div class="nav-niche">${esc(p.activo ? (p.marca || 'Activo') : 'Inactivo')}</div></span>
      </a>`;
    if (esEste) {
      html += '<div class="nav-subs">';
      for (const [sub, label, soloFundador] of SECCIONES) {
        if (!sub || (soloFundador && !esFundador())) continue;
        html += `<a class="nav-sub${activo.sub === sub ? ' active' : ''}" href="${href('p/' + id + '/' + sub)}">${esc(label)}</a>`;
      }
      html += '</div>';
    }
  }
  nav.innerHTML = html;
}
