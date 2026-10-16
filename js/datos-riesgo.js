/* Riesgo de abandono por alumno (139): lectura de cs_riesgo_abandono (RLS: fundador y quien edita el programa) y pedido
   de evaluación a la Edge Function ia-riesgo-abandono. Sin la 139 la lectura devuelve undefined. */
import { sb } from './supabase.js';
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { faltaObjeto } from './datos-faltante.js';

/* Una fila { nivel, motivo, accion, buen_momento_referido, buen_momento_testimonio, evaluado_en, modelo } o null
   (todavía no evaluado, o sin permiso para verlo). undefined = 139 sin correr. */
export async function traerRiesgo(clienteId) {
  const { data, error } = await sb.from('cs_riesgo_abandono')
    .select('nivel,motivo,accion,buen_momento_referido,buen_momento_testimonio,evaluado_en,modelo')
    .eq('cliente_id', clienteId).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || null;
}

/* Reevalúa a un alumno ahora (fundador o edición del programa; la función lo vuelve a verificar). */
export async function evaluarRiesgo(clienteId) {
  const { data: ses } = await sb.auth.getSession();
  const token = ses && ses.session && ses.session.access_token;
  if (!token) throw new Error('La sesión venció: volvé a entrar.');
  const r = await fetch(`${SUPABASE_URL}/functions/v1/ia-riesgo-abandono`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: SUPABASE_KEY },
    body: JSON.stringify({ alumno_id: clienteId })
  });
  let respuesta = null;
  try { respuesta = await r.json(); } catch { /* sin cuerpo */ }
  if (!r.ok) throw new Error((respuesta && respuesta.error) || `HTTP ${r.status}`);
  return respuesta;
}
