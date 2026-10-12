/* Usuario de solo lectura (cs_accesos.nivel = 'lectura'): corta toda escritura en el
   cliente antes de que llegue a la base. La protección real es la RLS (cs_puede_editar,
   migración 079); esto evita el "Guardado." falso: un UPDATE que la RLS filtra devuelve
   0 filas sin error. Cualquier insert, update, upsert, delete o rpc de escritura falla
   con un error claro, que las vistas ya muestran como toast y revierten la celda. */
import { sb } from './supabase.js';
import { soloLectura } from './sesion.js';

/* RPC que solo leen (o son del formulario público): el resto se bloquea. */
const RPC_LECTURA = new Set(['cs_cola_hoy', 'cs_altas_pendientes', 'cs_form_publico']);
const ESCRITURAS = ['insert', 'update', 'upsert', 'delete'];

function errorLectura() {
  const e = new Error('Tu usuario es de solo lectura: no puede modificar datos.');
  e.code = '42501';
  return e;
}

export function activarSoloLectura() {
  if (!soloLectura() || sb.__soloLectura) return;
  sb.__soloLectura = true;
  document.body.classList.add('solo-lectura');

  const from = sb.from.bind(sb);
  sb.from = tabla => {
    const q = from(tabla);
    for (const m of ESCRITURAS) q[m] = () => { throw errorLectura(); };
    return q;
  };

  const rpc = sb.rpc.bind(sb);
  sb.rpc = (nombre, ...resto) => (RPC_LECTURA.has(nombre) ? rpc(nombre, ...resto) : Promise.reject(errorLectura()));
}
