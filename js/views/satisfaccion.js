/* Pestaña "Satisfacción" (#/p/:programa/satisfaccion, 106).
   1. Para enviar: la misma tarjeta de Hoy (hoy-satisfaccion.js).
   2. Momentos: cuándo se pide el formulario en este programa (fin de onboarding, mitad, N días
      antes de vencer...). Lo definen el fundador o el CSM del programa. Solo piden formulario a
      alumnos cuyo hito cae desde la fecha "Desde" del momento (no al histórico).
   3. Respuestas: las últimas 500 del programa, con color (menos de 7 rojo, 7 y 8 amarillo, 9 y 10 verde).
   Los avisos a Discord (menos de 7; 9 o 10 con testimonio) salen de la base: los canales se
   configuran en Configuración. Sin la 106 la pestaña avisa que falta la migración. */
import { esc, fmtFecha, hoyAR, abrirModal, cerrarModal, plural } from '../ui.js';
import { puedeEditarPrograma } from '../sesion.js';
import { traerClientes, mensajeError } from '../datos.js';
import {
  traerMomentos, guardarMomento, traerRespuestasSatisfaccion, textoMomento, MOMENTO_TIPOS
} from '../datos-satisfaccion.js';
import { guardar, opcionesHtml } from './comunes.js';
import { tarjetaError } from './programa.js';
import { montarSatisfaccionHoy } from './hoy-satisfaccion.js';
import { nivelPuntaje } from './estado-columnas.js';

const SUGERIDOS = [
  { nombre: 'Fin de onboarding', tipo: 'onboarding_completo', valor: null },
  { nombre: 'Mitad del programa', tipo: 'porcentaje_ciclo', valor: 50 },
  { nombre: '30 días antes de vencer', tipo: 'dias_antes_fin', valor: 30 }
];

function modalMomento(programaId, m, alGuardar) {
  const nuevo = !m;
  const v = m || { nombre: '', tipo: 'porcentaje_ciclo', valor: 50, activo: true, desde: hoyAR() };
  abrirModal({
    titulo: nuevo ? 'Nuevo momento' : 'Editar momento',
    cuerpo: `
      <div class="form-row"><label for="mo-nombre">Nombre *</label>
        <input type="text" id="mo-nombre" maxlength="60" autocomplete="off" value="${esc(v.nombre)}"
          placeholder="Ej: Mitad del programa"></div>
      <div class="form-grid2">
        <div class="form-row"><label for="mo-tipo">Cuándo se pide</label>
          <select id="mo-tipo">${opcionesHtml(MOMENTO_TIPOS, v.tipo)}</select></div>
        <div class="form-row" id="mo-valor-row"><label for="mo-valor">Valor (N)</label>
          <input type="number" id="mo-valor" min="0" max="1000" step="1" value="${esc(v.valor ?? '')}"></div>
      </div>
      <div class="form-row"><label for="mo-desde">Desde (solo alumnos cuyo hito cae desde esta fecha)</label>
        <input type="date" id="mo-desde" value="${esc(v.desde)}"></div>
      <label class="check-row"><input type="checkbox" id="mo-activo"${v.activo ? ' checked' : ''}> Activo</label>
      <div id="mo-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="mo-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="mo-ok">Guardar</button>`
  });
  const tipo = document.getElementById('mo-tipo');
  const fila = document.getElementById('mo-valor-row');
  const alTipo = () => { fila.hidden = tipo.value === 'onboarding_completo'; };
  tipo.addEventListener('change', alTipo);
  alTipo();
  document.getElementById('mo-cancelar').onclick = cerrarModal;
  document.getElementById('mo-ok').onclick = () => {
    const err = t => { document.getElementById('mo-error').textContent = t; };
    const nombre = document.getElementById('mo-nombre').value.trim();
    const t = tipo.value;
    const valor = document.getElementById('mo-valor').value;
    if (!nombre) return err('Falta el nombre.');
    if (t !== 'onboarding_completo') {
      const n = Number(valor);
      if (valor === '' || !Number.isInteger(n) || n < 0) return err('El valor tiene que ser un número entero.');
      if (t === 'porcentaje_ciclo' && (n < 1 || n > 99)) return err('El porcentaje va de 1 a 99.');
    }
    const desde = document.getElementById('mo-desde').value;
    if (!desde) return err('Falta la fecha "Desde".');
    const datos = { id: m && m.id, orden: m && m.orden, nombre, tipo: t, valor, desde, activo: document.getElementById('mo-activo').checked };
    cerrarModal();
    guardar(() => guardarMomento(programaId, datos), { ok: 'Momento guardado.', luego: alGuardar });
  };
}

function htmlMomentos(momentos, editar) {
  if (!momentos.length) {
    return `<div class="muted-empty">Todavía no hay momentos definidos en este programa.
      ${editar ? '<div class="sat-vacio-acc"><button type="button" class="btn btn-sm btn-accent" data-mo-sugeridos>Agregar los 3 sugeridos</button></div>' : ''}</div>`;
  }
  return momentos.map(m => `<div class="sat-fila">
      <div class="sat-fila-main">
        <div class="sat-fila-tit">${esc(m.nombre)}${m.activo ? '' : ' <span class="hint">(inactivo)</span>'}</div>
        <div class="hint">${esc(textoMomento(m))} · desde ${esc(fmtFecha(m.desde))}</div>
      </div>
      ${editar ? `<button type="button" class="btn-icono" data-mo-editar="${esc(m.id)}">Editar</button>` : ''}
    </div>`).join('');
}

function htmlRespuestas(resp, nombres, programaId) {
  if (!resp.length) return '<div class="muted-empty">Todavía no respondió nadie.</div>';
  const n = resp.length;
  const prom = resp.reduce((s, r) => s + r.puntaje, 0) / n;
  const bajos = resp.filter(r => nivelPuntaje(r.puntaje) === 'rojo').length;
  const filas = resp.map(r => `<tr>
      <td data-label="Alumno"><a class="cli-nombre" href="#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(r.cliente_id)}?sec=satisfaccion">${esc(nombres.get(r.cliente_id) || 'Alumno')}</a></td>
      <td data-label="Momento">${esc(r.momento_nombre)}</td>
      <td data-label="Puntaje"><span class="ll-sem"><span class="sem-dot sem-${nivelPuntaje(r.puntaje)}"></span><strong>${esc(r.puntaje)}/10</strong></span></td>
      <td data-label="Fecha">${esc(fmtFecha(String(r.respondido_at).slice(0, 10)))}</td>
      <td data-label="Testimonio">${r.testimonio ? 'Sí' : 'No'}</td>
      <td data-label="Lo mejor" class="sat-celda-txt">${esc(r.mejor || '')}</td>
      <td data-label="Mejoraría" class="sat-celda-txt">${esc(r.mejorar || '')}</td>
    </tr>`).join('');
  return `<div class="hint">${esc(plural(n, 'respuesta'))} · promedio ${esc(prom.toFixed(1))} · ${esc(plural(bajos, 'con menos de 7', 'con menos de 7'))}</div>
    <div class="card table-card"><table class="data-table"><thead><tr>
      <th>Alumno</th><th>Momento</th><th>Puntaje</th><th>Fecha</th><th>Testimonio</th><th>Lo mejor</th><th>Mejoraría</th>
    </tr></thead><tbody>${filas}</tbody></table></div>`;
}

export function vistaSatisfaccion(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let momentos = [], respuestas = [], nombres = new Map();
  const editar = () => puedeEditarPrograma(programaId);
  let enviar = null;

  function pintar() {
    el.innerHTML = `
      <div class="section-title">Momentos<span class="line"></span>
        ${editar() ? '<button type="button" class="btn btn-sm btn-accent" data-mo-nuevo>Nuevo momento</button>' : ''}</div>
      <div class="card sat-momentos">${htmlMomentos(momentos, editar())}</div>
      <div id="sat-enviar"></div>
      <div class="section-title">Respuestas<span class="line"></span></div>
      ${htmlRespuestas(respuestas, nombres, programaId)}`;
    enviar = montarSatisfaccionHoy(el.querySelector('#sat-enviar'), programaId, vigente, () => {});
  }

  async function cargar() {
    const [mom, resp, cli] = await Promise.all([
      traerMomentos(programaId), traerRespuestasSatisfaccion(programaId), traerClientes(programaId)
    ]);
    if (!vigente()) return;
    if (mom === undefined || resp === undefined) {
      el.innerHTML = tarjetaError('Falta correr la migración 106', 'Esta pestaña se activa cuando la migración 106 está corrida.');
      return;
    }
    momentos = mom;
    respuestas = resp;
    nombres = new Map(cli.map(c => [c.id, c.nombre]));
    pintar();
  }

  el.addEventListener('click', async ev => {
    if (ev.target.closest('[data-mo-nuevo]') && editar()) {
      modalMomento(programaId, null, () => cargar());
      return;
    }
    const e = ev.target.closest('[data-mo-editar]');
    if (e && editar()) {
      const m = momentos.find(x => x.id === e.dataset.moEditar);
      if (m) modalMomento(programaId, m, () => cargar());
      return;
    }
    const s = ev.target.closest('[data-mo-sugeridos]');
    if (s && editar()) {
      s.disabled = true;
      await guardar(async () => {
        for (const [i, m] of SUGERIDOS.entries()) {
          await guardarMomento(programaId, { ...m, desde: hoyAR(), activo: true, orden: i });
        }
      }, { ok: 'Momentos agregados.', luego: () => cargar() });
    }
  });

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar la satisfacción', mensajeError(e));
  });
  return { refrescar: () => { if (enviar) enviar.cargar(); return cargar().catch(err => console.error('satisfaccion', err)); } };
}
