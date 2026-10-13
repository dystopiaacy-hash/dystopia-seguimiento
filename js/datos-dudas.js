/* Dudas frecuentes (106). Separado de datos.js por tamaño.
   - Lectura: cs_v_dudas (ranking por alumnos DISTINTOS, nueva esta semana, racha de semanas)
     y cs_duda_menciones (alumno y fecha de cada mención).
   - Alta de mención: cs_duda_mencion (existente por id o nueva por texto; RLS: cs_puede_editar).
   - Unir y borrar: solo fundador (la base lo exige).
   Sin la 106, las lecturas devuelven undefined. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';

export const ORIGEN_DUDA_LABEL = { discord: 'Discord', llamada: 'Llamada', whatsapp: 'WhatsApp', otro: 'Otro' };

/* Dudas del programa con su conteo, ordenadas por alumnos distintos y después por última mención. */
export async function traerDudas(programaId) {
  const { data, error } = await sb.from('cs_v_dudas').select('*').eq('programa_id', programaId).limit(2000);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return (data || []).sort((a, b) =>
    (b.alumnos - a.alumnos) || (b.menciones - a.menciones)
    || String(b.ultima_mencion || '').localeCompare(String(a.ultima_mencion || ''))
    || String(a.texto).localeCompare(String(b.texto), 'es'));
}

/* Menciones del programa: { duda_id, cliente_id, fecha, origen }. */
export async function traerMenciones(programaId) {
  const { data, error } = await sb.from('cs_duda_menciones').select('duda_id,cliente_id,fecha,origen')
    .eq('programa_id', programaId).order('fecha', { ascending: false }).limit(5000);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Una mención. dudaId = duda existente; si es null, texto crea la duda (o usa la que tenga el mismo texto).
   Devuelve el id de la duda. */
export async function registrarMencion(programaId, { dudaId = null, texto = '', clienteId, fecha = null, origen = 'otro', llamadaId = null }) {
  const { data, error } = await sb.rpc('cs_duda_mencion', {
    p_programa: programaId, p_duda: dudaId, p_texto: texto, p_cliente: clienteId,
    p_fecha: fecha, p_origen: origen, p_llamada: llamadaId
  });
  if (error) throw error;
  return data;
}

/* respuesta, recurso_url y recurso_titulo (todo opcional). */
export async function guardarDuda(id, { texto, respuesta, recurso_url, recurso_titulo }) {
  const { error } = await sb.from('cs_dudas').update({
    texto: String(texto || '').trim(),
    respuesta: String(respuesta || '').trim() || null,
    recurso_url: String(recurso_url || '').trim() || null,
    recurso_titulo: String(recurso_titulo || '').trim() || null
  }).eq('id', id);
  if (error) throw error;
}

export async function unirDudas(origenId, destinoId) {
  const { data, error } = await sb.rpc('cs_duda_unir', { p_origen: origenId, p_destino: destinoId });
  if (error) throw error;
  return data;
}
