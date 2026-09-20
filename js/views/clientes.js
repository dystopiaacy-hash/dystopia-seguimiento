/* Lista de clientes del programa (#/p/:programa/clientes).
   Datos y semáforo salen de cs_v_clientes; acá solo se filtra, ordena y pinta.
   Los filtros iniciales pueden venir por query (?estado=vivos, ?vencer=1, ...)
   para que los KPIs del dashboard lleven a la lista ya filtrada. */
import { esc, fmtNum, fmtFecha, fmtFechaHora, plural, badge, nivelPorDias } from '../ui.js';
import { queryActual } from '../router.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerClientes, mensajeError, esVivo,
  ESTADO_LABEL, ESTADO_COLOR, ONBOARDING_LABEL
} from '../datos.js';
import { abrirModalNuevoCliente } from './cliente-nuevo.js';

const n = v => Number(v) || 0;
const SEM_ORDEN = { rojo: 0, amarillo: 1, verde: 2, gris: 3 };

/* ---------- Columnas ---------- */
/* clave, etiqueta, clase de celda, valor para ordenar, celda HTML */
function columnas(p) {
  const base = '#/p/' + encodeURIComponent(p.id);
  return [
    { k: 'semaforo', lab: 'Sem.', cls: 'col-sem', ord: c => SEM_ORDEN[c.semaforo] ?? 9,
      td: c => `<span class="sem-dot sem-${esc(c.semaforo)}" title="${esc((c.motivos_semaforo || []).join(' · ') || 'Sin alertas')}"></span>` },
    { k: 'nombre', lab: 'Cliente', cls: 'col-nombre', ord: c => (c.nombre || '').toLowerCase(),
      td: c => `<a class="cli-nombre" href="${base}/c/${encodeURIComponent(c.id)}">${esc(c.nombre)}</a>${c.email ? `<span class="cli-email">${esc(c.email)}</span>` : ''}` },
    { k: 'estado', lab: 'Estado', cls: '', ord: c => ESTADO_LABEL[c.estado] || c.estado,
      td: c => badge(ESTADO_LABEL[c.estado] || c.estado, ESTADO_COLOR[c.estado], 'status') },
    { k: 'etapa', lab: 'Etapa', cls: '', ord: c => (c.etapa || '').toLowerCase(),
      td: c => c.etapa ? esc(c.etapa) : '<span class="txt-gris">—</span>' },
    { k: 'responsable', lab: 'Responsable', cls: '', ord: c => (c.responsable || '').toLowerCase(),
      td: c => c.responsable ? esc(c.responsable) : '<span class="txt-gris">Sin asignar</span>' },
    { k: 'progreso', lab: 'Programa', cls: 'col-prog', ord: c => (c.dias_restantes == null ? 99999 : n(c.dias_restantes)),
      td: c => celdaProgreso(c, p) },
    { k: 'acc_bpf_pendientes', lab: 'Acc. BPF', cls: 'num', ord: c => n(c.acc_bpf_pendientes),
      td: c => celdaConteo(n(c.acc_bpf_pendientes), n(c.acc_bpf_vencidos), 'vencidos') },
    { k: 'acc_cliente_pendientes', lab: 'Acc. cliente', cls: 'num', ord: c => n(c.acc_cliente_pendientes),
      td: c => celdaConteo(n(c.acc_cliente_pendientes), n(c.acc_cliente_vencidos), 'vencidos') },
    { k: 'dev_pendientes', lab: 'Dev. pend.', cls: 'num', ord: c => n(c.dev_pendientes),
      td: c => celdaConteo(n(c.dev_pendientes), n(c.dev_vencidas_sla), 'fuera de SLA') },
    { k: 'onboarding_estado', lab: 'Onboarding', cls: '', ord: c => ONBOARDING_LABEL[c.onboarding_estado] || 'zz',
      td: c => celdaOnboarding(c, p) },
    { k: 'ultimo_chequeo_at', lab: 'Chequeo', cls: 'col-chq', ord: c => (c.ultimo_chequeo_at ? Date.parse(c.ultimo_chequeo_at) : 0),
      td: c => celdaChequeo(c, p) }
  ];
}

function celdaProgreso(c, p) {
  const pct = Math.max(0, Math.min(100, n(c.pct_programa)));
  const d = c.dias_restantes == null ? null : n(c.dias_restantes);
  const nivel = nivelPorDias(d, { amarillo: n(p.aviso_renovacion_dias), rojo: -1 });
  const txt = d == null ? '—' : `${d} d`;
  const tit = d == null ? '' : (d < 0 ? `Venció hace ${plural(-d, 'día')}` : `Quedan ${plural(d, 'día')} · ${pct}% del programa`);
  return `<span class="prog-cell" title="${esc(tit)}">
      <span class="prog-track"><span class="prog-fill prog-${esc(nivel)}" style="width:${pct}%"></span></span>
      <span class="prog-dias sem-txt-${esc(nivel)}">${esc(txt)}</span>
    </span>`;
}

/* pend = pendientes, venc = subconjunto en rojo (vencidos o fuera de SLA). */
function celdaConteo(pend, venc, frase) {
  if (!pend) return '<span class="txt-gris">0</span>';
  const tit = venc ? `${pend} pendientes · ${venc} ${frase}` : `${pend} pendientes, ninguno ${frase}`;
  return `<span class="cuenta${venc ? ' txt-rojo' : ''}" title="${esc(tit)}">${fmtNum(pend)}${venc ? `<span class="cuenta-venc">${venc}</span>` : ''}</span>`;
}

function celdaOnboarding(c, p) {
  const e = c.onboarding_estado;
  if (!e) return '<span class="txt-gris">Sin call</span>';
  const demorado = e === 'pendiente_agendar' && n(c.dias_transcurridos) > n(p.sla_onboarding_dias) && esVivo(c);
  if (demorado) return `<span class="txt-rojo" title="${esc(`Sin agendar hace ${plural(n(c.dias_transcurridos), 'día')}`)}">Sin agendar</span>`;
  if (e === 'realizada') return '<span class="txt-gris">Hecha</span>';
  return esc(ONBOARDING_LABEL[e] || e);
}

function celdaChequeo(c, p) {
  if (!c.ultimo_chequeo_at) return '<span class="txt-gris">Nunca</span>';
  const d = n(c.dias_sin_chequeo);
  const tarde = esVivo(c) && d > n(p.dias_sin_chequeo_alerta);
  return `<span class="${tarde ? 'txt-amarillo' : ''}" title="${esc(fmtFechaHora(c.ultimo_chequeo_at) + ' · hace ' + plural(d, 'día'))}">${esc(fmtFecha(c.ultimo_chequeo_at))}</span>`;
}

/* ---------- Filtros ---------- */

function filtrosIniciales() {
  const q = queryActual();
  return {
    estado: q.get('estado') || '',
    semaforo: q.get('semaforo') || '',
    responsable: q.get('responsable') || '',
    etapa: q.get('etapa') || '',
    onboarding: q.get('onboarding') || '',
    vencer: q.get('vencer') === '1',
    q: q.get('q') || ''
  };
}

function aplicar(clientes, f, p) {
  const texto = f.q.trim().toLowerCase();
  return clientes.filter(c => {
    if (f.estado === 'vivos') { if (!esVivo(c)) return false; }
    else if (f.estado && c.estado !== f.estado) return false;
    if (f.semaforo && c.semaforo !== f.semaforo) return false;
    if (f.responsable && (c.responsable || '') !== f.responsable) return false;
    if (f.etapa && (c.etapa || '') !== f.etapa) return false;
    if (f.onboarding && (c.onboarding_estado || '') !== f.onboarding) return false;
    if (f.vencer) {
      const d = c.dias_restantes;
      if (!esVivo(c) || d == null || d > n(p.aviso_renovacion_dias)) return false;
    }
    if (texto) {
      const en = `${c.nombre || ''} ${c.email || ''}`.toLowerCase();
      if (!en.includes(texto)) return false;
    }
    return true;
  });
}

function ordenar(filas, cols, orden) {
  const col = cols.find(c => c.k === orden.k) || cols[0];
  const dir = orden.desc ? -1 : 1;
  return filas.slice().sort((a, b) => {
    const va = col.ord(a), vb = col.ord(b);
    if (va < vb) return -1 * dir;
    if (va > vb) return 1 * dir;
    return (a.nombre || '').localeCompare(b.nombre || '', 'es');
  });
}

function opcionesUnicas(clientes, campo) {
  return Array.from(new Set(clientes.map(c => (c[campo] || '').trim()).filter(Boolean))).sort((a, b) => a.localeCompare(b, 'es'));
}

/* Etiqueta y select van juntos en un grupo para que, al achicar la ventana,
   la fila de filtros corte entre filtros y no entre una etiqueta y su select. */
function selectHtml(id, label, opciones, valor) {
  return `<span class="fgroup">
      <label class="flabel" for="${id}">${esc(label)}</label>
      <select id="${id}">${opciones.map(([v, t]) =>
        `<option value="${esc(v)}"${v === valor ? ' selected' : ''}>${esc(t)}</option>`).join('')}</select>
    </span>`;
}

function barraFiltros(f, clientes, p, puedeCrear) {
  const etapas = Array.isArray(p.etapas) ? p.etapas.filter(Boolean).map(String) : [];
  const etapasOpt = Array.from(new Set(etapas.concat(opcionesUnicas(clientes, 'etapa'))));
  return `
    <div class="barra-acciones">
      <div class="section-title">Clientes<span class="line"></span></div>
      ${puedeCrear ? '<button type="button" class="btn btn-accent btn-sm" id="btn-nuevo">Nuevo cliente</button>' : ''}
    </div>
    <div class="filter-row filtros-clientes">
      <input type="search" id="f-q" class="search-input" placeholder="Buscar por nombre o email…" value="${esc(f.q)}" aria-label="Buscar cliente">
      ${selectHtml('f-estado', 'Estado', [['', 'Todos'], ['vivos', 'Activos (en curso)']]
        .concat(Object.entries(ESTADO_LABEL)), f.estado)}
      ${selectHtml('f-semaforo', 'Semáforo', [['', 'Todos'], ['rojo', 'Rojo'], ['amarillo', 'Amarillo'], ['verde', 'Verde']], f.semaforo)}
      ${selectHtml('f-responsable', 'Responsable', [['', 'Todos']].concat(opcionesUnicas(clientes, 'responsable').map(v => [v, v])), f.responsable)}
      ${selectHtml('f-etapa', 'Etapa', [['', 'Todas']].concat(etapasOpt.map(v => [v, v])), f.etapa)}
      ${selectHtml('f-onb', 'Onboarding', [['', 'Todos']].concat(Object.entries(ONBOARDING_LABEL)), f.onboarding)}
      <label class="check-row check-inline"><input type="checkbox" id="f-vencer"${f.vencer ? ' checked' : ''}> Por vencer</label>
      <button type="button" class="btn btn-ghost btn-sm" id="f-limpiar">Limpiar</button>
    </div>`;
}

/* ---------- Tabla ---------- */

function tablaHtml(filas, cols, orden, total, hayFiltro) {
  if (!filas.length) {
    return `<div class="card empty-state">
        <div class="big">${total ? 'Ningún cliente coincide con los filtros' : 'Todavía no hay clientes en este programa'}</div>
        <div class="small">${total ? 'Probá con "Limpiar" para ver los ' + plural(total, 'cliente') + '.' : 'Creá el primero con "Nuevo cliente".'}</div>
      </div>`;
  }
  const th = cols.map(c => {
    const on = orden.k === c.k;
    const flecha = on ? (orden.desc ? ' ↓' : ' ↑') : '';
    return `<th class="th-sort${on ? ' th-sort-on' : ''}${c.cls === 'num' ? ' num' : ''}" data-col="${esc(c.k)}"
      scope="col" title="Ordenar por ${esc(c.lab)}">${esc(c.lab)}${flecha}</th>`;
  }).join('');

  const tr = filas.map(c => `<tr>${cols.map(col =>
    `<td class="${esc(col.cls)}" data-label="${esc(col.lab)}">${col.td(c)}</td>`).join('')}</tr>`).join('');

  return `
    <div class="card table-card tabla-clientes"><table class="data-table"><thead><tr>${th}</tr></thead><tbody>${tr}</tbody></table></div>
    <div class="table-foot">${hayFiltro ? `${filas.length} de ${plural(total, 'cliente')}` : plural(total, 'cliente')}</div>`;
}

/* ---------- Vista ---------- */

export function vistaClientes(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  const f = filtrosIniciales();
  const orden = { k: 'semaforo', desc: false };
  let p = null, clientes = [], cols = [];
  let timerBusqueda = null;

  function hayFiltro() {
    return !!(f.estado || f.semaforo || f.responsable || f.etapa || f.onboarding || f.vencer || f.q.trim());
  }

  function pintarTabla() {
    const cont = el.querySelector('#cli-tabla');
    if (!cont) return;
    const filas = ordenar(aplicar(clientes, f, p), cols, orden);
    cont.innerHTML = tablaHtml(filas, cols, orden, clientes.length, hayFiltro());
  }

  /* La barra de filtros se repinta solo cuando cambian sus opciones, para no
     perder el foco del buscador mientras se escribe. */
  function pintarTodo() {
    const foco = document.activeElement && document.activeElement.id === 'f-q';
    const pos = foco ? document.getElementById('f-q').selectionStart : null;
    el.innerHTML = barraFiltros(f, clientes, p, true) + '<div id="cli-tabla"></div>';
    conectarFiltros();
    pintarTabla();
    if (foco) {
      const inp = document.getElementById('f-q');
      inp.focus();
      if (pos != null) inp.setSelectionRange(pos, pos);
    }
  }

  function conectarFiltros() {
    const on = (id, ev, fn) => { const e = document.getElementById(id); if (e) e.addEventListener(ev, fn); };
    on('f-estado', 'change', e => { f.estado = e.target.value; pintarTabla(); });
    on('f-semaforo', 'change', e => { f.semaforo = e.target.value; pintarTabla(); });
    on('f-responsable', 'change', e => { f.responsable = e.target.value; pintarTabla(); });
    on('f-etapa', 'change', e => { f.etapa = e.target.value; pintarTabla(); });
    on('f-onb', 'change', e => { f.onboarding = e.target.value; pintarTabla(); });
    on('f-vencer', 'change', e => { f.vencer = e.target.checked; pintarTabla(); });
    on('f-q', 'input', e => {
      f.q = e.target.value;
      clearTimeout(timerBusqueda);
      timerBusqueda = setTimeout(pintarTabla, 150);
    });
    on('f-limpiar', 'click', () => {
      Object.assign(f, { estado: '', semaforo: '', responsable: '', etapa: '', onboarding: '', vencer: false, q: '' });
      pintarTodo();
    });
    on('btn-nuevo', 'click', () => abrirModalNuevoCliente(p, () => cargar().catch(e => console.error('clientes', e))));
  }

  el.addEventListener('click', ev => {
    const th = ev.target.closest('th[data-col]');
    if (!th || !el.contains(th)) return;
    const k = th.dataset.col;
    if (orden.k === k) orden.desc = !orden.desc;
    else { orden.k = k; orden.desc = false; }
    pintarTabla();
  });

  async function cargar() {
    const [prog, filas] = await Promise.all([traerPrograma(programaId), traerClientes(programaId)]);
    if (!vigente()) return;
    if (!prog) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    p = prog;
    clientes = filas;
    cols = columnas(p);
    pintarTodo();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar la lista de clientes', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('clientes', e)) };
}
