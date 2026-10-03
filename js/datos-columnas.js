/* Columnas configurables del Maestro (071). Separado de datos.js por tamaño.
   cs_maestro_columnas solo tiene filas de lo que se tocó: una columna del sistema
   sin fila va con su nombre y su orden de siempre. Cambia la estructura solo un
   fundador (lo valida la base); los valores los edita cualquiera con acceso. */
import { sb } from './supabase.js';
import { mensajeError } from './datos.js';

export const TIPO_COLUMNA_LABEL = {
  texto: 'Texto', numero: 'Número', fecha: 'Fecha', casilla: 'Casilla', opcion: 'Opciones', link: 'Link'
};

/* La tabla no existe: la 071 no se corrió (42P01 de Postgres, PGRST205 de PostgREST). */
function faltaTabla(e) {
  return e.code === '42P01' || e.code === 'PGRST205'
    || (/cs_maestro_columnas/.test(e.message || '') && /does not exist|schema cache/i.test(e.message || ''));
}

/* Config del programa. null = sin 071: el Maestro se dibuja como siempre. */
export async function traerColumnasMaestro(programaId) {
  const { data, error } = await sb.from('cs_maestro_columnas')
    .select('clave,sistema,etiqueta,orden,visible,tipo,opciones,archivada')
    .eq('programa_id', programaId).order('created_at');
  if (error) {
    if (faltaTabla(error)) return null;
    throw error;
  }
  return data || [];
}

async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

/* etiqueta null = nombre original (solo en las del sistema). opciones null = no se tocan. */
export const guardarColumna = (programaId, clave, { etiqueta = null, visible = true, opciones = null } = {}) =>
  rpc('cs_maestro_columna_guardar', {
    p_programa: programaId, p_clave: clave, p_etiqueta: etiqueta, p_visible: visible, p_opciones: opciones
  });

/* Devuelve la clave nueva (x_...). */
export const crearColumna = (programaId, etiqueta, tipo, opciones = []) =>
  rpc('cs_maestro_columna_crear', {
    p_programa: programaId, p_etiqueta: etiqueta, p_tipo: tipo, p_opciones: tipo === 'opcion' ? opciones : []
  });

/* claves = el orden completo, incluidas las ocultas. */
export const ordenarColumnas = (programaId, claves) =>
  rpc('cs_maestro_columnas_ordenar', { p_programa: programaId, p_claves: claves });

export const archivarColumna = (programaId, clave, archivar = true) =>
  rpc('cs_maestro_columna_archivar', { p_programa: programaId, p_clave: clave, p_archivar: archivar });

/* Renombra la opción y los valores ya cargados en los clientes. */
export const renombrarOpcion = (programaId, clave, viejo, nuevo) =>
  rpc('cs_maestro_opcion_renombrar', { p_programa: programaId, p_clave: clave, p_viejo: viejo, p_nuevo: nuevo });

/* valor: string | number | boolean | null (null borra la clave). */
export const guardarCampoExtra = (clienteId, clave, valor) =>
  rpc('cs_guardar_campo_extra', { p_cliente: clienteId, p_clave: clave, p_valor: valor });

/* Las funciones de 071 ya hablan en castellano ("cs: ..."). */
export function errorColumnas(e) {
  if (e && e.code === 'PGRST202') return 'Esa función todavía no existe en la base: falta correr la migración 071.';
  return mensajeError(e).replace(/^cs: /, '');
}
