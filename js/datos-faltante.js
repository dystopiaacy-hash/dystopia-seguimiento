/* La tabla, vista o función no existe: la migración 106 todavía no se corrió (o falta una columna
   que trae). Las lecturas de lo nuevo la usan para devolver "no hay" en vez de romper la pantalla. */
export function faltaObjeto(e) {
  if (!e) return false;
  if (['42P01', 'PGRST205', '42883', 'PGRST202', '42703'].includes(e.code)) return true;
  return /does not exist|schema cache|could not find the function/i.test(e.message || '');
}

/* Los mensajes "cs: ..." de las funciones de la 106 ya están escritos para la persona. */
export function mensajeCs(e, respaldo) {
  const m = (e && e.message) || '';
  return /^cs: /.test(m) ? m.slice(4) : (respaldo || m || 'Error desconocido.');
}
