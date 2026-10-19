/* Propuestas de la IA para las llamadas de Fathom sin asignar (186). La función ia-fathom-clasificar
   escribe las propuestas (tipo + alumno); acá se leen y se deciden. Aceptar y corregir pasan por
   cs_fathom_prop_resolver, que llama a la MISMA cs_fathom_asignar (o cs_fathom_marcar_no_alumno) de la
   asignación manual. Sin la 186 las lecturas devuelven undefined y la pantalla avisa. */
import { sb } from './supabase.js';
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { faltaObjeto } from './datos-faltante.js';

export const TIPO_PROPUESTA_LABEL = {
  consultoria_1a1: 'Consultoría 1 a 1', clase_grupal: 'Clase grupal', venta: 'Venta', interna: 'Interna', otra: 'Otra'
};
export const CONFIANZA_LABEL = { alta: 'Alta', media: 'Media', baja: 'Baja' };

/* Propuestas pendientes (más nuevas primero). undefined = falta la 186. */
export async function traerPropuestas() {
  const { data, error } = await sb.from('cs_fathom_propuestas')
    .select('id,llamada_id,tipo,alumno_id,confianza,motivo,origen,estado,created_at')
    .eq('estado', 'pendiente').order('created_at', { ascending: false }).limit(1000);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* accion: 'aceptar' | 'corregir' | 'descartar'. Para corregir: clienteId (o null) y tipo. */
export async function resolverPropuesta(id, accion, { clienteId = null, tipo = null } = {}) {
  const { data, error } = await sb.rpc('cs_fathom_prop_resolver', {
    p_prop: id, p_accion: accion, p_cliente: clienteId, p_tipo: tipo
  });
  if (error) throw error;
  return data && typeof data === 'object' ? data : {};
}

/* "Aceptar todas las de confianza alta": solo propuestas con alumno y tipo consultoría 1 a 1.
   Devuelve { aceptadas, fallidas, errores, quedan }. */
export async function aceptarAltas(limite = 100) {
  const { data, error } = await sb.rpc('cs_fathom_prop_aceptar_altas', { p_limite: limite });
  if (error) throw error;
  return data && typeof data === 'object' ? data : {};
}

/* "Clasificar pendientes" (solo fundador): llama a la Edge Function con la sesión. Cada llamada procesa
   hasta ~120 llamadas y devuelve { procesadas, por_mail, por_ia, por_confianza, costo_usd, quedan, errores, ... }.
   opciones: { consultor, rehacer, diagnostico }. */
export async function clasificarPendientes(opciones) {
  const { data: ses } = await sb.auth.getSession();
  const token = ses && ses.session && ses.session.access_token;
  if (!token) throw new Error('La sesión venció: volvé a entrar.');
  const r = await fetch(`${SUPABASE_URL}/functions/v1/ia-fathom-clasificar`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: SUPABASE_KEY },
    body: JSON.stringify(opciones || {})
  });
  let respuesta = null;
  try { respuesta = await r.json(); } catch { /* sin cuerpo */ }
  if (!r.ok) {
    const motivo = (respuesta && respuesta.error) || `HTTP ${r.status}`;
    throw new Error(`No se pudo clasificar: ${motivo}`);
  }
  return respuesta;
}
