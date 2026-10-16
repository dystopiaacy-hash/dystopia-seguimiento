/* "Propuestas de la IA" (139), arriba de la pestaña Dudas frecuentes.
   La IA (Haiku) agrupa por tema las preguntas detectadas en llamadas, cuenta alumnos distintos y semanas (lo calcula la
   base, no el modelo) y propone el texto de la duda y una respuesta corta; marca «falta recurso» cuando haría falta un
   video o un SOP. NADA es oficial hasta que una persona lo aprueba: «Revisar y aprobar» abre el formulario con la
   propuesta editable, «Descartar» la cierra. Lo ven y lo usan el fundador y quien edita el programa (rol producto).
   «Reagrupar con IA»: solo fundador. Corre sola 1 vez por día (10:47). Sin la 139 el bloque no se muestra. */
import { esc, fmtFecha, plural, abrirModal, cerrarModal, confirmar, toast, urlSegura } from '../ui.js';
import { esFundador, puedeEditarPrograma } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { mensajeCs } from '../datos-faltante.js';
import {
  traerPropuestas, traerPreguntasDePropuestas, aprobarPropuesta, descartarPropuesta, correrIaDudas
} from '../datos-ia-dudas.js';

/* ctx: { programaId, clientes(), recargar(), filtros } — filtros.soloRepetidas persiste entre repintados. */
export async function montarPropuestasIa(cont, ctx) {
  const { programaId } = ctx;
  if (!puedeEditarPrograma(programaId)) { cont.innerHTML = ''; return; }
  const filtros = ctx.filtros;
  let props, preguntas = [];

  const nombreAlumno = id => (ctx.clientes().find(c => c.id === id) || {}).nombre || 'Alumno';

  async function cargar() {
    const p = await traerPropuestas(programaId);
    if (!cont.isConnected) return false;
    if (p === undefined) { cont.innerHTML = ''; return false; }
    props = p;
    preguntas = await traerPreguntasDePropuestas(props.map(x => x.id));
    return cont.isConnected;
  }

  function cuando(p) {
    if (!p.primera) return '';
    const n = p.semanas_desde;
    const desde = n < 1 ? 'primera vez esta semana' : `se repite desde hace ${plural(n, 'semana')}`;
    return `${desde} (primera: ${fmtFecha(p.primera)}, última: ${fmtFecha(p.ultima)})`
      + (p.semanas_distintas > 1 ? ` · en ${p.semanas_distintas} semanas distintas` : '');
  }

  function tarjeta(p) {
    const qs = preguntas.filter(q => q.propuesta_id === p.id);
    const lista = qs.map(q => `<li><a href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(q.cliente_id)}">${esc(nombreAlumno(q.cliente_id))}</a>
      · ${esc(fmtFecha(q.fecha))} · «${esc(q.texto)}»</li>`).join('');
    return `<div class="card duda-ia" data-ia-prop="${esc(p.id)}">
      <div class="duda-texto"><strong>${esc(p.tema)}</strong></div>
      <div class="duda-tags">
        <span class="duda-tag duda-tag-racha">${esc(plural(p.alumnos, 'alumno'))} · ${esc(plural(p.preguntas, 'pregunta'))}</span>
        ${p.falta_recurso ? '<span class="duda-tag duda-tag-nueva">Falta recurso</span>' : ''}
      </div>
      <div class="hint">${esc(cuando(p))}</div>
      ${p.duda_id_destino ? `<div class="hint">Se sumaría a la duda ya cargada «${esc(p.duda_destino_texto || '')}»${p.duda_destino_respuesta ? ' (que ya tiene respuesta oficial: no se pisa)' : ''}.</div>` : ''}
      ${p.respuesta ? `<div class="duda-resp"><em>Respuesta propuesta por la IA (no oficial):</em> ${esc(p.respuesta)}</div>` : '<div class="hint">La IA no propuso respuesta.</div>'}
      ${p.falta_recurso && p.recurso_sugerido ? `<div class="duda-resp"><em>Recurso que haría falta:</em> ${esc(p.recurso_sugerido)}</div>` : ''}
      ${qs.length ? `<details class="duda-det"><summary>${esc(plural(qs.length, 'pregunta detectada', 'preguntas detectadas'))}</summary><ul>${lista}</ul></details>` : ''}
      <div class="ll-item-acc">
        <button type="button" class="btn btn-accent btn-sm" data-ia-aprobar="${esc(p.id)}">Revisar y aprobar</button>
        <button type="button" class="btn btn-sm btn-icono-danger" data-ia-descartar="${esc(p.id)}">Descartar</button>
      </div></div>`;
  }

  function visibles() {
    return props.filter(p => !filtros.soloRepetidas || p.alumnos >= 2);
  }

  function pintar() {
    const v = visibles();
    const ocultas = props.length - v.length;
    cont.innerHTML = `
      <div class="section-title">Propuestas de la IA<span class="line"></span></div>
      <p class="hint">La IA agrupa por tema las preguntas detectadas en llamadas y propone una respuesta. <strong>Nada es oficial hasta que lo aprobás</strong>:
        al aprobar se crea la duda (o se completa la que ya existe) con sus menciones. Corre sola una vez por día.</p>
      <div class="filter-row">
        <label class="check-row check-inline"><input type="checkbox" id="ia-repetidas"${filtros.soloRepetidas ? ' checked' : ''}> Solo repetidas (2 alumnos o más)</label>
        ${esFundador() ? '<button type="button" class="btn" id="ia-reagrupar">Reagrupar con IA</button>' : ''}
        <span class="hint" id="ia-progreso"></span>
      </div>
      ${v.length ? v.map(tarjeta).join('') : `<div class="card empty-state"><div class="big">No hay propuestas pendientes</div>
        <div class="small">${ocultas ? `Hay ${esc(plural(ocultas, 'propuesta'))} de un solo alumno: destildá «Solo repetidas» para verlas.`
          : 'Aparecen cuando la IA agrupa preguntas nuevas detectadas en llamadas.'}</div></div>`}
      ${v.length && ocultas ? `<div class="table-foot">${esc(plural(ocultas, 'propuesta oculta', 'propuestas ocultas'))} (de un solo alumno)</div>` : ''}`;
  }

  async function refrescar() {
    if (await cargar()) pintar();
  }

  function modalAprobar(p) {
    const nota = p.duda_id_destino && p.duda_destino_respuesta
      ? '<p class="hint">Esta duda ya existe y tiene respuesta oficial: la respuesta de acá no la reemplaza.</p>' : '';
    abrirModal({
      titulo: 'Revisar y aprobar',
      cuerpo: `<p class="hint">Lo que dejes acá pasa a ser oficial al aprobar. Editalo si hace falta.</p>${nota}
        <div class="form-row"><label for="pa-texto">Duda *</label>
          <input type="text" id="pa-texto" maxlength="300" autocomplete="off" value="${esc(p.tema)}"></div>
        <div class="form-row"><label for="pa-resp">Respuesta</label>
          <textarea id="pa-resp" rows="5" maxlength="2000">${esc(p.respuesta || '')}</textarea></div>
        <div class="form-grid2">
          <div class="form-row"><label for="pa-titulo">Título del recurso o SOP</label>
            <input type="text" id="pa-titulo" maxlength="200" autocomplete="off" placeholder="${esc(p.falta_recurso ? (p.recurso_sugerido || 'Falta un video o SOP') : '')}"></div>
          <div class="form-row"><label for="pa-url">Link del recurso o SOP</label>
            <input type="url" id="pa-url" maxlength="1000" autocomplete="off" placeholder="https://…"></div>
        </div>
        <p class="hint">Se suman ${esc(plural(p.alumnos, 'alumno'))} como menciones de esta duda.</p>
        <div id="pa-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="pa-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="pa-ok">Aprobar</button>`
    });
    document.getElementById('pa-cancelar').onclick = cerrarModal;
    document.getElementById('pa-ok').onclick = async ev => {
      const err = t => { document.getElementById('pa-error').textContent = t; };
      const d = {
        texto: document.getElementById('pa-texto').value.trim(), respuesta: document.getElementById('pa-resp').value.trim(),
        recurso_titulo: document.getElementById('pa-titulo').value.trim(), recurso_url: document.getElementById('pa-url').value.trim()
      };
      if (!d.texto) return err('El texto de la duda es obligatorio.');
      if (d.recurso_url && !urlSegura(d.recurso_url)) return err('El link tiene que empezar con http:// o https://.');
      ev.target.disabled = true;
      try {
        const r = await aprobarPropuesta(p.id, d);
        cerrarModal();
        toast(r && r.nueva ? 'Duda creada con sus menciones.' : 'Se sumaron las menciones a la duda existente.');
        await ctx.recargar();
      } catch (e) {
        ev.target.disabled = false;
        err(mensajeCs(e, mensajeError(e)));
      }
    };
  }

  cont.addEventListener('change', ev => {
    if (ev.target.id !== 'ia-repetidas') return;
    filtros.soloRepetidas = ev.target.checked;
    pintar();
  });

  cont.addEventListener('click', async ev => {
    const por = id => props.find(p => p.id === id);
    const a = ev.target.closest('[data-ia-aprobar]');
    if (a) { const p = por(a.dataset.iaAprobar); if (p) modalAprobar(p); return; }

    const d = ev.target.closest('[data-ia-descartar]');
    if (d) {
      const p = por(d.dataset.iaDescartar);
      if (!p) return;
      const ok = await confirmar({
        titulo: 'Descartar propuesta', texto: `Se descarta «${p.tema}».`,
        detalle: 'Sus preguntas quedan pendientes en «Preguntas detectadas en llamadas» y la IA no las vuelve a leer.', ok: 'Descartar'
      });
      if (!ok) return;
      try {
        await descartarPropuesta(p.id);
        toast('Propuesta descartada.');
      } catch (e) {
        toast(mensajeCs(e, mensajeError(e)), 'error');
      }
      await ctx.recargar();
      return;
    }

    const r = ev.target.closest('#ia-reagrupar');
    if (r && esFundador()) {
      const ok = await confirmar({
        titulo: 'Reagrupar con IA',
        texto: 'Se borran las propuestas pendientes y la IA vuelve a agrupar todas las preguntas pendientes de este programa.',
        detalle: 'Las dudas ya aprobadas no se tocan. Gasta unos centavos de IA.', ok: 'Reagrupar', peligro: false
      });
      if (!ok) return;
      r.disabled = true;
      const prog = cont.querySelector('#ia-progreso');
      if (prog) prog.textContent = 'La IA está agrupando…';
      try {
        const res = await correrIaDudas({ programa: programaId, reagrupar: true });
        toast(res && res.ok === false ? 'La IA no pudo terminar: probá de nuevo.'
          : `Listo: ${plural(res.propuestas_nuevas || 0, 'propuesta nueva', 'propuestas nuevas')}.`, res && res.ok === false ? 'error' : '');
      } catch (e) {
        toast(mensajeCs(e, mensajeError(e)), 'error');
      }
      await ctx.recargar();
    }
  });

  if (await cargar()) pintar();
  return { refrescar };
}
