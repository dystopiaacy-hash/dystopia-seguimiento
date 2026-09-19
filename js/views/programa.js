/* Rutas de programa (#/p/:programa/...). En Fase 2 solo resuelven acceso y
   muestran el lugar de cada sección; el contenido llega en las fases siguientes. */
import { esc } from '../ui.js';
import { setHeader, SECCIONES } from '../layout.js';
import { esFundador } from '../sesion.js';

function vacio(big, small = '', extra = '') {
  return `<div class="card empty-state"><div class="big">${esc(big)}</div>${small ? `<div class="small">${esc(small)}</div>` : ''}${extra}</div>`;
}

/* p = fila de cs_programas visible para el usuario (o null). sub = '' | 'clientes' | ... */
export function vistaPrograma(el, { p, sub, clienteId }) {
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

  const aviso = !p.activo && sub !== 'config'
    ? `<div class="card aviso-inactivo">Este programa está <strong>inactivo</strong>.${esFundador()
        ? ` <a href="#/p/${encodeURIComponent(p.id)}/config">Configurarlo</a>`
        : ''}</div>`
    : '';

  el.innerHTML = aviso + vacio(clienteId ? 'Ficha de cliente' : label, 'Esta sección se construye en una fase siguiente.');
  return null;
}
