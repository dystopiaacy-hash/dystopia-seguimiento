/* Hoja "Fuera del maestro" de DCAC: filas que el CSM sacó del Maestro (señas que se completaron en
   otra fila, filas duplicadas, comprobantes extra, notas sueltas). Tabla cs_fuera_maestro (solo lectura acá). */
import { sb } from './supabase.js';

/* undefined = la tabla no existe (falta correr la migración de la estructura de agus). */
export async function traerFueraMaestro(programaId) {
  const { data, error } = await sb.from('cs_fuera_maestro').select('*')
    .eq('programa_id', programaId).order('fila_origen');
  if (error) {
    if (error.code === '42P01' || error.code === 'PGRST205' || /cs_fuera_maestro/.test(error.message || '')) return undefined;
    throw error;
  }
  return data || [];
}
