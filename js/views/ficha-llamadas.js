/* Ficha de cliente — accionables por llamada (102).
   Cada llamada (fecha + título opcional) tiene sus tareas, con un nivel de subtareas.
   Arriba, el avance del alumno ("4 de 23"). Pendientes primero, por llamada de la más nueva
   a la más vieja; los completados quedan plegados abajo, con quién y cuándo los marcó.
   Es distinto de "Accionables" (cs_accionables: plantilla del programa, vencimientos y
   métricas), que no se toca.
   Permisos: fundador y quien edita el programa crean, editan y marcan; solo lectura
   (cliente@) ve; borrar es solo del fundador (la base lo exige igual). Sin la 102 el
   bloque no se muestra. */
import { esc, fmtFecha, plural, abrirModal, cerrarModal, confirmar } from '../ui.js';
import { esFundador, puedeEditarPrograma } from '../sesion.js';
import { actualizarFila, borrarFila } from '../datos.js';
import { guardar } from './comunes.js';
import { agregarAccionables, agregarSubtarea, parsearAccionables } from '../datos-llamadas.js';
import { modalNueva, modalEditarLlamada } from './ficha-llamada-modales.js';

const T_ACC = 'cs_llamada_accionables';
const hijosDe = (items, id) => items.filter(a => a.padre_id === id);

/* ---------- Pintado ---------- */

function item(a, { editar, fundador, sub = false, contexto = false }) {
  const dis = editar ? '' : ' disabled';
  const acciones = editar || fundador ? `<span class="ll-item-acc">
      ${editar && !sub ? `<button type="button" class="btn-icono" data-ll-sub="${esc(a.id)}">Subtarea</button>` : ''}
      ${editar ? `<button type="button" class="btn-icono" data-ll-editar="${esc(a.id)}">Editar</button>` : ''}
      ${fundador ? `<button type="button" class="btn-icono btn-icono-danger" data-ll-borrar="${esc(a.id)}">Borrar</button>` : ''}
    </span>` : '';
  return `<div class="ll-item${sub ? ' ll-sub' : ''}${contexto ? ' ll-contexto' : ''}">
      <label class="acc-check">
        <input type="checkbox" data-ll-check="${esc(a.id)}"${a.hecho ? ' checked' : ''}${dis}
          aria-label="${esc((a.hecho ? 'Reabrir ' : 'Completar ') + a.texto)}">
        <span class="acc-titulo">${esc(a.texto)}</span>
      </label>${acciones}
    </div>`;
}

function cabeceraLlamada(ll, items, editar, fundador) {
  const pend = items.filter(a => !a.hecho).length;
  return `<div class="ll-head">
      <div class="ll-head-tit">
        <span class="ll-fecha">Llamada del ${esc(fmtFecha(ll.fecha))}</span>
        ${ll.titulo ? `<span class="ll-titulo">${esc(ll.titulo)}</span>` : ''}
        <span class="ll-cuenta">${esc(items.length ? plural(pend, 'pendiente') : 'sin accionables')}</span>
      </div>
      ${editar || fundador ? `<span class="ll-item-acc">
        ${editar ? `<button type="button" class="btn-icono" data-ll-editar-llamada="${esc(ll.id)}">Editar llamada</button>` : ''}
        ${fundador ? `<button type="button" class="btn-icono btn-icono-danger" data-ll-borrar-llamada="${esc(ll.id)}">Borrar llamada</button>` : ''}
      </span>` : ''}
    </div>`;
}

/* Resumen, "En qué está" y "Próximos pasos" de la llamada (106). Vacío si no hay nada cargado. */
function infoLlamada(ll) {
  const partes = [['Resumen', ll.resumen], ['En qué está', ll.en_que_esta], ['Próximos pasos', ll.proximos_pasos]]
    .filter(([, v]) => v && String(v).trim());
  if (!partes.length) return '';
  return `<div class="ll-info">${partes.map(([t, v]) =>
    `<div><span class="ll-info-lab">${esc(t)}</span> ${esc(v)}</div>`).join('')}</div>`;
}

function grupoPendientes(ll, items, editar, fundador) {
  const raices = items.filter(a => !a.padre_id);
  const filas = [];
  for (const r of raices) {
    const hijos = hijosDe(items, r.id);
    const hijosPend = hijos.filter(h => !h.hecho);
    if (r.hecho && !hijosPend.length) continue;
    filas.push(item(r, { editar, fundador, contexto: r.hecho }));
    for (const h of hijosPend) filas.push(item(h, { editar, fundador, sub: true }));
  }
  const alta = editar ? `<form class="ll-alta" data-ll-alta="${esc(ll.id)}">
      <textarea name="texto" rows="1" maxlength="4000" placeholder="Agregar accionables (uno por línea; con sangría = subtarea)"
        aria-label="Nuevos accionables de la llamada del ${esc(fmtFecha(ll.fecha))}"></textarea>
      <button type="submit" class="btn btn-sm">Agregar</button>
    </form>` : '';
  return `<div class="ll-grupo">
      ${cabeceraLlamada(ll, items, editar, fundador)}
      ${infoLlamada(ll)}
      ${filas.length ? `<div class="acc-lista">${filas.join('')}</div>`
        : '<div class="muted-empty ll-vacio">No hay accionables pendientes de esta llamada.</div>'}
      ${alta}
    </div>`;
}

function filaHecha(a, todos, editar, fundador) {
  const padre = a.padre_id ? todos.find(x => x.id === a.padre_id) : null;
  const quien = a.hecho_por_nombre ? `por ${esc(a.hecho_por_nombre)}` : '';
  const cuando = a.hecho_at ? `el ${esc(fmtFecha(a.hecho_at))}` : '';
  return `<div class="ll-hecha">
      ${item(a, { editar, fundador, sub: !!padre })}
      <div class="ll-meta">${padre ? `Subtarea de «${esc(padre.texto)}» · ` : ''}Marcado ${quien} ${cuando}</div>
    </div>`;
}

export function html(ctx) {
  const d = ctx.llamadas;
  if (!d) return '';
  const editar = puedeEditarPrograma(ctx.p.id);
  const fundador = esFundador();
  const { llamadas, accionables } = d;
  const total = accionables.length;
  const hechos = accionables.filter(a => a.hecho).length;
  const pct = total ? Math.round(hechos * 100 / total) : 0;
  const porLlamada = ll => accionables.filter(a => a.llamada_id === ll.id);

  /* Quien no edita solo ve las llamadas con algo pendiente. */
  const visibles = llamadas.filter(ll => editar || porLlamada(ll).some(a => !a.hecho));
  const completados = llamadas.map(ll => ({ ll, hechas: porLlamada(ll).filter(a => a.hecho) })).filter(g => g.hechas.length);

  return `
    <div class="section-title">Accionables por llamada<span class="line"></span></div>
    <div class="card ll-card">
      <div class="ll-avance">
        <span class="ll-avance-n">${total ? `${hechos} de ${total}` : 'Sin accionables'}</span>
        <span class="ll-barra" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}"
          aria-label="Avance de accionables"><span class="ll-barra-fill" style="width:${pct}%"></span></span>
        <span class="ll-avance-pct">${total ? pct + '%' : ''}</span>
        ${editar ? '<button type="button" class="btn btn-sm btn-accent" data-ll-nueva>Nueva llamada</button>' : ''}
      </div>
      ${visibles.length
        ? visibles.map(ll => grupoPendientes(ll, porLlamada(ll), editar, fundador)).join('')
        : `<div class="muted-empty">${llamadas.length ? 'No hay accionables pendientes.' : 'Todavía no hay llamadas cargadas.'}</div>`}
      ${completados.length ? `<details class="acc-hechos ll-hechos"><summary>${esc(plural(hechos, 'completado'))}</summary>
        ${completados.map(g => `<div class="ll-grupo">
          <div class="ll-head"><span class="ll-fecha">Llamada del ${esc(fmtFecha(g.ll.fecha))}</span>
            ${g.ll.titulo ? `<span class="ll-titulo">${esc(g.ll.titulo)}</span>` : ''}</div>
          ${g.hechas.map(a => filaHecha(a, accionables, editar, fundador)).join('')}
        </div>`).join('')}</details>` : ''}
    </div>`;
}

/* ---------- Modales ---------- */

/* "Nueva llamada" y "Editar llamada" viven en ficha-llamada-modales.js (106). */

/* Editar el texto de un accionable, o escribir una subtarea nueva (a = el padre). */
function modalTexto({ titulo, valor = '', placeholder = '', alGuardar }) {
  abrirModal({
    titulo,
    cuerpo: `<div class="form-row"><label for="ll-texto">Texto *</label>
        <input type="text" id="ll-texto" maxlength="500" autocomplete="off" value="${esc(valor)}"
          placeholder="${esc(placeholder)}"></div>
      <div id="ll-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="ll-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="ll-ok">Guardar</button>`
  });
  document.getElementById('ll-cancelar').onclick = cerrarModal;
  const inp = document.getElementById('ll-texto');
  inp.focus();
  const ok = () => {
    const t = inp.value.trim();
    if (!t) { document.getElementById('ll-error').textContent = 'El texto es obligatorio.'; return; }
    cerrarModal();
    alGuardar(t);
  };
  document.getElementById('ll-ok').onclick = ok;
  inp.addEventListener('keydown', ev => { if (ev.key === 'Enter') { ev.preventDefault(); ok(); } });
}

/* ---------- Acciones ---------- */

export async function manejar(ev, ctx, api) {
  const d = ctx.llamadas;
  if (!d) return false;
  const editar = puedeEditarPrograma(ctx.p.id);
  const acc = id => d.accionables.find(a => a.id === id);
  const llamada = id => d.llamadas.find(l => l.id === id);
  const refrescar = () => api.refrescar();

  if (ev.type === 'submit') {
    const form = ev.target.closest('[data-ll-alta]');
    if (!form) return false;
    ev.preventDefault();
    const items = parsearAccionables(form.elements.texto.value);
    if (!items.length || !editar) return true;
    const llId = form.dataset.llAlta;
    const orden = d.accionables.filter(a => a.llamada_id === llId).reduce((m, a) => Math.max(m, a.orden + 1), 0);
    await guardar(() => agregarAccionables(ctx.p.id, ctx.c.id, llId, items, orden), {
      ok: plural(items.length, 'accionable') + (items.length === 1 ? ' agregado.' : ' agregados.'),
      luego: refrescar, control: form.querySelector('button')
    });
    return true;
  }

  if (ev.type === 'change') {
    const chk = ev.target.closest('[data-ll-check]');
    if (!chk) return false;
    if (!editar) return true;
    await guardar(() => actualizarFila(T_ACC, chk.dataset.llCheck, { hecho: chk.checked }), {
      ok: chk.checked ? 'Accionable completado.' : 'Accionable reabierto.', luego: refrescar, control: chk
    });
    return true;
  }

  if (ev.type !== 'click') return false;
  const el = sel => ev.target.closest(sel);

  if (el('[data-ll-nueva]')) { if (editar) await modalNueva(ctx, api); return true; }

  const eLl = el('[data-ll-editar-llamada]');
  if (eLl) {
    const ll = llamada(eLl.dataset.llEditarLlamada);
    if (ll && editar) await modalEditarLlamada(ll, ctx, api);
    return true;
  }

  const eAcc = el('[data-ll-editar]');
  if (eAcc) {
    const a = acc(eAcc.dataset.llEditar);
    if (a && editar) {
      modalTexto({
        titulo: 'Editar accionable', valor: a.texto,
        alGuardar: t => guardar(() => actualizarFila(T_ACC, a.id, { texto: t }), { luego: refrescar })
      });
    }
    return true;
  }

  const eSub = el('[data-ll-sub]');
  if (eSub) {
    const padre = acc(eSub.dataset.llSub);
    if (padre && editar) {
      modalTexto({
        titulo: 'Nueva subtarea', placeholder: `Subtarea de: ${padre.texto}`.slice(0, 80),
        alGuardar: t => guardar(() => agregarSubtarea(ctx.p.id, ctx.c.id, padre, t),
          { ok: 'Subtarea agregada.', luego: refrescar })
      });
    }
    return true;
  }

  const bAcc = el('[data-ll-borrar]');
  if (bAcc) {
    const a = acc(bAcc.dataset.llBorrar);
    if (!a || !esFundador()) return true;
    const subs = hijosDe(d.accionables, a.id).length;
    const ok = await confirmar({
      titulo: 'Borrar accionable', texto: `Se borra "${a.texto}".`,
      detalle: subs ? `También se ${subs === 1 ? 'borra su subtarea' : 'borran sus ' + subs + ' subtareas'}. No se puede deshacer.`
        : 'No se puede deshacer.', ok: 'Borrar'
    });
    if (ok) await guardar(() => borrarFila(T_ACC, a.id), { ok: 'Accionable borrado.', luego: refrescar, control: bAcc });
    return true;
  }

  const bLl = el('[data-ll-borrar-llamada]');
  if (bLl) {
    const ll = llamada(bLl.dataset.llBorrarLlamada);
    if (!ll || !esFundador()) return true;
    const n = d.accionables.filter(a => a.llamada_id === ll.id).length;
    const ok = await confirmar({
      titulo: 'Borrar llamada', texto: `Se borra la llamada del ${fmtFecha(ll.fecha)}.`,
      detalle: `${n ? 'Se borran también sus ' + plural(n, 'accionable') + '. ' : ''}Los recursos de esa llamada quedan en la ficha sin llamada. No se puede deshacer.`,
      ok: 'Borrar'
    });
    if (ok) await guardar(() => borrarFila('cs_llamadas', ll.id), { ok: 'Llamada borrada.', luego: refrescar, control: bLl });
    return true;
  }
  return false;
}
