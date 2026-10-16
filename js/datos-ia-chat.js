/* Chat interno "Preguntale a la IA" (140): pedido a la Edge Function ia-preguntar con el token del usuario.
   Solo lectura: la IA elige una de 3 consultas ya armadas en la base y la base responde con los permisos de quien pregunta. */
import { sb } from './supabase.js';
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';

/* Devuelve { ok, respuesta, consultas: [{ herramienta, filas }] }. Tira Error con el mensaje de la función. */
export async function preguntarIa(pregunta, programaId) {
  const { data: ses } = await sb.auth.getSession();
  const token = ses && ses.session && ses.session.access_token;
  if (!token) throw new Error('La sesión venció: volvé a entrar.');
  const r = await fetch(`${SUPABASE_URL}/functions/v1/ia-preguntar`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: SUPABASE_KEY },
    body: JSON.stringify({ pregunta, programa: programaId || undefined })
  });
  let respuesta = null;
  try { respuesta = await r.json(); } catch { /* sin cuerpo */ }
  if (!r.ok || !respuesta || respuesta.ok === false) throw new Error((respuesta && respuesta.error) || `HTTP ${r.status}`);
  return respuesta;
}
