/* Datos de la sincronización con Fathom (122, 124). Las llamadas entran solas por la Edge Function
   fathom-sync, una cuenta de Fathom por consultor (cs_fathom_consultores); acá solo se leen y se
   asignan a mano. La API key de Fathom vive en un secreto de la función: nunca pasa por el front ni
   por una tabla (la tabla guarda solo el NOMBRE del secreto). Lo que cada usuario ve lo decide la
   RLS (llamadas de alumno: quien tiene acceso al programa; pendientes y "no es alumno": fundador
   y cliente). Sin la 124 las lecturas devuelven undefined y las pantallas avisan. */
import { sb } from './supabase.js';
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { faltaObjeto } from './datos-faltante.js';

export const TIPO_LLAMADA_LABEL = {
  onboarding: 'Onboarding', seguimiento: 'Seguimiento', resell: 'Resell', otra: 'Otra'
};
export const ESTADO_FATHOM_LABEL = {
  alumno: 'Alumno', pendiente: 'Pendiente', no_alumno: 'No es alumno'
};
/* Cómo se asignó una llamada de alumno (126): mail y nombre las hace la sincronización. */
export const ASIGNADA_POR_LABEL = { mail: 'Por mail', nombre: 'Por nombre', manual: 'A mano' };
export const MOTIVO_LABEL = {
  sin_alumno: 'Ningún invitado coincide con un alumno habilitado',
  varios_alumnos: 'Coincide con más de un alumno'
};

/* Todas las llamadas de Fathom que el usuario puede ver, más nuevas primero. undefined = falta la 124. */
export async function traerLlamadasFathom() {
  const { data, error } = await sb.from('cs_v_fathom_llamadas').select('*')
    .order('fecha', { ascending: false }).order('inicio_at', { ascending: false }).limit(1000);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Cuentas de Fathom por consultor (activas e inactivas). undefined = falta la 124. */
export async function traerConsultores() {
  const { data, error } = await sb.from('cs_fathom_consultores')
    .select('id,nombre,secreto,activo,orden,ultimo_at,ultimo_estado,ultimo_resumen,ultima_sync_ok_at')
    .order('orden').order('id');
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Programas habilitados para asignar (los ve quien ve las llamadas privadas). [] si no corresponde. */
export async function traerProgramasHabilitados() {
  const { data, error } = await sb.rpc('cs_fathom_programas');
  if (error) {
    if (faltaObjeto(error)) return [];
    throw error;
  }
  return data || [];
}

export async function asignarLlamada(id, clienteId) {
  const { data, error } = await sb.rpc('cs_fathom_asignar', { p_id: id, p_cliente: clienteId });
  if (error) throw error;
  return data;
}

/* Alumnos de los programas habilitados que el usuario puede usar para asignar o corregir (126):
   solo id, programa, nombre y estado. [] si falta la 126 o no corresponde. */
export async function traerAlumnosAsignables() {
  const { data, error } = await sb.rpc('cs_fathom_alumnos');
  if (error) {
    if (faltaObjeto(error)) return [];
    throw error;
  }
  return data || [];
}

/* Una llamada asignada por nombre que alguien revisó y dejó: pasa a "a mano" y aprende los mails. */
export async function confirmarLlamada(llamadaId) {
  const { error } = await sb.rpc('cs_fathom_confirmar', { p_llamada: llamadaId });
  if (error) throw error;
}

/* Pasa una llamada ya asignada a otro alumno, o la devuelve a pendiente (clienteId null). */
export async function corregirLlamada(llamadaId, clienteId) {
  const { data, error } = await sb.rpc('cs_fathom_corregir', { p_llamada: llamadaId, p_cliente: clienteId || null });
  if (error) throw error;
  return data;
}

/* Usuario de cada consultor (solo fundador): [{ consultor, email_login, usuario_existe }]. undefined = falta la 126. */
export async function traerLogins() {
  const { data, error } = await sb.rpc('cs_fathom_logins');
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Guarda el mail de login del consultor (null lo quita). Devuelve si ya existe un usuario con ese mail. */
export async function guardarLogin(consultor, email) {
  const { data, error } = await sb.rpc('cs_fathom_login_guardar', { p_consultor: consultor, p_email: email || null });
  if (error) throw error;
  return data === true;
}

export async function marcarNoAlumno(id) {
  const { error } = await sb.rpc('cs_fathom_marcar_no_alumno', { p_id: id });
  if (error) throw error;
}

export async function reabrirLlamada(id) {
  const { error } = await sb.rpc('cs_fathom_reabrir', { p_id: id });
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

export async function guardarConsultor(id, cambios) {
  const { data, error } = await sb.from('cs_fathom_consultores').update(cambios).eq('id', id).select('id');
  if (error) throw error;
  if (!data || !data.length) throw new Error('No se guardó el consultor.');
}

/* Nueva cuenta: solo el NOMBRE del secreto (FATHOM_API_KEY_<ALGO>), nunca la key. */
export async function crearConsultor({ id, nombre, secreto, orden }) {
  const { error } = await sb.from('cs_fathom_consultores').insert({ id, nombre, secreto, orden, activo: true });
  if (error) throw error;
}

/* Última corrida (o null). */
export async function traerUltimaCorrida() {
  const { data, error } = await sb.from('cs_fathom_corridas')
    .select('inicio,fin,origen,estado,traidas,asignadas,creadas,actualizadas,vinculadas,sin_asignar,ignoradas,errores,parcial,detalle,por_consultor')
    .order('inicio', { ascending: false }).limit(1).maybeSingle();
  if (error) throw error;
  return data || null;
}

/* "Sincronizar ahora": llama a la Edge Function con la sesión del fundador. Devuelve el resumen
   JSON (totales y `consultores` con el desglose). Puede tardar hasta ~2 minutos. */
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
