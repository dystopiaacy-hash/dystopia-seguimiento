/* Ficha de cliente — satisfacción por etapa (106).
   Una fila por momento activo del programa con el estado del link de este alumno
   (sin link / sin enviar / enviado / respondido) y, abajo, las respuestas anteriores de
   momentos que ya no están activos. "Copiar link" crea el link si no existe y lo copia;
   el envío al alumno lo hace el CSM a mano por WhatsApp ("Marcar como enviado").
   ctx.satisfaccion = { momentos, envios } (undefined = 106 sin correr: no se muestra). */
import { esc, fmtFecha, toast } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { guardar } from './comunes.js';
import { copiar } from './formularios-links.js';
import { linkSatisfaccion, marcarEnviado, textoMomento, urlSatisfaccion } from '../datos-satisfaccion.js';
import { mensajeCs } from '../datos-faltante.js';
import { nivelPuntaje } from './estado-columnas.js';

const dia = ts => fmtFecha(String(ts).slice(0, 10));

function respuesta(e) {
  return `<div class="sat-resp">
      <span class="ll-sem"><span class="sem-dot sem-${nivelPuntaje(e.puntaje)}"></span><strong>${esc(e.puntaje)}/10</strong></span>
      <span class="hint">${esc(dia(e.respondido_at))} · ${e.testimonio ? 'daría testimonio' : 'no daría testimonio'}</span>
      ${e.mejor ? `<div class="sat-txt"><em>Lo mejor:</em> ${esc(e.mejor)}</div>` : ''}
      ${e.mejorar ? `<div class="sat-txt"><em>Mejoraría:</em> ${esc(e.mejorar)}</div>` : ''}
    </div>`;
}

function filaMomento(m, e, editar) {
  let estado;
  if (e && e.respondido_at) estado = respuesta(e);
  else if (e && e.enviado_at) estado = `<span class="hint">Enviado el ${esc(dia(e.enviado_at))}, sin respuesta todavía.</span>`;
  else if (e) estado = '<span class="hint">Link generado, sin enviar.</span>';
  else estado = '<span class="hint">Sin link.</span>';
  const respondido = !!(e && e.respondido_at);
  const acciones = editar && !respondido ? `<span class="ll-item-acc">
      <button type="button" class="btn btn-sm" data-sat-copiar="${esc(m.id)}">Copiar link</button>
      ${e && !e.enviado_at ? `<button type="button" class="btn btn-sm" data-sat-enviado="${esc(e.id)}">Marcar como enviado</button>` : ''}
    </span>` : '';
  return `<div class="sat-fila">
      <div class="sat-fila-main">
        <div class="sat-fila-tit">${esc(m.nombre)} <span class="hint">· ${esc(textoMomento(m))}</span></div>
        ${estado}
      </div>${acciones}
    </div>`;
}

export function html(ctx) {
  const s = ctx.satisfaccion;
  if (!s) return '';
  const editar = puedeEditarPrograma(ctx.p.id);
  const activos = s.momentos.filter(m => m.activo);
  const porMomento = new Map(s.envios.filter(e => e.momento_id).map(e => [e.momento_id, e]));
  const idsActivos = new Set(activos.map(m => m.id));
  /* Respuestas de momentos que ya no están activos (o borrados): historial. */
  const otras = s.envios.filter(e => e.respondido_at && !idsActivos.has(e.momento_id));
  if (!activos.length && !otras.length) return '';
  return `
    <div class="section-title">Satisfacción<span class="line"></span></div>
    <div class="card sat-card-ficha">
      ${activos.map(m => filaMomento(m, porMomento.get(m.id), editar)).join('')}
      ${otras.map(e => `<div class="sat-fila"><div class="sat-fila-main">
          <div class="sat-fila-tit">${esc(e.momento_nombre)}</div>${respuesta(e)}</div></div>`).join('')}
    </div>`;
}

export async function manejar(ev, ctx, api) {
  if (ev.type !== 'click' || !ctx.satisfaccion) return false;
  const editar = puedeEditarPrograma(ctx.p.id);
  const copiarBtn = ev.target.closest('[data-sat-copiar]');
  if (copiarBtn) {
    if (!editar) return true;
    copiarBtn.disabled = true;
    try {
      const info = await linkSatisfaccion(ctx.c.id, copiarBtn.dataset.satCopiar);
      if (info.respondido_at) {
        toast('Este alumno ya respondió este formulario.');
      } else if (await copiar(urlSatisfaccion(info.token))) {
        toast('Link copiado. Mandáselo por WhatsApp y marcalo como enviado.');
      } else {
        toast(urlSatisfaccion(info.token));
      }
      await api.refrescar();
    } catch (e) {
      toast(mensajeCs(e), 'error');
    } finally {
      if (copiarBtn.isConnected) copiarBtn.disabled = false;
    }
    return true;
  }
  const env = ev.target.closest('[data-sat-enviado]');
  if (env) {
    if (editar) {
      await guardar(() => marcarEnviado(env.dataset.satEnviado), {
        ok: 'Marcado como enviado.', luego: () => api.refrescar(), control: env
      });
    }
    return true;
  }
  return false;
}
