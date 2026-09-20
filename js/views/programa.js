/* Rutas de programa (#/p/:programa/...): resuelve acceso, pinta las pestañas del
   programa y delega en la vista de cada sección. Las secciones que todavía no se
   construyeron muestran su lugar. */
import { esc } from '../ui.js';
import { setHeader, SECCIONES } from '../layout.js';
import { esFundador } from '../sesion.js';
import { vistaDashboard } from './dashboard.js';
import { vistaClientes } from './clientes.js';
import { vistaFicha } from './ficha.js';
import { vistaAccionables } from './accionables.js';
import { vistaDevoluciones } from './devoluciones.js';
import { vistaCalls } from './calls.js';
import { vistaRenovaciones } from './renovaciones.js';
import { vistaConfig } from './config.js';

export function vacio(big, small = '', extra = '') {
  return `<div class="card empty-state"><div class="big">${esc(big)}</div>${small ? `<div class="small">${esc(small)}</div>` : ''}${extra}</div>`;
}

export function tarjetaError(titulo, e) {
  return `<div class="card empty-state"><div class="big">${esc(titulo)}</div><div class="small">${esc(e)}</div></div>`;
}

/* Pestañas del programa. Van arriba del contenido (son navegación, no contenido):
   abajo de todo quedarían fuera de la vista en el dashboard. */
export function tabsPrograma(programaId, sub) {
  const id = encodeURIComponent(programaId);
  let html = '<nav class="tabs tabs-prog" aria-label="Secciones del programa">';
  for (const [s, label, soloFundador] of SECCIONES) {
    if (soloFundador && !esFundador()) continue;
    const href = '#/p/' + id + (s ? '/' + s : '');
    html += `<a class="tab-btn${sub === s ? ' active' : ''}" href="${href}">${esc(label)}</a>`;
  }
  return html + '</nav>';
}

/* p = fila de cs_programas visible para el usuario (o null). sub = '' | 'clientes' | ...
   Devuelve { refrescar } cuando la vista sabe refrescarse sola (realtime). */
export function vistaPrograma(el, { p, sub, clienteId, vigente }) {
  if (!p) {
    setHeader('Programa no encontrado');
    el.innerHTML = vacio('No existe este programa o no tenés acceso.', '', '<div class="small"><a href="#/">Volver al inicio</a></div>');
    return null;
  }

  const seccion = SECCIONES.find(s => s[0] === sub);
  if (!seccion) {
    setHeader(p.nombre, p.marca || '');
    el.innerHTML = vacio('No existe esta sección.');
    return null;
  }
  const [, label, soloFundador] = seccion;
  setHeader(p.nombre, clienteId ? 'Ficha de cliente' : `${p.marca ? p.marca + ' · ' : ''}${label}`);

  if (soloFundador && !esFundador()) {
    el.innerHTML = vacio('Solo el fundador puede ver esta sección.');
    return null;
  }

  const tabs = tabsPrograma(p.id, sub);
  const aviso = !p.activo && sub !== 'config'
    ? `<div class="card aviso-inactivo">Este programa está <strong>inactivo</strong>.${esFundador()
        ? ` <a href="#/p/${encodeURIComponent(p.id)}/config">Configurarlo</a>`
        : ''}</div>`
    : '';

  el.innerHTML = tabs + aviso + '<div id="seccion"><div class="loading-inline">Cargando…</div></div>';
  const cont = el.querySelector('#seccion');

  if (clienteId) return vistaFicha(cont, p, clienteId, vigente);
  if (sub === '') return vistaDashboard(cont, p.id, vigente);
  if (sub === 'clientes') return vistaClientes(cont, p.id, vigente);
  if (sub === 'accionables') return vistaAccionables(cont, p.id, vigente);
  if (sub === 'devoluciones') return vistaDevoluciones(cont, p.id, vigente);
  if (sub === 'calls') return vistaCalls(cont, p.id, vigente);
  if (sub === 'renovaciones') return vistaRenovaciones(cont, p.id, vigente);
  if (sub === 'config') return vistaConfig(cont, p.id, vigente);

  cont.innerHTML = vacio(label, 'Esta sección se construye en una fase siguiente.');
  return null;
}
