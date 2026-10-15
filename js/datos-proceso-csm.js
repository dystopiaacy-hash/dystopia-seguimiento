/* Proceso CSM semanal (130): cadencia por programa en cs_proceso_csm_config (lectura: quien ve el
   programa; escritura: solo fundador) y dos RPC solo del fundador:
     cs_csm_resumen(p_programa)  vista previa, cuenta lo que haría hoy sin escribir
     cs_csm_generar(p_programa)  corre el generador ahora (el chequeo diario ya lo corre solo).
   Sin la 130 la lectura devuelve null y la pantalla avisa que falta la migración. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';

const COLS = 'programa_id,activo,referidos_semanas,resell_dias';

/* Fila de cs_proceso_csm_config o null (130 sin correr o programa sin fila). */
export async function traerConfigCsm(programaId) {
  const { data, error } = await sb.from('cs_proceso_csm_config').select(COLS)
    .eq('programa_id', programaId).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return null;
    throw error;
  }
  return data || null;
}

export async function guardarConfigCsm(programaId, valores) {
  const { error } = await sb.from('cs_proceso_csm_config')
    .upsert({ programa_id: programaId, ...valores }, { onConflict: 'programa_id' });
  if (error) throw error;
}

/* { crear, cubierto_win, saltado_viejo, futuro, ... }: cuántos pasos hay en cada situación hoy. */
export async function resumenCsm(programaId) {
  const { data, error } = await sb.rpc('cs_csm_resumen', { p_programa: programaId });
  if (error) throw error;
  return data || {};
}

export async function generarCsm(programaId) {
  const { data, error } = await sb.rpc('cs_csm_generar', { p_programa: programaId });
  if (error) throw error;
  return data || {};
}
