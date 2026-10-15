/* Preguntas detectadas en llamadas de Fathom como candidatas a duda frecuente (134).
   - Lectura: cs_duda_candidatas (RLS: quien ve el programa).
   - Acciones: RPC cs_duda_cand_agregar / crear / descartar / reabrir (fundador, cliente del
     programa o edición; la base lo impone).
   - Reprocesar: cs_dudas_reprocesar (solo fundador), en tandas hasta restantes = 0.
   Sin la 134 las lecturas devuelven undefined. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';
import { yo, esFundador, puedeEditarPrograma } from './sesion.js';

/* Gestionar = la misma regla de la base (cs_duda_puede_gestionar). */
export function puedeGestionarDudas(programaId) {
  return esFundador() || puedeEditarPrograma(programaId)
    || (yo.rol === 'cliente' && yo.programas.some(p => p.id === programaId));
}

/* filtros: { estado: 'pendiente'|'agregada'|'descartada'|'', desde, hasta, consultor, soloAlta }
   soloAlta (135): oculta las de baja confianza. Sin la 135 la columna no existe y se pide sin ella. */
export async function traerCandidatas(programaId, { estado = 'pendiente', desde = '', hasta = '', consultor = '', soloAlta = false } = {}) {
  const base = 'id,cliente_id,llamada_id,fecha,consultor,hablante,texto,regla,estado,duda_id,resuelta_at';
  const pedir = (cols, conConfianza) => {
    let q = sb.from('cs_duda_candidatas').select(cols).eq('programa_id', programaId);
    if (estado) q = q.eq('estado', estado);
    if (desde) q = q.gte('fecha', desde);
    if (hasta) q = q.lte('fecha', hasta);
    if (consultor) q = q.eq('consultor', consultor);
    if (conConfianza && soloAlta) q = q.eq('confianza', 'alta');
    return q.order('fecha', { ascending: false }).order('created_at', { ascending: false }).limit(500);
  };
  let { data, error } = await pedir(base + ',confianza,motivo', true);
  if (error && error.code === '42703') ({ data, error } = await pedir(base, false));
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* { pendientes, pendientes_alta, pendientes_baja, agregadas, descartadas, llamadas, sin_procesar, sin_hablante, ambiguas }
   o null si no se pudo (las claves de confianza y ambiguas existen desde la 135). */
export async function estadoCandidatas(programaId) {
  const { data, error } = await sb.rpc('cs_dudas_estado', { p_programa: programaId });
  if (error) return null;
  return data;
}

/* id -> nombre visible del consultor (para el filtro). Si falla, el filtro muestra el id. */
export async function nombresConsultores() {
  const { data, error } = await sb.from('cs_fathom_consultores').select('id,nombre');
  if (error) return new Map();
  return new Map((data || []).map(c => [c.id, c.nombre]));
}

export async function agregarCandidata(candidataId, dudaId) {
  const { data, error } = await sb.rpc('cs_duda_cand_agregar', { p_candidata: candidataId, p_duda: dudaId });
  if (error) throw error;
  return data;
}

/* texto null = el de la candidata. Devuelve { duda_id, nueva }. */
export async function crearDesdeCandidata(candidataId, texto = null) {
  const { data, error } = await sb.rpc('cs_duda_cand_crear', { p_candidata: candidataId, p_texto: texto });
  if (error) throw error;
  return data;
}

export async function descartarCandidatas(ids) {
  const { data, error } = await sb.rpc('cs_duda_cand_descartar', { p_ids: ids });
  if (error) throw error;
  return data;
}

export async function reabrirCandidata(id) {
  const { error } = await sb.rpc('cs_duda_cand_reabrir', { p_candidata: id });
  if (error) throw error;
}

/* Reglas de detección (135): { regla_palabra, min_palabras, max_por_llamada, filtrar_segunda_persona } o null. */
export async function leerReglasDudas(programaId) {
  const { data, error } = await sb.rpc('cs_dudas_config_leer', { p_programa: programaId });
  if (error) return null;
  return data;
}

/* Solo fundador. Devuelve las reglas vigentes. */
export async function guardarReglasDudas(programaId, r) {
  const { data, error } = await sb.rpc('cs_dudas_config_guardar', {
    p_programa: programaId, p_regla_palabra: r.regla_palabra, p_min_palabras: r.min_palabras,
    p_max_por_llamada: r.max_por_llamada, p_filtrar_segunda_persona: r.filtrar_segunda_persona
  });
  if (error) throw error;
  return data;
}

/* Reprocesa todas las llamadas del programa en tandas. alProgreso({ procesadas, nuevas, restantes }). */
export async function reprocesarDudas(programaId, alProgreso = () => {}) {
  let corte = null, procesadas = 0, nuevas = 0, vueltas = 0;
  for (;;) {
    const { data, error } = await sb.rpc('cs_dudas_reprocesar', { p_programa: programaId, p_corte: corte, p_limite: 40 });
    if (error) throw error;
    corte = data.corte;
    procesadas += data.procesadas;
    nuevas += data.nuevas;
    alProgreso({ procesadas, nuevas, restantes: data.restantes });
    vueltas += 1;
    if (!data.restantes || !data.procesadas || vueltas > 200) return { procesadas, nuevas, restantes: data.restantes };
  }
}
