/* Estado de pagos del alumno (133 usa la 129 y la 132 de Finanzas). SIN montos.
   Lee public.cs_estado_pagos_alumno(p_cs_ids uuid[]): una fila por ficha que quien llama puede ver,
   máximo 500 ids por llamada. vinculo = 'vinculado' | 'sin_vinculo' (sin_vinculo: contadores null = sin dato).
   Sin la 132 la función no existe: las lecturas devuelven null y la pantalla dice "sin datos todavía". */
import { sb } from './supabase.js';
import { faltaObjeto } from './datos-faltante.js';

const LOTE = 500;

/* Mapa cs_cliente_id -> fila. null = 132 sin correr. Una llamada por lote de hasta 500 ids, nunca una por fila. */
export async function traerEstadoPagos(ids) {
  const lista = [...new Set((ids || []).filter(Boolean))];
  const mapa = new Map();
  for (let i = 0; i < lista.length; i += LOTE) {
    const { data, error } = await sb.rpc('cs_estado_pagos_alumno', { p_cs_ids: lista.slice(i, i + LOTE) });
    if (error) {
      if (faltaObjeto(error)) return null;
      throw error;
    }
    for (const r of data || []) mapa.set(r.cs_cliente_id, r);
  }
  return mapa;
}

/* Nunca tira: pega f.pagos en cada fila (undefined = la ficha no vino en la respuesta: sin permiso).
   false = 132 sin correr o error (la columna no se muestra). */
export async function sumarEstadoPagos(filas) {
  let mapa = null;
  try {
    mapa = await traerEstadoPagos(filas.map(f => f.id));
  } catch (e) {
    console.error('estado de pagos', e);
  }
  if (!mapa) return false;
  for (const f of filas) f.pagos = mapa.get(f.id) || null;
  return true;
}

/* 'sin_dato' | 'sin_vinculo' | 'atrasado' | 'al_dia' */
export function nivelPagos(p) {
  if (!p) return 'sin_dato';
  if (p.vinculo !== 'vinculado') return 'sin_vinculo';
  if (p.cuotas_total == null) return 'sin_dato';
  return (p.cuotas_atrasadas || 0) > 0 ? 'atrasado' : 'al_dia';
}
