/* Semáforo de "Última llamada" (102), compartido por Clientes, Maestro y Hoy.
   La fecha sale de cs_v_ultima_llamada (la más reciente entre las llamadas cargadas en la
   ficha, las calls realizadas y los seguimientos por call o reunión, también las de Fathom
   asignadas al alumno). Los umbrales son por programa (cs_servicio_config, 123; por defecto
   los de js/config.js). Solo aplica a alumnos vivos (onboarding, activo, en renovación): el resto
   muestra "—". Sin llamadas registradas: gris. */
import { esc, fmtFecha, plural, hoyAR, diasEntre } from '../ui.js';
import { esVivo } from '../datos.js';
import { traerUltimasLlamadas } from '../datos-llamadas.js';
import { umbralesLlamada, cargarUmbrales } from '../datos-servicio.js';

const FUENTE = { llamada: 'llamada cargada en la ficha', call: 'call realizada', seguimiento: 'seguimiento por call o reunión' };

/* Días desde la fecha hasta hoy (0 si es hoy). null si no hay fecha. */
export function diasSinLlamada(fecha) {
  if (!fecha) return null;
  const d = diasEntre(fecha, hoyAR());
  return d == null ? null : Math.max(0, d);
}

export function nivelLlamada(dias) {
  if (dias == null) return 'gris';
  const u = umbralesLlamada();   /* por programa (123); cargarUmbrales corre antes de pintar */
  if (dias >= u.alerta) return 'rojo';
  if (dias >= u.aviso) return 'amarillo';
  return 'verde';
}

export { cargarUmbrales, umbralesLlamada };

export function textoDias(dias) {
  return dias === 0 ? 'hoy' : `hace ${plural(dias, 'día')}`;
}

/* Pega ultima_llamada y ultima_llamada_fuente en cada fila. Nunca tira.
   Devuelve false si la 102 no está corrida (la columna no se muestra). */
export async function sumarUltimaLlamada(programaId, filas) {
  let mapa = null;
  await cargarUmbrales(programaId);
  try {
    mapa = await traerUltimasLlamadas(programaId);
  } catch (e) {
    console.error('ultima llamada', e);
  }
  if (!mapa) return false;
  for (const f of filas) {
    const u = mapa.get(f.id);
    f.ultima_llamada = u ? u.fecha : null;
    f.ultima_llamada_fuente = u ? u.fuente : null;
  }
  return true;
}

/* Para ordenar: más reciente primero; sin llamadas y no vivos al final. */
export function ordenUltimaLlamada(f) {
  if (!esVivo(f)) return 100000;
  const d = diasSinLlamada(f.ultima_llamada);
  return d == null ? 99999 : d;
}

/* Celda: punto de color + "hace N días". */
export function celdaUltimaLlamada(f) {
  if (!esVivo(f)) {
    return '<span class="txt-gris" title="El semáforo solo se calcula para alumnos activos">—</span>';
  }
  const d = diasSinLlamada(f.ultima_llamada);
  if (d == null) {
    return '<span class="ll-sem"><span class="sem-dot sem-gris"></span><span class="txt-gris">sin llamadas</span></span>';
  }
  const nivel = nivelLlamada(d);
  const fuente = FUENTE[f.ultima_llamada_fuente] || '';
  const tit = `${fmtFecha(f.ultima_llamada)}${fuente ? ' · ' + fuente : ''}`;
  return `<span class="ll-sem" title="${esc(tit)}"><span class="sem-dot sem-${nivel}"></span>${esc(textoDias(d))}</span>`;
}

/* Maestro: la celda es un botón que abre la sección de llamadas de la ficha (?sec=llamadas),
   igual que las demás calculadas (maestro-acciones.js). */
export function celdaUltimaLlamadaMaestro(f) {
  return `<button type="button" class="m-ir" data-mx-ir="llamadas" data-id="${esc(f.id)}"
    title="Abrir las llamadas y accionables en la ficha">${celdaUltimaLlamada(f)}</button>`;
}

/* Definición de la columna para Clientes y Maestro. */
export function columnaUltimaLlamada(cls = '', td = celdaUltimaLlamada) {
  return { k: 'ultima_llamada', lab: 'Última llamada', cls, ord: ordenUltimaLlamada, td };
}
