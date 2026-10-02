/* Hoy (#/p/:programa/hoy): la cola de trabajo del CSM, sobre cs_cola_hoy (069).
   Tres grupos (Atrasado, Hoy, Próximos) con una tarjeta por tarea y su acción:
     aviso_1 / aviso_2        Hecho (registrarAviso)
     accionable               Hecho, +3 días, +7 días
     contacto / renovacion    Registrar contacto (hoy-contacto.js)
     onboarding / devolucion  Abrir ficha
   Al resolver, la tarjeta sale al instante y la cola se vuelve a pedir.
   Atajos: J / K mueven la selección, H = hecho, C = registrar contacto. */
import { esc, hoyAR, sumarDias, fmtFecha, plural, toast, hayModalAbierto } from '../ui.js';
import { traerColaHoy, actualizarFila, mensajeError } from '../datos.js';
import { registrarAviso } from '../ciclo.js';
import { tarjetaError } from './programa.js';
import { abrirPanelContacto, hayPanelContacto } from './hoy-contacto.js';

const GRUPOS = [['atrasado', 'Atrasado'], ['hoy', 'Hoy'], ['proximo', 'Próximos']];
const TIPO_LABEL = {
  aviso_1: 'Aviso 1', aviso_2: 'Aviso 2', accionable: 'Accionable', contacto: 'Contacto',
  renovacion: 'Renovación', onboarding: 'Onboarding', devolucion: 'Devolución'
};
const ES_AVISO = { aviso_1: 1, aviso_2: 2 };
const CON_CONTACTO = ['contacto', 'renovacion'];

const clave = t => `${t.tipo}:${t.ref_id || t.cliente_id}`;
const hrefFicha = (programaId, t) => `#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(t.cliente_id)}`;

function botones(t, programaId, ocupada) {
  const dis = ocupada ? ' disabled' : '';
  const b = (accion, label, clase = '') =>
    `<button type="button" class="btn btn-sm ${clase}" data-accion="${accion}"${dis}>${esc(label)}</button>`;
  if (ES_AVISO[t.tipo]) return b('hecho', 'Hecho', 'btn-accent');
  if (t.tipo === 'accionable') return b('hecho', 'Hecho', 'btn-accent') + b('mas3', '+3 días') + b('mas7', '+7 días');
  if (CON_CONTACTO.includes(t.tipo)) return b('contacto', 'Registrar contacto', 'btn-accent');
  return `<a class="btn btn-sm" href="${hrefFicha(programaId, t)}">Abrir ficha</a>`;
}

function tarjeta(t, programaId, sel, ocupada) {
  const k = clave(t);
  const atraso = t.cuando === 'atrasado' && Number(t.dias_atraso) > 0
    ? `<span class="hoy-atraso">hace ${esc(plural(Number(t.dias_atraso), 'día'))}</span>` : '';
  return `
    <article class="hoy-card hoy-${esc(t.cuando)}${k === sel ? ' sel' : ''}${ocupada ? ' ocupada' : ''}" data-k="${esc(k)}">
      <div class="hoy-card-main">
        <div class="hoy-card-top">
          <a class="cli-nombre" href="${hrefFicha(programaId, t)}">${esc(t.cliente || 'Sin nombre')}</a>
          <span class="hoy-tipo">${esc(TIPO_LABEL[t.tipo] || t.tipo)}</span>
        </div>
        <div class="hoy-titulo">${esc(t.titulo || '')}</div>
        ${t.detalle ? `<div class="hoy-detalle">${esc(t.detalle)}</div>` : ''}
      </div>
      <div class="hoy-card-meta">
        <span class="hoy-fecha">${esc(t.fecha ? fmtFecha(t.fecha) : 'Sin fecha')}</span>${atraso}
      </div>
      <div class="hoy-card-acc">${botones(t, programaId, ocupada)}</div>
    </article>`;
}

function cabecera(todas, filtro) {
  const n = c => todas.filter(t => t.cuando === c).length;
  const porTipo = new Map();
  for (const t of todas) porTipo.set(t.tipo, (porTipo.get(t.tipo) || 0) + 1);
  const chip = (v, label, cant) =>
    `<button type="button" class="hoy-chip${filtro === v ? ' on' : ''}" data-tipo="${esc(v)}" aria-pressed="${filtro === v}">${esc(label)} <span class="hoy-chip-n">${cant}</span></button>`;
  const tipos = Object.keys(TIPO_LABEL).filter(tp => porTipo.has(tp));
  return `
    <div class="hoy-head">
      <div class="hoy-cuenta">
        <span class="hoy-n hoy-n-atrasado">${esc(plural(n('atrasado'), 'atrasado'))}</span> ·
        <span class="hoy-n hoy-n-hoy">${n('hoy')} hoy</span> ·
        <span class="hoy-n hoy-n-proximo">${esc(plural(n('proximo'), 'próximo'))}</span>
      </div>
      <div class="hoy-atajos" aria-hidden="true"><kbd>J</kbd><kbd>K</kbd> mover · <kbd>H</kbd> hecho · <kbd>C</kbd> contacto</div>
    </div>
    <div class="hoy-chips hoy-filtros" role="group" aria-label="Filtrar por tipo">
      ${chip('', 'Todos', todas.length)}${tipos.map(tp => chip(tp, TIPO_LABEL[tp], porTipo.get(tp))).join('')}
    </div>`;
}

export function vistaHoy(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let cola = [], cargada = false;
  let filtro = '', sel = null, pedido = 0;
  const ocupadas = new Set();   // llamada en vuelo: botones bloqueados
  const resueltas = new Set();  // ya resueltas: fuera de la lista hasta que vuelva la cola

  const pendientes = () => cola.filter(t => !resueltas.has(clave(t)));
  const visibles = () => pendientes().filter(t => !filtro || t.tipo === filtro);

  function pintar() {
    if (!cargada) return;
    const todas = pendientes();
    if (filtro && !todas.some(t => t.tipo === filtro)) filtro = '';
    if (!todas.length) {
      el.innerHTML = '<div class="card empty-state"><div class="big">Nada pendiente para hoy</div></div>';
      return;
    }
    const lista = visibles();
    if (!lista.some(t => clave(t) === sel)) sel = lista.length ? clave(lista[0]) : null;
    const main = document.querySelector('.main');
    const y = main ? main.scrollTop : 0;
    el.innerHTML = cabecera(todas, filtro) + GRUPOS.map(([c, label]) => {
      const g = lista.filter(t => t.cuando === c);
      if (!g.length) return '';
      return `<section class="hoy-grupo">
        <div class="section-title">${esc(label)} <span class="hoy-grupo-n hoy-n-${c}">${g.length}</span><span class="line"></span></div>
        ${g.map(t => tarjeta(t, programaId, sel, ocupadas.has(clave(t)))).join('')}
      </section>`;
    }).join('');
    if (main) main.scrollTop = y;
  }

  function seleccionar(k, mostrar = false) {
    sel = k;
    for (const c of el.querySelectorAll('.hoy-card')) c.classList.toggle('sel', c.dataset.k === k);
    if (!mostrar) return;
    const card = [...el.querySelectorAll('.hoy-card')].find(c => c.dataset.k === k);
    if (card) card.scrollIntoView({ block: 'nearest' });
  }

  /* Solo se pinta el último pedido: un refresco viejo (realtime) no pisa uno más nuevo. */
  async function cargar() {
    const n = ++pedido;
    const datos = await traerColaHoy(programaId);
    if (!vigente() || n !== pedido) return false;
    cola = datos;
    cargada = true;
    pintar();
    return true;
  }

  /* Una sola llamada por tarea a la vez. Si sale bien, la tarjeta se va ya y la cola se
     vuelve a pedir; recién con la cola nueva se suelta (un "+3 días" puede volver como próximo). */
  async function resolver(t, fn, ok) {
    const k = clave(t);
    if (ocupadas.has(k) || resueltas.has(k)) return;
    ocupadas.add(k);
    pintar();
    try {
      await fn();
      toast(ok);
      resueltas.add(k);
    } catch (e) {
      toast(mensajeError(e), 'error');
    } finally {
      ocupadas.delete(k);
    }
    if (!vigente()) return;
    pintar();
    if (!resueltas.has(k)) return;
    try {
      if (await cargar()) { resueltas.delete(k); pintar(); }
    } catch (e) {
      console.error('hoy', e);
    }
  }

  function hecho(t) {
    const n = ES_AVISO[t.tipo];
    if (n) return resolver(t, () => registrarAviso(t.cliente_id, n), `Aviso ${n} registrado.`);
    if (t.tipo === 'accionable') {
      return resolver(t, () => actualizarFila('cs_accionables', t.ref_id, { estado: 'completado' }), 'Accionable completado.');
    }
    return null;
  }

  function mover(t, dias) {
    const vence = sumarDias(hoyAR(), dias);
    return resolver(t, () => actualizarFila('cs_accionables', t.ref_id, { vence }), `Movido al ${fmtFecha(vence)}.`);
  }

  function contacto(t) {
    if (!CON_CONTACTO.includes(t.tipo) || ocupadas.has(clave(t))) return;
    const k = clave(t);
    abrirPanelContacto(t, async () => {
      if (!vigente()) return;
      resueltas.add(k);
      pintar();
      try {
        if (await cargar()) { resueltas.delete(k); pintar(); }
      } catch (e) {
        console.error('hoy', e);
      }
    });
  }

  const tareaDe = k => visibles().find(t => clave(t) === k);

  el.addEventListener('click', ev => {
    const chip = ev.target.closest('[data-tipo]');
    if (chip) { filtro = chip.dataset.tipo; pintar(); return; }
    const card = ev.target.closest('.hoy-card');
    if (!card) return;
    seleccionar(card.dataset.k);
    const btn = ev.target.closest('[data-accion]');
    const t = btn && tareaDe(card.dataset.k);
    if (!t) return;
    const a = btn.dataset.accion;
    if (a === 'hecho') hecho(t);
    else if (a === 'mas3') mover(t, 3);
    else if (a === 'mas7') mover(t, 7);
    else if (a === 'contacto') contacto(t);
  });

  /* Atajos. Van en document (la lista no tiene foco propio) y se sueltan solos cuando
     la vista deja de estar montada. Esc lo maneja el panel. */
  function onKey(ev) {
    if (!el.isConnected || !vigente()) { document.removeEventListener('keydown', onKey); return; }
    if (ev.ctrlKey || ev.metaKey || ev.altKey || hayModalAbierto() || hayPanelContacto()) return;
    const o = ev.target;
    if (o && (o.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(o.tagName))) return;
    const tecla = ev.key.toLowerCase();
    if (!['j', 'k', 'h', 'c'].includes(tecla)) return;
    const lista = visibles();
    if (!lista.length) return;
    ev.preventDefault();
    const i = Math.max(0, lista.findIndex(t => clave(t) === sel));
    if (tecla === 'j') return seleccionar(clave(lista[Math.min(lista.length - 1, i + 1)]), true);
    if (tecla === 'k') return seleccionar(clave(lista[Math.max(0, i - 1)]), true);
    if (tecla === 'h') return hecho(lista[i]);
    return contacto(lista[i]);
  }
  document.addEventListener('keydown', onKey);

  cargar().catch(e => {
    if (!vigente()) return;
    const falta = /cs_cola_hoy/.test(e && e.message || '')
      ? 'Falta correr la migración 069 (cola de hoy).' : mensajeError(e);
    el.innerHTML = tarjetaError('No se pudo cargar la cola de hoy', falta);
  });
  return { refrescar: () => cargar().catch(e => console.error('hoy', e)) };
}
