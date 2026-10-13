/* Datos del onboarding por link (093). Separado de datos.js por tamaño.
   Todo pasa por RPC: la app no lee cs_onboardings directo (el token no es legible).
   Si la 093 no se corrió, las lecturas devuelven null / [] y la app se ve como antes. */
import { sb } from './supabase.js';
import { ONBOARDING_BASE_URL } from './config.js';

/* La función no existe: 093 sin correr (42883 de Postgres, PGRST202 de PostgREST). */
function faltaFuncion(e) {
  return !!e && (e.code === '42883' || e.code === 'PGRST202'
    || /cs_onboarding_/.test(e.message || '') && /does not exist|schema cache/i.test(e.message || ''));
}

/* El link completo que se le manda al alumno. La base se define en config.js
   (ONBOARDING_BASE_URL); vacía, es el mismo dominio desde el que se abre la app. */
export const urlOnboarding = token =>
  `${ONBOARDING_BASE_URL || window.location.origin}/onboarding?t=${encodeURIComponent(token)}`;

/* Crea el onboarding del alumno (o devuelve el que ya existe).
   { token, estado, creado, vence_at, plantilla }. Lanza con mensaje "cs: ..." si no se puede. */
export async function linkOnboarding(clienteId) {
  const { data, error } = await sb.rpc('cs_onboarding_link', { p_cliente: clienteId });
  if (error) throw error;
  return data;
}

/* Ficha: null = todavía no tiene onboarding; undefined = 093 sin correr. */
export async function traerOnboardingCliente(clienteId) {
  const { data, error } = await sb.rpc('cs_onboarding_ficha', { p_cliente: clienteId });
  if (error) {
    if (faltaFuncion(error)) return undefined;
    throw error;
  }
  return data;
}

export async function resolverDiferenciaOnboarding(clienteId, campo, accion) {
  const { error } = await sb.rpc('cs_onboarding_diferencia_resolver',
    { p_cliente: clienteId, p_campo: campo, p_accion: accion });
  if (error) throw error;
}

/* Filas { cliente_id, estado, hechos, total, ultimo_at }. [] si la 093 no está. */
export async function traerAvanceOnboarding(programaId) {
  const { data, error } = await sb.rpc('cs_onboarding_avance', { p_programa: programaId });
  if (error) {
    if (faltaFuncion(error)) return [];
    throw error;
  }
  return data || [];
}

/* Filas { cliente_id, cliente, tipo: 'completo' | 'demorado', dias, hechos, total, fecha }. */
export async function traerOnboardingHoy(programaId) {
  const { data, error } = await sb.rpc('cs_onboarding_hoy', { p_programa: programaId });
  if (error) {
    if (faltaFuncion(error)) return [];
    throw error;
  }
  return data || [];
}

/* Pestaña "Onboarding" (096). Una fila por alumno no finalizado ni dado de baja:
   { cliente_id, nombre, estado_cliente, producto_id, producto, resell, fecha_alta,
     onboarding: sin_link | pendiente | en_curso | completado | sin_plantilla,
     hechos, total, paso_actual, ultimo_movimiento, link_vence_at, skool, wpp }.
   undefined = la 096 no se corrió (la pestaña avisa); skool/wpp null = ese dato no existe. */
export async function traerListaOnboarding(programaId) {
  const { data, error } = await sb.rpc('cs_onboarding_lista', { p_programa: programaId });
  if (error) {
    if (faltaFuncion(error)) return undefined;
    throw error;
  }
  return data || [];
}
