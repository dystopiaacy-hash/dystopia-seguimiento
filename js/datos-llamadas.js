/* Datos de llamadas, accionables por llamada y recursos por alumno (102).
   Separado de datos.js por tamaño. Las escrituras van por las tablas cs_llamadas,
   cs_llamada_accionables y cs_llamada_recursos (RLS: ver = cs_puede_ver, escribir =
   cs_puede_editar, borrar = solo fundador). Sin la 102 las lecturas devuelven
   undefined / null y la app se ve como antes. */
import { sb } from './supabase.js';
import { urlSegura } from './ui.js';

/* La tabla o la vista no existe: 102 sin correr (42P01 de Postgres, PGRST205 de PostgREST). */
function faltaTabla(e) {
  return !!e && (e.code === '42P01' || e.code === 'PGRST205'
    || (/cs_llamad|cs_v_ultima_llamada/.test(e.message || '') && /does not exist|schema cache/i.test(e.message || '')));
}

/* ---------- Tipo de recurso por dominio ---------- */
export const TIPO_RECURSO_LABEL = {
  doc: 'Doc', sheet: 'Sheet', slides: 'Slides', drive: 'Drive', youtube: 'YouTube', loom: 'Loom', otro: 'Otro'
};
export const TIPO_RECURSO_ORDEN = ['doc', 'sheet', 'slides', 'drive', 'youtube', 'loom', 'otro'];

const esDominio = (host, d) => host === d || host.endsWith('.' + d);

/* Devuelve { tipo, host } de una URL (la que no se puede leer cae en 'otro'). */
export function detectarRecurso(url) {
  let u;
  try { u = new URL(String(url).trim()); } catch { return { tipo: 'otro', host: '' }; }
  const host = u.hostname.toLowerCase().replace(/^www\./, '');
  const ruta = u.pathname.toLowerCase();
  let tipo = 'otro';
  if (host === 'docs.google.com') {
    if (ruta.startsWith('/document')) tipo = 'doc';
    else if (ruta.startsWith('/spreadsheets')) tipo = 'sheet';
    else if (ruta.startsWith('/presentation')) tipo = 'slides';
  } else if (esDominio(host, 'drive.google.com')) tipo = 'drive';
  else if (esDominio(host, 'youtube.com') || host === 'youtu.be') tipo = 'youtube';
  else if (esDominio(host, 'loom.com')) tipo = 'loom';
  return { tipo, host };
}

/* ---------- Pegar varios de una vez ---------- */

/* Una línea por accionable. Las líneas con sangría (2+ espacios o tab) son subtareas de la
   última sin sangría. Se sacan viñetas (-, *, •). Devuelve [{ texto, sub }] sin vacías. */
export function parsearAccionables(texto) {
  const salida = [];
  let hayPadre = false;
  for (const crudo of String(texto || '').split(/\r?\n/)) {
    const sangria = /^(\t| {2,})/.test(crudo);
    const t = crudo.trim().replace(/^[-*•]\s+/, '').trim();
    if (!t) continue;
    const sub = sangria && hayPadre;
    if (!sub) hayPadre = true;
    salida.push({ texto: t.slice(0, 500), sub });
  }
  return salida;
}

/* Una línea por link: "https://..." o "Título | https://...". Las que no son http(s) se
   devuelven aparte para avisar. Devuelve { items: [{ titulo, url, tipo }], invalidas: [linea] }. */
export function parsearLinks(texto) {
  const items = [], invalidas = [];
  for (const crudo of String(texto || '').split(/\r?\n/)) {
    const linea = crudo.trim();
    if (!linea) continue;
    const i = linea.lastIndexOf('|');
    const url = urlSegura((i >= 0 ? linea.slice(i + 1) : linea).trim());
    if (!url) { invalidas.push(linea); continue; }
    const { tipo, host } = detectarRecurso(url);
    const titulo = (i >= 0 ? linea.slice(0, i).trim() : '') || host || url;
    items.push({ titulo: titulo.slice(0, 200), url, tipo });
  }
  return { items, invalidas };
}

/* ---------- Lecturas ---------- */

/* { llamadas, accionables, recursos } del alumno. undefined = 102 sin correr. */
export async function traerLlamadasCliente(clienteId) {
  const [ll, acc, rec] = await Promise.all([
    sb.from('cs_llamadas').select('*').eq('cliente_id', clienteId)
      .order('fecha', { ascending: false }).order('created_at', { ascending: false }),
    sb.from('cs_llamada_accionables').select('*').eq('cliente_id', clienteId)
      .order('orden').order('created_at'),
    sb.from('cs_llamada_recursos').select('*').eq('cliente_id', clienteId)
      .order('created_at', { ascending: false })
  ]);
  for (const r of [ll, acc, rec]) {
    if (r.error) {
      if (faltaTabla(r.error)) return undefined;
      throw r.error;
    }
  }
  return { llamadas: ll.data || [], accionables: acc.data || [], recursos: rec.data || [] };
}

/* Mapa cliente_id -> { fecha, fuente, modalidad, sinAlerta, onboarding, ultimaConsultoria }. null = 102 sin
   correr. Con la 157 la vista trae modalidad (grupal / vip), sin_alerta (grupal sin datos de asistencia: no se
   alerta por falta de 1 a 1) y la fecha del onboarding; sin ella esas columnas faltan y quedan en null / false. */
export async function traerUltimasLlamadas(programaId) {
  const base = 'cliente_id,ultima_llamada,fuente';
  let { data, error } = await sb.from('cs_v_ultima_llamada')
    .select(base + ',modalidad,sin_alerta,onboarding_fecha,ultima_consultoria')
    .eq('programa_id', programaId).limit(5000);
  if (error && error.code === '42703') {
    ({ data, error } = await sb.from('cs_v_ultima_llamada').select(base).eq('programa_id', programaId).limit(5000));
  }
  if (error) {
    if (faltaTabla(error)) return null;
    throw error;
  }
  return new Map((data || []).map(r => [r.cliente_id, {
    fecha: r.ultima_llamada, fuente: r.fuente, modalidad: r.modalidad || null, sinAlerta: !!r.sin_alerta,
    onboarding: r.onboarding_fecha || null, ultimaConsultoria: r.ultima_consultoria || null
  }]));
}

/* ---------- Escrituras ---------- */

async function insertar(tabla, filas) {
  const { data, error } = await sb.from(tabla).insert(filas).select('*');
  if (error) throw error;
  return data || [];
}

/* Agrega accionables a una llamada. items = [{ texto, sub }] (sub = subtarea de la anterior sin
   sangría). Primero los principales y después las subtareas, con el id del padre. */
export async function agregarAccionables(programaId, clienteId, llamadaId, items, ordenInicial = 0) {
  if (!items.length) return [];
  const base = { programa_id: programaId, cliente_id: clienteId, llamada_id: llamadaId };
  const padres = [];
  let ultimo = -1;
  items.forEach((it, i) => {
    if (it.sub && ultimo >= 0) padres.push({ i, padre: ultimo });
    else { ultimo = i; padres.push({ i, padre: -1 }); }
  });
  const raices = padres.filter(p => p.padre < 0);
  const creadas = await insertar('cs_llamada_accionables',
    raices.map(p => ({ ...base, texto: items[p.i].texto, orden: ordenInicial + p.i })));
  const idPorOrden = new Map(creadas.map(r => [r.orden, r.id]));
  const hijas = padres.filter(p => p.padre >= 0)
    .map(p => ({ ...base, padre_id: idPorOrden.get(ordenInicial + p.padre), texto: items[p.i].texto, orden: ordenInicial + p.i }))
    .filter(f => f.padre_id);
  const subs = hijas.length ? await insertar('cs_llamada_accionables', hijas) : [];
  return creadas.concat(subs);
}

/* Una subtarea de un accionable (padre = la fila de cs_llamada_accionables). */
export async function agregarSubtarea(programaId, clienteId, padre, texto) {
  const [fila] = await insertar('cs_llamada_accionables', [{
    programa_id: programaId, cliente_id: clienteId, llamada_id: padre.llamada_id,
    padre_id: padre.id, texto: String(texto).trim().slice(0, 500), orden: (padre.orden || 0)
  }]);
  return fila;
}

export async function agregarRecursos(programaId, clienteId, llamadaId, items) {
  if (!items.length) return [];
  return insertar('cs_llamada_recursos', items.map(it => ({
    programa_id: programaId, cliente_id: clienteId, llamada_id: llamadaId || null,
    titulo: it.titulo, url: it.url, tipo: it.tipo
  })));
}

/* Una llamada con sus accionables y links.
   atomica = true (106 corrida): va por cs_llamada_crear, que carga llamada, accionables, links,
   transcripción y dudas en UNA transacción: si algo falla no queda nada. Devuelve el id.
   Sin la 106 (atomica false): si falla un paso después de crear la llamada, la llamada queda
   (no hay transacción desde el navegador) y el error dice qué faltó. */
export async function crearLlamada(programaId, clienteId, {
  fecha, titulo, accionables = [], links = [], atomica = false,
  resumen = '', en_que_esta = '', proximos_pasos = '', transcripcion = '', dudas = []
}) {
  if (atomica) {
    const { data, error } = await sb.rpc('cs_llamada_crear', {
      p_cliente: clienteId, p_fecha: fecha, p_titulo: (titulo || '').trim() || null,
      p_resumen: resumen, p_en_que_esta: en_que_esta, p_proximos_pasos: proximos_pasos,
      p_accionables: accionables, p_links: links, p_transcripcion: transcripcion || null, p_dudas: dudas
    });
    if (error) throw error;
    return data;
  }
  const [ll] = await insertar('cs_llamadas',
    [{ programa_id: programaId, cliente_id: clienteId, fecha, titulo: (titulo || '').trim() || null }]);
  try {
    await agregarAccionables(programaId, clienteId, ll.id, accionables);
    await agregarRecursos(programaId, clienteId, ll.id, links);
  } catch (e) {
    e.llamadaCreada = true;
    throw e;
  }
  return ll;
}
