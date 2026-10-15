/* Datos de la sincronización con Fathom (122). Las llamadas entran solas por la Edge Function
   fathom-sync; acá solo se leen y se asignan a mano. La API key de Fathom vive en un secreto de
   la función: nunca pasa por el front ni por una tabla. Sin la 122 las lecturas devuelven
   undefined y las pantallas avisan que falta la migración. */
import { sb } from './supabase.js';
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { faltaObjeto } from './datos-faltante.js';

/* Sin la transcripción (texto largo): la lista no la necesita. */
const COLS_SIN_ASIGNAR = 'id,externo_id,motivo,estado,fecha,titulo,tipo,duracion_min,grabacion_url,'
  + 'grabacion_share_url,resumen,en_que_esta,action_items,invitados,candidatos,created_at';

export const TIPO_LLAMADA_LABEL = {
  onboarding: 'Onboarding', seguimiento: 'Seguimiento', resell: 'Resell', otra: 'Otra'
};
export const MOTIVO_LABEL = {
  sin_alumno: 'Ningún invitado coincide con un alumno habilitado',
  varios_alumnos: 'Coincide con más de un alumno'
};

/* Pendientes de asignar, más nuevas primero. undefined = 122 sin correr. */
export async function traerSinAsignar() {
  const { data, error } = await sb.from('cs_fathom_sin_asignar').select(COLS_SIN_ASIGNAR)
    .eq('estado', 'pendiente').order('fecha', { ascending: false }).limit(500);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

export async function asignarLlamada(id, clienteId) {
  const { data, error } = await sb.rpc('cs_fathom_asignar', { p_id: id, p_cliente: clienteId });
  if (error) throw error;
  return data;
}

export async function descartarLlamada(id) {
  const { error } = await sb.rpc('cs_fathom_descartar', { p_id: id });
  if (error) throw error;
}

/* Transcripción de una llamada (solo quien edita el programa: la RLS lo exige). null = no hay. */
export async function traerTranscripcion(llamadaId) {
  const { data, error } = await sb.from('cs_llamada_transcripciones').select('texto')
    .eq('llamada_id', llamadaId).maybeSingle();
  if (error) throw error;
  return data ? data.texto : null;
}

/* ---- Configuración (solo fundador: la RLS lo exige) ---- */

/* { programas, cron_activo } o undefined si la 122 no está corrida. */
export async function traerConfigFathom() {
  const { data, error } = await sb.from('cs_fathom_config').select('programas,cron_activo').limit(1).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || { programas: [], cron_activo: false, sin_fila: true };
}

export async function guardarConfigFathom(cambios) {
  const { data, error } = await sb.from('cs_fathom_config').update(cambios).eq('id', true).select('id');
  if (error) throw error;
  if (!data || !data.length) throw new Error('No se guardó: falta la fila de configuración (migración 122).');
}

/* Última corrida (o null). */
export async function traerUltimaCorrida() {
  const { data, error } = await sb.from('cs_fathom_corridas')
    .select('inicio,fin,origen,estado,traidas,asignadas,creadas,actualizadas,vinculadas,sin_asignar,ignoradas,errores,parcial,detalle')
    .order('inicio', { ascending: false }).limit(1).maybeSingle();
  if (error) throw error;
  return data || null;
}

/* "Sincronizar Fathom ahora": llama a la Edge Function con la sesión del fundador. Devuelve el
   resumen JSON (traídas, asignadas, sin asignar, errores). Puede tardar hasta ~2 minutos. */
export async function sincronizarFathom(desde) {
  const { data: ses } = await sb.auth.getSession();
  const token = ses && ses.session && ses.session.access_token;
  if (!token) throw new Error('La sesión venció: volvé a entrar.');
  const r = await fetch(`${SUPABASE_URL}/functions/v1/fathom-sync`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: SUPABASE_KEY },
    body: JSON.stringify(desde ? { desde } : {})
  });
  let cuerpo = null;
  try { cuerpo = await r.json(); } catch { /* sin cuerpo */ }
  if (!r.ok) {
    const motivo = (cuerpo && cuerpo.error) || `HTTP ${r.status}`;
    throw new Error(`No se pudo sincronizar: ${motivo}`);
  }
  return cuerpo;
}
