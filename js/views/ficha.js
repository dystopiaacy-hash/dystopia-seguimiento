/* Ficha de cliente (#/p/:programa/c/:id).
   Es la vista más grande: acá solo van la carga de datos, el armado de los bloques y
   el despacho de eventos. Cada bloque vive en su propio archivo (ficha-*.js) y expone
   html(ctx) y manejar(ev, ctx, api).
   Después de cada cambio se recargan los datos y se repinta: la cabecera queda con el
   semáforo recalculado por cs_v_clientes, sin recargar la página. */
import { esc } from '../ui.js';
import { setHeader } from '../layout.js';
import { repintarConservandoFoco } from './comunes.js';
import { queryActual } from '../router.js';
import { vacio, tarjetaError } from './programa.js';
import {
  traerPrograma, traerCliente, traerAccionablesCliente, traerDevolucionesCliente, traerCallsCliente,
  traerRenovacionesCliente, traerRespuestasCliente, traerSeguimientosCliente,
  traerFormularios, traerHistorial, mensajeError
} from '../datos.js';
import { traerProductos, traerCicloCliente } from '../ciclo.js';
import { traerOnboardingCliente } from '../datos-onboarding.js';
import { traerLlamadasCliente } from '../datos-llamadas.js';
import { traerResumenCliente, traerUltimaLlamadaCliente } from '../datos-estado.js';
import { traerEnviosCliente, traerMomentos } from '../datos-satisfaccion.js';
import { traerWinsCliente } from '../datos-wins.js';
import * as cabecera from './ficha-cabecera.js';
import * as estado from './ficha-estado.js';
import * as satisfaccion from './ficha-satisfaccion.js';
import * as wins from './ficha-wins.js';
import * as ciclo from './ficha-ciclo.js';
import * as onboarding from './ficha-onboarding.js';
import * as seguimientos from './ficha-seguimientos.js';
import * as accionables from './ficha-accionables.js';
import * as llamadas from './ficha-llamadas.js';
import * as recursos from './ficha-recursos.js';
import * as devoluciones from './ficha-devoluciones.js';
import * as calls from './ficha-calls.js';
import * as historial from './ficha-historial.js';

const BLOQUES = [
  ['cabecera', cabecera],
  ['estado', estado],
  ['ciclo', ciclo],
  ['onboarding', onboarding],
  ['seguimientos', seguimientos],
  ['accionables', accionables],
  ['llamadas', llamadas],
  ['recursos', recursos],
  ['satisfaccion', satisfaccion],
  ['wins', wins],
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
  /* Lo de la 106 (estado, satisfacción, wins) nunca frena la ficha: sin la migración o con error
     queda undefined y sus bloques no se muestran. */
  const opcional = (fn, que) => fn().catch(e => { console.error(que, e); return undefined; });
  const [acc, devs, cls, rens, resp, segs, forms, productos, cicloCli, onb, llam, resumen, ultima, momentos, envios, winsCli] = await Promise.all([
    traerAccionablesCliente(c.id),
    traerDevolucionesCliente(c.id),
    traerCallsCliente(c.id),
    traerRenovacionesCliente(c.id),
    traerRespuestasCliente(c.id),
    traerSeguimientosCliente(c.id),
    traerFormularios(p.id),
    traerProductos(p.id),
    traerCicloCliente(c.id),
    /* El onboarding no frena la ficha: sin 093 (o con error) el bloque no se muestra. */
    traerOnboardingCliente(c.id).catch(e => { console.error('onboarding', e); return undefined; }),
    /* Igual con las llamadas (102): sin la migración (o con error) no se muestran sus bloques. */
    traerLlamadasCliente(c.id).catch(e => { console.error('llamadas', e); return undefined; }),
    opcional(() => traerResumenCliente(c.id), 'resumen'),
    opcional(() => traerUltimaLlamadaCliente(c.id), 'ultima llamada'),
    opcional(() => traerMomentos(p.id), 'momentos'),
    opcional(() => traerEnviosCliente(c.id), 'satisfacción'),
    opcional(() => traerWinsCliente(c.id), 'wins')
  ]);
  /* 106 corrida = la vista del resumen respondió (con fila o null). */
  const con106 = resumen !== undefined;
  /* cs_historial se busca por registro_id: el cliente y todo lo que cuelga de él. */
  const ids = [c.id]
    .concat(acc.map(x => x.id), devs.map(x => x.id), cls.map(x => x.id), rens.map(x => x.id));
  let hist = [];
  try { hist = await traerHistorial(p.id, ids); } catch (e) { console.error('historial', e); }
  return {
    p, c: { ...c, ...cicloCli }, productos,
    accionables: acc, devoluciones: devs, calls: cls, renovaciones: rens,
    respuestas: resp, seguimientos: segs, formularios: forms, historial: hist,
    onboarding: onb, llamadas: llam,
    estado: con106 ? { resumen: resumen || {}, ultima: ultima || null } : undefined,
    satisfaccion: con106 && momentos !== undefined && envios !== undefined ? { momentos, envios } : undefined,
    wins: con106 ? winsCli : undefined
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
      if (cont) {
        cont.innerHTML = mod.html(ctx);
        if (mod.montar) mod.montar(cont, ctx);   // listeners propios del bloque (una vez por contenedor)
      }
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
    irASeccion();
  }

  /* ?sec=accionables (desde el Maestro): la primera vez baja hasta esa sección. */
  let secPendiente = /^[a-z]+$/.test(queryActual().get('sec') || '') ? queryActual().get('sec') : '';
  function irASeccion() {
    if (!secPendiente) return;
    const dest = el.querySelector('#b-' + secPendiente) || el.querySelector(`[data-sec="${secPendiente}"]`);
    secPendiente = '';
    if (dest) dest.scrollIntoView({ block: 'start' });
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
