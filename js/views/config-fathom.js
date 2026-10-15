/* Configuración — Fathom (122, 124): cuentas de Fathom por consultor (nombre, nombre del secreto,
   activo, última corrida y resultado de cada una), programas a los que se asignan las llamadas,
   interruptor de la sincronización automática (2 veces por día) y botón "Sincronizar Fathom ahora".
   Solo fundador; la base lo exige igual. La API key de Fathom NO se carga acá: es un secreto de la
   Edge Function fathom-sync; acá solo se ve y se elige el NOMBRE del secreto. Sin la 122/124 el
   bloque avisa que falta la migración. */
import { esc, fmtFechaHora, plural, toast } from '../ui.js';
import { yo, esFundador } from '../sesion.js';
import { mensajeError } from '../datos.js';
import {
  traerConfigFathom, guardarConfigFathom, traerUltimaCorrida, sincronizarFathom,
  traerConsultores, guardarConsultor, crearConsultor, traerLogins, guardarLogin
} from '../datos-fathom.js';

const ESTADO_TXT = {
  ok: 'OK', parcial: 'Parcial (se cortó por tiempo)', con_errores: 'Con errores', error: 'Error',
  en_curso: 'En curso', sin_secretos: 'No corrió: faltan secretos en Vault',
  sin_secreto: 'Saltada: falta el secreto en la función', clave_repetida: 'Saltada: misma key que otro consultor',
  omitido_por_tiempo: 'Saltada: se acabó el tiempo de la corrida'
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
    `${c.asignadas || 0} asignadas a un alumno (${c.creadas || 0} nuevas, ${c.actualizadas || 0} ya estaban, ${c.vinculadas || 0} vinculadas a una carga manual)`,
    `${c.sin_asignar || 0} pendientes`, `${c.ignoradas || 0} internas ignoradas`,
    c.errores ? `${plural(c.errores, 'error', 'errores')}` : ''
  ].filter(Boolean).join(' · ');
  return `<div class="hint"><strong>Última corrida:</strong> ${esc(fmtFechaHora(c.inicio))}
      · ${esc(ESTADO_TXT[c.estado] || c.estado)} · ${esc(c.origen === 'manual' ? 'a mano' : 'automática')}</div>
    <div class="hint">${esc(det)}</div>
    ${c.detalle ? `<pre class="hint cf-fathom-detalle">${esc(c.detalle)}</pre>` : ''}`;
}

/* Resultado del consultor en su última corrida (cs_fathom_consultores.ultimo_*). */
function resultadoConsultor(c) {
  if (!c.ultimo_at) return 'Todavía no corrió.';
  const r = c.ultimo_resumen || {};
  const n = [
    r.traidas != null ? plural(r.traidas, 'reunión', 'reuniones') : '',
    r.creadas || r.actualizadas || r.vinculadas ? `${(r.creadas || 0) + (r.actualizadas || 0) + (r.vinculadas || 0)} de alumnos` : '',
    r.sin_asignar ? `${r.sin_asignar} pendientes` : '',
    r.errores ? plural(r.errores, 'error', 'errores') : ''
  ].filter(Boolean).join(' · ');
  return `${ESTADO_TXT[c.ultimo_estado] || c.ultimo_estado || '—'} · ${fmtFechaHora(c.ultimo_at)}${n ? ' · ' + n : ''}`;
}

const idDe = nombre => nombre.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
  .replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 30);

export async function montarFathom(box, vigente) {
  if (!box) return;
  if (!esFundador()) { box.innerHTML = '<div class="hint">Solo el fundador configura Fathom.</div>'; return; }

  async function pintar() {
    let cfg, corrida, consultores, logins;
    try {
      cfg = await traerConfigFathom();
      consultores = cfg ? await traerConsultores() : undefined;
      corrida = cfg ? await traerUltimaCorrida() : null;
      logins = cfg ? await traerLogins() : undefined;   // undefined = falta la 126
    } catch (e) {
      if (vigente() && box.isConnected) box.innerHTML = `<div class="hint">${esc(mensajeError(e))}</div>`;
      return;
    }
    if (!vigente() || !box.isConnected) return;
    if (cfg === undefined) {
      box.innerHTML = '<div class="hint">Falta correr la migración 122 para configurar Fathom.</div>';
      return;
    }
    if (consultores === undefined) {
      box.innerHTML = '<div class="hint">Falta correr la migración 124 (Fathom por consultor).</div>';
      return;
    }
    const activos = new Set(cfg.programas || []);
    box.innerHTML = `
      <div class="hint">Cada consultor conecta SU cuenta de Fathom: la key va como secreto de la función
        <code>fathom-sync</code> (Supabase &gt; Edge Functions &gt; Secrets) con el nombre que figura abajo. Mientras el
        secreto no exista, esa cuenta se saltea sin error. Las llamadas se asignan al alumno por el mail de un invitado
        externo, solo entre los programas marcados; las que no coinciden quedan «Pendientes» en la pantalla Llamadas.</div>
      <div id="fx-consultores">${consultores.map(c => `
        <div class="cf-consultor">
          <label class="check-row"><input type="checkbox" data-fx-activo="${esc(c.id)}"${c.activo ? ' checked' : ''}>
            <strong>${esc(c.nombre)}</strong></label>
          <span class="cf-consultor-n">Secreto <code>${esc(c.secreto)}</code><br>
            <span class="hint">${esc(resultadoConsultor(c))}</span></span>
          ${logins === undefined ? '' : (() => {
            const lg = logins.find(x => x.consultor === c.id) || {};
            return `<span class="cf-consultor-n">Usuario (mail de login)
              <input type="email" data-fx-login="${esc(c.id)}" value="${esc(lg.email_login || '')}"
                placeholder="mail con el que entra a la app" maxlength="200">
              <button type="button" class="btn btn-sm" data-fx-login-ok="${esc(c.id)}">Guardar usuario</button><br>
              <span class="hint">${lg.email_login
                ? (lg.usuario_existe ? 'Usuario encontrado: ve y asigna sus llamadas.'
                  : 'Todavía no existe ese usuario: queda guardado y se activa cuando se cree.')
                : 'Sin usuario: no tiene permisos propios sobre sus llamadas.'}</span></span>`;
          })()}
        </div>`).join('') || '<div class="hint">No hay cuentas cargadas.</div>'}
        <div class="cf-consultor">
          <input type="text" id="fx-nuevo-nombre" placeholder="Nombre del consultor" maxlength="60">
          <input type="text" id="fx-nuevo-secreto" placeholder="FATHOM_API_KEY_NOMBRE" maxlength="64">
          <button type="button" class="btn btn-sm" id="fx-nuevo">Agregar cuenta</button>
        </div>
      </div>
      <div class="form-row"><label>Programas habilitados (a cuyos alumnos se asignan las llamadas)</label>
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

    box.querySelectorAll('[data-fx-activo]').forEach(chk => {
      chk.onchange = async () => {
        chk.disabled = true;
        try {
          await guardarConsultor(chk.dataset.fxActivo, { activo: chk.checked });
          toast(chk.checked ? 'Cuenta activada.' : 'Cuenta desactivada.');
        } catch (e) {
          toast(mensajeError(e), 'error');
          chk.checked = !chk.checked;
        }
        chk.disabled = false;
      };
    });

    box.querySelectorAll('[data-fx-login-ok]').forEach(btn => {
      btn.onclick = async () => {
        const id = btn.dataset.fxLoginOk;
        const inp = box.querySelector(`[data-fx-login="${id}"]`);
        btn.disabled = true;
        try {
          const existe = await guardarLogin(id, inp.value.trim());
          toast(inp.value.trim()
            ? (existe ? 'Usuario guardado.' : 'Guardado. Todavía no existe un usuario con ese mail.')
            : 'Usuario quitado.');
          await pintar();
        } catch (e) {
          toast(mensajeError(e), 'error');
          btn.disabled = false;
        }
      };
    });

    box.querySelector('#fx-nuevo').onclick = async ev => {
      const btn = ev.currentTarget;
      const nombre = box.querySelector('#fx-nuevo-nombre').value.trim();
      const secreto = box.querySelector('#fx-nuevo-secreto').value.trim().toUpperCase();
      const id = idDe(nombre);
      if (!nombre || id.length < 2) { toast('Poné el nombre del consultor.', 'error'); return; }
      if (!/^FATHOM_API_KEY(_[A-Z0-9]+)*$/.test(secreto)) {
        toast('El secreto tiene que llamarse FATHOM_API_KEY_<ALGO> (solo letras mayúsculas y números).', 'error');
        return;
      }
      btn.disabled = true;
      try {
        await crearConsultor({ id, nombre, secreto, orden: consultores.length + 1 });
        toast('Cuenta agregada. Cargá el secreto en la función para que sincronice.');
        await pintar();
      } catch (e) {
        toast(mensajeError(e), 'error');
        btn.disabled = false;
      }
    };

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
        const por = Object.values(r.consultores || {})
          .map(c => `${c.nombre}: ${ESTADO_TXT[c.estado] || c.estado}`).join(' · ');
        toast(`Fathom: ${r.asignadas} de alumnos, ${r.sin_asignar} pendientes, ${r.errores} errores. ${por}`,
          r.errores ? 'error' : '');
      } catch (e) {
        toast(mensajeError(e), 'error');
      }
      if (box.isConnected) await pintar();
    };
  }

  await pintar();
}
