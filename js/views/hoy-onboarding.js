/* "Onboarding" de la pestaña Hoy (093): quién completó el onboarding en los últimos
   7 días y quién lo tiene empezado hace más de 3 días sin terminar.
   Vive en su propio contenedor, como las altas. Sin la 093 (o si la RPC falla) no
   muestra nada y el resto de la pantalla sigue igual. Solo nombres de la agencia
   adentro de la app: no se manda nada afuera. */
import { esc, plural } from '../ui.js';
import { traerOnboardingHoy } from '../datos-onboarding.js';

function fila(f, programaId) {
  const cuando = f.tipo === 'completo'
    ? (f.dias === 0 ? 'hoy' : `hace ${plural(f.dias, 'día')}`)
    : `empezado hace ${plural(f.dias, 'día')}`;
  const detalle = f.tipo === 'completo'
    ? 'Completó el onboarding'
    : `Lleva ${f.hechos} de ${f.total} pasos`;
  return `<article class="hoy-alta">
    <div class="hoy-card-main">
      <div class="hoy-card-top">
        <span class="hoy-alta-nombre">${esc(f.cliente)}</span>
        <span class="hoy-tipo">${esc(cuando)}</span>
      </div>
      <div class="hoy-detalle">${esc(detalle)}</div>
    </div>
    <div class="hoy-card-acc"><a class="btn btn-sm"
      href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(f.cliente_id)}">Abrir ficha</a></div>
  </article>`;
}

function grupo(titulo, filas, programaId) {
  if (!filas.length) return '';
  return `<section class="hoy-grupo">
    <div class="section-title">${esc(titulo)} <span class="hoy-grupo-n">${filas.length}</span><span class="line"></span></div>
    ${filas.map(f => fila(f, programaId)).join('')}
  </section>`;
}

export function montarOnboarding(box, programaId, vigente, alCambiar) {
  let filas = [], pedido = 0;

  function pintar() {
    box.innerHTML = grupo('Onboarding demorado (más de 3 días)', filas.filter(f => f.tipo === 'demorado'), programaId)
      + grupo('Completaron el onboarding', filas.filter(f => f.tipo === 'completo'), programaId);
  }

  async function cargar() {
    const n = ++pedido;
    let datos = [];
    try {
      datos = await traerOnboardingHoy(programaId);
    } catch (e) {
      console.error('onboarding hoy', e);
    }
    if (!vigente() || n !== pedido) return;
    filas = datos;
    pintar();
    alCambiar();
  }

  cargar();
  return { cantidad: () => filas.length, cargar };
}
