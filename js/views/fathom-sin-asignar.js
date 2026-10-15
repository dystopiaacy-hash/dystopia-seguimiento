/* Pestaña "Llamadas sin asignar" (#/p/:programa/fathom, 122).
   Reuniones de Fathom con invitados externos que la sincronización no pudo asignar a un alumno
   (ningún mail coincide con un alumno de los programas habilitados, o coincide con varios).
   Es una lista global: no depende del programa desde el que se mira. Asignar crea la llamada
   del alumno con su resumen, link, transcripción y accionables, igual que la sincronización.
   Ven y asignan el fundador y la CSM (edición en algún programa); la base lo exige igual
   (cs_fathom_gestor / cs_puede_editar). Sin la 122 avisa que falta la migración. */
import { esc, fmtFecha, plural, abrirModal, cerrarModal, confirmar, urlSegura } from '../ui.js';
import { yo, puedeEditarPrograma } from '../sesion.js';
import { traerClientes, mensajeError } from '../datos.js';
import {
  traerSinAsignar, asignarLlamada, descartarLlamada, TIPO_LLAMADA_LABEL, MOTIVO_LABEL
} from '../datos-fathom.js';
import { guardar } from './comunes.js';
import { tarjetaError } from './programa.js';
import { montarSelectorAlumno } from './alumno-selector.js';

/* Alumnos de todos los programas donde el usuario edita (el selector trae el programa en el nombre). */
async function alumnosEditables() {
  const progs = yo.programas.filter(p => puedeEditarPrograma(p.id));
  const listas = await Promise.all(progs.map(p => traerClientes(p.id)));
  return listas.flatMap((l, i) => l.map(c => ({
    id: c.id, nombre: `${c.nombre} · ${progs[i].nombre}`, estado: c.estado, programa_id: c.programa_id
  })));
}

function fila(l, nombres) {
  const url = urlSegura(l.grabacion_share_url || l.grabacion_url || '');
  const cand = (l.candidatos || []).map(id => nombres.get(id)).filter(Boolean);
  const items = Array.isArray(l.action_items) ? l.action_items.length : 0;
  const invitados = Array.isArray(l.invitados) ? l.invitados : [];
  return `<tr>
      <td data-label="Fecha">${esc(fmtFecha(l.fecha))}</td>
      <td data-label="Llamada">
        <div class="duda-texto">${esc(l.titulo || 'Sin título')}</div>
        <div class="hint">${esc(TIPO_LLAMADA_LABEL[l.tipo] || '')}${l.duracion_min ? ` · ${esc(l.duracion_min)} min` : ''}
          ${items ? ` · ${esc(plural(items, 'accionable'))}` : ''}</div>
        ${l.en_que_esta ? `<div class="duda-resp"><em>En qué está:</em> ${esc(l.en_que_esta.slice(0, 280))}${l.en_que_esta.length > 280 ? '…' : ''}</div>` : ''}
        ${url ? `<div class="duda-resp"><a href="${esc(url)}" target="_blank" rel="noopener noreferrer">Ver grabación en Fathom</a></div>` : ''}
      </td>
      <td data-label="Invitados">${invitados.length ? invitados.map(esc).join('<br>') : '—'}</td>
      <td data-label="Motivo">${esc(MOTIVO_LABEL[l.motivo] || l.motivo)}
        ${cand.length ? `<div class="hint">Posibles: ${cand.map(esc).join(', ')}</div>` : ''}</td>
      <td data-label="" class="acciones"><span class="ll-item-acc">
        <button type="button" class="btn btn-sm btn-accent" data-fa-asignar="${esc(l.id)}">Asignar</button>
        <button type="button" class="btn btn-sm" data-fa-descartar="${esc(l.id)}">No es de un alumno</button>
      </span></td>
    </tr>`;
}

export function vistaFathom(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let lista = [], alumnos = [], nombres = new Map();

  function pintar() {
    el.innerHTML = `
      <div class="section-title">Llamadas sin asignar<span class="line"></span></div>
      <div class="hint">Reuniones grabadas en Fathom con invitados externos que no se pudieron asignar solas
        a un alumno. Al asignar, la llamada entra en su ficha con resumen, link y accionables.
        «No es de un alumno» la saca de la lista sin crear nada.</div>
      <div class="card">${lista.length ? `<div class="table-wrap"><table class="tabla tabla-cards">
          <thead><tr><th>Fecha</th><th>Llamada</th><th>Invitados externos</th><th>Motivo</th><th></th></tr></thead>
          <tbody>${lista.map(l => fila(l, nombres)).join('')}</tbody></table></div>`
        : '<div class="muted-empty">No hay llamadas sin asignar.</div>'}</div>`;
  }

  function modalAsignar(l) {
    abrirModal({
      titulo: 'Asignar llamada',
      cuerpo: `<p class="hint">${esc(fmtFecha(l.fecha))} · ${esc(l.titulo || 'Sin título')}</p>
        <div class="form-row"><label for="fa-alumno">Alumno *</label><div id="fa-alumno-box"></div></div>
        <div id="fa-error" class="login-error"></div>`,
      pie: `<button type="button" class="btn" id="fa-cancelar">Cancelar</button>
            <button type="button" class="btn btn-accent" id="fa-ok">Asignar</button>`
    });
    const sel = montarSelectorAlumno(document.getElementById('fa-alumno-box'), alumnos, { id: 'fa-alumno' });
    sel.foco();
    document.getElementById('fa-cancelar').onclick = cerrarModal;
    document.getElementById('fa-ok').onclick = () => {
      const a = sel.cliente();
      if (!a) { document.getElementById('fa-error').textContent = 'Elegí un alumno de la lista.'; return; }
      cerrarModal();
      guardar(() => asignarLlamada(l.id, a.id), { ok: 'Llamada asignada.', luego: cargar });
    };
  }

  async function cargar() {
    try {
      const [l, a] = await Promise.all([traerSinAsignar(), alumnosEditables()]);
      if (!vigente()) return;
      if (l === undefined) {
        el.innerHTML = tarjetaError('Falta correr la migración 122', 'Esta pestaña se activa cuando la migración 122 está corrida.');
        return;
      }
      lista = l;
      alumnos = a;
      nombres = new Map(a.map(x => [x.id, x.nombre]));
      pintar();
    } catch (e) {
      if (vigente()) el.innerHTML = tarjetaError('No se pudieron cargar las llamadas', mensajeError(e));
    }
  }

  el.addEventListener('click', async ev => {
    const bA = ev.target.closest('[data-fa-asignar]');
    if (bA) {
      const l = lista.find(x => x.id === bA.dataset.faAsignar);
      if (l) modalAsignar(l);
      return;
    }
    const bD = ev.target.closest('[data-fa-descartar]');
    if (bD) {
      const l = lista.find(x => x.id === bD.dataset.faDescartar);
      if (!l) return;
      const ok = await confirmar({
        titulo: 'No es de un alumno',
        texto: `Se saca de la lista la llamada del ${fmtFecha(l.fecha)}${l.titulo ? ' «' + l.titulo + '»' : ''}.`,
        detalle: 'No se crea nada en ninguna ficha. La grabación sigue en Fathom.', ok: 'Descartar'
      });
      if (ok) await guardar(() => descartarLlamada(l.id), { ok: 'Llamada descartada.', luego: cargar, control: bD });
    }
  });

  return cargar();
}
