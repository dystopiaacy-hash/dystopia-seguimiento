/* Aviso de "ventas esperando alta como cliente" (cs_altas_pendientes, 070).
   Se muestra en Dashboard, Clientes y Panel general: sin alta, el programa se ve
   vacío y "al día" aunque haya ventas en la cola de Hoy. Las altas se crean en
   Hoy > Clientes nuevos (hoy-altas.js); acá solo se cuenta y se linkea.
   Nunca tira: si falta la 070 o la RPC falla, devuelve null y no se muestra nada. */
import { esc, plural } from '../ui.js';
import { traerAltasPendientes } from '../datos-hoy.js';

export async function contarAltasPendientes(programaId) {
  try {
    return (await traerAltasPendientes(programaId)).length;
  } catch (e) {
    return null;
  }
}

/* nombre: se agrega al texto cuando el aviso es de un programa dentro del panel general. */
export function avisoAltasHtml(programaId, cantidad, nombre = '') {
  if (!cantidad) return '';
  const href = '#/p/' + encodeURIComponent(programaId) + '/hoy';
  const texto = `${plural(cantidad, 'venta esperando', 'ventas esperando')} alta como cliente`
    + (nombre ? ` en ${nombre}` : '');
  return `<a class="aviso-altas" href="${esc(href)}" role="status">
      <strong>${esc(texto)}</strong>
      <span>Todavía no figuran como clientes. Se crean en Hoy, sección "Clientes nuevos".</span>
      <span class="aviso-altas-ir">Ir a Hoy →</span>
    </a>`;
}
