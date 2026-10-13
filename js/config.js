/* Mismo proyecto de Supabase que Dystopia (misma auth, mismos usuarios).
   La publishable key es pública por diseño: la seguridad la dan las políticas RLS. */
export const SUPABASE_URL = 'https://alxdjcdfpdayucassfub.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_EIkOqy24hED4t707eKnpDA_7s0DR4mE';

/* Zona horaria de negocio: hoy, días restantes y vencimientos se calculan acá, nunca en UTC. */
export const TZ = 'America/Argentina/Buenos_Aires';

/* Base del link de onboarding que se le manda al alumno (único lugar donde se arma).
   '' = el mismo dominio desde el que se abre la app (window.location.origin): hoy el de
   vercel.app. Al pasar a producto.dystopia.com.ar alcanza con abrir la app desde ese
   dominio, o con poner acá 'https://producto.dystopia.com.ar' (sin barra final).
   La app de Ventas arma el link con su propia base: la 096 le devuelve el path. */
export const ONBOARDING_BASE_URL = 'https://producto.dystopia.com.ar';
