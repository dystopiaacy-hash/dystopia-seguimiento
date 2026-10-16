/* Usuario actual: rol (de crm_members, igual que Dystopia), programas visibles y nivel.
   El acceso a Producto lo da 079: fundador (crm_members) ve y edita todo; el resto
   entra por cs_accesos, por programa, con nivel 'lectura' o 'edicion'. La RLS de
   cs_programas (cs_puede_ver) ya recorta los programas visibles. */
import { sb } from './supabase.js';

export const yo = { userId: null, email: '', rol: null, nombre: '', programas: [], niveles: {} };

/* Mismo orden que las cuentas en Dystopia; activos primero. */
const ORDEN = ['liam', 'agus', 'teo'];

function ordenar(lista) {
  const pos = id => { const i = ORDEN.indexOf(id); return i < 0 ? ORDEN.length : i; };
  return lista.slice().sort((a, b) =>
    (b.activo - a.activo) || (pos(a.id) - pos(b.id)) || a.nombre.localeCompare(b.nombre, 'es'));
}

export async function cargarProgramas() {
  const { data, error } = await sb.from('cs_programas').select('id,nombre,marca,activo');
  if (error) throw error;
  yo.programas = ordenar(data || []);
  return yo.programas;
}

/* Devuelve true si el usuario puede usar la app. */
export async function cargarSesion(user) {
  yo.userId = user.id;
  yo.email = user.email || '';
  const { data: mem, error } = await sb.from('crm_members')
    .select('rol,nombre').eq('user_id', user.id).maybeSingle();
  if (error) throw error;
  yo.rol = mem ? mem.rol : null;
  yo.nombre = (mem && mem.nombre) || yo.email;
  yo.niveles = {};
  await cargarProgramas();
  if (yo.rol !== 'fundador') {
    const { data: acc, error: errAcc } = await sb.from('cs_accesos').select('programa_id,nivel');
    if (errAcc) throw errAcc;
    for (const a of acc || []) yo.niveles[a.programa_id] = a.nivel;
  }
  return yo.rol === 'fundador' || yo.programas.length > 0;
}

export function esFundador() {
  return yo.rol === 'fundador';
}

/* Sin ningún programa en 'edicion' (y sin ser fundador): la app es de solo lectura.
   La base lo impone igual (cs_puede_editar); esto evita mostrar controles que fallarían. */
export function soloLectura() {
  return yo.rol !== 'fundador' && !Object.values(yo.niveles).includes('edicion');
}

/* Edición por programa (selección y edición masiva): fundador, o nivel 'edicion' en ESE programa.
   soloLectura() mira todos los programas; acá el cliente@ de un programa no edita otro. */
export function puedeEditarPrograma(id) {
  return yo.rol === 'fundador' || yo.niveles[id] === 'edicion';
}

/* Llamadas de Fathom sin asignar (122): fundador o CSM (edición en algún programa).
   La base lo impone igual con cs_fathom_gestor(). */
export function puedeGestionarFathom() {
  return yo.rol === 'fundador' || Object.values(yo.niveles).includes('edicion');
}

/* Chat interno / Dystopita (140, 141): fundador, rol producto (edición en algún programa) o rol cliente con programa.
   La base lo impone igual con cs_chat_puede() y la RLS recorta al cliente a su programa. */
export function puedeUsarChatIa() {
  return puedeGestionarFathom() || (yo.rol === 'cliente' && yo.programas.length > 0);
}

export function programa(id) {
  return yo.programas.find(p => p.id === id) || null;
}

/* Fundador arranca en el panel; un cliente entra directo a su (primer) programa. */
export function rutaInicio() {
  if (esFundador() || !yo.programas.length) return 'panel';
  return 'p/' + encodeURIComponent(yo.programas[0].id);
}

export function etiquetaRol() {
  if (yo.rol === 'fundador') return 'Fundador';
  return soloLectura() ? 'Solo lectura' : 'Edición';
}
