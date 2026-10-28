/* Pestaña "Llamadas Producto" (#/p/:programa/llamadas-producto): la hoja del mismo nombre del Maestro de BPF, ahora EDITABLE
   (la app reemplaza al sheet). Mismas columnas y orden que la hoja. Se guarda de a una celda; agregar y borrar filas.
   Escribe quien edita el programa (la base lo exige); el resto la ve en solo lectura. Filtros: encargado, estado, búsqueda. */
import { esc, toast } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { traerLlamadasProducto, guardarLlamadaProducto, crearLlamadaProducto, borrarLlamadaProducto } from '../datos-llamadas-producto.js';
import { tarjetaError } from './programa.js';

/* k = columna de cs_llamadas_producto; t = tipo de control. */
const CAMPOS = [
  { k: 'encargado', lab: 'Encargado de la llamada', t: 'texto' },
  { k: 'fecha_agendada', lab: 'Fecha agendada', t: 'fecha' },
  { k: 'fecha_llamada_txt', lab: 'Fecha llamada', t: 'texto' },
  { k: 'nombre', lab: 'Nombre completo', t: 'texto' },
  { k: 'telefono', lab: 'Teléfono', t: 'texto' },
  { k: 'email', lab: 'Email', t: 'texto' },
  { k: 'show_up', lab: 'Show up', t: 'lista', ops: ['SI', 'NO'] },
  { k: 'estado_llamada', lab: 'Estado de la llamada', t: 'texto', datalist: true },
  { k: 'contexto', lab: 'Contexto', t: 'texto', ancho: true },
  { k: 'tipo_venta', lab: 'Tipo de venta', t: 'lista', ops: ['CHURN', 'RESELL'] },
  { k: 'cc_dia_1', lab: 'CC día 1', t: 'texto' },
  { k: 'cc_seguimiento', lab: 'CC seguimiento', t: 'texto' },
  { k: 'cc_trato_cerrado', lab: 'CC trato cerrado', t: 'texto' },
  { k: 'monto_restante', lab: 'Monto restante a pagar', t: 'texto' },
  { k: 'phatom', lab: 'Phatom', t: 'texto' }
];

export function vistaLlamadasProducto(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let filas = [], encargado = '', estado = '', texto = '', confirmando = '';
  const puedeEditar = puedeEditarPrograma(programaId);

  function control(c, f) {
    const v = f[c.k] == null ? '' : String(f[c.k]);
    const attr = `data-lp="${esc(c.k)}" data-id="${esc(f.id)}" data-prev="${esc(v)}" aria-label="${esc(c.lab + ' de la fila ' + f.fila_origen)}"`;
    if (!puedeEditar) return esc(v);
    if (c.t === 'fecha') return `<input type="date" class="m-edit m-fecha" value="${esc(v)}" ${attr}>`;
    if (c.t === 'lista') {
      const ops = c.ops.includes(v) || !v ? c.ops : [...c.ops, v];
      return `<select class="m-edit" ${attr}><option value="">—</option>${ops.map(o => `<option value="${esc(o)}"${o === v ? ' selected' : ''}>${esc(o)}</option>`).join('')}</select>`;
    }
    return `<input type="text" class="m-edit" maxlength="2000" autocomplete="off" value="${esc(v)}" title="${esc(v)}" placeholder="—"
      ${c.datalist ? 'list="lp-estados" ' : ''}${attr}>`;
  }

  function accion(f) {
    if (!puedeEditar) return '';
    if (confirmando === f.id) {
      return `<span class="hint">¿Borrar esta fila?</span> <button type="button" class="btn btn-danger btn-sm" data-lp-borrar-si="${esc(f.id)}">Sí, borrar</button>
        <button type="button" class="btn btn-sm" data-lp-borrar-no>No</button>`;
    }
    return `<button type="button" class="btn btn-sm" data-lp-borrar="${esc(f.id)}" aria-label="Borrar la fila ${f.fila_origen}">Borrar</button>`;
  }

  function tabla() {
    const t = texto.trim().toLowerCase();
    const lista = filas.filter(f => (!encargado || f.encargado === encargado) && (!estado || f.estado_llamada === estado)
      && (!t || [f.nombre, f.email, f.telefono].some(x => String(x || '').toLowerCase().includes(t))));
    if (!lista.length) return '<div class="muted-empty">No hay filas con ese filtro.</div>';
    const cuerpo = lista.map(f => `<tr>${CAMPOS.map(c =>
      `<td data-label="${esc(c.lab)}"${c.ancho ? ' class="sat-celda-txt"' : ''}>${control(c, f)}</td>`).join('')}
      ${puedeEditar ? `<td data-label="Acciones">${accion(f)}</td>` : ''}</tr>`).join('');
    return `<div class="hint">${lista.length} de ${filas.length} filas</div>
      <div class="card table-card"><table class="data-table"><thead><tr>
        ${CAMPOS.map(c => `<th>${esc(c.lab)}</th>`).join('')}${puedeEditar ? '<th></th>' : ''}
      </tr></thead><tbody>${cuerpo}</tbody></table></div>`;
  }

  const opciones = (valores, actual) => valores.map(v => `<option value="${esc(v)}"${v === actual ? ' selected' : ''}>${esc(v)}</option>`).join('');

  function pintar() {
    const encargados = [...new Set(filas.map(f => f.encargado).filter(Boolean))].sort();
    const estados = [...new Set(filas.map(f => f.estado_llamada).filter(Boolean))].sort();
    el.innerHTML = `
      <div class="section-title">Llamadas Producto<span class="line"></span></div>
      <div class="hint">Llamadas de resell y churn agendadas por Producto (hoja "Llamadas Producto" del Maestro de BPF).
        ${puedeEditar ? 'Se edita acá: cada celda se guarda al salir del campo.' : 'Solo lectura para tu usuario.'}</div>
      <div class="filter-row filtros-clientes">
        <input type="search" id="lp-texto" class="search-input" placeholder="Buscar por nombre, mail o teléfono" value="${esc(texto)}"
          autocomplete="off" aria-label="Buscar">
        <select id="lp-encargado" aria-label="Encargado"><option value="">Todos los encargados</option>${opciones(encargados, encargado)}</select>
        <select id="lp-estado" aria-label="Estado de la llamada"><option value="">Todos los estados</option>${opciones(estados, estado)}</select>
        ${puedeEditar ? '<button type="button" class="btn btn-accent" id="lp-agregar">Agregar llamada</button>' : ''}
      </div>
      <datalist id="lp-estados">${estados.map(e => `<option value="${esc(e)}">`).join('')}</datalist>
      <div id="lp-tabla">${tabla()}</div>`;
  }

  const repintarTabla = () => { const t = el.querySelector('#lp-tabla'); if (t) t.innerHTML = tabla(); };

  async function cargar() {
    const datos = await traerLlamadasProducto(programaId);
    if (!vigente()) return;
    if (datos === undefined) {
      el.innerHTML = tarjetaError('Falta correr la migración 238', 'La pestaña se activa cuando existe la tabla cs_llamadas_producto.');
      return;
    }
    filas = datos;
    if (!filas.length && !puedeEditar) {
      el.innerHTML = '<div class="card empty-state"><div class="big">Todavía no hay llamadas cargadas.</div></div>';
      return;
    }
    pintar();
  }

  async function guardarCelda(ctl) {
    const f = filas.find(x => x.id === ctl.dataset.id);
    if (!f) return;
    const campo = ctl.dataset.lp, valor = ctl.value.trim();
    if (valor === ctl.dataset.prev) return;
    ctl.disabled = true;
    try {
      await guardarLlamadaProducto(f.id, { [campo]: valor === '' ? null : valor });
      f[campo] = valor === '' ? null : valor;
      ctl.dataset.prev = valor;
      toast('Guardado.');
    } catch (e) {
      ctl.value = ctl.dataset.prev;
      toast(mensajeError(e), 'error');
    } finally {
      ctl.disabled = false;
    }
  }

  el.addEventListener('change', ev => {
    if (ev.target.id === 'lp-encargado') encargado = ev.target.value;
    else if (ev.target.id === 'lp-estado') estado = ev.target.value;
    else if (ev.target.dataset && ev.target.dataset.lp) { guardarCelda(ev.target); return; }
    else return;
    repintarTabla();
  });
  el.addEventListener('input', ev => {
    if (ev.target.id === 'lp-texto') { texto = ev.target.value; repintarTabla(); }
  });
  el.addEventListener('keydown', ev => {
    const ctl = ev.target.closest && ev.target.closest('input[data-lp]');
    if (!ctl) return;
    if (ev.key === 'Enter') { ev.preventDefault(); ctl.blur(); }
    if (ev.key === 'Escape') { ctl.value = ctl.dataset.prev; ctl.blur(); }
  });
  el.addEventListener('click', async ev => {
    const b = ev.target.closest('button');
    if (!b) return;
    try {
      if (b.id === 'lp-agregar') {
        b.disabled = true;
        filas.push(await crearLlamadaProducto(programaId, filas));
        texto = ''; encargado = ''; estado = '';
        pintar();
        toast('Fila agregada al final.');
      } else if (b.dataset.lpBorrar) {
        confirmando = b.dataset.lpBorrar; repintarTabla();
      } else if (b.dataset.lpBorrarNo !== undefined) {
        confirmando = ''; repintarTabla();
      } else if (b.dataset.lpBorrarSi) {
        b.disabled = true;
        await borrarLlamadaProducto(b.dataset.lpBorrarSi);
        filas = filas.filter(f => f.id !== b.dataset.lpBorrarSi);
        confirmando = '';
        pintar();
        toast('Fila borrada.');
      }
    } catch (e) {
      b.disabled = false;
      toast(mensajeError(e), 'error');
    }
  });

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar "Llamadas Producto"', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(err => console.error('llamadas-producto', err)) };
}
