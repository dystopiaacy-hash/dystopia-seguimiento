/* Landing pública del onboarding (onboarding.html?t=<token de 64 hex>).
   Sin login. Lo único que hace contra la base son las cuatro RPC de la migración 093:
   cs_ob_estado, cs_ob_latido, cs_ob_avanzar y cs_ob_confirmar. No lee ninguna tabla.

   Cliente de supabase propio con persistSession en false: aunque quien abra el link
   esté logueado en la app (mismo origen), esta página siempre entra como anon.

   El orden de los pasos y todo el contenido vienen de la base (cs_onboarding_plantillas);
   acá no hay un solo texto de un programa. El servidor es quien manda en el avance:
   la página solo muestra el paso actual y los siguientes bloqueados.
   Todo lo que viene de la base pasa por esc() antes de ir al DOM. */
import { SUPABASE_URL, SUPABASE_KEY } from './config.js';
import { esc, urlSegura } from './ui.js';
import { pasoVideo } from './onboarding-video.js';
import { pasoFormulario } from './onboarding-formulario.js';

if (!window.supabase || !window.supabase.createClient) {
  throw new Error('supabase-js no cargó (revisar el <script> de jsdelivr en onboarding.html).');
}

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
});

const root = document.getElementById('ob-root');
const token = (new URLSearchParams(location.search).get('t') || '').trim().toLowerCase();

let estado = null;        // última respuesta de cs_ob_estado / cs_ob_avanzar / cs_ob_confirmar
let pasoFinal = null;     // paso 'final' (se guarda antes de completar: ya completado el servidor no lo manda)
let paso = null;          // módulo del paso en pantalla ({ destruir })
let acabaDeTerminar = false;
let vista = 0;            // índice del paso que se está mirando (<= estado.actual; menor = "Volver")

/* Borradores de formulario en memoria de la página: sobreviven a "Volver" y a volver
   a avanzar. Solo viven mientras la página está abierta; al enviar un formulario se
   descarta el suyo. Lo que viaja al servidor sigue siendo el borrador por sección. */
const borradores = {};
const borrador = key => {
  if (!borradores[key]) borradores[key] = { valores: null, sec: null };
  return borradores[key];
};

/* ---------- Llamadas ---------- */

async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

/* Los mensajes P0001 de la 093 ya están escritos para la persona. */
function mensaje(error) {
  const msg = (error && error.message) || '';
  if (error && error.code === 'P0001' && msg) return msg;
  if (/failed to fetch|networkerror|load failed/i.test(msg)) {
    return 'No se pudo conectar. Revisá tu internet y probá de nuevo: no perdiste nada de lo que escribiste.';
  }
  return 'No se pudo guardar. Probá de nuevo en un momento.';
}

const api = { rpc, token, mensaje, borrador, aplicar: s => { aplicar(s); } };

/* ---------- Pantallas fijas ---------- */

function pantalla(titulo, texto, tick = false) {
  root.innerHTML = `
    <div class="empty-state pub-gracias">
      ${tick ? '<div class="pub-tick" aria-hidden="true">✓</div>' : ''}
      <div class="big">${esc(titulo)}</div>
      ${texto ? `<div class="small">${esc(texto)}</div>` : ''}
    </div>`;
}

function pantallaFinal() {
  const f = pasoFinal || {};
  root.innerHTML = `
    <div class="empty-state pub-gracias">
      <div class="pub-tick" aria-hidden="true">✓</div>
      <div class="big">${esc(f.titulo || '¡Felicitaciones! Completaste el onboarding')}</div>
      <div class="small">${esc(f.texto || 'Ya recibimos tus respuestas. Podés cerrar esta página.')}</div>
    </div>`;
}

/* ---------- Pantalla de pasos ---------- */

/* Se listan todos los pasos menos el final, también los opcionales (un video no
   obligatorio se muestra en su lugar, marcado). "Paso n de N" es la posición en la
   lista; lo que cuenta como avance para la CSM son solo los obligatorios. */
function cabecera() {
  const pasos = estado.pasos;
  const lista = pasos.filter(p => p.tipo !== 'final');
  const n = Math.min(vista + 1, lista.length);
  const pct = Math.round((estado.actual / lista.length) * 100);
  const hecho = p => !!(estado.progreso[p.key] && estado.progreso[p.key].completado);
  /* Bloqueado = falta un paso OBLIGATORIO antes (igual que cs_ob_bloqueado en la base). */
  const bloqueado = i => lista.slice(0, i).some(q => q.obligatorio !== false && !hecho(q));
  return `
    <div class="pub-head">
      ${estado.marca ? `<div class="ob-marca">${esc(estado.marca)}</div>` : ''}
      <div class="pub-hola">Hola ${esc(estado.alumno || '')} 👋</div>
      <h1 class="pub-titulo">${esc(estado.programa || 'Tu onboarding')}</h1>
      ${estado.mentor ? `<div class="pub-sub">Mentor: ${esc(estado.mentor)}</div>` : ''}
    </div>
    <div class="ob-progreso">
      <div class="ob-progreso-txt">Paso ${n} de ${lista.length}</div>
      <div class="ob-barra" aria-hidden="true"><span style="width:${pct}%"></span></div>
    </div>
    <ol class="ob-pasos" aria-label="Pasos del onboarding">
      ${lista.map((p, i) => {
        const ok = hecho(p);
        const bloq = !ok && i !== estado.actual && bloqueado(i);
        const cls = i === vista ? 'actual' : ok ? 'hecho' : bloq ? 'bloqueado' : '';
        const marca = ok ? '✓' : bloq ? '🔒' : String(i + 1);
        const opc = p.obligatorio === false ? ' <span class="ob-bloq">Opcional</span>' : '';
        return `<li class="ob-paso-item ${cls}"${i === vista ? ' aria-current="step"' : ''}>
          <span class="ob-paso-n" aria-hidden="true">${marca}</span>
          <span class="ob-paso-t">${esc(p.titulo)}${opc}${bloq ? ' <span class="ob-bloq">Bloqueado hasta completar el anterior</span>' : ''}</span>
        </li>`;
      }).join('')}
    </ol>
    ${vista > 0 ? `<div class="ob-volver">
      <button type="button" class="btn" id="ob-volver">← Volver al paso anterior</button>
    </div>` : ''}
    <div id="ob-paso" class="ob-paso"></div>`;
}

/* Paso ya completado, visto con "Volver": dice que está hecho y deja avanzar. Por
   privacidad NO se vuelven a mostrar las respuestas enviadas (el servidor tampoco
   las manda). Los accesos sí muestran sus botones: abrirlos de nuevo no cambia nada. */
function pasoRevisado(box, p) {
  const hechos = (estado.progreso[p.key] && estado.progreso[p.key].enlaces) || {};
  const nota = p.tipo === 'formulario'
    ? 'Ya enviaste este formulario. Por privacidad no mostramos tus respuestas acá.'
    : p.tipo === 'acceso' ? 'Ya confirmaste estos accesos.' : 'Ya completaste este paso.';
  const enlaces = p.tipo === 'acceso' ? `
    <div class="ob-accesos">
      ${(p.enlaces || []).map(e => {
        const href = urlSegura(e.url);
        return `<div class="ob-acceso${hechos[e.key] ? ' hecho' : ''}">
          <div class="ob-acceso-t">${hechos[e.key] ? '<span class="ob-ok" aria-hidden="true">✓</span> ' : ''}${esc(e.label)}</div>
          ${href ? `<div class="ob-acceso-acc"><a class="btn" href="${esc(href)}" target="_blank" rel="noopener noreferrer">${esc(e.boton || 'Abrir')}</a></div>` : ''}
        </div>`;
      }).join('')}
    </div>` : '';
  box.innerHTML = `
    <h2 class="ob-titulo">${esc(p.titulo)}</h2>
    <div class="ob-hecho-aviso" role="status"><span class="ob-ok" aria-hidden="true">✓</span> ${esc(nota)}</div>
    ${enlaces}
    <button type="button" class="btn btn-accent pub-enviar" id="ob-seguir-rev">Continuar</button>`;
  box.querySelector('#ob-seguir-rev').addEventListener('click', () => {
    vista = Math.min(vista + 1, estado.actual);
    pintar();
    window.scrollTo({ top: 0 });
  });
  return { destruir() {} };
}

/* Paso de accesos: cada enlace con su botón y su confirmación. */
function pasoAcceso(box, p) {
  const hechos = (estado.progreso[p.key] && estado.progreso[p.key].enlaces) || {};
  box.innerHTML = `
    <h2 class="ob-titulo">${esc(p.titulo)}</h2>
    ${p.texto ? `<p class="ob-texto">${esc(p.texto)}</p>` : ''}
    <div class="pub-aviso ob-error" id="ob-error" role="alert" hidden></div>
    <div class="ob-accesos">
      ${p.enlaces.map(e => {
        const ok = !!hechos[e.key];
        const href = urlSegura(e.url);
        return `<div class="ob-acceso${ok ? ' hecho' : ''}" data-enlace="${esc(e.key)}">
          <div class="ob-acceso-t">${ok ? '<span class="ob-ok" aria-hidden="true">✓</span> ' : ''}${esc(e.label)}</div>
          <div class="ob-acceso-acc">
            ${href ? `<a class="btn" href="${esc(href)}" target="_blank" rel="noopener noreferrer">${esc(e.boton || 'Abrir')}</a>` : ''}
            ${ok ? '<span class="ob-hecho-txt">Listo</span>'
                 : `<button type="button" class="btn btn-accent" data-confirmar="${esc(e.key)}">Ya lo hice</button>`}
          </div>
        </div>`;
      }).join('')}
    </div>`;

  box.addEventListener('click', async ev => {
    const b = ev.target.closest('[data-confirmar]');
    if (!b || b.disabled) return;
    b.disabled = true;
    b.textContent = 'Guardando…';
    try {
      const s = await rpc('cs_ob_confirmar', { p_token: token, p_paso: p.key, p_enlace: b.dataset.confirmar });
      aplicar(s);
    } catch (e) {
      b.disabled = false;
      b.textContent = 'Ya lo hice';
      const er = box.querySelector('#ob-error');
      er.textContent = mensaje(e);
      er.hidden = false;
    }
  });
  return { destruir() {} };
}

function pasoTexto(box, p) {
  box.innerHTML = `
    <h2 class="ob-titulo">${esc(p.titulo)}</h2>
    ${p.texto ? `<p class="ob-texto">${esc(p.texto)}</p>` : ''}
    <div class="pub-aviso ob-error" id="ob-error" role="alert" hidden></div>
    <button type="button" class="btn btn-accent pub-enviar" id="ob-seguir">Continuar</button>`;
  box.querySelector('#ob-seguir').addEventListener('click', async ev => {
    ev.target.disabled = true;
    try {
      aplicar(await rpc('cs_ob_avanzar', { p_token: token, p_paso: p.key, p_respuestas: {}, p_completar: true }));
    } catch (e) {
      ev.target.disabled = false;
      const er = box.querySelector('#ob-error');
      er.textContent = mensaje(e);
      er.hidden = false;
    }
  });
  return { destruir() {} };
}

function pintar() {
  if (paso) { paso.destruir(); paso = null; }

  if (estado.estado === 'completado') {
    if (acabaDeTerminar) pantallaFinal();
    else pantalla('Ya completaste el onboarding', 'No hace falta que hagas nada más. Si tenés dudas, escribile a tu mentor.', true);
    return;
  }
  if (estado.estado === 'vencido') {
    pantalla('Este link venció', 'Pedile uno nuevo a quien te lo mandó.');
    return;
  }

  vista = Math.max(0, Math.min(vista, estado.actual));
  const p = estado.pasos[vista];
  if (!p || p.tipo === 'final') { pantallaFinal(); return; }

  root.innerHTML = cabecera();
  const box = root.querySelector('#ob-paso');
  const volver = root.querySelector('#ob-volver');
  if (volver) {
    volver.addEventListener('click', () => {
      if (paso && paso.guardarBorrador) paso.guardarBorrador();
      vista = Math.max(0, vista - 1);
      pintar();
      window.scrollTo({ top: 0 });
    });
  }
  if (vista < estado.actual) {
    paso = pasoRevisado(box, p);
  } else if (p.tipo === 'video') {
    const seg = (estado.progreso[p.key] && estado.progreso[p.key].segundos) || 0;
    paso = pasoVideo(box, p, seg, api);
  } else if (p.tipo === 'formulario') {
    paso = pasoFormulario(box, p, (estado.respuestas || {})[p.key] || {}, api);
  } else if (p.tipo === 'acceso') {
    paso = pasoAcceso(box, p);
  } else {
    paso = pasoTexto(box, p);
  }
}

/* Recibe el estado nuevo que devuelve el servidor y repinta. */
function aplicar(nuevo) {
  const eraCompleto = estado && estado.estado === 'completado';
  if (nuevo && nuevo.estado === 'completado' && !eraCompleto && estado && estado.estado === 'ok') {
    acabaDeTerminar = true;
  }
  if (nuevo && nuevo.pasos) pasoFinal = nuevo.pasos.find(x => x.tipo === 'final') || pasoFinal;
  estado = nuevo;
  /* Tras avanzar se muestra el paso actual; un formulario enviado suelta su borrador. */
  vista = (nuevo && Number.isInteger(nuevo.actual)) ? nuevo.actual : 0;
  if (nuevo && nuevo.progreso) {
    for (const k of Object.keys(borradores)) {
      if (nuevo.progreso[k] && nuevo.progreso[k].completado) delete borradores[k];
    }
  }
  window.scrollTo({ top: 0 });
  pintar();
}

/* ---------- Arranque ---------- */

async function iniciar() {
  if (!/^[0-9a-f]{64}$/.test(token)) {
    pantalla('Link inválido', 'Revisá que hayas copiado el link completo, o pedile uno nuevo a quien te lo mandó.');
    return;
  }
  try {
    const s = await rpc('cs_ob_estado', { p_token: token });
    if (s && s.pasos) pasoFinal = s.pasos.find(x => x.tipo === 'final') || null;
    estado = s;
    vista = Number.isInteger(s && s.actual) ? s.actual : 0;
    document.title =`${s.programa || 'Tu onboarding'} · Onboarding`;
    pintar();
  } catch (e) {
    const sinRed = /failed to fetch|networkerror|load failed/i.test((e && e.message) || '');
    pantalla(sinRed ? 'Sin conexión' : 'Link inválido',
      sinRed ? 'Revisá tu internet y volvé a abrir el link.'
             : 'Revisá que hayas copiado el link completo, o pedile uno nuevo a quien te lo mandó.');
  }
}

iniciar();
