/* Pantalla Llamadas dividida en secciones: consultorías semanales, 1 a 1, clases, ventas, internas y sin clasificar.
   Solo agrupa lo que la base ya devuelve (cs_v_fathom_llamadas, propuestas de la IA, horarios y consultorías
   registradas): NO decide quién ve qué (la RLS ya lo hizo: un cliente solo recibe lo de su programa) ni cambia datos.
   Una llamada pertenece a UNA sección, en este orden:
     1. asignada a un alumno                            -> 1 a 1
     2. tipo que le puso una persona (clasificacion)    -> clases / ventas / internas (otra -> sin clasificar)
     3. cae en un horario de cs_consultoria_horarios    -> consultorías semanales (misma regla que la sync: consultor,
        día de la semana en hora Argentina y arranque dentro de la tolerancia)
     4. interna automática (nadie de afuera)            -> internas
     5. propuesta pendiente de la IA                    -> según su tipo (queda marcada como propuesta)
     6. el resto                                        -> sin clasificar
   Las consultorías ya registradas (cs_consultorias, 157) no están en la vista: se suman aparte y se evita el duplicado
   por consultor + hora de inicio. */
import { esc } from '../ui.js';
import { DIAS_SEMANA } from '../datos-consultorias.js';
import { TIPO_PROPUESTA_LABEL, CONFIANZA_LABEL } from '../datos-fathom-ia.js';

export const SECCIONES = [
  { key: 'consultorias', label: 'Consultorías semanales',
    ayuda: 'Reuniones que cayeron en un horario de consultoría grupal (día y hora de Configuración > Consultorías grupales). No son llamadas de un alumno.' },
  { key: 'uno', label: '1 a 1',
    ayuda: 'Llamadas ya asignadas a un alumno. Las «por nombre» se asignaron por coincidencia de nombre: confirmalas o corregilas.' },
  { key: 'clases', label: 'Clases', ayuda: 'Clases grupales (clasificadas por una persona, o propuestas por la IA y todavía sin aceptar).' },
  { key: 'ventas', label: 'Ventas', ayuda: 'Llamadas de venta, con prospectos (clasificadas o propuestas por la IA).' },
  { key: 'internas', label: 'Internas', ayuda: 'Reuniones del equipo, sin nadie de afuera.' },
  { key: 'sin', label: 'Sin clasificar', ayuda: 'Pendientes sin tipo ni propuesta, y las marcadas «otra» o «no es alumno» sin tipo. Acá se asigna a mano.' }
];
const DEL_TIPO_PROP = { consultoria_1a1: 'uno', clase_grupal: 'clases', venta: 'ventas', interna: 'internas', otra: 'sin' };
const DE_CLASIF = { clase_grupal: 'clases', venta: 'ventas', interna: 'internas', otra: 'sin' };

const DIA_ISO = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
const DIA_NOMBRE = Object.fromEntries(DIAS_SEMANA);
const fmtArt = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/Argentina/Buenos_Aires', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
});

/* { dia: 1..7, min: minutos desde las 0:00 } en hora Argentina, o null si no hay fecha. */
export function diaHoraArt(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const p = Object.fromEntries(fmtArt.formatToParts(d).map(x => [x.type, x.value]));
  const dia = DIA_ISO[p.weekday];
  return dia ? { dia, min: Number(p.hour) * 60 + Number(p.minute) } : null;
}
const aMin = h => { const [a, b] = String(h || '').split(':'); return Number(a) * 60 + Number(b || 0); };
export const hhmm = min => `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;

/* Horario activo más cercano (mismo consultor, mismo día ART, dentro de la tolerancia) o null. */
export function horarioDe(l, horarios) {
  const t = diaHoraArt(l.inicio_at);
  if (!t) return null;
  let mejor = null, dif = Infinity;
  for (const h of horarios || []) {
    if (!h.activo || h.consultor !== l.consultor || h.dia_semana !== t.dia) continue;
    const d = Math.abs(t.min - aMin(h.hora));
    if (d <= h.tolerancia_min && d < dif) { mejor = h; dif = d; }
  }
  return mejor;
}

/* Una consultoría registrada (cs_consultorias) con la forma de una fila de la vista. */
function comoLlamada(c) {
  const inv = (Array.isArray(c.invitados) ? c.invitados : []).map(i => (i && (i.nombre || i.email)) || '').filter(Boolean);
  return {
    id: 'c:' + c.id, estado: 'consultoria', consultor: c.consultor, fecha: c.fecha, inicio_at: c.inicio_at,
    titulo: c.titulo, tipo: null, duracion_min: c.duracion_min, grabacion_url: c.grabacion_url,
    grabacion_share_url: c.grabacion_share_url, resumen: c.resumen, en_que_esta: null, proximos_pasos: null,
    cliente_id: null, programa_id: c.programa_id, alumno_nombre: null, invitados: inv, motivo: null, candidatos: [],
    asignada_por: null, clasificacion: null
  };
}

/* [{ l, seccion, prop, horario, programa, registrada }] para todo lo que hay que mostrar. */
export function armarItems({ llamadas, registradas, horarios, props, alumnos }) {
  const propDe = new Map((props || []).map(p => [p.llamada_id, p]));
  const progDe = new Map((alumnos || []).map(a => [a.id, a.programa_id]));
  const hPorId = new Map((horarios || []).map(h => [h.id, h]));
  const clave = l => `${l.consultor || ''}|${l.inicio_at ? new Date(l.inicio_at).getTime() : l.id}`;
  const yaRegistradas = new Set((registradas || []).map(c => clave(c)));
  const items = [];

  for (const c of registradas || []) {
    const l = comoLlamada(c);
    items.push({ l, seccion: 'consultorias', prop: null, horario: hPorId.get(c.horario_id) || horarioDe(l, horarios),
      programa: c.programa_id || null, registrada: true });
  }
  for (const l of llamadas || []) {
    if (yaRegistradas.has(clave(l))) continue;          // ya figura como consultoría registrada
    const prop = l.estado !== 'alumno' ? propDe.get(l.id) || null : null;
    let seccion, horario = null;
    if (l.estado === 'alumno') seccion = 'uno';
    else if (l.estado === 'no_alumno' && l.clasificacion) seccion = DE_CLASIF[l.clasificacion] || 'sin';
    else if ((horario = horarioDe(l, horarios))) seccion = 'consultorias';
    else if (l.estado === 'interna') seccion = 'internas';
    else if (prop) seccion = DEL_TIPO_PROP[prop.tipo] || 'sin';
    else seccion = 'sin';
    /* Programa: el de la ficha, el del horario, el del alumno propuesto o el del primer candidato de la sync. */
    let programa = l.programa_id || (horario && horario.programa_id) || null;
    if (!programa && prop && prop.alumno_id) programa = progDe.get(prop.alumno_id) || null;
    if (!programa) {
      const c = (Array.isArray(l.candidatos) ? l.candidatos : []).map(id => progDe.get(id)).find(Boolean);
      programa = c || null;
    }
    items.push({ l, seccion, prop, horario, programa, registrada: false });
  }
  return items;
}

const diaTxt = (l, h) => {
  const t = diaHoraArt(l.inicio_at);
  if (t) return `${DIA_NOMBRE[t.dia] || ''} ${hhmm(t.min)} (hora Argentina)`;
  return h ? `${DIA_NOMBRE[h.dia_semana] || ''} ${String(h.hora).slice(0, 5)}` : '';
};

/* Texto extra de la celda "Estado": día / horario / consultor de una consultoría, o la propuesta de la IA. */
export function extraItem(it, nombreConsultor) {
  const { l, horario, prop } = it;
  const partes = [];
  if (it.seccion === 'consultorias') {
    partes.push(`<span class="fa-estado fa-clasificada">Consultoría semanal</span>`);
    const dia = diaTxt(l, horario);
    partes.push(`<div class="hint">${esc(dia)}${l.consultor ? ` · consultor ${esc(nombreConsultor(l.consultor))}` : ''}</div>`);
    if (horario && horario.nota) partes.push(`<div class="hint">${esc(horario.nota)}</div>`);
    if (!it.registrada) partes.push('<div class="hint">Cae en el horario pero todavía no está registrada como consultoría: se hace con «Reclasificar» en Configuración.</div>');
  }
  if (prop) {
    partes.push(`<div class="hint fa-prop">Propuesta de la IA (sin aceptar): ${esc(TIPO_PROPUESTA_LABEL[prop.tipo] || prop.tipo)}
      · confianza ${esc((CONFIANZA_LABEL[prop.confianza] || prop.confianza || '').toLowerCase())}</div>`);
  }
  return partes.join('');
}
