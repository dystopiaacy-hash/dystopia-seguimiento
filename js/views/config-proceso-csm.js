/* Configuración — "Proceso CSM semanal" (130). Solo fundador.
   Cadencia por programa (cs_proceso_csm_config): prendido / apagado, semanas en las que se pide
   referidos (default 2, 4, 6) y días antes del fin para el resell (default 21, 14, 7).
   "Ver qué haría hoy" cuenta los pasos sin escribir; "Generar ahora" corre el generador (el chequeo
   diario ya lo corre solo y no duplica). Sin la 130 el bloque avisa que falta la migración. */
import { esc, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import { faltaObjeto, mensajeCs } from '../datos-faltante.js';
import { traerConfigCsm, guardarConfigCsm, resumenCsm, generarCsm } from '../datos-proceso-csm.js';

export const htmlProcesoCsm = () => `
  <div class="conf-seccion">
    <div class="section-title">Proceso CSM semanal<span class="line"></span></div>
    <div class="card" id="cf-proceso-csm"><div class="loading-inline">Cargando…</div></div>
  </div>`;

const DEFAULTS = { activo: false, referidos_semanas: [2, 4, 6], resell_dias: [21, 14, 7] };

/* "2, 4 6" -> [2, 4, 6] (únicos, de menor a mayor). Tira un Error legible si algo no es válido. */
function leerLista(texto, etiqueta, min, max, tope) {
  const partes = String(texto || '').split(/[\s,;]+/).filter(Boolean);
  const nums = partes.map(Number);
  if (nums.some(n => !Number.isInteger(n) || n < min || n > max)) {
    throw new Error(`${etiqueta}: números enteros entre ${min} y ${max}, separados por coma.`);
  }
  const unicos = [...new Set(nums)].sort((a, b) => a - b);
  if (unicos.length > tope) throw new Error(`${etiqueta}: hasta ${tope} valores.`);
  return unicos;
}

const ETIQUETAS = [
  ['crear', 'Se crearían hoy'],
  ['cubierto_win', 'Ya cubiertos por un win (se crean completados)'],
  ['cubierto_plantilla', 'Cubiertos por la plantilla "Pedir referidos"'],
  ['renovacion_en_curso', 'Resell de alumnos que ya están en renovación (no se crean)'],
  ['saltado_viejo', 'Vencieron hace más de 7 días (no se crean)'],
  ['futuro', 'Todavía falta más de una semana (se crean más adelante)']
];

export async function montarProcesoCsm(box, programaId, vigente) {
  if (!box) return;
  if (!esFundador()) { box.innerHTML = '<div class="hint">Solo el fundador configura el proceso CSM.</div>'; return; }
  let cfg;
  try {
    cfg = await traerConfigCsm(programaId);
  } catch (e) {
    if (vigente() && box.isConnected) box.innerHTML = `<div class="hint">${esc(mensajeCs(e))}</div>`;
    return;
  }
  if (!vigente() || !box.isConnected) return;
  if (cfg === null) cfg = { ...DEFAULTS };
  box.innerHTML = `
    <div class="hint">El CSM sigue a cada alumno activo con un ritmo fijo: pide referidos en las semanas
      indicadas (desde la fecha de inicio) y avisa el resell esos días antes de la fecha de fin. Genera accionables
      del equipo en el chequeo diario, sin duplicar; aparecen en Hoy como "Proceso CSM de hoy".</div>
    <div class="form-row"><label for="pc-activo">Proceso</label>
      <select id="pc-activo">
        <option value="0"${cfg.activo ? '' : ' selected'}>Apagado</option>
        <option value="1"${cfg.activo ? ' selected' : ''}>Prendido</option>
      </select></div>
    <div class="form-row"><label for="pc-ref">Pedir referidos en las semanas</label>
      <input type="text" id="pc-ref" value="${esc((cfg.referidos_semanas || []).join(', '))}" placeholder="2, 4, 6">
      <div class="hint">Semana 1 = los primeros 7 días. El pedido vence el primer día de esa semana.</div></div>
    <div class="form-row"><label for="pc-res">Resell: días antes del fin</label>
      <input type="text" id="pc-res" value="${esc((cfg.resell_dias || []).join(', '))}" placeholder="21, 14, 7">
      <div class="hint">Un aviso por cada valor. Si el alumno entra en renovación, los pendientes se cierran solos;
        si cambia la fecha de fin, se recalculan.</div></div>
    <div>
      <button type="button" class="btn btn-accent btn-sm" id="pc-guardar">Guardar</button>
      <button type="button" class="btn btn-sm" id="pc-ver">Ver qué haría hoy</button>
      <button type="button" class="btn btn-sm" id="pc-generar">Generar ahora</button>
    </div>
    <div class="hint" id="pc-res-box"></div>`;

  const leer = () => ({
    activo: box.querySelector('#pc-activo').value === '1',
    referidos_semanas: leerLista(box.querySelector('#pc-ref').value, 'Semanas de referidos', 1, 52, 8),
    resell_dias: leerLista(box.querySelector('#pc-res').value, 'Días de resell', 1, 365, 6)
  });

  const pintarResumen = r => {
    const filas = ETIQUETAS.filter(([k]) => Number(r[k]) > 0)
      .map(([k, lab]) => `<li>${esc(lab)}: <strong>${Number(r[k])}</strong></li>`).join('');
    box.querySelector('#pc-res-box').innerHTML = filas
      ? `<ul>${filas}</ul>` : 'No hay pasos para este programa hoy.';
  };

  box.addEventListener('click', async ev => {
    const b = ev.target.closest('#pc-guardar, #pc-ver, #pc-generar');
    if (!b) return;
    b.disabled = true;
    try {
      const v = leer();
      if (b.id === 'pc-guardar') {
        await guardarConfigCsm(programaId, v);
        toast('Proceso CSM guardado.');
      } else if (b.id === 'pc-ver') {
        await guardarConfigCsm(programaId, v);   // la vista previa usa lo que se ve en pantalla
        pintarResumen(await resumenCsm(programaId));
      } else {
        await guardarConfigCsm(programaId, v);
        const r = await generarCsm(programaId);
        const n = Number(r.creados) || 0;
        toast(`Proceso CSM: ${n} accionable${n === 1 ? '' : 's'} nuevo${n === 1 ? '' : 's'}.`);
        pintarResumen(await resumenCsm(programaId));
      }
    } catch (e) {
      toast(faltaObjeto(e) ? 'Falta correr la migración 130.' : (e.message && !e.code ? e.message : mensajeCs(e)), 'error');
    } finally {
      if (b.isConnected) b.disabled = false;
    }
  });
}
