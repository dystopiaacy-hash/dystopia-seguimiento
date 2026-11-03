/* Datos de la pantalla Comparar (#/p/:programa/comparar). Solo lecturas; no hay migración.
   Seguimientos hechos: cuenta filas de cs_seguimientos por fecha (columna date) en el programa.
   El resto sale de lo que ya trae Métricas (cs_v_metricas_mensuales y cs_v_clientes). */
import { sb } from './supabase.js';

/* Cantidad de seguimientos con fecha entre desde y hasta (ambos 'YYYY-MM-DD', inclusive). */
export async function contarSeguimientos(programaId, desde, hasta) {
  const { count, error } = await sb.from('cs_seguimientos').select('id', { count: 'exact', head: true })
    .eq('programa_id', programaId).gte('fecha', desde).lte('fecha', hasta);
  if (error) throw error;
  return count || 0;
}
