/* Selección múltiple y edición masiva de clientes (Clientes y Maestro).
   NO hay camino paralelo: cada cambio se aplica alumno por alumno con las mismas
   funciones que usan la ficha y el Maestro:
     estado, etapa, responsable, producto, testimonio, fecha de fin -> guardarCampoCliente
       (datos.js: update de cs_clientes, que dispara los mismos triggers)
     resell (x_resell) -> guardarCampoExtra (datos-columnas.js, como la ficha)
   El borrado usa borrarFila('cs_clientes', id), igual que el botón de la ficha; el
   permiso real lo da la base (cs_puede_borrar). Acá además solo el fundador ve el botón.
   La selección vive en esta vista: se descarta sola al cambiar de programa o de pestaña. */
import { esc, plural, toast, abrirModal, fmtFecha } from '../ui.js';
import { esFundador, puedeEditarPrograma } from '../sesion.js';
import { guardarCampoCliente, borrarFila, mensajeError, ESTADO_LABEL } from '../datos.js';
import { guardarCampoExtra } from '../datos-columnas.js';
import { TESTIMONIO_LABEL, traerProductos, opcionesProducto } from '../ciclo.js';
import { opcionesHtml } from './comunes.js';

const SIN_ELEGIR = '__';

/* Misma regla que la ficha: en_renovacion lo pone la base y pausado va por Pausar. */
const estadosElegibles = () => Object.entries(ESTADO_LABEL)
  .filter(([v]) => !['en_renovacion', 'pausado'].includes(v));

const CAMPOS = [
  ['estado', 'Estado'], ['etapa', 'Etapa'], ['responsable', 'Responsable'], ['producto_id', 'Producto'],
  ['resell', 'Resell'], ['testimonio', 'Testimonio'], ['fecha_fin', 'Fecha de fin']
];
const etiquetaCampo = k => (CAMPOS.find(c => c[0] === k) || [k, k])[1];

/* ¿La fila ya tiene ese valor? Solo se sabe si la vista trae la columna (cs_v_clientes
   no trae producto, testimonio ni campos_extra): si no se sabe, se aplica. */
function yaTiene(f, campo, valor) {
  const norm = v => (v == null ? '' : String(v));
  if (campo === 'resell') {
    if (!('campos_extra' in f)) return false;
    return !!(f.campos_extra && f.campos_extra.x_resell === true) === valor;
  }
  if (!(campo in f)) return false;
  if (campo === 'testimonio') return (f.testimonio || 'sin_pedir') === valor;
  return norm(f[campo]) === norm(valor);
}

export function crearSeleccion({ el, programaId, prog, filas, recargar }) {
  const ids = new Set();
  let visibles = [];           // ids de lo que muestra la tabla ahora (filtros y búsqueda aplicados)
  let productos = null;        // se piden la primera vez que se elige Producto
  let ocupado = false;
  const est = { campo: '', valor: SIN_ELEGIR, sinResp: false };

  const activo = () => puedeEditarPrograma(programaId);
  const porId = () => new Map((filas() || []).map(f => [f.id, f]));

  /* ---------- Piezas para la tabla (las pinta quien la dibuja) ---------- */

  const thHtml = () => !activo() ? '' : `<th class="sel-th" scope="col">
      <input type="checkbox" data-sel-todos aria-label="Seleccionar todos los filtrados"
        title="Seleccionar todos los filtrados"></th>`;

  const tdHtml = f => !activo() ? '' : `<td class="sel-td" data-label="Seleccionar">
      <input type="checkbox" data-sel-fila="${esc(f.id)}"${ids.has(f.id) ? ' checked' : ''}
        aria-label="${esc('Seleccionar a ' + (f.nombre || ''))}"></td>`;

  const contenedorHtml = () => (activo() ? '<div id="sel-barra"></div>' : '');

  function sincronizar() {
    const todos = el.querySelector('[data-sel-todos]');
    if (!todos) return;
    const marcados = visibles.filter(id => ids.has(id)).length;
    todos.checked = visibles.length > 0 && marcados === visibles.length;
    todos.indeterminate = marcados > 0 && marcados < visibles.length;
  }

  /* La tabla se acaba de pintar con estas filas (ya filtradas). */
  function alPintar(filasVisibles) {
    visibles = filasVisibles.map(f => f.id);
    sincronizar();
    const fuera = el.querySelector('#sel-fuera');
    if (fuera) fuera.textContent = textoFuera();
  }

  function textoFuera() {
    const n = [...ids].filter(id => !visibles.includes(id)).length;
    return n ? ` · ${n} fuera del filtro actual` : '';
  }

  /* Datos nuevos: lo que ya no existe sale de la selección. */
  function alRecargar(nuevas) {
    const vivos = new Set((nuevas || []).map(f => f.id));
    let cambio = false;
    for (const id of [...ids]) if (!vivos.has(id)) { ids.delete(id); cambio = true; }
    if (cambio) pintarBarra();
  }

  /* ---------- Barra ---------- */

  function controlValor() {
    const p = prog() || {};
    const sel = (pares, conPlaceholder) => `<select id="sel-valor" aria-label="Valor nuevo">
        ${conPlaceholder ? `<option value="${SIN_ELEGIR}">Elegí un valor…</option>` : ''}${opcionesHtml(pares, est.valor)}</select>`;
    switch (est.campo) {
      case 'estado': return sel(estadosElegibles(), true);
      case 'etapa': {
        const et = (Array.isArray(p.etapas) ? p.etapas : []).filter(Boolean).map(String);
        return sel([['', 'Sin etapa']].concat(et.map(e => [e, e])), true);
      }
      case 'producto_id': {
        if (productos === null) return '<span class="hint">Cargando productos…</span>';
        return sel([['', 'Sin producto']].concat(opcionesProducto(productos, '')), true);
      }
      case 'testimonio': return sel(Object.entries(TESTIMONIO_LABEL), true);
      case 'resell': return sel([['si', 'Marcar como Resell'], ['no', 'Quitar la marca de Resell']], true);
      case 'fecha_fin': return `<input type="date" id="sel-valor" value="${esc(est.valor === SIN_ELEGIR ? '' : est.valor)}" aria-label="Fecha de fin">`;
      case 'responsable': {
        const nombres = Array.from(new Set((filas() || []).map(f => (f.responsable || '').trim()).filter(Boolean)))
          .sort((a, b) => a.localeCompare(b, 'es'));
        return `<input type="text" id="sel-valor" maxlength="80" autocomplete="off" list="sel-resp-lista"
            placeholder="Nombre del responsable" value="${esc(est.valor === SIN_ELEGIR ? '' : est.valor)}"${est.sinResp ? ' disabled' : ''}>
          <datalist id="sel-resp-lista">${nombres.map(v => `<option value="${esc(v)}"></option>`).join('')}</datalist>
          <label class="check-row check-inline"><input type="checkbox" id="sel-sin"${est.sinResp ? ' checked' : ''}> Dejar sin asignar</label>`;
      }
      default: return '';
    }
  }

  function pintarBarra() {
    const cont = el.querySelector('#sel-barra');
    if (!cont) return;
    if (!activo() || !ids.size) { cont.innerHTML = ''; return; }
    cont.innerHTML = `
      <div class="card sel-barra" role="region" aria-label="Edición masiva">
        <div class="sel-cuenta"><strong>${esc(plural(ids.size, 'seleccionado'))}</strong><span id="sel-fuera" class="hint">${esc(textoFuera())}</span>
          <button type="button" class="btn btn-ghost btn-sm" data-sel-limpiar>Limpiar selección</button></div>
        <div class="sel-accion">
          <label class="flabel" for="sel-campo">Cambiar</label>
          <select id="sel-campo"><option value="">Elegí un campo…</option>${opcionesHtml(CAMPOS, est.campo)}</select>
          <span id="sel-valor-wrap" class="sel-valor-wrap">${controlValor()}</span>
          <button type="button" class="btn btn-accent btn-sm" id="sel-aplicar" disabled>Aplicar…</button>
          ${esFundador() ? '<button type="button" class="btn btn-danger btn-sm" data-sel-borrar>Borrar seleccionados</button>' : ''}
        </div>
      </div>`;
    actualizarBoton();
  }

  /* Devuelve { ok, valor, texto } con lo elegido en la barra. */
  function valorElegido() {
    const v = est.valor;
    const c = est.campo;
    if (!c) return { ok: false };
    if (c === 'responsable') {
      if (est.sinResp) return { ok: true, valor: null, texto: 'Sin asignar' };
      const t = (v === SIN_ELEGIR ? '' : v).trim();
      return t ? { ok: true, valor: t, texto: t } : { ok: false };
    }
    if (c === 'fecha_fin') return v !== SIN_ELEGIR && v ? { ok: true, valor: v, texto: fmtFecha(v) } : { ok: false };
    if (v === SIN_ELEGIR) return { ok: false };
    if (c === 'estado') return { ok: true, valor: v, texto: ESTADO_LABEL[v] || v };
    if (c === 'testimonio') return { ok: true, valor: v, texto: TESTIMONIO_LABEL[v] || v };
    if (c === 'resell') return { ok: true, valor: v === 'si', texto: v === 'si' ? 'Resell: marcado' : 'Resell: sin marca' };
    if (c === 'etapa') return { ok: true, valor: v || null, texto: v || 'Sin etapa' };
    if (c === 'producto_id') {
      const pr = (productos || []).find(x => x.id === v);
      return { ok: true, valor: v || null, texto: v ? (pr ? pr.nombre : v) : 'Sin producto' };
    }
    return { ok: false };
  }

  function actualizarBoton() {
    const b = el.querySelector('#sel-aplicar');
    if (b) b.disabled = ocupado || !valorElegido().ok;
  }

  function limpiar() {
    ids.clear();
    pintarBarra();
    for (const c of el.querySelectorAll('[data-sel-fila]')) c.checked = false;
    sincronizar();
  }

  /* ---------- Confirmación y aplicación ---------- */

  const listaNombres = items => `<ul class="sel-lista">${items.map(i => `<li>${esc(i.nombre || '(sin nombre)')}</li>`).join('')}</ul>`;

  function resultadoModal(titulo, hechos, fallas, verbo) {
    const cuerpo = `
      <p class="aviso-texto">${esc(verbo)} a ${esc(plural(hechos, 'alumno'))}.</p>
      ${fallas.length ? `<p class="aviso-texto">No se aplicó a ${esc(plural(fallas.length, 'alumno'))}:</p>
        <ul class="sel-lista">${fallas.map(x => `<li><strong>${esc(x.nombre || '(sin nombre)')}</strong> — ${esc(x.motivo)}</li>`).join('')}</ul>
        <p class="hint">Quedaron seleccionados para que los puedas revisar o reintentar.</p>` : ''}`;
    const m = abrirModal({ titulo, cuerpo, pie: '<button type="button" class="btn btn-accent" data-sel-cerrar>Cerrar</button>' });
    m.el.querySelector('[data-sel-cerrar]').addEventListener('click', () => m.cerrar());
  }

  /* Un alumno, con las mismas reglas que la ficha. Lanza Error si no corresponde. */
  async function aplicarUno(f, campo, valor) {
    if (campo === 'resell') return guardarCampoExtra(f.id, 'x_resell', valor);
    if (campo === 'fecha_fin') {
      if (!valor) throw new Error('El programa necesita una fecha de fin.');
      if (f.fecha_inicio && valor < f.fecha_inicio) {
        throw new Error('La fecha de fin no puede ser anterior al inicio (' + fmtFecha(f.fecha_inicio) + ').');
      }
    }
    return guardarCampoCliente(f.id, campo, valor);
  }

  async function terminar(fallas) {
    await recargar();
    ids.clear();
    for (const x of fallas) ids.add(x.id);
    const vivos = porId();
    for (const id of [...ids]) if (!vivos.has(id)) ids.delete(id);
    pintarBarra();
    for (const c of el.querySelectorAll('[data-sel-fila]')) c.checked = ids.has(c.dataset.selFila);
    sincronizar();
  }

  async function pedirAplicar() {
    const v = valorElegido();
    if (!v.ok || ocupado) return;
    const campo = est.campo;
    const mapa = porId();
    const todos = [...ids].map(id => mapa.get(id)).filter(Boolean);
    const aCambiar = todos.filter(f => !yaTiene(f, campo, v.valor));
    const iguales = todos.length - aCambiar.length;
    if (!aCambiar.length) { toast('Todos los seleccionados ya tienen ese valor.'); return; }

    const notas = [];
    if (campo === 'estado' && ['finalizado', 'baja'].includes(v.valor)) {
      notas.push('Finalizado y baja disparan el offboarding, igual que al cambiarlo uno por uno.');
    }
    if (campo === 'estado') {
      const pausados = aCambiar.filter(f => f.estado === 'pausado').length;
      if (pausados) notas.push(`${plural(pausados, 'alumno')} está${pausados === 1 ? '' : 'n'} en pausa: al elegir otro estado se reanuda.`);
    }
    if (campo === 'producto_id') notas.push('Cambiar el producto no mueve la fecha de fin: la mueve la renovación.');
    if (iguales) notas.push(`${plural(iguales, 'alumno')} ya tiene${iguales === 1 ? '' : 'n'} ese valor y se saltea${iguales === 1 ? '' : 'n'}.`);

    const m = abrirModal({
      titulo: 'Confirmar cambio masivo', ancho: true,
      cuerpo: `
        <p class="aviso-texto">Se va a cambiar <strong>${esc(etiquetaCampo(campo))}</strong> a
          <strong>${esc(v.texto)}</strong> en <strong>${esc(plural(aCambiar.length, 'alumno'))}</strong>.</p>
        ${notas.map(n => `<p class="conf-detalle">${esc(n)}</p>`).join('')}
        ${listaNombres(aCambiar)}
        <div id="sel-progreso" class="hint" role="status"></div>`,
      pie: `<button type="button" class="btn" data-sel-no>Cancelar</button>
            <button type="button" class="btn btn-accent" data-sel-si>Aplicar a ${esc(plural(aCambiar.length, 'alumno'))}</button>`
    });
    m.el.querySelector('[data-sel-no]').addEventListener('click', () => m.cerrar());
    const si = m.el.querySelector('[data-sel-si]');
    si.addEventListener('click', async () => {
      si.disabled = true;
      m.el.querySelector('[data-sel-no]').disabled = true;
      ocupado = true;
      actualizarBoton();
      const prog_ = m.el.querySelector('#sel-progreso');
      const fallas = [];
      let hechos = 0;
      for (let i = 0; i < aCambiar.length; i++) {
        const f = aCambiar[i];
        if (prog_) prog_.textContent = `Aplicando ${i + 1} de ${aCambiar.length}…`;
        try {
          await aplicarUno(f, campo, v.valor);
          hechos++;
        } catch (e) {
          fallas.push({ id: f.id, nombre: f.nombre, motivo: mensajeError(e) });
        }
      }
      try { await terminar(fallas); } catch (e) { console.error('seleccion', e); }
      ocupado = false;
      actualizarBoton();
      m.cerrar();
      if (fallas.length) resultadoModal('Cambio masivo: resultado parcial', hechos, fallas, 'Se aplicó');
      else toast(`Listo: ${etiquetaCampo(campo)} actualizado en ${plural(hechos, 'alumno')}.`);
    });
  }

  /* ---------- Borrado (solo fundador; la base lo vuelve a exigir) ---------- */

  function pedirBorrar() {
    if (!esFundador() || ocupado) return;
    const mapa = porId();
    const todos = [...ids].map(id => mapa.get(id)).filter(Boolean);
    if (!todos.length) return;
    const n = todos.length;
    const m = abrirModal({
      titulo: 'Borrar clientes seleccionados', ancho: true,
      cuerpo: `
        <p class="aviso-texto">Se borran <strong>${esc(plural(n, 'cliente'))}</strong> y todo lo que cuelga de ellos.</p>
        <p class="conf-detalle">Accionables, devoluciones, calls, renovaciones y seguimientos se borran con cada cliente. No se puede deshacer.</p>
        ${listaNombres(todos)}
        <div class="form-row"><label for="sel-conf">Para habilitar el botón, escribí la cantidad: <strong>${n}</strong></label>
          <input type="text" id="sel-conf" inputmode="numeric" autocomplete="off" placeholder="${n}"></div>
        <div id="sel-progreso" class="hint" role="status"></div>`,
      pie: `<button type="button" class="btn" data-sel-no>Cancelar</button>
            <button type="button" class="btn btn-danger" data-sel-si disabled>Borrar ${esc(plural(n, 'cliente'))}</button>`
    });
    m.el.querySelector('[data-sel-no]').addEventListener('click', () => m.cerrar());
    const si = m.el.querySelector('[data-sel-si]');
    const conf = m.el.querySelector('#sel-conf');
    conf.addEventListener('input', () => { si.disabled = ocupado || conf.value.trim() !== String(n); });
    conf.focus();
    si.addEventListener('click', async () => {
      if (!esFundador() || conf.value.trim() !== String(n)) return;
      si.disabled = true; conf.disabled = true;
      m.el.querySelector('[data-sel-no]').disabled = true;
      ocupado = true;
      actualizarBoton();
      const prog_ = m.el.querySelector('#sel-progreso');
      const fallas = [];
      for (let i = 0; i < todos.length; i++) {
        const f = todos[i];
        if (prog_) prog_.textContent = `Borrando ${i + 1} de ${todos.length}…`;
        try { await borrarFila('cs_clientes', f.id); }
        catch (e) { fallas.push({ id: f.id, nombre: f.nombre, motivo: mensajeError(e) }); }
      }
      /* Un delete que la base filtra no da error: se verifica con los datos recargados. */
      try { await recargar(); } catch (e) { console.error('seleccion', e); }
      const siguen = porId();
      for (const f of todos) {
        if (siguen.has(f.id) && !fallas.some(x => x.id === f.id)) {
          fallas.push({ id: f.id, nombre: f.nombre, motivo: 'sigue en la base (sin permiso para borrarlo).' });
        }
      }
      const hechos = todos.length - fallas.length;
      ids.clear();
      for (const x of fallas) if (siguen.has(x.id)) ids.add(x.id);
      pintarBarra();
      for (const c of el.querySelectorAll('[data-sel-fila]')) c.checked = ids.has(c.dataset.selFila);
      sincronizar();
      ocupado = false;
      m.cerrar();
      if (fallas.length) resultadoModal('Borrado: resultado parcial', hechos, fallas, 'Se borró');
      else toast(`Se ${hechos === 1 ? 'borró' : 'borraron'} ${plural(hechos, 'cliente')}.`);
    });
  }

  /* ---------- Eventos (delegados: la tabla se repinta seguido) ---------- */

  el.addEventListener('change', async ev => {
    const t = ev.target;
    if (!t || !t.closest) return;
    if (t.matches('[data-sel-fila]')) {
      if (t.checked) ids.add(t.dataset.selFila); else ids.delete(t.dataset.selFila);
      pintarBarra();
      sincronizar();
      return;
    }
    if (t.matches('[data-sel-todos]')) {
      for (const id of visibles) { if (t.checked) ids.add(id); else ids.delete(id); }
      for (const c of el.querySelectorAll('[data-sel-fila]')) c.checked = ids.has(c.dataset.selFila);
      pintarBarra();
      sincronizar();
      return;
    }
    if (t.id === 'sel-campo') {
      est.campo = t.value;
      est.valor = SIN_ELEGIR;
      est.sinResp = false;
      if (est.campo === 'producto_id' && productos === null) {
        const w = el.querySelector('#sel-valor-wrap');
        if (w) w.innerHTML = controlValor();
        try { productos = await traerProductos(programaId); }
        catch (e) { productos = []; toast(mensajeError(e), 'error'); }
      }
      const w = el.querySelector('#sel-valor-wrap');
      if (w) w.innerHTML = controlValor();
      actualizarBoton();
      return;
    }
    if (t.id === 'sel-valor') { est.valor = t.value; actualizarBoton(); return; }
    if (t.id === 'sel-sin') {
      est.sinResp = t.checked;
      const w = el.querySelector('#sel-valor-wrap');
      if (w) w.innerHTML = controlValor();
      actualizarBoton();
    }
  });

  el.addEventListener('input', ev => {
    if (ev.target && ev.target.id === 'sel-valor' && ev.target.tagName === 'INPUT') {
      est.valor = ev.target.value;
      actualizarBoton();
    }
  });

  el.addEventListener('click', ev => {
    const t = ev.target.closest && ev.target.closest('[data-sel-limpiar],#sel-aplicar,[data-sel-borrar]');
    if (!t) return;
    if (t.matches('[data-sel-limpiar]')) limpiar();
    else if (t.id === 'sel-aplicar') pedirAplicar();
    else pedirBorrar();
  });

  return {
    get activo() { return activo(); },
    thHtml, tdHtml, contenedorHtml, pintarBarra, alPintar, alRecargar
  };
}
