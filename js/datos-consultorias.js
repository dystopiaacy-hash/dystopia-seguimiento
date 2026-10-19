/* Grupales vs VIP y consultorías grupales (157).
   - Horarios recurrentes (cs_consultoria_horarios): los carga el fundador; lee quien ve el programa.
   - Modalidad del alumno (cs_clientes.modalidad + cs_v_modalidad): editable en la ficha.
   - Consultorías a las que asistió un alumno (cs_consultoria_asistentes + cs_consultorias).
   Sin la 157 las lecturas devuelven undefined / null y la app se ve como antes. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';

/* ISO: 1 lunes ... 7 domingo (igual que cs_consultoria_horarios.dia_semana). */
export const DIAS_SEMANA = [[1, 'Lunes'], [2, 'Martes'], [3, 'Miércoles'], [4, 'Jueves'], [5, 'Viernes'], [6, 'Sábado'], [7, 'Domingo']];
export const CLASE_LLAMADA = { onboarding: 'Onboarding', uno_a_uno: '1 a 1', consultoria: 'Consultoría grupal', otra: 'Otra' };
export const MODALIDAD_LABEL = { grupal: 'Grupal', vip: 'VIP / 1 a 1' };

const COLS_H = 'id,programa_id,consultor,dia_semana,hora,duracion_min,tolerancia_min,activo,nota';

/* Todos los horarios que ve el usuario. undefined = 157 sin correr. */
export async function traerHorarios() {
  const { data, error } = await sb.from('cs_consultoria_horarios').select(COLS_H)
    .order('programa_id').order('dia_semana').order('hora');
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Consultorías ya registradas (las más nuevas primero; la RLS deja solo las de los programas que ve el usuario).
   [] si falta la 157. */
export async function traerConsultoriasRegistradas() {
  const { data, error } = await sb.from('cs_consultorias')
    .select('id,programa_id,horario_id,consultor,fecha,inicio_at,titulo,duracion_min,grabacion_url,grabacion_share_url,resumen,invitados')
    .order('inicio_at', { ascending: false }).limit(500);
  if (error) {
    if (faltaObjeto(error)) return [];
    throw error;
  }
  return data || [];
}

/* Cuentas de Fathom (consultores) para elegir en el horario. */
export async function traerConsultores() {
  const { data, error } = await sb.from('cs_fathom_consultores').select('id,nombre,activo').order('orden').order('id');
  if (error) {
    if (faltaObjeto(error)) return [];
    throw error;
  }
  return data || [];
}

/* h = { id?, programa_id, consultor, dia_semana, hora 'HH:MM', duracion_min, tolerancia_min, activo, nota }. */
export async function guardarHorario(h) {
  const fila = {
    programa_id: h.programa_id, consultor: h.consultor, dia_semana: Number(h.dia_semana), hora: h.hora,
    duracion_min: Number(h.duracion_min), tolerancia_min: Number(h.tolerancia_min), activo: !!h.activo,
    nota: (h.nota || '').trim() || null
  };
  const q = h.id ? sb.from('cs_consultoria_horarios').update(fila).eq('id', h.id)
    : sb.from('cs_consultoria_horarios').insert(fila);
  const { error } = await q;
  if (error) throw error;
}

/* Reclasifica por tandas (194): repite hasta que no quede nada o una tanda no avance (tope 40 tandas).
   onProgreso({ hechas, quedan }) se llama después de cada tanda.
   -> { pendientes_reclasificadas, quedan, omitidas_de_alumno, omitidas_confirmadas, consultorias } */
export async function reclasificarConsultorias(onProgreso) {
  let hechas = 0, ultimo = {};
  for (let i = 0; i < 40; i++) {
    const { data, error } = await sb.rpc('cs_consultoria_reclasificar', { p_limite: 25 });
    if (error) throw error;
    ultimo = data || {};
    const n = ultimo.pendientes_reclasificadas || 0;
    hechas += n;
    if (onProgreso) onProgreso({ hechas, quedan: ultimo.quedan || 0 });
    if (!n || !(ultimo.quedan > 0)) break;
  }
  return { ...ultimo, pendientes_reclasificadas: hechas };
}

/* Programas de cada cuenta de Fathom (194): Map consultor -> [programa_id]. undefined = 194 sin correr. */
export async function traerConsultorProgramas() {
  const { data, error } = await sb.from('cs_fathom_consultor_programas').select('consultor,programa_id');
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  const m = new Map();
  for (const r of data || []) m.set(r.consultor, [...(m.get(r.consultor) || []), r.programa_id]);
  return m;
}

/* Reemplaza los programas de un consultor (solo fundador). */
export async function guardarConsultorProgramas(consultor, programas) {
  const { error } = await sb.rpc('cs_fathom_consultor_programas_guardar', { p_consultor: consultor, p_programas: programas });
  if (error) throw error;
}

/* { modalidad, modalidad_manual, modalidad_auto, origen } o undefined (157 sin correr). */
export async function traerModalidadCliente(clienteId) {
  const { data, error } = await sb.from('cs_v_modalidad')
    .select('modalidad,modalidad_manual,modalidad_auto,origen').eq('cliente_id', clienteId).maybeSingle();
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || null;
}

/* valor: 'grupal' | 'vip' | '' (automática). */
export async function guardarModalidad(clienteId, valor) {
  const { error } = await sb.from('cs_clientes').update({ modalidad: valor || null }).eq('id', clienteId);
  if (error) throw error;
}

/* Consultorías a las que asistió: [{ consultoria_id, hablo, via, fecha, titulo, consultor }] (la más nueva primero). */
export async function traerConsultoriasCliente(clienteId) {
  const { data, error } = await sb.from('cs_consultoria_asistentes')
    .select('consultoria_id,hablo,via,cs_consultorias(fecha,titulo,consultor)').eq('cliente_id', clienteId).limit(60);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return (data || []).filter(r => r.cs_consultorias).map(r => ({
    consultoria_id: r.consultoria_id, hablo: r.hablo, via: r.via,
    fecha: r.cs_consultorias.fecha, titulo: r.cs_consultorias.titulo, consultor: r.cs_consultorias.consultor
  })).sort((a, b) => (a.fecha < b.fecha ? 1 : -1));
}

/* Mapa llamada_id -> clase (onboarding | uno_a_uno | consultoria | otra) de las llamadas de un alumno. */
export async function traerClasesLlamadas(clienteId) {
  const { data, error } = await sb.from('cs_v_llamadas_clase').select('llamada_id,clase').eq('cliente_id', clienteId);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return new Map((data || []).map(r => [r.llamada_id, r.clase]));
}
