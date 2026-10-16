/* Layout de la app interna (replica Dystopia): sidebar con marca, navegación
   y pie (email + Salir); header con título de la vista, "En vivo" y rol. */
import { esc } from './ui.js';
import { yo, esFundador, etiquetaRol, puedeGestionarFathom } from './sesion.js';
import { botonTemaHtml, activarBotonTema } from './tema.js';

/* Secciones de un programa: [sub-ruta, etiqueta, soloFundador, soloGestor]
   soloGestor (122): fundador o CSM, no cliente@ de solo lectura (hoy ninguna lo usa).
   "Llamadas" (124) la ve cualquiera con acceso al programa: la RLS decide qué filas. */
export const SECCIONES = [
  ['hoy', 'Hoy', false],
  ['', 'Dashboard', false],
  ['clientes', 'Clientes', false],
  ['maestro', 'Maestro', false],
  ['onboarding', 'Onboarding', false],
  ['accionables', 'Accionables', false],
  ['devoluciones', 'Devoluciones', false],
  ['calls', 'Calls', false],
  ['renovaciones', 'Renovaciones', false],
  ['revision', 'Revisión', false],
  ['satisfaccion', 'Satisfacción', false],
  ['dudas', 'Dudas frecuentes', false],
  ['llamadas', 'Llamadas', false],
  ['preguntar', 'Preguntale a la IA', false, true],
  ['formularios', 'Formularios', false],
  ['metricas', 'Métricas', false],
  ['config', 'Configuración', true]
];

/* Íconos lineales (24x24, trazo fino) de cada sección del programa. */
const ico = d => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
const ICONOS = {
  hoy: ico('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'),
  clientes: ico('<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6M16 4.5a3.5 3.5 0 0 1 0 7M18 14.3c2 .7 3.5 2.6 3.5 5.7"/>'),
  maestro: ico('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M9 4v16"/>'),
  onboarding: ico('<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>'),
  accionables: ico('<rect x="4" y="4" width="16" height="16" rx="3"/><path d="m8.5 12 2.5 2.5 4.5-5"/>'),
  devoluciones: ico('<path d="M9 14 4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>'),
  calls: ico('<path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z"/>'),
  renovaciones: ico('<path d="M20 11a8 8 0 0 0-14-4.5L4 9M4 4v5h5M4 13a8 8 0 0 0 14 4.5L20 15M20 20v-5h-5"/>'),
  revision: ico('<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>'),
  satisfaccion: ico('<path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.5l6.1-.9z"/>'),
  dudas: ico('<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7M12 17h.01"/>'),
  llamadas: ico('<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>'),
  preguntar: ico('<path d="M4 5h16v11H9l-5 4z"/>'),
  formularios: ico('<path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5M9 13h7M9 17h5"/>'),
  metricas: ico('<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>'),
  config: ico('<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>'),
  panel: ico('<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>'),
  dashboard: ico('<path d="M3 12a9 9 0 0 1 18 0"/><path d="m12 12 4-4"/><path d="M5 20h14"/>')
};
const iconoSub = sub => ICONOS[sub || 'dashboard'] || '';

export function renderLayout(app, onSalir) {
  const inicial = esc((yo.nombre || yo.email || '?').trim().charAt(0));
  app.innerHTML = `
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-logo" aria-hidden="true">D</div>
        <div class="brand-txt">
          <div class="brand-mark">DYS<span>TOPIA</span></div>
          <div class="brand-sub">Producto</div>
        </div>
      </div>
      <nav id="nav-areas"></nav>
      <div class="perfil" title="${esc(yo.email)}">
        <div class="perfil-avatar" aria-hidden="true">${inicial}</div>
        <div class="perfil-txt">
          <div class="perfil-nombre" id="user-email">${esc(yo.nombre || yo.email)}</div>
          <div class="perfil-dato">${esc(etiquetaRol())}</div>
        </div>
      </div>
      <nav class="nav-list" id="nav" aria-label="Navegación"></nav>
      <div class="sidebar-foot">
        <div class="sidebar-foot-acc">
          ${botonTemaHtml()}
          <button type="button" class="refresh-btn" id="btn-logout">Salir</button>
        </div>
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
  activarBotonTema();
}

export function setHeader(titulo, sub = '') {
  document.getElementById('view-title').textContent = titulo || '';
  document.getElementById('view-sub').textContent = sub || '';
  document.title = titulo ? `${titulo} — Producto` : 'Dystopia — Producto';
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

/* activo = { panel: true } | { configGeneral: true } | { programaId, sub } */
export function renderNav(activo = {}) {
  const nav = document.getElementById('nav');
  if (!nav) return;
  let html = '';
  if (esFundador()) {
    html += `
      <a class="nav-item${activo.panel ? ' active' : ''}" href="${href('panel')}">
        <span class="nav-icon">${ICONOS.panel}</span>
        <span class="nav-text"><div class="nav-name">Panel general</div><div class="nav-niche">Todos los programas</div></span>
      </a>
      <div class="nav-subs">
        <a class="nav-sub${activo.configGeneral ? ' active' : ''}" href="${href('config-general')}">${ICONOS.config}Configuración general</a>
      </div>`;
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
      for (const [sub, label, soloFundador, soloGestor] of SECCIONES) {
        if (!sub || (soloFundador && !esFundador()) || (soloGestor && !puedeGestionarFathom())) continue;
        html += `<a class="nav-sub${activo.sub === sub ? ' active' : ''}" href="${href('p/' + id + '/' + sub)}">${iconoSub(sub)}${esc(label)}</a>`;
      }
      html += '</div>';
    }
  }
  nav.innerHTML = html;
}
