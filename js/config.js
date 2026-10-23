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
   Decisión de Joaquín (123): 7 días aviso (amarillo) y 10 días alerta (rojo).
   El valor real es POR PROGRAMA y lo edita el fundador en Configuración (cs_servicio_config):
   Clientes, Maestro, Hoy, la ficha y el aviso a Discord leen ese mismo parámetro.
   Estos dos números son solo el valor por defecto si la migración 123 no está corrida. */
export const LLAMADA_AMARILLO_DESDE = 7;
export const LLAMADA_ROJO_DESDE = 10;

/* Alumno vencido hace más de estos días y sin renovación en curso: no cuenta como activo (162).
   Tiene que coincidir con el 30 de la migración 162. */
export const DIAS_VENCIDO_COMO_ACTIVO = 30;

/* Productos sin vencimiento (Skool de agus). La base exige duracion_dias > 0 y fecha_fin: se usa una
   duración de 100 años (SIN_VENCIMIENTO_DIAS) y una fecha de fin lejana (desde SIN_VENCIMIENTO_DESDE
   se muestra "Sin vencimiento" y no se cuentan días restantes). Ver js/sin-vencimiento.js. */
export const SIN_VENCIMIENTO_DIAS = 36500;
export const SIN_VENCIMIENTO_DESDE = '2099-01-01';

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

/* Pantalla "Vincular alumnos" de Finanzas (ruta #/vincular, verificada en dystopia-finanzas/js/app.js). */
export const FINANZAS_VINCULAR_URL = 'https://finanzas.dystopia.com.ar/#/vincular';
