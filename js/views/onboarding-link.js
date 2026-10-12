/* Botón "Link de onboarding": crea (o muestra) el link del alumno y lo copia.
   Lo usan la ficha y "Clientes nuevos". Si el navegador no deja copiar solo,
   el link queda en un cuadro seleccionado para copiarlo a mano. */
import { esc, abrirModal, cerrarModal, toast, fmtFecha } from '../ui.js';
import { mensajeError } from '../datos.js';
import { linkOnboarding, urlOnboarding } from '../datos-onboarding.js';
import { copiar } from './formularios-links.js';

/* Las RPC de la 093 traen el mensaje en castellano ("cs: ..."). */
export const mensajeOnboarding = e =>
  /^cs: /.test((e && e.message) || '') ? e.message.slice(4) : mensajeError(e);

function modalLink(url, info) {
  abrirModal({
    titulo: 'Link de onboarding',
    cuerpo: `
      <p class="hint">${info.estado === 'completado'
        ? 'Este alumno ya completó el onboarding: el link solo le muestra que está completo.'
        : 'Mandáselo al alumno por WhatsApp. Es personal: las respuestas quedan en su ficha.'}</p>
      <input type="text" id="onb-url" readonly value="${esc(url)}" aria-label="Link de onboarding"
        style="width:100%;font-family:var(--font-mono);font-size:var(--fs-meta);padding:var(--sp-2) var(--sp-3)">
      <p class="hint">Vence el ${esc(fmtFecha(String(info.vence_at).slice(0, 10)))}.</p>`,
    pie: '<button type="button" class="btn btn-accent" data-cerrar="1">Listo</button>'
  });
  const b = document.querySelector('[data-cerrar="1"]');
  if (b) b.onclick = cerrarModal;
  const inp = document.getElementById('onb-url');
  if (inp) { inp.focus(); inp.select(); }
}

/* Devuelve { url, info } o null si falló (el aviso ya se mostró). */
export async function generarYCopiar(clienteId, nombre = '') {
  try {
    const info = await linkOnboarding(clienteId);
    const url = urlOnboarding(info.token);
    if (await copiar(url)) {
      toast(`Link de onboarding${nombre ? ' de ' + nombre : ''} copiado${info.creado ? ' (recién creado)' : ''}.`);
    } else {
      modalLink(url, info);
    }
    return { url, info };
  } catch (e) {
    toast(mensajeOnboarding(e), 'error');
    return null;
  }
}
