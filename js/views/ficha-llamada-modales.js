/* Ficha de cliente — modales de llamada (102 + 106): "Nueva llamada" y "Editar llamada".
   Separado de ficha-llamadas.js por tamaño.
   Con la 106 corrida (ctx.estado !== undefined) la llamada suma Resumen, "En qué está",
   "Próximos pasos", transcripción o resumen de Fathom (plegado) y "Dudas que aparecieron",
   y el alta va por cs_llamada_crear: llamada, accionables, links, transcripción y dudas en UNA
   transacción (si falla un paso no queda nada). Sin la 106 es el modal de la 102 de siempre.
   La transcripción solo la ve y la edita quien edita el programa (la base lo exige). */
import { esc, abrirModal, cerrarModal, hoyAR } from '../ui.js';
import { sb } from '../supabase.js';
import { esFundador } from '../sesion.js';
import { actualizarFila } from '../datos.js';
import { guardar } from './comunes.js';
import { crearLlamada, parsearAccionables, parsearLinks } from '../datos-llamadas.js';
import { traerDudas } from '../datos-dudas.js';
import { montarSelectorDudas } from './duda-selector.js';

const T_TRANSC = 'cs_llamada_transcripciones';

const camposEstado = (v = {}) => `
  <div class="form-row"><label for="ll-resumen">Resumen</label>
    <textarea id="ll-resumen" rows="3" maxlength="4000" placeholder="De qué se habló, en pocas líneas">${esc(v.resumen || '')}</textarea></div>
  <div class="form-grid2">
    <div class="form-row"><label for="ll-esta">En qué está</label>
      <textarea id="ll-esta" rows="3" maxlength="2000" placeholder="Dónde está el alumno hoy">${esc(v.en_que_esta || '')}</textarea></div>
    <div class="form-row"><label for="ll-pasos">Próximos pasos</label>
      <textarea id="ll-pasos" rows="3" maxlength="2000" placeholder="Qué sigue">${esc(v.proximos_pasos || '')}</textarea></div>
  </div>`;

const campoTranscripcion = (texto = '') => `
  <details class="ll-transc"${texto ? ' open' : ''}>
    <summary>Transcripción o resumen de Fathom (opcional)</summary>
    <div class="form-row"><textarea id="ll-transc" rows="9" maxlength="200000"
      placeholder="Pegá acá la transcripción o el resumen de Fathom. Solo la ve quien edita el programa.">${esc(texto)}</textarea></div>
  </details>`;

const val = id => (document.getElementById(id) ? document.getElementById(id).value : '');

export async function modalNueva(ctx, api) {
  const con106 = ctx.estado !== undefined;
  let dudas = [];
  if (con106) {
    try { dudas = (await traerDudas(ctx.p.id)) || []; } catch (e) { console.error('dudas', e); }
  }
  abrirModal({
    titulo: 'Nueva llamada', ancho: con106,
    cuerpo: `
      <div class="form-grid2">
        <div class="form-row"><label for="ll-fecha">Fecha de la llamada *</label>
          <input type="date" id="ll-fecha" value="${esc(hoyAR())}" max="${esc(hoyAR())}"></div>
        <div class="form-row"><label for="ll-titulo">Título (opcional)</label>
          <input type="text" id="ll-titulo" maxlength="120" autocomplete="off" placeholder="Ej: Revisión de embudo"></div>
      </div>
      ${con106 ? camposEstado() : ''}
      <div class="form-row"><label for="ll-acc">Accionables (uno por línea)</label>
        <textarea id="ll-acc" rows="6" maxlength="8000"
          placeholder="Pegá la lista acá. Una línea con sangría (2 espacios) es subtarea de la de arriba."></textarea></div>
      <div class="form-row"><label for="ll-links">Links de la llamada (uno por línea)</label>
        <textarea id="ll-links" rows="3" maxlength="4000"
          placeholder="https://...  o  Título | https://..."></textarea></div>
      ${con106 ? `<div class="form-row"><label for="ll-duda">Dudas que aparecieron</label>
        <div id="ll-dudas-box"></div>
        <div class="hint">Elegí una duda que ya existe o escribí una nueva: queda mencionada por este alumno en la fecha de la llamada.</div></div>
        ${campoTranscripcion()}` : ''}
      <div id="ll-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="ll-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="ll-ok">Guardar llamada</button>`
  });
  const selector = con106 ? montarSelectorDudas(document.getElementById('ll-dudas-box'), dudas, { multiple: true, id: 'll-duda' }) : null;
  document.getElementById('ll-cancelar').onclick = cerrarModal;
  document.getElementById('ll-fecha').focus();
  document.getElementById('ll-ok').onclick = () => {
    const err = t => { document.getElementById('ll-error').textContent = t; };
    const fecha = val('ll-fecha');
    if (!fecha) return err('Falta la fecha de la llamada.');
    if (fecha > hoyAR()) return err('La fecha de la llamada no puede ser futura.');
    const links = parsearLinks(val('ll-links'));
    if (links.invalidas.length) return err(`Estos links no son válidos (tienen que empezar con http:// o https://): ${links.invalidas.join(' · ')}`);
    const datos = {
      fecha, titulo: val('ll-titulo'), accionables: parsearAccionables(val('ll-acc')), links: links.items,
      atomica: con106,
      ...(con106 ? {
        resumen: val('ll-resumen'), en_que_esta: val('ll-esta'), proximos_pasos: val('ll-pasos'),
        transcripcion: val('ll-transc'), dudas: selector.valores()
      } : {})
    };
    cerrarModal();
    guardar(() => crearLlamada(ctx.p.id, ctx.c.id, datos), { ok: 'Llamada guardada.', luego: () => api.refrescar() });
  };
}

export async function modalEditarLlamada(ll, ctx, api) {
  const con106 = ctx.estado !== undefined;
  let transc = null;   // null = sin transcripción cargada
  if (con106) {
    const { data, error } = await sb.from(T_TRANSC).select('texto').eq('llamada_id', ll.id).maybeSingle();
    if (error) console.error('transcripción', error);
    transc = data ? data.texto : null;
  }
  abrirModal({
    titulo: 'Editar llamada', ancho: con106,
    cuerpo: `
      <div class="form-grid2">
        <div class="form-row"><label for="ll-fecha">Fecha *</label>
          <input type="date" id="ll-fecha" value="${esc(ll.fecha)}" max="${esc(hoyAR())}"></div>
        <div class="form-row"><label for="ll-titulo">Título</label>
          <input type="text" id="ll-titulo" maxlength="120" autocomplete="off" value="${esc(ll.titulo || '')}"></div>
      </div>
      ${con106 ? camposEstado(ll) + campoTranscripcion(transc || '') : ''}
      <div id="ll-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="ll-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="ll-ok">Guardar</button>`
  });
  document.getElementById('ll-cancelar').onclick = cerrarModal;
  document.getElementById('ll-ok').onclick = () => {
    const err = t => { document.getElementById('ll-error').textContent = t; };
    const fecha = val('ll-fecha');
    if (!fecha || fecha > hoyAR()) return err('La fecha es obligatoria y no puede ser futura.');
    const cambios = { fecha, titulo: val('ll-titulo').trim() || null };
    let transcNueva;   // undefined = no se toca
    if (con106) {
      cambios.resumen = val('ll-resumen').trim() || null;
      cambios.en_que_esta = val('ll-esta').trim() || null;
      cambios.proximos_pasos = val('ll-pasos').trim() || null;
      const t = val('ll-transc');
      if (t.trim()) transcNueva = t;
      else if (transc !== null) {
        if (!esFundador()) return err('Solo el fundador puede borrar una transcripción. Dejá algún texto o pedíselo al fundador.');
        transcNueva = '';
      }
    }
    cerrarModal();
    guardar(async () => {
      await actualizarFila('cs_llamadas', ll.id, cambios);
      if (transcNueva === undefined) return;
      const q = transcNueva === ''
        ? sb.from(T_TRANSC).delete().eq('llamada_id', ll.id)
        : sb.from(T_TRANSC).upsert(
          { llamada_id: ll.id, programa_id: ctx.p.id, cliente_id: ctx.c.id, texto: transcNueva }, { onConflict: 'llamada_id' });
      const { error } = await q;
      if (error) throw error;
    }, { luego: () => api.refrescar() });
  };
}
