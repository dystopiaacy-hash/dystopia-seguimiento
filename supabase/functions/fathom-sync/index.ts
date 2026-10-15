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
// Que hace, por cada reunion que devuelve Fathom (GET /meetings, ver abajo):
//   - Sin invitados externos: se ignora (es interna).
//   - Busca al alumno por el mail de un invitado externo (minusculas) entre TODOS los alumnos
//     de los programas habilitados en cs_fathom_config.programas.
//       un solo alumno  -> cs_llamadas (upsert por id de Fathom) + accionables + transcripcion
//       ninguno o varios -> cs_fathom_sin_asignar (se asigna a mano desde la app)
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
type Consultor = { id: string; nombre: string; secreto: string; ultima_sync_ok_at?: string | null };
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
  sin_asignar: number; ignoradas: number; errores: number;
};
const conteoVacio = (estado = 'ok'): Conteo => ({
  estado, traidas: 0, creadas: 0, actualizadas: 0, vinculadas: 0, sin_asignar: 0, ignoradas: 0, errores: 0,
});

const dormir = (ms: number) => new Promise((r) => setTimeout(r, ms));

class SinPresupuesto extends Error {}

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
    if (!r.ok) throw new Error(`Fathom respondio HTTP ${r.status}`);
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
// Alumnos de los programas habilitados, indexados por mail
// ---------------------------------------------------------------------------
type Alumno = { id: string; programa_id: string; vivo: boolean };
async function cargarAlumnos(sb: SupabaseClient, programas: string[]): Promise<Map<string, Alumno[]>> {
  const mapa = new Map<string, Alumno[]>();
  const PAG = 1000;
  for (let desde = 0; ; desde += PAG) {
    const { data, error } = await sb.from('cs_clientes').select('id,programa_id,email,estado')
      .in('programa_id', programas).not('email', 'is', null).order('id').range(desde, desde + PAG - 1);
    if (error) throw new Error(`no se pudieron leer los alumnos: ${error.message}`);
    for (const c of data ?? []) {
      const e = String(c.email).toLowerCase().trim();
      if (!e) continue;
      const v = mapa.get(e) ?? [];
      v.push({ id: c.id, programa_id: c.programa_id, vivo: !['finalizado', 'baja'].includes(c.estado) });
      mapa.set(e, v);
    }
    if (!data || data.length < PAG) break;
  }
  return mapa;
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
// Una reunion -> payload de cs_fathom_registrar
// ---------------------------------------------------------------------------
function armarPayload(m: any, consultor: string, alumno: Alumno | undefined, candidatos: string[], externos: string[]) {
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

  // Consultores activos (migracion 124) y que secretos existen
  const { data: cons, error: econs } = await sb.from('cs_fathom_consultores')
    .select('id,nombre,secreto,ultima_sync_ok_at').eq('activo', true).order('orden').order('id');
  if (econs) return responder({ error: `no se pudo leer cs_fathom_consultores (migracion 124 corrida?): ${econs.message}` }, 500);
  const cuentas = resolverCuentas((cons ?? []) as Consultor[]);
  if (!cuentas.some((c) => c.clave)) {
    return responder({
      error: 'ningun consultor activo tiene su secreto cargado en la funcion',
      consultores: cuentas.map((c) => ({ id: c.id, secreto: c.secreto, estado: c.omitir })),
    }, 500);
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
    if (cuerpo.desde) return new Date(`${cuerpo.desde}T00:00:00-03:00`).toISOString();
    const base = c.ultima_sync_ok_at ? Date.parse(c.ultima_sync_ok_at) - 2 * 86400000 : ms60;
    return new Date(base).toISOString();
  };
  const hastaISO = cuerpo.hasta ? new Date(`${cuerpo.hasta}T23:59:59-03:00`).toISOString() : null;
  const desdeISO = cuentas.filter((c) => c.clave).map((c) => desdeDe(c)).sort()[0];

  const { data: corrida, error: ecor } = await sb.from('cs_fathom_corridas')
    .insert({ origen, desde: desdeISO, estado: 'en_curso' }).select('id').single();
  if (ecor) return responder({ error: `no se pudo abrir la corrida: ${ecor.message}` }, 500);

  const porConsultor: Record<string, Conteo> = {};
  const errores: { recording_id: unknown; motivo: string }[] = [];
  let totalErrores = 0;
  let parcial = false;
  let fatal: string | null = null;

  const falla = (c: Conteo, cta: string, id: unknown, motivo: string) => {
    totalErrores++;
    c.errores++;
    if (errores.length < MAX_ERRORES_DETALLE) errores.push({ recording_id: id, motivo: `${cta}: ${motivo}`.slice(0, 300) });
  };

  try {
    const alumnos = await cargarAlumnos(sb, programas);

    for (const cuenta of cuentas) {
      const c = porConsultor[cuenta.id] = conteoVacio();
      if (cuenta.omitir) { c.estado = cuenta.omitir; continue; }
      if (parcial) { c.estado = 'omitido_por_tiempo'; continue; }

      const desdeCuenta = desdeDe(cuenta);
      let cursor: string | null = null;
      let cuentaFallo = false;
      do {
        if (Date.now() + PAUSA_MS > limite) { parcial = true; c.estado = 'parcial'; break; }
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
          if (e instanceof SinPresupuesto) { parcial = true; c.estado = 'parcial'; break; }
          falla(c, cuenta.id, null, (e as Error).message);
          cuentaFallo = true;
          break;   // esta cuenta no sigue; las demas si
        }

        for (const m of pagina.items ?? []) {
          c.traidas++;
          try {
            const invitados: any[] = Array.isArray(m.calendar_invitees) ? m.calendar_invitees : [];
            if (!invitados.some((i) => i?.is_external)) { c.ignoradas++; continue; }
            const grabador = String(m.recorded_by?.email ?? '').toLowerCase().trim();
            const externos = [...new Set(invitados
              .filter((i) => i?.is_external && i?.email)
              .map((i) => String(i.email).toLowerCase().trim())
              .filter((e) => e && e !== grabador))];
            const { alumno, candidatos } = resolverAlumno(externos, alumnos);
            const { data, error } = await sb.rpc('cs_fathom_registrar',
              { p: armarPayload(m, cuenta.id, alumno, candidatos, externos) });
            if (error) { falla(c, cuenta.id, m.recording_id, error.message); continue; }
            const r = String(data?.resultado ?? '');
            if (r === 'creada') c.creadas++;
            else if (r === 'actualizada') c.actualizadas++;
            else if (r === 'vinculada') c.vinculadas++;
            else c.sin_asignar++;
          } catch (e) {
            falla(c, cuenta.id, m?.recording_id, (e as Error).message);
          }
        }

        cursor = pagina.next_cursor ?? null;
        if (cursor) await dormir(PAUSA_MS);   // limite de Fathom: por cuenta (key)
      } while (cursor);

      if (c.estado !== 'parcial') {
        c.estado = cuentaFallo && c.traidas === 0 ? 'error' : c.errores ? 'con_errores' : 'ok';
      }
    }
  } catch (e) {
    fatal = (e as Error).message;
  }

  // Totales
  const tot = conteoVacio();
  for (const c of Object.values(porConsultor)) {
    tot.traidas += c.traidas; tot.creadas += c.creadas; tot.actualizadas += c.actualizadas;
    tot.vinculadas += c.vinculadas; tot.sin_asignar += c.sin_asignar; tot.ignoradas += c.ignoradas;
  }
  const asignadas = tot.creadas + tot.actualizadas + tot.vinculadas;
  const estado = fatal ? 'error' : parcial ? 'parcial' : totalErrores ? 'con_errores' : 'ok';
  const detalle = [
    fatal ? `error: ${fatal}` : '',
    parcial ? 'corrida cortada por tiempo: repetir (o usar "desde"/"hasta" por tramos)' : '',
    ...Object.entries(porConsultor).filter(([, c]) => ['sin_secreto', 'clave_repetida'].includes(c.estado))
      .map(([id, c]) => `${id}: ${c.estado === 'sin_secreto' ? 'saltado, falta el secreto' : 'saltado, misma key que otro consultor'}`),
    ...errores.map((e) => `${e.recording_id ?? 'cuenta'}: ${e.motivo}`),
  ].filter(Boolean).join('\n').slice(0, 2000);

  // Resultado de cada consultor (solo conteos): lo muestra Configuracion.
  const fin = new Date().toISOString();
  const ESTADOS_BD = ['ok', 'parcial', 'con_errores', 'error', 'sin_secreto', 'clave_repetida', 'omitido_por_tiempo'];
  for (const cuenta of cuentas) {
    const c = porConsultor[cuenta.id];
    if (!c) continue;
    const { estado: e, ...resumen } = c;
    const fila: Record<string, unknown> = {
      ultimo_at: fin, ultimo_estado: ESTADOS_BD.includes(e) ? e : 'error', ultimo_resumen: resumen,
    };
    if (e === 'ok') fila.ultima_sync_ok_at = new Date(inicio).toISOString();
    await sb.from('cs_fathom_consultores').update(fila).eq('id', cuenta.id);
  }
  const desglose = Object.fromEntries(cuentas.filter((c) => porConsultor[c.id])
    .map((c) => [c.id, { nombre: c.nombre, ...porConsultor[c.id] }]));

  await sb.from('cs_fathom_corridas').update({
    fin, estado, traidas: tot.traidas, asignadas, creadas: tot.creadas,
    actualizadas: tot.actualizadas, vinculadas: tot.vinculadas, sin_asignar: tot.sin_asignar,
    ignoradas: tot.ignoradas, errores: totalErrores, parcial, detalle: detalle || null,
    por_consultor: desglose,
  }).eq('id', corrida.id);

  // Solo conteos y motivos: nunca contenido de llamadas, mails ni la key.
  return responder({
    corrida_id: corrida.id, estado, invocado_por: quien, desde: desdeISO, hasta: hastaISO,
    programas_habilitados: programas, consultores: desglose,
    traidas: tot.traidas, asignadas, creadas: tot.creadas, actualizadas: tot.actualizadas,
    vinculadas: tot.vinculadas, sin_asignar: tot.sin_asignar, ignoradas_internas: tot.ignoradas,
    errores: totalErrores, parcial, segundos: Math.round((Date.now() - inicio) / 100) / 10,
    detalle_errores: fatal ? [{ recording_id: null, motivo: fatal }, ...errores] : errores,
  }, fatal ? 500 : 200);
});
