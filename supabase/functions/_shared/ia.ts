// _shared/ia.ts — helper de IA para Edge Functions (Deno). Base común de las apps de Dystopia.
//
// Llama a la Messages API de Anthropic y SIEMPRE deja una fila en public.ia_uso (migración 137),
// también si la llamada falla. Sin topes por gasto: solo mide.
//
// Contrato de ia_uso (compartido con el CRM; si cambia, cambia en las dos copias):
//   app ('producto'|'crm'|'finanzas'|'ventas'), funcion, user_id (null si lo dispara un cron),
//   cliente_id (texto), modelo, tokens_entrada, tokens_salida, costo_usd, ok, error, ms.
//
// Secreto de la función: ANTHROPIC_API_KEY (Supabase > Edge Functions > Secrets).
// La clave y el texto de los alumnos NUNCA van a logs ni a la columna `error`: ahí solo
// "HTTP <status>" y el tipo de error de la API.
//
// Uso:
//   const r = await llamarClaude({
//     app: 'producto', funcion: 'en_que_esta', modelo: MODELOS.haiku, cliente_id: id,
//     sistema: 'Sos ...', mensajes: [{ role: 'user', content: '...' }], max_tokens: 2000, effort: 'low',
//   });
// En los modelos 5.5 el thinking viene prendido y gasta tokens de salida: dejar max_tokens holgado.
// Solo se lee el texto de los bloques `text` (los `thinking` se descartan).
//   if (r.ok) usar(r.texto);
//
// Herramientas (tool use, 139/140): `herramientas` va tal cual a la API; NUNCA se manda tool_choice
// (los 5.5 dan 400 con any/tool: queda en auto). Si el modelo pide herramientas, r.usos trae
// [{id, name, input}] y r.contenido el contenido COMPLETO de la respuesta (con los bloques de
// thinking): hay que devolverlo tal cual como turno del assistant junto con los tool_result.

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.116.0';

// --- Modelos -----------------------------------------------------------------
// Barato, para resúmenes. Se puede cambiar sin tocar código con el secreto IA_MODELO_HAIKU.
export const MODELOS = {
  haiku: Deno.env.get('IA_MODELO_HAIKU') || 'claude-haiku-5-5',
  sonnet: Deno.env.get('IA_MODELO_SONNET') || 'claude-sonnet-5-5',
} as const;

// --- Precios (USD por millón de tokens) -----------------------------------------
// Fuente: documentación oficial de Anthropic (cacheada 06/10/2026).
// Haiku 5.5: 0,10 / 0,50 con prompts de hasta 100K tokens; por encima, 0,50 / 2,50 (todo el pedido).
// Un modelo que no está en la tabla se registra con costo_usd = null (no se inventa).
type Precio = { entrada: number; salida: number; sobre100k?: { entrada: number; salida: number } };
const PRECIOS: Record<string, Precio> = {
  'claude-haiku-5-5': { entrada: 0.10, salida: 0.50, sobre100k: { entrada: 0.50, salida: 2.50 } },
  'claude-sonnet-5-5': { entrada: 2, salida: 10 },
  'claude-haiku-4-5-20251001': { entrada: 1, salida: 5 },
  'claude-haiku-4-5': { entrada: 1, salida: 5 },
};

// content: texto o bloques (tool_use / tool_result / el contenido devuelto por el modelo)
export type Mensaje = { role: 'user' | 'assistant'; content: string | unknown[] };
export type UsoHerramienta = { id: string; name: string; input: Record<string, unknown> };
export type OpcionesClaude = {
  app: 'producto' | 'crm' | 'finanzas' | 'ventas';
  funcion: string;
  modelo: string;
  sistema?: string;
  mensajes: Mensaje[];
  max_tokens: number;
  user_id?: string | null;
  cliente_id?: string | null;
  /** Solo para modelos 4.x: en Haiku/Sonnet 5.5 un valor no default da 400, por eso no se manda. */
  temperatura?: number;
  /** Esfuerzo del thinking adaptativo (output_config.effort). Si falta, rige el default del modelo. */
  effort?: 'low' | 'medium' | 'high';
  /** cliente de Supabase con service role; si falta, se crea uno con las variables de la función */
  supabase?: SupabaseClient;
  /** definiciones de herramientas ({name, description, input_schema}); sin tool_choice (auto) */
  herramientas?: unknown[];
};
export type ResultadoClaude = {
  ok: boolean;
  texto: string;
  modelo: string;
  tokens_entrada: number | null;
  tokens_salida: number | null;
  costo_usd: number | null;
  ms: number;
  error: string | null;
  /** pedidos de herramientas del modelo (vacío si no pidió ninguna) */
  usos: UsoHerramienta[];
  /** contenido completo de la respuesta (para devolverlo en el turno siguiente de un tool use) */
  contenido: unknown[];
  stop_reason: string | null;
};

const URL_API = 'https://api.anthropic.com/v1/messages';
const REINTENTOS = 3;
const ESPERA_MAX_MS = 20000;

export function calcularCosto(modelo: string, entrada: number | null, salida: number | null): number | null {
  const base = PRECIOS[modelo];
  if (!base || entrada == null || salida == null) return null;
  const p = base.sobre100k && entrada > 100_000 ? base.sobre100k : base;
  return Math.round(((entrada * p.entrada + salida * p.salida) / 1_000_000) * 1e6) / 1e6;
}

function clienteServicio(): SupabaseClient | null {
  const url = Deno.env.get('SUPABASE_URL');
  let clave = '';
  const crudo = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (crudo) {
    try {
      const j = JSON.parse(crudo);
      const vals = Array.isArray(j) ? j : j && typeof j === 'object' ? Object.values(j) : [];
      clave = String(vals.find((v) => typeof v === 'string' && v.startsWith('sb_secret_')) ?? '');
    } catch { /* sigue con la otra */ }
  }
  if (!clave) clave = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!url || !clave) return null;
  return createClient(url, clave, { auth: { persistSession: false } });
}

async function registrar(o: OpcionesClaude, r: ResultadoClaude): Promise<void> {
  try {
    const sb = o.supabase ?? clienteServicio();
    if (!sb) { console.error('[ia] no hay cliente de Supabase para registrar el uso'); return; }
    const { error } = await sb.from('ia_uso').insert({
      app: o.app, funcion: o.funcion, user_id: o.user_id ?? null, cliente_id: o.cliente_id ?? null,
      modelo: r.modelo, tokens_entrada: r.tokens_entrada, tokens_salida: r.tokens_salida,
      costo_usd: r.costo_usd, ok: r.ok, error: r.error ? r.error.slice(0, 300) : null, ms: r.ms,
    });
    if (error) console.error('[ia] no se pudo registrar ia_uso:', error.code ?? 'error');
  } catch (e) {
    console.error('[ia] fallo al registrar ia_uso:', (e as Error).name);
  }
}

const dormir = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function llamarClaude(o: OpcionesClaude): Promise<ResultadoClaude> {
  const t0 = Date.now();
  const res: ResultadoClaude = {
    ok: false, texto: '', modelo: o.modelo, tokens_entrada: null, tokens_salida: null,
    costo_usd: null, ms: 0, error: null, usos: [], contenido: [], stop_reason: null,
  };
  const clave = (Deno.env.get('ANTHROPIC_API_KEY') ?? '').trim();
  if (!clave) {
    res.error = 'falta el secreto ANTHROPIC_API_KEY';
  } else {
    const cuerpo = JSON.stringify({
      model: o.modelo, max_tokens: o.max_tokens, system: o.sistema, messages: o.mensajes,
      // temperature solo en 4.x (en 5.5 devuelve 400 con valores no default)
      ...(o.temperatura != null && /(^|-)4-/.test(o.modelo) ? { temperature: o.temperatura } : {}),
      ...(o.effort ? { output_config: { effort: o.effort } } : {}),
      ...(o.herramientas?.length ? { tools: o.herramientas } : {}),
    });
    for (let intento = 1; intento <= REINTENTOS; intento++) {
      try {
        const r = await fetch(URL_API, {
          method: 'POST',
          headers: { 'x-api-key': clave, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
          body: cuerpo,
        });
        if ((r.status === 429 || r.status === 529) && intento < REINTENTOS) {
          const ra = Number(r.headers.get('retry-after'));
          const espera = Math.min(ESPERA_MAX_MS, Number.isFinite(ra) && ra > 0 ? ra * 1000 : 1500 * 2 ** (intento - 1));
          await r.text().catch(() => '');
          await dormir(espera);
          continue;
        }
        const j = await r.json().catch(() => null);
        if (!r.ok) {
          // Solo status y tipo de error: el mensaje de la API puede citar el pedido.
          const tipo = typeof j?.error?.type === 'string' ? j.error.type : '';
          res.error = `HTTP ${r.status}${tipo ? ' ' + tipo : ''}`;
          break;
        }
        res.tokens_entrada = Number.isFinite(j?.usage?.input_tokens) ? j.usage.input_tokens : null;
        res.tokens_salida = Number.isFinite(j?.usage?.output_tokens) ? j.usage.output_tokens : null;
        res.texto = Array.isArray(j?.content)
          ? j.content.filter((b: { type?: string }) => b?.type === 'text').map((b: { text?: string }) => b.text ?? '').join('').trim()
          : '';
        res.contenido = Array.isArray(j?.content) ? j.content : [];
        res.stop_reason = typeof j?.stop_reason === 'string' ? j.stop_reason : null;
        res.usos = res.contenido
          .filter((b) => (b as { type?: string })?.type === 'tool_use')
          .map((b) => {
            const x = b as { id?: string; name?: string; input?: Record<string, unknown> };
            return { id: String(x.id ?? ''), name: String(x.name ?? ''), input: x.input ?? {} };
          });
        if (!res.texto && !res.usos.length) { res.error = 'respuesta vacía'; break; }
        res.ok = true;
        break;
      } catch (e) {
        res.error = `red: ${(e as Error).name}`;
        if (intento < REINTENTOS) await dormir(1000 * intento);
      }
    }
  }
  res.ms = Date.now() - t0;
  res.costo_usd = calcularCosto(res.modelo, res.tokens_entrada, res.tokens_salida);
  await registrar(o, res);
  return res;
}
