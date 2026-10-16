/* tema-init — pone <html data-theme="light|dark"> antes de pintar (sin parpadeo).
   ESTE ARCHIVO ES IDÉNTICO EN LAS 4 APPS. Va en el <head>, como script común
   (no módulo), ANTES de las hojas de estilo. Orden: lo guardado por la persona
   (localStorage 'dystopia_tema') y, si no hay nada, el tema del sistema. */
(function () {
  var tema = null;
  try { tema = localStorage.getItem('dystopia_tema'); } catch (e) { /* storage bloqueado */ }
  var mq = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  if (tema !== 'light' && tema !== 'dark') tema = mq && mq.matches ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', tema);
  /* Sin preferencia guardada, acompaña los cambios del sistema. */
  if (mq && mq.addEventListener) {
    mq.addEventListener('change', function (ev) {
      var guardado = null;
      try { guardado = localStorage.getItem('dystopia_tema'); } catch (e) { /* nada */ }
      if (guardado !== 'light' && guardado !== 'dark') {
        document.documentElement.setAttribute('data-theme', ev.matches ? 'dark' : 'light');
      }
    });
  }
})();
