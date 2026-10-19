/* Configuración general (#/config-general, bajo "Panel general"). Solo fundador: la ruta ya lo
   filtra (app.js) y las tablas lo vuelven a exigir con RLS. Acá van los ajustes que no son de un
   programa sino de toda la agencia: hoy, las cuentas de Fathom por consultor (programas habilitados,
   sincronización automática, "Sincronizar ahora" y "Traer historial completo") y los horarios de las
   consultorías grupales (157). */
import { esc } from '../ui.js';
import { esFundador } from '../sesion.js';
import { setHeader } from '../layout.js';
import { htmlFathom, montarFathom } from './config-fathom.js';
import { htmlFathomEquipo, montarFathomEquipo } from './config-fathom-equipo.js';   // 193
import { htmlConsultorias, montarConsultorias } from './config-consultorias.js';   // 157

export function vistaConfigGeneral(el, vigente) {
  setHeader('Configuración general', 'Toda la agencia · solo el fundador');
  if (!esFundador()) {
    el.innerHTML = `<div class="card empty-state"><div class="big">Solo el fundador puede ver esta sección</div></div>`;
    return null;
  }
  el.innerHTML = `
    <div class="hint">Ajustes que no son de un programa. Los de cada programa (plazos, etapas, plantilla, avisos
      a Discord) están en la Configuración de ese programa.</div>
    ${htmlFathom()}
    ${htmlFathomEquipo()}
    ${htmlConsultorias()}`;
  montarFathomEquipo(el.querySelector('#cf-fathom-equipo'), vigente)
    .catch(e => {
      console.error('fathom equipo', e);
      const box = el.querySelector('#cf-fathom-equipo');
      if (box) box.innerHTML = `<div class="hint">${esc((e && e.message) || 'No se pudo cargar el equipo.')}</div>`;
    });
  montarFathom(el.querySelector('#cf-fathom'), vigente)
    .catch(e => {
      console.error('fathom', e);
      const box = el.querySelector('#cf-fathom');
      if (box) box.innerHTML = `<div class="hint">${esc((e && e.message) || 'No se pudo cargar Fathom.')}</div>`;
    });
  montarConsultorias(el.querySelector('#cf-consultorias'), vigente)
    .catch(e => {
      console.error('consultorias', e);
      const box = el.querySelector('#cf-consultorias');
      if (box) box.innerHTML = `<div class="hint">${esc((e && e.message) || 'No se pudieron cargar las consultorías.')}</div>`;
    });
  return null;
}
