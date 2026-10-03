/* Maestro — clic en una columna calculada (botones .m-ir de maestro-celdas.js).
   No se editan en la planilla: se abre lo que las cambia.
     accionables / devoluciones / renovaciones -> la ficha, en esa sección (?sec=)
     seguimiento -> el formulario de seguimiento, en un modal, sin salir del Maestro. */
import { toast, abrirModal } from '../ui.js';
import { registrarSeguimiento } from '../datos.js';
import { navegar } from '../router.js';
import { guardar } from './comunes.js';
import { formSeguimiento, anotarCambio, leerSeguimiento, limpiarBorrador } from './seguimiento-form.js';

const PRE = 'mxs';

function modalSeguimiento(f, ctx) {
  const m = abrirModal({
    titulo: 'Seguimiento de ' + f.nombre,
    cuerpo: formSeguimiento({ pre: PRE, p: ctx.prog, c: f }),
    pie: `<button type="button" class="btn" data-mxs="cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" data-mxs="guardar">Guardar seguimiento</button>`
  });
  m.el.addEventListener('change', anotarCambio);
  m.el.addEventListener('input', anotarCambio);
  m.el.addEventListener('click', async ev => {
    const b = ev.target.closest('[data-mxs]');
    if (!b) return;
    if (b.dataset.mxs === 'cancelar') { m.cerrar(); return; }
    const { error, foco, datos } = leerSeguimiento(m.el, PRE);
    if (error) {
      toast(error, 'error');
      if (foco) foco.focus();
      return;
    }
    const r = await guardar(() => registrarSeguimiento(f, datos), { ok: 'Seguimiento guardado.', control: b });
    if (r === null) return;
    limpiarBorrador(f.id);
    m.cerrar();
    ctx.refrescar();
  });
}

/* click en la planilla. Devuelve true si era una celda calculada. */
export function manejarIr(ev, ctx) {
  const b = ev.target.closest('[data-mx-ir]');
  if (!b) return false;
  const f = ctx.porId.get(b.dataset.id);
  if (!f) return true;
  if (b.dataset.mxIr === 'seguimiento') modalSeguimiento(f, ctx);
  else navegar(`p/${encodeURIComponent(ctx.prog.id)}/c/${encodeURIComponent(f.id)}?sec=${b.dataset.mxIr}`);
  return true;
}
