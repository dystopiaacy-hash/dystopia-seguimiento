/* Página pública de formularios (se implementa en Fase 5).
   Todo lo que entra acá es input de extraños: validar, limitar largo y escapar siempre con esc(). */

const root = document.getElementById('form-root');
const token = new URLSearchParams(location.search).get('f');

root.innerHTML = `
  <div class="empty-state">
    <div class="big">Formulario no disponible</div>
    <div class="small">${token ? 'Este formulario todavía no está habilitado.' : 'Falta el identificador del formulario.'}</div>
  </div>`;
