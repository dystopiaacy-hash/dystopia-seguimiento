/* Dystopita: mascota pixel art que abre el chat interno de IA (panel desplegable) en todas las pantallas de Producto.
   Solo se monta para fundador, rol producto y rol cliente (puedeUsarChatIa). El chat es el de la 140 (views/preguntar-ia.js):
   Dystopita solo lo muestra; los permisos y el recorte por programa los impone la base.
   - Burbujita (globito de chat con cara). Estados: quieta (flota y parpadea), deslizándose de lado unos px, durmiendo, pensando
     (tres puntitos) y saludo. prefers-reduced-motion: sin flotar ni moverse, solo parpadea.
   - Cada tanto (y mientras la IA responde) aparece una notebook pixel y tipea; si se suelta con velocidad contra una esquina
     explota en píxeles y se rearma ahí (con movimiento reducido no explota: solo se acomoda en la esquina).
   - Se arrastra con mouse o dedo; la posición se recuerda en localStorage y se corrige al cambiar el tamaño de la ventana.
   - En pantallas chicas: más chica, fija en la esquina, sin arrastre, y el panel ocupa casi toda la pantalla. */
import { puedeUsarChatIa } from './sesion.js';
import { svgCuadro, svgZ, svgCompu, pixelesCuadro, DIM } from './dystopita-sprites.js';
import { velocidadFinal, esquinaCercana, explotarPixeles } from './dystopita-efectos.js';
import { vistaPreguntar } from './views/preguntar-ia.js';

const CLAVE = 'dystopita_pos_v1';
const MARGEN = 8;          // distancia mínima al borde de la pantalla
const MARGEN_INICIAL = 20; // posición por defecto: abajo a la derecha
const SUENO_MS = 90_000;   // sin interacción => se duerme
const VEL_EXPLOTA = 1.1;   // px/ms en los últimos 100 ms antes de soltar
const ZONA_ESQUINA = 40;   // px de la esquina de la pantalla
const CUADROS_POR_ESTADO = {
  quieto: ['quieto'], paso: ['quieto'], saludo: ['quieto'],
  dormido: ['dormido'], pensando: ['pensA', 'pensB', 'pensC']
};

const mqMovil = window.matchMedia('(max-width: 640px)');
const mqQuieto = window.matchMedia('(prefers-reduced-motion: reduce)');
const movil = () => mqMovil.matches;
const tam = () => (movil() ? 36 : 48);        // ancho del sprite (4 px por pixel; 3 en celular)
const alto = () => (movil() ? 30 : 40);
const azar = (a, b) => a + Math.random() * (b - a);
const limitar = (v, min, max) => Math.max(min, Math.min(v, Math.max(min, max)));

let raiz = null, btn = null, cuerpo = null, mover = null, globo = null, panel = null, chatEl = null, observador = null;
let compuEl = null, boomEl = null, compuVisible = false, compuP = -1, cn = 0, explotando = false, cancelarBoom = null, muestras = [];
let estado = 'quieto', pensando = false, parpadeando = false, n = 0, cuadroActual = '';
let pos = { x: 0, y: 0 }, anclado = true, desplazo = 0;   // desplazo: px que caminó desde su posición
let arrastre = null, suprimirClick = false, abierto = false, chatPrograma;
let tickId = null, suenoId = null, espontaneoId = null, parpadeoId = null, estadoId = null, globoId = null, trabajoId = null, trabajoRndId = null;
let escuchas = [];

/* ---------- Posición ---------- */
function posInicial() {
  return { x: innerWidth - tam() - MARGEN_INICIAL, y: innerHeight - alto() - MARGEN_INICIAL };
}
function cargarPos() {
  try {
    const v = JSON.parse(localStorage.getItem(CLAVE));
    if (v && Number.isFinite(v.x) && Number.isFinite(v.y)) return { x: v.x, y: v.y };
  } catch { /* sin almacenamiento */ }
  return null;
}
function guardarPos() {
  try { localStorage.setItem(CLAVE, JSON.stringify(pos)); } catch { /* sin almacenamiento */ }
}
function encajar() {
  pos.x = limitar(pos.x, MARGEN, innerWidth - tam() - MARGEN);
  pos.y = limitar(pos.y, MARGEN, innerHeight - alto() - MARGEN);
}
function aplicar() {
  raiz.style.left = pos.x + 'px';
  raiz.style.top = pos.y + 'px';
  raiz.classList.toggle('dy-izq', pos.x + tam() / 2 < innerWidth / 2);
  raiz.classList.toggle('dy-abajo', pos.y < 70);
  posicionarPanel();
}
function alRedimensionar() {
  if (movil() || anclado) pos = posInicial();
  encajar();
  aplicar();
}

/* La caminata mueve solo el dibujo; antes de arrastrar o abrir el panel se suma a la posición real. */
function plegar() {
  if (!desplazo) return;
  pos.x += desplazo;
  desplazo = 0;
  mover.style.transition = 'none';
  mover.style.transform = '';
  encajar();
  aplicar();
}

/* ---------- Dibujo y estados ---------- */
function pintar() {
  let nombre;
  if ((estado === 'quieto' || estado === 'paso') && parpadeando) nombre = 'parpadeo';
  else {
    const lista = CUADROS_POR_ESTADO[estado];
    nombre = !mqQuieto.matches ? lista[Math.floor(n / 2) % lista.length] : estado === 'pensando' ? 'pensFijo' : lista[0];
  }
  if (nombre !== cuadroActual) { cuadroActual = nombre; cuerpo.innerHTML = svgCuadro(nombre); }
}
function ir(nuevo, ms) {
  clearTimeout(estadoId);
  estado = nuevo;
  raiz.dataset.estado = nuevo;
  if (nuevo !== 'paso') { mover.style.transition = 'none'; }
  if (nuevo === 'dormido') ponerCompu(false);
  n = 0;
  pintar();
  if (ms) estadoId = setTimeout(reposar, ms);
}
function reposar() {
  ir(pensando ? 'pensando' : 'quieto');
}

function ocupado() { return !!arrastre || abierto || pensando || explotando || estado === 'dormido' || estado === 'saludo'; }

/* ---------- Notebook: aparece delante y la burbujita "tipea" (1 px arriba y abajo, por CSS) ---------- */
function pintarCompu() {
  const p = mqQuieto.matches ? 15 : cn % 16;
  if (p === compuP) return;
  compuP = p;
  compuEl.innerHTML = svgCompu(p);
}
function ponerCompu(on) {
  if (on && explotando) return;
  clearTimeout(trabajoId);
  if (on === compuVisible) return;
  compuVisible = on;
  compuEl.hidden = !on;
  if (on) { cn = 0; compuP = -1; pintarCompu(); raiz.dataset.compu = '1'; } else delete raiz.dataset.compu;
}
function programarTrabajo() {
  clearTimeout(trabajoRndId);
  trabajoRndId = setTimeout(() => {
    if (!ocupado() && !mqQuieto.matches && estado === 'quieto' && !compuVisible) {
      ponerCompu(true);
      trabajoId = setTimeout(() => { if (!pensando) ponerCompu(false); }, azar(4000, 6500));
    }
    programarTrabajo();
  }, azar(25000, 50000));
}

/* ---------- Explosión contra una esquina ---------- */
function estallar() {
  if (mqQuieto.matches || movil()) return;
  explotando = true;
  ponerCompu(false);
  clearTimeout(estadoId);
  raiz.dataset.boom = '1';
  decir('¡uy!', 1800);
  cancelarBoom = explotarPixeles(boomEl, pixelesCuadro(cuadroActual || 'quieto'), DIM, tam() / DIM.w, terminarBoom);
}
function terminarBoom() {
  cancelarBoom = null;
  explotando = false;
  if (!raiz) return;
  delete raiz.dataset.boom;
  boomEl.replaceChildren();
  if (pensando) ponerCompu(true);
  reiniciarSueno();
}

/* Deslizamiento lateral corto y lento (hasta 14 px de su lugar), sin salirse de la pantalla. */
function caminar() {
  const libreIzq = raiz.offsetLeft - MARGEN, libreDer = innerWidth - (raiz.offsetLeft + tam()) - MARGEN;
  const lo = -Math.min(14, libreIzq), hi = Math.min(14, libreDer);
  const dir = desplazo > 5 ? -1 : desplazo < -5 ? 1 : (Math.random() < 0.5 ? -1 : 1);
  const destino = limitar(desplazo + dir * azar(6, 14), lo, hi);
  if (Math.abs(destino - desplazo) < 4) return;
  const ms = Math.max(2500, Math.abs(destino - desplazo) * 250);
  ir('paso', ms);
  mover.style.transition = `transform ${ms}ms linear`;
  mover.style.transform = `translateX(${destino}px)`;
  desplazo = destino;
}

/* Cada tanto, algo distinto al azar (suave: la mayoría de las veces se queda quieta). */
function programarEspontaneo() {
  clearTimeout(espontaneoId);
  espontaneoId = setTimeout(() => {
    if (!ocupado() && !mqQuieto.matches && estado === 'quieto') {
      if (Math.random() < 0.3 && !movil()) caminar();
    }
    programarEspontaneo();
  }, azar(8000, 16000));
}
function programarParpadeo() {
  clearTimeout(parpadeoId);
  parpadeoId = setTimeout(() => {
    if (estado === 'quieto' || estado === 'paso') {
      parpadeando = true; pintar();
      setTimeout(() => { parpadeando = false; pintar(); }, 140);
    }
    programarParpadeo();
  }, azar(2500, 6000));
}
function reiniciarSueno() {
  clearTimeout(suenoId);
  suenoId = setTimeout(() => { if (!pensando && !arrastre && !abierto) ir('dormido'); }, SUENO_MS);
}
function actividad() {
  if (estado === 'dormido') ir(pensando ? 'pensando' : 'quieto');
  reiniciarSueno();
}

/* ---------- Globo de texto ---------- */
function decir(texto, ms) {
  clearTimeout(globoId);
  globo.textContent = texto;
  globo.hidden = false;
  globoId = setTimeout(() => { globo.hidden = true; }, ms);
}

/* ---------- Panel ---------- */
function programaActual() {
  const m = /^#\/p\/([^/?]+)/.exec(location.hash);
  return m ? decodeURIComponent(m[1]) : null;
}
function montarChat() {
  chatPrograma = programaActual();
  const cont = document.createElement('div');
  cont.className = 'dy-chat-in';
  chatEl.replaceChildren(cont);
  vistaPreguntar(cont, chatPrograma, () => true);   // la conversación (hilo) se conserva entre montajes
}
function posicionarPanel() {
  if (!panel || panel.hidden) return;
  if (movil()) { panel.style.cssText = ''; return; }
  const W = Math.min(380, innerWidth - 16), H = Math.min(540, innerHeight - 16), t = tam(), sep = 10;
  const aLaIzq = pos.x + t / 2 > innerWidth / 2;
  const left = limitar(aLaIzq ? pos.x - W - sep : pos.x + t + sep, 8, innerWidth - W - 8);
  const top = limitar(pos.y + alto() - H, 8, innerHeight - H - 8);
  panel.style.cssText = `left:${left}px;top:${top}px;width:${W}px;height:${H}px`;
}
function abrir() {
  plegar();
  if (!pensando) ponerCompu(false);
  if (chatPrograma !== programaActual() || !chatEl.firstChild) montarChat();
  abierto = true;
  panel.hidden = false;
  btn.setAttribute('aria-expanded', 'true');
  globo.hidden = true;
  posicionarPanel();
  const ta = chatEl.querySelector('#ia-pregunta');
  if (ta) ta.focus();
}
function cerrar(devolverFoco) {
  if (!abierto) return;
  abierto = false;
  panel.hidden = true;
  btn.setAttribute('aria-expanded', 'false');
  if (devolverFoco) btn.focus();
}

/* ---------- Arrastre ---------- */
function alPresionar(e) {
  suprimirClick = false;
  actividad();
  if (movil() || explotando || (e.pointerType === 'mouse' && e.button !== 0)) return;
  plegar();
  muestras = [];
  arrastre = { id: e.pointerId, sx: e.clientX, sy: e.clientY, ox: pos.x, oy: pos.y, movio: false };
  try { btn.setPointerCapture(e.pointerId); } catch { /* sin captura */ }
}
function alMover(e) {
  if (!arrastre || e.pointerId !== arrastre.id) return;
  const dx = e.clientX - arrastre.sx, dy = e.clientY - arrastre.sy;
  if (!arrastre.movio && Math.hypot(dx, dy) < 5) return;
  if (!arrastre.movio && !pensando) ponerCompu(false);
  arrastre.movio = true;
  raiz.classList.add('dy-arrastrando');
  pos = { x: arrastre.ox + dx, y: arrastre.oy + dy };
  encajar();
  aplicar();
  const t = performance.now();
  muestras.push({ t, x: e.clientX, y: e.clientY });
  while (muestras.length && t - muestras[0].t > 200) muestras.shift();
}
function alSoltar(e) {
  if (!arrastre || e.pointerId !== arrastre.id) return;
  const movio = arrastre.movio;
  arrastre = null;
  raiz.classList.remove('dy-arrastrando');
  try { btn.releasePointerCapture(e.pointerId); } catch { /* ya liberado */ }
  if (movio && e.type === 'pointerup') {
    anclado = false;
    suprimirClick = true;    // el click que sigue a un arrastre (o a una explosión) no abre el panel
    // Soltada con velocidad contra una esquina: se acomoda ahí y explota (con movimiento reducido, solo se acomoda)
    const esq = velocidadFinal(muestras, performance.now()) >= VEL_EXPLOTA
      ? esquinaCercana(pos, tam(), alto(), innerWidth, innerHeight, ZONA_ESQUINA, MARGEN_INICIAL) : null;
    if (esq) { pos = { x: esq.x, y: esq.y }; encajar(); aplicar(); guardarPos(); estallar(); } else guardarPos();
  }
  reiniciarSueno();
}

/* ---------- Montaje ---------- */
function escuchar(blanco, tipo, fn, opciones) {
  blanco.addEventListener(tipo, fn, opciones);
  escuchas.push([blanco, tipo, fn, opciones]);
}

export function montarDystopita() {
  desmontarDystopita();
  if (!puedeUsarChatIa()) return;

  raiz = document.createElement('div');
  raiz.id = 'dystopita';
  raiz.className = 'dy-raiz';
  raiz.dataset.estado = 'quieto';
  raiz.innerHTML = `
    <div class="dy-globo" role="status" hidden></div>
    <button type="button" class="dy-btn" aria-label="Abrir Dystopita" aria-expanded="false" aria-controls="dy-panel">
      <span class="dy-mover">
        <span class="dy-cuerpo"></span>
        <span class="dy-boom" aria-hidden="true"></span>
        <span class="dy-compu" aria-hidden="true" hidden></span>
        <span class="dy-zzz" aria-hidden="true">${svgZ()}</span>
      </span>
    </button>`;
  panel = document.createElement('section');
  panel.id = 'dy-panel';
  panel.className = 'dy-panel';
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-label', 'Dystopita');
  panel.hidden = true;
  panel.innerHTML = `
    <header class="dy-panel-cab">
      <h2>Dystopita</h2>
      <button type="button" class="dy-x" aria-label="Cerrar">×</button>
    </header>
    <div class="dy-chat"></div>`;
  document.body.append(raiz, panel);

  btn = raiz.querySelector('.dy-btn');
  cuerpo = raiz.querySelector('.dy-cuerpo');
  mover = raiz.querySelector('.dy-mover');
  boomEl = raiz.querySelector('.dy-boom');
  compuEl = raiz.querySelector('.dy-compu');
  globo = raiz.querySelector('.dy-globo');
  chatEl = panel.querySelector('.dy-chat');
  chatPrograma = undefined;

  const guardada = cargarPos();
  anclado = !guardada;
  pos = guardada || posInicial();
  if (movil()) pos = posInicial();
  encajar();
  aplicar();
  pintar();

  btn.addEventListener('pointerdown', alPresionar);
  btn.addEventListener('pointermove', alMover);
  btn.addEventListener('pointerup', alSoltar);
  btn.addEventListener('pointercancel', alSoltar);
  btn.addEventListener('pointerenter', actividad);
  btn.addEventListener('click', e => {
    if (explotando) { e.preventDefault(); return; }
    if (suprimirClick) { suprimirClick = false; e.preventDefault(); return; }
    if (abierto) cerrar(false); else abrir();
  });
  panel.querySelector('.dy-x').addEventListener('click', () => cerrar(true));

  escuchar(window, 'resize', alRedimensionar);
  escuchar(window, 'hashchange', () => { if (abierto && chatPrograma !== programaActual()) montarChat(); });
  escuchar(window, 'ia-chat-pensando', e => {
    pensando = !!(e.detail && e.detail.pensando);
    ponerCompu(pensando);
    if (pensando) ir('pensando'); else if (estado === 'pensando') ir('quieto');
    reiniciarSueno();
  });
  escuchar(document, 'keydown', e => {
    actividad();
    if (e.key === 'Escape' && abierto) { e.preventDefault(); cerrar(true); }
  });
  escuchar(document, 'pointerdown', e => {
    actividad();
    if (abierto && !panel.contains(e.target) && !raiz.contains(e.target)) cerrar(false);
  }, true);
  escuchar(document, 'wheel', actividad, { passive: true, capture: true });

  // Tras cada mensaje del chat: bajar al último y no perder el foco del cuadro de texto.
  observador = new MutationObserver(() => {
    const h = chatEl.querySelector('.chat-ia-hilo');
    if (h) h.scrollTop = h.scrollHeight;
    if (abierto && (!document.activeElement || document.activeElement === document.body)) {
      const ta = chatEl.querySelector('#ia-pregunta');
      if (ta) ta.focus();
    }
  });
  observador.observe(chatEl, { childList: true, subtree: true });

  tickId = setInterval(() => { n++; pintar(); if (compuVisible) { cn++; pintarCompu(); } }, 220);
  programarEspontaneo();
  programarTrabajo();
  programarParpadeo();
  reiniciarSueno();

  // Saludo corto al cargar
  setTimeout(() => {
    if (!raiz) return;
    ir('saludo', 900);
    decir('¡Hola! Soy Dystopita', 3000);
  }, 700);
}

export function desmontarDystopita() {
  [tickId, suenoId, espontaneoId, parpadeoId, estadoId, globoId, trabajoId, trabajoRndId].forEach(clearTimeout);
  if (cancelarBoom) cancelarBoom();
  cancelarBoom = null;
  clearInterval(tickId);
  for (const [b, t, f, o] of escuchas) b.removeEventListener(t, f, o);
  escuchas = [];
  if (observador) observador.disconnect();
  observador = null;
  if (raiz) raiz.remove();
  if (panel) panel.remove();
  raiz = panel = btn = cuerpo = mover = globo = chatEl = compuEl = boomEl = null;
  compuVisible = false; compuP = -1; explotando = false; muestras = [];
  estado = 'quieto'; pensando = false; parpadeando = false; abierto = false; arrastre = null; desplazo = 0; cuadroActual = '';
}
