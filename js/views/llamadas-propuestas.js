/* Sección "Propuestas de la IA" de la pantalla Llamadas (186): por cada llamada sin asignar, la IA propone
   tipo y alumno; una persona acepta, corrige o descarta. NADA se asigna solo. Aceptar y corregir llaman a
   cs_fathom_prop_resolver, que usa la misma cs_fathom_asignar de la asignación manual (o "No es alumno"
   si no hay alumno), así el resto de la app se entera igual. "Clasificar pendientes" es solo del fundador.
   Lo monta llamadas-fathom.js: crearPropuestas({...}) devuelve { cargar, pintar(caja) }. */
import { esc, fmtFecha, plural, abrirModal, cerrarModal, confirmar, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import { mensajeError } from '../datos.js';
import {
  traerPropuestas, resolverPropuesta, aceptarAltas, clasificarPendientes,
  TIPO_PROPUESTA_LABEL, CONFIANZA_LABEL
} from '../datos-fathom-ia.js';
import { guardar } from './comunes.js';
import { montarSelectorAlumno } from './alumno-selector.js';
import { resumenAprendido } from '../datos-fathom.js';

const PAGINA = 40;
const LOTE = 60;            // llamadas por pedido a la función (~30 s); se encadenan hasta terminar
const MAX_PEDIDOS = 20;     // tope de pedidos encadenados por clic (1.200 llamadas)
const usd = n => `US$ ${(Number(n) || 0).toFixed(4).replace('.', ',')}`;

export function crearPropuestas({ llamadas, alumnos, alCambiar }) {
  let props = [];                 // undefined = falta la 186
  let caja = null;
  const filtro = { conf: '', consultor: '' };
  let mostrar = PAGINA;
  const estado = { clasificando: false, progreso: '', hecho: 0, total: 0, resultado: '', aceptando: false };

  const delAlumno = id => (alumnos() || []).find(a => a.id === id);
  /* Solo las propuestas cuya llamada sigue sin asignar y el usuario puede ver. */
  const filas = () => {
    const porId = new Map((llamadas() || []).filter(l => l.estado === 'pendiente' || l.estado === 'interna').map(l => [l.id, l]));
    return (props || []).map(p => ({ p, l: porId.get(p.llamada_id) })).filter(x => x.l);
  };
  const esAltaAceptable = p => p.confianza === 'alta' && p.alumno_id && p.tipo === 'consultoria_1a1';

  function filaHtml({ p, l }) {
    const a = p.alumno_id ? delAlumno(p.alumno_id) : null;
    const meta = [fmtFecha(l.fecha), l.consultor, l.duracion_min ? `${l.duracion_min} min` : ''].filter(Boolean).join(' · ');
    const necesitaAlumno = p.tipo === 'consultoria_1a1' && !p.alumno_id;
    const quien = p.alumno_id
      ? `<strong>${esc(a ? a.nombre : 'Alumno no disponible')}</strong>`
      : '<span class="pi-sin">sin alumno</span>';
    /* 187: sin alumno, aceptar deja la llamada guardada con su tipo (clase, venta, interna u otra). */
    const aceptarTxt = p.alumno_id ? 'Aceptar y asignar' : (necesitaAlumno ? 'Aceptar' : `Aceptar como ${(TIPO_PROPUESTA_LABEL[p.tipo] || p.tipo).toLowerCase()}`);
    return `<div class="pi-fila" data-pi="${esc(p.id)}">
      <div class="pi-main">
        <div class="pi-tit">${esc(l.titulo || 'Sin título')}</div>
        <div class="hint">${esc(meta)}</div>
        <div class="pi-prop">
          <span class="pi-tipo">${esc(TIPO_PROPUESTA_LABEL[p.tipo] || p.tipo)}</span>
          <span class="pi-flecha" aria-hidden="true">→</span> ${quien}
          <span class="pi-conf pi-conf-${esc(p.confianza)}">${esc(CONFIANZA_LABEL[p.confianza] || p.confianza)}</span>
          ${p.origen === 'mail' ? '<span class="hint">por mail</span>' : ''}
        </div>
        ${p.motivo ? `<div class="hint">${esc(p.motivo)}</div>` : ''}
      </div>
      <div class="pi-acc">
        <button type="button" class="btn btn-sm btn-accent" data-pi-aceptar="${esc(p.id)}"${necesitaAlumno ? ' disabled title="Elegí el alumno con Corregir"' : ''}>${esc(aceptarTxt)}</button>
        <button type="button" class="btn btn-sm" data-pi-corregir="${esc(p.id)}">Corregir</button>
        <button type="button" class="btn btn-sm" data-pi-descartar="${esc(p.id)}">Descartar</button>
      </div>
    </div>`;
  }

  function pintar(c) {
    if (c) caja = c;
    if (!caja || !caja.isConnected) return;
    const fund = esFundador();
    if (props === undefined) {
      caja.innerHTML = fund
        ? '<div class="hint pi-falta">Propuestas de la IA: falta correr la migración 186.</div>' : '';
      return;
    }
    const todas = filas();
    if (!todas.length && !fund && !estado.resultado) { caja.innerHTML = ''; return; }
    const consultores = [...new Set(todas.map(x => x.l.consultor).filter(Boolean))].sort();
    const lista = todas.filter(x => (!filtro.conf || x.p.confianza === filtro.conf)
      && (!filtro.consultor || x.l.consultor === filtro.consultor));
    const altas = todas.filter(x => esAltaAceptable(x.p)).length;
    const visibles = lista.slice(0, mostrar);
    const ocupado = estado.clasificando || estado.aceptando;
    caja.innerHTML = `
      <div class="section-title">Propuestas de la IA<span class="line"></span></div>
      <div class="hint">La IA propone el tipo de cada llamada sin asignar y, si es de un alumno, cuál. Nada se asigna hasta que
        alguien acepta: con alumno, «Aceptar» hace lo mismo que «Asignar a alumno»; una clase grupal, venta, interna u otra
        queda guardada con ese tipo (no es de ningún alumno). Pueden revisarlas el fundador, el consultor de cada llamada y el cliente (solo las de su programa).</div>
      <div class="pi-barra">
        ${fund ? `<button type="button" class="btn btn-accent" id="pi-clasificar"${ocupado ? ' disabled' : ''}>${estado.clasificando ? 'Clasificando…' : 'Clasificar pendientes'}</button>` : ''}
        ${fund && todas.length ? `<button type="button" class="btn" id="pi-reclasificar"${ocupado ? ' disabled' : ''}>Re-clasificar propuestas</button>` : ''}
        ${altas ? `<button type="button" class="btn" id="pi-altas"${ocupado ? ' disabled' : ''}>${estado.aceptando ? 'Aceptando…' : `Aceptar todas las de confianza alta (${altas})`}</button>` : ''}
        <label>Confianza <select id="pi-f-conf"><option value="">Todas</option>
          ${Object.entries(CONFIANZA_LABEL).map(([k, v]) => `<option value="${k}"${filtro.conf === k ? ' selected' : ''}>${esc(v)}</option>`).join('')}
        </select></label>
        ${consultores.length > 1 ? `<label>Consultor <select id="pi-f-cons"><option value="">Todos</option>
          ${consultores.map(k => `<option value="${esc(k)}"${filtro.consultor === k ? ' selected' : ''}>${esc(k)}</option>`).join('')}
        </select></label>` : ''}
      </div>
      ${estado.clasificando ? `<div class="pi-estado" role="status">${esc(estado.progreso || 'Clasificando…')}
        ${estado.total ? `<progress class="pi-prog" max="${estado.total}" value="${Math.min(estado.hecho, estado.total)}"></progress>` : ''}</div>` : ''}
      ${!estado.clasificando && estado.resultado ? `<div class="pi-estado pi-resultado" role="status">${esc(estado.resultado)}</div>` : ''}
      <div class="card pi-lista">${visibles.length ? visibles.map(filaHtml).join('')
        : `<div class="muted-empty">${todas.length ? 'Ninguna propuesta coincide con los filtros.'
          : 'No hay propuestas pendientes.' + (fund ? ' Usá «Clasificar pendientes» para generarlas.' : '')}</div>`}</div>
      ${lista.length ? `<div class="hint">${esc(plural(lista.length, 'propuesta'))}${lista.length !== todas.length ? ` de ${todas.length}` : ''}.
        ${lista.length > visibles.length ? '<button type="button" class="btn btn-sm" id="pi-mas">Mostrar más</button>' : ''}</div>` : ''}`;
    enganchar(caja);
  }

  /* Un resumen corto del resultado de "Clasificar pendientes". */
  function textoResultado(t) {
    const n = t.procesadas;
    if (!n && !t.errores) return 'No había llamadas nuevas para clasificar.';
    return `Clasificadas ${plural(n, 'llamada')}: ${t.alta} alta, ${t.media} media, ${t.baja} baja confianza `
      + `(${t.por_mail} por mail sin IA, ${t.por_ia} con IA). Costo ${usd(t.costo)}.`
      + (t.errores ? ` ${plural(t.errores, 'llamada')} ${t.errores === 1 ? 'no se pudo' : 'no se pudieron'} clasificar: probá de nuevo.` : '')
      + (t.tope ? ' Se frenó por el tope de costo de la corrida: volvé a tocar el botón para seguir.' : '');
  }

  /* "Clasificar pendientes" / "Re-clasificar": procesa TODO encadenando pedidos de LOTE llamadas (cada uno tarda
     ~30 s, bien por debajo del límite de la función) y mostrando el progreso. Se corta si no avanza o por el tope
     de costo. rehacer = vuelve a proponer las propuestas PENDIENTES (las ya decididas no se tocan: la base las
     protege). `desde` evita repetir lo que ya se rehízo en esta corrida. */
  async function clasificar(rehacer) {
    if (estado.clasificando) return;
    estado.clasificando = true; estado.resultado = ''; estado.progreso = 'Clasificando…'; estado.hecho = 0; estado.total = 0;
    pintar();
    const desde = new Date().toISOString();
    const t = { procesadas: 0, por_mail: 0, por_ia: 0, alta: 0, media: 0, baja: 0, errores: 0, costo: 0, tope: false };
    let previo = Infinity;
    try {
      for (let i = 0; i < MAX_PEDIDOS; i++) {
        const r = await clasificarPendientes({ max: LOTE, ...(rehacer ? { rehacer: true, rehacer_desde: desde } : {}) });
        t.procesadas += r.procesadas || 0; t.por_mail += r.por_mail || 0; t.por_ia += r.por_ia || 0;
        t.alta += (r.por_confianza || {}).alta || 0; t.media += (r.por_confianza || {}).media || 0;
        t.baja += (r.por_confianza || {}).baja || 0; t.costo += r.costo_usd || 0;
        t.errores = r.errores || 0; t.tope = !!r.cortada_por_costo;
        if (i === 0) estado.total = (r.procesadas || 0) + (r.quedan || 0);
        estado.hecho = t.procesadas;
        estado.progreso = `Clasificando… ${t.procesadas} de ${estado.total}${r.quedan ? ` (faltan ${r.quedan})` : ''}`;
        pintar();
        if (!r.procesadas || !r.quedan || r.cortada_por_costo || r.quedan >= previo) break;
        previo = r.quedan;
      }
      estado.resultado = textoResultado(t);
    } catch (e) {
      toast(mensajeError(e), 'error');
      estado.resultado = t.procesadas ? textoResultado(t) : '';
    } finally {
      estado.clasificando = false;
      await alCambiar();
    }
  }

  async function reclasificar() {
    if (estado.clasificando) return;
    const ok = await confirmar({
      titulo: 'Re-clasificar las propuestas pendientes',
      texto: 'La IA vuelve a proponer tipo y alumno para las propuestas que todavía nadie decidió, con los alumnos de todos los programas habilitados.',
      detalle: 'Las propuestas aceptadas, corregidas o descartadas no se tocan y no se crean duplicadas. Cuesta unos centavos de dólar cada ~200 llamadas.',
      ok: 'Re-clasificar', peligro: false
    });
    if (ok) await clasificar(true);
  }

  async function aceptarTodasAltas() {
    const n = filas().filter(x => esAltaAceptable(x.p)).length;
    if (!n || estado.aceptando) return;
    const ok = await confirmar({
      titulo: 'Aceptar las de confianza alta',
      texto: `Se asignan ${plural(n, 'llamada')} a los alumnos propuestos, igual que «Asignar a alumno».`,
      detalle: 'Son consultorías 1 a 1 donde coincide el mail o el nombre completo. Si alguna falla, el resto sigue.',
      ok: 'Aceptar todas', peligro: false
    });
    if (!ok) return;
    estado.aceptando = true; pintar();
    let aceptadas = 0, fallidas = 0;
    try {
      for (let i = 0; i < 6; i++) {
        const r = await aceptarAltas(100);
        aceptadas += r.aceptadas || 0; fallidas += r.fallidas || 0;
        if (!r.aceptadas || !r.quedan) break;
      }
      toast(`${plural(aceptadas, 'llamada asignada', 'llamadas asignadas')}.`
        + (fallidas ? ` ${plural(fallidas, 'no se pudo asignar', 'no se pudieron asignar')}: revisalas una por una.` : ''),
      fallidas ? 'error' : '');
    } catch (e) {
      toast(mensajeError(e), 'error');
    } finally {
      estado.aceptando = false;
      await alCambiar();
    }
  }

  /* Aviso del resultado de aceptar / corregir: lo que aprendió la asignación (alias) y lo que chocó. */
  function avisar(base, r) {
    toast(base);
    const conf = r && Array.isArray(r.alias_conflictos) ? r.alias_conflictos : [];
    if (r && r.alias_guardados) toast(resumenAprendido({ alias_guardados: r.alias_guardados }));
    if (conf.length) toast(resumenAprendido({ alias_conflictos: conf }), 'error');
  }

  function modalCorregir(p, l) {
    const a = p.alumno_id ? delAlumno(p.alumno_id) : null;
    abrirModal({
      titulo: 'Corregir la propuesta',
      cuerpo: `<p class="hint">${esc(fmtFecha(l.fecha))} · ${esc(l.titulo || 'Sin título')}<br>
          La IA propuso: <strong>${esc(TIPO_PROPUESTA_LABEL[p.tipo] || p.tipo)}</strong>${a ? ` · ${esc(a.nombre)}` : ''}</p>
        <div class="form-row"><label for="pi-c-tipo">Tipo</label>
          <select id="pi-c-tipo">${Object.entries(TIPO_PROPUESTA_LABEL)
            .map(([k, v]) => `<option value="${k}"${p.tipo === k ? ' selected' : ''}>${esc(v)}</option>`).join('')}</select></div>
        <div class="form-row"><label for="pi-c-alumno">Alumno</label><div id="pi-c-box"></div></div>
        <div class="hint">${a ? `Si no elegís otro, en una consultoría 1 a 1 queda ${esc(a.nombre)}. ` : ''}Una consultoría 1 a 1 se
          asigna a la ficha del alumno; clase grupal, venta, interna u otra quedan guardadas con ese tipo, sin alumno.</div>
        <div id="pi-c-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="pi-c-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="pi-c-ok">Corregir y aplicar</button>`
    });
    const sel = montarSelectorAlumno(document.getElementById('pi-c-box'), alumnos() || [], { id: 'pi-c-alumno' });
    sel.foco();
    document.getElementById('pi-c-cancelar').onclick = cerrarModal;
    document.getElementById('pi-c-ok').onclick = () => {
      const tipo = document.getElementById('pi-c-tipo').value;
      const elegido = sel.cliente();
      const clienteId = elegido ? elegido.id : (tipo === 'consultoria_1a1' ? p.alumno_id : null);
      if (tipo === 'consultoria_1a1' && !clienteId) {
        document.getElementById('pi-c-error').textContent = 'Una consultoría 1 a 1 necesita alumno: elegilo de la lista.';
        return;
      }
      cerrarModal();
      const base = tipo === 'consultoria_1a1' ? 'Llamada asignada.'
        : `Guardada como ${(TIPO_PROPUESTA_LABEL[tipo] || tipo).toLowerCase()}.`;
      guardar(async () => avisar(base,
        await resolverPropuesta(p.id, 'corregir', { clienteId: tipo === 'consultoria_1a1' ? clienteId : null, tipo })),
      { ok: '', luego: alCambiar });
    };
  }

  /* Los escuchas se ponen una sola vez por caja (pintar reescribe el contenido, no la caja). */
  const enganchadas = new WeakSet();
  function enganchar(c) {
    if (enganchadas.has(c)) return;
    enganchadas.add(c);
    c.addEventListener('change', ev => {
      if (ev.target.id === 'pi-f-conf') filtro.conf = ev.target.value;
      else if (ev.target.id === 'pi-f-cons') filtro.consultor = ev.target.value;
      else return;
      mostrar = PAGINA; pintar();
    });
    c.addEventListener('click', async ev => {
      const t = ev.target;
      if (t.closest('#pi-clasificar')) { await clasificar(false); return; }
      if (t.closest('#pi-reclasificar')) { await reclasificar(); return; }
      if (t.closest('#pi-altas')) { await aceptarTodasAltas(); return; }
      if (t.closest('#pi-mas')) { mostrar += PAGINA; pintar(); return; }
      const porId = id => filas().find(x => x.p.id === id);
      const bA = t.closest('[data-pi-aceptar]');
      if (bA) {
        await guardar(async () => avisar('Propuesta aceptada.', await resolverPropuesta(bA.dataset.piAceptar, 'aceptar')),
          { ok: '', luego: alCambiar, control: bA });
        return;
      }
      const bC = t.closest('[data-pi-corregir]');
      if (bC) { const x = porId(bC.dataset.piCorregir); if (x) modalCorregir(x.p, x.l); return; }
      const bD = t.closest('[data-pi-descartar]');
      if (bD) {
        await guardar(() => resolverPropuesta(bD.dataset.piDescartar, 'descartar'),
          { ok: 'Propuesta descartada: la llamada sigue pendiente.', luego: alCambiar, control: bD });
      }
    });
  }

  async function cargar() {
    try { props = await traerPropuestas(); } catch (e) { props = []; toast(mensajeError(e), 'error'); }
  }

  return { cargar, pintar };
}
