/* Parámetros de servicio por programa (123): umbral "sin llamada" (aviso y alerta), hora del
   aviso diario de Discord, días de moroso y de accionables de llamadas. Viven en
   cs_servicio_config (lectura: quien ve el programa; escritura: solo fundador).
   Sin la 123 las lecturas devuelven null y se usan los valores por defecto de js/config.js. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';
import { LLAMADA_AMARILLO_DESDE, LLAMADA_ROJO_DESDE } from './config.js';

const COLS = 'programa_id,llamada_aviso_dias,llamada_alerta_dias,hora_aviso,morosos_dias,acc_llamada_dias';

/* Umbral en uso: el del último programa cargado (las pantallas lo cargan antes de pintar). */
let actual = { programa: null, aviso: LLAMADA_AMARILLO_DESDE, alerta: LLAMADA_ROJO_DESDE };

export const umbralesLlamada = () => actual;

/* Fila de cs_servicio_config o null (123 sin correr o sin fila). Nunca tira por tabla faltante. */
export async function traerConfigServicio(programaId) {
  const { data, error } = await sb.from('cs_servicio_config').select(COLS)
    .eq('programa_id', programaId).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return null;
    throw error;
  }
  return data || null;
}

/* Carga el umbral del programa para el semáforo. Nunca tira: ante cualquier problema deja
   los valores por defecto de js/config.js. */
export async function cargarUmbrales(programaId, forzar = false) {
  if (!forzar && actual.programa === programaId) return actual;
  let aviso = LLAMADA_AMARILLO_DESDE, alerta = LLAMADA_ROJO_DESDE;
  try {
    const c = await traerConfigServicio(programaId);
    if (c) { aviso = c.llamada_aviso_dias; alerta = c.llamada_alerta_dias; }
  } catch (e) {
    console.error('umbral sin llamada', e);
  }
  actual = { programa: programaId, aviso, alerta };
  return actual;
}

export async function guardarConfigServicio(programaId, valores) {
  const { error } = await sb.from('cs_servicio_config')
    .upsert({ programa_id: programaId, ...valores }, { onConflict: 'programa_id' });
  if (error) throw error;
  await cargarUmbrales(programaId, true);
}

/* Botón "Probar aviso de servicio": manda el mensaje real del día al canal (solo fundador). */
export async function probarServicio(programaId) {
  const { data, error } = await sb.rpc('cs_servicio_probar', { p_programa: programaId });
  if (error) throw error;
  return data;
}
