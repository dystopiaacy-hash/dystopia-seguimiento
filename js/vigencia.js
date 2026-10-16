/* Alumno vigente (162): vivo (onboarding, activo, en renovación) y que NO esté vencido hace más de
   DIAS_VENCIDO_COMO_ACTIVO días. Lo vencido hace más que eso es un alumno que
   se fue sin renovar: la base lo pasa a "finalizado" (migración 162 y el cierre diario); esto solo evita
   contarlo como activo en las listas mientras el dato no se corrigió. */
import { esVivo } from './datos.js';
import { DIAS_VENCIDO_COMO_ACTIVO } from './config.js';

/* Misma regla que la base: el cierre diario finaliza al vencido aunque tenga una renovación abierta. */
export function vencidoSinRenovar(c) {
  const d = c.dias_restantes == null ? null : Number(c.dias_restantes);
  return d != null && d < -DIAS_VENCIDO_COMO_ACTIVO;
}

export const esVigente = c => esVivo(c) && !vencidoSinRenovar(c);
