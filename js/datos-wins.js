/* Wins y marca de upsell (106). Separado de datos.js por tamaño.
   Escrituras directo a cs_wins y cs_upsell_marcas (RLS: crear/editar = cs_puede_editar,
   borrar = solo fundador). La base avisa a Discord al crear un win y deja el pendiente
   "Pedir referido" (referido_estado = 'pendiente'). Sin la 106, las lecturas devuelven undefined. */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';

export const WIN_TIPO_LABEL = {
  resultado_economico: 'Resultado económico', hito: 'Hito', testimonio: 'Testimonio', otro: 'Otro'
};
export const REFERIDO_LABEL = { pendiente: 'Referido sin pedir', pedido: 'Referido pedido', descartado: 'Referido descartado' };

const COLS = 'id,cliente_id,fecha,texto,tipo,monto,referido_estado,referido_at,created_at';

/* Wins del alumno, el más nuevo primero. undefined = 106 sin correr. */
export async function traerWinsCliente(clienteId) {
  const { data, error } = await sb.from('cs_wins').select(COLS)
    .eq('cliente_id', clienteId).order('fecha', { ascending: false }).order('created_at', { ascending: false });
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* Referidos para pedir en Hoy. undefined = 106 sin correr. */
export async function traerReferidosPendientes(programaId) {
  const { data, error } = await sb.from('cs_wins').select(COLS)
    .eq('programa_id', programaId).eq('referido_estado', 'pendiente')
    .order('fecha', { ascending: false }).limit(200);
  if (error) {
    if (faltaObjeto(error)) return undefined;
    throw error;
  }
  return data || [];
}

/* w = { fecha, texto, tipo, monto }. El monto es opcional. */
export async function crearWin(programaId, clienteId, w) {
  const monto = w.monto === '' || w.monto == null ? null : Number(w.monto);
  if (monto != null && (!Number.isFinite(monto) || monto < 0)) throw new Error('El monto tiene que ser un número positivo.');
  const { error } = await sb.from('cs_wins').insert({
    programa_id: programaId, cliente_id: clienteId, fecha: w.fecha,
    texto: String(w.texto || '').trim(), tipo: w.tipo || 'otro', monto
  });
  if (error) throw error;
}

/* estado: 'pedido' | 'descartado' | 'pendiente' (deshacer). Quién y cuándo lo pone la base. */
export async function resolverReferido(winId, estado) {
  const { error } = await sb.from('cs_wins').update({ referido_estado: estado }).eq('id', winId);
  if (error) throw error;
}

/* Marca o actualiza el "listo para upsell" del alumno. */
export async function marcarUpsell(programaId, clienteId, motivo) {
  const { error } = await sb.from('cs_upsell_marcas').upsert(
    { cliente_id: clienteId, programa_id: programaId, motivo: String(motivo || '').trim(), activo: true },
    { onConflict: 'cliente_id' });
  if (error) throw error;
}

/* Quitar la marca no borra la fila (borrar es del fundador): queda inactiva. */
export async function quitarUpsell(clienteId) {
  const { error } = await sb.from('cs_upsell_marcas').update({ activo: false }).eq('cliente_id', clienteId);
  if (error) throw error;
}
