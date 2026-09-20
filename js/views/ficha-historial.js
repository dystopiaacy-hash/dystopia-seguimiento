/* Ficha de cliente — formularios respondidos, historial y notas.
   Los formularios se muestran tal como quedaron en cs_respuestas; el constructor de
   formularios es una fase siguiente. El historial junta cs_historial (lo que
   escribieron los triggers) con los chequeos del cliente, en una sola línea de tiempo. */
import { esc, fmtFecha, fmtFechaHora, plural, abrirModal } from '../ui.js';
import {
  actualizarFila, nombreUsuario,
  ESTADO_LABEL, ACC_LABEL, DEV_LABEL, CALL_ESTADO_LABEL, REN_LABEL
} from '../datos.js';
import { mapaPorId, guardar, textoTipoCall } from './comunes.js';

/* ---------- Formularios respondidos ---------- */

function nombreFormulario(ctx, id) {
  const f = (ctx.formularios || []).find(x => x.id === id);
  return f ? f.nombre : 'Formulario';
}

function filaRespuesta(ctx, r) {
  return `
    <button type="button" class="resp-row" data-resp="${esc(r.id)}">
      <span class="resp-fecha">${esc(fmtFecha(r.created_at))}</span>
      <span class="resp-nombre">${esc(nombreFormulario(ctx, r.formulario_id))}</span>
      <span class="resp-puntaje">${r.puntaje == null ? '<span class="txt-gris">sin puntaje</span>' : esc(String(r.puntaje) + ' / 10')}</span>
      <span class="aten-ir">Ver respuesta →</span>
    </button>`;
}

function bloqueFormularios(ctx) {
  const rs = ctx.respuestas || [];
  return `
    <div class="section-title">Formularios respondidos
      <span class="aten-cuenta">${esc(plural(rs.length, 'respuesta'))}</span>
      <span class="line"></span>
    </div>
    <div class="card card-list resp-lista">
      ${rs.length ? rs.map(r => filaRespuesta(ctx, r)).join('') : '<div class="muted-empty">Este cliente todavía no respondió ningún formulario.</div>'}
    </div>`;
}

/* Los si/no se guardan como 'si' y 'no': se muestran como los lee una persona. */
function valorLegible(campo, v) {
  if (v == null || v === '') return '—';
  const s = String(v);
  if (campo && campo.tipo === 'si_no') return s === 'si' ? 'Sí' : s === 'no' ? 'No' : s;
  return s;
}

/* Campos del formulario para poner etiquetas legibles; si la respuesta trae una clave
   que el formulario ya no tiene, se muestra la clave tal cual. */
function detalleRespuesta(ctx, r) {
  const form = (ctx.formularios || []).find(x => x.id === r.formulario_id);
  const campos = form && Array.isArray(form.campos) ? form.campos : [];
  const datos = r.respuestas && typeof r.respuestas === 'object' ? r.respuestas : {};
  const claves = campos.map(c => c.key).concat(Object.keys(datos).filter(k => !campos.some(c => c.key === k)));
  const filas = Array.from(new Set(claves)).map(k => {
    const campo = campos.find(c => c.key === k);
    const valor = valorLegible(campo, datos[k]);
    return `<div class="resp-campo">
        <div class="field-label">${esc(campo ? campo.label : k)}</div>
        <div class="resp-valor">${esc(valor)}</div>
      </div>`;
  }).join('');
  return `
    <div class="resp-detalle">
      <p class="aviso-texto">${esc(nombreFormulario(ctx, r.formulario_id))} · ${esc(fmtFechaHora(r.created_at))}${r.puntaje == null ? '' : ` · puntaje ${r.puntaje}/10`}</p>
      ${filas || '<div class="muted-empty">La respuesta llegó vacía.</div>'}
    </div>`;
}

/* ---------- Historial ---------- */

const VALOR_LABEL = {
  cs_clientes: ESTADO_LABEL,
  cs_accionables: ACC_LABEL,
  cs_devoluciones: DEV_LABEL,
  cs_calls: CALL_ESTADO_LABEL,
  cs_renovaciones: REN_LABEL
};

function etiquetaValor(tabla, campo, v) {
  if (v == null || v === '') return 'sin valor';
  if (campo === 'fecha_fin') return fmtFecha(v);
  const mapa = VALOR_LABEL[tabla];
  return (mapa && mapa[v]) || v;
}

/* De qué registro habla la fila: título del accionable, de la devolución, etc. */
function sujeto(ctx, h, mapas) {
  if (h.tabla === 'cs_clientes') return campoCliente(h.campo);
  if (h.tabla === 'cs_accionables') {
    const a = mapas.accionables.get(h.registro_id);
    return a ? `Accionable "${a.titulo}"` : 'Accionable';
  }
  if (h.tabla === 'cs_devoluciones') {
    const d = mapas.devoluciones.get(h.registro_id);
    return d ? `Devolución "${d.titulo}"` : 'Devolución';
  }
  if (h.tabla === 'cs_calls') {
    const c = mapas.calls.get(h.registro_id);
    return c ? `Call de ${textoTipoCall(c.tipo).toLowerCase()}` : 'Call';
  }
  if (h.tabla === 'cs_renovaciones') return 'Renovación';
  return h.tabla;
}

function campoCliente(campo) {
  return campo === 'estado' ? 'Estado del cliente' : campo === 'fecha_fin' ? 'Fecha de fin' : campo;
}

function filaHistorial(ctx, h, mapas) {
  const de = h.valor_anterior;
  const texto = de == null
    ? `${sujeto(ctx, h, mapas)}: ${etiquetaValor(h.tabla, h.campo, h.valor_nuevo)}`
    : `${sujeto(ctx, h, mapas)}: ${etiquetaValor(h.tabla, h.campo, de)} → ${etiquetaValor(h.tabla, h.campo, h.valor_nuevo)}`;
  return `
    <div class="hist-row">
      <span class="hist-fecha">${esc(fmtFechaHora(h.at))}</span>
      <span class="hist-texto">${esc(texto)}</span>
      <span class="hist-quien">${esc(nombreUsuario(h.usuario))}</span>
    </div>`;
}

function filaChequeo(ch) {
  return `
    <div class="hist-row hist-chequeo">
      <span class="hist-fecha">${esc(fmtFechaHora(ch.created_at))}</span>
      <span class="hist-texto">Chequeo${ch.nota ? ': ' + esc(ch.nota) : ' registrado'}</span>
      <span class="hist-quien">${esc(nombreUsuario(ch.usuario))}</span>
    </div>`;
}

function bloqueHistorial(ctx) {
  const mapas = {
    accionables: mapaPorId(ctx.accionables),
    devoluciones: mapaPorId(ctx.devoluciones),
    calls: mapaPorId(ctx.calls),
    renovaciones: mapaPorId(ctx.renovaciones)
  };
  const filas = (ctx.historial || []).map(h => ({ at: h.at, html: filaHistorial(ctx, h, mapas) }))
    .concat((ctx.chequeos || []).map(ch => ({ at: ch.created_at, html: filaChequeo(ch) })))
    .sort((a, b) => String(b.at).localeCompare(String(a.at)));

  return `
    <div class="section-title">Historial<span class="line"></span></div>
    <div class="card card-list hist-lista">
      ${filas.length ? filas.map(f => f.html).join('') : '<div class="muted-empty">Todavía no hay movimientos registrados.</div>'}
    </div>`;
}

/* ---------- Notas ---------- */

function bloqueNotas(ctx) {
  return `
    <div class="section-title">Notas<span class="line"></span></div>
    <div class="card">
      <div class="form-row">
        <label for="f-notas">Notas operativas del cliente</label>
        <textarea id="f-notas" maxlength="4000" rows="4"
          placeholder="Contexto del cliente, acuerdos, cosas a tener en cuenta. Nada de datos financieros.">${esc(ctx.c.notas || '')}</textarea>
      </div>
      <button type="button" class="btn btn-sm btn-accent" data-accion="guardar-notas">Guardar notas</button>
    </div>`;
}

export function html(ctx) {
  return bloqueFormularios(ctx) + bloqueHistorial(ctx) + bloqueNotas(ctx);
}

/* ---------- Acciones ---------- */

export async function manejar(ev, ctx, api) {
  if (ev.type === 'change' || ev.type === 'submit') return false;

  const resp = ev.target.closest('[data-resp]');
  if (resp) {
    const r = (ctx.respuestas || []).find(x => x.id === resp.dataset.resp);
    if (r) abrirModal({ titulo: 'Respuesta del formulario', cuerpo: detalleRespuesta(ctx, r), ancho: true });
    return true;
  }

  const notas = ev.target.closest('[data-accion="guardar-notas"]');
  if (notas) {
    const el = document.getElementById('f-notas');
    const valor = el ? el.value.trim() : '';
    await guardar(() => actualizarFila('cs_clientes', ctx.c.id, { notas: valor || null }), {
      ok: 'Notas guardadas.', luego: () => api.refrescar(), control: notas
    });
    return true;
  }
  return false;
}
