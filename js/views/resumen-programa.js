/* Pestaña "Resumen" (#/p/:programa/resumen): la hoja "Resumen" del Maestro de DCAC, calculada en
   vivo con los alumnos del programa (cs_v_maestro). Tres bloques:
   1. Altas por mes y producto. Altas = clientes nuevos: no cuenta resell, upsell ni 2da cuota
      (se reconocen por el producto "Resell …" o por la columna Concepto del Maestro, x_concepto).
   2. Activos hoy por producto (con fecha de fin vigente; los sin vencimiento aparte) y cuántos
      vencen dentro del aviso de renovación del programa.
   3. Vencen en los próximos días (para renovar) y vencidos en los últimos 30 días (resell). */
import { esc, fmtFecha, plural, hoyAR } from '../ui.js';
import { traerMaestro, traerPrograma, esVivo, mensajeError } from '../datos.js';
import { traerProductos } from '../ciclo.js';
import { sinVencimiento } from '../sin-vencimiento.js';
import { tarjetaError } from './programa.js';
import { num } from './comunes.js';

const CLAVE_CONCEPTO = 'x_concepto';
const DIAS_VENCIDOS = 30;
const MAX_FILAS = 200;
const MESES = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];

const concepto = c => String((c.campos_extra && c.campos_extra[CLAVE_CONCEPTO]) || '');
const esResell = c => /^resell/i.test(c.producto || '') || ['Resell', 'Upsell'].includes(concepto(c));
const producto = c => c.producto || 'Sin producto';

/* Orden de las columnas de producto: el del catálogo; los que no están, al final. */
function ordenProductos(nombres, catalogo) {
  const idx = new Map((catalogo || []).map((p, i) => [p.nombre, i]));
  return [...nombres].sort((a, b) => (idx.has(a) ? idx.get(a) : 999) - (idx.has(b) ? idx.get(b) : 999) || a.localeCompare(b));
}

function htmlAltas(filas, anio, catalogo) {
  const altas = filas.filter(c => concepto(c) !== '2da cuota' && String(c.fecha_inicio || '').startsWith(anio));
  const nombres = ordenProductos(new Set(altas.filter(c => !esResell(c)).map(producto)), catalogo);
  const mes = Array.from({ length: 12 }, () => ({ porProducto: new Map(), resell: 0 }));
  for (const c of altas) {
    const m = mes[Number(String(c.fecha_inicio).slice(5, 7)) - 1];
    if (!m) continue;
    if (esResell(c)) m.resell++;
    else m.porProducto.set(producto(c), (m.porProducto.get(producto(c)) || 0) + 1);
  }
  if (!altas.length) return '<div class="muted-empty">No hay altas en este año.</div>';
  const total = new Map();
  let totalResell = 0;
  const cuerpo = mes.map((m, i) => {
    let suma = 0;
    const celdas = nombres.map(n => {
      const v = m.porProducto.get(n) || 0;
      suma += v;
      total.set(n, (total.get(n) || 0) + v);
      return `<td class="num" data-label="${esc(n)}">${v}</td>`;
    }).join('');
    totalResell += m.resell;
    return `<tr><td data-label="Mes">${MESES[i]}</td>${celdas}<td class="num" data-label="Total altas"><strong>${suma}</strong></td>
      <td class="num" data-label="Resell + Upsell">${m.resell}</td></tr>`;
  }).join('');
  const totalAltas = [...total.values()].reduce((a, b) => a + b, 0);
  const pie = `<tr><td><strong>Total ${esc(anio)}</strong></td>${nombres.map(n => `<td class="num"><strong>${total.get(n) || 0}</strong></td>`).join('')}
    <td class="num"><strong>${totalAltas}</strong></td><td class="num"><strong>${totalResell}</strong></td></tr>`;
  return `<div class="card table-card"><table class="data-table"><thead><tr><th>Mes</th>${nombres.map(n => `<th>${esc(n)}</th>`).join('')}
    <th>Total altas</th><th>Resell + Upsell</th></tr></thead><tbody>${cuerpo}${pie}</tbody></table></div>`;
}

function htmlActivos(filas, catalogo, avisoDias) {
  const vivos = filas.filter(c => esVivo(c) && (sinVencimiento(c.fecha_fin) || (c.dias_restantes != null && num(c.dias_restantes) >= 0)));
  if (!vivos.length) return '<div class="muted-empty">No hay alumnos activos.</div>';
  const nombres = ordenProductos(new Set(vivos.map(producto)), catalogo);
  const fila = n => {
    const de = vivos.filter(c => producto(c) === n);
    const sinV = de.filter(c => sinVencimiento(c.fecha_fin)).length;
    const conV = de.length - sinV;
    const vencen = de.filter(c => !sinVencimiento(c.fecha_fin) && num(c.dias_restantes) <= avisoDias).length;
    return { n, conV, sinV, vencen };
  };
  const datos = nombres.map(fila);
  const sum = k => datos.reduce((a, d) => a + d[k], 0);
  const cuerpo = datos.map(d => `<tr><td data-label="Producto">${esc(d.n)}</td>
      <td class="num" data-label="Activos">${d.conV}</td>
      <td class="num" data-label="Sin vencimiento">${d.sinV}</td>
      <td class="num" data-label="Vencen">${d.vencen}</td></tr>`).join('');
  return `<div class="card table-card"><table class="data-table"><thead><tr><th>Producto</th><th>Activos</th><th>Sin vencimiento</th>
    <th>Vencen en ≤${esc(avisoDias)} días</th></tr></thead><tbody>${cuerpo}
    <tr><td><strong>Total</strong></td><td class="num"><strong>${sum('conV')}</strong></td><td class="num"><strong>${sum('sinV')}</strong></td>
    <td class="num"><strong>${sum('vencen')}</strong></td></tr></tbody></table></div>`;
}

function tablaLista(filas, programaId, vacio) {
  if (!filas.length) return `<div class="muted-empty">${esc(vacio)}</div>`;
  const cuerpo = filas.slice(0, MAX_FILAS).map(c => `<tr>
      <td data-label="Alumno"><a class="cli-nombre" href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(c.id)}">${esc(c.nombre)}</a></td>
      <td data-label="Producto">${esc(producto(c))}</td>
      <td data-label="Fecha fin">${esc(fmtFecha(c.fecha_fin))}</td>
      <td class="num" data-label="Días">${esc(num(c.dias_restantes))}</td>
      <td data-label="Mail">${esc(c.email || '')}</td>
      <td data-label="Número">${esc(c.telefono || '')}</td>
      <td data-label="Resell">${esc(c.renovacion_estado || '')}</td></tr>`).join('');
  const mas = filas.length > MAX_FILAS ? `<div class="hint">Se muestran ${MAX_FILAS} de ${filas.length}.</div>` : '';
  return `<div class="card table-card"><table class="data-table"><thead><tr><th>Alumno</th><th>Producto</th><th>Fecha fin</th><th>Días</th>
    <th>Mail</th><th>Número</th><th>Resell</th></tr></thead><tbody>${cuerpo}</tbody></table></div>${mas}`;
}

export function vistaResumen(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let filas = [], catalogo = [], avisoDias = 21, anio = hoyAR().slice(0, 4);

  function pintar() {
    const anios = [...new Set(filas.map(c => String(c.fecha_inicio || '').slice(0, 4)).filter(Boolean).concat([hoyAR().slice(0, 4)]))].sort().reverse();
    const vivosConFin = filas.filter(c => esVivo(c) && c.dias_restantes != null);
    const vencen = vivosConFin.filter(c => num(c.dias_restantes) >= 0 && num(c.dias_restantes) <= avisoDias)
      .sort((a, b) => num(a.dias_restantes) - num(b.dias_restantes));
    const vencidos = filas.filter(c => c.dias_restantes != null && num(c.dias_restantes) < 0 && num(c.dias_restantes) >= -DIAS_VENCIDOS
      && c.estado !== 'baja').sort((a, b) => num(b.dias_restantes) - num(a.dias_restantes));
    el.innerHTML = `
      <div class="section-title">Altas por mes<span class="line"></span>
        <select id="rs-anio" aria-label="Año">${anios.map(a => `<option value="${esc(a)}"${a === anio ? ' selected' : ''}>${esc(a)}</option>`).join('')}</select></div>
      <div class="hint">Altas = clientes nuevos. No cuenta resell, upsell ni 2da cuota (esos van en "Resell + Upsell" o se omiten).</div>
      ${htmlAltas(filas, anio, catalogo)}
      <div class="section-title">Activos hoy<span class="line"></span></div>
      ${htmlActivos(filas, catalogo, avisoDias)}
      <div class="section-title">Vencen en los próximos ${esc(plural(avisoDias, 'día'))} (para renovar)<span class="line"></span></div>
      ${tablaLista(vencen, programaId, 'Nadie vence en ese plazo.')}
      <div class="section-title">Vencidos en los últimos ${DIAS_VENCIDOS} días (oportunidad de resell)<span class="line"></span></div>
      ${tablaLista(vencidos, programaId, 'No hay vencidos en ese plazo.')}`;
  }

  async function cargar() {
    const [maestro, prods, prog] = await Promise.all([traerMaestro(programaId), traerProductos(programaId), traerPrograma(programaId)]);
    if (!vigente()) return;
    filas = maestro;
    catalogo = prods;
    avisoDias = num(prog && prog.aviso_renovacion_dias) || 21;
    pintar();
  }

  el.addEventListener('change', ev => {
    if (ev.target.id === 'rs-anio') { anio = ev.target.value; pintar(); }
  });

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar el resumen', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(err => console.error('resumen', err)) };
}
