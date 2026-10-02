/* "Clientes nuevos" de la pestaña Hoy: las ventas de Finanzas que todavía no son
   cliente (cs_altas_pendientes, 070). Una tarjeta por venta: se elige producto y
   estado inicial y se crea, o se descarta con "No es nuevo".
   Vive en su propio contenedor: la cola se repinta entera a cada rato y acá hay
   campos a medio completar. Si falta la 070 (o la RPC falla) no se muestra nada. */
import { esc, fmtFecha, toast } from '../ui.js';
import { mensajeError } from '../datos.js';
import { traerAltasPendientes, crearClienteDesdePago, descartarAlta } from '../datos-hoy.js';
import { traerProductos, opcionesProducto } from '../ciclo.js';

const ESTADOS = [['onboarding', 'Onboarding'], ['activo', 'Activo']];

const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/\s+/g, ' ').trim();

/* El producto cuyo nombre aparece en el texto de programa del pago. Si hay más de
   uno, el de nombre más largo ("Mentoría Pro" le gana a "Mentoría"). */
function productoSugerido(productos, texto) {
  const t = norm(texto);
  let mejor = '', largo = 0;
  for (const pr of productos) {
    const n = norm(pr.nombre);
    if (n && n.length > largo && t.includes(n)) { mejor = pr.id; largo = n.length; }
  }
  return mejor;
}

/* Las RPC de la 070 ya traen el mensaje en castellano ("cs: ..."): va tal cual. */
const mensajeAlta = e => /^cs: /.test(e && e.message || '') ? e.message.slice(4) : mensajeError(e);

function toastFicha(programaId, clienteId, nombre) {
  const t = document.createElement('div');
  t.className = 'toast';
  t.setAttribute('role', 'status');
  t.append(`${nombre} ya es cliente.`);
  const a = document.createElement('a');
  a.className = 'hoy-toast-link';
  a.href = `#/p/${encodeURIComponent(programaId)}/c/${encodeURIComponent(clienteId)}`;
  a.textContent = 'Abrir ficha';
  a.addEventListener('click', () => t.remove());
  t.append(a);
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 6000);
}

function tarjeta(a, f, opciones, ocupada) {
  const dis = ocupada ? ' disabled' : '';
  const ops = [['', 'Elegí un producto']].concat(opciones).map(([v, label]) =>
    `<option value="${esc(v)}"${v === f.producto ? ' selected' : ''}>${esc(label)}</option>`).join('');
  const chips = ESTADOS.map(([v, label]) =>
    `<button type="button" class="hoy-chip${f.estado === v ? ' on' : ''}" data-estado="${v}" aria-pressed="${f.estado === v}"${dis}>${label}</button>`).join('');
  const descarte = f.descartando ? `
      <div class="hoy-alta-descarte">
        <input type="text" data-campo="motivo" maxlength="200" autocomplete="off" placeholder="Motivo (opcional)" aria-label="Motivo del descarte" value="${esc(f.motivo)}"${dis}>
        <button type="button" class="btn btn-sm btn-danger" data-accion="confirmar"${dis}>Confirmar</button>
        <button type="button" class="btn btn-sm btn-ghost" data-accion="cancelar"${dis}>Cancelar</button>
      </div>` : '';
  return `
    <article class="hoy-alta${ocupada ? ' ocupada' : ''}" data-clave="${esc(a.pago_clave)}">
      <div class="hoy-card-main">
        <div class="hoy-card-top">
          <span class="hoy-alta-nombre">${esc(a.alumno || 'Sin nombre')}</span>
          <span class="hoy-tipo">Venta del ${esc(fmtFecha(a.fecha))}</span>
        </div>
        ${a.concepto ? `<div class="hoy-titulo">${esc(a.concepto)}</div>` : ''}
        ${a.programa ? `<div class="hoy-detalle">Programa en el pago: ${esc(a.programa)}</div>` : ''}
      </div>
      <div class="hoy-alta-form">
        <select data-campo="producto" aria-label="Producto"${dis}>${ops}</select>
        <div class="hoy-chips" role="group" aria-label="Estado inicial">${chips}</div>
      </div>
      <div class="hoy-card-acc">
        <button type="button" class="btn btn-sm btn-accent" data-accion="crear"${ocupada || !f.producto ? ' disabled' : ''}>Crear cliente</button>
        ${f.descartando ? '' : `<button type="button" class="btn btn-sm" data-accion="descartar"${dis}>No es nuevo</button>`}
      </div>${descarte}
    </article>`;
}

/* alCambiar(recargarCola): avisa a hoy.js que cambió la cantidad (contador de arriba)
   y, al crear un cliente, que la cola tiene tareas nuevas. */
export function montarAltas(box, programaId, vigente, alCambiar) {
  let altas = [], productos = null, pedido = 0;
  const form = new Map();       // por pago_clave: { producto, estado, descartando, motivo }
  const ocupadas = new Set();   // llamada en vuelo: tarjeta bloqueada

  function estadoDe(a) {
    if (!form.has(a.pago_clave)) {
      form.set(a.pago_clave, { producto: productoSugerido(productos || [], a.programa),
        estado: 'onboarding', descartando: false, motivo: '' });
    }
    return form.get(a.pago_clave);
  }

  function pintar() {
    if (!altas.length) { box.innerHTML = ''; return; }
    const opciones = opcionesProducto(productos || [], null);
    box.innerHTML = `<section class="hoy-grupo hoy-altas">
      <div class="section-title">Clientes nuevos <span class="hoy-grupo-n hoy-n-altas">${altas.length}</span><span class="line"></span></div>
      ${altas.map(a => tarjeta(a, estadoDe(a), opciones, ocupadas.has(a.pago_clave))).join('')}
    </section>`;
  }

  /* Nunca tira: si falla, la sección queda vacía y el resto de la pantalla sigue. Un
     refresco que trae las mismas ventas no repinta (hay campos a medio completar). */
  async function cargar() {
    const n = ++pedido;
    let filas = [];
    try {
      if (!productos) {
        productos = await traerProductos(programaId)
          .then(l => l.filter(pr => pr.activo), e => { console.error('productos', e); return null; });
      }
      filas = await traerAltasPendientes(programaId);
    } catch (e) {
      if (e && e.code !== 'PGRST202') console.error('altas', e);
    }
    if (!vigente() || n !== pedido) return;
    const antes = altas.map(a => a.pago_clave).join('|');
    altas = filas;
    for (const k of [...form.keys()]) if (!altas.some(a => a.pago_clave === k)) form.delete(k);
    if (altas.map(a => a.pago_clave).join('|') === antes && (box.innerHTML || !altas.length)) return;
    pintar();
    alCambiar(false);
  }

  /* Una sola llamada por tarjeta a la vez. Si sale bien, la tarjeta se va. */
  async function correr(a, fn, alSalir, recargarCola) {
    const k = a.pago_clave;
    if (ocupadas.has(k)) return;
    ocupadas.add(k);
    pintar();
    let ok = false, res;
    try {
      res = await fn();
      ok = true;
    } catch (e) {
      toast(mensajeAlta(e), 'error');
      /* Ya creado por otro, o el pago cambió en la planilla: la lista quedó vieja. */
      if (e && (e.code === '23505' || e.code === 'P0002')) cargar();
    } finally {
      ocupadas.delete(k);
    }
    if (ok) {
      altas = altas.filter(x => x.pago_clave !== k);
      form.delete(k);
      alSalir(res);
    }
    if (!vigente()) return;
    pintar();
    if (ok) alCambiar(recargarCola);
  }

  function crear(a) {
    const f = estadoDe(a);
    if (!f.producto) return;
    correr(a, () => crearClienteDesdePago(programaId, a.pago_clave, f.producto, f.estado),
      id => id ? toastFicha(programaId, id, a.alumno || 'El alumno') : toast('Cliente creado.'), true);
  }

  function descartar(a) {
    const f = estadoDe(a);
    correr(a, () => descartarAlta(programaId, a.pago_clave, f.motivo),
      () => toast('Venta descartada: no es un cliente nuevo.'), false);
  }

  const altaDe = nodo => {
    const card = nodo.closest('.hoy-alta');
    return card ? altas.find(a => a.pago_clave === card.dataset.clave) : null;
  };

  box.addEventListener('click', ev => {
    const a = altaDe(ev.target);
    if (!a || ocupadas.has(a.pago_clave)) return;
    const f = estadoDe(a);
    const chip = ev.target.closest('[data-estado]');
    if (chip) { f.estado = chip.dataset.estado; pintar(); return; }
    const btn = ev.target.closest('[data-accion]');
    if (!btn) return;
    const accion = btn.dataset.accion;
    if (accion === 'crear') crear(a);
    else if (accion === 'confirmar') descartar(a);
    else if (accion === 'descartar' || accion === 'cancelar') {
      f.descartando = accion === 'descartar';
      pintar();
      const campo = f.descartando && [...box.querySelectorAll('.hoy-alta')]
        .find(c => c.dataset.clave === a.pago_clave)?.querySelector('[data-campo="motivo"]');
      if (campo) campo.focus();
    }
  });

  box.addEventListener('change', ev => {
    if (ev.target.dataset.campo !== 'producto') return;
    const a = altaDe(ev.target);
    if (!a) return;
    estadoDe(a).producto = ev.target.value;
    ev.target.closest('.hoy-alta').querySelector('[data-accion="crear"]').disabled = !ev.target.value;
  });

  box.addEventListener('input', ev => {
    if (ev.target.dataset.campo !== 'motivo') return;
    const a = altaDe(ev.target);
    if (a) estadoDe(a).motivo = ev.target.value;
  });

  box.addEventListener('keydown', ev => {
    if (ev.target.dataset.campo !== 'motivo') return;
    const a = altaDe(ev.target);
    if (!a) return;
    if (ev.key === 'Enter') { ev.preventDefault(); descartar(a); }
    else if (ev.key === 'Escape') { estadoDe(a).descartando = false; pintar(); }
  });

  cargar();
  return { cantidad: () => altas.length, cargar };
}
