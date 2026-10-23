/* Pestaña "Fuera del maestro" (#/p/:programa/fuera): la hoja del mismo nombre de DCAC. Lista de solo
   lectura de las filas que se sacaron del Maestro y por qué (columna MOTIVO). Se carga con la
   migración de datos de agus; acá no se edita. Filtro por motivo y búsqueda por nombre, mail o número. */
import { esc, fmtFecha } from '../ui.js';
import { mensajeError } from '../datos.js';
import { traerFueraMaestro } from '../datos-fuera-maestro.js';
import { tarjetaError } from './programa.js';

export function vistaFueraMaestro(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let filas = [], motivo = '', texto = '';

  function tabla() {
    const t = texto.trim().toLowerCase();
    const lista = filas.filter(f => (!motivo || f.motivo === motivo)
      && (!t || [f.nombre, f.mail, f.numero].some(x => String(x || '').toLowerCase().includes(t))));
    if (!lista.length) return '<div class="muted-empty">No hay filas con ese filtro.</div>';
    const cuerpo = lista.map(f => `<tr>
        <td data-label="Fecha de carga">${esc(f.fecha_carga ? fmtFecha(f.fecha_carga) : '—')}</td>
        <td data-label="Programa">${esc(f.producto_raw || '')}</td>
        <td data-label="Nombre">${esc(f.nombre || '')}</td>
        <td data-label="Mail">${esc(f.mail || '')}</td>
        <td data-label="Número">${esc(f.numero || '')}</td>
        <td data-label="Estado">${esc(f.estado || '')}</td>
        <td data-label="Contexto" class="sat-celda-txt">${esc(f.contexto || '')}</td>
        <td data-label="Motivo">${esc(f.motivo || '')}</td>
      </tr>`).join('');
    return `<div class="hint">${lista.length} de ${filas.length} filas</div>
      <div class="card table-card"><table class="data-table"><thead><tr>
        <th>Fecha de carga</th><th>Programa</th><th>Nombre</th><th>Mail</th><th>Número</th><th>Estado</th><th>Contexto</th><th>Motivo</th>
      </tr></thead><tbody>${cuerpo}</tbody></table></div>`;
  }

  function pintar() {
    const motivos = [...new Set(filas.map(f => f.motivo).filter(Boolean))].sort();
    el.innerHTML = `
      <div class="section-title">Fuera del maestro<span class="line"></span></div>
      <div class="hint">Filas que se sacaron del Maestro (señas completadas en otra fila, duplicadas, comprobantes extra, notas sueltas). Solo lectura.</div>
      <div class="filter-row filtros-clientes">
        <input type="search" id="fm-texto" class="search-input" placeholder="Buscar por nombre, mail o número" value="${esc(texto)}"
          autocomplete="off" aria-label="Buscar">
        <select id="fm-motivo" aria-label="Motivo"><option value="">Todos los motivos</option>
          ${motivos.map(m => `<option value="${esc(m)}"${m === motivo ? ' selected' : ''}>${esc(m)}</option>`).join('')}</select>
      </div>
      <div id="fm-tabla">${tabla()}</div>`;
  }

  async function cargar() {
    const datos = await traerFueraMaestro(programaId);
    if (!vigente()) return;
    if (datos === undefined) {
      el.innerHTML = tarjetaError('Falta correr la migración de la estructura de agus',
        'La pestaña se activa cuando existe la tabla cs_fuera_maestro.');
      return;
    }
    filas = datos;
    if (!filas.length) {
      el.innerHTML = '<div class="card empty-state"><div class="big">Todavía no hay filas cargadas.</div></div>';
      return;
    }
    pintar();
  }

  el.addEventListener('change', ev => {
    if (ev.target.id === 'fm-motivo') { motivo = ev.target.value; el.querySelector('#fm-tabla').innerHTML = tabla(); }
  });
  el.addEventListener('input', ev => {
    if (ev.target.id === 'fm-texto') { texto = ev.target.value; el.querySelector('#fm-tabla').innerHTML = tabla(); }
  });

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar "Fuera del maestro"', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(err => console.error('fuera-maestro', err)) };
}
