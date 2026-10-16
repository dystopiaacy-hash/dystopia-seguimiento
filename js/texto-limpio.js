/* Texto de Fathom (markdown en bruto) -> texto plano legible. Solo para mostrar: no toca lo guardado.
   Saca asteriscos, comillas invertidas, numerales de títulos y guiones bajos de énfasis; los links
   [texto](url) quedan como "texto" y las URLs sueltas como "dominio.com/…". Las viñetas pasan a "•". */

const acortarUrl = u => {
  const m = String(u).match(/^https?:\/\/(?:www\.)?([^/?#\s]+)(\/[^?#\s]*)?/i);
  if (!m) return u;
  const ruta = m[2] && m[2] !== '/' ? '/…' : '';
  return m[1] + ruta;
};

export function limpiarMarkdown(s) {
  if (s == null) return '';
  let t = String(s).replace(/\r\n?/g, '\n');
  t = t.replace(/```[a-z]*\n?/gi, '');
  t = t.replace(/!?\[([^\]\n]*)\]\((https?:\/\/[^)\s]+)\)/g, (_, txt, url) => (txt.trim() ? txt.trim() : acortarUrl(url)));
  t = t.replace(/https?:\/\/[^\s)>\]]+/g, u => acortarUrl(u));
  t = t.replace(/^[ \t]{0,3}#{1,6}[ \t]+/gm, '');
  t = t.replace(/^[ \t]*[-*+][ \t]+/gm, '• ');
  t = t.replace(/\*\*([^*\n]+)\*\*/g, '$1').replace(/__([^_\n]+)__/g, '$1');
  t = t.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, '$1$2');
  t = t.replace(/`+/g, '').replace(/\*{2,}/g, '');
  t = t.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n');
  return t.trim();
}

/* Una sola línea para celdas de planilla. */
export const limpiarEnUnaLinea = s => limpiarMarkdown(s).replace(/\s*\n+\s*/g, ' · ');
