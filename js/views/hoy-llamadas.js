/* "Sin llamada" de la pestaña Hoy (102): alumnos vivos cuya última llamada es de hace
   el umbral de alerta del programa (cs_servicio_config, 123) o más. Debajo, plegados, los vivos que nunca
   tuvieron una llamada registrada. Vive en su propio contenedor, como las altas y el
   onboarding. Sin la 102 (o si falla la lectura) no muestra nada y el resto sigue igual. */
import { esc, fmtFecha, plural } from '../ui.js';
import { traerClientes } from '../datos.js';
import { esVigente } from '../vigencia.js';
import { sumarUltimaLlamada, diasSinLlamada, textoDias, umbralesLlamada } from './llamada-semaforo.js';

function fila(c, programaId) {
  const d = diasSinLlamada(c.ultima_llamada);
  return `<article class="hoy-alta">
    <div class="hoy-card-main">
      <div class="hoy-card-top">
        <a class="cli-nombre" href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(c.id)}">${esc(c.nombre || 'Sin nombre')}</a>
        <span class="hoy-tipo">${esc(d == null ? 'sin llamadas' : textoDias(d))}</span>
      </div>
      <div class="hoy-detalle">${d == null ? 'Sin llamadas registradas' : 'Última llamada: ' + esc(fmtFecha(c.ultima_llamada))}</div>
    </div>
    <div class="hoy-card-acc"><a class="btn btn-sm"
      href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(c.id)}?sec=llamadas">Abrir llamadas</a></div>
  </article>`;
}

export function montarSinLlamada(box, programaId, vigente, alCambiar) {
  let atrasados = [], nunca = [], pedido = 0;

  function pintar() {
    if (!atrasados.length && !nunca.length) { box.innerHTML = ''; return; }
    /* El contador suma a los que nunca tuvieron llamada: un alumno sin ninguna llamada
       también está "sin llamada hace N días o más" (en el semáforo es gris, no verde). */
    const titulo = `Sin llamada hace ${plural(umbralesLlamada().alerta, 'día')} o más`;
    const total = atrasados.length + nunca.length;
    box.innerHTML = `<section class="hoy-grupo">
      <div class="section-title">${esc(titulo)} <span class="hoy-grupo-n hoy-n-atrasado">${total}</span><span class="line"></span></div>
      ${atrasados.length ? atrasados.map(c => fila(c, programaId)).join('')
        : `<div class="muted-empty">${nunca.length
          ? `Ningún alumno con llamadas registradas pasó ese plazo. Los ${nunca.length} de abajo todavía no tienen ninguna llamada registrada y por eso suman al número.`
          : 'Ningún alumno activo pasó ese plazo.'}</div>`}
      ${nunca.length ? `<details class="ll-nunca"><summary>${esc(plural(nunca.length, 'alumno activo sin ninguna llamada registrada (cuenta como sin llamada)', 'alumnos activos sin ninguna llamada registrada (cuentan como sin llamada)'))}</summary>
        ${nunca.map(c => fila(c, programaId)).join('')}</details>` : ''}
    </section>`;
  }

  async function cargar() {
    const n = ++pedido;
    let a = [], s = [];
    try {
      const clientes = (await traerClientes(programaId)).filter(esVigente);
      if (await sumarUltimaLlamada(programaId, clientes)) {
        const alerta = umbralesLlamada().alerta;   // ya cargado por sumarUltimaLlamada
        a = clientes.filter(c => { const d = diasSinLlamada(c.ultima_llamada); return d != null && d >= alerta; })
          .sort((x, y) => diasSinLlamada(y.ultima_llamada) - diasSinLlamada(x.ultima_llamada));
        /* 157: los grupales sin datos de asistencia no cuentan como "sin llamada" (no tienen 1 a 1 periódico). */
        s = clientes.filter(c => c.ultima_llamada == null && !c.ultima_llamada_sin_alerta)
          .sort((x, y) => (x.nombre || '').localeCompare(y.nombre || '', 'es'));
      }
    } catch (e) {
      console.error('sin llamada', e);
    }
    if (!vigente() || n !== pedido) return;
    atrasados = a;
    nunca = s;
    pintar();
    alCambiar();
  }

  cargar();
  return { cantidad: () => atrasados.length + nunca.length, cargar };
}
