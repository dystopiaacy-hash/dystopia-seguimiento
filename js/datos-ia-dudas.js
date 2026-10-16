/* Propuestas de la IA para las dudas frecuentes (139).
   - Lectura: cs_v_duda_propuestas (alumnos distintos, semanas y fechas calculados por la base) y las preguntas de cada
     propuesta (cs_duda_candidatas.propuesta_id). RLS: solo quien EDITA el programa (fundador y rol producto).
   - Acciones: RPC cs_duda_propuesta_aprobar / cs_duda_propuesta_descartar. Nada es oficial hasta aprobar.
   - "Reagrupar con IA" (solo fundador) y la corrida a pedido: Edge Function ia-dudas.
   Sin la 139 las lecturas devuelven undefined. */
import { sb } from './supabase.js';
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { faltaObjeto } from './datos-faltante.js';

/* Propuestas pendientes del programa, las más repetidas primero. undefined = 139 sin correr. */
export async function traerPropuestas(programaId) {
  const { data, error } = await sb.from('cs_v_duda_propuestas').select('*')
    .eq('programa_id', programaId).eq('estado', 'pendiente')
    .order('alumnos', { ascending: false }).order('created_at', { ascending: false }).limit(200);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Preguntas de cada propuesta: [{ id, propuesta_id, cliente_id, fecha, texto }]. */
export async function traerPreguntasDePropuestas(ids) {
  if (!ids.length) return [];
  const { data, error } = await sb.from('cs_duda_candidatas')
    .select('id,propuesta_id,cliente_id,fecha,texto').in('propuesta_id', ids).neq('estado', 'descartada')
    .order('fecha', { ascending: false }).limit(1000);
  if (error) throw error;
  return data || [];
}

/* d = { texto, respuesta, recurso_titulo, recurso_url } (lo que la persona dejó en el formulario). */
export async function aprobarPropuesta(id, d) {
  const { data, error } = await sb.rpc('cs_duda_propuesta_aprobar', {
    p_id: id, p_texto: d.texto || null, p_respuesta: d.respuesta || null,
    p_recurso_titulo: d.recurso_titulo || null, p_recurso_url: d.recurso_url || null
  });
  if (error) throw error;
  return data;   // { duda_id, nueva, menciones }
}

export async function descartarPropuesta(id) {
  const { error } = await sb.rpc('cs_duda_propuesta_descartar', { p_id: id });
  if (error) throw error;
}

/* Corre ia-dudas con el token del usuario. cuerpo: { lote: true } o { programa, reagrupar: true } (solo fundador). */
export async function correrIaDudas(cuerpo) {
  const { data: ses } = await sb.auth.getSession();
  const token = ses && ses.session && ses.session.access_token;
  if (!token) throw new Error('La sesión venció: volvé a entrar.');
  const r = await fetch(`${SUPABASE_URL}/functions/v1/ia-dudas`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: SUPABASE_KEY },
    body: JSON.stringify(cuerpo)
  });
  let respuesta = null;
  try { respuesta = await r.json(); } catch { /* sin cuerpo */ }
  if (!r.ok) throw new Error((respuesta && respuesta.error) || `HTTP ${r.status}`);
  return respuesta;
}
