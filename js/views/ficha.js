/* Ficha de cliente (#/p/:programa/c/:id).
   Es la vista más grande: acá solo van la carga de datos, el armado de los bloques y
   el despacho de eventos. Cada bloque vive en su propio archivo (ficha-*.js) y expone
   html(ctx) y manejar(ev, ctx, api).
   Después de cada cambio se recargan los datos y se repinta: la cabecera queda con el
   semáforo recalculado por cs_v_clientes, sin recargar la página. */
import { esc } from '../ui.js';
import { setHeader } from '../layout.js';
import { repintarConservandoFoco } from './comunes.js';
import { vacio, tarjetaError } from './programa.js';
import {
  traerPrograma, traerCliente, traerAccionablesCliente, traerDevolucionesCliente, traerCallsCliente,
  traerRenovacionesCliente, traerRespuestasCliente, traerChequeosCliente,
  traerFormularios, traerHistorial, mensajeError
} from '../datos.js';
import * as cabecera from './ficha-cabecera.js';
import * as accionables from './ficha-accionables.js';
import * as devoluciones from './ficha-devoluciones.js';
import * as calls from './ficha-calls.js';
import * as historial from './ficha-historial.js';

const BLOQUES = [
  ['cabecera', cabecera],
  ['accionables', accionables],
  ['devoluciones', devoluciones],
  ['calls', calls],
  ['historial', historial]
];

/* La fila de programa que trae la sesión es la corta (id, nombre, marca, activo):
   la ficha necesita la completa (etapas, SLAs, aviso de renovación). */
async function cargarDatos(programaCorto, clienteId) {
  const [completo, c] = await Promise.all([
    traerPrograma(programaCorto.id), traerCliente(clienteId)
  ]);
  if (!c) return null;
  const p = completo || programaCorto;
  const [acc, devs, cls, rens, resp, chq, forms] = await Promise.all([
    traerAccionablesCliente(c.id),
    traerDevolucionesCliente(c.id),
    traerCallsCliente(c.id),
    traerRenovacionesCliente(c.id),
    traerRespuestasCliente(c.id),
    traerChequeosCliente(c.id),
    traerFormularios(p.id)
  ]);
  /* cs_historial se busca por registro_id: el cliente y todo lo que cuelga de él. */
  const ids = [c.id]
    .concat(acc.map(x => x.id), devs.map(x => x.id), cls.map(x => x.id), rens.map(x => x.id));
  let hist = [];
  try { hist = await traerHistorial(p.id, ids); } catch (e) { console.error('historial', e); }
  return {
    p, c,
    accionables: acc, devoluciones: devs, calls: cls, renovaciones: rens,
    respuestas: resp, chequeos: chq, formularios: forms, historial: hist
  };
}

function armazon(p) {
  const base = '#/p/' + encodeURIComponent(p.id);
  return `
    <div class="ficha">
      <div class="ficha-volver"><a href="${base}/clientes">← Clientes de ${esc(p.nombre)}</a></div>
      ${BLOQUES.map(([id]) => `<section id="b-${id}"></section>`).join('')}
    </div>`;
}

export function vistaFicha(el, p, clienteId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let ctx = null;
  let armado = false;

  function pintar() {
    if (!armado || !el.querySelector('#b-cabecera')) {
      el.innerHTML = armazon(p);
      armado = true;
    }
    for (const [id, mod] of BLOQUES) {
      const cont = el.querySelector('#b-' + id);
      if (cont) cont.innerHTML = mod.html(ctx);
    }
  }

  async function cargar() {
    const datos = await cargarDatos(p, clienteId);
    if (!vigente()) return;
    if (!datos) {
      armado = false;
      el.innerHTML = vacio('No existe este cliente o no tenés acceso.', '',
        `<div class="small"><a href="#/p/${encodeURIComponent(p.id)}/clientes">Volver a la lista</a></div>`);
      return;
    }
    ctx = datos;
    setHeader(ctx.c.nombre, `${p.marca ? p.marca + ' · ' : ''}Ficha de cliente`);
    /* El contenedor que scrollea es .main: repintar no tiene que mover la página. */
    const main = document.querySelector('.main');
    const y = main ? main.scrollTop : 0;
    repintarConservandoFoco(el, pintar);
    if (main) main.scrollTop = y;
  }

  const api = {
    refrescar: () => cargar().catch(e => console.error('ficha', e))
  };

  async function despachar(ev) {
    /* Ningún formulario de la ficha navega: se guarda por API. */
    if (ev.type === 'submit') ev.preventDefault();
    if (!ctx) return;
    for (const [, mod] of BLOQUES) {
      try {
        if (await mod.manejar(ev, ctx, api)) return;
      } catch (e) {
        console.error('ficha', e);
        return;
      }
    }
  }

  el.addEventListener('click', despachar);
  el.addEventListener('change', despachar);
  el.addEventListener('submit', despachar);

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar la ficha', mensajeError(e));
  });

  return { refrescar: api.refrescar };
}
