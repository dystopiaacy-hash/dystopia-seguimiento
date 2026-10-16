/* tema — botón para cambiar entre tema claro y oscuro.
   ESTE ARCHIVO ES IDÉNTICO EN LAS 4 APPS. Se recuerda en localStorage
   ('dystopia_tema'); el estado inicial lo pone js/tema-init.js. */
const CLAVE = 'dystopia_tema';

export function temaActual() {
  return document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light';
}

function textoBoton(tema) {
  return tema === 'dark' ? 'Cambiar a tema claro' : 'Cambiar a tema oscuro';
}

export function aplicarTema(tema) {
  document.documentElement.setAttribute('data-theme', tema);
  try { localStorage.setItem(CLAVE, tema); } catch (e) { /* sin storage: vale solo esta sesión */ }
  document.querySelectorAll('.tema-btn').forEach(b => {
    b.title = textoBoton(tema);
    b.setAttribute('aria-label', b.title);
  });
}

const SOL = '<svg class="tema-sol" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
const LUNA = '<svg class="tema-luna" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>';

/* HTML del botón, para pegarlo en cualquier plantilla; después llamar a activarBotonTema(). */
export function botonTemaHtml() {
  const t = textoBoton(temaActual());
  return `<button type="button" class="tema-btn" id="btn-tema" title="${t}" aria-label="${t}">${SOL}${LUNA}</button>`;
}

export function activarBotonTema() {
  const b = document.getElementById('btn-tema');
  if (b) b.onclick = () => aplicarTema(temaActual() === 'dark' ? 'light' : 'dark');
}
