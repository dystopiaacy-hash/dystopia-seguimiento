/* Constructor de formularios — vista de respuestas de UN formulario.
   Tabla con filtro por cliente y por fecha, y export CSV. Todo lo que se muestra
   viene de cs_respuestas.respuestas, que es input de extraños: pasa por esc().
   Las columnas son los campos ACTUALES del formulario; si se agregó un campo
   después, las respuestas viejas lo muestran vacío (no se inventa nada). */
import { esc, fmtFechaHora, fechaISO_AR, descargarCSV, abrirModal, plural } from '../ui.js';
import { opcionesHtml } from './comunes.js';

/* Un valor guardado (texto, número o booleano) como texto para tabla y CSV. */
export function valorTexto(v) {
  if (v === true) return 'Sí';
  if (v === false) return 'No';
  if (v == null || v === '') return '';
  return String(v);
}

function nombreCliente(r, mapaClientes) {
  const c = r.cliente_id ? mapaClientes.get(r.cliente_id) : null;
  return c ? c.nombre : 'Cliente borrado';
}

/* Filtra por cliente y por rango de fechas de negocio (Buenos Aires). */
function filtrar(respuestas, { cliente, desde, hasta }) {
  return respuestas.filter(r => {
    if (cliente && r.cliente_id !== cliente) return false;
    const dia = fechaISO_AR(r.created_at);
    if (desde && dia < desde) return false;
    if (hasta && dia > hasta) return false;
    return true;
  });
}

function tabla(form, filas, mapaClientes) {
  if (!filas.length) {
    return '<div class="muted-empty">No hay respuestas con esos filtros.</div>';
  }
  const campos = form.campos || [];
  const encabezados = campos.map(c => `<th scope="col">${esc(c.label)}</th>`).join('');
  const cuerpo = filas.map(r => `
    <tr>
      <td>${esc(fmtFechaHora(r.created_at))}</td>
      <td>${esc(nombreCliente(r, mapaClientes))}</td>
      <td class="num">${r.puntaje == null ? '—' : esc(r.puntaje)}</td>
      ${campos.map(c => {
        const t = valorTexto((r.respuestas || {})[c.key]);
        return `<td title="${esc(t)}">${esc(t) || '<span class="txt-gris">—</span>'}</td>`;
      }).join('')}
    </tr>`).join('');
  return `
    <div class="table-card resp-tabla">
      <table class="data-table data-table-dense">
        <thead><tr>
          <th scope="col">Fecha</th><th scope="col">Cliente</th><th scope="col" class="num">Puntaje</th>
          ${encabezados}
        </tr></thead>
        <tbody>${cuerpo}</tbody>
      </table>
    </div>
    <div class="table-foot">${esc(plural(filas.length, 'respuesta'))}</div>`;
}

function filasCSV(form, filas, mapaClientes) {
  const campos = form.campos || [];
  const out = [['Fecha', 'Cliente', 'Puntaje', ...campos.map(c => c.label)]];
  for (const r of filas) {
    out.push([
      fmtFechaHora(r.created_at),
      nombreCliente(r, mapaClientes),
      r.puntaje == null ? '' : r.puntaje,
      ...campos.map(c => valorTexto((r.respuestas || {})[c.key]))
    ]);
  }
  return out;
}

/* Abre el modal de respuestas de un formulario.
   respuestas = las de ESE formulario, ya ordenadas de la más nueva a la más vieja. */
export function abrirRespuestas({ form, respuestas, clientes, mapaClientes }) {
  const filtros = { cliente: '', desde: '', hasta: '' };

  /* Solo los clientes que efectivamente respondieron: un select con los 30 clientes
     del programa para 4 respuestas no ayuda a nadie. */
  const conRespuesta = new Set(respuestas.map(r => r.cliente_id).filter(Boolean));
  const paresCliente = [['', 'Todos']].concat(
    (clientes || []).filter(c => conRespuesta.has(c.id)).map(c => [c.id, c.nombre])
  );

  const m = abrirModal({
    titulo: `Respuestas · ${form.nombre}`,
    ancho: true,
    cuerpo: `
      <div class="filter-row">
        <span class="fgroup">
          <label class="flabel" for="r-cli">Cliente</label>
          <select id="r-cli">${opcionesHtml(paresCliente, '')}</select>
        </span>
        <span class="fgroup">
          <label class="flabel" for="r-desde">Desde</label>
          <input type="date" id="r-desde">
        </span>
        <span class="fgroup">
          <label class="flabel" for="r-hasta">Hasta</label>
          <input type="date" id="r-hasta">
        </span>
        <button type="button" class="btn btn-sm" id="r-csv">Exportar CSV</button>
      </div>
      <div id="r-tabla"></div>`
  });

  const cont = m.el.querySelector('#r-tabla');
  const pintar = () => { cont.innerHTML = tabla(form, filtrar(respuestas, filtros), mapaClientes); };

  m.el.querySelector('#r-cli').addEventListener('change', e => { filtros.cliente = e.target.value; pintar(); });
  m.el.querySelector('#r-desde').addEventListener('change', e => { filtros.desde = e.target.value; pintar(); });
  m.el.querySelector('#r-hasta').addEventListener('change', e => { filtros.hasta = e.target.value; pintar(); });
  m.el.querySelector('#r-csv').addEventListener('click', () => {
    const filas = filtrar(respuestas, filtros);
    descargarCSV(`respuestas-${form.nombre}.csv`.replace(/[\\/:*?"<>|]/g, '-'),
                 filasCSV(form, filas, mapaClientes));
  });

  pintar();
  return m;
}
