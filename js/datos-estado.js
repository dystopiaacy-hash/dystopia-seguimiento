/* Resumen por alumno (106): "En qué está" y "Próximos pasos" de la última llamada que los tiene,
   último puntaje de satisfacción, wins y upsell. Sale de cs_v_alumno_resumen.
   Sin la 106 las lecturas devuelven null / undefined y la app se ve como antes. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';
import { limpiarMarkdown } from './texto-limpio.js';

const COLS = 'cliente_id,estado_llamada_id,estado_fecha,en_que_esta,proximos_pasos,sat_puntaje,sat_momento,'
  + 'sat_at,wins_30d,ultimo_win,referidos_pendientes,upsell_marcado,upsell_motivo,upsell_at';

/* "En qué está" mostrable: si el alumno tiene el texto automático (137, IA) manda ese; si no, el de la
   última llamada pero sin los símbolos de markdown de Fathom. 'en_que_esta_auto' marca cuál se usó.
   "Próximos pasos" también sale limpio. Sin la 137 (auto vacío) queda el texto limpio. */
function aplicarAuto(fila, auto) {
  const t = auto && String(auto).trim();
  return {
    ...fila,
    proximos_pasos: limpiarMarkdown(fila.proximos_pasos) || null,
    en_que_esta_auto: !!t,
    en_que_esta: t || limpiarMarkdown(fila.en_que_esta) || null
  };
}

/* cliente_id -> texto automático. Nunca tira: sin la 137 o con error queda vacío. */
async function autoPrograma(programaId) {
  try {
    const { data, error } = await sb.from('cs_en_que_esta').select('cliente_id,texto')
      .eq('programa_id', programaId).limit(5000);
    if (error) return new Map();
    return new Map((data || []).map(r => [r.cliente_id, r.texto]));
  } catch { return new Map(); }
}

/* Mapa cliente_id -> fila. null = 106 sin correr. */
export async function traerResumenPrograma(programaId) {
  const [{ data, error }, auto] = await Promise.all([
    sb.from('cs_v_alumno_resumen').select(COLS).eq('programa_id', programaId).limit(5000),
    autoPrograma(programaId)
  ]);
  if (error) {
    if (faltaObjeto(error)) return null;
    throw error;
  }
  return new Map((data || []).map(r => [r.cliente_id, aplicarAuto(r, auto.get(r.cliente_id))]));
}

/* Una fila. undefined = 106 sin correr. */
export async function traerResumenCliente(clienteId) {
  const { data, error } = await sb.from('cs_v_alumno_resumen').select(COLS)
    .eq('cliente_id', clienteId).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  if (!data) return null;
  let auto;
  try {
    const r = await sb.from('cs_en_que_esta').select('texto').eq('cliente_id', clienteId).maybeSingle();
    auto = r.error ? undefined : r.data && r.data.texto;
  } catch { /* sin la 137 */ }
  return aplicarAuto(data, auto);
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
