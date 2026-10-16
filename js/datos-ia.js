/* "En qué está" automático por alumno (137): lectura de cs_en_que_esta y pedido de actualización a la
   Edge Function ia-en-que-esta. Sin la 137 la lectura devuelve undefined y el bloque avisa. */
import { sb } from './supabase.js';
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { faltaObjeto } from './datos-faltante.js';

/* Una fila { texto, reuniones, actualizado_en, modelo } o null (sin texto todavía). undefined = 137 sin correr. */
export async function traerEnQueEsta(clienteId) {
  const { data, error } = await sb.from('cs_en_que_esta')
    .select('texto,reuniones,actualizado_en,modelo').eq('cliente_id', clienteId).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || null;
}

/* Regenera el texto de un alumno (fundador o edición del programa; la función lo vuelve a verificar). */
export async function actualizarEnQueEsta(clienteId) {
  const { data: ses } = await sb.auth.getSession();
  const token = ses && ses.session && ses.session.access_token;
  if (!token) throw new Error('La sesión venció: volvé a entrar.');
  const r = await fetch(`${SUPABASE_URL}/functions/v1/ia-en-que-esta`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: SUPABASE_KEY },
    body: JSON.stringify({ alumno_id: clienteId })
  });
  let respuesta = null;
  try { respuesta = await r.json(); } catch { /* sin cuerpo */ }
  if (!r.ok) throw new Error((respuesta && respuesta.error) || `HTTP ${r.status}`);
  return respuesta;
}
