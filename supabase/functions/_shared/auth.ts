// _shared/auth.ts — autorización común de las Edge Functions de IA (139, 140).
// Misma política que fathom-sync e ia-en-que-esta:
//   Authorization: Bearer sb_secret_...  (cron y curl)   o   Bearer <JWT de usuario> (pantalla).
// ia-en-que-esta tiene su propia copia (no se tocó); las funciones nuevas usan esta.

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.116.0';

export const URL_SB = Deno.env.get('SUPABASE_URL')!;

export const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};
export const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'content-type': 'application/json' } });

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

export const SECRETAS = (() => {
  const lista = valoresDe('SUPABASE_SECRET_KEYS').filter((k) => k.startsWith('sb_secret_'));
  if (lista.length) return lista;
  const sr = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  return sr.startsWith('sb_secret_') ? [sr] : [];
})();
const CLAVE_PUBLICA = valoresDe('SUPABASE_PUBLISHABLE_KEYS').find((k) => k.startsWith('sb_publishable_'))
  ?? Deno.env.get('SUPABASE_ANON_KEY') ?? null;

function iguales(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let dif = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) dif |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return dif === 0;
}

/** `cliente` es un cliente con el token del usuario: las consultas respetan su RLS y sus permisos. */
export type Quien = { tipo: 'secret_key' } | { tipo: 'usuario'; userId: string; cliente: SupabaseClient };

export async function autorizar(req: Request): Promise<Quien | null> {
  const m = (req.headers.get('authorization') ?? '').match(/^Bearer\s+(\S+)$/i);
  if (!m) return null;
  const token = m[1];
  if (token.startsWith('sb_secret_')) {
    return SECRETAS.some((k) => iguales(k, token)) ? { tipo: 'secret_key' } : null;
  }
  if (!CLAVE_PUBLICA || token.startsWith('sb_publishable_') || token.split('.').length !== 3) return null;
  const cliente = createClient(URL_SB, CLAVE_PUBLICA, {
    global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false },
  });
  const { data: u, error } = await cliente.auth.getUser(token);
  if (error || !u?.user) return null;
  return { tipo: 'usuario', userId: u.user.id, cliente };
}

/** Cliente con service role (null si la función no tiene sb_secret_). */
export function clienteServicio(): SupabaseClient | null {
  const clave = SECRETAS[0];
  if (!clave) return null;
  return createClient(URL_SB, clave, { auth: { persistSession: false } });
}
