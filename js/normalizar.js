/* Normalización de nombres para buscar: sin acentos, sin mayúsculas, solo letras y números.
   Es la misma regla que cs_norm_nombre en la base (070), para que el buscador del navegador
   y el de las funciones de carga coincidan. */
export const norm = s => String(s ?? '').toLowerCase()
  .normalize('NFD').replace(/[̀-ͯ]/g, '')
  .replace(/[^a-z0-9]+/g, ' ').trim();

/* Todas las palabras escritas están en el nombre (sin importar el orden). Vacío = coincide. */
export function coincide(nombre, consulta) {
  const q = norm(consulta);
  if (!q) return true;
  const n = norm(nombre);
  return q.split(' ').every(w => n.includes(w));
}
