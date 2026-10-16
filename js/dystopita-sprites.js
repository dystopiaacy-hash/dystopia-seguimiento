/* Dystopita "Burbujita": un globito de chat con cara, pixel art propio (grilla de 12 x 10), dibujado en código y devuelto como SVG.
   Sin imágenes externas. Los colores salen de clases CSS (css/dystopita.css): o contorno, b cuerpo, h brillo, e ojo. */

const W = 12, H = 10;

const BASE = [
  '..oooooooo..',
  '.obhhbbbbbo.',
  'obhbbbbbbbbo',
  'obbebbbbebbo',
  'obbebbbbebbo',
  'obbbbbbbbbbo',
  '.obbbbbbbbo.',
  '..oobooooo..',
  '...ob.......',
  '...o........'
];

/* Ojos que se pisan sobre la base: abiertos ya vienen en BASE; el resto se arma por cuadro. */
const OJOS_ABIERTOS = [[3, 3], [8, 3], [3, 4], [8, 4]];
const OJOS_CERRADOS = [[3, 4], [4, 4], [7, 4], [8, 4]];   // una línea de 2 px por ojo, en la fila 4
const PUNTOS = [[3, 4], [5, 4], [7, 4]];                  // "escribiendo…"

/* Cada cuadro: ojos a dibujar y, si hay, cuál de los puntos queda encendido ('d' = apagado, más tenue). */
export const CUADROS = {
  quieto:   { ojos: OJOS_ABIERTOS },
  parpadeo: { ojos: [] },
  dormido:  { ojos: OJOS_CERRADOS },
  pensA:    { puntos: 0 },
  pensB:    { puntos: 1 },
  pensC:    { puntos: 2 },
  pensFijo: { puntos: -1 }   // los tres encendidos (movimiento reducido)
};

function dibujar(c) {
  const g = BASE.map(f => f.split(''));
  for (const [x, y] of OJOS_ABIERTOS) g[y][x] = 'b';
  for (const [x, y] of (c.ojos || [])) g[y][x] = 'e';
  if (c.puntos !== undefined) {
    PUNTOS.forEach(([x, y], i) => { g[y][x] = (c.puntos === -1 || c.puntos === i) ? 'e' : 'd'; });
  }
  return g;
}

const cache = {};

function svgDe(g, w, h) {
  let r = '';
  for (let y = 0; y < h; y++) {
    let x = 0;
    while (x < w) {
      const c = g[y][x];
      let n = 1;
      while (x + n < w && g[y][x + n] === c) n++;
      if (c !== '.') r += `<rect class="dy-${c}" x="${x}" y="${y}" width="${n}" height="1"/>`;
      x += n;
    }
  }
  return `<svg viewBox="0 0 ${w} ${h}" shape-rendering="crispEdges" aria-hidden="true" focusable="false">${r}</svg>`;
}

/* SVG de un cuadro. Corridas horizontales del mismo color = un solo <rect>. */
export function svgCuadro(nombre) {
  if (!cache[nombre]) cache[nombre] = svgDe(dibujar(CUADROS[nombre] || CUADROS.quieto), W, H);
  return cache[nombre];
}

/* La "z" chiquita que sube cuando duerme (3 x 3). */
export function svgZ() {
  return svgDe([['o', 'o', 'o'], ['.', 'o', '.'], ['o', 'o', 'o']], 3, 3);
}
