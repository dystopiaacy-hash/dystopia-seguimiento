/* "Satisfacción para enviar" de la pestaña Hoy (106): alumnos que llegaron a un momento del
   programa (fin de onboarding, mitad, N días antes de vencer...) y todavía no tienen el link
   enviado. "Copiar link" crea el link del alumno para ese momento y lo copia; "Marcar como
   enviado" lo saca de la lista. El envío lo hace el CSM a mano por WhatsApp: la app no manda
   nada al alumno. Los momentos se definen en la pestaña Satisfacción.
   Vive en su propio contenedor, como las altas. Sin la 106 (o si falla) no muestra nada. */
import { esc, toast, fmtFecha } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { traerPendientesSatisfaccion, linkSatisfaccion, marcarEnviado, urlSatisfaccion } from '../datos-satisfaccion.js';
import { mensajeCs } from '../datos-faltante.js';
import { copiar } from './formularios-links.js';

function fila(f, programaId, editar, ocupada) {
  const k = `${f.cliente_id}:${f.momento_id}`;
  const dis = ocupada ? ' disabled' : '';
  const acciones = editar ? `<div class="hoy-card-acc">
      <button type="button" class="btn btn-sm btn-accent" data-sat-copiar="${esc(k)}"${dis}>Copiar link</button>
      <button type="button" class="btn btn-sm" data-sat-enviado="${esc(k)}"${dis}>Marcar como enviado</button>
    </div>` : '';
  return `<article class="hoy-alta">
    <div class="hoy-card-main">
      <div class="hoy-card-top">
        <a class="cli-nombre" href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(f.cliente_id)}">${esc(f.nombre || 'Sin nombre')}</a>
        <span class="hoy-tipo">${esc(f.momento)}</span>
      </div>
      <div class="hoy-detalle">Llegó a este momento el ${esc(fmtFecha(f.hito_fecha))}${f.tiene_link ? ' · link generado, sin enviar' : ''}</div>
    </div>
    ${acciones}
  </article>`;
}

export function montarSatisfaccionHoy(box, programaId, vigente, alCambiar) {
  let filas = [], pedido = 0;
  const ocupadas = new Set();
  const editar = () => puedeEditarPrograma(programaId);

  function pintar() {
    if (!filas.length) { box.innerHTML = ''; return; }
    box.innerHTML = `<section class="hoy-grupo">
      <div class="section-title">Satisfacción para enviar <span class="hoy-grupo-n">${filas.length}</span><span class="line"></span></div>
      ${filas.map(f => fila(f, programaId, editar(), ocupadas.has(`${f.cliente_id}:${f.momento_id}`))).join('')}
    </section>`;
  }

  async function cargar() {
    const n = ++pedido;
    let datos = [];
    try {
      datos = (await traerPendientesSatisfaccion(programaId)) || [];
    } catch (e) {
      console.error('satisfacción hoy', e);
    }
    if (!vigente() || n !== pedido) return;
    filas = datos;
    pintar();
    alCambiar();
  }

  const buscar = k => filas.find(f => `${f.cliente_id}:${f.momento_id}` === k);

  box.addEventListener('click', async ev => {
    const bC = ev.target.closest('[data-sat-copiar]');
    const bE = ev.target.closest('[data-sat-enviado]');
    if (!bC && !bE) return;
    const f = buscar(bC ? bC.dataset.satCopiar : bE.dataset.satEnviado);
    if (!f || !editar()) return;
    const k = `${f.cliente_id}:${f.momento_id}`;
    ocupadas.add(k);
    pintar();
    try {
      const info = await linkSatisfaccion(f.cliente_id, f.momento_id);
      if (bC) {
        if (await copiar(urlSatisfaccion(info.token))) toast(`Link de ${f.nombre} copiado. Mandáselo por WhatsApp y marcalo como enviado.`);
        else toast(urlSatisfaccion(info.token));
      } else {
        await marcarEnviado(info.envio_id);
        toast('Marcado como enviado.');
      }
    } catch (e) {
      toast(mensajeCs(e), 'error');
    } finally {
      ocupadas.delete(k);
    }
    await cargar();
  });

  cargar();
  return { cantidad: () => filas.length, cargar };
}
