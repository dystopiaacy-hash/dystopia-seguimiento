/* Resumen por alumno (106): "En qué está" y "Próximos pasos" de la última llamada que los tiene,
   último puntaje de satisfacción, wins y upsell. Sale de cs_v_alumno_resumen.
   Sin la 106 las lecturas devuelven null / undefined y la app se ve como antes. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';

const COLS = 'cliente_id,estado_llamada_id,estado_fecha,en_que_esta,proximos_pasos,sat_puntaje,sat_momento,'
  + 'sat_at,wins_30d,ultimo_win,referidos_pendientes,upsell_marcado,upsell_motivo,upsell_at';

/* Mapa cliente_id -> fila. null = 106 sin correr. */
export async function traerResumenPrograma(programaId) {
  const { data, error } = await sb.from('cs_v_alumno_resumen').select(COLS)
    .eq('programa_id', programaId).limit(5000);
  if (error) {
    if (faltaObjeto(error)) return null;
    throw error;
  }
  return new Map((data || []).map(r => [r.cliente_id, r]));
}

/* Una fila. undefined = 106 sin correr. */
export async function traerResumenCliente(clienteId) {
  const { data, error } = await sb.from('cs_v_alumno_resumen').select(COLS)
    .eq('cliente_id', clienteId).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || null;
}

/* { fecha, fuente, modalidad, sinAlerta, onboarding, ultimaConsultoria } de la última llamada
   (cs_v_ultima_llamada, 102; las 4 últimas son de la 157: sin ella quedan null / false) o null. */
export async function traerUltimaLlamadaCliente(clienteId) {
  const base = 'ultima_llamada,fuente';
  let { data, error } = await sb.from('cs_v_ultima_llamada')
    .select(base + ',modalidad,sin_alerta,onboarding_fecha,ultima_consultoria').eq('cliente_id', clienteId).maybeSingle();
  if (error && error.code === '42703') {
    ({ data, error } = await sb.from('cs_v_ultima_llamada').select(base).eq('cliente_id', clienteId).maybeSingle());
  }
  if (error) {
    if (faltaObjeto(error)) return null;
    throw error;
  }
  return data ? {
    fecha: data.ultima_llamada, fuente: data.fuente, modalidad: data.modalidad || null, sinAlerta: !!data.sin_alerta,
    onboarding: data.onboarding_fecha || null, ultimaConsultoria: data.ultima_consultoria || null
  } : null;
}
