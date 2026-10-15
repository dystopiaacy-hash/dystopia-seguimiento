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
  alumno: 'Alumno', pendiente: 'Pendiente', interna: 'Interna', no_alumno: 'No es alumno'
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
  const base = 'id,nombre,secreto,activo,orden,ultimo_at,ultimo_estado,ultimo_resumen,ultima_sync_ok_at';
  /* 127: estado del historial reanudable. Sin la 127 esas columnas no existen: se vuelve a pedir sin ellas. */
  let r = await sb.from('cs_fathom_consultores')
    .select(`${base},hist_estado,hist_desde,hist_traidas,hist_inicio_at,hist_fin_at`)
    .order('orden').order('id');
  if (r.error) {
    r = await sb.from('cs_fathom_consultores').select(base).order('orden').order('id');
  }
  if (r.error) {
    if (faltaObjeto(r.error)) return undefined;
    throw r.error;
  }
  return r.data || [];
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

/* Una llamada asignada por nombre que alguien revisó y dejó: pasa a "a mano" y aprende mails y alias.
   Devuelve { mails, alias_guardados, alias_conflictos: [{ alias, con }] } (127). */
export async function confirmarLlamada(llamadaId) {
  const { data, error } = await sb.rpc('cs_fathom_confirmar', { p_llamada: llamadaId });
  if (error) throw error;
  return data && typeof data === 'object' ? data : {};
}

/* ---- Alias de nombre del alumno (127) ---- */

/* Alias de un alumno (solo fundador y cliente del programa los ven: la RLS lo exige).
   undefined = falta la 127. */
export async function traerAliasCliente(clienteId) {
  const { data, error } = await sb.from('cs_clientes_alias')
    .select('id,alias,origen,created_at').eq('cliente_id', clienteId).order('alias');
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

export async function quitarAlias(id) {
  const { error } = await sb.rpc('cs_fathom_alias_quitar', { p_id: id });
  if (error) throw error;
}

export async function agregarAlias(clienteId, alias) {
  const { error } = await sb.rpc('cs_fathom_alias_agregar', { p_cliente: clienteId, p_alias: alias });
  if (error) throw error;
}

/* Texto para el toast después de asignar, confirmar o corregir: qué se aprendió y qué alias chocó. */
export function resumenAprendido(r) {
  if (!r || typeof r !== 'object') return '';
  const partes = [];
  if (r.alias_guardados) partes.push(`${r.alias_guardados === 1 ? 'Alias guardado' : r.alias_guardados + ' alias guardados'}`);
  const conf = Array.isArray(r.alias_conflictos) ? r.alias_conflictos : [];
  for (const c of conf) partes.push(`No se guardó el alias «${c.alias}»: ya es de ${c.con}.`);
  return partes.join(' ');
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
  const base = 'inicio,fin,origen,estado,traidas,asignadas,creadas,actualizadas,vinculadas,sin_asignar,ignoradas,errores,parcial,detalle,por_consultor';
  let r = await sb.from('cs_fathom_corridas').select(`${base},internas`)
    .order('inicio', { ascending: false }).limit(1).maybeSingle();
  if (r.error) {   // sin la 127 no existe `internas`
    r = await sb.from('cs_fathom_corridas').select(base).order('inicio', { ascending: false }).limit(1).maybeSingle();
  }
  if (r.error) throw r.error;
  return r.data || null;
}

/* "Sincronizar ahora": llama a la Edge Function con la sesión del fundador. Devuelve el resumen
   JSON (totales y `consultores` con el desglose). Puede tardar hasta ~2 minutos.
   opciones: un string 'YYYY-MM-DD' (desde) o { desde, historial: true, consultor, reiniciar } (127):
   con historial arranca o continúa el historial completo de esa cuenta (una tanda por corrida). */
export async function sincronizarFathom(opciones) {
  const cuerpo = typeof opciones === 'string' ? { desde: opciones } : { ...(opciones || {}) };
  const { data: ses } = await sb.auth.getSession();
  const token = ses && ses.session && ses.session.access_token;
  if (!token) throw new Error('La sesión venció: volvé a entrar.');
  const r = await fetch(`${SUPABASE_URL}/functions/v1/fathom-sync`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: SUPABASE_KEY },
    body: JSON.stringify(cuerpo)
  });
  let cuerpo = null;
  try { cuerpo = await r.json(); } catch { /* sin cuerpo */ }
  if (!r.ok) {
    const motivo = (cuerpo && cuerpo.error) || `HTTP ${r.status}`;
    throw new Error(`No se pudo sincronizar: ${motivo}`);
  }
  return cuerpo;
}
