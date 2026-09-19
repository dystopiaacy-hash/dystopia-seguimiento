/* Caché en memoria por tabla + suscripción realtime.
   Las vistas leen de acá (get) y se enteran de cambios con onChange. */
import { sb } from './supabase.js';

const cache = new Map();      // tabla -> Map(id -> fila)
const listeners = new Set();  // fn(tabla, evento, fila)
let canal = null;

export function get(tabla) {
  const m = cache.get(tabla);
  return m ? Array.from(m.values()) : [];
}

export function getById(tabla, id) {
  const m = cache.get(tabla);
  return m ? m.get(id) || null : null;
}

export function onChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function notificar(tabla, evento, fila) {
  for (const fn of listeners) {
    try { fn(tabla, evento, fila); } catch (e) { console.error(e); }
  }
}

/* Carga completa de una tabla (reemplaza su caché). `armar` permite agregar filtros/orden. */
export async function cargar(tabla, armar) {
  let q = sb.from(tabla).select('*');
  if (armar) q = armar(q);
  const { data, error } = await q;
  if (error) throw error;
  cache.set(tabla, new Map(data.map(f => [f.id, f])));
  notificar(tabla, 'LOAD', null);
  return data;
}

function aplicarCambio(tabla, payload) {
  if (!cache.has(tabla)) cache.set(tabla, new Map());
  const m = cache.get(tabla);
  const { eventType, new: nueva, old: vieja } = payload;
  if (eventType === 'DELETE') {
    if (vieja && vieja.id != null) m.delete(vieja.id);
    notificar(tabla, eventType, vieja);
  } else {
    m.set(nueva.id, nueva);
    notificar(tabla, eventType, nueva);
  }
}

/* Realtime respeta RLS: cada usuario solo recibe cambios de filas que puede leer.
   Requiere que las tablas estén en la publicación supabase_realtime (se hace por migración).
   onEstado(status): 'SUBSCRIBED' | 'CHANNEL_ERROR' | 'TIMED_OUT' | 'CLOSED' (para el indicador "En vivo"). */
export function suscribir(tablas, onEstado) {
  desuscribir();
  const este = sb.channel('cs-cambios');
  canal = este;
  for (const t of tablas) {
    este.on('postgres_changes', { event: '*', schema: 'public', table: t }, p => aplicarCambio(t, p));
  }
  este.subscribe(status => {
    if (onEstado && canal === este) onEstado(status);
  });
}

export function desuscribir() {
  if (canal) { sb.removeChannel(canal); canal = null; }
}

export function limpiar() {
  desuscribir();
  cache.clear();
}
