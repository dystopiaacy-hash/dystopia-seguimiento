/* Dystopita: sprites pixel art propios (grilla de 16x16), dibujados en código y devueltos como SVG.
   Sin imágenes externas. Los colores salen de clases CSS (css/dystopita.css) para seguir la paleta de la app.
   Personaje: un robotito de visor con antena (no es ningún personaje ni logo de terceros). */

const N = 16;

function grilla() {
  return Array.from({ length: N }, () => Array(N).fill('.'));
}
function px(g, x, y, c) { if (x >= 0 && x < N && y >= 0 && y < N) g[y][x] = c; }
function rect(g, x, y, w, h, c) { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) px(g, x + i, y + j, c); }

/* Piernas: [x izquierda, x derecha] de cada pie (2 px de ancho, filas 14 y 15). */
const PIES = { parado: [5, 9], pasoA: [4, 10], pasoB: [6, 8] };

/* Brazos: lista de píxeles [x, y] oscuros. */
const BRAZOS = {
  bajos: [[3, 11], [3, 12], [12, 11], [12, 12]],
  tipeoA: [[3, 12], [3, 13], [12, 11], [12, 12]],
  tipeoB: [[3, 11], [3, 12], [12, 12], [12, 13]],
  pensar: [[3, 11], [3, 12], [12, 12], [12, 11], [13, 10], [13, 9]],
  saludoA: [[3, 11], [3, 12], [12, 12], [12, 11], [13, 10], [13, 9], [13, 8]],
  saludoB: [[3, 11], [3, 12], [12, 12], [12, 11], [13, 10], [14, 9], [14, 8]]
};

/* Ojos dentro del visor (columnas 6 y 9). */
const OJOS = {
  abiertos: [[6, 5], [9, 5], [6, 6], [9, 6]],
  cerrados: [[6, 6], [9, 6]],
  arriba: [[6, 4], [9, 4], [6, 5], [9, 5]]
};

/* Cada cuadro = combinación de ojos, brazos y piernas (o laptop). */
export const CUADROS = {
  quieto:   { ojos: 'abiertos', brazos: 'bajos',   pies: 'parado' },
  parpadeo: { ojos: 'cerrados', brazos: 'bajos',   pies: 'parado' },
  pasoA:    { ojos: 'abiertos', brazos: 'bajos',   pies: 'pasoA' },
  pasoB:    { ojos: 'abiertos', brazos: 'bajos',   pies: 'pasoB' },
  tipeoA:   { ojos: 'abiertos', brazos: 'tipeoA',  laptop: 'A' },
  tipeoB:   { ojos: 'abiertos', brazos: 'tipeoB',  laptop: 'B' },
  dormido:  { ojos: 'cerrados', brazos: 'bajos',   pies: 'parado' },
  pensando: { ojos: 'arriba',   brazos: 'pensar',  pies: 'parado' },
  saludoA:  { ojos: 'abiertos', brazos: 'saludoA', pies: 'parado' },
  saludoB:  { ojos: 'abiertos', brazos: 'saludoB', pies: 'parado' }
};

function dibujar(c) {
  const g = grilla();
  if (c.pies) {
    const [a, b] = PIES[c.pies];
    rect(g, a, 14, 2, 2, 'k');
    rect(g, b, 14, 2, 2, 'k');
  }
  // Cuerpo con una chapita
  rect(g, 4, 10, 8, 4, 'k');
  rect(g, 5, 10, 6, 3, 'a');
  rect(g, 7, 11, 2, 1, 'l');
  for (const [x, y] of BRAZOS[c.brazos]) px(g, x, y, 'k');
  // Cabeza con visor y brillo
  rect(g, 3, 2, 10, 8, 'k');
  rect(g, 4, 3, 8, 6, 'a');
  rect(g, 5, 4, 6, 4, 's');
  px(g, 4, 3, 'l'); px(g, 5, 3, 'l');
  for (const [x, y] of OJOS[c.ojos]) px(g, x, y, 'e');
  // Antena
  px(g, 7, 0, 'y'); px(g, 8, 0, 'y'); px(g, 7, 1, 'k'); px(g, 8, 1, 'k');
  // Laptop (tipeando): tapa con pantalla y base con teclas; una tecla se ilumina
  if (c.laptop) {
    rect(g, 4, 12, 8, 2, 'k');
    rect(g, 5, 12, 6, 1, 's');
    px(g, c.laptop === 'A' ? 6 : 9, 12, 'e');
    rect(g, 2, 14, 12, 2, 'k');
    rect(g, 3, 14, 10, 1, 'l');
    px(g, c.laptop === 'A' ? 5 : 10, 14, 'y');
  }
  return g;
}

const cache = {};

/* SVG de un cuadro. Corridas horizontales del mismo color = un solo <rect>. */
export function svgCuadro(nombre) {
  if (cache[nombre]) return cache[nombre];
  const g = dibujar(CUADROS[nombre] || CUADROS.quieto);
  let r = '';
  for (let y = 0; y < N; y++) {
    let x = 0;
    while (x < N) {
      const c = g[y][x];
      let n = 1;
      while (x + n < N && g[y][x + n] === c) n++;
      if (c !== '.') r += `<rect class="dy-${c}" x="${x}" y="${y}" width="${n}" height="1"/>`;
      x += n;
    }
  }
  cache[nombre] = `<svg viewBox="0 0 ${N} ${N}" shape-rendering="crispEdges" aria-hidden="true" focusable="false">${r}</svg>`;
  return cache[nombre];
}
