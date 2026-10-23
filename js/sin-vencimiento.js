/* Productos sin vencimiento (Skool de agus).
   En la base el alumno tiene una fecha de fin muy lejana (cs_productos.duracion_dias = 36500; la
   carga inicial usa 2099-12-31). Acá se detecta esa fecha para no mostrar "27.000 días" ni
   avisar renovaciones: los días restantes pasan a null (todas las vistas ya muestran "—" o lo
   dejan afuera cuando dias_restantes es null). */
import { SIN_VENCIMIENTO_DESDE, SIN_VENCIMIENTO_DIAS } from './config.js';

/* fecha = 'YYYY-MM-DD' (fecha_fin de cs_clientes). */
export const sinVencimiento = fecha => typeof fecha === 'string' && fecha >= SIN_VENCIMIENTO_DESDE;

/* Producto de cs_productos sin vencimiento. */
export const productoSinVencimiento = pr => !!pr && Number(pr.duracion_dias) >= SIN_VENCIMIENTO_DIAS;

/* Filas de cs_v_clientes / cs_v_maestro: sin vencimiento no tiene días restantes. */
export function sinVencimientoFilas(filas) {
  for (const f of filas || []) if (f && sinVencimiento(f.fecha_fin)) f.dias_restantes = null;
  return filas;
}
export function sinVencimientoFila(fila) {
  if (fila && sinVencimiento(fila.fecha_fin)) fila.dias_restantes = null;
  return fila;
}
