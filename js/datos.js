/* Lecturas y escrituras compartidas por las vistas de programa.
   Los cálculos (semáforo, KPIs, días, porcentajes) ya vienen hechos de las vistas
   cs_v_clientes y cs_v_kpis_programa: acá no se recalculan. */
import { sb } from './supabase.js';
import { yo } from './sesion.js';

/* Estados que la vista de KPIs considera "clientes vivos". 'pausado' (039) no cuenta:
   sus días no corren y no genera alertas de renovación ni de chequeo. */
export const ESTADOS_VIVOS = ['onboarding', 'activo', 'en_renovacion'];

export const ESTADO_LABEL = {
  onboarding: 'Onboarding',
  activo: 'Activo',
  en_renovacion: 'En renovación',
  pausado: 'Pausado',
  finalizado: 'Finalizado',
  baja: 'Baja'
};

/* Color del badge de estado: peso distinto según etapa del ciclo de vida. */
export const ESTADO_COLOR = {
  onboarding: 'var(--cyan)',
  activo: 'var(--sem-verde)',
  en_renovacion: 'var(--sem-amarillo)',
  pausado: 'var(--estado-pausado)',
  finalizado: 'var(--text-faint)',
  baja: 'var(--text-faint)'
};

export const ONBOARDING_LABEL = {
  pendiente_agendar: 'Sin agendar',
  agendada: 'Agendada',
  realizada: 'Hecha',
  no_show: 'No asistió',
  cancelada: 'Cancelada'
};

export const ALERTA_LABEL = {
  renovacion_proxima: 'Renovación próxima',
  devolucion_vencida: 'Devolución vencida',
  onboarding_demorado: 'Onboarding demorado',
  accionable_bpf_vencido: 'Accionable BPF vencido',
  sin_chequeo: 'Sin chequeo',
  satisfaccion_baja: 'Satisfacción baja',
  programa_vencido: 'Programa vencido',
  proximo_contacto_vencido: 'Próximo contacto vencido',
  aviso_renovacion_1: '1er aviso de renovación',
  aviso_renovacion_2: '2do aviso de renovación'
};

/* Alertas que piden acción inmediata (rojo). El resto, amarillo. */
const ALERTAS_ROJAS = new Set(['devolucion_vencida', 'onboarding_demorado',
  'accionable_bpf_vencido', 'programa_vencido']);

export function nivelAlerta(tipo) {
  return ALERTAS_ROJAS.has(tipo) ? 'rojo' : 'amarillo';
}

export function esVivo(c) {
  return ESTADOS_VIVOS.includes(c.estado);
}

/* ---------- Errores en lenguaje claro (nunca se silencian) ---------- */
export function mensajeError(e) {
  if (!e) return 'Error desconocido.';
  const code = e.code || '';
  const msg = e.message || String(e);
  if (code === '42501' || /row-level security/i.test(msg)) {
    return 'No tenés permiso para hacer esto en este programa.';
  }
  if (code === '23505') return 'Ya existe un registro igual.';
  /* Los triggers propios ya traen el mensaje en castellano ("cs: ..."): va tal cual. */
  if (code === '23514') return /^cs: /.test(msg) ? msg.slice(4) : 'Los datos no cumplen una regla del programa: ' + msg;
  if (code === '23503') return 'Falta un dato relacionado (cliente o programa).';
  if (code === 'PGRST301' || /jwt/i.test(msg)) return 'Tu sesión venció. Recargá la página.';
  /* Las RPC de la app son cs_correr_diario (003) y cs_probar_discord (036). */
  if (code === 'PGRST202') return 'Esa función todavía no existe en la base: falta correr una migración (003 o 036).';
  if (/failed to fetch|networkerror/i.test(msg)) return 'Sin conexión con el servidor. Revisá internet.';
  return msg;
}

/* Un usuario nulo (trigger, job, formulario público) se muestra como "Sistema". */
export function etiquetaUsuario(nombre) {
  const s = (nombre == null ? '' : String(nombre)).trim();
  return s || 'Sistema';
}

/* ---------- Lecturas ---------- */

/* Fila completa de cs_programas (etapas, duración default, SLAs). */
export async function traerPrograma(id) {
  const { data, error } = await sb.from('cs_programas').select('*').eq('id', id).maybeSingle();
  if (error) throw error;
  return data;
}

export async function traerKpis(programaId) {
  const { data, error } = await sb.from('cs_v_kpis_programa').select('*')
    .eq('programa_id', programaId).maybeSingle();
  if (error) throw error;
  return data;
}

export async function traerClientes(programaId) {
  const { data, error } = await sb.from('cs_v_clientes').select('*')
    .eq('programa_id', programaId).order('nombre');
  if (error) throw error;
  return data || [];
}

export async function traerAlertas(programaId) {
  const { data, error } = await sb.from('cs_alertas').select('*')
    .eq('programa_id', programaId).eq('resuelta', false)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data || [];
}

/* ---------- Escrituras ---------- */

export async function resolverAlerta(id) {
  const { error } = await sb.from('cs_alertas').update({ resuelta: true }).eq('id', id);
  if (error) throw error;
}

/* Devuelve la fila creada. fecha_fin la calcula quien llama (fecha_inicio + duración). */
export async function crearCliente(fila) {
  const { data, error } = await sb.from('cs_clientes').insert(fila).select('*').single();
  if (error) throw error;
  return data;
}

/* Qué generaron los triggers al crear el cliente (call de onboarding + plantilla día 0). */
export async function traerGeneradoAlCrear(clienteId) {
  const [calls, acc] = await Promise.all([
    sb.from('cs_calls').select('tipo,estado').eq('cliente_id', clienteId),
    sb.from('cs_accionables').select('titulo,responsable,vence').eq('cliente_id', clienteId).order('vence')
  ]);
  if (calls.error) throw calls.error;
  if (acc.error) throw acc.error;
  return { calls: calls.data || [], accionables: acc.data || [] };
}

/* ---------- Etiquetas de las tablas hijas ---------- */
export const ACC_LABEL = { pendiente: 'Pendiente', en_proceso: 'En proceso', completado: 'Completado' };
export const ACC_COLOR = { pendiente: 'var(--text-dim)', en_proceso: 'var(--cyan)', completado: 'var(--sem-verde)' };
export const RESPONSABLE_LABEL = { bpf: 'BPF', cliente: 'Cliente' };

export const DEV_LABEL = { pendiente: 'Pendiente', en_proceso: 'En proceso', entregada: 'Entregada' };
export const DEV_COLOR = { pendiente: 'var(--sem-rojo)', en_proceso: 'var(--sem-amarillo)', entregada: 'var(--sem-verde)' };

export const CALL_TIPO_LABEL = { onboarding: 'Onboarding', seguimiento: 'Seguimiento', renovacion: 'Renovación', otra: 'Otra' };
/* cs_calls y la call de onboarding comparten los mismos 5 estados. */
export const CALL_ESTADO_LABEL = ONBOARDING_LABEL;
export const CALL_ESTADO_COLOR = {
  pendiente_agendar: 'var(--text-dim)', agendada: 'var(--cyan)', realizada: 'var(--sem-verde)',
  no_show: 'var(--sem-rojo)', cancelada: 'var(--text-faint)'
};

/* Pipeline de resell (037): cuatro estados abiertos, en orden, y dos cerrados. */
export const REN_ABIERTOS = ['en_proceso', 'contactado', 'call_agendada', 'propuesta_enviada'];
export const renAbierta = e => REN_ABIERTOS.includes(e);

export const REN_LABEL = {
  en_proceso: 'En proceso', contactado: 'Contactado', call_agendada: 'Call agendada',
  propuesta_enviada: 'Propuesta enviada', renovado: 'Renovado', no_renovado: 'No renovó'
};
export const REN_COLOR = {
  en_proceso: 'var(--sem-amarillo)', contactado: 'var(--sem-amarillo)', call_agendada: 'var(--cyan)',
  propuesta_enviada: 'var(--accent)', renovado: 'var(--sem-verde)', no_renovado: 'var(--text-faint)'
};

/* Qué compró al renovar (cs_renovaciones.resell_producto). Obligatorio al cerrar como renovado. */
export const RESELL_PRODUCTO_LABEL = {
  mismo_programa: 'Mismo programa', upgrade: 'Upsell', downgrade: 'Downsell', otro: 'Otro'
};

export const PRIORIDAD_LABEL = { alta: 'Alta', media: 'Media', baja: 'Baja' };

/* cs_seguimientos (038): canal obligatorio, avance opcional. */
export const CANAL_LABEL = { whatsapp: 'WhatsApp', mail: 'Mail', call: 'Call', reunion: 'Reunión', otro: 'Otro' };
export const AVANCE_LABEL = { bien: 'Bien', demorado: 'Demorado', trabado: 'Trabado' };
export const AVANCE_COLOR = { bien: 'var(--sem-verde)', demorado: 'var(--sem-amarillo)', trabado: 'var(--sem-rojo)' };

/* No hay directorio de usuarios en esta app (crm_members solo deja ver la fila propia):
   se distingue "yo" del resto del equipo. Sin usuario = lo hizo un trigger o un job. */
export function nombreUsuario(id) {
  if (!id) return 'Sistema';
  return id === yo.userId ? (yo.nombre || 'Yo') : 'Equipo';
}

/* ---------- SLA de devoluciones (una sola fuente para dashboard, ficha y tablero) ---------- */

/* Horas que estuvo (o lleva) esperando una devolución desde que se solicitó. */
export function horasEspera(dev) {
  const desde = dev && dev.solicitada_at ? Date.parse(dev.solicitada_at) : NaN;
  if (isNaN(desde)) return null;
  const hasta = dev.entregada_at ? Date.parse(dev.entregada_at) : Date.now();
  return Math.max(0, (hasta - desde) / 3600000);
}

/* Horas de atraso contra el SLA: solicitada_at + sla_devolucion_horas vs ahora.
   Positivo = fuera de SLA. Null si ya se entregó o no hay fecha. */
export function horasAtraso(dev, slaHoras) {
  if (!dev || dev.estado === 'entregada') return null;
  const desde = Date.parse(dev.solicitada_at);
  if (isNaN(desde)) return null;
  return (Date.now() - (desde + Number(slaHoras || 0) * 3600000)) / 3600000;
}

/* cliente_id -> horas del mayor atraso de sus devoluciones abiertas (solo las que ya
   pasaron el SLA). Es lo que ordena "Requiere atención" por antigüedad del problema. */
export function atrasoPorCliente(devoluciones, slaHoras) {
  const m = new Map();
  for (const d of devoluciones || []) {
    const h = horasAtraso(d, slaHoras);
    if (h == null || h <= 0) continue;
    m.set(d.cliente_id, Math.max(m.get(d.cliente_id) || 0, h));
  }
  return m;
}

/* ---------- Lecturas por programa ---------- */

async function lista(tabla, programaId, armar) {
  let q = sb.from(tabla).select('*').eq('programa_id', programaId);
  if (armar) q = armar(q);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
}

export const traerAccionablesPrograma = id =>
  lista('cs_accionables', id, q => q.order('vence', { ascending: true, nullsFirst: false }));
export const traerDevolucionesPrograma = id =>
  lista('cs_devoluciones', id, q => q.order('solicitada_at', { ascending: false }));
export const traerDevolucionesAbiertas = id =>
  lista('cs_devoluciones', id, q => q.in('estado', ['pendiente', 'en_proceso']));
export const traerCallsPrograma = id =>
  lista('cs_calls', id, q => q.order('fecha', { ascending: false, nullsFirst: true }));
export const traerFormularios = id =>
  lista('cs_formularios', id, q => q.order('nombre'));

/* ---------- Formularios (Fase 5) ---------- */

/* Los 5 tipos del CHECK de cs_formularios.tipo en 001. 'onboarding' es el único
   con efecto extra: al responderlo, cs_enviar_respuesta cierra el accionable de
   plantilla 'formulario_onboarding' del cliente. */
export const FORM_TIPO_LABEL = {
  onboarding: 'Onboarding',
  satisfaccion: 'Satisfacción',
  checkin: 'Check-in',
  devolucion: 'Devolución',
  otro: 'Otro'
};

/* Los 6 tipos de campo que acepta cs_validar_campos (001). */
export const CAMPO_TIPO_LABEL = {
  texto: 'Texto corto',
  parrafo: 'Párrafo',
  numero: 'Número',
  escala_0_10: 'Escala 0 a 10',
  opcion: 'Opción',
  si_no: 'Sí / No'
};

/* Respuestas de todo el programa. Sin cliente_id cuando el cliente se borró
   (la FK las deja huérfanas a propósito, ver 001). */
export const traerRespuestasPrograma = id =>
  lista('cs_respuestas', id, q => q.order('created_at', { ascending: false }).limit(2000));

/* ---------- Lecturas por cliente ---------- */

export async function traerCliente(id) {
  const { data, error } = await sb.from('cs_v_clientes').select('*').eq('id', id).maybeSingle();
  if (error) throw error;
  return data;
}

async function deCliente(tabla, clienteId, armar) {
  let q = sb.from(tabla).select('*').eq('cliente_id', clienteId);
  if (armar) q = armar(q);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
}

export const traerAccionablesCliente = id =>
  deCliente('cs_accionables', id, q => q.order('vence', { ascending: true, nullsFirst: false }).order('created_at'));
export const traerDevolucionesCliente = id =>
  deCliente('cs_devoluciones', id, q => q.order('solicitada_at', { ascending: false }));
export const traerCallsCliente = id =>
  deCliente('cs_calls', id, q => q.order('fecha', { ascending: false, nullsFirst: true }));
export const traerRenovacionesCliente = id =>
  deCliente('cs_renovaciones', id, q => q.order('iniciada_at', { ascending: false }));
export const traerRespuestasCliente = id =>
  deCliente('cs_respuestas', id, q => q.order('created_at', { ascending: false }));
/* El último primero, con el mismo criterio que cs_v_maestro y la alerta de 038. */
export const traerSeguimientosCliente = id =>
  deCliente('cs_seguimientos', id, q => q.order('fecha', { ascending: false })
    .order('created_at', { ascending: false }).limit(100));

/* cs_historial no tiene cliente_id: se pide por los ids del cliente y sus filas hijas. */
export async function traerHistorial(programaId, ids) {
  const registros = (ids || []).filter(Boolean);
  if (!registros.length) return [];
  const { data, error } = await sb.from('cs_historial').select('*')
    .eq('programa_id', programaId).in('registro_id', registros)
    .order('at', { ascending: false }).limit(200);
  if (error) throw error;
  return data || [];
}

/* ---------- Escrituras genéricas ---------- */

export async function crearFila(tabla, fila) {
  const { data, error } = await sb.from(tabla).insert(fila).select('*').single();
  if (error) throw error;
  return data;
}

export async function actualizarFila(tabla, id, cambios) {
  const { error } = await sb.from(tabla).update(cambios).eq('id', id);
  if (error) throw error;
}

export async function borrarFila(tabla, id) {
  const { error } = await sb.from(tabla).delete().eq('id', id);
  if (error) throw error;
}

/* ---------- Escrituras con regla propia ---------- */

/* Los triggers de 038 mueven ultimo_chequeo_at, la etapa del cliente (si viene) y
   dejan el avance en cs_historial. La base valida etapa y próximo contacto igual. */
export async function registrarSeguimiento(cliente, s) {
  const resumen = (s.resumen || '').trim();
  if (!CANAL_LABEL[s.canal]) throw new Error('Elegí por dónde fue el contacto.');
  if (!resumen) throw new Error('Escribí un resumen del contacto.');
  return crearFila('cs_seguimientos', {
    programa_id: cliente.programa_id, cliente_id: cliente.id, canal: s.canal, resumen,
    etapa: s.etapa || null, avance: s.avance || null, proximo_contacto: s.proximo_contacto || null
  });
}

/* Abre la renovación en un estado abierto (por defecto en_proceso). El trigger pasa
   al cliente a 'en_renovacion', salvo que ya esté finalizado y en días de gracia. */
export async function iniciarRenovacion(cliente, estado = 'en_proceso') {
  if (!renAbierta(estado)) throw new Error('Una renovación nueva tiene que arrancar en una etapa abierta.');
  return crearFila('cs_renovaciones', {
    programa_id: cliente.programa_id, cliente_id: cliente.id, estado
  });
}

/* Mueve una renovación abierta a otra etapa abierta. El cierre va por cerrarRenovacion. */
export async function moverRenovacion(id, estado) {
  if (!renAbierta(estado)) throw new Error('Para cerrar la renovación usá "Renovó" o "No renovó".');
  return actualizarFila('cs_renovaciones', id, { estado });
}

/* ---------- Maestro del CSM (037) ---------- */

export async function traerMaestro(programaId) {
  const { data, error } = await sb.from('cs_v_maestro').select('*')
    .eq('programa_id', programaId).order('nombre');
  if (error) throw error;
  return data || [];
}

/* Campos de cs_clientes que el CSM edita desde el maestro. Texto vacío = null. */
const CAMPOS_MAESTRO = ['prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha', 'nota_csm', 'testimonio'];

export async function guardarCampoCliente(id, campo, valor) {
  if (!CAMPOS_MAESTRO.includes(campo)) throw new Error('Ese campo no se edita desde el maestro.');
  const v = typeof valor === 'string' ? valor.trim() : valor;
  return actualizarFila('cs_clientes', id, { [campo]: v === '' ? null : v });
}

/* ---------- Renovaciones (Fase 4.2) ---------- */

export const traerRenovacionesPrograma = id =>
  lista('cs_renovaciones', id, q => q.order('iniciada_at', { ascending: false }));

/* Motivos de no renovación. El texto libre se suma al motivo elegido; así
   "Motivos de no renovación" de Métricas puede agrupar por el prefijo. */
export const MOTIVO_NO_RENOVACION = {
  precio: 'Precio',
  resultados: 'Resultados',
  tiempo: 'Falta de tiempo',
  otro: 'Otro'
};

export function armarMotivo(clave, texto) {
  const base = MOTIVO_NO_RENOVACION[clave] || 'Otro';
  const extra = (texto || '').trim();
  return extra ? `${base}: ${extra}` : base;
}

/* Cierra una renovación abierta. Los triggers hacen el resto:
   renovado -> cliente activo + fecha_fin nueva + contador (mismo_programa, upgrade,
   downgrade u otro: la fecha es la del programa que compró);
   no_renovado -> cliente activo (o finalizado si ya venció).
   producto es obligatorio con renovado: se valida acá para no llegar al error de la base.
   productoId (039, catálogo): con nuevaFechaFin null, la base calcula la fecha nueva
   (fin vigente o hoy, la mayor, + duración) y el cliente queda con ese producto. */
export async function cerrarRenovacion(id, { estado, nuevaFechaFin = null, motivo = null, producto = null, productoId = null }) {
  if (estado === 'renovado' && !RESELL_PRODUCTO_LABEL[producto]) {
    throw new Error('Elegí qué compró: mismo programa, upsell, downsell u otro.');
  }
  if (estado === 'renovado' && !nuevaFechaFin && !productoId) {
    throw new Error('Poné la nueva fecha de fin o elegí el producto.');
  }
  const cambios = estado === 'renovado'
    ? { estado, nueva_fecha_fin: nuevaFechaFin, motivo: null, resell_producto: producto, producto_id: productoId }
    : { estado, nueva_fecha_fin: null, motivo, resell_producto: null };
  return actualizarFila('cs_renovaciones', id, cambios);
}

/* Tasa de renovación de las cerradas desde una fecha (ISO). null si no hay cerradas.
   La histórica ya viene calculada en cs_v_kpis_programa.tasa_renovacion. */
export function tasaRenovacion(renovaciones, desdeISO = null) {
  let ren = 0, noren = 0;
  for (const r of renovaciones || []) {
    if (r.estado !== 'renovado' && r.estado !== 'no_renovado') continue;
    if (desdeISO && !(r.resultado_at && r.resultado_at >= desdeISO)) continue;
    if (r.estado === 'renovado') ren++; else noren++;
  }
  const total = ren + noren;
  return total ? { pct: Math.round((1000 * ren) / total) / 10, ren, noren, total } : null;
}

/* ---------- Métricas (Fase 4.4) ---------- */

/* Filas de cs_v_metricas_mensuales desde un mes (inclusive), en orden cronológico.
   La vista ya trae altas, renovados, no renovados, devoluciones entregadas,
   horas promedio de entrega, satisfacción promedio y n de respuestas: acá no se
   recalcula ninguna de esas columnas. Solo devuelve meses con al menos un evento. */
export async function traerMetricasMensuales(programaId, desdeMes) {
  let q = sb.from('cs_v_metricas_mensuales').select('*').eq('programa_id', programaId);
  if (desdeMes) q = q.gte('mes', desdeMes);
  const { data, error } = await q.order('mes');
  if (error) throw error;
  return data || [];
}

/* ---------- Chequeo diario (Fase 4.1) ---------- */

/* cs_correr_diario() valida adentro que sea el fundador. Devuelve los contadores. */
export async function correrChequeoDiario() {
  const { data, error } = await sb.rpc('cs_correr_diario');
  if (error) throw error;
  return data || {};
}

/* ---------- Config del programa (Fase 4.5) ---------- */

export async function guardarPrograma(id, cambios) {
  const { error } = await sb.from('cs_programas').update(cambios).eq('id', id);
  if (error) throw error;
}

export async function traerIntegracion(programaId) {
  const { data, error } = await sb.from('cs_integraciones').select('*')
    .eq('programa_id', programaId).maybeSingle();
  if (error) throw error;
  return data;
}

/* cs_probar_discord() (036) valida adentro que sea el fundador y manda el mensaje
   aunque las notificaciones estén desactivadas. Devuelve { enviado, motivo, envio_id }.
   "enviado" = quedó en la cola de pg_net: si Discord lo rechaza, la app no se entera. */
export async function probarDiscord(programaId) {
  const { data, error } = await sb.rpc('cs_probar_discord', { p_programa: programaId });
  if (error) throw error;
  return data || {};
}

/* Una fila por programa: upsert sobre la PK programa_id. */
export async function guardarIntegracion(programaId, cambios) {
  const { error } = await sb.from('cs_integraciones')
    .upsert({ programa_id: programaId, ...cambios, updated_at: new Date().toISOString() },
            { onConflict: 'programa_id' });
  if (error) throw error;
}
