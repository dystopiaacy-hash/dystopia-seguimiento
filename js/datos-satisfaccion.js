/* Datos de la satisfacción por etapa (106). Separado de datos.js por tamaño.
   - Momentos (cs_satisf_momentos): cuándo se pide, por programa. Se editan directo (RLS: cs_puede_editar).
   - Envíos (cs_satisf_envios): un link por alumno y momento. El token NO es legible por la app
     (permiso por columna): se pide con cs_satisf_link. Nunca usar select('*') sobre esa tabla.
   - La página pública (satisfaccion.html) usa solo cs_satisf_estado y cs_satisf_responder.
   Sin la 106, las lecturas devuelven undefined y la pantalla no muestra nada nuevo. */
import { sb } from './supabase.js';
import { ONBOARDING_BASE_URL } from './config.js';
import { faltaObjeto } from './datos-faltante.js';

export const MOMENTO_TIPOS = [
  ['onboarding_completo', 'Cuando completa el onboarding'],
  ['dias_desde_inicio', 'N días después de empezar'],
  ['porcentaje_ciclo', 'N % del programa (50 = mitad)'],
  ['dias_antes_fin', 'N días antes de vencer']
];

/* "7 días después de empezar", "mitad del programa", ... para listas y avisos. */
export function textoMomento(m) {
  if (m.tipo === 'onboarding_completo') return 'Cuando completa el onboarding';
  if (m.tipo === 'dias_desde_inicio') return m.valor === 0 ? 'El día que empieza' : `${m.valor} días después de empezar`;
  if (m.tipo === 'porcentaje_ciclo') return m.valor === 50 ? 'A la mitad del programa' : `Al ${m.valor} % del programa`;
  return `${m.valor} días antes de vencer`;
}

/* El link que se le manda al alumno: mismo dominio que el onboarding. */
export const urlSatisfaccion = token =>
  `${ONBOARDING_BASE_URL || window.location.origin}/satisfaccion?t=${encodeURIComponent(token)}`;

const COLS_ENVIO = 'id,cliente_id,momento_id,momento_nombre,created_at,enviado_at,respondido_at,puntaje,mejor,mejorar,testimonio';

/* Momentos del programa. undefined = 106 sin correr. */
export async function traerMomentos(programaId) {
  const { data, error } = await sb.from('cs_satisf_momentos').select('*')
    .eq('programa_id', programaId).order('orden').order('created_at');
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

export async function guardarMomento(programaId, m) {
  const fila = {
    nombre: String(m.nombre || '').trim(), tipo: m.tipo, activo: m.activo !== false,
    valor: m.tipo === 'onboarding_completo' ? null : Number(m.valor), desde: m.desde
  };
  const q = m.id
    ? sb.from('cs_satisf_momentos').update(fila).eq('id', m.id)
    : sb.from('cs_satisf_momentos').insert({ ...fila, programa_id: programaId, orden: m.orden || 0 });
  const { error } = await q;
  if (error) throw error;
}

/* Alumnos que llegaron a un momento y no tienen el link enviado.
   Filas { cliente_id, nombre, momento_id, momento, hito_fecha, envio_id, tiene_link }. undefined = sin 106. */
export async function traerPendientesSatisfaccion(programaId) {
  const { data, error } = await sb.rpc('cs_satisf_pendientes', { p_programa: programaId });
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Crea (o devuelve) el link del alumno para ese momento. { envio_id, token, enviado_at, respondido_at, puntaje }. */
export async function linkSatisfaccion(clienteId, momentoId) {
  const { data, error } = await sb.rpc('cs_satisf_link', { p_cliente: clienteId, p_momento: momentoId });
  if (error) throw error;
  return data;
}

export async function marcarEnviado(envioId) {
  const { error } = await sb.rpc('cs_satisf_marcar_enviado', { p_envio: envioId });
  if (error) throw error;
}

/* Respuestas e historial del alumno (sin token). */
export async function traerEnviosCliente(clienteId) {
  const { data, error } = await sb.from('cs_satisf_envios').select(COLS_ENVIO)
    .eq('cliente_id', clienteId).order('created_at', { ascending: false });
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Todas las respondidas del programa, las más nuevas primero. */
export async function traerRespuestasSatisfaccion(programaId) {
  const { data, error } = await sb.from('cs_satisf_envios').select(COLS_ENVIO)
    .eq('programa_id', programaId).not('respondido_at', 'is', null)
    .order('respondido_at', { ascending: false }).limit(500);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}
