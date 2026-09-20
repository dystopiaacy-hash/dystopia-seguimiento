/* Ficha de cliente — cabecera (quién es, semáforo, estado, etapa, contacto, chequeo)
   y bloque de tiempo (fechas, progreso, días restantes, aviso de renovación).
   Todo cambio se guarda al momento; el semáforo se repinta con el dato nuevo de
   cs_v_clientes, sin recargar la página. */
import {
  esc, fmtFecha, fmtFechaHora, plural, badge, nivelPorDias, abrirModal, cerrarModal, confirmar, toast
} from '../ui.js';
import { esFundador } from '../sesion.js';
import { navegar } from '../router.js';
import {
  actualizarFila, borrarFila, registrarChequeo, iniciarRenovacion, esVivo,
  ESTADO_LABEL, ESTADO_COLOR
} from '../datos.js';
import { num, opcionesHtml, guardar } from './comunes.js';

/* A mano solo se elige entre estos: 'en_renovacion' lo pone el trigger al iniciar una
   renovación. Si el cliente ya está en renovación, su estado actual aparece igual
   para no cambiárselo sin querer al abrir el select. */
function opcionesEstado(c) {
  const pares = Object.entries(ESTADO_LABEL)
    .filter(([v]) => v !== 'en_renovacion' || c.estado === 'en_renovacion');
  return opcionesHtml(pares, c.estado);
}

function opcionesEtapa(c, p) {
  const etapas = (Array.isArray(p.etapas) ? p.etapas : []).filter(Boolean).map(String);
  if (c.etapa && !etapas.includes(c.etapa)) etapas.push(c.etapa);
  return opcionesHtml([['', 'Sin etapa']].concat(etapas.map(e => [e, e])), c.etapa || '');
}

function motivos(c) {
  const lista = Array.isArray(c.motivos_semaforo) ? c.motivos_semaforo : [];
  if (!lista.length) return '<li class="ok">Sin alertas: al día.</li>';
  return lista.map(m => `<li>${esc(m)}</li>`).join('');
}

function datosContacto(c) {
  const email = c.email
    ? `<a href="mailto:${esc(c.email)}">${esc(c.email)}</a>`
    : '<span class="txt-gris">Sin email</span>';
  const tel = c.telefono ? esc(c.telefono) : '<span class="txt-gris">Sin teléfono</span>';
  return `${email} · ${tel}`;
}

function chequeoTexto(c, p) {
  if (!c.ultimo_chequeo_at) return '<span class="txt-gris">Nunca se registró un chequeo</span>';
  const d = num(c.dias_sin_chequeo);
  const tarde = esVivo(c) && d > num(p.dias_sin_chequeo_alerta);
  const cuando = d === 0 ? 'hoy' : `hace ${plural(d, 'día')}`;
  return `<span class="${tarde ? 'txt-amarillo' : 'txt-gris'}">Último chequeo: ${esc(fmtFechaHora(c.ultimo_chequeo_at))} (${esc(cuando)})</span>`;
}

/* ---------- Bloque de tiempo ---------- */

function avisoRenovacion(c, p, renovaciones) {
  const enProceso = (renovaciones || []).some(r => r.estado === 'en_proceso');
  const d = c.dias_restantes == null ? null : num(c.dias_restantes);
  if (enProceso) {
    return '<div class="banner banner-amarillo">Renovación en proceso. Se cierra (renovó / no renovó) abajo, en Renovaciones.</div>';
  }
  if (['finalizado', 'baja'].includes(c.estado) || d == null || d > num(p.aviso_renovacion_dias)) return '';
  const txt = d < 0
    ? `El programa venció hace ${plural(-d, 'día')} y no hay renovación iniciada.`
    : `Quedan ${plural(d, 'día')} de programa (el aviso del programa es a ${plural(num(p.aviso_renovacion_dias), 'día')}).`;
  return `
    <div class="banner banner-rojo">
      <span>${esc(txt)}</span>
      <button type="button" class="btn btn-sm btn-accent" data-accion="iniciar-renovacion">Iniciar proceso de renovación</button>
    </div>`;
}

function bloqueTiempo(ctx) {
  const { c, p, renovaciones } = ctx;
  const pct = Math.max(0, Math.min(100, num(c.pct_programa)));
  const d = c.dias_restantes == null ? null : num(c.dias_restantes);
  const nivel = nivelPorDias(d, { amarillo: num(p.aviso_renovacion_dias), rojo: -1 });
  return `
    <div class="card ficha-tiempo">
      <div class="tiempo-grid">
        <div>
          <div class="field-label">Inicio</div>
          <div class="tiempo-fecha">${esc(fmtFecha(c.fecha_inicio))}</div>
        </div>
        <div class="form-row tiempo-fin">
          <label for="f-fecha-fin">Fin</label>
          <input type="date" id="f-fecha-fin" data-campo="fecha_fin" value="${esc(c.fecha_fin || '')}"
            min="${esc(c.fecha_inicio || '')}">
        </div>
        <div class="tiempo-barra">
          <div class="field-label">Avance del programa</div>
          <span class="prog-track"><span class="prog-fill prog-${esc(nivel)}" style="width:${pct}%"></span></span>
          <div class="hint">${pct}% · ${esc(plural(num(c.dias_transcurridos), 'día'))} desde el inicio${c.renovaciones_count ? ' · ' + esc(plural(num(c.renovaciones_count), 'renovación', 'renovaciones')) : ''}</div>
        </div>
        <div class="tiempo-dias">
          <div class="stat-num sem-txt-${esc(nivel)}">${d == null ? '—' : esc(String(Math.abs(d)))}</div>
          <div class="stat-label">${d == null ? 'Sin fecha de fin' : d < 0 ? 'días vencido' : 'días restantes'}</div>
        </div>
      </div>
      ${avisoRenovacion(c, p, renovaciones)}
    </div>`;
}

/* ---------- Cabecera ---------- */

function textoSemaforo(s) {
  return s === 'rojo' ? 'Hay que actuar' : s === 'amarillo' ? 'Mirar pronto' : 'Al día';
}

function colorSemaforo(s) {
  return s === 'rojo' ? 'var(--sem-rojo)' : s === 'amarillo' ? 'var(--sem-amarillo)' : 'var(--sem-verde)';
}

export function html(ctx) {
  const { c, p } = ctx;
  return `
    <div class="card ficha-head">
      <div class="ficha-head-top">
        <div class="ficha-ident">
          <h2 class="ficha-nombre">${esc(c.nombre)}</h2>
          <div class="ficha-contacto">${datosContacto(c)}</div>
          <div class="ficha-chequeo">${chequeoTexto(c, p)}</div>
        </div>
        <div class="ficha-sem">
          ${badge(textoSemaforo(c.semaforo), colorSemaforo(c.semaforo), 'status')}
          <ul class="ficha-motivos">${motivos(c)}</ul>
        </div>
      </div>
      <div class="ficha-campos">
        <div class="form-row">
          <label for="f-estado">Estado</label>
          <select id="f-estado" data-campo="estado">${opcionesEstado(c)}</select>
        </div>
        <div class="form-row">
          <label for="f-etapa">Etapa</label>
          <select id="f-etapa" data-campo="etapa">${opcionesEtapa(c, p)}</select>
        </div>
        <div class="form-row">
          <label for="f-responsable">Responsable</label>
          <input type="text" id="f-responsable" data-campo="responsable" maxlength="80"
            value="${esc(c.responsable || '')}" placeholder="Sin asignar" autocomplete="off">
        </div>
        <div class="form-row">
          <label for="f-plan">Plan</label>
          <input type="text" id="f-plan" data-campo="plan" maxlength="80"
            value="${esc(c.plan || '')}" placeholder="Sin plan" autocomplete="off">
        </div>
      </div>
      <div class="ficha-acciones">
        <button type="button" class="btn btn-accent btn-sm" data-accion="chequeo">Registrar chequeo</button>
        <button type="button" class="btn btn-sm" data-accion="editar-datos">Editar datos de contacto</button>
        ${esFundador() ? '<button type="button" class="btn btn-sm btn-danger" data-accion="borrar-cliente">Borrar cliente</button>' : ''}
        <span class="ficha-estado-badge">${badge(ESTADO_LABEL[c.estado] || c.estado, ESTADO_COLOR[c.estado], 'status')}</span>
      </div>
    </div>
    ${bloqueTiempo(ctx)}`;
}

/* ---------- Acciones ---------- */

function conectarCancelar() {
  const b = document.querySelector('[data-cerrar="1"]');
  if (b) b.onclick = cerrarModal;
}

function modalChequeo(ctx, api) {
  abrirModal({
    titulo: 'Registrar chequeo',
    cuerpo: `
      <p class="aviso-texto">Queda registrado que hoy se revisó a <strong>${esc(ctx.c.nombre)}</strong>.</p>
      <div class="form-row">
        <label for="chq-nota">Nota (opcional)</label>
        <textarea id="chq-nota" maxlength="1000" placeholder="Qué se habló o qué quedó pendiente"></textarea>
      </div>`,
    pie: `<button type="button" class="btn" data-cerrar="1">Cancelar</button>
          <button type="button" class="btn btn-accent" id="chq-ok">Registrar</button>`
  });
  conectarCancelar();
  const nota = document.getElementById('chq-nota');
  nota.focus();
  document.getElementById('chq-ok').onclick = () => {
    const texto = nota.value;
    cerrarModal();
    guardar(() => registrarChequeo(ctx.c, texto), { ok: 'Chequeo registrado.', luego: () => api.refrescar() });
  };
}

function modalDatos(ctx, api) {
  const c = ctx.c;
  abrirModal({
    titulo: 'Editar datos de contacto',
    cuerpo: `
      <div class="form-row"><label for="d-nombre">Nombre *</label>
        <input type="text" id="d-nombre" maxlength="120" value="${esc(c.nombre)}" autocomplete="off"></div>
      <div class="form-grid2">
        <div class="form-row"><label for="d-email">Email</label>
          <input type="email" id="d-email" maxlength="160" value="${esc(c.email || '')}" autocomplete="off"></div>
        <div class="form-row"><label for="d-tel">Teléfono</label>
          <input type="tel" id="d-tel" maxlength="40" value="${esc(c.telefono || '')}" autocomplete="off"></div>
      </div>
      <div class="hint">Solo nombre, email y teléfono: ningún dato financiero del cliente va a la base.</div>
      <div id="d-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" data-cerrar="1">Cancelar</button>
          <button type="button" class="btn btn-accent" id="d-ok">Guardar</button>`
  });
  conectarCancelar();
  document.getElementById('d-nombre').focus();
  document.getElementById('d-ok').onclick = () => {
    const nombre = document.getElementById('d-nombre').value.trim();
    const email = document.getElementById('d-email').value.trim();
    const telefono = document.getElementById('d-tel').value.trim();
    const errEl = document.getElementById('d-error');
    if (!nombre) { errEl.textContent = 'El nombre es obligatorio.'; return; }
    if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      errEl.textContent = 'El email no tiene un formato válido.';
      return;
    }
    cerrarModal();
    guardar(() => actualizarFila('cs_clientes', c.id, {
      nombre, email: email || null, telefono: telefono || null
    }), { ok: 'Datos guardados.', luego: () => api.refrescar() });
  };
}

export async function manejar(ev, ctx, api) {
  const c = ctx.c;

  if (ev.type === 'change') {
    const campo = ev.target.closest('[data-campo]');
    if (!campo) return false;
    const nombre = campo.dataset.campo;
    let valor = campo.value;
    if (nombre === 'fecha_fin') {
      if (!valor) { toast('El programa necesita una fecha de fin.', 'error'); await api.refrescar(); return true; }
      if (c.fecha_inicio && valor < c.fecha_inicio) {
        toast('La fecha de fin no puede ser anterior al inicio.', 'error');
        await api.refrescar();
        return true;
      }
    }
    if (nombre !== 'estado' && nombre !== 'fecha_fin') valor = valor.trim() || null;
    await guardar(() => actualizarFila('cs_clientes', c.id, { [nombre]: valor }), {
      ok: 'Guardado.', luego: () => api.refrescar(), control: campo
    });
    return true;
  }

  const btn = ev.target.closest('[data-accion]');
  if (!btn) return false;
  const accion = btn.dataset.accion;

  if (accion === 'chequeo') { modalChequeo(ctx, api); return true; }
  if (accion === 'editar-datos') { modalDatos(ctx, api); return true; }

  if (accion === 'iniciar-renovacion') {
    const ok = await confirmar({
      titulo: 'Iniciar proceso de renovación',
      texto: `Se abre una renovación en proceso para ${c.nombre}.`,
      detalle: 'El cliente pasa a estado "En renovación" hasta que la cierres.',
      ok: 'Iniciar', peligro: false
    });
    if (!ok) return true;
    await guardar(() => iniciarRenovacion(c), {
      ok: 'Renovación iniciada.', luego: () => api.refrescar(), control: btn
    });
    return true;
  }

  if (accion === 'borrar-cliente') {
    const ok = await confirmar({
      titulo: 'Borrar cliente',
      texto: `Se borra ${c.nombre} y todo lo que cuelga de él.`,
      detalle: 'Accionables, devoluciones, calls, renovaciones y chequeos se borran con el cliente. No se puede deshacer.',
      ok: 'Borrar'
    });
    if (!ok) return true;
    await guardar(() => borrarFila('cs_clientes', c.id), {
      ok: 'Cliente borrado.',
      luego: () => navegar('p/' + encodeURIComponent(ctx.p.id) + '/clientes')
    });
    return true;
  }
  return false;
}
