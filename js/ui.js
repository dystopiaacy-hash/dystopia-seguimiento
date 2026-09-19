/* Utilidades de UI compartidas: escape, fechas de negocio, formatos, badges, semáforo, modal, toast.
   REGLA: todo dato que venga de la base o de formularios pasa por esc() antes de ir al DOM. */
import { TZ } from './config.js';

/* ---------- Escape (misma función que Dystopia) ---------- */
export function esc(s) {
  return (s == null ? '' : String(s)).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* Solo http(s): evita javascript: y data: en href armados con datos de la base (links de Loom, etc.). */
export function urlSegura(u) {
  try {
    const url = new URL(String(u));
    return (url.protocol === 'https:' || url.protocol === 'http:') ? url.href : '';
  } catch { return ''; }
}

/* ---------- Fechas de negocio (America/Argentina/Buenos_Aires) ---------- */
const fmtISO = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' });
const fmtCorta = new Intl.DateTimeFormat('es-AR', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric' });
const fmtHora = new Intl.DateTimeFormat('es-AR', { timeZone: TZ, day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false });

/* 'YYYY-MM-DD' de hoy en Buenos Aires. */
export function hoyAR() {
  return fmtISO.format(new Date());
}

/* Normaliza a 'YYYY-MM-DD' en Buenos Aires. Un 'YYYY-MM-DD' (columna date) se devuelve tal cual. */
export function fechaISO_AR(v) {
  if (!v) return '';
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
  const d = v instanceof Date ? v : new Date(v);
  return isNaN(d) ? '' : fmtISO.format(d);
}

function aDiaUTC(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  return Date.UTC(y, m - 1, d);
}

/* Días calendario de a -> b (fechas de negocio). Positivo si b es posterior. */
export function diasEntre(a, b) {
  const ia = fechaISO_AR(a), ib = fechaISO_AR(b);
  if (!ia || !ib) return null;
  return Math.round((aDiaUTC(ib) - aDiaUTC(ia)) / 86400000);
}

/* Días desde hoy hasta la fecha. Negativo = vencido. */
export function diasRestantes(fecha) {
  return diasEntre(hoyAR(), fecha);
}

export function sumarDias(fecha, n) {
  const iso = fechaISO_AR(fecha);
  if (!iso) return '';
  return new Date(aDiaUTC(iso) + n * 86400000).toISOString().slice(0, 10);
}

/* dd/mm/aaaa. Un 'YYYY-MM-DD' se formatea sin pasar por Date (no se corre de día). */
export function fmtFecha(v) {
  if (!v) return '—';
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)) {
    const [y, m, d] = v.split('-');
    return `${d}/${m}/${y}`;
  }
  const d = new Date(v);
  return isNaN(d) ? '—' : fmtCorta.format(d);
}

export function fmtFechaHora(v) {
  if (!v) return '—';
  const d = new Date(v);
  return isNaN(d) ? '—' : fmtHora.format(d);
}

/* ---------- Números ---------- */
const fmtN = new Intl.NumberFormat('es-AR');
export function fmtNum(n) {
  return n == null || isNaN(n) ? '—' : fmtN.format(n);
}
export function fmtPct(n, dec = 0) {
  return n == null || isNaN(n) ? '—' : `${Number(n).toFixed(dec).replace('.', ',')}%`;
}
export function plural(n, uno, varios) {
  return `${n} ${n === 1 ? uno : (varios || uno + 's')}`;
}

/* ---------- Badges ---------- */
/* color: cualquier valor CSS (hex o var(--x)). variante: '' | 'status' | 'outline' | 'solid'. */
export function badge(texto, color, variante = '') {
  const clases = ['badge'];
  if (variante) clases.push('badge-status');
  if (variante === 'outline') clases.push('badge-outline');
  if (variante === 'solid') clases.push('badge-solid');
  const estilo = color ? ` style="--badge-color:${esc(color)}"` : '';
  return `<span class="${clases.join(' ')}"${estilo}>${esc(texto)}</span>`;
}

/* ---------- Semáforo ---------- */
export const SEMAFORO = { verde: 'verde', amarillo: 'amarillo', rojo: 'rojo', gris: 'gris' };

export function semaforo(nivel, texto) {
  const n = SEMAFORO[nivel] || 'gris';
  return `<span class="badge badge-status sem-${n}">${esc(texto == null ? '' : texto)}</span>`;
}

export function semaforoDot(nivel, titulo) {
  const n = SEMAFORO[nivel] || 'gris';
  const t = titulo ? ` title="${esc(titulo)}"` : '';
  return `<span class="sem-dot sem-${n}"${t}></span>`;
}

/* Nivel por días restantes. Umbrales por defecto; cada programa podrá definir los suyos. */
export function nivelPorDias(dias, { amarillo = 14, rojo = 0 } = {}) {
  if (dias == null) return 'gris';
  if (dias <= rojo) return 'rojo';
  if (dias <= amarillo) return 'amarillo';
  return 'verde';
}

/* ---------- Toast ---------- */
export function toast(msg, tipo = '') {
  const el = document.createElement('div');
  el.className = 'toast' + (tipo === 'error' ? ' toast-error' : '');
  el.setAttribute('role', 'status');
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), tipo === 'error' ? 4000 : 2600);
}

/* ---------- Modal ---------- */
/* cuerpo y pie son HTML ya armado por quien llama (con esc() aplicado a los datos).
   El título se escapa acá. Devuelve { el, cerrar }. */
let modalActual = null;

export function abrirModal({ titulo = '', cuerpo = '', pie = '', ancho = false, alCerrar = null } = {}) {
  cerrarModal();
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="modal-box${ancho ? ' wide' : ''}" role="dialog" aria-modal="true" aria-label="${esc(titulo)}">
      <div class="modal-head"><h2>${esc(titulo)}</h2><button type="button" class="modal-close" aria-label="Cerrar">✕</button></div>
      <div class="modal-body">${cuerpo}</div>
      ${pie ? `<div class="modal-foot">${pie}</div>` : ''}
    </div>`;
  const onKey = e => { if (e.key === 'Escape') cerrar(); };
  function cerrar() {
    if (!overlay.isConnected) return;
    overlay.remove();
    document.removeEventListener('keydown', onKey);
    if (modalActual && modalActual.el === overlay) modalActual = null;
    if (alCerrar) alCerrar();
  }
  overlay.addEventListener('mousedown', e => { if (e.target === overlay) cerrar(); });
  overlay.querySelector('.modal-close').addEventListener('click', cerrar);
  document.addEventListener('keydown', onKey);
  document.body.appendChild(overlay);
  modalActual = { el: overlay, cerrar };
  return modalActual;
}

export function cerrarModal() {
  if (modalActual) modalActual.cerrar();
}

export function hayModalAbierto() {
  return !!modalActual;
}
