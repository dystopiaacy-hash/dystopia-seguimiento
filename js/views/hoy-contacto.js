/* Panel lateral "Registrar contacto" de la pantalla Hoy (069).
   Canal y resultado como chips, resumen opcional y próximo contacto. Guarda con
   cs_registrar_contacto: el resultado mueve el pipeline de resell en la misma llamada.
   "No renueva" cierra la renovación, así que pide confirmación adentro del panel. */
import { esc, hoyAR, sumarDias, fmtFecha, toast } from '../ui.js';
import { CANAL_LABEL, registrarContacto, mensajeError } from '../datos.js';

export const RESULTADO_LABEL = {
  contesto: 'Contestó', no_contesta: 'No contesta', interesado: 'Interesado',
  call_agendada: 'Call agendada', no_renueva: 'No renueva'
};

const PROXIMOS = [['3', '+3 días'], ['7', '+7 días'], ['14', '+14 días'], ['fecha', 'Fecha'], ['ninguno', 'Sin próximo']];

let actual = null;   // { el, cerrar }

export function hayPanelContacto() {
  return !!actual;
}

export function cerrarPanelContacto() {
  if (actual) actual.cerrar();
}

function chips(grupo, pares, valor) {
  return `<div class="hoy-chips" role="group">${pares.map(([v, label]) =>
    `<button type="button" class="hoy-chip${v === valor ? ' on' : ''}" data-grupo="${grupo}" data-valor="${esc(v)}"
      aria-pressed="${v === valor}">${esc(label)}</button>`).join('')}</div>`;
}

/* tarea = fila de cs_cola_hoy (usa cliente_id, cliente y titulo).
   alGuardar(resultado de la rpc) corre después de guardar bien, con el panel ya cerrado. */
export function abrirPanelContacto(tarea, alGuardar) {
  cerrarPanelContacto();
  const s = { canal: 'whatsapp', resultado: '', proximo: '7', confirmando: false, enVuelo: false };

  const el = document.createElement('aside');
  el.className = 'hoy-panel';
  el.setAttribute('role', 'dialog');
  el.setAttribute('aria-label', 'Registrar contacto');
  el.innerHTML = `
    <div class="hoy-panel-head">
      <div>
        <h2>Registrar contacto</h2>
        <div class="hoy-panel-sub">${esc(tarea.cliente || '')}${tarea.titulo ? ' · ' + esc(tarea.titulo) : ''}</div>
      </div>
      <button type="button" class="modal-close" data-cerrar aria-label="Cerrar">✕</button>
    </div>
    <div class="hoy-panel-body">
      <div class="field-label">Canal</div>
      ${chips('canal', Object.entries(CANAL_LABEL), s.canal)}
      <div class="field-label">Resultado</div>
      ${chips('resultado', Object.entries(RESULTADO_LABEL), s.resultado)}
      <div class="form-row">
        <label for="hc-resumen">Resumen (opcional)</label>
        <input type="text" id="hc-resumen" maxlength="240" autocomplete="off" placeholder="Qué pasó, en una línea">
      </div>
      <div class="field-label">Próximo contacto</div>
      ${chips('proximo', PROXIMOS, s.proximo)}
      <div class="form-row" id="hc-fecha-row" hidden>
        <label for="hc-fecha">Fecha</label>
        <input type="date" id="hc-fecha" min="${esc(hoyAR())}">
      </div>
      <div class="hoy-panel-prox" id="hc-prox"></div>
      <div class="hoy-confirma" id="hc-confirma" hidden>
        <strong>¿Cerrar como no renovado?</strong>
        <span>La renovación queda en "No renovó", con el resumen como motivo.</span>
      </div>
    </div>
    <div class="hoy-panel-foot">
      <button type="button" class="btn btn-ghost" data-cancelar>Cancelar</button>
      <button type="button" class="btn btn-accent" data-guardar>Guardar</button>
    </div>`;

  const $ = sel => el.querySelector(sel);
  const btnGuardar = $('[data-guardar]');
  const btnCancelar = $('[data-cancelar]');

  function fechaProximo() {
    if (s.proximo === 'ninguno') return null;
    if (s.proximo === 'fecha') return $('#hc-fecha').value || '';
    return sumarDias(hoyAR(), Number(s.proximo));
  }

  function pintarEstado() {
    for (const b of el.querySelectorAll('.hoy-chip')) {
      const on = s[b.dataset.grupo] === b.dataset.valor;
      b.classList.toggle('on', on);
      b.setAttribute('aria-pressed', String(on));
    }
    $('#hc-fecha-row').hidden = s.proximo !== 'fecha';
    const f = fechaProximo();
    $('#hc-prox').textContent = f ? `Próximo contacto: ${fmtFecha(f)}` : (f === null ? 'Sin próximo contacto.' : '');
    $('#hc-confirma').hidden = !s.confirmando;
    btnGuardar.textContent = s.enVuelo ? 'Guardando…' : (s.confirmando ? 'Sí, no renueva' : 'Guardar');
    btnGuardar.classList.toggle('btn-danger', s.confirmando);
    btnGuardar.classList.toggle('btn-accent', !s.confirmando);
    btnCancelar.textContent = s.confirmando ? 'Volver' : 'Cancelar';
    btnGuardar.disabled = btnCancelar.disabled = s.enVuelo;
  }

  function cerrar() {
    if (!el.isConnected) return;
    el.remove();
    document.removeEventListener('keydown', onKey);
    window.removeEventListener('hashchange', cerrar);
    if (actual && actual.el === el) actual = null;
  }

  function onKey(ev) {
    if (ev.key !== 'Escape' || s.enVuelo) return;
    ev.preventDefault();
    if (s.confirmando) { s.confirmando = false; pintarEstado(); } else cerrar();
  }

  async function guardar() {
    if (s.enVuelo) return;
    if (!s.resultado) { toast('Elegí el resultado del contacto.', 'error'); return; }
    const proximo = fechaProximo();
    if (proximo === '') { toast('Elegí la fecha del próximo contacto.', 'error'); return; }
    if (s.resultado === 'no_renueva' && !s.confirmando) { s.confirmando = true; pintarEstado(); return; }

    s.enVuelo = true;
    pintarEstado();
    try {
      const r = await registrarContacto(tarea.cliente_id, {
        canal: s.canal, resultado: s.resultado, resumen: $('#hc-resumen').value, proximo
      });
      toast('Contacto registrado.');
      cerrar();
      if (alGuardar) await alGuardar(r);
    } catch (e) {
      toast(mensajeError(e), 'error');
      s.enVuelo = false;
      s.confirmando = false;
      if (el.isConnected) pintarEstado();
    }
  }

  el.addEventListener('click', ev => {
    if (s.enVuelo) return;
    const chip = ev.target.closest('.hoy-chip');
    if (chip) {
      s[chip.dataset.grupo] = chip.dataset.valor;
      s.confirmando = false;
      /* Un "no renueva" casi nunca lleva próximo contacto: se saca, y se puede volver a poner. */
      if (chip.dataset.grupo === 'resultado' && s.resultado === 'no_renueva') s.proximo = 'ninguno';
      pintarEstado();
      if (s.proximo === 'fecha' && chip.dataset.grupo === 'proximo') $('#hc-fecha').focus();
      return;
    }
    if (ev.target.closest('[data-cerrar]')) return cerrar();
    if (ev.target.closest('[data-cancelar]')) {
      if (s.confirmando) { s.confirmando = false; pintarEstado(); } else cerrar();
      return;
    }
    if (ev.target.closest('[data-guardar]')) guardar();
  });
  el.addEventListener('change', ev => { if (ev.target.id === 'hc-fecha') pintarEstado(); });
  el.addEventListener('keydown', ev => {
    if (ev.key === 'Enter' && ev.target.id === 'hc-resumen') { ev.preventDefault(); guardar(); }
  });

  document.addEventListener('keydown', onKey);
  window.addEventListener('hashchange', cerrar);
  document.body.appendChild(el);
  actual = { el, cerrar };
  pintarEstado();
  const primero = el.querySelector('.hoy-chip[data-grupo="resultado"]');
  if (primero) primero.focus();
  return actual;
}
