/* Mismo proyecto de Supabase que Dystopia (misma auth, mismos usuarios).
   La publishable key es pública por diseño: la seguridad la dan las políticas RLS. */
export const SUPABASE_URL = 'https://alxdjcdfpdayucassfub.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_EIkOqy24hED4t707eKnpDA_7s0DR4mE';

/* Zona horaria de negocio: hoy, días restantes y vencimientos se calculan acá, nunca en UTC. */
export const TZ = 'America/Argentina/Buenos_Aires';
