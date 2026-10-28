/* Hoja "Llamadas Producto" del Maestro de BPF (liam): llamadas de resell / churn que agenda el equipo de Producto.
   Tabla cs_llamadas_producto (238). Editable en la app (reemplaza al sheet): ve quien ve el programa, escribe quien lo edita (RLS). */
import { sb } from './supabase.js';

const faltaTabla = error => error.code === '42P01' || error.code === 'PGRST205' || /cs_llamadas_producto/.test(error.message || '');

/* undefined = la tabla no existe (falta correr la migración 238). */
export async function traerLlamadasProducto(programaId) {
  const { data, error } = await sb.from('cs_llamadas_producto').select('*')
    .eq('programa_id', programaId).order('fila_origen');
  if (error) {
    if (faltaTabla(error)) return undefined;
    throw error;
  }
  return data || [];
}

export async function guardarLlamadaProducto(id, cambios) {
  const { error } = await sb.from('cs_llamadas_producto').update({ ...cambios, updated_at: new Date().toISOString() }).eq('id', id);
  if (error) throw error;
}

/* Fila nueva al final. fila_origen = la más alta + 1 (si otra persona agregó una al mismo tiempo, reintenta una vez). */
export async function crearLlamadaProducto(programaId, filasActuales) {
  let siguiente = filasActuales.reduce((m, f) => Math.max(m, f.fila_origen || 0), 0) + 1;
  for (let intento = 0; intento < 2; intento++) {
    const { data, error } = await sb.from('cs_llamadas_producto')
      .insert({ programa_id: programaId, fila_origen: siguiente }).select('*').single();
    if (!error) return data;
    if (error.code !== '23505') throw error;
    siguiente += 1;
  }
  throw new Error('No se pudo agregar la fila. Probá de nuevo.');
}

export async function borrarLlamadaProducto(id) {
  const { error } = await sb.from('cs_llamadas_producto').delete().eq('id', id);
  if (error) throw error;
}
