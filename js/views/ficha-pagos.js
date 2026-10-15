/* Ficha de cliente: bloque "Pagos" (estado de cuotas desde Finanzas, 129 y 132), SIN montos.
   ctx.pagos = { estado: fila de cs_estado_pagos_alumno | null } o { sinDatos: true } si la 132 no está
   corrida o falló. La fila ausente (sin permiso) se muestra como "sin datos". */
import { esc, fmtFecha } from '../ui.js';
import { esFundador } from '../sesion.js';
import { nivelPagos } from '../datos-pagos.js';
import { FINANZAS_VINCULAR_URL } from '../config.js';

function fila(lab, val) {
  return `<div class="est-bloque"><div class="est-lab">${esc(lab)}</div><div class="est-val">${val}</div></div>`;
}

export function html(ctx) {
  const g = ctx.pagos;
  if (!g) return '';
  const titulo = '<div class="section-title">Pagos<span class="line"></span></div>';
  if (g.sinDatos) {
    return `${titulo}<div class="card"><span class="txt-gris">Pagos: sin datos todavía</span></div>`;
  }
  const p = g.estado;
  const n = nivelPagos(p);
  if (n === 'sin_dato') {
    return `${titulo}<div class="card"><span class="txt-gris">Pagos: sin datos</span></div>`;
  }
  if (n === 'sin_vinculo') {
    const link = esFundador()
      ? ` <a href="${esc(FINANZAS_VINCULAR_URL)}" target="_blank" rel="noopener">Vincular alumnos en Finanzas</a>`
      : '';
    return `${titulo}<div class="card"><span class="est-chip">Sin vincular en Finanzas</span>${link}
      <div class="small txt-gris">No hay un alumno de Finanzas vinculado a esta ficha, así que no hay dato de pagos.</div></div>`;
  }
  const c = p.cuotas_atrasadas || 0;
  const estado = n === 'atrasado'
    ? `<span class="est-chip pg-atrasado">Atrasado · ${esc(c)} ${c === 1 ? 'cuota' : 'cuotas'}, máx. ${esc(p.max_dias_atraso ?? 0)} días</span>`
    : '<span class="est-chip est-listo">Al día</span>';
  const otras = p.cuotas_otras ? ` · ${esc(p.cuotas_otras)} en otro estado` : '';
  return `${titulo}
    <div class="card est-card">
      <div class="est-grid pg-grid">
        ${fila('Estado', estado)}
        ${fila('Cuotas pagadas', `${esc(p.cuotas_pagadas)} de ${esc(p.cuotas_total)}${otras}`)}
        ${fila('Próximo vencimiento', p.proximo_vencimiento ? esc(fmtFecha(p.proximo_vencimiento)) : '<span class="txt-gris">—</span>')}
        ${fila('Último pago', p.ultimo_pago ? esc(fmtFecha(p.ultimo_pago)) : '<span class="txt-gris">—</span>')}
      </div>
    </div>`;
}

export async function manejar() {
  return false;
}
