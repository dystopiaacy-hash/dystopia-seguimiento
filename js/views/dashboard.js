/* Dashboard del programa (#/p/:programa). Orden: lo urgente primero.
   a) KPIs (cs_v_kpis_programa)  b) Requiere atención (cs_v_clientes)
   c) Alertas no resueltas (cs_alertas).
   Nada se recalcula acá: los números, el semáforo y los motivos vienen de las vistas. */
import { esc, fmtNum, fmtPct, fmtFecha, fmtHoras, plural, toast } from '../ui.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerKpis, traerClientes, traerAlertas, traerDevolucionesAbiertas, resolverAlerta,
  atrasoPorCliente, mensajeError, etiquetaUsuario, esVivo, ALERTA_LABEL, nivelAlerta
} from '../datos.js';

const n = v => Number(v) || 0;
const nn = v => (v == null || v === '' ? null : Number(v));

/* ---------- KPIs ---------- */

/* subs = [[texto, clase]] */
function kpi({ valor, label, subs = [], alerta = false, href = '' }) {
  const cuerpo = `
    <div class="stat-num">${valor}</div>
    <div class="stat-label">${esc(label)}</div>
    ${subs.filter(Boolean).map(([t, c]) => `<div class="stat-sub${c ? ' ' + c : ''}">${esc(t)}</div>`).join('')}`;
  const clase = 'stat-card' + (alerta ? ' stat-alerta' : '') + (href ? ' stat-nav' : '');
  return href
    ? `<a class="${clase}" href="${esc(href)}">${cuerpo}</a>`
    : `<div class="${clase}">${cuerpo}</div>`;
}

function fmtSat(v) {
  return v == null ? '—' : Number(v).toFixed(1).replace('.', ',');
}

function fmtNps(v) {
  return v == null ? '—' : (v > 0 ? '+' : '') + Math.round(v);
}

/* Onboardings pendientes que ya pasaron el SLA del programa. La vista de KPIs da el
   total de pendientes pero no cuántos están demorados: se cuenta sobre cs_v_clientes
   con el mismo criterio que usa el semáforo (dias_transcurridos > sla_onboarding_dias). */
function onboardingDemorados(clientes, p) {
  return clientes.filter(c => esVivo(c)
    && c.onboarding_estado === 'pendiente_agendar'
    && n(c.dias_transcurridos) > n(p.sla_onboarding_dias)).length;
}

function filaKpis(k, clientes, p) {
  const base = '#/p/' + encodeURIComponent(p.id);
  const demorados = onboardingDemorados(clientes, p);
  const devPend = n(k.dev_pendientes);
  const accVenc = n(k.acc_bpf_vencidos);
  const resp = n(k.respuestas_90d);
  const sat = nn(k.satisfaccion_prom_90d);

  return `
    <div class="stat-row stat-row-kpi">
      ${kpi({
        valor: fmtNum(n(k.clientes_activos)), label: 'Clientes activos',
        subs: [['Onboarding, activos y en renovación']],
        href: base + '/clientes?estado=vivos'
      })}
      ${kpi({
        valor: fmtNum(n(k.onboarding_pendientes)), label: 'Onboarding pendientes',
        subs: [demorados ? [`${plural(demorados, 'demorado')} (pasó el SLA de ${plural(n(p.sla_onboarding_dias), 'día')})`, 'txt-rojo'] : ['Dentro del SLA']],
        alerta: demorados > 0,
        href: base + '/clientes?onboarding=pendiente_agendar'
      })}
      ${kpi({
        valor: fmtNum(n(k.acc_bpf_pendientes)), label: 'Accionables BPF pendientes',
        subs: [accVenc ? [`${plural(accVenc, 'vencido')}`, 'txt-rojo'] : ['Ninguno vencido']],
        alerta: accVenc > 0,
        href: base + '/accionables?responsable=bpf'
      })}
      ${kpi({
        valor: fmtNum(n(k.acc_cliente_pendientes)), label: 'Accionables cliente pendientes',
        href: base + '/accionables?responsable=cliente'
      })}
      ${kpi({
        valor: `${fmtNum(devPend)}${k.pct_dev_pendientes != null ? ` · ${fmtPct(k.pct_dev_pendientes, 0)}` : ''}`,
        label: 'Devoluciones pendientes',
        subs: [[`Entregadas: ${fmtNum(n(k.dev_entregadas))}${k.pct_dev_entregadas != null ? ` (${fmtPct(k.pct_dev_entregadas, 0)})` : ''}`]],
        alerta: devPend > 0,
        href: base + '/devoluciones'
      })}
      ${kpi({
        valor: fmtNum(n(k.por_vencer)), label: 'Por vencer',
        subs: [[`Vencen dentro de ${plural(n(p.aviso_renovacion_dias), 'día')}`]],
        href: base + '/clientes?vencer=1'
      })}
      ${kpi({
        valor: fmtPct(k.tasa_renovacion, 0), label: 'Tasa de renovación',
        subs: [[k.tasa_renovacion == null ? 'Sin renovaciones cerradas' : 'Sobre renovaciones cerradas']],
        href: base + '/renovaciones'
      })}
      ${kpi({
        valor: fmtSat(sat), label: 'Satisfacción 90 días (0–10)',
        subs: [
          [`NPS ${fmtNps(nn(k.nps_90d))} · n = ${plural(resp, 'respuesta')}`],
          resp > 0 && resp < 5 ? ['Muestra chica', 'txt-gris'] : (resp ? null : ['Sin respuestas en 90 días', 'txt-gris'])
        ],
        href: base + '/metricas'
      })}
    </div>`;
}

/* ---------- Requiere atención ---------- */

/* Antigüedad del problema, en HORAS (el atraso de una devolución se mide en horas y
   puede ser menor a un día): días vencido del programa, días de más sin chequeo, días
   de más sin agendar el onboarding y el atraso de las devoluciones fuera de SLA, que
   sale de cs_devoluciones con la misma función que usan la ficha y el tablero. */
function antiguedad(c, p, atrasos) {
  const v = [0, atrasos.get(c.id) || 0];
  if (c.dias_restantes != null && c.dias_restantes < 0) v.push(-n(c.dias_restantes) * 24);
  if (c.dias_sin_chequeo != null) v.push((n(c.dias_sin_chequeo) - n(p.dias_sin_chequeo_alerta)) * 24);
  if (c.onboarding_estado === 'pendiente_agendar') v.push((n(c.dias_transcurridos) - n(p.sla_onboarding_dias)) * 24);
  return Math.max(...v);
}

function filaAtencion(c, p, atrasos) {
  const motivos = Array.isArray(c.motivos_semaforo) ? c.motivos_semaforo : [];
  const horas = antiguedad(c, p, atrasos);
  return `
    <a class="aten-row" href="#/p/${encodeURIComponent(p.id)}/c/${encodeURIComponent(c.id)}">
      <span class="sem-dot sem-${esc(c.semaforo)}" title="${esc(c.semaforo === 'rojo' ? 'Rojo: hay que actuar ya' : 'Amarillo: mirar pronto')}"></span>
      <span class="aten-nombre">${esc(c.nombre)}</span>
      <span class="aten-motivos">${motivos.length ? motivos.map(esc).join(' · ') : 'Sin motivos registrados'}</span>
      <span class="aten-dias" title="Antigüedad del problema más viejo">${horas >= 1 ? esc(fmtHoras(horas)) : ''}</span>
      <span class="aten-ir">Ver ficha →</span>
    </a>`;
}

function bloqueAtencion(clientes, p, atrasos) {
  const orden = { rojo: 0, amarillo: 1 };
  const filas = clientes
    .filter(c => esVivo(c) && (c.semaforo === 'rojo' || c.semaforo === 'amarillo'))
    .sort((a, b) =>
      (orden[a.semaforo] - orden[b.semaforo]) ||
      (antiguedad(b, p, atrasos) - antiguedad(a, p, atrasos)) ||
      a.nombre.localeCompare(b.nombre, 'es'));

  const rojos = filas.filter(c => c.semaforo === 'rojo').length;
  const cuerpo = filas.length
    ? `<div class="aten-list">${filas.map(c => filaAtencion(c, p, atrasos)).join('')}</div>`
    : '<div class="muted-empty">Ningún cliente en rojo ni en amarillo. Todo al día.</div>';

  return `
    <div class="section-title">Requiere atención
      ${filas.length ? `<span class="aten-cuenta${rojos ? ' txt-rojo' : ''}">${plural(filas.length, 'cliente')}${rojos ? ` · ${rojos} en rojo` : ''}</span>` : ''}
      <span class="line"></span>
    </div>
    <div class="card card-list">${cuerpo}</div>`;
}

/* ---------- Alertas ---------- */

function filaAlerta(a) {
  const nivel = nivelAlerta(a.tipo);
  return `
    <div class="alerta-row" data-alerta="${esc(a.id)}">
      <span class="sem-dot sem-${nivel}"></span>
      <span class="alerta-cuerpo">
        <span class="alerta-tipo">${esc(ALERTA_LABEL[a.tipo] || a.tipo)}</span>
        <span class="alerta-msg">${esc(a.mensaje || 'Sin detalle')}</span>
        <span class="alerta-meta">${esc(fmtFecha(a.created_at))} · generada por ${esc(etiquetaUsuario(a.created_by))}</span>
      </span>
      <button type="button" class="btn btn-sm" data-resolver="${esc(a.id)}">Resolver</button>
    </div>`;
}

function bloqueAlertas(alertas) {
  const cuerpo = alertas.length
    ? alertas.map(filaAlerta).join('')
    : '<div class="muted-empty">No hay alertas sin resolver.</div>';
  return `
    <div class="section-title">Alertas
      ${alertas.length ? `<span class="aten-cuenta">${plural(alertas.length, 'sin resolver', 'sin resolver')}</span>` : ''}
      <span class="line"></span>
    </div>
    <div class="card card-list">${cuerpo}</div>`;
}

/* ---------- Vista ---------- */

function html(p, k, clientes, alertas, atrasos) {
  const kpis = k
    ? filaKpis(k, clientes, p)
    : '<div class="card empty-state"><div class="big">Sin KPIs todavía</div><div class="small">Este programa no devolvió datos de seguimiento.</div></div>';
  return kpis + bloqueAtencion(clientes, p, atrasos) + bloqueAlertas(alertas);
}

export function vistaDashboard(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';

  async function cargar() {
    const [p, k, clientes, alertas, devs] = await Promise.all([
      traerPrograma(programaId), traerKpis(programaId),
      traerClientes(programaId), traerAlertas(programaId), traerDevolucionesAbiertas(programaId)
    ]);
    if (!vigente()) return;
    if (!p) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    el.innerHTML = html(p, k, clientes, alertas, atrasoPorCliente(devs, p.sla_devolucion_horas));
  }

  el.onclick = async ev => {
    const btn = ev.target.closest('[data-resolver]');
    if (!btn) return;
    btn.disabled = true;
    try {
      await resolverAlerta(btn.dataset.resolver);
      toast('Alerta resuelta.');
      cargar().catch(e => console.error('dashboard', e));
    } catch (e) {
      btn.disabled = false;
      toast('No se pudo resolver: ' + mensajeError(e), 'error');
    }
  };

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar el dashboard', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('dashboard', e)) };
}
