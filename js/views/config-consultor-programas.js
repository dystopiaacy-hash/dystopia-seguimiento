/* Configuración general — "Programa de cada cuenta de Fathom" (194). Solo fundador.
   Cada cuenta (consultor) puede estar en uno o más programas. Sirve para ubicar una llamada de esa cuenta en su
   programa aunque no caiga justo en un horario de consultoría. No cambia quién ve qué (eso lo hace la RLS).
   Sin la 194 el bloque avisa que falta la migración. */
import { esc, toast } from '../ui.js';
import { yo } from '../sesion.js';
import { faltaObjeto, mensajeCs } from '../datos-faltante.js';
import { traerConsultores, traerConsultorProgramas, guardarConsultorProgramas } from '../datos-consultorias.js';

export async function montarConsultorProgramas(box, vigente) {
  if (!box) return;
  let consultores, mapa;
  try {
    [consultores, mapa] = await Promise.all([traerConsultores(), traerConsultorProgramas()]);
  } catch (e) {
    if (vigente() && box.isConnected) box.innerHTML = `<div class="hint">${esc(mensajeCs(e))}</div>`;
    return;
  }
  if (!vigente() || !box.isConnected) return;
  if (mapa === undefined) { box.innerHTML = '<div class="hint">Falta correr la migración 194 (programa de cada cuenta de Fathom).</div>'; return; }
  const programas = (yo.programas || []).filter(p => p.activo !== false);
  box.innerHTML = `
    <div class="section-title">Programa de cada cuenta de Fathom<span class="line"></span></div>
    <div class="hint">Una cuenta puede estar en más de un programa. Con esto, una llamada de esa cuenta queda en su programa
      aunque no caiga justo en un horario. Una cuenta sin programa (por ejemplo joaco) no se ubica sola.</div>
    ${consultores.map(c => {
      const mios = new Set(mapa.get(c.id) || []);
      return `<div class="cf-consultor cc-fila" data-cp="${esc(c.id)}">
        <strong>${esc(c.nombre)}${c.activo ? '' : ' (inactivo)'}</strong>
        ${programas.map(p => `<label class="cc-activo"><input type="checkbox" data-prog="${esc(p.id)}"${mios.has(p.id) ? ' checked' : ''}> ${esc(p.nombre)}</label>`).join('')}
        <button type="button" class="btn btn-sm btn-accent" data-cp-guardar="${esc(c.id)}">Guardar</button>
      </div>`;
    }).join('') || '<div class="muted-empty">No hay cuentas de Fathom cargadas.</div>'}`;

  box.onclick = async ev => {
    const b = ev.target.closest('[data-cp-guardar]');
    if (!b) return;
    const progs = [...b.closest('.cc-fila').querySelectorAll('[data-prog]:checked')].map(i => i.dataset.prog);
    b.disabled = true;
    try {
      await guardarConsultorProgramas(b.dataset.cpGuardar, progs);
      toast('Programas de la cuenta guardados.');
    } catch (e) {
      toast(faltaObjeto(e) ? 'Falta correr la migración 194.' : (e.message && !e.code ? e.message : mensajeCs(e)), 'error');
    } finally {
      if (b.isConnected) b.disabled = false;
    }
  };
}
