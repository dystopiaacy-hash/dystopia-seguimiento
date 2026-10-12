/* Onboarding público: paso de video (obligatorio u opcional según el dato del paso).

   Mecanismo (ver 093, cs_ob_latido): el servidor cuenta el tiempo que este paso estuvo
   en pantalla con la pestaña visible. Mientras el video está en pantalla y la pestaña
   está a la vista, la página manda un latido cada 10 s; el servidor suma lo transcurrido
   entre latidos (máximo 15 s por latido).
   - paso.obligatorio === false (hoy, en Liam): el botón está habilitado desde el
     principio. El tiempo se registra igual (le sirve a la CSM) y el servidor marca
     "visto" si llegó al 90 % de la duración. No exige nada.
   - obligatorio (por defecto): el botón se habilita cuando el servidor ya contó el
     tiempo requerido, y el servidor vuelve a exigirlo al recibir "continuar": editar
     esta página no alcanza. Un video obligatorio sin duración no pasa la validación
     de la base, así que acá siempre hay un tiempo requerido.

   Límites, dichos sin vueltas: mide tiempo con el video en pantalla, NO que la persona
   lo haya mirado ni que haya dado play. Alguien puede dejar la pestaña abierta y
   hacer otra cosa. El reproductor de Loom embebido no se usa como fuente de verdad
   porque no hay un evento de "terminó" documentado y verificable. */
import { esc } from './ui.js';

const LATIDO_MS = 10000;
const LATIDO_RAPIDO_MS = 6000;   // cuando el contador local ya llegó y falta que el servidor lo confirme

/* loom.com/share/<id> -> loom.com/embed/<id>. La URL ya la validó la base (32 hex). */
function urlEmbed(url) {
  const m = /^https:\/\/(?:www\.)?loom\.com\/share\/([0-9a-f]{32})/.exec(String(url || ''));
  return m ? `https://www.loom.com/embed/${m[1]}?hide_owner=true&hide_share=true&hide_title=true&hideEmbedTopBar=true` : '';
}

function mmss(s) {
  const t = Math.max(0, Math.ceil(s));
  return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, '0')}`;
}

/* box: contenedor del paso. api: { rpc, token, aplicar, mensaje }.
   Devuelve { destruir } para cortar timers al cambiar de paso. */
export function pasoVideo(box, paso, segundosIniciales, api) {
  const embed = urlEmbed(paso.url);
  const obligatorio = paso.obligatorio !== false;
  /* Mismo criterio que cs_ob_video_requerido. null = duración desconocida (solo opcional). */
  const requerido = paso.minimo_seg || (paso.duracion_seg ? Math.ceil(paso.duracion_seg * 0.9) : null);
  const tope = requerido || 3600;                                    // mismo tope que el servidor
  let local = Math.min(Number(segundosIniciales) || 0, tope);        // lo que muestra el contador
  let servidor = local;                                              // lo que el servidor confirmó
  let enviando = false, cerrado = false;
  let tTick = null, tLatido = null, ultimo = 0;

  box.innerHTML = `
    <h2 class="ob-titulo">${esc(paso.titulo)}</h2>
    ${paso.texto ? `<p class="ob-texto">${esc(paso.texto)}</p>` : ''}
    ${embed ? `<div class="ob-video"><iframe src="${esc(embed)}" title="${esc(paso.titulo)}" loading="lazy"
        allow="autoplay; fullscreen; picture-in-picture" allowfullscreen referrerpolicy="no-referrer"></iframe></div>`
      : '<div class="pub-aviso" role="alert">No se pudo cargar el video. Avisale a quien te mandó el link.</div>'}
    ${obligatorio ? `<div class="ob-tiempo" id="ob-tiempo" aria-live="polite"></div>
    <div class="ob-barra" aria-hidden="true"><span id="ob-barra-i"></span></div>` : ''}
    <div class="pub-aviso ob-error" id="ob-error" role="alert" hidden></div>
    <button type="button" class="btn btn-accent pub-enviar" id="ob-seguir"${obligatorio ? ' disabled' : ''}>${esc(paso.boton || 'Continuar')}</button>
    ${obligatorio ? '<div class="pub-pie">Dejá este video en pantalla: el botón se habilita cuando termina el tiempo del video.</div>' : ''}`;

  const elTiempo = box.querySelector('#ob-tiempo');   // null si el video es opcional
  const elBarra = box.querySelector('#ob-barra-i');
  const btn = box.querySelector('#ob-seguir');
  const elError = box.querySelector('#ob-error');

  const visible = () => document.visibilityState === 'visible';
  /* Habilitado para continuar: siempre si es opcional; si no, cuando el servidor contó el tiempo. */
  const listo = () => !obligatorio || requerido == null || servidor >= requerido;
  /* El servidor ya no suma más (llegó al tiempo del video o al tope): dejar de mandar latidos. */
  const completo = () => servidor >= tope;

  function pintar() {
    if (!obligatorio) {
      btn.disabled = enviando;
      return;
    }
    const pct = Math.min(100, (local / requerido) * 100);
    elBarra.style.width = pct.toFixed(1) + '%';
    if (listo()) {
      elTiempo.textContent = 'Listo: ya podés continuar.';
      btn.disabled = enviando;
    } else if (local >= requerido) {
      elTiempo.textContent = 'Verificando…';
      btn.disabled = true;
    } else {
      elTiempo.textContent = visible()
        ? `Te falta ${mmss(requerido - local)} de video para continuar.`
        : 'En pausa: volvé a esta pestaña para seguir contando el tiempo.';
      btn.disabled = true;
    }
  }

  async function latido() {
    if (cerrado || enviando || completo() || !visible()) return;
    ultimo = Date.now();
    try {
      const d = await api.rpc('cs_ob_latido', { p_token: api.token, p_paso: paso.key });
      if (cerrado) return;
      servidor = Math.max(servidor, Number(d && d.segundos) || 0);
      /* El contador local no se queda atrás del servidor ni lo pasa por mucho. */
      if (local < servidor) local = servidor;
    } catch (e) {
      /* Un latido perdido solo atrasa el contador: no se muestra error. */
      console.error('latido', e);
    }
    pintar();
  }

  function tick() {
    if (cerrado || !visible()) { pintar(); return; }
    if (local < tope) local += 1;
    const espera = obligatorio && local >= tope && !completo() ? LATIDO_RAPIDO_MS : LATIDO_MS;
    if (Date.now() - ultimo >= espera) latido();
    pintar();
  }

  btn.addEventListener('click', async () => {
    if (!listo() || enviando) return;
    enviando = true;
    elError.hidden = true;
    btn.disabled = true;
    btn.textContent = 'Guardando…';
    try {
      const estado = await api.rpc('cs_ob_avanzar', { p_token: api.token, p_paso: paso.key, p_respuestas: {}, p_completar: true });
      cerrado = true;
      api.aplicar(estado);
    } catch (e) {
      enviando = false;
      btn.textContent = paso.boton || 'Continuar';
      elError.textContent = api.mensaje(e);
      elError.hidden = false;
      pintar();
    }
  });

  document.addEventListener('visibilitychange', pintar);
  tTick = setInterval(tick, 1000);
  tLatido = setTimeout(latido, 300);   // primer latido enseguida: deja registrado que empezó
  pintar();

  return {
    destruir() {
      cerrado = true;
      clearInterval(tTick);
      clearTimeout(tLatido);
      document.removeEventListener('visibilitychange', pintar);
    }
  };
}
