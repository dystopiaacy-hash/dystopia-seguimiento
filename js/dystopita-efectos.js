/* Dystopita: efectos del arrastre contra las esquinas (detección y explosión de píxeles). Sin librerías: Web Animations API. */

const azar = (a, b) => a + Math.random() * (b - a);

/* Velocidad (px/ms) en los últimos 100 ms antes de soltar. Si frenó antes de soltar, la ventana queda vacía o lenta. */
export function velocidadFinal(muestras, ahora) {
  const rec = muestras.filter(m => ahora - m.t <= 100);
  if (rec.length < 2) return 0;
  const a = rec[0], b = rec[rec.length - 1];
  return Math.hypot(b.x - a.x, b.y - a.y) / Math.max(ahora - a.t, 30);
}

/* Si el sprite (esquina superior izquierda en pos, tamaño w x h) quedó a menos de `umbral` px de una esquina de la
   pantalla (W x H), devuelve la posición del sprite pegado a esa esquina con `margen`; si no, null. */
export function esquinaCercana(pos, w, h, W, H, umbral, margen) {
  const izq = pos.x < W - pos.x - w, arr = pos.y < H - pos.y - h;
  const dx = izq ? pos.x : W - pos.x - w, dy = arr ? pos.y : H - pos.y - h;
  if (dx > umbral || dy > umbral) return null;
  return { x: izq ? margen : W - w - margen, y: arr ? margen : H - h - margen };
}

/* Explota los píxeles del sprite dentro de `host` (~600 ms salen volando, girando y desvaneciéndose) y los junta de
   nuevo en su lugar (~600 ms). `u` = px de pantalla por píxel del sprite. Devuelve una función que cancela todo. */
export function explotarPixeles(host, pixeles, dim, u, alTerminar) {
  host.innerHTML = `<svg viewBox="0 0 ${dim.w} ${dim.h}" shape-rendering="crispEdges" aria-hidden="true" focusable="false">${
    pixeles.map(p => `<rect class="dy-${p.c}" x="${p.x}" y="${p.y}" width="1" height="1"/>`).join('')}</svg>`;
  const rects = [...host.querySelectorAll('rect')];
  const cx = dim.w / 2, cy = dim.h / 2;
  const vuelos = pixeles.map(p => {
    const ang = Math.atan2(p.y + 0.5 - cy, p.x + 0.5 - cx) + (Math.random() - 0.5) * 1.1;
    const d = azar(18, 42) / u;
    return { dx: Math.cos(ang) * d, dy: Math.sin(ang) * d, rot: (Math.random() < 0.5 ? -1 : 1) * azar(40, 160) };
  });
  const T = 'translate(0px,0px) rotate(0deg)';
  const lejos = v => `translate(${v.dx}px,${v.dy}px) rotate(${v.rot}deg)`;
  const anims = [];
  rects.forEach((r, i) => {
    anims.push(r.animate([{ transform: T, opacity: 1 }, { transform: lejos(vuelos[i]), opacity: 0 }],
      { duration: 600, easing: 'ease-out', fill: 'forwards' }));
  });
  const t1 = setTimeout(() => {
    rects.forEach((r, i) => {
      anims.push(r.animate([{ transform: lejos(vuelos[i]), opacity: 0 }, { transform: T, opacity: 1 }],
        { duration: 600, easing: 'ease-in-out', fill: 'forwards' }));
    });
  }, 600);
  const t2 = setTimeout(alTerminar, 1250);
  return () => { clearTimeout(t1); clearTimeout(t2); anims.forEach(a => { try { a.cancel(); } catch { /* ya terminó */ } }); };
}
