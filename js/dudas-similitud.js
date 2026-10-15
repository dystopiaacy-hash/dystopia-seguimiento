/* Dudas parecidas SIN IA (134): normaliza, saca palabras vacías y compara por palabras compartidas.
   Puntaje = compartidas / raíz(palabras A × palabras B) (0 a 1). Es una ayuda para sugerir: la
   decisión es siempre de una persona. Si más adelante hay IA, este archivo es el que se reemplaza. */
import { norm } from './normalizar.js';

const VACIAS = new Set(('a al algo algun alguna ante aqui asi aun como con cual cuales cuando cuanto cuanta cuantos ' +
  'cuantas de del desde donde el ella ellos en entonces eso esa ese esto esta estas este estos es era fue ha han ' +
  'hay he la las le les lo los me mi mis mas muy no nos o otra otro para pero por porque puedo puede pueden ' +
  'podria podemos que quiero quiere se sea ser si sin sobre su sus te tengo tiene tienen todo tu un una uno unos ' +
  'unas y ya yo hago hace hacer hacen voy va van vamos tema cosa cosas vez').split(' '));

/* Palabras con contenido, sin plural simple (reel/reels, cuenta/cuentas). */
export function palabrasClave(texto) {
  const out = new Set();
  for (const w of norm(texto).split(' ')) {
    if (w.length < 3 || VACIAS.has(w)) continue;
    out.add(w.length > 4 && w.endsWith('s') ? w.slice(0, -1) : w);
  }
  return out;
}

export function similitud(a, b) {
  const A = a instanceof Set ? a : palabrasClave(a);
  const B = b instanceof Set ? b : palabrasClave(b);
  if (!A.size || !B.size) return 0;
  let comunes = 0;
  for (const w of A) if (B.has(w)) comunes += 1;
  return comunes / Math.sqrt(A.size * B.size);
}

/* Las `max` dudas más parecidas al texto, con puntaje >= minimo. dudas = filas de cs_v_dudas. */
export function parecidas(texto, dudas, { max = 3, minimo = 0.34, excluir = null } = {}) {
  const A = palabrasClave(texto);
  if (!A.size) return [];
  return dudas
    .filter(d => d.id !== excluir)
    .map(d => ({ duda: d, puntaje: similitud(A, d.texto) }))
    .filter(x => x.puntaje >= minimo)
    .sort((x, y) => y.puntaje - x.puntaje || y.duda.alumnos - x.duda.alumnos)
    .slice(0, max);
}
