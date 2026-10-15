/* Reglas de detección de dudas (135), solo fundador: regla "palabra" (apagada por defecto),
   mínimo de palabras, tope por llamada y filtro de segunda persona del consultor.
   Cambian lo que detectan las llamadas nuevas y "Reprocesar"; no tocan lo ya guardado.
   Sin la 135 el bloque no se muestra. */
import { esc, toast } from '../ui.js';
import { mensajeError } from '../datos.js';
import { mensajeCs } from '../datos-faltante.js';
import { leerReglasDudas, guardarReglasDudas } from '../datos-dudas-candidatas.js';

export async function montarReglasDudas(cont, programaId) {
  const r = await leerReglasDudas(programaId);
  if (!r || !cont.isConnected) { cont.innerHTML = ''; return; }
  cont.innerHTML = `<details class="card"><summary>Reglas de detección</summary>
    <div class="filter-row">
      <label><input type="checkbox" id="rd-palabra"${r.regla_palabra ? ' checked' : ''}> Detectar también oraciones sin «?» que empiezan con cómo, qué, cuándo… (siempre baja confianza)</label>
    </div>
    <div class="filter-row">
      <label><input type="checkbox" id="rd-segunda"${r.filtrar_segunda_persona ? ' checked' : ''}> Descartar preguntas típicas del consultor («¿tenés…?», «¿pudiste…?», «¿se entiende?»)</label>
    </div>
    <div class="filter-row">
      <span class="flabel">Mínimo de palabras</span>
      <input type="number" id="rd-min" min="4" max="20" value="${esc(r.min_palabras)}">
      <span class="flabel">Máximo por llamada</span>
      <input type="number" id="rd-max" min="1" max="30" value="${esc(r.max_por_llamada)}">
      <button type="button" class="btn" id="rd-guardar">Guardar reglas</button>
    </div>
    <p class="hint">Rigen para las llamadas nuevas y para «Reprocesar llamadas». Lo ya detectado no se borra ni se reevalúa.</p>
  </details>`;
  cont.querySelector('#rd-guardar').onclick = async () => {
    const min = parseInt(cont.querySelector('#rd-min').value, 10);
    const max = parseInt(cont.querySelector('#rd-max').value, 10);
    if (!(min >= 4 && min <= 20) || !(max >= 1 && max <= 30)) {
      toast('El mínimo va de 4 a 20 palabras y el tope de 1 a 30 por llamada.', 'error');
      return;
    }
    try {
      await guardarReglasDudas(programaId, {
        regla_palabra: cont.querySelector('#rd-palabra').checked,
        filtrar_segunda_persona: cont.querySelector('#rd-segunda').checked,
        min_palabras: min, max_por_llamada: max
      });
      toast('Reglas guardadas.');
    } catch (e) {
      toast(mensajeCs(e, mensajeError(e)), 'error');
    }
  };
}
