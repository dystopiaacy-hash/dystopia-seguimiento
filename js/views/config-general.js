/* Configuración general (#/config-general, bajo "Panel general"). Solo fundador: la ruta ya lo
   filtra (app.js) y las tablas lo vuelven a exigir con RLS. Acá van los ajustes que no son de un
   programa sino de toda la agencia: hoy, las cuentas de Fathom por consultor (programas habilitados,
   sincronización automática, "Sincronizar ahora" y "Traer historial completo"). */
import { esc } from '../ui.js';
import { esFundador } from '../sesion.js';
import { setHeader } from '../layout.js';
import { htmlFathom, montarFathom } from './config-fathom.js';

export function vistaConfigGeneral(el, vigente) {
  setHeader('Configuración general', 'Toda la agencia · solo el fundador');
  if (!esFundador()) {
    el.innerHTML = `<div class="card empty-state"><div class="big">Solo el fundador puede ver esta sección</div></div>`;
    return null;
  }
  el.innerHTML = `
    <div class="hint">Ajustes que no son de un programa. Los de cada programa (plazos, etapas, plantilla, avisos
      a Discord) están en la Configuración de ese programa.</div>
    ${htmlFathom()}`;
  montarFathom(el.querySelector('#cf-fathom'), vigente)
    .catch(e => {
      console.error('fathom', e);
      const box = el.querySelector('#cf-fathom');
      if (box) box.innerHTML = `<div class="hint">${esc((e && e.message) || 'No se pudo cargar Fathom.')}</div>`;
    });
  return null;
}
