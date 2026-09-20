/* Hash routing mínimo: #/programa/liam, #/cliente/123, etc.
   Patrones con segmentos ":param". El handler recibe los params ya decodificados. */

const rutas = [];
let noEncontrada = null;
let escuchando = false;

export function ruta(patron, handler) {
  const partes = patron.split('/').filter(Boolean);
  rutas.push({ partes, handler });
}

export function rutaNoEncontrada(handler) {
  noEncontrada = handler;
}

export function rutaActual() {
  return location.hash.replace(/^#\/?/, '');
}

/* Query string de la ruta actual: #/p/liam/clientes?estado=activos -> URLSearchParams. */
export function queryActual() {
  const q = rutaActual().split('?')[1] || '';
  return new URLSearchParams(q);
}

export function navegar(path) {
  const destino = '#/' + String(path).replace(/^#?\/?/, '');
  if (location.hash === destino) resolver();
  else location.hash = destino;
}

/* Igual que navegar() pero sin dejar la ruta actual en el historial (redirecciones). */
export function reemplazar(path) {
  const destino = '#/' + String(path).replace(/^#?\/?/, '');
  if (location.hash === destino) resolver();
  else location.replace(destino);
}

function coincide(partesRuta, segmentos) {
  if (partesRuta.length !== segmentos.length) return null;
  const params = {};
  for (let i = 0; i < partesRuta.length; i++) {
    const p = partesRuta[i];
    if (p.startsWith(':')) {
      try { params[p.slice(1)] = decodeURIComponent(segmentos[i]); }
      catch { return null; }
    } else if (p !== segmentos[i]) {
      return null;
    }
  }
  return params;
}

export function resolver() {
  const segmentos = rutaActual().split('?')[0].split('/').filter(Boolean);
  for (const r of rutas) {
    const params = coincide(r.partes, segmentos);
    if (params) return r.handler(params);
  }
  if (noEncontrada) noEncontrada(segmentos.join('/'));
}

export function iniciarRouter() {
  if (!escuchando) {
    window.addEventListener('hashchange', resolver);
    escuchando = true;
  }
  resolver();
}
