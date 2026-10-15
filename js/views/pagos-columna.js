/* Clientes y Maestro: columna "Pagos" (indicador al día / atrasado / sin dato), sin montos.
   Los datos se cargan en lote con sumarEstadoPagos (datos-pagos.js). Sin la 132 la columna no existe. */
import { esc } from '../ui.js';
import { nivelPagos } from '../datos-pagos.js';

const ORDEN = { atrasado: 0, al_dia: 1, sin_vinculo: 2, sin_dato: 3 };

export function celdaPagos(f) {
  const n = nivelPagos(f.pagos);
  const p = f.pagos || {};
  if (n === 'atrasado') {
    const c = p.cuotas_atrasadas;
    return `<span class="est-chip pg-atrasado" title="${esc(`${c} ${c === 1 ? 'cuota atrasada' : 'cuotas atrasadas'}, máximo ${p.max_dias_atraso ?? 0} días`)}">Atrasado · ${esc(c)}</span>`;
  }
  if (n === 'al_dia') return '<span class="est-chip est-listo" title="Sin cuotas atrasadas">Al día</span>';
  if (n === 'sin_vinculo') return '<span class="est-chip" title="No está vinculado con un alumno de Finanzas">Sin vincular</span>';
  return '<span class="txt-gris" title="Sin datos de pagos">—</span>';
}

/* maestro = true: la celda abre la sección de la ficha como las otras calculadas. */
export function columnaPagos(cls = '', maestro = false) {
  const td = maestro
    ? f => `<button type="button" class="m-ir" data-mx-ir="pagos" data-id="${esc(f.id)}" title="Abrir en la ficha">${celdaPagos(f)}</button>`
    : celdaPagos;
  return { k: 'pagos', lab: 'Pagos', cls, ord: f => ORDEN[nivelPagos(f.pagos)], td };
}
