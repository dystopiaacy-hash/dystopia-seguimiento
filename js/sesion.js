/* Usuario actual: rol (de crm_members, igual que Dystopia) y programas visibles.
   La RLS de cs_programas (cs_puede_ver) ya recorta: fundador ve los 5, un 'cliente'
   solo los asignados, un editor ninguno. */
import { sb } from './supabase.js';

export const yo = { userId: null, email: '', rol: null, nombre: '', programas: [] };

/* Mismo orden que las cuentas en Dystopia; activos primero. */
const ORDEN = ['liam', 'agus', 'teo', 'mauro', 'lucas'];

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
  if (yo.rol !== 'fundador' && yo.rol !== 'cliente') { yo.programas = []; return false; }
  await cargarProgramas();
  return yo.rol === 'fundador' || yo.programas.length > 0;
}

export function esFundador() {
  return yo.rol === 'fundador';
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
  return { fundador: 'Fundador', cliente: 'Cliente', editor: 'Editor' }[yo.rol] || '';
}
