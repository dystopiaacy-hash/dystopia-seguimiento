/* Ficha de cliente — recursos compartidos con el alumno (102).
   Links con título, tipo detectado por el dominio (Doc, Sheet, Slides, Drive, YouTube,
   Loom u otro) y la llamada a la que pertenecen (opcional). Buscador por título, agrupado
   por tipo. Se abren en una pestaña nueva (sin lector embebido).
   Permisos: los mismos que los accionables por llamada (editar = fundador o producto;
   cliente@ solo ve; borrar solo el fundador). Sin la 102 el bloque no se muestra. */
import { esc, fmtFecha, abrirModal, cerrarModal, confirmar, urlSegura } from '../ui.js';
import { esFundador, puedeEditarPrograma } from '../sesion.js';
import { actualizarFila, borrarFila } from '../datos.js';
import { guardar, opcionesHtml } from './comunes.js';
import {
  TIPO_RECURSO_LABEL, TIPO_RECURSO_ORDEN, detectarRecurso, agregarRecursos
} from '../datos-llamadas.js';

const T_REC = 'cs_llamada_recursos';

/* La búsqueda vive en el módulo: sobrevive a los repintados de la ficha (se pierde al
   cambiar de alumno). */
let busqueda = { cliente: null, q: '' };
let ultimoCtx = null;

const textoBuscable = (r) => `${r.titulo} ${r.url} ${TIPO_RECURSO_LABEL[r.tipo] || ''}`.toLowerCase();

function listaHtml(ctx) {
  const { llamadas, recursos } = ctx.llamadas;
  const editar = puedeEditarPrograma(ctx.p.id);
  const fundador = esFundador();
  const q = busqueda.cliente === ctx.c.id ? busqueda.q.trim().toLowerCase() : '';
  const filtrados = recursos.filter(r => !q || textoBuscable(r).includes(q));
  if (!recursos.length) return '<div class="muted-empty">Todavía no hay recursos cargados.</div>';
  if (!filtrados.length) return '<div class="muted-empty">Ningún recurso coincide con la búsqueda.</div>';
  const llamadaDe = id => llamadas.find(l => l.id === id);

  return TIPO_RECURSO_ORDEN.map(tipo => {
    const filas = filtrados.filter(r => r.tipo === tipo);
    if (!filas.length) return '';
    return `<div class="rec-grupo">
      <div class="rec-tipo">${esc(TIPO_RECURSO_LABEL[tipo])} <span class="rec-tipo-n">${filas.length}</span></div>
      ${filas.map(r => {
        const href = urlSegura(r.url);
        const ll = r.llamada_id ? llamadaDe(r.llamada_id) : null;
        const { host } = detectarRecurso(r.url);
        return `<div class="rec-fila">
          <div class="rec-main">
            ${href ? `<a class="rec-link" href="${esc(href)}" target="_blank" rel="noopener noreferrer">${esc(r.titulo)}</a>`
              : `<span class="rec-link">${esc(r.titulo)}</span>`}
            <span class="rec-meta">${esc(host)}${ll ? ` · de la llamada del ${esc(fmtFecha(ll.fecha))}` : ''}</span>
          </div>
          ${editar || fundador ? `<span class="ll-item-acc">
            ${editar ? `<button type="button" class="btn-icono" data-rec-editar="${esc(r.id)}">Editar</button>` : ''}
            ${fundador ? `<button type="button" class="btn-icono btn-icono-danger" data-rec-borrar="${esc(r.id)}">Borrar</button>` : ''}
          </span>` : ''}
        </div>`;
      }).join('')}
    </div>`;
  }).join('');
}

const opcionesLlamada = (llamadas, sel = '') => opcionesHtml(
  [['', 'Sin llamada']].concat(llamadas.map(l => [l.id, 'Llamada del ' + fmtFecha(l.fecha) + (l.titulo ? ' · ' + l.titulo : '')])), sel);

export function html(ctx) {
  if (!ctx.llamadas) return '';
  ultimoCtx = ctx;
  const editar = puedeEditarPrograma(ctx.p.id);
  const q = busqueda.cliente === ctx.c.id ? busqueda.q : '';
  return `
    <div class="section-title">Recursos<span class="line"></span></div>
    <div class="card rec-card">
      <div class="rec-buscar">
        <input type="search" id="rec-q" value="${esc(q)}" maxlength="100" autocomplete="off"
          placeholder="Buscar por título…" aria-label="Buscar recursos por título">
      </div>
      <div id="rec-lista">${listaHtml(ctx)}</div>
      ${editar ? `<form class="rec-alta" data-rec-alta>
        <input type="text" name="titulo" maxlength="200" autocomplete="off" placeholder="Título (opcional)" aria-label="Título del recurso">
        <input type="url" name="url" maxlength="1000" autocomplete="off" required placeholder="https://…" aria-label="URL del recurso">
        <select name="llamada" aria-label="Llamada del recurso">${opcionesLlamada(ctx.llamadas.llamadas)}</select>
        <button type="submit" class="btn btn-sm">Agregar</button>
      </form>` : ''}
    </div>`;
}

/* Búsqueda en vivo: solo se repinta la lista (el campo conserva el foco). Lo llama ficha.js
   después de pintar el bloque; el listener se pone una sola vez por contenedor. */
export function montar(cont) {
  if (cont.dataset.recMontado) return;
  cont.dataset.recMontado = '1';
  cont.addEventListener('input', ev => {
    if (ev.target.id !== 'rec-q' || !ultimoCtx || !ultimoCtx.llamadas) return;
    busqueda = { cliente: ultimoCtx.c.id, q: ev.target.value };
    const lista = cont.querySelector('#rec-lista');
    if (lista) lista.innerHTML = listaHtml(ultimoCtx);
  });
}

function modalEditar(r, ctx, api) {
  abrirModal({
    titulo: 'Editar recurso',
    cuerpo: `
      <div class="form-row"><label for="rec-titulo">Título *</label>
        <input type="text" id="rec-titulo" maxlength="200" autocomplete="off" value="${esc(r.titulo)}"></div>
      <div class="form-row"><label for="rec-url">URL *</label>
        <input type="url" id="rec-url" maxlength="1000" autocomplete="off" value="${esc(r.url)}"></div>
      <div class="form-row"><label for="rec-llamada">Llamada</label>
        <select id="rec-llamada">${opcionesLlamada(ctx.llamadas.llamadas, r.llamada_id || '')}</select></div>
      <div id="rec-error" class="login-error"></div>`,
    pie: `<button type="button" class="btn" id="rec-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="rec-ok">Guardar</button>`
  });
  document.getElementById('rec-cancelar').onclick = cerrarModal;
  document.getElementById('rec-ok').onclick = () => {
    const titulo = document.getElementById('rec-titulo').value.trim();
    const url = urlSegura(document.getElementById('rec-url').value.trim());
    const err = t => { document.getElementById('rec-error').textContent = t; };
    if (!titulo) return err('El título es obligatorio.');
    if (!url) return err('La URL tiene que empezar con http:// o https://.');
    const cambios = {
      titulo, url, tipo: detectarRecurso(url).tipo,
      llamada_id: document.getElementById('rec-llamada').value || null
    };
    cerrarModal();
    guardar(() => actualizarFila(T_REC, r.id, cambios), { luego: () => api.refrescar() });
  };
}

export async function manejar(ev, ctx, api) {
  if (!ctx.llamadas) return false;
  const editar = puedeEditarPrograma(ctx.p.id);

  if (ev.type === 'submit') {
    const form = ev.target.closest('[data-rec-alta]');
    if (!form) return false;
    ev.preventDefault();
    if (!editar) return true;
    const url = urlSegura(form.elements.url.value.trim());
    if (!url) {
      form.elements.url.setCustomValidity('Tiene que empezar con http:// o https://');
      form.elements.url.reportValidity();
      form.elements.url.setCustomValidity('');
      return true;
    }
    const { tipo, host } = detectarRecurso(url);
    const titulo = form.elements.titulo.value.trim() || host || url;
    await guardar(
      () => agregarRecursos(ctx.p.id, ctx.c.id, form.elements.llamada.value || null, [{ titulo: titulo.slice(0, 200), url, tipo }]),
      { ok: 'Recurso agregado.', luego: () => api.refrescar(), control: form.querySelector('button') });
    return true;
  }

  if (ev.type !== 'click') return false;
  const rec = id => ctx.llamadas.recursos.find(r => r.id === id);

  const ed = ev.target.closest('[data-rec-editar]');
  if (ed) {
    const r = rec(ed.dataset.recEditar);
    if (r && editar) modalEditar(r, ctx, api);
    return true;
  }
  const bo = ev.target.closest('[data-rec-borrar]');
  if (bo) {
    const r = rec(bo.dataset.recBorrar);
    if (!r || !esFundador()) return true;
    const ok = await confirmar({ titulo: 'Borrar recurso', texto: `Se borra "${r.titulo}".`, detalle: 'No se puede deshacer.', ok: 'Borrar' });
    if (ok) await guardar(() => borrarFila(T_REC, r.id), { ok: 'Recurso borrado.', luego: () => api.refrescar(), control: bo });
    return true;
  }
  return false;
}
