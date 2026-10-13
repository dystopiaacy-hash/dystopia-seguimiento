/* Alta de un win (106): modal compartido por la ficha (alumno fijo) y por Hoy (alta rápida,
   con buscador de alumno). Al guardar, la base avisa al canal de wins de Discord y deja el
   pendiente "Pedir referido" (se ve en Hoy hasta marcarlo pedido o descartado). */
import { esc, abrirModal, cerrarModal, hoyAR } from '../ui.js';
import { crearWin, WIN_TIPO_LABEL } from '../datos-wins.js';
import { opcionesHtml, guardar } from './comunes.js';
import { montarSelectorAlumno } from './alumno-selector.js';

/* fijo = { id, nombre } (ficha). Sin fijo, hace falta clientes = [{ id, nombre, estado }]. */
export function abrirModalWin({ programaId, fijo = null, clientes = [], alGuardar }) {
  abrirModal({
    titulo: fijo ? `Nuevo win de ${fijo.nombre}` : 'Registrar un win',
    cuerpo: `
      ${fijo ? '' : `<div class="form-row"><label for="win-alumno">Alumno *</label><div id="win-alumno-box"></div></div>`}
      <div class="form-grid2">
        <div class="form-row"><label for="win-fecha">Fecha *</label>
          <input type="date" id="win-fecha" value="${esc(hoyAR())}" max="${esc(hoyAR())}"></div>
        <div class="form-row"><label for="win-tipo">Tipo</label>
          <select id="win-tipo">${opcionesHtml(Object.entries(WIN_TIPO_LABEL), 'otro')}</select></div>
      </div>
      <div class="form-row"><label for="win-texto">Qué pasó * (corto)</label>
        <input type="text" id="win-texto" maxlength="300" autocomplete="off"
          placeholder="Ej: Hizo su primera inversión en CEDEARs"></div>
      <div class="form-row"><label for="win-monto">Monto (opcional)</label>
        <input type="number" id="win-monto" min="0" step="any" inputmode="decimal">
        <div class="hint">El monto no va a Discord salvo que el canal de wins lo tenga habilitado en Configuración.</div></div>
      <div id="win-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="win-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="win-ok">Guardar win</button>`
  });
  const err = t => { document.getElementById('win-error').textContent = t; };
  const sel = fijo ? null : montarSelectorAlumno(document.getElementById('win-alumno-box'), clientes, { id: 'win-alumno' });
  document.getElementById('win-cancelar').onclick = cerrarModal;
  (sel ? sel.foco : () => document.getElementById('win-texto').focus())();

  document.getElementById('win-ok').onclick = () => {
    const alumno = fijo || (sel && sel.cliente());
    if (!alumno) return err('Elegí un alumno de la lista.');
    const fecha = document.getElementById('win-fecha').value;
    const texto = document.getElementById('win-texto').value.trim();
    if (!fecha || fecha > hoyAR()) return err('La fecha es obligatoria y no puede ser futura.');
    if (!texto) return err('Escribí qué pasó.');
    const datos = {
      fecha, texto, tipo: document.getElementById('win-tipo').value, monto: document.getElementById('win-monto').value
    };
    cerrarModal();
    guardar(() => crearWin(programaId, alumno.id, datos), {
      ok: 'Win guardado. Quedó el pendiente de pedir referido.', luego: alGuardar
    });
  };
}
