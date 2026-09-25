/* Configuración del programa (#/p/:programa/config). Solo fundador: la ruta ya lo
   filtra (SECCIONES) y la RLS de cs_programas/cs_integraciones lo vuelve a exigir.
   Cada bloque guarda por separado: un error en la plantilla no se lleva puestos
   los SLAs. Los límites de acá son los mismos CHECK de 001. */
import { esc, plural, toast, confirmar } from '../ui.js';
import { tarjetaError } from './programa.js';
import {
  traerPrograma, traerIntegracion, guardarPrograma, guardarIntegracion,
  correrChequeoDiario, probarDiscord, mensajeError
} from '../datos.js';
import { esFundador } from '../sesion.js';
import { guardar, num } from './comunes.js';
import {
  htmlEtapas, leerEtapas, htmlPlantilla, leerPlantilla,
  completarKeys, validarPlantilla
} from './config-plantilla.js';

/* Mismos límites que los CHECK de cs_programas en 001. */
const AJUSTES = [
  ['duracion_default_dias', 'Duración del programa (días)', 1, 3650,
    'Se usa para la fecha de fin de un cliente nuevo y para el default al renovar.'],
  ['aviso_renovacion_dias', 'Aviso de renovación (días antes)', 0, 365,
    'Cuántos días antes del fin el cliente entra en "Iniciar renovación".'],
  ['sla_devolucion_horas', 'SLA de devoluciones (horas)', 1, 2160,
    'Pasadas estas horas sin entregar, la devolución queda fuera de SLA y el cliente en rojo.'],
  ['sla_onboarding_dias', 'SLA de onboarding (días)', 0, 365,
    'Días para agendar la call de onboarding antes de que el cliente pase a rojo.'],
  ['dias_sin_chequeo_alerta', 'Umbral de chequeo (días)', 1, 365,
    'Días sin chequear a un cliente antes de que aparezca en amarillo.'],
  ['satisfaccion_umbral_bajo', 'Umbral de satisfacción baja (0 a 10)', 0, 10,
    'Debajo de este puntaje, una respuesta genera alerta de satisfacción baja.']
];

const RX_DISCORD = /^https:\/\/((canary|ptb)\.)?(discord|discordapp)\.com\/api\/webhooks\//;

function campoAjuste(p, [campo, label, min, max, hint]) {
  const paso = campo === 'satisfaccion_umbral_bajo' ? '0.5' : '1';
  return `
    <div class="form-row"><label for="cf-${campo}">${esc(label)}</label>
      <input type="number" id="cf-${campo}" data-ajuste="${campo}" min="${min}" max="${max}" step="${paso}"
        value="${esc(p[campo])}">
      <div class="hint">${esc(hint)}</div></div>`;
}

function seccion(titulo, cuerpo, acciones = '') {
  return `
    <div class="conf-seccion">
      <div class="section-title">${esc(titulo)}<span class="line"></span>${acciones}</div>
      <div class="card">${cuerpo}</div>
    </div>`;
}

export function vistaConfig(el, programaId, vigente) {
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  let prog = null, integ = null;
  const estado = { etapas: [], plantilla: [] };

  /* ---------- Pintado ---------- */

  function pintar() {
    el.innerHTML = `
      ${seccion('Estado del programa', `
        <p class="conf-detalle">${esc(prog.nombre)}${prog.marca ? ' · ' + esc(prog.marca) : ''} ·
          ${prog.activo ? 'activo' : 'inactivo'}</p>
        <div class="hint">Un programa inactivo se sigue viendo, pero queda marcado como fuera de uso
          en la barra lateral y arriba de cada sección.</div>
        <button type="button" class="btn ${prog.activo ? '' : 'btn-accent'}" id="cf-activo">
          ${prog.activo ? 'Desactivar programa' : 'Activar programa'}</button>`)}

      ${seccion('Plazos y SLAs',
        `<div class="conf-grid">${AJUSTES.map(a => campoAjuste(prog, a)).join('')}</div>`,
        '<button type="button" class="btn btn-accent btn-sm" id="cf-guardar-ajustes">Guardar plazos</button>')}

      ${seccion('Etapas', `<div id="cf-etapas">${htmlEtapas(estado.etapas)}</div>`,
        '<button type="button" class="btn btn-accent btn-sm" id="cf-guardar-etapas">Guardar etapas</button>')}

      ${seccion('Plantilla de accionables', `<div id="cf-plantilla">${htmlPlantilla(estado.plantilla)}</div>`,
        '<button type="button" class="btn btn-accent btn-sm" id="cf-guardar-plantilla">Guardar plantilla</button>')}

      ${seccion('Discord', `
        <div class="form-row"><label for="cf-webhook">Webhook</label>
          <input type="password" id="cf-webhook" autocomplete="off" maxlength="300"
            value="${esc((integ && integ.discord_webhook_url) || '')}"
            placeholder="https://discord.com/api/webhooks/…">
          <div class="hint">Se guarda en cs_integraciones, que solo ve el fundador.
            Dejalo vacío para sacarlo.</div></div>
        <div class="form-row"><label for="cf-discord-activo">Notificaciones</label>
          <select id="cf-discord-activo">
            <option value="0"${integ && integ.discord_activo ? '' : ' selected'}>Desactivadas</option>
            <option value="1"${integ && integ.discord_activo ? ' selected' : ''}>Activadas</option>
          </select></div>
        ${esFundador() ? `<button type="button" class="btn btn-sm" id="cf-probar-discord">Probar</button>
        <span class="hint">Manda un mensaje de prueba al canal. Si hay cambios sin guardar, los guarda antes.</span>` : ''}`,
        '<button type="button" class="btn btn-accent btn-sm" id="cf-guardar-discord">Guardar Discord</button>')}

      ${seccion('Chequeo diario', `
        <div class="hint">Aplica las plantillas que ya vencieron, finaliza los programas vencidos
          y recalcula las alertas. Es lo mismo que corre el cron: se puede correr las veces que
          haga falta, no duplica nada.</div>
        <button type="button" class="btn btn-accent" id="cf-chequeo">Correr chequeo ahora</button>
        <div class="chequeo-res" id="cf-chequeo-res"></div>`)}`;
  }

  function repintarEtapas() {
    const cont = el.querySelector('#cf-etapas');
    if (cont) cont.innerHTML = htmlEtapas(estado.etapas);
  }

  function repintarPlantilla() {
    const cont = el.querySelector('#cf-plantilla');
    if (cont) cont.innerHTML = htmlPlantilla(estado.plantilla);
  }

  /* Antes de mover o borrar, lo que está escrito en pantalla pasa al estado. */
  function sincronizarEtapas() { estado.etapas = leerEtapas(el); }
  function sincronizarPlantilla() { estado.plantilla = leerPlantilla(el); }

  /* ---------- Guardados ---------- */

  const recargar = () => cargar().catch(e => toast(mensajeError(e), 'error'));

  async function guardarAjustes(boton) {
    const cambios = {};
    for (const [campo, label, min, max] of AJUSTES) {
      const inp = el.querySelector(`[data-ajuste="${campo}"]`);
      if (!inp) continue;
      if (inp.value.trim() === '') { toast(`Completá "${label}".`, 'error'); return; }
      const v = Number(inp.value);
      if (isNaN(v) || v < min || v > max) {
        toast(`"${label}" tiene que estar entre ${min} y ${max}.`, 'error');
        return;
      }
      cambios[campo] = campo === 'satisfaccion_umbral_bajo' ? v : Math.round(v);
    }
    await guardar(() => guardarPrograma(programaId, cambios), {
      ok: 'Plazos guardados.', luego: recargar, control: boton
    });
  }

  async function guardarEtapas(boton) {
    sincronizarEtapas();
    if (new Set(estado.etapas).size !== estado.etapas.length) {
      toast('Hay dos etapas con el mismo nombre.', 'error');
      return;
    }
    await guardar(() => guardarPrograma(programaId, { etapas: estado.etapas }), {
      ok: 'Etapas guardadas.', luego: recargar, control: boton
    });
  }

  async function guardarPlantilla(boton) {
    sincronizarPlantilla();
    estado.plantilla = completarKeys(estado.plantilla);
    const error = validarPlantilla(estado.plantilla);
    if (error) {
      /* El CHECK de la base diría lo mismo con menos palabras: se avisa antes. */
      toast(error, 'error');
      repintarPlantilla();
      return;
    }
    await guardar(() => guardarPrograma(programaId, { plantilla_accionables: estado.plantilla }), {
      ok: 'Plantilla guardada.', luego: recargar, control: boton
    });
  }

  /* Lo que está en pantalla, validado. null (con toast) si no se puede guardar. */
  function leerDiscord() {
    const url = el.querySelector('#cf-webhook').value.trim();
    const activo = el.querySelector('#cf-discord-activo').value === '1';
    if (url && !RX_DISCORD.test(url)) {
      toast('El webhook tiene que empezar con https://discord.com/api/webhooks/', 'error');
      return null;
    }
    if (activo && !url) {
      toast('Para activar las notificaciones hace falta el webhook.', 'error');
      return null;
    }
    return { discord_webhook_url: url || null, discord_activo: activo };
  }

  async function guardarDiscord(boton) {
    const cambios = leerDiscord();
    if (!cambios) return;
    await guardar(() => guardarIntegracion(programaId, cambios),
      { ok: 'Integración guardada.', luego: recargar, control: boton });
  }

  async function probarDiscordAhora(boton) {
    const cambios = leerDiscord();
    if (!cambios) return;
    if (!cambios.discord_webhook_url) {
      toast('No hay webhook cargado: pegalo arriba y volvé a probar.', 'error');
      return;
    }
    const sinGuardar = cambios.discord_webhook_url !== ((integ && integ.discord_webhook_url) || null)
      || cambios.discord_activo !== !!(integ && integ.discord_activo);
    boton.disabled = true;
    try {
      if (sinGuardar) {
        await guardarIntegracion(programaId, cambios);
        integ = { ...(integ || {}), programa_id: programaId, ...cambios };
      }
      const r = await probarDiscord(programaId);
      if (!r.enviado) {
        toast('No hay webhook guardado para este programa: pegalo arriba y volvé a probar.', 'error');
      } else if (!cambios.discord_activo) {
        toast('Prueba enviada: revisá el canal. Ojo: las notificaciones están desactivadas, ' +
              'el digest diario no sale hasta que las actives y guardes.', 'error');
      } else {
        toast(`${sinGuardar ? 'Integración guardada. ' : ''}Prueba enviada: revisá el canal de Discord. ` +
              'Si no llega en un minuto, revisá el webhook.');
      }
    } catch (e) {
      toast(mensajeError(e), 'error');
    } finally {
      if (boton.isConnected) boton.disabled = false;
    }
  }

  async function correrChequeo(boton) {
    const salida = el.querySelector('#cf-chequeo-res');
    if (salida) salida.textContent = 'Corriendo…';
    boton.disabled = true;
    try {
      const r = await correrChequeoDiario();
      const linea = [
        `${plural(num(r.alertas_creadas), 'alerta nueva', 'alertas nuevas')}`,
        `${plural(num(r.alertas_resueltas), 'alerta resuelta', 'alertas resueltas')}`,
        `${plural(num(r.accionables_creados), 'accionable creado', 'accionables creados')}`,
        `${plural(num(r.clientes_finalizados), 'cliente finalizado', 'clientes finalizados')}`,
        `${plural(num(r.renovaciones_cerradas), 'renovación cerrada', 'renovaciones cerradas')}`
      ].join(' · ');
      if (salida) salida.textContent = linea;
      toast(`Chequeo listo: ${plural(num(r.alertas_creadas), 'alerta nueva', 'alertas nuevas')}, ` +
            `${plural(num(r.alertas_resueltas), 'resuelta', 'resueltas')}.`);
    } catch (e) {
      if (salida) salida.textContent = '';
      toast(mensajeError(e), 'error');
    } finally {
      if (boton.isConnected) boton.disabled = false;
    }
  }

  /* ---------- Eventos ---------- */

  el.addEventListener('click', async ev => {
    const b = ev.target.closest('button');
    if (!b) return;

    if (b.id === 'cf-guardar-ajustes') return guardarAjustes(b);
    if (b.id === 'cf-guardar-etapas') return guardarEtapas(b);
    if (b.id === 'cf-guardar-plantilla') return guardarPlantilla(b);
    if (b.id === 'cf-guardar-discord') return guardarDiscord(b);
    if (b.id === 'cf-probar-discord') return probarDiscordAhora(b);
    if (b.id === 'cf-chequeo') return correrChequeo(b);

    if (b.id === 'cf-activo') {
      const ok = await confirmar({
        titulo: prog.activo ? 'Desactivar programa' : 'Activar programa',
        texto: prog.activo
          ? `${prog.nombre} queda marcado como inactivo.`
          : `${prog.nombre} vuelve a quedar activo.`,
        detalle: 'No se borra ni se oculta nada: es solo el marcador de programa en uso.',
        ok: prog.activo ? 'Desactivar' : 'Activar',
        peligro: !!prog.activo
      });
      if (!ok) return;
      return guardar(() => guardarPrograma(programaId, { activo: !prog.activo }), {
        ok: 'Estado del programa guardado.', luego: recargar, control: b
      });
    }

    if (b.hasAttribute('data-agregar-etapa')) {
      sincronizarEtapas();
      estado.etapas.push('Nueva etapa');
      repintarEtapas();
      return;
    }
    if (b.hasAttribute('data-borrar-etapa')) {
      sincronizarEtapas();
      estado.etapas.splice(Number(b.dataset.borrarEtapa), 1);
      repintarEtapas();
      return;
    }
    if (b.hasAttribute('data-mover-etapa')) {
      sincronizarEtapas();
      const i = Number(b.dataset.moverEtapa);
      const j = i + Number(b.dataset.dir);
      if (j >= 0 && j < estado.etapas.length) {
        [estado.etapas[i], estado.etapas[j]] = [estado.etapas[j], estado.etapas[i]];
      }
      repintarEtapas();
      return;
    }
    if (b.hasAttribute('data-agregar-pl')) {
      sincronizarPlantilla();
      estado.plantilla.push({ key: '', titulo: '', responsable: 'bpf', dia_offset: 0, vence_en_dias: 3 });
      repintarPlantilla();
      return;
    }
    if (b.hasAttribute('data-borrar-pl')) {
      sincronizarPlantilla();
      estado.plantilla.splice(Number(b.dataset.borrarPl), 1);
      repintarPlantilla();
    }
  });

  async function cargar() {
    const [p, i] = await Promise.all([traerPrograma(programaId), traerIntegracion(programaId)]);
    if (!vigente()) return;
    if (!p) { el.innerHTML = tarjetaError('Programa no encontrado', 'No existe o no tenés acceso.'); return; }
    prog = p;
    integ = i;
    estado.etapas = Array.isArray(p.etapas) ? p.etapas.slice() : [];
    estado.plantilla = Array.isArray(p.plantilla_accionables) ? p.plantilla_accionables.slice() : [];
    pintar();
  }

  cargar().catch(e => {
    if (vigente()) el.innerHTML = tarjetaError('No se pudo cargar la configuración', mensajeError(e));
  });
  /* Sin refresco automático: si alguien está editando la plantilla, un refetch
     le borraría lo escrito. Se recarga solo después de guardar. */
  return null;
}
