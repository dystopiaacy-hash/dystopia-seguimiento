/* Modal "Nuevo cliente". Al crear, los triggers de la base generan la call de
   onboarding y los accionables de plantilla del día 0: se muestran en el resumen.
   Con producto (039) la fecha de fin la calcula la base (inicio + duración del
   producto): acá se muestra antes de guardar y se manda fecha_fin null. */
import { esc, hoyAR, sumarDias, fmtFecha, plural, toast, abrirModal, cerrarModal } from '../ui.js';
import { crearCliente, traerGeneradoAlCrear, mensajeError, ESTADO_LABEL, ONBOARDING_LABEL } from '../datos.js';
import { traerProductos, opcionesProducto } from '../ciclo.js';

/* Un cliente nuevo arranca en onboarding o ya activo. 'en_renovacion' lo pone el
   trigger al iniciar una renovación, y 'finalizado'/'baja' cierran el ciclo: ninguno
   de los tres tiene sentido como estado inicial. */
const ESTADOS_INICIALES = ['onboarding', 'activo'];

function opciones(valores, valor) {
  return valores.map(([v, t]) =>
    `<option value="${esc(v)}"${v === valor ? ' selected' : ''}>${esc(t)}</option>`).join('');
}

function campoProducto(productos) {
  if (!productos.length) return '';
  return `
      <div class="form-row">
        <label for="c-producto">Producto</label>
        <select id="c-producto">${opciones([['', 'Sin producto (duración a mano)']]
          .concat(opcionesProducto(productos, null)), '')}</select>
      </div>`;
}

function formulario(p, productos) {
  const etapas = (Array.isArray(p.etapas) ? p.etapas : []).filter(Boolean).map(String);
  return `
      ${campoProducto(productos)}
    <form id="form-cliente" novalidate>
      <div class="form-grid2">
        <div class="form-row">
          <label for="c-nombre">Nombre *</label>
          <input type="text" id="c-nombre" required maxlength="120" autocomplete="off">
        </div>
        <div class="form-row">
          <label for="c-email">Email</label>
          <input type="email" id="c-email" maxlength="160" autocomplete="off">
        </div>
      </div>
      <div class="form-grid2">
        <div class="form-row">
          <label for="c-telefono">Teléfono</label>
          <input type="tel" id="c-telefono" maxlength="40" autocomplete="off">
        </div>
        <div class="form-row">
          <label for="c-responsable">Responsable</label>
          <input type="text" id="c-responsable" maxlength="80" autocomplete="off" placeholder="Quién lo sigue en el equipo">
        </div>
      </div>
      <div class="form-grid2">
        <div class="form-row">
          <label for="c-inicio">Fecha de inicio</label>
          <input type="date" id="c-inicio" value="${esc(hoyAR())}">
        </div>
        <div class="form-row">
          <label for="c-duracion">Duración (días)</label>
          <input type="number" id="c-duracion" min="1" max="3650" step="1" value="${esc(String(p.duracion_default_dias))}">
          <div class="hint" id="c-fin"></div>
        </div>
      </div>
      <div class="form-grid2">
        <div class="form-row">
          <label for="c-etapa">Etapa inicial</label>
          <select id="c-etapa">${opciones([['', 'Sin etapa']].concat(etapas.map(e => [e, e])), etapas[0] || '')}</select>
        </div>
        <div class="form-row">
          <label for="c-estado">Estado inicial</label>
          <select id="c-estado">${opciones(ESTADOS_INICIALES.map(v => [v, ESTADO_LABEL[v]]), 'onboarding')}</select>
          <div class="hint">En "Onboarding" se crea la call de onboarding pendiente de agendar.
            "En renovación" no se elige a mano: lo pone el sistema al iniciar una renovación.</div>
        </div>
      </div>
      ${productos.length ? '' : `<div class="form-row">
        <label for="c-plan">Plan</label>
        <input type="text" id="c-plan" maxlength="80" autocomplete="off" placeholder="Nombre del plan contratado">
      </div>`}
      <div id="c-error" class="login-error"></div>
    </form>`;
}

function resumenCreado(p, cliente, generado) {
  const call = generado.calls.find(c => c.tipo === 'onboarding');
  const acc = generado.accionables;
  const base = '#/p/' + encodeURIComponent(p.id);
  return `
    <p class="aviso-texto"><strong>${esc(cliente.nombre)}</strong> quedó creado del
      ${esc(fmtFecha(cliente.fecha_inicio))} al ${esc(fmtFecha(cliente.fecha_fin))}.</p>
    <div class="subhead">Lo que se generó solo</div>
    <ul class="list-clean">
      <li>${call
        ? `Call de onboarding: ${esc(ONBOARDING_LABEL[call.estado] || call.estado)}`
        : 'Sin call de onboarding (el cliente no arranca en onboarding)'}</li>
      <li>${acc.length
        ? `${esc(plural(acc.length, 'accionable'))} de plantilla`
        : 'Sin accionables de plantilla para el día 0'}</li>
    </ul>
    ${acc.length ? `<ul class="list-clean">${acc.map(a =>
      `<li>${esc(a.titulo)} <span class="txt-gris">(${esc(a.responsable === 'bpf' ? 'BPF' : 'Cliente')}${a.vence ? ' · vence ' + esc(fmtFecha(a.vence)) : ''})</span></li>`).join('')}</ul>` : ''}
    <div class="aviso-acciones">
      <a class="btn btn-accent" href="${base}/c/${encodeURIComponent(cliente.id)}">Ir a la ficha</a>
    </div>`;
}

function valor(id) {
  const e = document.getElementById(id);
  return e ? e.value.trim() : '';
}

export async function abrirModalNuevoCliente(p, alCrear) {
  /* Sin catálogo (o si falla la lectura) el alta sigue como antes: duración a mano. */
  let productos = [];
  try { productos = await traerProductos(p.id); } catch (e) { console.error('productos', e); }
  abrirModal({
    titulo: 'Nuevo cliente',
    cuerpo: formulario(p, productos),
    pie: `<button type="button" class="btn" id="c-cancelar">Cancelar</button>
          <button type="submit" form="form-cliente" class="btn btn-accent" id="c-guardar">Crear cliente</button>`
  });

  const inicio = document.getElementById('c-inicio');
  const duracion = document.getElementById('c-duracion');
  const fin = document.getElementById('c-fin');
  const errEl = document.getElementById('c-error');
  const selProducto = document.getElementById('c-producto');
  const producto = () => (selProducto ? productos.find(x => x.id === selProducto.value) || null : null);

  function pintarFin() {
    const pr = producto();
    if (pr) duracion.value = String(pr.duracion_dias);
    duracion.disabled = !!pr;
    const d = parseInt(duracion.value, 10);
    const f = inicio.value && d > 0 ? sumarDias(inicio.value, d) : '';
    fin.textContent = !f ? 'Poné una fecha de inicio y una duración.'
      : pr ? `Termina el ${fmtFecha(f)} (${pr.nombre}: ${d} días)` : `Termina el ${fmtFecha(f)}`;
  }
  inicio.addEventListener('change', pintarFin);
  duracion.addEventListener('input', pintarFin);
  if (selProducto) selProducto.addEventListener('change', pintarFin);
  pintarFin();

  document.getElementById('c-cancelar').onclick = cerrarModal;
  document.getElementById('c-nombre').focus();

  document.getElementById('form-cliente').onsubmit = async ev => {
    ev.preventDefault();
    const btn = document.getElementById('c-guardar');
    errEl.textContent = '';

    const nombre = valor('c-nombre');
    const email = valor('c-email');
    const dias = parseInt(duracion.value, 10);
    if (!nombre) { errEl.textContent = 'El nombre es obligatorio.'; return; }
    if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { errEl.textContent = 'El email no tiene un formato válido.'; return; }
    if (!inicio.value) { errEl.textContent = 'Poné una fecha de inicio.'; return; }
    if (!(dias > 0)) { errEl.textContent = 'La duración tiene que ser mayor a 0 días.'; return; }

    btn.disabled = true;
    try {
      const cliente = await crearCliente({
        programa_id: p.id,
        nombre,
        email: email || null,
        telefono: valor('c-telefono') || null,
        fecha_inicio: inicio.value,
        producto_id: producto() ? producto().id : null,
        fecha_fin: producto() ? null : sumarDias(inicio.value, dias),
        estado: valor('c-estado') || 'onboarding',
        etapa: valor('c-etapa') || null,
        responsable: valor('c-responsable') || null,
        plan: valor('c-plan') || null
      });
      let generado = { calls: [], accionables: [] };
      try { generado = await traerGeneradoAlCrear(cliente.id); }
      catch (e) { console.error('generado', e); }
      toast('Cliente creado.');
      if (alCrear) alCrear();
      abrirModal({ titulo: 'Cliente creado', cuerpo: resumenCreado(p, cliente, generado) });
    } catch (e) {
      btn.disabled = false;
      errEl.textContent = mensajeError(e);
    }
  };
}
