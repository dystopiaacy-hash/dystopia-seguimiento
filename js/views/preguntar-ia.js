/* Pestaña "Preguntale a la IA" (#/p/:programa/preguntar, 140) y chat de Dystopita. Fundador, rol producto y rol cliente.
   SOLO LECTURA: Sonnet entiende la pregunta y elige consultas ya armadas en la base (Producto, Marketing, Ventas y Finanzas,
   ver docs/dystopita-herramientas.md); la base responde con los permisos de quien pregunta. Si la pregunta no entra en
   ninguna, lo dice. El historial vive solo en esta pantalla (no se guarda). */
import { esc, toast } from '../ui.js';
import { puedeUsarChatIa } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { preguntarIa } from '../datos-ia-chat.js';
import { vacio } from './programa.js';

const HERRAMIENTA = {
  alumnos_atrasados: 'alumnos atrasados',
  en_que_esta_alumno: 'en qué está un alumno',
  por_renovar_o_deuda: 'por renovar o deuda',
  alumnos_cantidad: 'cantidad de alumnos',
  mkt_piezas_publicadas: 'piezas publicadas',
  mkt_pendientes_produccion: 'pendientes de producción',
  mkt_analisis_semanal: 'análisis semanal',
  ventas_llamadas: 'llamadas',
  ventas_por_persona: 'llamadas por closer o setter',
  ventas_leads: 'leads',
  fin_cobros: 'cobros',
  fin_ingresos_gastos: 'ingresos y gastos',
  fin_deudas: 'deudas',
  fin_pagos: 'pagos'
};

/* Markdown mínimo y seguro para las respuestas de la IA. Primero se escapa TODO el HTML; recién después se arman
   las etiquetas propias (strong, em, code, ul, ol, li, p, br). Sin links ni imágenes: quedan como texto.
   Negrita **x**, cursiva *x* o _x_, código `x`, listas "- " / "* " y "1. ", títulos "#" a "######", saltos de línea. */
function mdInline(s) {
  const codigo = [];
  return s
    .replace(/`([^`\n]+)`/g, (_, c) => `\u0000${codigo.push(c) - 1}\u0000`)
    .replace(/\*\*([^*\n]+?)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*\w])\*([^*\s][^*\n]*?)\*(?![*\w])/g, '$1<em>$2</em>')
    .replace(/(^|[^\w])_([^_\s][^_\n]*?)_(?!\w)/g, '$1<em>$2</em>')
    .replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codigo[Number(i)]}</code>`);
}

export function dystopitaMd(texto) {
  const lineas = esc(String(texto == null ? '' : texto).replace(/\u0000/g, '')).split(/\r?\n/);
  let html = '';
  let parrafo = [];
  let lista = null;   // 'ul' | 'ol'
  const cerrarParrafo = () => { if (parrafo.length) html += `<p>${parrafo.join('<br>')}</p>`; parrafo = []; };
  const cerrarLista = () => { if (lista) html += `</${lista}>`; lista = null; };
  for (const linea of lineas) {
    const vineta = /^\s*[-*]\s+(.+)$/.exec(linea);
    const numero = /^\s*\d+\.\s+(.+)$/.exec(linea);
    const titulo = /^\s*#{1,6}\s+(.+)$/.exec(linea);
    if (vineta || numero) {
      cerrarParrafo();
      const tipo = vineta ? 'ul' : 'ol';
      if (lista !== tipo) { cerrarLista(); html += `<${tipo}>`; lista = tipo; }
      html += `<li>${mdInline((vineta || numero)[1])}</li>`;
    } else if (titulo) {
      cerrarParrafo(); cerrarLista();
      html += `<p class="dy-md-h">${mdInline(titulo[1])}</p>`;
    } else if (!linea.trim()) {
      cerrarParrafo(); cerrarLista();
    } else {
      cerrarLista();
      parrafo.push(mdInline(linea.trim()));
    }
  }
  cerrarParrafo(); cerrarLista();
  return html;
}

/* Conserva la conversación al cambiar de pestaña y volver. */
let hilo = [];

export function vistaPreguntar(el, programaId, vigente) {
  if (!puedeUsarChatIa()) {
    el.innerHTML = vacio('No tenés acceso a esta sección.');
    return null;
  }
  const ejemplos = [
    programaId ? `¿Qué alumnos de ${programaId} están atrasados o sin llamada?` : '¿Qué alumnos están atrasados o sin llamada?',
    '¿En qué está ',
    programaId ? `¿Cuántos alumnos activos tiene ${programaId}?` : '¿Cuántos alumnos activos hay por cliente?'
  ];
  let esperando = false;

  function mensajes() {
    return hilo.map(m => m.rol === 'yo'
      ? `<div class="chat-ia-msg chat-ia-msg-yo">${esc(m.texto)}</div>`
      : `<div class="chat-ia-msg chat-ia-msg-ia"><div class="dy-md">${dystopitaMd(m.texto)}</div>${m.consultas && m.consultas.length
          ? `<div class="chat-ia-meta">Consultó: ${esc(m.consultas.map(c => `${HERRAMIENTA[c.herramienta] || c.herramienta}${c.filas == null ? '' : ` (${c.filas} ${c.filas === 1 ? 'fila' : 'filas'})`}`).join(', '))}</div>` : ''}</div>`
    ).join('');
  }

  function pintar() {
    el.innerHTML = `
      <div class="chat-ia">
        <div class="card">
          <p><strong>Preguntale a la IA</strong> · solo lectura: no modifica nada.</p>
          <p class="hint">Responde de Producto, Marketing, Ventas y Finanzas, con los datos que vos tenés permiso de ver. Si no tiene la herramienta para tu pregunta, te lo dice.</p>
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
    window.dispatchEvent(new CustomEvent('ia-chat-pensando', { detail: { pensando: true } }));   // Dystopita
    try {
      const r = await preguntarIa(t, programaId);
      hilo.push({ rol: 'ia', texto: r.respuesta, consultas: r.consultas || [] });
    } catch (e) {
      toast(mensajeError(e), 'error');
      hilo.push({ rol: 'ia', texto: 'No pude responder: ' + mensajeError(e) });
    }
    window.dispatchEvent(new CustomEvent('ia-chat-pensando', { detail: { pensando: false } }));
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
