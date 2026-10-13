/* Menú entre apps Dystopia. Idéntico en los 4 repos. Roles por área definidos por el jefe el 2026-10-12.

   Lo único que cambia por repo es la constante AREA_ACTUAL, declarada FUERA
   de este archivo y antes de cargarlo:
     <script>const AREA_ACTUAL = 'ventas';</script>
     <script src="/js/nav-areas.js"></script>

   Script clásico (no módulo) para que funcione igual en repos con y sin
   módulos ES. Expone window.montarNavAreas(contenedor, rol).

   Ocultar áreas según el rol es COSMÉTICO. La protección real es la RLS
   y el chequeo de acceso de cada app. */
(function () {
  'use strict';

  /* Orden fijo: Marketing | Ventas | Producto | Finanzas. */
  var AREAS = [
    { id: 'marketing', label: 'Marketing', url: 'https://mkt.dystopia.com.ar',         roles: ['fundador', 'cliente', 'editor', 'contenido'] },
    { id: 'ventas',    label: 'Ventas',    url: 'https://ventas.dystopia.com.ar',      roles: ['fundador', 'cliente', 'closer', 'setter', 'ventas', 'finanzas'] },
    { id: 'producto',  label: 'Producto',  url: 'https://producto.dystopia.com.ar', roles: ['fundador', 'cliente', 'producto'] },
    { id: 'finanzas',  label: 'Finanzas',  url: 'https://finanzas.dystopia.com.ar',    roles: ['fundador', 'cliente', 'closer', 'setter', 'finanzas', 'ventas'] }
  ];

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* Pinta la barra dentro de `contenedor` (reemplaza su contenido).
     rol: 'fundador' | 'cliente' | 'editor' | null. Con rol desconocido
     solo se muestra el área actual. */
  function montarNavAreas(contenedor, rol) {
    if (!contenedor) return;
    var actual = typeof AREA_ACTUAL !== 'undefined' ? AREA_ACTUAL : null;
    if (!AREAS.some(function (a) { return a.id === actual; })) {
      console.warn('nav-areas: AREA_ACTUAL no definida o inválida:', actual);
    }
    var items = AREAS.filter(function (a) {
      return a.id === actual || a.roles.indexOf(rol) !== -1;
    }).map(function (a) {
      if (a.id === actual) {
        return '<span class="nav-area activa" aria-current="page">' + esc(a.label) + '</span>';
      }
      return '<a class="nav-area" href="' + esc(a.url) + '">' + esc(a.label) + '</a>';
    });
    contenedor.classList.add('nav-areas');
    contenedor.setAttribute('aria-label', 'Áreas');
    contenedor.innerHTML = items.join('');
  }

  window.montarNavAreas = montarNavAreas;
})();
