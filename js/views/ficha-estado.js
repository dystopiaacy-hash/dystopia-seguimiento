/* Ficha de cliente — tarjeta "Estado actual" (106), arriba de todo.
   Muestra "En qué está" y "Próximos pasos" de la ÚLTIMA llamada que los tiene cargados, la
   fecha de esa llamada y el semáforo de última llamada (102). Se carga desde la llamada
   (campos de "Nueva llamada" / "Editar llamada") o con cs_llamada_cargar.
   ctx.estado = { resumen, ultima } (undefined = 106 sin correr: el bloque no se muestra). */
import { esc, fmtFecha } from '../ui.js';
import { celdaUltimaLlamada } from './llamada-semaforo.js';

export function html(ctx) {
  const e = ctx.estado;
  if (!e) return '';
  const r = e.resumen || {};
  const f = { ...ctx.c, ultima_llamada: e.ultima ? e.ultima.fecha : null, ultima_llamada_fuente: e.ultima ? e.ultima.fuente : null };
  const bloque = (titulo, texto) => `<div class="est-bloque">
      <div class="est-lab">${esc(titulo)}</div>
      ${texto ? `<div class="est-val">${esc(texto)}</div>` : '<div class="est-val txt-gris">Sin cargar</div>'}
    </div>`;
  const tiene = !!(r.en_que_esta || r.proximos_pasos);
  return `
    <div class="section-title">Estado actual<span class="line"></span></div>
    <div class="card est-card">
      <div class="est-grid">
        ${bloque('En qué está', r.en_que_esta)}
        ${bloque('Próximos pasos', r.proximos_pasos)}
      </div>
      <div class="est-pie">
        <span>${tiene && r.estado_fecha
          ? `Según la llamada del ${esc(fmtFecha(r.estado_fecha))}`
          : 'Todavía no hay una llamada con "En qué está" o "Próximos pasos". Se cargan al registrar la llamada.'}</span>
        <span class="est-pie-sem">Última llamada: ${celdaUltimaLlamada(f)}</span>
      </div>
    </div>`;
}

export async function manejar() {
  return false;
}
