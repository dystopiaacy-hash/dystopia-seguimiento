/* Ficha de cliente — nombres alternativos (alias) para las llamadas de Fathom (127).
   Se aprenden solos al asignar o confirmar una llamada a mano (nombre del invitado o del título);
   fathom-sync los usa junto con el nombre del alumno para vincular la próxima reunión. Acá se ven,
   se quitan y se agregan a mano. Solo fundador y cliente del programa (la base lo exige igual, y la
   tabla solo la leen ellos). Un nombre que ya es de otro alumno no se puede agregar.
   El bloque carga sus datos por su cuenta (sin la 127 no se muestra nada). */
import { esc, confirmar, toast } from '../ui.js';
import { esFundador, yo } from '../sesion.js';
import { mensajeError } from '../datos.js';
import { traerAliasCliente, quitarAlias, agregarAlias } from '../datos-fathom.js';

/* Lo último cargado: sobrevive a los repintados de la ficha (se pierde al cambiar de alumno). */
let cache = { id: null, lista: undefined };

const permitido = () => esFundador() || yo.rol === 'cliente';

function cuerpo(ctx) {
  if (cache.id !== ctx.c.id) return '<div class="loading-inline">Cargando…</div>';
  if (cache.lista === undefined) return '<div class="hint">Falta correr la migración 127 (alias de nombre).</div>';
  const chips = cache.lista.length
    ? `<div class="al-lista">${cache.lista.map(a => `
        <span class="al-chip">${esc(a.alias)}
          <span class="hint">${a.origen === 'manual' ? 'a mano' : 'aprendido'}</span>
          <button type="button" class="btn-icono btn-icono-danger" data-al-quitar="${esc(a.id)}"
            data-al-nombre="${esc(a.alias)}">Quitar</button></span>`).join('')}</div>`
    : '<div class="muted-empty">Todavía no aprendió ningún nombre alternativo.</div>';
  return `
    <div class="hint">Cuando una llamada de Fathom trae uno de estos nombres (invitado o título) se vincula sola a
      este alumno, además de por su nombre y mail. Se aprenden al asignar o confirmar una llamada a mano.</div>
    ${chips}
    <div class="al-alta">
      <input type="text" id="al-nuevo" maxlength="80" autocomplete="off" placeholder="Nombre y apellido alternativo">
      <button type="button" class="btn btn-sm" data-al-agregar>Agregar</button>
    </div>`;
}

export function html(ctx) {
  if (!permitido()) return '';
  return `
    <div class="section-title">Nombres alternativos (llamadas de Fathom)<span class="line"></span></div>
    <div class="card" data-al-box>${cuerpo(ctx)}</div>`;
}

function repintar(cont, ctx) {
  const box = cont && cont.querySelector('[data-al-box]');
  if (box && box.isConnected) box.innerHTML = cuerpo(ctx);
}

export function montar(cont, ctx) {
  if (!permitido() || cache.id === ctx.c.id) return;
  const id = ctx.c.id;
  traerAliasCliente(id)
    .then(lista => { cache = { id, lista }; repintar(cont, ctx); })
    .catch(e => { console.error('alias', e); cache = { id, lista: undefined }; repintar(cont, ctx); });
}

export async function manejar(ev, ctx) {
  if (ev.type !== 'click' || !permitido()) return false;
  const bQ = ev.target.closest('[data-al-quitar]');
  const bA = ev.target.closest('[data-al-agregar]');
  if (!bQ && !bA) return false;
  const cont = ev.target.closest('[data-al-box]') && ev.target.closest('[data-al-box]').parentElement;

  const recargar = async () => {
    cache = { id: ctx.c.id, lista: await traerAliasCliente(ctx.c.id) };
    repintar(cont, ctx);
  };

  if (bQ) {
    const ok = await confirmar({
      titulo: 'Quitar nombre alternativo',
      texto: `Se quita «${bQ.dataset.alNombre}» de ${ctx.c.nombre}.`,
      detalle: 'Las llamadas ya asignadas no cambian. Esa persona deja de vincularse sola por ese nombre.',
      ok: 'Quitar', peligro: true
    });
    if (!ok) return true;
    bQ.disabled = true;
    try { await quitarAlias(bQ.dataset.alQuitar); toast('Nombre quitado.'); await recargar(); }
    catch (e) { toast(mensajeError(e), 'error'); bQ.disabled = false; }
    return true;
  }

  const inp = ev.target.closest('[data-al-box]').querySelector('#al-nuevo');
  const alias = inp.value.trim();
  if (!alias) { toast('Escribí el nombre.', 'error'); return true; }
  bA.disabled = true;
  try { await agregarAlias(ctx.c.id, alias); toast('Nombre agregado.'); await recargar(); }
  catch (e) { toast(mensajeError(e), 'error'); }
  if (bA.isConnected) bA.disabled = false;
  return true;
}
