/* Revisión del programa (#/p/:programa/revision): el chequeo guiado.
   Dos modos: "Diario" (rojos, amarillos y los que nadie chequea hace mucho) y
   "Semanal completo" (todos los clientes vivos, los lunes).
   Recorre un cliente por vez y muestra por qué está así, qué tiene abierto y
   cuál es la próxima acción. "Chequeado" inserta en cs_chequeos: el trigger de
   001 es el que mueve ultimo_chequeo_at del cliente.
   El progreso del día vive en memoria (ver PROGRESO): si se recarga, arranca de
   nuevo, y eso está bien: la revisión es de una sentada. */
import {
  esc, badge, plural, fmtFecha, fmtFechaHora, hoyAR, diasRestantes
} from '../ui.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerClientes, traerAccionablesPrograma, traerDevolucionesAbiertas,
  registrarChequeo, horasAtraso, mensajeError, esVivo, ESTADO_LABEL, ESTADO_COLOR
} from '../datos.js';
import {
  guardar, num, badgeAcc, badgeDev, celdaVence, pillEspera, mapaPorId,
  repintarConservandoFoco
} from './comunes.js';

/* ---------- Progreso del día (memoria, no base) ---------- */
/* programaId|modo -> { dia, hechos:Set, saltados:Set }. Se descarta al cambiar de
   día de negocio, así el lunes la revisión empieza limpia sin tocar la base. */
const PROGRESO = new Map();
const MODOS = new Map();   // programaId -> 'diario' | 'semanal'

function progreso(programaId, modo) {
  const clave = programaId + '|' + modo;
  const dia = hoyAR();
  let e = PROGRESO.get(clave);
  if (!e || e.dia !== dia) {
    e = { dia, orden: [], hechos: new Set(), saltados: new Set() };
    PROGRESO.set(clave, e);
  }
  return e;
}

/* ---------- Cola de revisión ---------- */

const ORDEN_SEM = { rojo: 0, amarillo: 1, verde: 2, gris: 3 };

/* El más descuidado primero dentro de cada color: ordena por días sin chequeo. */
function ordenar(a, b) {
  return (ORDEN_SEM[a.semaforo] ?? 9) - (ORDEN_SEM[b.semaforo] ?? 9)
    || num(b.dias_sin_chequeo) - num(a.dias_sin_chequeo)
    || String(a.nombre).localeCompare(String(b.nombre), 'es');
}

/* Diario: rojos, amarillos y —por si el semáforo no lo marcó— los que pasaron el
   umbral de días sin chequeo. Semanal: todos los vivos. */
function armarCola(clientes, p, modo) {
  const vivos = (clientes || []).filter(esVivo);
  if (modo === 'semanal') return vivos.slice().sort(ordenar);
  const umbral = num(p.dias_sin_chequeo_alerta);
  return vivos
    .filter(c => c.semaforo === 'rojo' || c.semaforo === 'amarillo'
      || num(c.dias_sin_chequeo) > umbral)
    .sort(ordenar);
}

/* La cola del día se congela: al chequear un cliente deja de estar en amarillo y
   saldría de la cola, y la barra de progreso iría para atrás. Entonces el orden
   se guarda una vez (e.orden) y después solo se le suman los que aparecen; nadie
   se va salvo que deje de ser un cliente vivo. */
function colaEstable(clientes, prog, modo, e, mapa) {
  for (const c of armarCola(clientes, prog, modo)) {
    if (!e.orden.includes(c.id)) e.orden.push(c.id);
  }
  return e.orden.map(id => mapa.get(id)).filter(c => c && esVivo(c));
}

/* ---------- Próxima acción sugerida ---------- */

/* Una sola frase, la más urgente. Mismo orden de prioridad que el semáforo de
   cs_v_clientes: devolución fuera de SLA, accionable BPF vencido, onboarding
   sin agendar, renovación, accionable del cliente, devolución en curso, chequeo. */
function proximaAccion(c, p, accs, devs) {
  const fuera = devs.filter(d => num(horasAtraso(d, p.sla_devolucion_horas)) > 0);
  if (fuera.length) return `Entregar la devolución de "${fuera[0].titulo}" (fuera de SLA)`;

  /* El título del accionable ya es la acción ("Agendar call de onboarding"):
     se muestra tal cual, sin envolverlo en "cerrar el accionable". */
  const bpfVenc = accs.filter(a => a.responsable === 'bpf' && a.vence && diasRestantes(a.vence) < 0);
  if (bpfVenc.length) return `${bpfVenc[0].titulo} (venció el ${fmtFecha(bpfVenc[0].vence)})`;

  if (c.onboarding_estado === 'pendiente_agendar') {
    return 'Agendar la call de onboarding';
  }
  if (c.dias_restantes != null && num(c.dias_restantes) <= num(p.aviso_renovacion_dias)
      && !['en_proceso', 'no_renovado'].includes(c.renovacion_estado || '')) {
    return num(c.dias_restantes) < 0
      ? `Iniciar la renovación (venció hace ${plural(-num(c.dias_restantes), 'día')})`
      : `Iniciar la renovación (vence en ${plural(num(c.dias_restantes), 'día')})`;
  }
  if (c.renovacion_estado === 'en_proceso') {
    return c.dias_restantes == null
      ? 'Cerrar la renovación: renovó o no renovó'
      : `Cerrar la renovación: renovó o no renovó (vence en ${plural(num(c.dias_restantes), 'día')})`;
  }

  const cliVenc = accs.filter(a => a.responsable === 'cliente' && a.vence && diasRestantes(a.vence) < 0);
  if (cliVenc.length) return `Pedirle al cliente que resuelva "${cliVenc[0].titulo}" (vencido)`;
  if (devs.length) return `Entregar la devolución de "${devs[0].titulo}" (dentro de SLA)`;
  if (num(c.dias_sin_chequeo) > num(p.dias_sin_chequeo_alerta)) {
    return `Escribirle al cliente para saber cómo viene (${plural(num(c.dias_sin_chequeo), 'día')} sin chequeo)`;
  }
  return 'Nada urgente: dejá una nota del estado y seguí';
}

/* ---------- Piezas ---------- */

function barraProgreso(hechos, saltados, total) {
  const vistos = hechos + saltados;
  const pct = total ? Math.round((100 * vistos) / total) : 0;
  return `
    <div class="card rev-progreso">
      <div class="rev-progreso-top">
        <strong>${vistos} de ${total}</strong>
        <span>${esc(`${plural(hechos, 'chequeado')} · ${saltados} saltado${saltados === 1 ? '' : 's'}`)}</span>
        <span class="rev-pct">${pct}%</span>
      </div>
      <span class="prog-track"><span class="prog-fill rev-fill" style="width:${pct}%"></span></span>
      <div class="hint">El progreso del día se guarda mientras la pestaña esté abierta. Si recargás, arranca de nuevo.</div>
    </div>`;
}

function listaAbiertos(titulo, filas) {
  if (!filas.length) return '';
  return `<div class="rev-sub"><div class="rev-sub-tit">${esc(titulo)}</div>${filas.join('')}</div>`;
}

function filaAccionable(a) {
  return `<div class="rev-linea">
      ${badgeAcc(a.estado)}
      <span class="rev-linea-tit">${esc(a.titulo)}</span>
      <span class="rev-linea-meta">${esc(a.responsable === 'bpf' ? 'BPF' : 'Cliente')} · ${celdaVence(a)}</span>
    </div>`;
}

function filaDevolucion(d, slaHoras) {
  return `<div class="rev-linea">
      ${badgeDev(d.estado)}
      <span class="rev-linea-tit">${esc(d.titulo)}</span>
      <span class="rev-linea-meta">${pillEspera(d, slaHoras)}</span>
    </div>`;
}

function tarjetaCliente(c, p, accs, devs, marca) {
  const motivos = Array.isArray(c.motivos_semaforo) ? c.motivos_semaforo : [];
  const ficha = `#/p/${encodeURIComponent(p.id)}/c/${encodeURIComponent(c.id)}`;
  const chequeo = c.ultimo_chequeo_at
    ? `Último chequeo: ${fmtFechaHora(c.ultimo_chequeo_at)} (hace ${plural(num(c.dias_sin_chequeo), 'día')})`
    : 'Nunca se chequeó';
  return `
    <div class="card rev-cliente">
      <div class="rev-cab">
        <span class="sem-dot sem-${esc(c.semaforo)}"></span>
        <a class="rev-nombre" href="${ficha}">${esc(c.nombre)}</a>
        ${badge(ESTADO_LABEL[c.estado] || c.estado, ESTADO_COLOR[c.estado], 'status')}
        ${marca ? `<span class="rev-marca">${esc(marca)}</span>` : ''}
        <span class="rev-cab-meta">${esc(chequeo)}</span>
      </div>
      <div class="rev-datos">
        <span>Fin ${esc(fmtFecha(c.fecha_fin))}</span>
        <span>${c.dias_restantes == null ? 'Sin fecha' : num(c.dias_restantes) < 0
          ? esc(`Venció hace ${plural(-num(c.dias_restantes), 'día')}`)
          : esc(`Faltan ${plural(num(c.dias_restantes), 'día')}`)}</span>
        <span>${esc(num(c.pct_programa))}% del programa</span>
        ${c.etapa ? `<span>Etapa: ${esc(c.etapa)}</span>` : ''}
      </div>

      <div class="rev-motivos">
        <div class="rev-sub-tit">Por qué está en ${esc(c.semaforo)}</div>
        ${motivos.length
          ? `<ul class="rev-motivos-lista">${motivos.map(m => `<li>${esc(m)}</li>`).join('')}</ul>`
          : '<div class="muted-empty">Sin motivos: está en verde.</div>'}
      </div>

      <div class="rev-accion">
        <span class="rev-accion-lab">Próxima acción</span>
        <span class="rev-accion-txt">${esc(proximaAccion(c, p, accs, devs))}</span>
      </div>

      ${listaAbiertos(`Accionables abiertos (${accs.length})`, accs.slice(0, 6).map(filaAccionable))}
      ${listaAbiertos(`Devoluciones pendientes (${devs.length})`, devs.slice(0, 6).map(d => filaDevolucion(d, p.sla_devolucion_horas)))}
      ${!accs.length && !devs.length ? '<div class="muted-empty">Sin accionables ni devoluciones abiertas.</div>' : ''}

      <div class="form-row rev-nota">
        <label for="rev-nota-campo">Nota del chequeo (opcional)</label>
        <textarea id="rev-nota-campo" maxlength="500" placeholder="Qué pasó, qué quedó pendiente"></textarea>
      </div>
      <div class="rev-botones">
        <button type="button" class="btn btn-accent" data-rev="chequeado">Chequeado</button>
        <button type="button" class="btn" data-rev="saltar">Saltar</button>
        <a class="btn" href="${ficha}">Abrir ficha</a>
      </div>
    </div>`;
}

function tarjetaFin(cola, hechos, saltados, modo) {
  const titulo = cola.length ? 'Revisión terminada' : (modo === 'semanal'
    ? 'No hay clientes vivos para revisar'
    : 'Nada para revisar hoy');
  const detalle = cola.length
    ? `${plural(hechos, 'cliente chequeado')} y ${saltados} saltado${saltados === 1 ? '' : 's'}.`
    : (modo === 'semanal'
      ? 'Este programa no tiene clientes en onboarding, activos ni en renovación.'
      : 'Ningún cliente en rojo ni en amarillo, y ninguno pasó el umbral de días sin chequeo.');
  return `<div class="card empty-state">
      <div class="big">${esc(titulo)}</div>
      <div class="small">${esc(detalle)}</div>
      ${cola.length ? '<div class="rev-botones rev-botones-fin"><button type="button" class="btn" data-rev="reiniciar">Volver a empezar</button></div>' : ''}
    </div>`;
}

function filaCola(c, e, actualId) {
  const estado = e.hechos.has(c.id) ? 'hecho' : e.saltados.has(c.id) ? 'saltado' : 'pendiente';
  const texto = { hecho: '✓ Chequeado', saltado: '→ Saltado', pendiente: 'Pendiente' }[estado];
  return `<button type="button" class="rev-cola-fila is-${estado}${c.id === actualId ? ' is-actual' : ''}" data-ir="${esc(c.id)}">
      <span class="sem-dot sem-${esc(c.semaforo)}"></span>
      <span class="rev-cola-nombre">${esc(c.nombre)}</span>
      <span class="rev-cola-estado">${esc(texto)}</span>
    </button>`;
}

/* ---------- Vista ---------- */

export function vistaRevision(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let prog = null, clientes = [], porCliente = new Map(), devPorCliente = new Map();
  let mapaClientes = new Map();
  let actualId = null;

  const modo = () => MODOS.get(programaId) || 'diario';

  function siguientePendiente(cola, e, desde = 0) {
    for (let i = desde; i < cola.length; i++) {
      const c = cola[i];
      if (!e.hechos.has(c.id) && !e.saltados.has(c.id)) return c.id;
    }
    return null;
  }

  function pintar() {
    const e = progreso(programaId, modo());
    const cola = colaEstable(clientes, prog, modo(), e, mapaClientes);
    const idx = cola.findIndex(c => c.id === actualId);
    if (idx === -1) actualId = siguientePendiente(cola, e);
    const actual = actualId ? cola.find(c => c.id === actualId) : null;
    /* Se cuentan contra la cola visible: así el total y el avance no se pelean. */
    const hechos = cola.filter(c => e.hechos.has(c.id)).length;
    const saltados = cola.filter(c => e.saltados.has(c.id)).length;

    const tabs = `
      <div class="tabs tabs-inline rev-modos" role="tablist" aria-label="Modo de revisión">
        <button type="button" class="tab-btn${modo() === 'diario' ? ' active' : ''}" data-modo="diario"
          role="tab" aria-selected="${modo() === 'diario'}">Diario</button>
        <button type="button" class="tab-btn${modo() === 'semanal' ? ' active' : ''}" data-modo="semanal"
          role="tab" aria-selected="${modo() === 'semanal'}">Semanal completo</button>
      </div>`;

    const explica = modo() === 'diario'
      ? `Rojos y amarillos, y los que nadie chequea hace más de ${plural(num(prog.dias_sin_chequeo_alerta), 'día')}. 5 a 10 minutos.`
      : 'Todos los clientes vivos, uno por uno. Pensado para los lunes.';

    el.innerHTML = `
      <div class="barra-acciones rev-barra">
        <div class="section-title">Revisión del ${esc(fmtFecha(hoyAR()))}<span class="line"></span></div>
        ${tabs}
      </div>
      <div class="hint rev-explica">${esc(explica)}</div>
      ${barraProgreso(hechos, saltados, cola.length)}
      <div class="rev-grid">
        <div class="rev-col-principal">
          ${actual
            ? tarjetaCliente(actual, prog, porCliente.get(actual.id) || [], devPorCliente.get(actual.id) || [], prog.marca)
            : tarjetaFin(cola, hechos, saltados, modo())}
        </div>
        <div class="rev-col-cola">
          <div class="section-title">Cola<span class="line"></span></div>
          <div class="card card-list rev-cola">
            ${cola.length ? cola.map(c => filaCola(c, e, actualId)).join('')
              : '<div class="muted-empty">Sin clientes en la cola.</div>'}
          </div>
        </div>
      </div>`;
  }

  function avanzar(cola, e) {
    const i = cola.findIndex(c => c.id === actualId);
    actualId = siguientePendiente(cola, e, i + 1) || siguientePendiente(cola, e, 0);
    pintar();
  }

  el.addEventListener('click', async ev => {
    const bModo = ev.target.closest('[data-modo]');
    if (bModo) { MODOS.set(programaId, bModo.dataset.modo); actualId = null; pintar(); return; }

    const bIr = ev.target.closest('[data-ir]');
    if (bIr) { actualId = bIr.dataset.ir; pintar(); return; }

    const btn = ev.target.closest('[data-rev]');
    if (!btn || !prog) return;
    const e = progreso(programaId, modo());
    const cola = colaEstable(clientes, prog, modo(), e, mapaClientes);

    if (btn.dataset.rev === 'reiniciar') {
      e.orden = []; e.hechos.clear(); e.saltados.clear();
      actualId = null;
      pintar();
      return;
    }
    const c = mapaClientes.get(actualId);
    if (!c) return;

    if (btn.dataset.rev === 'saltar') {
      e.saltados.add(c.id);
      e.hechos.delete(c.id);
      avanzar(cola, e);
      return;
    }
    if (btn.dataset.rev === 'chequeado') {
      const campo = el.querySelector('#rev-nota-campo');
      const nota = campo ? campo.value : '';
      const r = await guardar(() => registrarChequeo(c, nota), {
        ok: `Chequeado: ${c.nombre}.`, control: btn
      });
      if (r === null) return;
      e.hechos.add(c.id);
      e.saltados.delete(c.id);
      /* No se recarga acá: el realtime de cs_chequeos ya dispara el refresco y
         avanzamos de una para no frenar la revisión. */
      avanzar(cola, e);
    }
  });

  /* En el refresco de realtime se conserva lo que se esté escribiendo en la nota;
     al avanzar de cliente, en cambio, el campo tiene que quedar vacío. */
  async function cargar(conservarFoco = false) {
    const [p, cls, accs, devs] = await Promise.all([
      traerPrograma(programaId), traerClientes(programaId),
      traerAccionablesPrograma(programaId), traerDevolucionesAbiertas(programaId)
    ]);
    if (!vigente()) return;
    if (!p) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    prog = p; clientes = cls; mapaClientes = mapaPorId(cls);
    porCliente = new Map();
    for (const a of accs) {
      if (a.estado === 'completado') continue;
      if (!porCliente.has(a.cliente_id)) porCliente.set(a.cliente_id, []);
      porCliente.get(a.cliente_id).push(a);
    }
    devPorCliente = new Map();
    for (const d of devs) {
      if (!devPorCliente.has(d.cliente_id)) devPorCliente.set(d.cliente_id, []);
      devPorCliente.get(d.cliente_id).push(d);
    }
    if (conservarFoco) repintarConservandoFoco(el, pintar); else pintar();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar la revisión', mensajeError(e));
  });
  return { refrescar: () => cargar(true).catch(e => console.error('revision', e)) };
}
