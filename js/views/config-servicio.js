/* Configuración — "Aviso de servicio" (123). Solo fundador.
   Parámetros por programa en cs_servicio_config:
     umbral sin llamada: aviso (amarillo) y alerta (rojo), los mismos que usan Hoy, la ficha,
       Clientes y el Maestro, y el mensaje a Discord;
     hora del aviso diario (hora Argentina), días para considerar moroso y, opcional, días de
       accionables de llamadas sin completar (0 = no se avisan).
   El webhook del canal "servicio" se carga en "Avisos por tipo" (config-canales.js).
   "Probar aviso de servicio" manda el mensaje real del día a ese canal (cs_servicio_probar).
   Sin la 123 el bloque avisa que falta la migración. */
import { esc, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import { faltaObjeto, mensajeCs } from '../datos-faltante.js';
import { traerConfigServicio, guardarConfigServicio, probarServicio } from '../datos-servicio.js';
import { LLAMADA_AMARILLO_DESDE, LLAMADA_ROJO_DESDE } from '../config.js';

export const htmlServicio = () => `
  <div class="conf-seccion">
    <div class="section-title">Aviso de servicio<span class="line"></span></div>
    <div class="card" id="cf-servicio"><div class="loading-inline">Cargando…</div></div>
  </div>`;

const CAMPOS = [
  ['llamada_aviso_dias', 'Sin llamada: aviso (amarillo), días', 1, 364,
    'Desde estos días sin llamada el alumno queda en amarillo y entra al aviso diario.'],
  ['llamada_alerta_dias', 'Sin llamada: alerta (rojo), días', 2, 365,
    'Desde estos días queda en rojo. Tiene que ser mayor que el aviso. Cuenta cualquier llamada (manual o de Fathom) asignada al alumno; solo alumnos activos.'],
  ['hora_aviso', 'Hora del aviso diario (0 a 23, hora Argentina)', 0, 23,
    'Sale a esa hora y 12 minutos. Si Discord falla, reintenta hasta 3 veces en el día.'],
  ['morosos_dias', 'Moroso: días de atraso de la cuota', 1, 365,
    'Cuotas pendientes de Finanzas con más de estos días de atraso, solo si el alumno se cruza con seguridad (teléfono o nombre).'],
  ['acc_llamada_dias', 'Accionables de llamadas sin completar: días (0 = no avisar)', 0, 365,
    'Los accionables de llamadas no tienen vencimiento: se avisan los pendientes de llamadas de hace estos días o más.']
];

export async function montarServicio(box, programaId, vigente) {
  if (!box) return;
  if (!esFundador()) { box.innerHTML = '<div class="hint">Solo el fundador configura el aviso de servicio.</div>'; return; }
  let cfg;
  try {
    cfg = await traerConfigServicio(programaId);
  } catch (e) {
    if (vigente() && box.isConnected) box.innerHTML = `<div class="hint">${esc(mensajeCs(e))}</div>`;
    return;
  }
  if (!vigente() || !box.isConnected) return;
  if (cfg === null) {
    /* null = tabla ausente (123 sin correr) o programa sin fila: se muestran los valores por defecto. */
    cfg = { llamada_aviso_dias: LLAMADA_AMARILLO_DESDE, llamada_alerta_dias: LLAMADA_ROJO_DESDE,
      hora_aviso: 9, morosos_dias: 14, acc_llamada_dias: 0 };
  }
  box.innerHTML = `
    ${CAMPOS.map(([k, lab, min, max, hint]) => `
      <div class="form-row"><label for="sv-${k}">${esc(lab)}</label>
        <input type="number" id="sv-${k}" data-sv="${k}" min="${min}" max="${max}" step="1" value="${esc(cfg[k])}">
        <div class="hint">${esc(hint)}</div></div>`).join('')}
    <div>
      <button type="button" class="btn btn-accent btn-sm" id="sv-guardar">Guardar</button>
      <button type="button" class="btn btn-sm" id="sv-probar">Probar aviso de servicio</button>
      <span class="hint">"Probar" manda el mensaje real de hoy al canal Servicio (aunque esté desactivado). No cuenta como el envío del día.</span>
    </div>`;

  const leer = () => {
    const v = {};
    for (const [k, lab, min, max] of CAMPOS) {
      const n = Number(box.querySelector(`[data-sv="${k}"]`).value);
      if (!Number.isInteger(n) || n < min || n > max) throw new Error(`${lab}: tiene que ser un entero entre ${min} y ${max}.`);
      v[k] = n;
    }
    if (v.llamada_alerta_dias <= v.llamada_aviso_dias) throw new Error('La alerta tiene que ser mayor que el aviso.');
    return v;
  };

  box.addEventListener('click', async ev => {
    const b = ev.target.closest('#sv-guardar, #sv-probar');
    if (!b) return;
    b.disabled = true;
    try {
      const v = leer();
      if (b.id === 'sv-guardar') {
        await guardarConfigServicio(programaId, v);
        toast('Aviso de servicio guardado.');
      } else {
        await guardarConfigServicio(programaId, v);   // prueba con lo que se ve en pantalla
        const r = await probarServicio(programaId);
        toast(`Aviso de servicio enviado (${r && r.partes ? r.partes : 1} mensaje${r && r.partes > 1 ? 's' : ''}). Si no llega en un minuto, revisá el webhook.`);
      }
    } catch (e) {
      toast(faltaObjeto(e) ? 'Falta correr la migración 123.' : (e.message && !e.code ? e.message : mensajeCs(e)), 'error');
    } finally {
      if (b.isConnected) b.disabled = false;
    }
  });
}
