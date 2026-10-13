/* "Sin llamada" de la pestaña Hoy (102): alumnos vivos cuya última llamada es de hace
   LLAMADA_ROJO_DESDE días o más (js/config.js). Debajo, plegados, los vivos que nunca
   tuvieron una llamada registrada. Vive en su propio contenedor, como las altas y el
   onboarding. Sin la 102 (o si falla la lectura) no muestra nada y el resto sigue igual. */
import { esc, fmtFecha, plural } from '../ui.js';
import { traerClientes, esVivo } from '../datos.js';
import { LLAMADA_ROJO_DESDE } from '../config.js';
import { sumarUltimaLlamada, diasSinLlamada, textoDias } from './llamada-semaforo.js';

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
    const titulo = `Sin llamada hace ${plural(LLAMADA_ROJO_DESDE, 'día')} o más`;
    box.innerHTML = `<section class="hoy-grupo">
      <div class="section-title">${esc(titulo)} <span class="hoy-grupo-n hoy-n-atrasado">${atrasados.length}</span><span class="line"></span></div>
      ${atrasados.length ? atrasados.map(c => fila(c, programaId)).join('')
        : '<div class="muted-empty">Ningún alumno activo pasó ese plazo.</div>'}
      ${nunca.length ? `<details class="ll-nunca"><summary>${esc(plural(nunca.length, 'alumno activo sin ninguna llamada registrada', 'alumnos activos sin ninguna llamada registrada'))}</summary>
        ${nunca.map(c => fila(c, programaId)).join('')}</details>` : ''}
    </section>`;
  }

  async function cargar() {
    const n = ++pedido;
    let a = [], s = [];
    try {
      const clientes = (await traerClientes(programaId)).filter(esVivo);
      if (await sumarUltimaLlamada(programaId, clientes)) {
        a = clientes.filter(c => { const d = diasSinLlamada(c.ultima_llamada); return d != null && d >= LLAMADA_ROJO_DESDE; })
          .sort((x, y) => diasSinLlamada(y.ultima_llamada) - diasSinLlamada(x.ultima_llamada));
        s = clientes.filter(c => c.ultima_llamada == null)
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
