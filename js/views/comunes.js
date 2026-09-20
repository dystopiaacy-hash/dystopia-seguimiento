/* Piezas compartidas por la ficha de cliente y por las vistas transversales
   (Accionables, Devoluciones, Calls): badges, celdas de vencimiento, espera de SLA,
   campo de Loom con embed y el envoltorio de guardado con toast. */
import {
  esc, badge, fmtFecha, fmtHoras, plural, toast, loomEmbed, urlSegura, diasRestantes
} from '../ui.js';
import {
  mensajeError, horasEspera, horasAtraso,
  ACC_LABEL, ACC_COLOR, DEV_LABEL, DEV_COLOR,
  CALL_TIPO_LABEL, CALL_ESTADO_LABEL, CALL_ESTADO_COLOR, REN_LABEL, REN_COLOR
} from '../datos.js';

export const num = v => Number(v) || 0;

/* ---------- Selects y opciones ---------- */

export function opcionesHtml(pares, valor) {
  return pares.map(([v, t]) =>
    `<option value="${esc(v)}"${String(v) === String(valor) ? ' selected' : ''}>${esc(t)}</option>`).join('');
}

/* Etiqueta y select viajan juntos para que la fila de filtros corte entre filtros. */
export function filtroSelect(id, label, pares, valor) {
  return `<span class="fgroup">
      <label class="flabel" for="${id}">${esc(label)}</label>
      <select id="${id}">${opcionesHtml(pares, valor)}</select>
    </span>`;
}

/* ---------- Badges por tabla ---------- */
export const badgeAcc = e => badge(ACC_LABEL[e] || e, ACC_COLOR[e], 'status');
export const badgeDev = e => badge(DEV_LABEL[e] || e, DEV_COLOR[e], 'status');
export const badgeCall = e => badge(CALL_ESTADO_LABEL[e] || e, CALL_ESTADO_COLOR[e], 'status');
export const badgeRen = e => badge(REN_LABEL[e] || e, REN_COLOR[e], 'status');
export const textoTipoCall = t => CALL_TIPO_LABEL[t] || t;

/* ---------- Vencimiento de un accionable ---------- */
/* Rojo solo si está vencido y el accionable sigue abierto: rojo = hay que actuar ya. */
export function celdaVence(a) {
  if (!a.vence) return '<span class="txt-gris">Sin fecha</span>';
  const d = diasRestantes(a.vence);
  const abierto = a.estado !== 'completado';
  const clase = abierto && d != null && d < 0 ? 'txt-rojo' : (abierto && d === 0 ? 'txt-amarillo' : 'txt-gris');
  const tit = d == null ? '' : d < 0 ? `Venció hace ${plural(-d, 'día')}` : d === 0 ? 'Vence hoy' : `Faltan ${plural(d, 'día')}`;
  return `<span class="${clase}" title="${esc(tit)}">${esc(fmtFecha(a.vence))}</span>`;
}

/* ---------- Espera de una devolución contra el SLA ---------- */
/* Devuelve { texto, fuera, titulo } con las horas en espera y si pasó el SLA. */
export function espera(dev, slaHoras) {
  const h = horasEspera(dev);
  const atraso = horasAtraso(dev, slaHoras);
  const fuera = atraso != null && atraso > 0;
  return {
    horas: h,
    atraso,
    fuera,
    texto: h == null ? '—' : fmtHoras(h),
    titulo: h == null ? ''
      : dev.estado === 'entregada'
        ? `Tardó ${fmtHoras(h)} desde que se solicitó`
        : fuera
          ? `En espera hace ${fmtHoras(h)} · ${fmtHoras(atraso)} fuera del SLA de ${plural(num(slaHoras), 'hora')}`
          : `En espera hace ${fmtHoras(h)} · dentro del SLA de ${plural(num(slaHoras), 'hora')}`
  };
}

export function pillEspera(dev, slaHoras) {
  const e = espera(dev, slaHoras);
  return `<span class="espera${e.fuera ? ' txt-rojo' : ''}" title="${esc(e.titulo)}">${esc(e.texto)}${e.fuera ? ' · fuera de SLA' : ''}</span>`;
}

/* ---------- Loom ---------- */
/* Campo para pegar el link + embed. El embed solo se arma si la URL valida como Loom;
   los links que no lo son se muestran como link y nada más.
   El iframe va dentro de un <details>: si el video no existe, falla adentro de su caja
   y la ficha no se rompe. loading="lazy" + sandbox mínimo (scripts, mismo origen que
   loom.com y presentación a pantalla completa). */
export function embedLoom(url) {
  const embed = loomEmbed(url);
  const href = urlSegura(url);
  if (!href) return '';
  const link = `<a class="loom-link" href="${esc(href)}" target="_blank" rel="noopener noreferrer">Abrir en Loom ↗</a>`;
  if (!embed) {
    return `<div class="loom-bloque"><div class="hint">Ese link no es un video de Loom que se pueda mostrar acá.</div>${link}</div>`;
  }
  return `
    <div class="loom-bloque">
      <details class="loom-det">
        <summary>Ver el video acá</summary>
        <div class="loom-embed">
          <iframe src="${esc(embed)}" title="Devolución en Loom" loading="lazy"
            sandbox="allow-scripts allow-same-origin allow-presentation"
            referrerpolicy="strict-origin-when-cross-origin"
            allow="fullscreen; picture-in-picture"></iframe>
        </div>
        <div class="hint">Si el video no aparece, el link puede estar vencido o ser privado: abrilo en Loom.</div>
      </details>
      ${link}
    </div>`;
}

/* Input + botón para pegar/actualizar el link de una devolución. */
export function campoLoom(dev) {
  return `
    <div class="loom-campo">
      <input type="url" class="loom-input" id="loom-${esc(dev.id)}" data-loom-input="${esc(dev.id)}"
        value="${esc(dev.loom_url || '')}" maxlength="300" autocomplete="off"
        placeholder="https://www.loom.com/share/…" aria-label="Link de Loom">
      <button type="button" class="btn btn-sm" data-loom-guardar="${esc(dev.id)}">Guardar link</button>
    </div>`;
}

/* ---------- Guardado ---------- */
/* Un solo lugar para: deshabilitar el control, guardar, avisar y refrescar.
   Si falla, el toast muestra el error en lenguaje claro y se vuelve a pintar
   (así el control vuelve al valor real de la base, no al que quedó en pantalla). */
export async function guardar(fn, { ok = 'Guardado.', luego = null, control = null } = {}) {
  if (control) control.disabled = true;
  try {
    const r = await fn();
    if (ok) toast(ok);
    if (luego) await luego();
    return r;
  } catch (e) {
    toast(mensajeError(e), 'error');
    if (luego) await luego();
    return null;
  } finally {
    if (control && control.isConnected) control.disabled = false;
  }
}

/* ---------- Repintado ---------- */
/* Un refresco (propio o de realtime) no tiene que borrar lo que alguien está
   escribiendo: se guarda el campo con foco (por id) y se restaura después de pintar. */
export function repintarConservandoFoco(raiz, pintar) {
  const act = document.activeElement;
  const editable = act && act.id && raiz.contains(act) && /^(INPUT|TEXTAREA)$/.test(act.tagName);
  let estado = null;
  if (editable) {
    estado = { id: act.id, valor: act.value, ini: null, fin: null };
    try { estado.ini = act.selectionStart; estado.fin = act.selectionEnd; } catch { /* date/number no tienen selección */ }
  }
  pintar();
  if (!estado) return;
  const nuevo = document.getElementById(estado.id);
  if (!nuevo) return;
  if (nuevo.value !== estado.valor) nuevo.value = estado.valor;
  nuevo.focus();
  if (estado.ini != null) {
    try { nuevo.setSelectionRange(estado.ini, estado.fin); } catch { /* ídem */ }
  }
}

/* ---------- Varios ---------- */

export function linkCliente(programaId, cliente) {
  if (!cliente) return '<span class="txt-gris">Sin cliente</span>';
  return `<a class="cli-nombre" href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(cliente.id)}">${esc(cliente.nombre)}</a>`;
}

export function mapaPorId(filas) {
  const m = new Map();
  for (const f of filas || []) m.set(f.id, f);
  return m;
}

/* 'YYYY-MM-DDTHH:mm' local para <input type="datetime-local"> desde un timestamptz. */
export function paraInputFechaHora(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  if (isNaN(d)) return '';
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

/* El valor de un <input type="datetime-local"> se manda como ISO con zona del navegador. */
export function desdeInputFechaHora(v) {
  if (!v) return null;
  const d = new Date(v);
  return isNaN(d) ? null : d.toISOString();
}
