/* Panel general (#/panel), solo fundador.
   KPIs sumando los programas ACTIVOS + una tarjeta por programa.
   Fuente: cs_v_kpis_programa (semáforo, devoluciones, por vencer) y
   cs_renovaciones (conteos para la tasa global ponderada). */
import { sb } from '../supabase.js';
import { esc, fmtNum, fmtPct, badge } from '../ui.js';
import { setHeader } from '../layout.js';
import { yo, programa } from '../sesion.js';

const n = v => Number(v) || 0;

function sumar(filas, campo) {
  return filas.reduce((s, f) => s + n(f[campo]), 0);
}

function kpis(activos, renovaciones) {
  const ids = new Set(activos.map(k => k.programa_id));
  const ren = renovaciones.filter(r => ids.has(r.programa_id));
  const renovados = ren.filter(r => r.estado === 'renovado').length;
  const cerradas = ren.length;
  /* Satisfacción global = promedio ponderado por cantidad de respuestas (90 días). */
  const resp = sumar(activos, 'respuestas_90d');
  const satSuma = activos.reduce((s, k) => s + n(k.satisfaccion_prom_90d) * n(k.respuestas_90d), 0);
  return {
    clientes: sumar(activos, 'clientes_activos'),
    rojo: sumar(activos, 'clientes_rojo'),
    devPend: sumar(activos, 'dev_pendientes'),
    porVencer: sumar(activos, 'por_vencer'),
    tasaRen: cerradas ? (100 * renovados / cerradas) : null,
    cerradas,
    sat: resp ? satSuma / resp : null,
    resp
  };
}

function statCard(valor, label, { alerta = false, sub = '' } = {}) {
  return `
    <div class="stat-card${alerta ? ' stat-alerta' : ''}">
      <div class="stat-num">${valor}</div>
      <div class="stat-label">${esc(label)}</div>
      ${sub ? `<div class="stat-sub">${esc(sub)}</div>` : ''}
    </div>`;
}

function fmtSat(v) {
  return v == null ? '—' : v.toFixed(1).replace('.', ',');
}

function barraSemaforo(r, a, v) {
  const total = r + a + v;
  if (!total) return '<div class="sem-bar sem-bar-vacia"></div>';
  const seg = (c, clase) => c ? `<span class="${clase}" style="flex-grow:${c}"></span>` : '';
  return `<div class="sem-bar" role="img" aria-label="${r} en rojo, ${a} en amarillo, ${v} en verde">
      ${seg(r, 's-rojo')}${seg(a, 's-amarillo')}${seg(v, 's-verde')}
    </div>
    <div class="sem-leyenda">
      <span><span class="sem-dot sem-rojo"></span>${r}</span>
      <span><span class="sem-dot sem-amarillo"></span>${a}</span>
      <span><span class="sem-dot sem-verde"></span>${v}</span>
    </div>`;
}

function tarjeta(k) {
  const id = k.programa_id;
  const p = programa(id);
  const marca = p && p.marca;
  const color = `var(--c-${id}, var(--accent))`;
  const ruta = '#/p/' + encodeURIComponent(id);

  if (!k.activo) {
    return `
      <div class="ops-card prog-card is-inactivo">
        <div class="prog-card-head"><h3>${esc(k.nombre)}</h3>${badge('Inactivo', '', 'outline')}</div>
        <div class="niche">${esc(marca || 'Sin configurar')}</div>
        <p class="prog-card-nota">Todavía no se hace seguimiento de este programa.</p>
        <a class="btn btn-sm" href="${ruta}/config">Configurar</a>
      </div>`;
  }

  const dev = n(k.dev_pendientes);
  return `
    <a class="ops-card prog-card" href="${ruta}" style="--card-color:${esc(color)}">
      <div class="prog-card-head"><h3>${esc(k.nombre)}</h3>${badge('Activo', 'var(--sem-verde)', 'status')}</div>
      <div class="niche">${esc(marca || '')}</div>
      <div class="prog-card-kpi"><span class="stat-num">${fmtNum(n(k.clientes_activos))}</span><span>clientes activos</span></div>
      ${barraSemaforo(n(k.clientes_rojo), n(k.clientes_amarillo), n(k.clientes_verde))}
      <div class="prog-card-rows">
        <div class="prog-card-row"><span>Devoluciones pendientes</span><strong class="${dev > 0 ? 'txt-rojo' : ''}">${fmtNum(dev)}</strong></div>
        <div class="prog-card-row"><span>Por vencer</span><strong>${fmtNum(n(k.por_vencer))}</strong></div>
      </div>
    </a>`;
}

function html(filas, renovaciones) {
  const orden = new Map(yo.programas.map((p, i) => [p.id, i]));
  filas.sort((a, b) => (orden.get(a.programa_id) ?? 99) - (orden.get(b.programa_id) ?? 99));
  const activos = filas.filter(k => k.activo);
  const t = kpis(activos, renovaciones);

  const kpiHtml = `
    <div class="stat-row stat-row-6">
      ${statCard(fmtNum(t.clientes), 'Clientes activos')}
      ${statCard(fmtNum(t.rojo), 'Clientes en rojo', { alerta: t.rojo > 0 })}
      ${statCard(fmtNum(t.devPend), 'Devoluciones pendientes')}
      ${statCard(fmtNum(t.porVencer), 'Por vencer', { sub: 'Dentro del aviso de renovación' })}
      ${statCard(fmtPct(t.tasaRen), 'Tasa de renovación', { sub: t.cerradas ? `${t.cerradas} renovaciones cerradas` : 'Sin renovaciones cerradas' })}
      ${statCard(fmtSat(t.sat), 'Satisfacción (0–10)', { sub: t.resp ? `${t.resp} respuestas, últimos 90 días` : 'Sin respuestas en 90 días' })}
    </div>`;

  const tarjetas = filas.length
    ? `<div class="ops-grid prog-grid">${filas.map(tarjeta).join('')}</div>`
    : '<div class="card empty-state"><div class="big">No hay programas</div></div>';

  return `
    ${activos.length ? kpiHtml : ''}
    <div class="section-title">Programas<span class="line"></span></div>
    ${tarjetas}`;
}

/* vigente(): false si el usuario ya navegó a otra vista (evita pintar tarde). */
export function vistaPanel(el, vigente) {
  setHeader('Panel general', 'Todos los programas activos');
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';

  async function cargar() {
    const [k, r] = await Promise.all([
      sb.from('cs_v_kpis_programa').select('*'),
      sb.from('cs_renovaciones').select('programa_id,estado').in('estado', ['renovado', 'no_renovado'])
    ]);
    if (!vigente()) return;
    const error = k.error || r.error;
    if (error) {
      el.innerHTML = `<div class="card empty-state"><div class="big">No se pudo cargar el panel</div><div class="small">${esc(error.message)}</div></div>`;
      return;
    }
    el.innerHTML = html(k.data || [], r.data || []);
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = `<div class="card empty-state"><div class="big">No se pudo cargar el panel</div><div class="small">${esc(e.message || String(e))}</div></div>`;
  });
  return { refrescar: () => cargar().catch(e => console.error('panel', e)) };
}
