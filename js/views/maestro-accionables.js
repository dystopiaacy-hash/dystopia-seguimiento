/* Maestro — columnas que MUESTRAN accionables de la plantilla (238, liam / BPF).
   El sheet de BPF tiene "¿Lo saqué de Skool / WPP?", "¿Le pedí referidos?" y FUP 1 / 2 / 3 como casillas; en la app son accionables
   (Skool y WPP son ítems de cierre) y esa lógica no cambia. Estas columnas (x_acc_*, tipo casilla en cs_maestro_columnas) reflejan
   el estado del accionable: tildado = completado. Tildar o destildar acá completa o reabre el accionable (igual que la casilla de la
   ficha). Si el alumno no tiene ese accionable (programa viejo, ficha sin plantilla), la casilla guarda en campos_extra como cualquier
   columna casilla y queda lista para cuando el accionable exista. */
import { esc } from '../ui.js';
import { sb } from '../supabase.js';
import { actualizarFila } from '../datos.js';

/* clave de la columna -> cómo se reconoce su accionable (plantilla_key exacta, o prefijo para los de cierre: cierre:<key>:<fecha_fin>). */
const ACC = {
  x_acc_referidos: { clave: 'pedir_referidos' },
  x_acc_fup_1: { clave: 'fup_1' },
  x_acc_fup_2: { clave: 'fup_2' },
  x_acc_fup_3: { clave: 'fup_3' },
  x_acc_skool: { prefijo: 'cierre:cierre_skool:' },
  x_acc_wpp: { prefijo: 'cierre:cierre_whatsapp:' }
};

export const esColumnaAccionable = clave => Object.prototype.hasOwnProperty.call(ACC, clave);

const columnaDe = key => Object.keys(ACC).find(k => ACC[k].clave === key || (ACC[k].prefijo && key.startsWith(ACC[k].prefijo)));

/* Pega f.acc = { x_acc_...: { id, estado, key } } en cada fila. Devuelve true si hay columnas de este tipo. Nunca tira. */
export async function sumarAccionablesMaestro(programaId, filas, config) {
  if (!(config || []).some(r => esColumnaAccionable(r.clave) && !r.archivada)) return false;
  const por = new Map();
  try {
    for (let desde = 0; ; desde += 1000) {
      const { data, error } = await sb.from('cs_accionables').select('id,cliente_id,plantilla_key,estado')
        .eq('programa_id', programaId)
        .or('plantilla_key.eq.pedir_referidos,plantilla_key.in.(fup_1,fup_2,fup_3),plantilla_key.like.cierre:cierre_skool:*,plantilla_key.like.cierre:cierre_whatsapp:*')
        .order('id').range(desde, desde + 999);
      if (error) throw error;
      for (const a of data || []) {
        const col = columnaDe(a.plantilla_key || '');
        if (!col) continue;
        const mapa = por.get(a.cliente_id) || por.set(a.cliente_id, {}).get(a.cliente_id);
        /* Los de cierre llevan la fecha de fin del ciclo en la clave: gana el más nuevo. */
        if (!mapa[col] || a.plantilla_key > mapa[col].key) mapa[col] = { id: a.id, estado: a.estado, key: a.plantilla_key };
      }
      if (!data || data.length < 1000) break;
    }
  } catch (e) {
    console.error('accionables del maestro', e);
  }
  for (const f of filas) f.acc = por.get(f.id) || {};
  return true;
}

const completo = (f, k) => {
  const a = (f.acc || {})[k];
  return a ? a.estado === 'completado' : (f.campos_extra || {})[k] === true;
};

export const ordenAccionable = (f, k) => (completo(f, k) ? 0 : 1);

/* Celda: con accionable -> data-extra="accionable"; sin accionable -> casilla común (campos_extra). */
export function celdaAccionable(col, f) {
  const a = (f.acc || {})[col.k];
  const marca = completo(f, col.k);
  const tipo = a ? 'accionable' : 'casilla';
  const ayuda = a ? 'Refleja el accionable de la plantilla: tildar lo completa, destildar lo reabre.' : 'Este alumno no tiene el accionable: se guarda como casilla.';
  return `<input type="checkbox" class="m-check"${marca ? ' checked' : ''} id="mx-${esc(col.k)}-${esc(f.id)}" data-campo="${esc(col.k)}"
    data-extra="${tipo}" data-id="${esc(f.id)}" data-prev="${marca ? '1' : ''}" title="${esc(ayuda)}"
    aria-label="${esc(col.lab + ' de ' + f.nombre)}">`;
}

/* Completa o reabre el accionable de la fila. Lanza si falla (el llamador revierte la casilla). */
export async function guardarEstadoAccionable(fila, clave, tildado) {
  const a = (fila.acc || {})[clave];
  if (!a) throw new Error('El alumno no tiene ese accionable.');
  await actualizarFila('cs_accionables', a.id, { estado: tildado ? 'completado' : 'pendiente' });
  a.estado = tildado ? 'completado' : 'pendiente';
}
