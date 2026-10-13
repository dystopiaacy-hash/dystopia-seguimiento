/* Configuración — avisos de Discord por tipo (106): un webhook por programa y por tipo de aviso.
     satisfaccion  respuestas menores a 7, y 9 o 10 con "daría testimonio: sí"
     wins          cada win cargado (sin monto salvo que se habilite acá)
   Se guardan en cs_discord_canales (solo fundador, igual que cs_integraciones). Sin webhook
   cargado, o con el canal desactivado, la base no envía nada y no rompe. Los canales de Discord
   y sus webhooks los crea el jefe. Sin la 106 el bloque avisa que falta la migración. */
import { esc, toast } from '../ui.js';
import { sb } from '../supabase.js';
import { esFundador } from '../sesion.js';
import { faltaObjeto, mensajeCs } from '../datos-faltante.js';

const RX_DISCORD = /^https:\/\/((canary|ptb)\.)?(discord|discordapp)\.com\/api\/webhooks\//;

const TIPOS = [
  ['satisfaccion', 'Satisfacción',
    'Avisa cuando entra una respuesta menor a 7 (alumno, momento, puntaje y qué mejoraría) y cuando entra un 9 o 10 que daría testimonio.'],
  ['wins', 'Wins',
    'Avisa cada win cargado (alumno, programa y texto). El pendiente "Pedir referido" aparece en Hoy.']
];

export const htmlCanales = () => `
  <div class="conf-seccion">
    <div class="section-title">Avisos por tipo (Discord)<span class="line"></span></div>
    <div class="card" id="cf-canales"><div class="loading-inline">Cargando…</div></div>
  </div>`;

function filaCanal([tipo, titulo, ayuda], c) {
  const v = c || {};
  return `<div class="canal-fila" data-canal="${esc(tipo)}">
      <div class="canal-tit">${esc(titulo)}</div>
      <div class="hint">${esc(ayuda)}</div>
      <div class="form-row"><label for="cn-url-${esc(tipo)}">Webhook</label>
        <input type="password" id="cn-url-${esc(tipo)}" autocomplete="off" maxlength="300"
          value="${esc(v.webhook_url || '')}" placeholder="https://discord.com/api/webhooks/…"></div>
      <div class="canal-opciones">
        <label class="check-row"><input type="checkbox" data-cn="activo"${v.activo ? ' checked' : ''}> Activado</label>
        <label class="check-row"><input type="checkbox" data-cn="nombre"${v.incluir_nombre === false ? '' : ' checked'}> Incluir el nombre del alumno</label>
        ${tipo === 'wins' ? `<label class="check-row"><input type="checkbox" data-cn="monto"${v.incluir_monto ? ' checked' : ''}> Incluir el monto del win</label>` : ''}
      </div>
      <div>
        <button type="button" class="btn btn-accent btn-sm" data-cn-guardar="${esc(tipo)}">Guardar</button>
        <button type="button" class="btn btn-sm" data-cn-probar="${esc(tipo)}">Probar</button>
      </div>
    </div>`;
}

export async function montarCanales(box, programaId, vigente) {
  if (!box) return;
  if (!esFundador()) { box.innerHTML = '<div class="hint">Solo el fundador configura los avisos.</div>'; return; }
  const { data, error } = await sb.from('cs_discord_canales').select('*').eq('programa_id', programaId);
  if (!vigente() || !box.isConnected) return;
  if (error) {
    box.innerHTML = `<div class="hint">${faltaObjeto(error)
      ? 'Falta correr la migración 106 para configurar estos avisos.' : esc(mensajeCs(error))}</div>`;
    return;
  }
  const por = new Map((data || []).map(r => [r.tipo, r]));
  box.innerHTML = TIPOS.map(t => filaCanal(t, por.get(t[0]))).join('');

  box.addEventListener('click', async ev => {
    const g = ev.target.closest('[data-cn-guardar]');
    const p = ev.target.closest('[data-cn-probar]');
    const b = g || p;
    if (!b) return;
    const tipo = g ? g.dataset.cnGuardar : p.dataset.cnProbar;
    const fila = box.querySelector(`[data-canal="${tipo}"]`);
    const url = fila.querySelector('input[type=password]').value.trim();
    const marca = k => { const i = fila.querySelector(`[data-cn="${k}"]`); return i ? i.checked : false; };
    if (url && !RX_DISCORD.test(url)) {
      toast('El webhook tiene que empezar con https://discord.com/api/webhooks/', 'error');
      return;
    }
    b.disabled = true;
    try {
      if (p) {
        const guardado = por.get(tipo);
        if (!url || !guardado || guardado.webhook_url !== url) {
          toast('Guardá el webhook antes de probarlo.', 'error');
          return;
        }
        const { error: e } = await sb.rpc('cs_probar_discord_canal', { p_programa: programaId, p_tipo: tipo });
        if (e) throw e;
        toast('Mensaje de prueba enviado. Si no llega en un minuto, revisá el webhook.');
        return;
      }
      if (marca('activo') && !url) {
        toast('Para activar el aviso hace falta el webhook.', 'error');
        return;
      }
      const fila106 = {
        programa_id: programaId, tipo, webhook_url: url || null, activo: marca('activo'),
        incluir_nombre: marca('nombre'), incluir_monto: tipo === 'wins' ? marca('monto') : false
      };
      const { error: e } = await sb.from('cs_discord_canales').upsert(fila106, { onConflict: 'programa_id,tipo' });
      if (e) throw e;
      por.set(tipo, fila106);
      toast('Aviso guardado.');
    } catch (e) {
      toast(mensajeCs(e), 'error');
    } finally {
      if (b.isConnected) b.disabled = false;
    }
  });
}
