/* Configuración — Fathom (122): programas a los que se asignan las llamadas, interruptor de la
   sincronización automática (2 veces por día), botón "Sincronizar Fathom ahora" y resultado de la
   última corrida. Es una sola configuración para todos los programas (cs_fathom_config).
   Solo fundador; la base lo exige igual. La API key de Fathom NO se carga acá: es un secreto de
   la Edge Function fathom-sync. Sin la 122 el bloque avisa que falta la migración. */
import { esc, fmtFechaHora, plural, toast } from '../ui.js';
import { yo, esFundador } from '../sesion.js';
import { mensajeError } from '../datos.js';
import {
  traerConfigFathom, guardarConfigFathom, traerUltimaCorrida, sincronizarFathom
} from '../datos-fathom.js';

const ESTADO_TXT = {
  ok: 'OK', parcial: 'Parcial (se cortó por tiempo)', con_errores: 'Con errores', error: 'Error',
  en_curso: 'En curso', sin_secretos: 'No corrió: faltan secretos en Vault'
};

export const htmlFathom = () => `
  <div class="conf-seccion">
    <div class="section-title">Llamadas de Fathom<span class="line"></span></div>
    <div class="card" id="cf-fathom"><div class="loading-inline">Cargando…</div></div>
  </div>`;

function resumenCorrida(c) {
  if (!c) return '<div class="hint">Todavía no hubo ninguna corrida.</div>';
  const det = [
    c.traidas != null ? `${plural(c.traidas, 'reunión traída', 'reuniones traídas')}` : '',
    `${c.asignadas || 0} asignadas (${c.creadas || 0} nuevas, ${c.actualizadas || 0} ya estaban, ${c.vinculadas || 0} vinculadas a una carga manual)`,
    `${c.sin_asignar || 0} sin asignar`, `${c.ignoradas || 0} internas ignoradas`,
    c.errores ? `${plural(c.errores, 'error', 'errores')}` : ''
  ].filter(Boolean).join(' · ');
  return `<div class="hint"><strong>Última corrida:</strong> ${esc(fmtFechaHora(c.inicio))}
      · ${esc(ESTADO_TXT[c.estado] || c.estado)} · ${esc(c.origen === 'manual' ? 'a mano' : 'automática')}</div>
    <div class="hint">${esc(det)}</div>
    ${c.detalle ? `<pre class="hint cf-fathom-detalle">${esc(c.detalle)}</pre>` : ''}`;
}

export async function montarFathom(box, vigente) {
  if (!box) return;
  if (!esFundador()) { box.innerHTML = '<div class="hint">Solo el fundador configura Fathom.</div>'; return; }

  async function pintar() {
    let cfg, corrida;
    try {
      cfg = await traerConfigFathom();
      corrida = cfg ? await traerUltimaCorrida() : null;
    } catch (e) {
      if (vigente() && box.isConnected) box.innerHTML = `<div class="hint">${esc(mensajeError(e))}</div>`;
      return;
    }
    if (!vigente() || !box.isConnected) return;
    if (cfg === undefined) {
      box.innerHTML = '<div class="hint">Falta correr la migración 122 para configurar Fathom.</div>';
      return;
    }
    const activos = new Set(cfg.programas || []);
    box.innerHTML = `
      <div class="hint">Las llamadas se traen de la cuenta de Fathom de Joaquín (secreto <code>FATHOM_API_KEY</code> de la
        función <code>fathom-sync</code>) y se asignan al alumno por el mail de un invitado externo, solo entre los
        programas marcados acá. Las reuniones con invitados externos que no coinciden van a «Llamadas sin asignar».</div>
      <div class="form-row"><label>Programas habilitados</label>
        <div class="canal-opciones">${yo.programas.map(p => `
          <label class="check-row"><input type="checkbox" data-fx-prog="${esc(p.id)}"${activos.has(p.id) ? ' checked' : ''}>
            ${esc(p.nombre)}</label>`).join('')}</div></div>
      <label class="check-row"><input type="checkbox" id="fx-cron"${cfg.cron_activo ? ' checked' : ''}>
        Sincronización automática (2 veces por día: 10:07 y 19:07). Necesita los secretos <code>fathom_sync_url</code> e
        <code>ig_sync_service_key</code> en Vault.</label>
      <div>
        <button type="button" class="btn btn-accent btn-sm" id="fx-guardar">Guardar</button>
        <button type="button" class="btn btn-sm" id="fx-ahora">Sincronizar Fathom ahora</button>
        <span class="hint" id="fx-estado"></span>
      </div>
      ${resumenCorrida(corrida)}`;

    box.querySelector('#fx-guardar').onclick = async ev => {
      const btn = ev.currentTarget;
      const programas = [...box.querySelectorAll('[data-fx-prog]:checked')].map(i => i.dataset.fxProg);
      if (!programas.length) { toast('Habilitá al menos un programa.', 'error'); return; }
      btn.disabled = true;
      try {
        await guardarConfigFathom({ programas, cron_activo: box.querySelector('#fx-cron').checked });
        toast('Fathom guardado.');
        await pintar();
      } catch (e) {
        toast(mensajeError(e), 'error');
        btn.disabled = false;
      }
    };

    box.querySelector('#fx-ahora').onclick = async ev => {
      const btn = ev.currentTarget;
      const estado = box.querySelector('#fx-estado');
      btn.disabled = true;
      estado.textContent = 'Sincronizando… puede tardar un par de minutos.';
      try {
        const r = await sincronizarFathom();
        toast(`Fathom: ${r.asignadas} asignadas, ${r.sin_asignar} sin asignar, ${r.errores} errores.`,
          r.errores ? 'error' : '');
      } catch (e) {
        toast(mensajeError(e), 'error');
      }
      if (box.isConnected) await pintar();
    };
  }

  await pintar();
}
