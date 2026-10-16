// fathom-sync/index.ts — Edge Function: llamadas de Fathom -> cs_llamadas (Producto).
//
// POST /functions/v1/fathom-sync
//   Authorization: Bearer <sb_secret_... del proyecto>   (cron y curl)
//               o  Bearer <JWT de un fundador>           (boton "Sincronizar Fathom ahora")
//   Cuerpo (opcional, JSON):
//     { "desde": "YYYY-MM-DD" }   trae reuniones creadas desde ese dia (hora de Buenos Aires)
//     { "desde": "...", "hasta": "YYYY-MM-DD" }   opcional: acota por arriba (para recuperar
//                                                  historia por tramos)
//   Sin "desde": desde el inicio de la ultima corrida COMPLETA menos 2 dias (el upsert es
//   idempotente, el margen cubre grabaciones que Fathom termina de procesar tarde); la primera
//   vez, 60 dias atras.
//
// Que hace, por cada reunion que devuelve Fathom (GET /meetings, ver abajo). v4 (migracion 127):
// NINGUNA reunion se ignora; todas entran a la pestana del consultor.
//   - "Otros invitados" = invitados de calendario sin quien grabo, sin el consultor (por nombre) y sin
//     gente del equipo (no externos con dominio propio, o el mail de login de un consultor).
//   - Busca al alumno por el mail de un otro invitado (minusculas) entre TODOS los alumnos
//     de los programas habilitados en cs_fathom_config.programas: mail principal + mails extra
//     (cs_clientes_mails, 126). Si el mail no resuelve, respaldo por nombre (ver coincidenPorNombre):
//     nombre del alumno + sus alias (cs_clientes_alias, 127). Un solo alumno = asignada por nombre
//     (cs_llamadas.asignada_por = 'nombre', a confirmar).
//       un solo alumno  -> cs_llamadas (upsert por id de Fathom) + accionables + transcripcion
//       ninguno o varios -> cs_fathom_sin_asignar (se asigna a mano desde la app):
//           'interna'   = ningun otro invitado y ningun nombre en el titulo (ver clasificar)
//           'pendiente' = hay alguien o un nombre, pero no coincide con un alumno
//   - CONSULTORIAS GRUPALES (migracion 157): ANTES de buscar alumno, si la reunion arranca dentro de un
//     horario activo de cs_consultoria_horarios del consultor (dia y hora ART, con tolerancia), va a
//     cs_consultoria_registrar (cs_consultorias + asistentes + lo que dijo cada alumno + preguntas) y no se
//     asigna a un alumno. Sin la 157 corrida se sigue como siempre. Se cuenta como `consultorias`.
//   - Historial: { "historial": true, "consultor": "<id>" } (solo fundador o secret key) arranca el
//     historial completo de esa cuenta (desde 2020-01-01 o "desde"); se trae por tandas y se guarda el
//     cursor en cs_fathom_consultores.hist_*: cada corrida (manual o cron) sigue desde ahi y la corrida
//     queda 'parcial' hasta completarlo. { "reiniciar": true } lo vuelve a empezar.
//   - Toda la escritura va por la RPC cs_fathom_registrar (migracion 122): una transaccion
//     por reunion, sin duplicar, sin pisar lo cargado a mano.
//
// Cuentas (migracion 124): una por consultor, tabla cs_fathom_consultores (id, nombre, secreto,
// activo). Se recorren las activas cuyo secreto exista; una sin secreto se saltea sin error
// (estado 'sin_secreto'). Cada llamada guarda el consultor que la grabo. El limite de Fathom es
// por cuenta (key): hay pausa entre paginas de cada una.
//
// Secretos de la funcion (Supabase > Edge Functions > Secrets), nombres exactos:
//   FATHOM_API_KEY            Joaco (User Settings > API Access de su Fathom)
//   FATHOM_API_KEY_TEO        Teo
//   FATHOM_API_KEY_MARTU      Martu
//   (un consultor nuevo = una fila en cs_fathom_consultores con secreto FATHOM_API_KEY_<ALGO>)
//   FATHOM_PAUSA_MS           opcional, pausa entre paginas (default 2500)
//   FATHOM_PRESUPUESTO_SEG    opcional, tiempo maximo de la corrida (default 110)
// La key de Fathom nunca va al front, ni a tablas, ni a la respuesta ni a los logs.
//
// API de Fathom (verificada 14/10/2026, resumen en jefe/insumos/fathom-api.md):
//   GET https://api.fathom.ai/external/v1/meetings        https://developers.fathom.ai/api-reference/meetings/list-meetings
//     header X-Api-Key; params created_after, created_before (ISO), cursor,
//     include_summary, include_transcript, include_action_items.
//     Respuesta { limit, next_cursor, items[] }, 10 por pagina, sin parametro de tamanio.
//     Limite: 30 llamadas / 60 s con summary o transcript (429 con Retry-After): se respeta
//     con pausa entre paginas y reintento. Resumen y action items vienen en ingles: se guardan tal cual.
//
// Deploy: supabase functions deploy fathom-sync --no-verify-jwt
// (la verificacion la hace este codigo: sb_secret_ o JWT de fundador, como "sincronizar" de Finanzas).

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.116.0';

const URL_SB = Deno.env.get('SUPABASE_URL')!;
const BASE_FATHOM = 'https://api.fathom.ai/external/v1';
const PAUSA_MS = Math.max(0, Number(Deno.env.get('FATHOM_PAUSA_MS') ?? 2500) || 2500);
const PRESUPUESTO_MS = Math.max(20, Number(Deno.env.get('FATHOM_PRESUPUESTO_SEG') ?? 110) || 110) * 1000;
const MAX_TRANSCRIPCION = 190000;   // la tabla acepta 200000
const MAX_ERRORES_DETALLE = 20;

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};
const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo, null, 2), { status, headers: { ...CORS, 'content-type': 'application/json' } });

// ---------------------------------------------------------------------------
// Autorizacion (misma politica que sincronizar de Finanzas)
// ---------------------------------------------------------------------------
function valoresDe(nombre: string): string[] {
  const crudo = Deno.env.get(nombre);
  if (!crudo) return [];
  try {
    const j = JSON.parse(crudo);
    if (Array.isArray(j)) return j.filter((v) => typeof v === 'string');
    if (j && typeof j === 'object') return Object.values(j).filter((v): v is string => typeof v === 'string');
    if (typeof j === 'string') return [j];
  } catch { /* valor plano */ }
  return [crudo];
}
const SECRETAS = (() => {
  const lista = valoresDe('SUPABASE_SECRET_KEYS').filter((k) => k.startsWith('sb_secret_'));
  if (lista.length) return lista;
  const sr = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  return sr.startsWith('sb_secret_') ? [sr] : [];
})();
const CLAVE_SERVICIO: string | null = SECRETAS[0] ?? null;
const CLAVE_PUBLICA = valoresDe('SUPABASE_PUBLISHABLE_KEYS').find((k) => k.startsWith('sb_publishable_'))
  ?? Deno.env.get('SUPABASE_ANON_KEY') ?? null;

function iguales(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let dif = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) dif |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return dif === 0;
}
function tipoDe(t: string): string {
  if (t.startsWith('sb_secret_')) return 'sb_secret';
  if (t.startsWith('sb_publishable_')) return 'sb_publishable';
  const partes = t.split('.');
  if (partes.length !== 3) return 'desconocida';
  try {
    const p = JSON.parse(atob(partes[1].replace(/-/g, '+').replace(/_/g, '/')));
    return p.role === 'service_role' ? 'jwt_legacy_service_role' : p.role === 'anon' ? 'jwt_legacy_anon' : 'jwt_usuario';
  } catch { return 'jwt_ilegible'; }
}
function rechazo(motivo: string): null {
  console.warn(`[auth] rechazo: ${motivo}`);   // nunca la key ni un fragmento
  return null;
}
// 'secret_key' | 'fundador:<user_id>' | null
async function autorizar(req: Request): Promise<string | null> {
  const m = (req.headers.get('authorization') ?? '').match(/^Bearer\s+(\S+)$/i);
  if (!m) return rechazo('falta Authorization Bearer');
  const token = m[1];
  const tipo = tipoDe(token);
  if (tipo === 'sb_secret') {
    return SECRETAS.some((k) => iguales(k, token)) ? 'secret_key' : rechazo('sb_secret_ que no coincide');
  }
  if (tipo !== 'jwt_usuario') return rechazo(`token de tipo ${tipo}`);
  if (!CLAVE_PUBLICA) return rechazo('no hay key publica para verificar usuarios');
  const comoUsuario = createClient(URL_SB, CLAVE_PUBLICA, {
    global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false },
  });
  const { data: u, error: eu } = await comoUsuario.auth.getUser(token);
  if (eu || !u?.user) return rechazo('JWT de usuario invalido o vencido');
  const { data: fundador, error: ef } = await comoUsuario.rpc('es_fundador');
  if (ef || fundador !== true) return rechazo(`el usuario ${u.user.id} no es fundador`);
  return `fundador:${u.user.id}`;
}

// ---------------------------------------------------------------------------
// Cuentas de Fathom por consultor (cs_fathom_consultores, migracion 124)
// ---------------------------------------------------------------------------
type Consultor = {
  id: string; nombre: string; secreto: string; ultima_sync_ok_at?: string | null; email_login?: string | null;
  // historial reanudable (127)
  hist_estado?: string | null; hist_desde?: string | null; hist_hasta?: string | null; hist_cursor?: string | null;
  hist_oldest?: string | null; hist_desc?: boolean | null; hist_traidas?: number | null;
};
// Solo secretos FATHOM_API_KEY[_X]: aunque alguien editara la tabla, la funcion no lee otros secretos.
const RX_SECRETO = /^FATHOM_API_KEY(_[A-Z0-9]+)*$/;

type Cuenta = Consultor & { clave: string | null; omitir: string | null };
function resolverCuentas(consultores: Consultor[]): Cuenta[] {
  const vistas = new Set<string>();
  return consultores.map((c) => {
    const clave = RX_SECRETO.test(c.secreto) ? (Deno.env.get(c.secreto) ?? '').trim() : '';
    if (!clave) return { ...c, clave: null, omitir: 'sin_secreto' };
    if (vistas.has(clave)) return { ...c, clave: null, omitir: 'clave_repetida' };   // dos consultores con la misma key
    vistas.add(clave);
    return { ...c, clave, omitir: null };
  });
}

type Conteo = {
  estado: string; traidas: number; creadas: number; actualizadas: number; vinculadas: number;
  sin_asignar: number; internas: number; ignoradas: number; errores: number; por_nombre: number;
  consultorias: number;   // 157: reuniones que cayeron en un horario de consultoria grupal
  historial?: string;   // 'en_curso' | 'completo' cuando la cuenta tiene historial pedido
  historial_traidas?: number;
};
const conteoVacio = (estado = 'ok'): Conteo => ({
  estado, traidas: 0, creadas: 0, actualizadas: 0, vinculadas: 0, sin_asignar: 0, internas: 0, ignoradas: 0,
  errores: 0, por_nombre: 0, consultorias: 0,
});

const dormir = (ms: number) => new Promise((r) => setTimeout(r, ms));

class SinPresupuesto extends Error {}
class FathomHttp extends Error {
  constructor(public status: number) { super(`Fathom respondio HTTP ${status}`); }
}

// GET a Fathom con reintento ante 429 (Retry-After) y 5xx. Nunca loguea la key.
async function fathomGet(clave: string, ruta: string, params: URLSearchParams, limite: number): Promise<any> {
  for (let intento = 0; intento < 4; intento++) {
    const r = await fetch(`${BASE_FATHOM}${ruta}?${params}`, {
      headers: { 'X-Api-Key': clave, accept: 'application/json' },
    });
    if (r.status === 429 || r.status >= 500) {
      const ra = Number(r.headers.get('retry-after'));
      const espera = r.status === 429 ? (Number.isFinite(ra) && ra > 0 ? ra * 1000 : 30000) : 2000 * (intento + 1);
      if (Date.now() + espera > limite) throw new SinPresupuesto('sin tiempo para esperar el limite de Fathom');
      await dormir(espera);
      continue;
    }
    if (r.status === 401 || r.status === 403) throw new Error(`Fathom rechazo la key (HTTP ${r.status}): revisar el secreto`);
    if (!r.ok) throw new FathomHttp(r.status);
    return await r.json();
  }
  throw new Error('Fathom: demasiados reintentos');
}

// ---------------------------------------------------------------------------
// Texto: resumen -> "en que esta" y "proximos pasos"
// ---------------------------------------------------------------------------
function secciones(md: string): [string, string][] {
  const salida: [string, string][] = [];
  let clave = '';
  let buf: string[] = [];
  const cerrar = () => { if (clave) salida.push([clave, buf.join('\n').trim()]); buf = []; };
  for (const l of md.split(/\r?\n/)) {
    const h = l.match(/^#{1,6}\s+(.+?)\s*$/);
    if (h) { cerrar(); clave = h[1].toLowerCase().replace(/[*_`:]/g, '').trim(); } else buf.push(l);
  }
  cerrar();
  return salida;
}
const recortar = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s);

function enQueEsta(md: string): string {
  const s = secciones(md);
  for (const rx of [/key takeaway/, /takeaway/, /highlight/, /summary|overview/, /purpose/]) {
    const f = s.find(([k, v]) => rx.test(k) && v);
    if (f) return recortar(f[1], 2000);
  }
  return recortar(md.replace(/^#{1,6}\s+/gm, '').trim(), 1500);
}
function proximosPasos(md: string): string {
  const f = secciones(md).find(([k, v]) => /next steps?|action items?|follow.?ups?/.test(k) && v);
  return f ? recortar(f[1], 2000) : '';
}

// Tipo de llamada por el titulo; si no se puede inferir, 'otra'.
function inferirTipo(titulo: string): string {
  const t = titulo.toLowerCase();
  if (/onboard|bienvenida|kick.?off|kickoff|inicio/.test(t)) return 'onboarding';
  if (/resell|renovaci|renewal|upsell|ampliaci/.test(t)) return 'resell';
  if (/seguimiento|follow.?up|check.?in|sesi[oó]n|1\s*(a|:|-|on)\s*1|one.?on.?one|consultor|mentor/.test(t)) return 'seguimiento';
  return 'otra';
}

function textoTranscripcion(items: any[]): string {
  const t = items.map((i) => `[${i.timestamp ?? ''}] ${i.speaker?.display_name ?? '?'}: ${i.text ?? ''}`).join('\n');
  return t.length > MAX_TRANSCRIPCION ? t.slice(0, MAX_TRANSCRIPCION) + '\n[transcripcion cortada por tamanio]' : t;
}

// ---------------------------------------------------------------------------
// Alumnos de los programas habilitados: indexados por mail (principal + extras, migracion 126)
// y en lista con el nombre normalizado (match por nombre, respaldo del mail)
// ---------------------------------------------------------------------------
type Alumno = { id: string; programa_id: string; vivo: boolean };
type AlumnoN = Alumno & { nom: string; toks: string[] };
type Alumnos = { porMail: Map<string, Alumno[]>; lista: AlumnoN[] };

// Minusculas, sin acentos, sin simbolos, sin espacios dobles (mismo criterio que cs_norm_nombre).
const normNombre = (s: unknown): string =>
  String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

async function cargarAlumnos(sb: SupabaseClient, programas: string[]): Promise<Alumnos> {
  const porMail = new Map<string, Alumno[]>();
  const lista: AlumnoN[] = [];
  const porId = new Map<string, Alumno>();
  const PAG = 1000;
  const sumar = (e: unknown, a: Alumno) => {
    const m = String(e ?? '').toLowerCase().trim();
    if (!m) return;
    const v = porMail.get(m) ?? [];
    if (!v.some((x) => x.id === a.id)) v.push(a);
    porMail.set(m, v);
  };
  for (let desde = 0; ; desde += PAG) {
    const { data, error } = await sb.from('cs_clientes').select('id,programa_id,nombre,email,estado')
      .in('programa_id', programas).order('id').range(desde, desde + PAG - 1);
    if (error) throw new Error(`no se pudieron leer los alumnos: ${error.message}`);
    for (const c of data ?? []) {
      const a: Alumno = { id: c.id, programa_id: c.programa_id, vivo: !['finalizado', 'baja'].includes(c.estado) };
      porId.set(a.id, a);
      const nom = normNombre(c.nombre);
      if (nom) lista.push({ ...a, nom, toks: nom.split(' ') });
      sumar(c.email, a);
    }
    if (!data || data.length < PAG) break;
  }
  // Mails extra (126). Si la tabla todavia no existe, se sigue solo con el principal.
  for (let desde = 0; ; desde += PAG) {
    const { data, error } = await sb.from('cs_clientes_mails').select('cliente_id,email')
      .in('programa_id', programas).order('id').range(desde, desde + PAG - 1);
    if (error) {
      console.warn(`[alumnos] sin mails extra (migracion 126 corrida?): ${error.message}`);
      break;
    }
    for (const m of data ?? []) {
      const a = porId.get(m.cliente_id);
      if (a) sumar(m.email, a);
    }
    if (!data || data.length < PAG) break;
  }
  // Alias de nombre (127): cada alias suma una entrada mas de la lista para el mismo alumno, asi el
  // match por nombre usa nombre + alias con las mismas reglas. Sin la 127 se sigue sin alias.
  for (let desde = 0; ; desde += PAG) {
    const { data, error } = await sb.from('cs_clientes_alias').select('cliente_id,alias')
      .in('programa_id', programas).order('id').range(desde, desde + PAG - 1);
    if (error) {
      console.warn(`[alumnos] sin alias (migracion 127 corrida?): ${error.message}`);
      break;
    }
    for (const al of data ?? []) {
      const a = porId.get(al.cliente_id);
      const nom = normNombre(al.alias);
      if (a && nom) lista.push({ ...a, nom, toks: nom.split(' ') });
    }
    if (!data || data.length < PAG) break;
  }
  return { porMail, lista };
}

// Un alumno unico, o los candidatos si hay varios. Entre homonimos de mail prefiere el vivo.
function resolverAlumno(emails: string[], alumnos: Map<string, Alumno[]>): { alumno?: Alumno; candidatos: string[] } {
  const todos = new Map<string, Alumno>();
  for (const e of emails) for (const a of alumnos.get(e) ?? []) todos.set(a.id, a);
  if (todos.size === 0) return { candidatos: [] };
  if (todos.size === 1) return { alumno: [...todos.values()][0], candidatos: [] };
  const vivos = [...todos.values()].filter((a) => a.vivo);
  // Los mails de UN solo invitado que apuntan a varias filas: si hay un unico vivo, es ese.
  if (vivos.length === 1 && emails.filter((e) => alumnos.has(e)).length === 1) return { alumno: vivos[0], candidatos: [] };
  return { candidatos: [...todos.keys()] };
}

// ---------------------------------------------------------------------------
// Match por nombre (respaldo cuando el mail no resuelve). Reglas, en orden:
//   1. Nombres del invitado externo (sin quien grabo) que tengan 2 palabras o mas. Si no queda ninguno,
//      los nombres que salen del titulo de la reunion (ver nombresDeTitulo).
//   2. Un nombre coincide con un alumno si es IGUAL normalizado; si no hay iguales, si el nombre del
//      invitado tiene 2 palabras o mas, la misma primera y la misma ultima palabra, y las palabras del
//      mas corto estan dentro del mas largo (segundo nombre de mas o de menos).
//   3. Un solo alumno distinto = asignada por nombre. Mas de uno = pendiente con candidatos. Ninguno = pendiente.
//   Si el mail dejo candidatos, el nombre solo desempata entre ellos.
// ---------------------------------------------------------------------------
const RUIDO_TITULO = new RegExp(
  '\\b(reunion|llamada|call|meeting|videollamada|sesion|seguimiento|onboarding|follow ?up|check ?in|consultoria|' +
  'mentoria|one ?on ?one|north ecom|bpf|dystopia|grupal|1 a 1|1 ?x ?1|1 ?on ?1|de|del|la|el|' +
  // 127: titulos genericos que no nombran a nadie (reunion instantanea, sala, etc.)
  'instantanea|nueva|nuevo|sin titulo|untitled|zoom|meet|google|teams|sala|semanal|weekly|daily|standup|sync|' +
  'planning|equipo|interna|interno|personal|privada|privado|test|prueba|started|ended|with|and|y|e|con)\\b', 'g');

// Partes del titulo que no son del consultor, ya sin ruido y normalizadas (1 palabra o mas).
// "Federico Rolon and Joaco Fernandez": se parte por and / y / con / with / & / + / x / <> / guion /
// barra / coma, se sacan palabras de ruido y se descarta la parte que es del consultor (su nombre
// de la cuenta o el de quien grabo).
function partesDeTitulo(titulo: string, propios: string[]): string[] {
  const t = titulo.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/\([^)]*\)|\[[^\]]*\]/g, ' ').replace(/['’]s\b/g, ' ');
  const partes = t.split(/\s+(?:and|y|e|con|with|&|x|\+|<>)\s+|\s[-–—]\s|[\/|,;:]/);
  const mios = new Set(propios.flatMap((p) => normNombre(p).split(' ')).filter(Boolean));
  const out: string[] = [];
  for (const p of partes) {
    const n = normNombre(p.replace(RUIDO_TITULO, ' ').replace(/\d+/g, ' '));
    if (!n) continue;
    const toks = n.split(' ').filter((x) => x.length >= 2);
    if (!toks.length || toks.every((x) => mios.has(x))) continue;   // vacio o es el consultor
    out.push(toks.join(' '));
  }
  return [...new Set(out)];
}

// Para match y alias: nombres con 2 palabras o mas.
const nombresDeTitulo = (titulo: string, propios: string[]): string[] =>
  partesDeTitulo(titulo, propios).filter((n) => n.split(' ').length >= 2);

// Para clasificar: hay algun nombre (de 3 letras o mas) en el titulo que no es del consultor.
const hayNombreEnTitulo = (titulo: string, propios: string[]): boolean =>
  partesDeTitulo(titulo, propios).some((n) => n.split(' ').some((x) => x.length >= 3));

// Dominios de mail gratuitos: ahi "mismo dominio" no dice nada del equipo.
const DOMINIOS_LIBRES = new Set(['gmail.com', 'googlemail.com', 'hotmail.com', 'outlook.com', 'live.com', 'yahoo.com',
  'yahoo.com.ar', 'icloud.com', 'me.com', 'msn.com', 'proton.me', 'protonmail.com', 'gmx.com', 'aol.com']);

type Invitado = { name?: string | null; email?: string | null; email_domain?: string | null; is_external?: boolean;
  matched_speaker_display_name?: string | null };

// Otros invitados de una reunion y su clasificacion. Un invitado cuenta como "de afuera" si no es
// quien grabo, no es el consultor (todas las palabras de su nombre estan en el nombre del consultor),
// y no es del equipo (no externo con dominio propio, o mail de login de un consultor).
function otrosInvitados(m: any, propios: string[], equipo: Set<string>): Invitado[] {
  const lista: Invitado[] = Array.isArray(m.calendar_invitees) ? m.calendar_invitees : [];
  const grabador = String(m.recorded_by?.email ?? '').toLowerCase().trim();
  const mios = new Set(propios.flatMap((p) => normNombre(p).split(' ')).filter((x) => x.length >= 2));
  return lista.filter((i) => {
    const mail = String(i?.email ?? '').toLowerCase().trim();
    const nom = normNombre(i?.name ?? i?.matched_speaker_display_name);
    if (!mail && !nom) return false;
    if (mail && mail === grabador) return false;
    if (mail && equipo.has(mail)) return false;
    const dom = String(i?.email_domain ?? mail.split('@')[1] ?? '').toLowerCase();
    if (mail && !i?.is_external && dom && !DOMINIOS_LIBRES.has(dom)) return false;   // equipo
    const toks = nom.split(' ').filter((x) => x.length >= 2);
    if (toks.length && toks.every((x) => mios.has(x))) return false;                // es el consultor
    return true;
  });
}

function coincidenPorNombre(nombres: string[], lista: AlumnoN[], solo?: Set<string>): string[] {
  const exactos = new Set<string>();
  const parecidos = new Set<string>();
  for (const n of nombres) {
    const t = n.split(' ');
    for (const a of lista) {
      if (solo && !solo.has(a.id)) continue;
      if (a.nom === n) { exactos.add(a.id); continue; }
      if (t.length >= 2 && a.toks.length >= 2 && t[0] === a.toks[0] && t[t.length - 1] === a.toks[a.toks.length - 1]) {
        const [c, l] = t.length <= a.toks.length ? [t, a.toks] : [a.toks, t];
        if (c.every((x) => l.includes(x))) parecidos.add(a.id);
      }
    }
  }
  return [...(exactos.size ? exactos : parecidos)];
}

// ---------------------------------------------------------------------------
// Una reunion -> payload de cs_fathom_registrar
// ---------------------------------------------------------------------------
function armarPayload(
  m: any, consultor: string, alumno: Alumno | undefined, candidatos: string[], externos: string[],
  asignadaPor: 'mail' | 'nombre' = 'mail', interna = false, nombres: string[] = [],
) {
  const titulo = String(m.meeting_title || m.title || '').trim();
  const resumen = String(m.default_summary?.markdown_formatted ?? '').trim();
  const ini = m.recording_start_time || m.scheduled_start_time || m.created_at;
  const fin = m.recording_end_time;
  let duracion: number | null = null;
  if (m.recording_start_time && fin) {
    const min = Math.round((Date.parse(fin) - Date.parse(m.recording_start_time)) / 60000);
    if (Number.isFinite(min) && min >= 0 && min < 24 * 60) duracion = min;
  }
  return {
    externo_id: `fathom:${m.recording_id}`,
    consultor,
    origen: 'sync',
    cliente_id: alumno?.id ?? null,
    asignada_por: alumno ? asignadaPor : null,
    motivo: alumno ? null : (candidatos.length ? 'varios_alumnos' : 'sin_alumno'),
    candidatos,
    inicio_at: ini,
    titulo,
    tipo: inferirTipo(titulo),
    duracion_min: duracion,
    grabacion_url: m.url ?? null,
    grabacion_share_url: m.share_url ?? null,
    resumen: resumen ? recortar(resumen, 4000) : null,
    en_que_esta: resumen ? enQueEsta(resumen) : null,
    proximos_pasos: resumen ? proximosPasos(resumen) : null,
    transcripcion: Array.isArray(m.transcript) && m.transcript.length ? textoTranscripcion(m.transcript) : null,
    action_items: (m.action_items ?? [])
      .filter((a: any) => a?.description && String(a.description).trim())
      .map((a: any) => ({
        descripcion: String(a.description).trim(),
        responsable: a.assignee?.name ?? null,
      })),
    invitados: externos,
    nombres,
    clasificar: !alumno && interna ? 'interna' : undefined,
  };
}

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'usar POST' }, 405);

  const quien = await autorizar(req);
  if (!quien) return responder({ error: 'no autorizado: hace falta una secret key sb_secret_ del proyecto o un usuario fundador' }, 401);
  if (!CLAVE_SERVICIO) {
    console.error('[auth] no hay ninguna sb_secret_ configurada: no se puede hablar con la base');
    return responder({ error: 'la funcion no tiene una secret key sb_secret_ para hablar con la base' }, 500);
  }
  const sb = createClient(URL_SB, CLAVE_SERVICIO, { auth: { persistSession: false } });

  let cuerpo: any = {};
  try {
    const texto = await req.text();
    cuerpo = texto ? JSON.parse(texto) : {};
  } catch {
    return responder({ error: 'el cuerpo no es JSON valido' }, 400);
  }
  const RX_FECHA = /^\d{4}-\d{2}-\d{2}$/;
  if (cuerpo.desde != null && !RX_FECHA.test(String(cuerpo.desde))) return responder({ error: '"desde" debe ser YYYY-MM-DD' }, 400);
  if (cuerpo.hasta != null && !RX_FECHA.test(String(cuerpo.hasta))) return responder({ error: '"hasta" debe ser YYYY-MM-DD' }, 400);
  const pideHistorial = cuerpo.historial === true;
  if (pideHistorial && !/^[a-z][a-z0-9_]{1,30}$/.test(String(cuerpo.consultor ?? ''))) {
    return responder({ error: '"historial" necesita "consultor" (id de la cuenta, ej. "joaco")' }, 400);
  }

  // Consultores activos (migracion 124) y que secretos existen. Con la 127 trae tambien el estado del
  // historial y el mail de login (equipo); sin ella sigue con los campos de siempre.
  const COLS_BASE = 'id,nombre,secreto,ultima_sync_ok_at';
  const COLS_127 = `${COLS_BASE},email_login,hist_estado,hist_desde,hist_hasta,hist_cursor,hist_oldest,hist_desc,hist_traidas`;
  let tieneHist = true;
  // Tipo propio: las columnas de la 127 son opcionales en Consultor, asi que sirve para las dos consultas.
  type RespConsultores = { data: Consultor[] | null; error: { message: string } | null };
  let rc = await sb.from('cs_fathom_consultores').select(COLS_127).eq('activo', true).order('orden').order('id') as unknown as RespConsultores;
  if (rc.error) {
    tieneHist = false;
    rc = await sb.from('cs_fathom_consultores').select(COLS_BASE).eq('activo', true).order('orden').order('id') as unknown as RespConsultores;
  }
  if (rc.error) return responder({ error: `no se pudo leer cs_fathom_consultores (migracion 124 corrida?): ${rc.error.message}` }, 500);
  const cuentas = resolverCuentas(rc.data ?? []);
  if (!cuentas.some((c) => c.clave)) {
    return responder({
      error: 'ningun consultor activo tiene su secreto cargado en la funcion',
      consultores: cuentas.map((c) => ({ id: c.id, secreto: c.secreto, estado: c.omitir })),
    }, 500);
  }
  if (pideHistorial) {
    if (!tieneHist) return responder({ error: 'falta correr la migracion 127 (historial reanudable)' }, 409);
    const cta = cuentas.find((c) => c.id === cuerpo.consultor);
    if (!cta || !cta.clave) {
      return responder({ error: `el consultor "${cuerpo.consultor}" no esta activo o no tiene su secreto cargado` }, 409);
    }
  }

  const inicio = Date.now();
  const limite = inicio + PRESUPUESTO_MS;
  const origen = quien === 'secret_key' ? 'servicio' : 'manual';

  // Config: programas habilitados
  const { data: cfg, error: ecfg } = await sb.from('cs_fathom_config').select('programas').limit(1).maybeSingle();
  if (ecfg) return responder({ error: `no se pudo leer cs_fathom_config (migracion 122 corrida?): ${ecfg.message}` }, 500);
  const programas: string[] = (cfg?.programas ?? []).filter((p: unknown) => typeof p === 'string');
  if (!programas.length) return responder({ error: 'no hay programas habilitados en cs_fathom_config' }, 409);

  // Desde, por consultor: body > su ultima corrida completa - 2 dias > 60 dias atras (cuenta nueva).
  // Cada cuenta tiene su propia ventana: sumar un consultor no obliga a re-traer a los demas.
  const ms60 = Date.now() - 60 * 86400000;
  const desdeDe = (c: { ultima_sync_ok_at?: string | null }): string => {
    if (cuerpo.desde && !pideHistorial) return new Date(`${cuerpo.desde}T00:00:00-03:00`).toISOString();
    const base = c.ultima_sync_ok_at ? Date.parse(c.ultima_sync_ok_at) - 2 * 86400000 : ms60;
    return new Date(base).toISOString();
  };
  const hastaISO = cuerpo.hasta && !pideHistorial ? new Date(`${cuerpo.hasta}T23:59:59-03:00`).toISOString() : null;
  const desdeISO = cuentas.filter((c) => c.clave).map((c) => desdeDe(c)).sort()[0];

  const { data: corrida, error: ecor } = await sb.from('cs_fathom_corridas')
    .insert({ origen, desde: desdeISO, estado: 'en_curso' }).select('id').single();
  if (ecor) return responder({ error: `no se pudo abrir la corrida: ${ecor.message}` }, 500);

  const porConsultor: Record<string, Conteo> = {};
  const incompleta = new Set<string>();   // cuentas cuya ventana incremental no termino (no avanzan ultima_sync_ok_at)
  const errores: { recording_id: unknown; motivo: string }[] = [];
  let totalErrores = 0;
  let parcial = false;
  let historialPendiente = false;
  let fatal: string | null = null;

  const falla = (c: Conteo, cta: string, id: unknown, motivo: string) => {
    totalErrores++;
    c.errores++;
    if (errores.length < MAX_ERRORES_DETALLE) errores.push({ recording_id: id, motivo: `${cta}: ${motivo}`.slice(0, 300) });
  };

  // Mails del equipo: login de los consultores + quien grabo cada reunion que se va viendo.
  const equipo = new Set<string>(cuentas.map((c) => String(c.email_login ?? '').toLowerCase().trim()).filter(Boolean));

  try {
    const alumnos = await cargarAlumnos(sb, programas);

    // 157: si la migracion no esta corrida, cs_consultoria_horario_buscar falla y se sigue como siempre.
    let consultoriasOk = true;

    // Una reunion de Fathom -> cs_fathom_registrar. Nada se ignora (127).
    const procesar = async (m: any, cuenta: Cuenta, c: Conteo) => {
      c.traidas++;
      try {
        const grabador = String(m.recorded_by?.email ?? '').toLowerCase().trim();
        if (grabador) equipo.add(grabador);
        const propios = [cuenta.nombre, String(m.recorded_by?.name ?? '')];
        const titulo = String(m.meeting_title || m.title || '');
        const otros = otrosInvitados(m, propios, equipo);
        const mails = [...new Set(otros.map((i) => String(i.email ?? '').toLowerCase().trim()).filter(Boolean))];
        // Mails que se aprenden al asignar a mano: solo los de invitados externos (un colega no
        // puede quedar como mail de un alumno).
        const externos = [...new Set(otros.filter((i) => i.is_external && i.email)
          .map((i) => String(i.email).toLowerCase().trim()))];
        const nombresExt = otros.filter((i) => i.is_external)
          .map((i) => normNombre(i.name ?? i.matched_speaker_display_name))
          .filter((n) => n.split(' ').filter(Boolean).length >= 2);
        const nombresTit = nombresDeTitulo(titulo, propios);

        // 0. (157) consultoria grupal: la reunion arranca dentro de un horario cargado del consultor.
        // No se asigna a un alumno: cs_consultoria_registrar arma la consultoria, los asistentes y las preguntas.
        if (consultoriasOk) {
          const iniReunion = m.recording_start_time || m.scheduled_start_time || m.created_at;
          const { data: horarioId, error: eh } = await sb.rpc('cs_consultoria_horario_buscar',
            { p_consultor: cuenta.id, p_inicio: iniReunion });
          if (eh) {
            consultoriasOk = false;
            console.warn(`[consultorias] horarios no disponibles (migracion 157 corrida?): ${eh.code ?? 'error'}`);
          } else if (horarioId) {
            const base = armarPayload(m, cuenta.id, undefined, [], [], 'mail', false, []);
            const asistentes = otros.map((i) => ({ nombre: i.name ?? i.matched_speaker_display_name ?? null, email: i.email ?? null }));
            const { data: rc157, error: ec157 } = await sb.rpc('cs_consultoria_registrar', {
              p: {
                externo_id: base.externo_id, consultor: base.consultor, inicio_at: base.inicio_at, titulo: base.titulo,
                duracion_min: base.duracion_min, grabacion_url: base.grabacion_url,
                grabacion_share_url: base.grabacion_share_url, resumen: base.resumen,
                transcripcion: base.transcripcion, asistentes,
              },
            });
            if (ec157) { falla(c, cuenta.id, m.recording_id, ec157.message); return; }
            if (String(rc157?.resultado ?? '') !== 'sin_horario') { c.consultorias++; return; }
          }
        }

        // 1. por mail (principal o extra). 2. respaldo: por nombre (nombre o alias), ver coincidenPorNombre.
        let { alumno, candidatos } = resolverAlumno(mails, alumnos.porMail);
        let asignadaPor: 'mail' | 'nombre' = 'mail';
        if (!alumno) {
          const nombres = nombresExt.length ? nombresExt : nombresTit;
          const solo = candidatos.length ? new Set(candidatos) : undefined;
          const ids = nombres.length ? coincidenPorNombre(nombres, alumnos.lista, solo) : [];
          if (ids.length === 1) {
            alumno = alumnos.lista.find((a) => a.id === ids[0]);
            asignadaPor = 'nombre';
            candidatos = [];
          } else if (ids.length > 1) {
            candidatos = ids.slice(0, 10);   // dudas: queda pendiente con los candidatos
          }
        }
        // interna = nadie de afuera y ningun nombre en el titulo (ni invitados sin identificar)
        const interna = otros.length === 0 && !hayNombreEnTitulo(titulo, propios);
        const aprender = [...new Set([...nombresExt, ...nombresTit])].slice(0, 3);
        const { data, error } = await sb.rpc('cs_fathom_registrar',
          { p: armarPayload(m, cuenta.id, alumno, candidatos, externos, asignadaPor, interna, aprender) });
        if (error) { falla(c, cuenta.id, m.recording_id, error.message); return; }
        const r = String(data?.resultado ?? '');
        if (r === 'creada') c.creadas++;
        else if (r === 'actualizada') c.actualizadas++;
        else if (r === 'vinculada') c.vinculadas++;
        else if (r === 'interna') c.internas++;
        else c.sin_asignar++;
        if (asignadaPor === 'nombre' && (r === 'creada' || r === 'vinculada')) c.por_nombre++;
      } catch (e) {
        falla(c, cuenta.id, m?.recording_id, (e as Error).message);
      }
    };

    // ---- Pasada 1: ventana incremental de cada cuenta (corta: no la frena un historial largo) ----
    for (const cuenta of cuentas) {
      const c = porConsultor[cuenta.id] = conteoVacio();
      if (cuenta.omitir) { c.estado = cuenta.omitir; continue; }
      if (parcial) { c.estado = 'omitido_por_tiempo'; incompleta.add(cuenta.id); continue; }

      const desdeCuenta = desdeDe(cuenta);
      let cursor: string | null = null;
      let cuentaFallo = false;
      do {
        if (Date.now() + PAUSA_MS > limite) { parcial = true; c.estado = 'parcial'; incompleta.add(cuenta.id); break; }
        const params = new URLSearchParams({
          created_after: desdeCuenta,
          include_summary: 'true', include_transcript: 'true', include_action_items: 'true',
        });
        if (hastaISO) params.set('created_before', hastaISO);
        if (cursor) params.set('cursor', cursor);

        let pagina: any;
        try {
          pagina = await fathomGet(cuenta.clave!, '/meetings', params, limite);
        } catch (e) {
          if (e instanceof SinPresupuesto) { parcial = true; c.estado = 'parcial'; incompleta.add(cuenta.id); break; }
          falla(c, cuenta.id, null, (e as Error).message);
          cuentaFallo = true;
          break;   // esta cuenta no sigue; las demas si
        }

        for (const m of pagina.items ?? []) await procesar(m, cuenta, c);

        cursor = pagina.next_cursor ?? null;
        if (cursor) await dormir(PAUSA_MS);   // limite de Fathom: por cuenta (key)
      } while (cursor);

      if (c.estado !== 'parcial') {
        c.estado = cuentaFallo && c.traidas === 0 ? 'error' : c.errores ? 'con_errores' : 'ok';
      }
    }

    // ---- Historial pedido: arrancar (o reiniciar) el de la cuenta que lo pide ----
    if (tieneHist && pideHistorial) {
      const cta = cuentas.find((c) => c.id === cuerpo.consultor)!;
      if (cta.hist_estado !== 'en_curso' || cuerpo.reiniciar === true) {
        const desdeH = new Date(`${cuerpo.desde ?? '2020-01-01'}T00:00:00-03:00`).toISOString();
        const nuevo = {
          hist_estado: 'en_curso', hist_desde: desdeH, hist_hasta: new Date(inicio).toISOString(),
          hist_cursor: null, hist_oldest: null, hist_desc: null, hist_traidas: 0,
          hist_inicio_at: new Date(inicio).toISOString(), hist_fin_at: null,
        };
        const { error } = await sb.from('cs_fathom_consultores').update(nuevo).eq('id', cta.id);
        if (error) throw new Error(`no se pudo arrancar el historial: ${error.message}`);
        Object.assign(cta, nuevo);
      }
    }

    // ---- Pasada 2: historial en curso (una tanda por corrida; el cursor queda guardado) ----
    for (const cuenta of cuentas) {
      if (!tieneHist || cuenta.omitir || cuenta.hist_estado !== 'en_curso') continue;
      const c = porConsultor[cuenta.id];
      const guardarHist = async (cambios: Record<string, unknown>) => {
        const { error } = await sb.from('cs_fathom_consultores').update(cambios).eq('id', cuenta.id);
        if (error) console.warn(`[historial] ${cuenta.id}: no se pudo guardar el estado: ${error.message}`);
      };
      let cursor: string | null = cuenta.hist_cursor ?? null;
      const desde = cuenta.hist_desde ?? new Date('2020-01-01T00:00:00-03:00').toISOString();
      let hasta = cuenta.hist_hasta ?? new Date(inicio).toISOString();
      let oldest = cuenta.hist_oldest ? Date.parse(cuenta.hist_oldest) : Infinity;
      let desc = cuenta.hist_desc ?? true;
      let traidas = cuenta.hist_traidas ?? 0;
      let ultimoCreado = Infinity;
      let reintentoCursor = false;
      let terminado = false;

      while (!terminado) {
        if (Date.now() + PAUSA_MS > limite) { parcial = true; historialPendiente = true; break; }
        const params = new URLSearchParams({
          created_after: desde, created_before: hasta,
          include_summary: 'true', include_transcript: 'true', include_action_items: 'true',
        });
        if (cursor) params.set('cursor', cursor);

        let pagina: any;
        try {
          pagina = await fathomGet(cuenta.clave!, '/meetings', params, limite);
        } catch (e) {
          if (e instanceof SinPresupuesto) { parcial = true; historialPendiente = true; break; }
          // Cursor rechazado: una sola vez, seguir por fecha (si el orden observado es del mas nuevo al
          // mas viejo) o volver a empezar la ventana (el upsert es idempotente).
          if (e instanceof FathomHttp && e.status >= 400 && e.status < 500 && cursor && !reintentoCursor) {
            reintentoCursor = true;
            cursor = null;
            if (desc && Number.isFinite(oldest)) hasta = new Date(oldest).toISOString();
            await guardarHist({ hist_cursor: null, hist_hasta: hasta });
            continue;
          }
          falla(c, cuenta.id, null, `historial: ${(e as Error).message}`);
          historialPendiente = true;   // queda en_curso: la proxima corrida reintenta desde el mismo cursor
          break;
        }

        for (const m of pagina.items ?? []) {
          const t = Date.parse(m.created_at ?? '');
          if (Number.isFinite(t)) {
            if (t > ultimoCreado) desc = false;   // no viene del mas nuevo al mas viejo
            ultimoCreado = t;
            if (t < oldest) oldest = t;
          }
          await procesar(m, cuenta, c);
          traidas++;
        }

        const masViejo = Number.isFinite(oldest) ? new Date(oldest).toISOString() : null;
        cursor = pagina.next_cursor ?? null;
        if (!cursor) {
          terminado = true;
          await guardarHist({
            hist_estado: 'completo', hist_cursor: null, hist_oldest: masViejo,
            hist_desc: desc, hist_traidas: traidas, hist_fin_at: new Date().toISOString(),
          });
          c.historial = 'completo';
          c.historial_traidas = traidas;
        } else {
          await guardarHist({ hist_cursor: cursor, hist_oldest: masViejo, hist_desc: desc, hist_traidas: traidas });
          await dormir(PAUSA_MS);
        }
      }
      if (!terminado) {
        c.historial = 'en_curso';
        c.historial_traidas = traidas;
        if (c.estado === 'ok') c.estado = 'parcial';   // historial a medias: se completa solo en la proxima corrida
      }
    }
  } catch (e) {
    fatal = (e as Error).message;
  }

  // Totales
  const tot = conteoVacio();
  for (const c of Object.values(porConsultor)) {
    tot.traidas += c.traidas; tot.creadas += c.creadas; tot.actualizadas += c.actualizadas;
    tot.vinculadas += c.vinculadas; tot.sin_asignar += c.sin_asignar; tot.internas += c.internas;
    tot.ignoradas += c.ignoradas; tot.por_nombre += c.por_nombre; tot.consultorias += c.consultorias;
  }
  const asignadas = tot.creadas + tot.actualizadas + tot.vinculadas;
  const estado = fatal ? 'error' : parcial ? 'parcial' : totalErrores ? 'con_errores' : 'ok';
  const detalle = [
    fatal ? `error: ${fatal}` : '',
    historialPendiente
      ? 'historial en curso: la proxima corrida sigue desde el cursor guardado (se completa sola con la sincronizacion automatica, o volver a apretar el boton)'
      : (parcial ? 'corrida cortada por tiempo: repetir (o usar "desde"/"hasta" por tramos)' : ''),
    ...Object.entries(porConsultor).filter(([, c]) => ['sin_secreto', 'clave_repetida'].includes(c.estado))
      .map(([id, c]) => `${id}: ${c.estado === 'sin_secreto' ? 'saltado, falta el secreto' : 'saltado, misma key que otro consultor'}`),
    ...errores.map((e) => `${e.recording_id ?? 'cuenta'}: ${e.motivo}`),
  ].filter(Boolean).join('\n').slice(0, 2000);

  // Resultado de cada consultor (solo conteos): lo muestra Configuracion.
  const cierreAt = new Date().toISOString();
  const ESTADOS_BD = ['ok', 'parcial', 'con_errores', 'error', 'sin_secreto', 'clave_repetida', 'omitido_por_tiempo'];
  for (const cuenta of cuentas) {
    const c = porConsultor[cuenta.id];
    if (!c) continue;
    const { estado: e, ...resumen } = c;
    const fila: Record<string, unknown> = {
      ultimo_at: cierreAt, ultimo_estado: ESTADOS_BD.includes(e) ? e : 'error', ultimo_resumen: resumen,
    };
    // La ventana incremental se da por completa aunque el historial siga a medias.
    const incrementalOk = e === 'ok' || (e === 'parcial' && c.historial === 'en_curso' && !incompleta.has(cuenta.id));
    if (incrementalOk) fila.ultima_sync_ok_at = new Date(inicio).toISOString();
    await sb.from('cs_fathom_consultores').update(fila).eq('id', cuenta.id);
  }
  const desglose = Object.fromEntries(cuentas.filter((c) => porConsultor[c.id])
    .map((c) => [c.id, { nombre: c.nombre, ...porConsultor[c.id] }]));

  const cierre: Record<string, unknown> = {
    fin: cierreAt, estado, traidas: tot.traidas, asignadas, creadas: tot.creadas,
    actualizadas: tot.actualizadas, vinculadas: tot.vinculadas, sin_asignar: tot.sin_asignar,
    ignoradas: tot.ignoradas, errores: totalErrores, parcial, detalle: detalle || null,
    por_consultor: desglose,
  };
  // internas (127): si la columna todavia no existe, se cierra la corrida igual sin ella.
  const r1 = await sb.from('cs_fathom_corridas').update({ ...cierre, internas: tot.internas }).eq('id', corrida.id);
  if (r1.error) await sb.from('cs_fathom_corridas').update(cierre).eq('id', corrida.id);

  // Solo conteos y motivos: nunca contenido de llamadas, mails ni la key.
  return responder({
    corrida_id: corrida.id, estado, invocado_por: quien, desde: desdeISO, hasta: hastaISO,
    programas_habilitados: programas, consultores: desglose,
    traidas: tot.traidas, asignadas, creadas: tot.creadas, actualizadas: tot.actualizadas,
    vinculadas: tot.vinculadas, sin_asignar: tot.sin_asignar, internas: tot.internas,
    asignadas_por_nombre: tot.por_nombre, consultorias_grupales: tot.consultorias,
    historial_pendiente: historialPendiente,
    errores: totalErrores, parcial, segundos: Math.round((Date.now() - inicio) / 100) / 10,
    detalle_errores: fatal ? [{ recording_id: null, motivo: fatal }, ...errores] : errores,
  }, fatal ? 500 : 200);
});
