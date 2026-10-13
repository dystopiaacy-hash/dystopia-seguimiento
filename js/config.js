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

/* Semáforo de "Última llamada" (102): días desde la última llamada con el alumno.
   Verde hasta AMARILLO_DESDE - 1, amarillo de AMARILLO_DESDE a ROJO_DESDE - 1, rojo desde ROJO_DESDE.
   Único lugar donde se definen: Clientes, Maestro y Hoy leen estos dos números.
   Pendiente de decisión de Joaquín: 15 / 21 (los de Evolve) o 7 / 10. */
export const LLAMADA_AMARILLO_DESDE = 15;
export const LLAMADA_ROJO_DESDE = 21;

/* Satisfacción por etapa (106): color del último puntaje. Menos de ROJO_MENOS = rojo,
   de ahí hasta VERDE_DESDE - 1 = amarillo (7 y 8), VERDE_DESDE o más = verde (9 y 10).
   Los avisos a Discord (menos de 7, y 9 o 10 con testimonio) los dispara la base con los mismos números. */
export const SATISF_ROJO_MENOS = 7;
export const SATISF_VERDE_DESDE = 9;

/* "Sugerido para upsell" (106). Regla visible: al menos un win en los últimos UPSELL_WINS_DIAS días,
   último puntaje de satisfacción >= UPSELL_PUNTAJE_MIN (si tiene) y semáforo de última llamada
   que no esté en rojo. La sugerencia no marca sola: el CSM confirma. */
export const UPSELL_WINS_DIAS = 30;
export const UPSELL_PUNTAJE_MIN = 9;
