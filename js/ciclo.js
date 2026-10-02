/* Producto y ciclo del cliente (039): catálogo de productos del programa, pausa,
   los dos avisos de renovación y testimonio. Separado de datos.js por tamaño.
   Las reglas viven en la base (cs_tg_clientes_before, cs_tg_renovaciones_before):
   acá solo se leen, se escriben y se calculan los textos de previsualización. */
import { sb } from './supabase.js';
import { actualizarFila } from './datos.js';
import { hoyAR, sumarDias, diasEntre } from './ui.js';

export const TESTIMONIO_LABEL = {
  sin_pedir: 'Sin pedir', pitchiado: 'Pitchiado', coordinado: 'Coordinado',
  grabado: 'Grabado', no_quiere: 'No quiere'
};
export const TESTIMONIO_COLOR = {
  sin_pedir: 'var(--text-faint)', pitchiado: 'var(--sem-amarillo)',
  coordinado: 'var(--sem-amarillo)', grabado: 'var(--sem-verde)', no_quiere: 'var(--sem-rojo)'
};

/* Datos de la call de resell (cs_calls tipo 'renovacion'). */
export const CALIFICACION_LABEL = { calificado: 'Calificado', no_calificado: 'No calificado' };

/* ---------- Lecturas ---------- */

/* Todos los productos del programa, activos o no: un inactivo sigue valiendo para
   los clientes que ya lo tienen. Los selectores muestran solo los activos + el actual. */
export async function traerProductos(programaId) {
  const { data, error } = await sb.from('cs_productos').select('*')
    .eq('programa_id', programaId).order('orden').order('nombre');
  if (error) throw error;
  return data || [];
}

/* cs_v_clientes no trae las columnas de 039 (mantiene sus columnas): se piden aparte. */
export async function traerCicloCliente(id) {
  const { data, error } = await sb.from('cs_clientes')
    .select('producto_id,pausado_desde,aviso_1_at,aviso_2_at,testimonio').eq('id', id).maybeSingle();
  if (error) throw error;
  return data || {};
}

/* Pares [id, "Nombre (N días)"] para un <select>: activos, más el actual si está inactivo. */
export function opcionesProducto(productos, actual) {
  return (productos || [])
    .filter(pr => pr.activo || pr.id === actual)
    .map(pr => [pr.id, `${pr.nombre} (${pr.duracion_dias} días)${pr.activo ? '' : ' · inactivo'}`]);
}

export const nombreProducto = (productos, id) => {
  const pr = (productos || []).find(x => x.id === id);
  return pr ? pr.nombre : '';
};

/* ---------- Pausa ---------- */

/* Días que lleva pausado (hoy - pausado_desde). */
export function diasPausado(c) {
  return c && c.pausado_desde ? Math.max(0, diasEntre(c.pausado_desde, hoyAR())) : 0;
}

/* Fin "vigente": el de la base, corrido por los días de pausa si está pausado.
   Es lo que la base usa al reanudar y al cerrar una renovación con producto. */
export function finVigente(c) {
  if (!c || !c.fecha_fin) return '';
  return c.estado === 'pausado' ? sumarDias(c.fecha_fin, diasPausado(c)) : c.fecha_fin;
}

/* La base completa pausado_desde (hoy si no viene) y congela los días del programa. */
export const pausarCliente = (id, desde = null) =>
  actualizarFila('cs_clientes', id, { estado: 'pausado', pausado_desde: desde || null });

/* Vuelve a activo; la base corre fecha_fin por los días pausados y, si hay una
   renovación abierta, lo deja en 'en_renovacion'. */
export const reanudarCliente = id => actualizarFila('cs_clientes', id, { estado: 'activo' });

/* ---------- Avisos de renovación ---------- */

/* Fecha sugerida de cada aviso: fin - aviso_1_dias / fin - aviso_2_dias. */
export function fechaSugeridaAviso(c, p, n) {
  const dias = Number(n === 1 ? p.aviso_1_dias : p.aviso_2_dias);
  const fin = finVigente(c);
  return fin && Number.isFinite(dias) ? sumarDias(fin, -dias) : '';
}

/* Un 'YYYY-MM-DD' se guarda al mediodía de Buenos Aires: el día no se corre. */
function tsDeFecha(fecha) {
  return fecha ? `${fecha}T12:00:00-03:00` : null;
}

/* fecha = 'YYYY-MM-DD' | null (borra el registro) | undefined (ahora). */
export function registrarAviso(id, n, fecha) {
  if (n !== 1 && n !== 2) throw new Error('Aviso inválido.');
  const v = fecha === undefined ? new Date().toISOString() : tsDeFecha(fecha);
  return actualizarFila('cs_clientes', id, { [n === 1 ? 'aviso_1_at' : 'aviso_2_at']: v });
}

/* ---------- Renovación con producto ---------- */

/* Misma cuenta que cs_tg_renovaciones_before: la mayor entre el fin vigente y hoy,
   + la duración del producto. Solo para mostrar: la base la vuelve a calcular. */
export function finConProducto(c, producto) {
  if (!producto) return '';
  const fin = finVigente(c);
  const base = fin && fin > hoyAR() ? fin : hoyAR();
  return sumarDias(base, Number(producto.duracion_dias) || 0);
}
