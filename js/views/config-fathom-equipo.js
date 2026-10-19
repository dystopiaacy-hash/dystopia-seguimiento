/* Configuración general — Fathom: nombres del EQUIPO (193). Personas del equipo (consultores, fundador, agencia) tal como
   aparecen en Fathom: la IA que clasifica las llamadas pendientes las ignora al buscar al alumno. Solo el fundador agrega,
   edita la nota o desactiva (no se borra). Sin la 193 el bloque avisa que falta la migración. */
import { esc, toast } from '../ui.js';
import { esFundador } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { traerEquipoNombres, guardarEquipoNombre, crearEquipoNombre } from '../datos-fathom.js';

export const htmlFathomEquipo = () => `
  <div class="card" id="cf-fathom-equipo"><div class="loading-inline">Cargando…</div></div>`;

export async function montarFathomEquipo(box, vigente) {
  if (!box) return;
  if (!esFundador()) { box.innerHTML = '<div class="hint">Solo el fundador edita los nombres del equipo.</div>'; return; }

  async function pintar() {
    let filas;
    try { filas = await traerEquipoNombres(); } catch (e) {
      if (vigente() && box.isConnected) box.innerHTML = `<div class="hint">${esc(mensajeError(e))}</div>`;
      return;
    }
    if (!vigente() || !box.isConnected) return;
    if (filas === undefined) { box.innerHTML = '<div class="hint">Falta correr la migración 193 (nombres del equipo).</div>'; return; }
    box.innerHTML = `
      <div class="section-title">Equipo en Fathom (la IA lo ignora al buscar al alumno)<span class="line"></span></div>
      <div class="hint">Poné el nombre como aparece en Fathom; el orden nombre / apellido, las mayúsculas y los acentos no importan.
        Si una llamada tiene un hablante de una sola palabra que coincide con el nombre o el apellido de alguien de esta lista, también se descarta:
        no cargues clientes. Los consultores de arriba ya cuentan solos.</div>
      ${filas.map(f => `
        <div class="cf-consultor">
          <label class="check-row"><input type="checkbox" data-eq-activo="${esc(f.id)}"${f.activo ? ' checked' : ''}>
            <strong>${esc(f.nombre)}</strong></label>
          <span class="cf-consultor-n">
            <input type="text" data-eq-nota="${esc(f.id)}" value="${esc(f.nota || '')}" placeholder="Nota (rol, apodo)" maxlength="200">
            <button type="button" class="btn btn-sm" data-eq-nota-ok="${esc(f.id)}">Guardar nota</button></span>
        </div>`).join('') || '<div class="hint">No hay nombres cargados.</div>'}
      <div class="cf-consultor">
        <input type="text" id="eq-nuevo-nombre" placeholder="Nombre en Fathom (ej. Nombre Apellido)" maxlength="80">
        <input type="text" id="eq-nuevo-nota" placeholder="Nota (opcional)" maxlength="200">
        <button type="button" class="btn btn-sm" id="eq-nuevo">Agregar al equipo</button>
      </div>`;

    box.querySelectorAll('[data-eq-activo]').forEach(chk => {
      chk.onchange = async () => {
        chk.disabled = true;
        try {
          await guardarEquipoNombre(chk.dataset.eqActivo, { activo: chk.checked });
          toast(chk.checked ? 'Nombre activado.' : 'Nombre desactivado.');
        } catch (e) { toast(mensajeError(e), 'error'); chk.checked = !chk.checked; }
        chk.disabled = false;
      };
    });
    box.querySelectorAll('[data-eq-nota-ok]').forEach(btn => {
      btn.onclick = async () => {
        const id = btn.dataset.eqNotaOk;
        btn.disabled = true;
        try {
          await guardarEquipoNombre(id, { nota: box.querySelector(`[data-eq-nota="${id}"]`).value.trim() || null });
          toast('Nota guardada.');
        } catch (e) { toast(mensajeError(e), 'error'); }
        btn.disabled = false;
      };
    });
    box.querySelector('#eq-nuevo').onclick = async ev => {
      const btn = ev.currentTarget;
      const nombre = box.querySelector('#eq-nuevo-nombre').value.trim();
      if (nombre.length < 2) { toast('Poné el nombre tal como aparece en Fathom.', 'error'); return; }
      btn.disabled = true;
      try {
        await crearEquipoNombre({ nombre, nota: box.querySelector('#eq-nuevo-nota').value.trim() });
        toast('Agregado al equipo.');
        await pintar();
      } catch (e) {
        toast(/duplicate|23505/i.test(`${e?.code} ${e?.message}`) ? 'Ese nombre ya está en la lista.' : mensajeError(e), 'error');
        btn.disabled = false;
      }
    };
  }

  await pintar();
}
