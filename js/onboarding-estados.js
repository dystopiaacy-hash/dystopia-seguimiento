/* Definición única de los estados de onboarding de cs_onboarding_lista (096).
   La usan la pestaña Onboarding (filtros y resumen) y el Dashboard (tarjeta
   "Onboarding pendientes"), para que los dos números siempre coincidan.
   "Sin onboarding" (sin_plantilla) es un producto sin plantilla y "Completos" no cuentan como pendientes. */
export const SIN_EMPEZAR = ['sin_link', 'pendiente'];
export const EN_CURSO = ['en_curso'];
export const COMPLETOS = ['completado'];
export const SIN_ONBOARDING = ['sin_plantilla'];

/* Cuenta alumnos de la lista por grupo de estados. */
export function contarOnboarding(alumnos) {
  const n = estados => alumnos.filter(a => estados.includes(a.onboarding)).length;
  const sinEmpezar = n(SIN_EMPEZAR);
  const enCurso = n(EN_CURSO);
  return {
    sinEmpezar, enCurso, pendientes: sinEmpezar + enCurso,
    completos: n(COMPLETOS), sinOnboarding: n(SIN_ONBOARDING)
  };
}
