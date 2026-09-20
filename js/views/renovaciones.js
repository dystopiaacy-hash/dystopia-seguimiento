/* Renovaciones del programa (#/p/:programa/renovaciones).
   Tres bloques en orden de urgencia: "Iniciar renovación" (por vencer y nadie
   las tocó, en rojo), "En proceso" y "Cerradas". Arriba, la tasa de renovación.
   El cierre (renovó / no renovó) sale por modal y lo hacen los triggers de 001:
   acá solo se actualiza la fila de cs_renovaciones. */
import {
  esc, plural, toast, fmtFecha, fmtFechaHora, fmtPct, sumarDias, hoyAR, diasRestantes,
  abrirModal, confirmar
} from '../ui.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerKpis, traerClientes, traerRenovacionesPrograma,
  iniciarRenovacion, cerrarRenovacion, tasaRenovacion, armarMotivo,
  mensajeError, MOTIVO_NO_RENOVACION, ESTADO_LABEL
} from '../datos.js';
import { guardar, linkCliente, mapaPorId, badgeRen, opcionesHtml, num } from './comunes.js';

const DIAS_TRIMESTRE = 90;

/* ---------- Selección de cada bloque ---------- */

/* Mismo criterio que el semáforo de cs_v_clientes (r_ren): está en la ventana
   de aviso y nadie inició la renovación ni la cerró como no renovada. */
function porIniciar(clientes, avisoDias) {
  return clientes
    .filter(c => !['finalizado', 'baja'].includes(c.estado)
      && c.dias_restantes != null && c.dias_restantes <= num(avisoDias)
      && !['en_proceso', 'no_renovado'].includes(c.renovacion_estado || ''))
    .sort((a, b) => num(a.dias_restantes) - num(b.dias_restantes));
}

function enProceso(renovaciones) {
  return renovaciones.filter(r => r.estado === 'en_proceso');
}

function cerradas(renovaciones) {
  return renovaciones
    .filter(r => r.estado === 'renovado' || r.estado === 'no_renovado')
    .sort((a, b) => String(b.resultado_at || '').localeCompare(String(a.resultado_at || '')));
}

/* ---------- Piezas ---------- */

/* "Vence en 5 días" / "Venció hace 3 días". Rojo si ya venció o vence hoy. */
function textoDias(dias) {
  if (dias == null) return '<span class="txt-gris">Sin fecha</span>';
  if (dias < 0) return `<span class="txt-rojo">Venció hace ${esc(plural(-dias, 'día'))}</span>`;
  if (dias === 0) return '<span class="txt-rojo">Vence hoy</span>';
  return `<span class="${dias <= 7 ? 'txt-amarillo' : ''}">Vence en ${esc(plural(dias, 'día'))}</span>`;
}

function tarjetaTasa(titulo, t, detalle) {
  return `
    <div class="card stat-card">
      <div class="stat-num">${t ? esc(fmtPct(t.pct, 1)) : '—'}</div>
      <div class="stat-label">${esc(titulo)}</div>
      <div class="stat-sub">${t ? esc(`${t.ren} renovó · ${t.noren} no renovó`) : esc(detalle)}</div>
    </div>`;
}

function filaPorIniciar(programaId, c) {
  return `
    <div class="ren-item ren-urgente">
      <span class="ren-cli">${linkCliente(programaId, c)}</span>
      <span class="ren-detalle">${textoDias(c.dias_restantes)} · fin ${esc(fmtFecha(c.fecha_fin))}
        · ${esc(ESTADO_LABEL[c.estado] || c.estado)}</span>
      <button type="button" class="btn btn-sm btn-accent" data-ren-iniciar="${esc(c.id)}">Iniciar renovación</button>
    </div>`;
}

function filaEnProceso(programaId, r, cliente) {
  const dias = cliente ? cliente.dias_restantes : null;
  return `
    <div class="ren-item ren-curso">
      <span class="ren-cli">${linkCliente(programaId, cliente)}</span>
      <span class="ren-detalle">Abierta el ${esc(fmtFechaHora(r.iniciada_at))} · ${textoDias(dias)}</span>
      <button type="button" class="btn btn-sm btn-accent" data-ren-cerrar="${esc(r.id)}">Cerrar renovación</button>
    </div>`;
}

function filaCerrada(programaId, r, cliente) {
  const detalle = [
    `Cerrada el ${fmtFecha(r.resultado_at)}`,
    r.nueva_fecha_fin ? `nueva fecha de fin ${fmtFecha(r.nueva_fecha_fin)}` : ''
  ].filter(Boolean).join(' · ');
  return `
    <div class="ren-item">
      <span class="ren-cli">${linkCliente(programaId, cliente)}</span>
      <span class="ren-badge">${badgeRen(r.estado)}</span>
      <span class="ren-detalle">${esc(detalle)}</span>
      ${r.motivo ? `<span class="ren-motivo">${esc(r.motivo)}</span>` : ''}
    </div>`;
}

function bloque(titulo, cuenta, vacio, filas, clase = '') {
  return `
    <div class="section-title">${esc(titulo)}
      <span class="aten-cuenta${clase}">${esc(cuenta)}</span>
      <span class="line"></span>
    </div>
    <div class="card card-list ren-lista">
      ${filas.length ? filas.join('') : `<div class="muted-empty">${esc(vacio)}</div>`}
    </div>`;
}

/* ---------- Modal de cierre ---------- */

/* r = fila de cs_renovaciones en proceso; cliente = fila de cs_v_clientes;
   prog = fila de cs_programas (para la duración por defecto).
   alGuardar() se llama después de cerrar bien (para refrescar quien la abrió). */
export function modalCerrarRenovacion(r, cliente, prog, alGuardar) {
  const base = (cliente && cliente.fecha_fin) || hoyAR();
  const porDefecto = sumarDias(base, num(prog && prog.duracion_default_dias) || 90);
  const nombre = cliente ? cliente.nombre : 'este cliente';

  const m = abrirModal({
    titulo: 'Cerrar renovación',
    cuerpo: `
      <p class="conf-detalle">${esc(nombre)} · fin actual ${esc(fmtFecha(base))}</p>
      <div class="form-row"><label for="rc-resultado">Resultado</label>
        <select id="rc-resultado">
          <option value="renovado">Renovó</option>
          <option value="no_renovado">No renovó</option>
        </select></div>
      <div id="rc-bloque-fin">
        <div class="form-row"><label for="rc-fin">Nueva fecha de fin</label>
          <input type="date" id="rc-fin" value="${esc(porDefecto)}">
          <div class="hint">Por defecto, fin actual + ${esc(plural(num(prog && prog.duracion_default_dias) || 90, 'día'))}
            (duración del programa).</div></div>
      </div>
      <div id="rc-bloque-motivo" hidden>
        <div class="form-row"><label for="rc-motivo">Motivo</label>
          <select id="rc-motivo">${opcionesHtml(Object.entries(MOTIVO_NO_RENOVACION), 'precio')}</select></div>
        <div class="form-row"><label for="rc-texto">Detalle</label>
          <textarea id="rc-texto" maxlength="500" placeholder="Qué dijo el cliente"></textarea>
          <div class="hint">Con "Otro", el detalle es obligatorio.</div></div>
      </div>`,
    pie: `<button type="button" class="btn" data-rc="0">Cancelar</button>
          <button type="button" class="btn btn-accent" data-rc="1">Guardar cierre</button>`
  });

  const $ = id => m.el.querySelector('#' + id);
  const resultado = $('rc-resultado');
  const sincronizar = () => {
    const renovo = resultado.value === 'renovado';
    $('rc-bloque-fin').hidden = !renovo;
    $('rc-bloque-motivo').hidden = renovo;
  };
  resultado.addEventListener('change', sincronizar);
  sincronizar();

  m.el.querySelector('[data-rc="0"]').addEventListener('click', () => m.cerrar());
  const aceptar = m.el.querySelector('[data-rc="1"]');
  aceptar.addEventListener('click', async () => {
    const estado = resultado.value;
    let cambios;

    if (estado === 'renovado') {
      const fin = $('rc-fin').value;
      if (!fin) { toast('Poné la nueva fecha de fin.', 'error'); return; }
      if (diasRestantes(fin) <= 0) { toast('La nueva fecha de fin tiene que ser posterior a hoy.', 'error'); return; }
      if (cliente && cliente.fecha_inicio && fin < cliente.fecha_inicio) {
        toast('La nueva fecha de fin no puede ser anterior al inicio del programa.', 'error');
        return;
      }
      cambios = { estado, nuevaFechaFin: fin };
    } else {
      const clave = $('rc-motivo').value;
      const texto = $('rc-texto').value;
      if (clave === 'otro' && !texto.trim()) { toast('Con "Otro", escribí el motivo.', 'error'); return; }
      cambios = { estado, motivo: armarMotivo(clave, texto) };
    }

    const r2 = await guardar(() => cerrarRenovacion(r.id, cambios), {
      ok: estado === 'renovado' ? 'Renovación cerrada: renovó.' : 'Renovación cerrada: no renovó.',
      luego: alGuardar,
      control: aceptar
    });
    if (r2 !== null) m.cerrar();
  });
  aceptar.focus();
}

/* ---------- Vista ---------- */

export function vistaRenovaciones(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let prog = null, kpis = null, clientes = [], renovaciones = [], mapaClientes = new Map();

  function pintar() {
    const aIniciar = porIniciar(clientes, prog.aviso_renovacion_dias);
    const abiertas = enProceso(renovaciones);
    const hechas = cerradas(renovaciones);
    const historica = kpis && kpis.tasa_renovacion != null
      ? { pct: Number(kpis.tasa_renovacion), ren: hechas.filter(r => r.estado === 'renovado').length,
          noren: hechas.filter(r => r.estado === 'no_renovado').length }
      : null;
    const trimestre = tasaRenovacion(renovaciones, new Date(Date.now() - DIAS_TRIMESTRE * 86400000).toISOString());

    el.innerHTML = `
      <div class="grid-2 ren-tasas">
        ${tarjetaTasa('Tasa de renovación histórica', historica, 'Todavía no hay renovaciones cerradas')}
        ${tarjetaTasa(`Último trimestre (${DIAS_TRIMESTRE} días)`, trimestre, 'Ninguna cerrada en el trimestre')}
      </div>
      ${bloque('Iniciar renovación',
        aIniciar.length ? plural(aIniciar.length, 'cliente por vencer') : 'Ninguno por vencer',
        `Ningún cliente entra en la ventana de aviso (${plural(num(prog.aviso_renovacion_dias), 'día')} antes del fin).`,
        aIniciar.map(c => filaPorIniciar(programaId, c)),
        aIniciar.length ? ' txt-rojo' : '')}
      ${bloque('En proceso',
        abiertas.length ? plural(abiertas.length, 'abierta') : 'Ninguna abierta',
        'No hay renovaciones en proceso.',
        abiertas.map(r => filaEnProceso(programaId, r, mapaClientes.get(r.cliente_id))))}
      ${bloque('Cerradas',
        hechas.length ? plural(hechas.length, 'cerrada') : 'Ninguna cerrada',
        'Todavía no se cerró ninguna renovación.',
        hechas.map(r => filaCerrada(programaId, r, mapaClientes.get(r.cliente_id))))}`;
  }

  const recargar = () => cargar().catch(e => toast(mensajeError(e), 'error'));

  el.addEventListener('click', async ev => {
    const bIniciar = ev.target.closest('[data-ren-iniciar]');
    if (bIniciar) {
      const c = mapaClientes.get(bIniciar.dataset.renIniciar);
      if (!c) return;
      const ok = await confirmar({
        titulo: 'Iniciar proceso de renovación',
        texto: `Se abre una renovación en proceso para ${c.nombre}.`,
        detalle: 'El cliente pasa a estado "En renovación" hasta que la cierres.',
        ok: 'Iniciar', peligro: false
      });
      if (!ok) return;
      await guardar(() => iniciarRenovacion(c), {
        ok: 'Renovación iniciada.', luego: recargar, control: bIniciar
      });
      return;
    }

    const bCerrar = ev.target.closest('[data-ren-cerrar]');
    if (bCerrar) {
      const r = renovaciones.find(x => x.id === bCerrar.dataset.renCerrar);
      if (!r) return;
      modalCerrarRenovacion(r, mapaClientes.get(r.cliente_id), prog, recargar);
    }
  });

  async function cargar() {
    const [p, k, cls, rens] = await Promise.all([
      traerPrograma(programaId), traerKpis(programaId),
      traerClientes(programaId), traerRenovacionesPrograma(programaId)
    ]);
    if (!vigente()) return;
    if (!p) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    prog = p; kpis = k; clientes = cls; renovaciones = rens;
    mapaClientes = mapaPorId(cls);
    pintar();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las renovaciones', mensajeError(e));
  });
  return { refrescar: () => cargar().catch(e => console.error('renovaciones', e)) };
}
