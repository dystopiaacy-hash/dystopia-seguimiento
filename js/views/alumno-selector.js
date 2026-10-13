/* Selector de alumno por nombre (106): acentos y mayúsculas no importan. Lo usan el alta rápida
   de wins en Hoy y la mención de dudas. clientes = [{ id, nombre, estado }] ya cargados. */
import { coincide } from '../normalizar.js';
import { esVivo, ESTADO_LABEL } from '../datos.js';
import { montarBuscador } from './buscador.js';

export function montarSelectorAlumno(box, clientes, { id = 'alumno-sel', placeholder = 'Buscar alumno por nombre…' } = {}) {
  let elegido = null;
  const b = montarBuscador(box, {
    id, placeholder,
    buscar: q => clientes
      .filter(c => coincide(c.nombre, q))
      /* vivos primero, después por nombre */
      .sort((x, y) => (Number(esVivo(y)) - Number(esVivo(x))) || (x.nombre || '').localeCompare(y.nombre || '', 'es'))
      .map(c => ({ id: c.id, label: c.nombre, detalle: ESTADO_LABEL[c.estado] || c.estado, cliente: c })),
    alElegir: it => { elegido = it.cliente; b.poner(it.label); },
    alEscribir: () => { elegido = null; }
  });
  return {
    /* El alumno elegido en la lista, o null si todavía no eligió uno. */
    cliente: () => elegido,
    limpiar: () => { elegido = null; b.limpiar(); },
    foco: b.foco
  };
}
