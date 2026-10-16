/* Pestaña "Preguntale a la IA" (#/p/:programa/preguntar, 140). Solo fundador y rol producto (edición en algún programa).
   SOLO LECTURA: Sonnet entiende la pregunta y elige una de 3 consultas ya armadas en la base; la base responde con los
   permisos de quien pregunta. Sabe responder:
     1. ¿Qué alumnos de <cliente> están atrasados o sin llamada?
     2. ¿En qué está <alumno>?
     3. ¿Quién está por renovar o debe plata?
   Si la pregunta no entra en esas, lo dice y sugiere estas. El historial vive solo en esta pantalla (no se guarda). */
import { esc, toast } from '../ui.js';
import { puedeGestionarFathom } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { preguntarIa } from '../datos-ia-chat.js';
import { vacio } from './programa.js';

const HERRAMIENTA = {
  alumnos_atrasados: 'alumnos atrasados',
  en_que_esta_alumno: 'en qué está un alumno',
  por_renovar_o_deuda: 'por renovar o deuda'
};

/* Conserva la conversación al cambiar de pestaña y volver. */
let hilo = [];

export function vistaPreguntar(el, programaId, vigente) {
  if (!puedeGestionarFathom()) {
    el.innerHTML = vacio('Solo el fundador o el rol producto pueden usar esta sección.');
    return null;
  }
  const ejemplos = [
    `¿Qué alumnos de ${programaId} están atrasados o sin llamada?`,
    '¿En qué está ',
    '¿Quién está por renovar o debe plata?'
  ];
  let esperando = false;

  function mensajes() {
    return hilo.map(m => m.rol === 'yo'
      ? `<div class="chat-ia-msg chat-ia-msg-yo">${esc(m.texto)}</div>`
      : `<div class="chat-ia-msg chat-ia-msg-ia">${esc(m.texto)}${m.consultas && m.consultas.length
          ? `<div class="chat-ia-meta">Consultó: ${esc(m.consultas.map(c => `${HERRAMIENTA[c.herramienta] || c.herramienta}${c.filas == null ? '' : ` (${c.filas} ${c.filas === 1 ? 'fila' : 'filas'})`}`).join(', '))}</div>` : ''}</div>`
    ).join('');
  }

  function pintar() {
    el.innerHTML = `
      <div class="chat-ia">
        <div class="card">
          <p><strong>Preguntale a la IA</strong> · solo lectura: no modifica nada.</p>
          <p class="hint">Por ahora responde tres tipos de pregunta, con los datos que vos tenés permiso de ver. Si le preguntás otra cosa, te lo dice.</p>
          <div class="chat-ia-ejemplos">
            ${ejemplos.map((t, i) => `<button type="button" class="btn btn-sm" data-ia-ejemplo="${i}">${esc(t.trim())}${i === 1 ? '…' : ''}</button>`).join('')}
          </div>
        </div>
        <div class="chat-ia-hilo" id="ia-hilo" aria-live="polite">${mensajes()}</div>
        <div class="chat-ia-form">
          <textarea id="ia-pregunta" rows="2" maxlength="600" placeholder="Escribí tu pregunta…" aria-label="Pregunta"></textarea>
          <button type="button" class="btn btn-accent" id="ia-enviar">Preguntar</button>
        </div>
        <div class="hint" id="ia-estado"></div>
      </div>`;
  }

  async function enviar(texto) {
    const t = (texto || '').trim();
    if (!t || esperando) return;
    esperando = true;
    hilo.push({ rol: 'yo', texto: t });
    pintar();
    const estado = el.querySelector('#ia-estado');
    const enviarBtn = el.querySelector('#ia-enviar');
    if (enviarBtn) enviarBtn.disabled = true;
    if (estado) estado.textContent = 'Pensando…';
    try {
      const r = await preguntarIa(t, programaId);
      hilo.push({ rol: 'ia', texto: r.respuesta, consultas: r.consultas || [] });
    } catch (e) {
      toast(mensajeError(e), 'error');
      hilo.push({ rol: 'ia', texto: 'No pude responder: ' + mensajeError(e) });
    }
    esperando = false;
    if (!vigente()) return;
    pintar();
  }

  el.addEventListener('click', ev => {
    const ej = ev.target.closest('[data-ia-ejemplo]');
    if (ej) {
      const t = ejemplos[Number(ej.dataset.iaEjemplo)];
      if (Number(ej.dataset.iaEjemplo) === 1) {
        const ta = el.querySelector('#ia-pregunta');
        ta.value = t;
        ta.focus();
      } else {
        enviar(t);
      }
      return;
    }
    if (ev.target.closest('#ia-enviar')) enviar(el.querySelector('#ia-pregunta').value);
  });
  el.addEventListener('keydown', ev => {
    if (ev.target.id === 'ia-pregunta' && ev.key === 'Enter' && !ev.shiftKey) {
      ev.preventDefault();
      enviar(ev.target.value);
    }
  });

  pintar();
  return null;
}
