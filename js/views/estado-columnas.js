/* Clientes y Maestro: columnas "En qué está", "Próximos pasos", "Satisfacción" y "Upsell" (106),
   y la regla de "Sugerido para upsell".
   Los datos salen de cs_v_alumno_resumen (datos-estado.js). Sin la 106, sumarResumenAlumno
   devuelve false y las columnas no existen: la planilla queda como siempre.
   Las claves (en_que_esta, proximos_pasos, satisfaccion_ultima, upsell) son del sistema en
   cs_maestro_claves_sistema(): se pueden renombrar y ocultar como las demás. */
import { esc, fmtFecha, hoyAR, diasEntre } from '../ui.js';
import { esVivo, renAbierta, REN_LABEL } from '../datos.js';
import { traerResumenPrograma } from '../datos-estado.js';
import { nivelLlamada, diasSinLlamada } from './llamada-semaforo.js';
import {
  SATISF_ROJO_MENOS, SATISF_VERDE_DESDE, UPSELL_WINS_DIAS, UPSELL_PUNTAJE_MIN
} from '../config.js';

const CAMPOS = [
  'estado_llamada_id', 'estado_fecha', 'en_que_esta', 'proximos_pasos', 'sat_puntaje', 'sat_momento',
  'sat_at', 'wins_30d', 'ultimo_win', 'referidos_pendientes', 'upsell_marcado', 'upsell_motivo', 'upsell_at'
];

/* Pega los campos del resumen en cada fila (por id). Nunca tira. false = 106 sin correr. */
export async function sumarResumenAlumno(programaId, filas) {
  let mapa = null;
  try {
    mapa = await traerResumenPrograma(programaId);
  } catch (e) {
    console.error('resumen alumno', e);
  }
  if (!mapa) return false;
  for (const f of filas) {
    const r = mapa.get(f.id);
    for (const k of CAMPOS) f[k] = r ? r[k] : null;
  }
  return true;
}

/* ---------- Satisfacción ---------- */

export const nivelPuntaje = p => (p == null ? 'gris' : p < SATISF_ROJO_MENOS ? 'rojo' : p >= SATISF_VERDE_DESDE ? 'verde' : 'amarillo');

/* Punto de color + "8/10". Sin respuestas: "—". */
export function celdaPuntaje(f) {
  if (f.sat_puntaje == null) return '<span class="txt-gris">—</span>';
  const tit = `${f.sat_momento || 'Satisfacción'}${f.sat_at ? ' · ' + fmtFecha(String(f.sat_at).slice(0, 10)) : ''}`;
  return `<span class="ll-sem" title="${esc(tit)}"><span class="sem-dot sem-${nivelPuntaje(f.sat_puntaje)}"></span>${esc(f.sat_puntaje)}/10</span>`;
}

/* ---------- Upsell ---------- */

/* Regla simple y visible (valores en js/config.js). Necesita ultima_llamada (sumarUltimaLlamada)
   y renovacion_estado (Maestro) cuando existen; si faltan, no frenan. */
export function sugeridoUpsell(f) {
  if (!esVivo(f) || f.upsell_marcado || renAbierta(f.renovacion_estado)) return false;
  if (!f.ultimo_win) return false;
  const d = diasEntre(f.ultimo_win, hoyAR());
  if (d == null || d > UPSELL_WINS_DIAS) return false;
  if (f.sat_puntaje != null && f.sat_puntaje < UPSELL_PUNTAJE_MIN) return false;
  return nivelLlamada(diasSinLlamada(f.ultima_llamada)) !== 'rojo';
}

export const TEXTO_REGLA_UPSELL = `Al menos un win en los últimos ${UPSELL_WINS_DIAS} días, último puntaje de `
  + `satisfacción de ${UPSELL_PUNTAJE_MIN} o más (si tiene) y semáforo de última llamada que no esté en rojo.`;

/* 'en_resell' (ya hay pipeline abierto: la marca ya cumplió su función) | 'marcado' | 'sugerido' | ''. */
export function estadoUpsell(f) {
  if (renAbierta(f.renovacion_estado)) return 'en_resell';
  if (f.upsell_marcado) return 'marcado';
  return sugeridoUpsell(f) ? 'sugerido' : '';
}

export function celdaUpsell(f) {
  const e = estadoUpsell(f);
  if (e === 'en_resell') {
    return `<span class="est-chip est-resell" title="Ya tiene un pipeline de resell abierto">En resell · ${esc(REN_LABEL[f.renovacion_estado] || f.renovacion_estado)}</span>`;
  }
  if (e === 'marcado') {
    const tit = `${f.upsell_motivo || ''}${f.upsell_at ? ' · ' + fmtFecha(String(f.upsell_at).slice(0, 10)) : ''}`;
    return `<span class="est-chip est-listo" title="${esc(tit)}">Listo</span>`;
  }
  if (e === 'sugerido') {
    return `<span class="est-chip est-sugerido" title="${esc('Regla: ' + TEXTO_REGLA_UPSELL)}">Sugerido</span>`;
  }
  return '<span class="txt-gris">—</span>';
}

/* Filtro: '' | 'listo' | 'sugerido' | 'ambos'. */
export function pasaUpsell(f, valor) {
  if (!valor) return true;
  const e = estadoUpsell(f);
  if (valor === 'listo') return e === 'marcado';
  if (valor === 'sugerido') return e === 'sugerido';
  return e === 'marcado' || e === 'sugerido';
}

export const OPCIONES_UPSELL = [
  ['', 'Todos'], ['ambos', 'Listo o sugerido'], ['listo', 'Listo (marcado)'], ['sugerido', 'Sugerido']
];

/* ---------- Columnas ---------- */

const texto = (f, k) => {
  const v = (f[k] || '').trim();
  if (!v) return '<span class="txt-gris">—</span>';
  const tit = `${v}${f.estado_fecha ? '\n(llamada del ' + fmtFecha(f.estado_fecha) + ')' : ''}`;
  return `<span class="est-txt" title="${esc(tit)}">${esc(v)}</span>`;
};

/* maestro = true: la celda es un botón que abre la sección de la ficha (?sec=), como las otras calculadas. */
const envolver = (sec, html, f, maestro) => (maestro
  ? `<button type="button" class="m-ir" data-mx-ir="${sec}" data-id="${esc(f.id)}" title="Abrir en la ficha">${html}</button>`
  : html);

export function columnasEstado(cls, maestro = false) {
  const ordTxt = k => f => (f[k] || '').trim().toLowerCase() || '~';
  return [
    { k: 'en_que_esta', lab: 'En qué está', cls: `${cls} est-col`, ord: ordTxt('en_que_esta'),
      td: f => envolver('estado', texto(f, 'en_que_esta'), f, maestro) },
    { k: 'proximos_pasos', lab: 'Próximos pasos', cls: `${cls} est-col`, ord: ordTxt('proximos_pasos'),
      td: f => envolver('estado', texto(f, 'proximos_pasos'), f, maestro) },
    { k: 'satisfaccion_ultima', lab: 'Satisfacción', cls, ord: f => (f.sat_puntaje == null ? 99 : f.sat_puntaje),
      td: f => envolver('satisfaccion', celdaPuntaje(f), f, maestro) },
    { k: 'upsell', lab: 'Upsell', cls,
      ord: f => ({ marcado: 0, sugerido: 1, en_resell: 2 }[estadoUpsell(f)] ?? 3),
      td: f => envolver('wins', celdaUpsell(f), f, maestro) }
  ];
}
