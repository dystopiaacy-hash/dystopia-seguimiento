/* Ficha de cliente — wins y "listo para upsell" (106).
   Wins: fecha, texto, tipo y monto opcional. Cada alta avisa a Discord (la base) y deja el
   pendiente "Pedir referido", que se resuelve acá o en Hoy.
   Upsell: marca manual con motivo y fecha, y una SUGERENCIA con regla visible (js/config.js)
   que no marca sola: el CSM confirma. Relación con Resell: si ya hay un pipeline de resell
   abierto, la marca ya cumplió su función y se muestra "En resell" (la integración es de lectura:
   el pipeline sigue siendo cs_renovaciones, no hay un concepto paralelo).
   ctx.wins (undefined = 106 sin correr: no se muestra), ctx.estado.resumen para puntaje y marca. */
import { esc, fmtFecha, abrirModal, cerrarModal, confirmar } from '../ui.js';
import { esFundador, puedeEditarPrograma } from '../sesion.js';
import { borrarFila, renAbierta, REN_LABEL } from '../datos.js';
import { guardar } from './comunes.js';
import {
  WIN_TIPO_LABEL, REFERIDO_LABEL, resolverReferido, marcarUpsell, quitarUpsell
} from '../datos-wins.js';
import { sugeridoUpsell, TEXTO_REGLA_UPSELL } from './estado-columnas.js';
import { abrirModalWin } from './win-modal.js';

/* La fila con todo lo que la regla necesita, armada con lo que ya tiene la ficha. */
function filaRegla(ctx) {
  const r = (ctx.estado && ctx.estado.resumen) || {};
  const abierta = (ctx.renovaciones || []).find(x => renAbierta(x.estado));
  return {
    ...ctx.c, ...r,
    ultima_llamada: ctx.estado && ctx.estado.ultima ? ctx.estado.ultima.fecha : null,
    renovacion_estado: abierta ? abierta.estado : null
  };
}

function bloqueUpsell(ctx, f, editar) {
  const abierta = renAbierta(f.renovacion_estado);
  if (abierta) {
    return `<div class="wins-upsell"><span class="est-chip est-resell">En resell · ${esc(REN_LABEL[f.renovacion_estado] || f.renovacion_estado)}</span>
      <span class="hint">Ya hay un pipeline de resell abierto: se sigue desde Renovaciones.</span></div>`;
  }
  if (f.upsell_marcado) {
    return `<div class="wins-upsell"><span class="est-chip est-listo">Listo para upsell</span>
      <span class="hint">${esc(f.upsell_motivo || '')}${f.upsell_at ? ' · ' + esc(fmtFecha(String(f.upsell_at).slice(0, 10))) : ''}</span>
      ${editar ? '<button type="button" class="btn btn-sm" data-w-quitar>Quitar marca</button>' : ''}</div>`;
  }
  const sugerido = sugeridoUpsell(f);
  return `<div class="wins-upsell">
      ${sugerido ? '<span class="est-chip est-sugerido">Sugerido para upsell</span>' : '<span class="txt-gris">Sin marca de upsell.</span>'}
      ${editar ? `<button type="button" class="btn btn-sm${sugerido ? ' btn-accent' : ''}" data-w-marcar="${sugerido ? 'sugerido' : 'manual'}">${sugerido ? 'Confirmar: listo para upsell' : 'Marcar listo para upsell'}</button>` : ''}
      <div class="hint wins-regla">Regla de la sugerencia: ${esc(TEXTO_REGLA_UPSELL)}</div>
    </div>`;
}

function filaWin(w, editar, fundador) {
  const ref = w.referido_estado;
  const acciones = editar ? (ref === 'pendiente'
    ? `<button type="button" class="btn btn-sm" data-w-ref="pedido" data-id="${esc(w.id)}">Pedí el referido</button>
       <button type="button" class="btn btn-sm" data-w-ref="descartado" data-id="${esc(w.id)}">Descartar</button>`
    : `<button type="button" class="btn-icono" data-w-ref="pendiente" data-id="${esc(w.id)}">Volver a pendiente</button>`) : '';
  return `<div class="win-fila">
      <div class="win-main">
        <div><strong>${esc(w.texto)}</strong></div>
        <div class="hint">${esc(fmtFecha(w.fecha))} · ${esc(WIN_TIPO_LABEL[w.tipo] || w.tipo)}${w.monto != null ? ' · ' + esc(Number(w.monto).toLocaleString('es-AR')) : ''}
          · <span class="win-ref win-ref-${esc(ref)}">${esc(REFERIDO_LABEL[ref] || ref)}</span></div>
      </div>
      <span class="ll-item-acc">${acciones}${fundador ? `<button type="button" class="btn-icono btn-icono-danger" data-w-borrar="${esc(w.id)}">Borrar</button>` : ''}</span>
    </div>`;
}

export function html(ctx) {
  if (!ctx.wins) return '';
  const editar = puedeEditarPrograma(ctx.p.id);
  const f = filaRegla(ctx);
  return `
    <div class="section-title">Wins y upsell<span class="line"></span>
      ${editar ? '<button type="button" class="btn btn-sm btn-accent" data-w-nuevo>Nuevo win</button>' : ''}</div>
    <div class="card wins-card">
      ${bloqueUpsell(ctx, f, editar)}
      ${ctx.wins.length ? ctx.wins.map(w => filaWin(w, editar, esFundador())).join('')
        : '<div class="muted-empty">Todavía no hay wins cargados.</div>'}
    </div>`;
}

function modalMotivo(sugerido, alGuardar) {
  const base = sugerido ? 'Win reciente y sin señales rojas (sugerido por la regla).' : '';
  abrirModal({
    titulo: 'Listo para upsell',
    cuerpo: `<div class="form-row"><label for="up-motivo">Motivo *</label>
        <input type="text" id="up-motivo" maxlength="300" autocomplete="off" value="${esc(base)}"
          placeholder="Ej: cerró su primera venta y pidió seguir"></div>
      <div id="up-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="up-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="up-ok">Marcar</button>`
  });
  const inp = document.getElementById('up-motivo');
  inp.focus();
  document.getElementById('up-cancelar').onclick = cerrarModal;
  const ok = () => {
    const t = inp.value.trim();
    if (!t) { document.getElementById('up-error').textContent = 'Escribí el motivo.'; return; }
    cerrarModal();
    alGuardar(t);
  };
  document.getElementById('up-ok').onclick = ok;
  inp.addEventListener('keydown', ev => { if (ev.key === 'Enter') { ev.preventDefault(); ok(); } });
}

export async function manejar(ev, ctx, api) {
  if (ev.type !== 'click' || !ctx.wins) return false;
  if (!ev.target.closest('[data-w-nuevo],[data-w-marcar],[data-w-quitar],[data-w-ref],[data-w-borrar]')) return false;
  const editar = puedeEditarPrograma(ctx.p.id);
  const refrescar = () => api.refrescar();
  const el = sel => ev.target.closest(sel);

  if (el('[data-w-nuevo]')) {
    if (editar) abrirModalWin({ programaId: ctx.p.id, fijo: { id: ctx.c.id, nombre: ctx.c.nombre }, alGuardar: refrescar });
    return true;
  }
  const m = el('[data-w-marcar]');
  if (m) {
    if (editar) {
      modalMotivo(m.dataset.wMarcar === 'sugerido',
        motivo => guardar(() => marcarUpsell(ctx.p.id, ctx.c.id, motivo), { ok: 'Marcado como listo para upsell.', luego: refrescar }));
    }
    return true;
  }
  const q = el('[data-w-quitar]');
  if (q) {
    if (editar) await guardar(() => quitarUpsell(ctx.c.id), { ok: 'Marca de upsell quitada.', luego: refrescar, control: q });
    return true;
  }
  const r = el('[data-w-ref]');
  if (r) {
    if (editar) {
      await guardar(() => resolverReferido(r.dataset.id, r.dataset.wRef), { ok: 'Listo.', luego: refrescar, control: r });
    }
    return true;
  }
  const b = el('[data-w-borrar]');
  if (b) {
    if (!esFundador()) return true;
    const ok = await confirmar({
      titulo: 'Borrar win', texto: 'Se borra el win y su pendiente de referido.', detalle: 'No se puede deshacer.', ok: 'Borrar'
    });
    if (ok) await guardar(() => borrarFila('cs_wins', b.dataset.wBorrar), { ok: 'Win borrado.', luego: refrescar, control: b });
    return true;
  }
  return false;
}
