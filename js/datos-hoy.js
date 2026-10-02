/* Datos de la pantalla "Hoy": la cola (069) y las altas desde las ventas de
   Finanzas (070). Separado de datos.js por tamaño. */
import { sb } from './supabase.js';

/* ---------- Cola de hoy (069) ---------- */
export async function traerColaHoy(programaId, diasAdelante = 3) {
  const { data, error } = await sb.rpc('cs_cola_hoy', { p_programa: programaId, p_dias_adelante: diasAdelante });
  if (error) throw error;
  return data || [];
}

/* c = { canal, resultado, resumen, proximo }. Devuelve { seguimiento_id, renovacion_id, renovacion_estado }. */
export async function registrarContacto(clienteId, c) {
  const { data, error } = await sb.rpc('cs_registrar_contacto', { p_cliente: clienteId, p_canal: c.canal,
    p_resultado: c.resultado, p_resumen: (c.resumen || '').trim() || null, p_proximo: c.proximo || null });
  if (error) throw error;
  return data || {};
}

/* ---------- Altas desde pagos (070) ---------- */
/* Filas { pago_clave, fecha, alumno, telefono, programa, concepto }. Sin montos. */
export async function traerAltasPendientes(programaId) {
  const { data, error } = await sb.rpc('cs_altas_pendientes', { p_programa: programaId });
  if (error) throw error;
  return data || [];
}

/* estado: 'onboarding' | 'activo'. Devuelve el uuid del cliente creado. */
export async function crearClienteDesdePago(programaId, clave, productoId, estado) {
  const { data, error } = await sb.rpc('cs_crear_cliente_desde_pago',
    { p_programa: programaId, p_clave: clave, p_producto: productoId, p_estado: estado });
  if (error) throw error;
  return data;
}

export async function descartarAlta(programaId, clave, motivo) {
  const { error } = await sb.rpc('cs_descartar_alta',
    { p_programa: programaId, p_clave: clave, p_motivo: (motivo || '').trim() || null });
  if (error) throw error;
}
