-- =====================================================================
-- 093-producto-onboarding-link.sql  ·  PRODUCTO, fase 6 (onboarding por link)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas: este número lo
-- asignó el jefe. Los controles van en 093b-producto-onboarding-control.sql
-- (consultas sueltas, de a una).
-- Evitar los minutos :00, :15, :30 y :45 (sync de Finanzas) y las 9:00.
--
-- Requiere: 039 (cs_productos, cs_clientes.producto_id), 070 (cs_norm_nombre,
-- cs_norm_tel), 071 (campos_extra, cs_maestro_columnas), 079 (cs_puede_editar)
-- y crm_members / crm_asignaciones (CRM).
--
-- Qué hace
--   El alumno recibe UN link a una landing pública con pasos en orden
--   (video, formularios, accesos). Formularios y accesos son obligatorios; el
--   video es OPCIONAL por ahora: es un dato del paso ("obligatorio": false) y
--   se activa cambiando solo ese dato. Todo el contenido de cada onboarding
--   (títulos, textos, links, preguntas) es un DATO de la base.
--
--   1. Tablas nuevas (sin tocar ninguna existente):
--        cs_onboarding_plantillas          pasos de cada onboarding (jsonb validado)
--        cs_onboarding_plantilla_productos qué producto usa qué plantilla
--        cs_onboardings                    uno por alumno: token, avance, diferencias
--        cs_onboarding_respuestas          respuestas por paso (datos sensibles)
--      Por qué no se reutiliza cs_formularios/cs_respuestas (004): su validador
--      (cs_validar_campos) no tiene casillas ni escala 1 a 10 ni secciones, y la
--      definición del formulario tendría que vivir en dos lugares. Sí se
--      reutiliza: cs_clientes, cs_productos, campos_extra / cs_maestro_columnas
--      (las casillas del Maestro, incl. x_unio_school de la 079), cs_norm_*
--      de la 070 y el accionable de plantilla 'formulario_onboarding' (como 004).
--
--   2. RPC PÚBLICAS (anon), todas por token de 64 hex y security definer:
--        cs_ob_estado, cs_ob_latido, cs_ob_avanzar, cs_ob_confirmar
--      Devuelven SOLO la configuración y el avance de ese token. anon no tiene
--      ningún permiso sobre ninguna tabla.
--
--   3. RPC internas de la app (authenticated):
--        cs_onboarding_link          crea o muestra el link (cs_puede_editar)
--        cs_onboarding_link_closer   lo mismo para un closer (rol ventas o closer)
--                                    con el cliente asignado en crm_asignaciones;
--                                    busca al alumno por teléfono, no lo crea
--        cs_onboarding_ficha         avance + respuestas de un alumno (cs_puede_ver)
--        cs_onboarding_diferencia_resolver  la CSM decide qué dato de contacto vale
--        cs_onboarding_avance        "3 de 6" por alumno, para el Maestro
--        cs_onboarding_hoy           completaron / demorados, para Hoy
--
--   4. Carga de datos de Liam: dos plantillas ('1a1' y 'grupal') con los
--      textos, links y preguntas reales, asignadas por NOMBRE EXACTO de
--      producto. Los productos que no coincidan quedan sin asignar (no se
--      inventa ni se renombra nada): ver el control 02 de la 093b.
--
--   5. Maestro de liam: 4 casillas nuevas de onboarding (x_ob_*) y la
--      columna calculada 'onb_avance'. Se usa x_unio_school (079) para Skool.
--
-- Seguridad: tokens de 244 bits generados con gen_random_uuid() (CSPRNG),
-- vencimiento configurable (30 días por defecto), tope de 20 KB por paso, tope
-- de escrituras por link, formularios y link completado de solo lectura.
-- El token NO es legible por ningún usuario de la app (permiso por columna):
-- solo sale por cs_onboarding_link / cs_onboarding_link_closer.
-- Privacidad del link: el closer recibe el token (lo necesita para mandarlo), así
-- que la protección está en el estado público (cs_ob_armar_estado): un formulario
-- ya enviado no vuelve nunca por esa vía. Solo vuelve el borrador del que el
-- alumno está llenando. RIESGO ACEPTADO: quien tiene el link ve ese borrador
-- mientras el alumno lo llena. Las respuestas enviadas solo las lee quien tiene
-- cs_puede_ver (ficha).
-- El tope de 400 escrituras por link se reinicia al pedir el link desde la ficha
-- (cs_onboarding_link, fundador o producto); el avance se conserva.
--
-- Re-ejecutable: tablas con if not exists, funciones con create or replace,
-- seeds con on conflict. Volver a correrla restaura las dos plantillas de
-- Liam al texto de ESTE archivo (pisa ediciones hechas a mano de esas dos).
-- No usa format() ni arrays sin cast.
--
-- Si falla: el mensaje empieza con "cs 093:" (autochequeo y carga de las
-- plantillas, con paso y regla). Nada queda aplicado: es una sola transacción.
-- Para saber qué hay aplicado después de una corrida: consulta Q00 de la 093b.
-- Error del closer cuando el alumno no está en Producto: SQLSTATE P0002, message
-- 'ALUMNO_SIN_ALTA: ...' y hint 'ALUMNO_SIN_ALTA'. Si el alumno existe pero está
-- finalizado o dado de baja: P0002 con 'ALUMNO_INACTIVO: ...' y hint 'ALUMNO_INACTIVO'.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- 0. AUTOCHEQUEO (no depende de ninguna tabla nueva)
-- ---------------------------------------------------------------------
-- Los cuerpos PL/pgSQL no se verifican al crearse: si una tabla, columna o
-- función que usan no existe, el error saltaría recién al usarlos. Acá se
-- comprueba TODO lo que la 093 lee o escribe, y se corta con un mensaje claro
-- antes de crear nada.
do $chk$
declare
  v_falta text;
begin
  if current_setting('server_version_num')::int < 130000 then
    raise exception 'cs 093: hace falta Postgres 13 o más (gen_random_uuid). Versión: %', current_setting('server_version');
  end if;

  select string_agg(r.t, ', ' order by r.t) into v_falta
    from (values ('cs_programas'), ('cs_productos'), ('cs_clientes'), ('cs_accionables'),
                 ('cs_maestro_columnas'), ('cs_accesos'), ('crm_members'), ('crm_asignaciones')) as r(t)
   where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 093: faltan tablas: %. Tienen que estar corridas 001, 037, 039, 071 y 079, y existir crm_members y crm_asignaciones (CRM).', v_falta;
  end if;

  select string_agg(r.t || '.' || r.c, ', ' order by r.t, r.c) into v_falta
    from (values
      ('cs_programas', 'id'), ('cs_programas', 'nombre'), ('cs_programas', 'marca'),
      ('cs_productos', 'id'), ('cs_productos', 'programa_id'), ('cs_productos', 'nombre'),
      ('cs_productos', 'duracion_dias'), ('cs_productos', 'activo'), ('cs_productos', 'orden'),
      ('cs_clientes', 'id'), ('cs_clientes', 'programa_id'), ('cs_clientes', 'nombre'),
      ('cs_clientes', 'email'), ('cs_clientes', 'telefono'), ('cs_clientes', 'estado'),
      ('cs_clientes', 'producto_id'), ('cs_clientes', 'campos_extra'),
      ('cs_accionables', 'cliente_id'), ('cs_accionables', 'plantilla_key'), ('cs_accionables', 'estado'),
      ('cs_maestro_columnas', 'programa_id'), ('cs_maestro_columnas', 'clave'),
      ('cs_maestro_columnas', 'sistema'), ('cs_maestro_columnas', 'etiqueta'),
      ('cs_maestro_columnas', 'orden'), ('cs_maestro_columnas', 'tipo'),
      ('crm_members', 'user_id'), ('crm_members', 'rol'),
      ('crm_asignaciones', 'user_id'), ('crm_asignaciones', 'cliente_id')
    ) as r(t, c)
   where not exists (select 1 from information_schema.columns k
                      where k.table_schema = 'public' and k.table_name = r.t and k.column_name = r.c);
  if v_falta is not null then
    raise exception 'cs 093: faltan columnas: %.', v_falta;
  end if;

  select string_agg(f, ', ' order by f) into v_falta
    from unnest(array['public.cs_puede_ver(text)', 'public.cs_puede_editar(text)',
                      'public.cs_norm_tel(text)', 'public.cs_norm_nombre(text)',
                      'public.cs_hoy()', 'auth.uid()']) as f
   where to_regprocedure(f) is null;
  if v_falta is not null then
    raise exception 'cs 093: faltan funciones: %. (cs_puede_editar es de la 079; cs_norm_* de la 070.)', v_falta;
  end if;

  -- Destinos de las FK compuestas y del on conflict (índices únicos exactos).
  select string_agg(r.t || '(' || r.cols || ')', ', ') into v_falta
    from (values ('cs_clientes', 'id,programa_id'), ('cs_productos', 'id,programa_id'),
                 ('cs_maestro_columnas', 'clave,programa_id')) as r(t, cols)
   where not exists (
           select 1 from pg_index i
            where i.indrelid = to_regclass('public.' || r.t) and i.indisunique and i.indpred is null
              and (select string_agg(a.attname::text, ',' order by a.attname::text)
                     from pg_attribute a
                    where a.attrelid = i.indrelid and a.attnum = any (i.indkey)) = r.cols);
  if v_falta is not null then
    raise exception 'cs 093: falta el índice único en: %.', v_falta;
  end if;

  if not exists (select 1 from public.cs_programas where id = 'liam') then
    raise notice 'cs 093: no existe el programa liam: se crea todo pero no se carga ninguna plantilla.';
  end if;
end
$chk$;

-- Las FK de las tablas nuevas toman SHARE ROW EXCLUSIVE sobre estas tres. Se
-- piden juntas y primero para no cruzarse con el cron ni con la app (ya hubo
-- un deadlock por no hacerlo). Si no consigue el lock en 8 s, aborta limpio.
lock table public.cs_programas, public.cs_productos, public.cs_clientes
  in share row exclusive mode;


-- =====================================================================
-- 1. VALIDADOR DE PASOS
-- =====================================================================
-- Un paso = { key, tipo, titulo, texto?, tiempo?, casilla?, ... } según tipo:
--   obligatorio (todos, opcional, por defecto true): false solo en video y texto.
--               Un paso no obligatorio se muestra en su lugar pero no bloquea: no
--               cuenta en "3 de 4" ni en el estado completo. Todo onboarding
--               necesita al menos un paso obligatorio.
--   video       url (loom.com/share/<32 hex>), duracion_seg?, minimo_seg?, boton?
--               Si es obligatorio hace falta duracion_seg o minimo_seg (de ahí
--               sale el tiempo que se exige). Si es opcional, el tiempo se guarda
--               igual y "visto" es haber llegado a ese tiempo (sin duración
--               conocida solo se guardan los segundos).
--   formulario  secciones: [{ titulo?, campos: [{ key, label, tipo, requerido?,
--               opciones?, ayuda?, extremos?, contacto? }] }]
--               tipos de campo: texto, parrafo, opcion, casillas, escala_1_10
--               contacto: nombre | apellido | email | telefono
--   acceso      enlaces: [{ key, label, url, boton?, confirmar?, casilla? }]
--   texto       solo título y texto (se marca como leído)
--   final       pantalla de cierre (tiene que ser el último, no cuenta en el avance)
-- casilla = clave de columna del Maestro (x_...) que se marca al completar.
-- Devuelve NULL si los pasos son válidos, o el motivo (qué paso y qué regla
-- falló). La carga de datos de abajo la usa para decir POR QUÉ falla; el CHECK
-- de la tabla usa la versión booleana de más abajo.
-- Ojo: en las regex de PostgreSQL un cuantificador {m,n} no puede pasar de 255:
-- los largos grandes se validan con char_length(), no con la regex.
create or replace function public.cs_validar_onboarding_pasos_motivo(p jsonb)
returns text
language plpgsql immutable set search_path = public
as $fn$
declare
  e        jsonb;
  s        jsonb;
  c        jsonb;
  en       jsonb;
  o        jsonb;
  v_keys   text[] := '{}'::text[];
  v_ckeys  text[];
  v_tipo   text;
  v_ctipo  text;
  v_final  boolean := false;
  v_obl    int := 0;
  v_obl_paso boolean;
  v_i      int := 0;
  v_pn     text;
  v_cn     text;
begin
  if jsonb_typeof(p) is distinct from 'array' then
    return 'los pasos tienen que ser una lista (array JSON)';
  end if;
  if jsonb_array_length(p) = 0 or jsonb_array_length(p) > 30 then
    return 'tiene que haber entre 1 y 30 pasos';
  end if;

  for e in select value from jsonb_array_elements(p) loop
    v_i := v_i + 1;
    if jsonb_typeof(e) <> 'object' then return 'paso ' || v_i || ': tiene que ser un objeto'; end if;
    v_pn := 'paso ' || v_i || ' (' || coalesce(e->>'key', 'sin key') || ')';
    if v_final then return v_pn || ': hay un paso después del paso final'; end if;
    if coalesce(e->>'key', '') !~ '^[a-z][a-z0-9_]{0,39}$' then
      return v_pn || ': key inválida (a-z, 0-9 y _, empieza con letra, hasta 40)';
    end if;
    if (e->>'key') = any (v_keys) then return v_pn || ': key repetida'; end if;
    v_keys := v_keys || (e->>'key');
    if coalesce(btrim(e->>'titulo'), '') = '' or char_length(e->>'titulo') > 200 then
      return v_pn || ': titulo vacío o de más de 200 caracteres';
    end if;
    if char_length(coalesce(e->>'texto', '')) > 3000 then return v_pn || ': texto de más de 3000 caracteres'; end if;
    if char_length(coalesce(e->>'tiempo', '')) > 40 then return v_pn || ': tiempo de más de 40 caracteres'; end if;
    if coalesce(e->>'casilla', '') <> '' and (e->>'casilla') !~ '^x_[a-z0-9_]{1,60}$' then
      return v_pn || ': casilla inválida (' || (e->>'casilla') || '), tiene que ser x_ y minúsculas';
    end if;

    v_tipo := e->>'tipo';
    if v_tipo is null or v_tipo not in ('video', 'formulario', 'acceso', 'texto', 'final') then
      return v_pn || ': tipo inválido (' || coalesce(v_tipo, 'null') || ')';
    end if;

    if e->'obligatorio' is not null and jsonb_typeof(e->'obligatorio') not in ('boolean', 'null') then
      return v_pn || ': obligatorio tiene que ser true o false';
    end if;
    v_obl_paso := coalesce(e->>'obligatorio', 'true') <> 'false';
    if not v_obl_paso and v_tipo not in ('video', 'texto') then
      return v_pn || ': solo un video o un texto puede ser no obligatorio (tipo ' || v_tipo || ')';
    end if;

    if v_tipo = 'final' then
      v_final := true;
    elsif v_obl_paso then
      v_obl := v_obl + 1;
    end if;

    if v_tipo = 'video' then
      if coalesce(e->>'url', '') !~ '^https://(www\.)?loom\.com/share/[0-9a-f]{32}([/?#][^\s]*)?$' then
        return v_pn || ': url de video inválida (tiene que ser https://www.loom.com/share/<32 hex>): ' || coalesce(e->>'url', 'null');
      end if;
      -- Un video obligatorio tiene que decir cuánto dura (o el mínimo a exigir).
      if v_obl_paso and (e->>'duracion_seg') is null and (e->>'minimo_seg') is null then
        return v_pn || ': un video obligatorio necesita duracion_seg o minimo_seg';
      end if;
      if e->'duracion_seg' is not null and jsonb_typeof(e->'duracion_seg') <> 'null'
         and not (jsonb_typeof(e->'duracion_seg') = 'number' and (e->>'duracion_seg') ~ '^[1-9][0-9]{0,3}$') then
        return v_pn || ': duracion_seg tiene que ser un entero de 1 a 9999';
      end if;
      if e->'minimo_seg' is not null and jsonb_typeof(e->'minimo_seg') <> 'null'
         and not (jsonb_typeof(e->'minimo_seg') = 'number' and (e->>'minimo_seg') ~ '^[1-9][0-9]{0,3}$') then
        return v_pn || ': minimo_seg tiene que ser un entero de 1 a 9999';
      end if;

    elsif v_tipo = 'formulario' then
      if jsonb_typeof(e->'secciones') is distinct from 'array' then
        return v_pn || ': secciones tiene que ser una lista';
      end if;
      if jsonb_array_length(e->'secciones') = 0 or jsonb_array_length(e->'secciones') > 10 then
        return v_pn || ': tiene que haber entre 1 y 10 secciones';
      end if;
      v_ckeys := '{}'::text[];
      for s in select value from jsonb_array_elements(e->'secciones') loop
        if jsonb_typeof(s) <> 'object' then return v_pn || ': una sección no es un objeto'; end if;
        if char_length(coalesce(s->>'titulo', '')) > 200 or char_length(coalesce(s->>'texto', '')) > 3000 then
          return v_pn || ': sección con titulo (200) o texto (3000) demasiado largo';
        end if;
        if jsonb_typeof(s->'campos') is distinct from 'array' then
          return v_pn || ': una sección no tiene la lista campos';
        end if;
        if jsonb_array_length(s->'campos') = 0 or jsonb_array_length(s->'campos') > 40 then
          return v_pn || ': cada sección necesita entre 1 y 40 campos';
        end if;
        for c in select value from jsonb_array_elements(s->'campos') loop
          if jsonb_typeof(c) <> 'object' then return v_pn || ': un campo no es un objeto'; end if;
          v_cn := v_pn || ', campo ' || coalesce(c->>'key', 'sin key');
          if coalesce(c->>'key', '') !~ '^[a-z][a-z0-9_]{0,39}$' then
            return v_cn || ': key inválida (a-z, 0-9 y _, empieza con letra, hasta 40)';
          end if;
          if (c->>'key') = any (v_ckeys) then return v_cn || ': key repetida dentro del formulario'; end if;
          v_ckeys := v_ckeys || (c->>'key');
          if coalesce(btrim(c->>'label'), '') = '' or char_length(c->>'label') > 400 then
            return v_cn || ': label vacío o de más de 400 caracteres';
          end if;
          if char_length(coalesce(c->>'ayuda', '')) > 600 then return v_cn || ': ayuda de más de 600 caracteres'; end if;
          if c->'requerido' is not null and jsonb_typeof(c->'requerido') not in ('boolean', 'null') then
            return v_cn || ': requerido tiene que ser true o false';
          end if;
          if coalesce(c->>'contacto', '') <> '' and (c->>'contacto') not in ('nombre', 'apellido', 'email', 'telefono') then
            return v_cn || ': contacto inválido (' || (c->>'contacto') || ')';
          end if;
          v_ctipo := c->>'tipo';
          if v_ctipo is null or v_ctipo not in ('texto', 'parrafo', 'opcion', 'casillas', 'escala_1_10') then
            return v_cn || ': tipo de campo inválido (' || coalesce(v_ctipo, 'null') || ')';
          end if;
          if v_ctipo in ('opcion', 'casillas') then
            if jsonb_typeof(c->'opciones') is distinct from 'array' then
              return v_cn || ': opciones tiene que ser una lista';
            end if;
            if jsonb_array_length(c->'opciones') = 0 or jsonb_array_length(c->'opciones') > 20 then
              return v_cn || ': tiene que haber entre 1 y 20 opciones';
            end if;
            for o in select value from jsonb_array_elements(c->'opciones') loop
              if jsonb_typeof(o) <> 'string' or btrim(o #>> '{}') = '' or char_length(o #>> '{}') > 200 then
                return v_cn || ': una opción no es texto, está vacía o pasa los 200 caracteres';
              end if;
            end loop;
            if (select count(distinct x) from jsonb_array_elements_text(c->'opciones') x)
               <> jsonb_array_length(c->'opciones') then
              return v_cn || ': opciones repetidas';
            end if;
          end if;
        end loop;
      end loop;

    elsif v_tipo = 'acceso' then
      if jsonb_typeof(e->'enlaces') is distinct from 'array' then
        return v_pn || ': enlaces tiene que ser una lista';
      end if;
      if jsonb_array_length(e->'enlaces') = 0 or jsonb_array_length(e->'enlaces') > 10 then
        return v_pn || ': tiene que haber entre 1 y 10 enlaces';
      end if;
      v_ckeys := '{}'::text[];
      for en in select value from jsonb_array_elements(e->'enlaces') loop
        if jsonb_typeof(en) <> 'object' then return v_pn || ': un enlace no es un objeto'; end if;
        v_cn := v_pn || ', enlace ' || coalesce(en->>'key', 'sin key');
        if coalesce(en->>'key', '') !~ '^[a-z][a-z0-9_]{0,39}$' then
          return v_cn || ': key inválida (a-z, 0-9 y _, empieza con letra, hasta 40)';
        end if;
        if (en->>'key') = any (v_ckeys) then return v_cn || ': key repetida'; end if;
        v_ckeys := v_ckeys || (en->>'key');
        if coalesce(btrim(en->>'label'), '') = '' or char_length(en->>'label') > 300 then
          return v_cn || ': label vacío o de más de 300 caracteres';
        end if;
        -- El largo va con char_length: {4,500} en la regex falla (máximo 255).
        if coalesce(en->>'url', '') !~ '^https://[^\s]+$'
           or char_length(en->>'url') not between 12 and 500 then
          return v_cn || ': url inválida (https://, sin espacios, de 12 a 500 caracteres): ' || coalesce(en->>'url', 'null');
        end if;
        if coalesce(en->>'casilla', '') <> '' and (en->>'casilla') !~ '^x_[a-z0-9_]{1,60}$' then
          return v_cn || ': casilla inválida (' || (en->>'casilla') || ')';
        end if;
      end loop;
    end if;
  end loop;

  if v_obl < 1 then return 'tiene que haber al menos un paso obligatorio'; end if;
  return null;
end;
$fn$;

-- Versión booleana: la que usa el CHECK de cs_onboarding_plantillas.
create or replace function public.cs_validar_onboarding_pasos(p jsonb)
returns boolean
language sql immutable set search_path = public
as $$
  select public.cs_validar_onboarding_pasos_motivo(p) is null
$$;


-- =====================================================================
-- 2. TABLAS
-- =====================================================================
create table if not exists public.cs_onboarding_plantillas (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id) on delete cascade,
  clave        text not null check (clave ~ '^[a-z0-9_]{1,40}$'),
  nombre       text not null check (btrim(nombre) <> ''),
  mentor       text check (mentor is null or char_length(mentor) <= 120),
  validez_dias int  not null default 30 check (validez_dias between 1 and 365),
  pasos        jsonb not null check (public.cs_validar_onboarding_pasos(pasos)),
  activa       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint cs_onboarding_plantillas_clave_key unique (programa_id, clave),
  constraint cs_onboarding_plantillas_id_programa_key unique (id, programa_id)
);
comment on table public.cs_onboarding_plantillas is
  'Onboarding por link (093): una plantilla = lista ordenada de pasos como datos. Se carga por SQL; para otro cliente (agus, teo) alcanza con insertar filas.';

create table if not exists public.cs_onboarding_plantilla_productos (
  producto_id  uuid primary key,
  programa_id  text not null,
  plantilla_id uuid not null,
  created_at   timestamptz not null default now(),
  constraint cs_onb_pp_producto_fk foreign key (producto_id, programa_id)
    references public.cs_productos (id, programa_id) on delete cascade,
  constraint cs_onb_pp_plantilla_fk foreign key (plantilla_id, programa_id)
    references public.cs_onboarding_plantillas (id, programa_id) on delete cascade
);
comment on table public.cs_onboarding_plantilla_productos is
  'Qué plantilla de onboarding usa cada producto (093). Un producto sin fila no puede generar link.';

create table if not exists public.cs_onboardings (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null,
  programa_id   text not null,
  plantilla_id  uuid not null,
  token         text not null unique
                check (token ~ '^[0-9a-f]{64}$')
                default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'en_curso', 'completado')),
  progreso      jsonb not null default '{}'::jsonb
                check (jsonb_typeof(progreso) = 'object' and octet_length(progreso::text) <= 20000),
  diferencias   jsonb not null default '{}'::jsonb
                check (jsonb_typeof(diferencias) = 'object' and octet_length(diferencias::text) <= 5000),
  vence_at      timestamptz not null,
  abierto_at    timestamptz,
  iniciado_at   timestamptz,
  completado_at timestamptz,
  escrituras    int not null default 0,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint cs_onboardings_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  constraint cs_onboardings_plantilla_fk foreign key (plantilla_id, programa_id)
    references public.cs_onboarding_plantillas (id, programa_id)
);
create unique index if not exists cs_onboardings_cliente_key on public.cs_onboardings (cliente_id);
create index if not exists cs_onboardings_programa_estado_idx on public.cs_onboardings (programa_id, estado);
comment on table public.cs_onboardings is
  'Un onboarding por alumno (093). token = link público; NO es legible por la app (permiso por columna). Se opera por RPC.';

create table if not exists public.cs_onboarding_respuestas (
  onboarding_id uuid not null references public.cs_onboardings(id) on delete cascade,
  programa_id   text not null,
  cliente_id    uuid not null,
  paso_key      text not null,
  respuestas    jsonb not null check (jsonb_typeof(respuestas) = 'object' and octet_length(respuestas::text) <= 20000),
  completo      boolean not null default false,
  updated_at    timestamptz not null default now(),
  primary key (onboarding_id, paso_key)
);
create index if not exists cs_onboarding_respuestas_cliente_idx on public.cs_onboarding_respuestas (cliente_id);
comment on table public.cs_onboarding_respuestas is
  'Respuestas del alumno por paso (093). Datos sensibles (diagnóstico financiero): solo leen fundador, producto y cliente del programa (cs_puede_ver). Ninguna vista las expone.';

-- Permisos: nada para anon; la app solo lee, y de cs_onboardings sin token.
alter table public.cs_onboarding_plantillas          enable row level security;
alter table public.cs_onboarding_plantilla_productos enable row level security;
alter table public.cs_onboardings                    enable row level security;
alter table public.cs_onboarding_respuestas          enable row level security;

revoke all on table public.cs_onboarding_plantillas          from public, anon, authenticated;
revoke all on table public.cs_onboarding_plantilla_productos from public, anon, authenticated;
revoke all on table public.cs_onboardings                    from public, anon, authenticated;
revoke all on table public.cs_onboarding_respuestas          from public, anon, authenticated;

grant select on table public.cs_onboarding_plantillas          to authenticated;
grant select on table public.cs_onboarding_plantilla_productos to authenticated;
grant select on table public.cs_onboarding_respuestas          to authenticated;
-- cs_onboardings: sin token, sin escrituras, sin created_by
grant select (id, cliente_id, programa_id, plantilla_id, estado, progreso, diferencias,
              vence_at, abierto_at, iniciado_at, completado_at, created_at, updated_at)
  on table public.cs_onboardings to authenticated;

drop policy if exists cs_onb_plantillas_ver on public.cs_onboarding_plantillas;
create policy cs_onb_plantillas_ver on public.cs_onboarding_plantillas
  for select to authenticated using (public.cs_puede_ver(programa_id));
drop policy if exists cs_onb_pp_ver on public.cs_onboarding_plantilla_productos;
create policy cs_onb_pp_ver on public.cs_onboarding_plantilla_productos
  for select to authenticated using (public.cs_puede_ver(programa_id));
drop policy if exists cs_onb_ver on public.cs_onboardings;
create policy cs_onb_ver on public.cs_onboardings
  for select to authenticated using (public.cs_puede_ver(programa_id));
drop policy if exists cs_onb_resp_ver on public.cs_onboarding_respuestas;
create policy cs_onb_resp_ver on public.cs_onboarding_respuestas
  for select to authenticated using (public.cs_puede_ver(programa_id));
-- Sin políticas de escritura: se escribe solo por las funciones de abajo.


-- =====================================================================
-- 3. FUNCIONES INTERNAS (nadie las ejecuta suelta)
-- =====================================================================
create or replace function public.cs_ob_total(p_pasos jsonb)
returns int
language sql immutable set search_path = public
as $$
  select count(*)::int from jsonb_array_elements(p_pasos) s
  where s->>'tipo' <> 'final'
    and coalesce(s->>'obligatorio', 'true') <> 'false'
$$;

-- El avance ("3 de 4") y el estado completo cuentan SOLO pasos obligatorios.
create or replace function public.cs_ob_hechos(p_pasos jsonb, p_progreso jsonb)
returns int
language sql immutable set search_path = public
as $$
  select count(*)::int from jsonb_array_elements(p_pasos) s
  where s->>'tipo' <> 'final'
    and coalesce(s->>'obligatorio', 'true') <> 'false'
    and (p_progreso -> (s->>'key') ->> 'completado_at') is not null
$$;

-- ¿Hay un paso OBLIGATORIO sin completar antes del índice p_idx (base 0)? Un paso
-- opcional pendiente no bloquea a los que le siguen.
create or replace function public.cs_ob_bloqueado(p_pasos jsonb, p_progreso jsonb, p_idx int)
returns boolean
language sql immutable set search_path = public
as $$
  select exists (
    select 1
      from jsonb_array_elements(p_pasos) with ordinality as t(s, i)
     where (t.i - 1) < p_idx
       and t.s->>'tipo' <> 'final'
       and coalesce(t.s->>'obligatorio', 'true') <> 'false'
       and (p_progreso -> (t.s->>'key') ->> 'completado_at') is null)
$$;

-- Índice (base 0) del primer paso sin completar, opcional o no: es el que se le
-- muestra al alumno. Si están todos, el índice del último (el 'final').
create or replace function public.cs_ob_actual(p_pasos jsonb, p_progreso jsonb)
returns int
language sql immutable set search_path = public
as $$
  select coalesce(
    (select (t.i - 1)::int
       from jsonb_array_elements(p_pasos) with ordinality as t(s, i)
      where t.s->>'tipo' <> 'final'
        and (p_progreso -> (t.s->>'key') ->> 'completado_at') is null
      order by t.i
      limit 1),
    jsonb_array_length(p_pasos) - 1)
$$;

-- Segundos de video que cuentan como "visto" (y que se exigen si el paso es
-- obligatorio): minimo_seg, o 90 % de duracion_seg. NULL si el paso no declara
-- ninguno de los dos: no hay mínimo inventado.
create or replace function public.cs_ob_video_requerido(p_paso jsonb)
returns int
language sql immutable set search_path = public
as $$
  select coalesce(
    nullif(p_paso->>'minimo_seg', '')::int,
    ceil(nullif(p_paso->>'duracion_seg', '')::numeric * 0.9)::int)
$$;

-- Nombre sin tildes ni orden: "Pérez, Ana" y "Ana Perez" dan la misma clave.
create or replace function public.cs_ob_nombre_clave(p text)
returns text
language sql immutable set search_path = public
as $$
  select nullif(string_agg(t.w, ' ' order by t.w), '')
  from unnest(string_to_array(coalesce(public.cs_norm_nombre(p), ''), ' ')) as t(w)
  where t.w <> ''
$$;

-- Busca el onboarding por token y lo bloquea. Un token mal formado y uno que
-- no existe dan el mismo mensaje.
create or replace function public.cs_ob_cargar(p_token text)
returns public.cs_onboardings
language plpgsql security definer set search_path = public
as $fn$
declare
  r public.cs_onboardings;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'Link inválido' using errcode = 'P0001';
  end if;
  select * into r from public.cs_onboardings where token = p_token for update;
  if not found then
    raise exception 'Link inválido' using errcode = 'P0001';
  end if;
  return r;
end;
$fn$;

-- Valida y limpia las respuestas de un paso formulario contra su definición.
-- p_completo = false (borrador): no exige obligatorias, sí valida lo que vino.
create or replace function public.cs_ob_limpiar(p_paso jsonb, p_resp jsonb, p_completo boolean)
returns jsonb
language plpgsql immutable set search_path = public
as $fn$
declare
  s      jsonb;
  c      jsonb;
  v_out  jsonb := '{}'::jsonb;
  v_key  text;
  v_tipo text;
  v_val  jsonb;
  v_txt  text;
  v_req  boolean;
  v_lab  text;
  v_lim  int;
begin
  for s in select value from jsonb_array_elements(p_paso->'secciones') loop
    for c in select value from jsonb_array_elements(s->'campos') loop
      v_key  := c->>'key';
      v_tipo := c->>'tipo';
      v_lab  := c->>'label';
      v_req  := coalesce((c->>'requerido')::boolean, false);
      v_val  := p_resp -> v_key;

      if v_val is null or jsonb_typeof(v_val) = 'null'
         or (jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') = '')
         or (jsonb_typeof(v_val) = 'array' and jsonb_array_length(v_val) = 0) then
        if v_req and p_completo then
          raise exception 'Falta completar: %', v_lab using errcode = 'P0001';
        end if;
        continue;
      end if;

      if v_tipo in ('texto', 'parrafo') then
        if jsonb_typeof(v_val) not in ('string', 'number') then
          raise exception 'Revisá este campo: %', v_lab using errcode = 'P0001';
        end if;
        v_txt := btrim(v_val #>> '{}');
        v_lim := case when v_tipo = 'texto' then 300 else 2000 end;
        if char_length(v_txt) > v_lim then
          raise exception 'Revisá este campo (muy largo): %', v_lab using errcode = 'P0001';
        end if;
        v_out := v_out || jsonb_build_object(v_key, v_txt);

      elsif v_tipo = 'opcion' then
        if jsonb_typeof(v_val) <> 'string'
           or not exists (select 1 from jsonb_array_elements_text(c->'opciones') o where o = btrim(v_val #>> '{}')) then
          raise exception 'Revisá este campo: %', v_lab using errcode = 'P0001';
        end if;
        v_out := v_out || jsonb_build_object(v_key, btrim(v_val #>> '{}'));

      elsif v_tipo = 'casillas' then
        if jsonb_typeof(v_val) <> 'array' then
          raise exception 'Revisá este campo: %', v_lab using errcode = 'P0001';
        end if;
        if exists (select 1 from jsonb_array_elements(v_val) e where jsonb_typeof(e) <> 'string')
           or exists (select 1 from jsonb_array_elements_text(v_val) x
                      where not exists (select 1 from jsonb_array_elements_text(c->'opciones') o where o = x))
           or (select count(distinct x) from jsonb_array_elements_text(v_val) x) <> jsonb_array_length(v_val) then
          raise exception 'Revisá este campo: %', v_lab using errcode = 'P0001';
        end if;
        v_out := v_out || jsonb_build_object(v_key, v_val);

      elsif v_tipo = 'escala_1_10' then
        v_txt := btrim(v_val #>> '{}');
        if jsonb_typeof(v_val) not in ('string', 'number') or v_txt !~ '^(10|[1-9])$' then
          raise exception 'Revisá este campo: %', v_lab using errcode = 'P0001';
        end if;
        v_out := v_out || jsonb_build_object(v_key, v_txt::int);

      else
        raise exception 'Revisá este campo: %', v_lab using errcode = 'P0001';
      end if;
    end loop;
  end loop;
  return v_out;
end;
$fn$;

-- Marca una casilla del Maestro si TODOS los ítems que apuntan a esa clave
-- están hechos (pasos completos y enlaces confirmados). Un video cuenta cuando
-- fue VISTO (visto_at: llegó al tiempo del video), no cuando se siguió de largo.
create or replace function public.cs_ob_marcar_casilla(p_id uuid, p_clave text)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  o  public.cs_onboardings;
  v_pasos jsonb;
  v_falta boolean;
begin
  if p_clave is null or p_clave !~ '^x_[a-z0-9_]{1,60}$' then return; end if;
  select * into o from public.cs_onboardings where id = p_id;
  select pasos into v_pasos from public.cs_onboarding_plantillas where id = o.plantilla_id;

  select exists (
    select 1 from jsonb_array_elements(v_pasos) s
    where (s->>'tipo' not in ('acceso', 'final', 'video')
           and s->>'casilla' = p_clave
           and (o.progreso -> (s->>'key') ->> 'completado_at') is null)
       or (s->>'tipo' = 'video'
           and s->>'casilla' = p_clave
           and (o.progreso -> (s->>'key') ->> 'visto_at') is null)
       or (s->>'tipo' = 'acceso'
           and exists (select 1 from jsonb_array_elements(s->'enlaces') en
                       where en->>'casilla' = p_clave
                         and (o.progreso -> (s->>'key') -> 'enlaces' ->> (en->>'key')) is null))
  ) into v_falta;

  if not v_falta then
    update public.cs_clientes
       set campos_extra = campos_extra || jsonb_build_object(p_clave, true)
     where id = o.cliente_id;
  end if;
end;
$fn$;

-- Datos de contacto del formulario: completa la ficha SOLO donde está vacía;
-- si difiere de lo que ya hay, no pisa y lo deja en cs_onboardings.diferencias.
create or replace function public.cs_ob_contacto(p_id uuid, p_paso jsonb, p_resp jsonb)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  o       public.cs_onboardings;
  c       public.cs_clientes;
  s       jsonb;
  f       jsonb;
  v_nom   text;
  v_ape   text;
  v_mail  text;
  v_tel   text;
  v_dif   jsonb;
  v_val   text;
begin
  select * into o from public.cs_onboardings where id = p_id;
  select * into c from public.cs_clientes where id = o.cliente_id;
  if c.id is null then return; end if;

  for s in select value from jsonb_array_elements(p_paso->'secciones') loop
    for f in select value from jsonb_array_elements(s->'campos') loop
      v_val := nullif(btrim(coalesce(p_resp ->> (f->>'key'), '')), '');
      if v_val is null then continue; end if;
      case f->>'contacto'
        when 'nombre'   then v_nom  := v_val;
        when 'apellido' then v_ape  := v_val;
        when 'email'    then v_mail := v_val;
        when 'telefono' then v_tel  := v_val;
        else null;
      end case;
    end loop;
  end loop;

  v_nom := nullif(btrim(coalesce(v_nom, '') || ' ' || coalesce(v_ape, '')), '');
  v_dif := o.diferencias;

  -- nombre: nunca está vacío en la ficha; solo se compara
  if v_nom is not null
     and public.cs_ob_nombre_clave(c.nombre) is distinct from public.cs_ob_nombre_clave(v_nom) then
    v_dif := v_dif || jsonb_build_object('nombre',
      jsonb_build_object('ficha', c.nombre, 'alumno', v_nom, 'estado', 'pendiente'));
  end if;

  -- email
  if v_mail is not null then
    if c.email is null or btrim(c.email) = '' then
      if v_mail ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        update public.cs_clientes set email = v_mail where id = c.id;
      else
        v_dif := v_dif || jsonb_build_object('email',
          jsonb_build_object('ficha', null, 'alumno', v_mail, 'estado', 'pendiente'));
      end if;
    elsif lower(btrim(c.email)) <> lower(v_mail) then
      v_dif := v_dif || jsonb_build_object('email',
        jsonb_build_object('ficha', c.email, 'alumno', v_mail, 'estado', 'pendiente'));
    end if;
  end if;

  -- teléfono
  if v_tel is not null then
    if c.telefono is null or btrim(c.telefono) = '' then
      update public.cs_clientes set telefono = v_tel where id = c.id;
    elsif coalesce(public.cs_norm_tel(c.telefono), lower(btrim(c.telefono)))
          is distinct from coalesce(public.cs_norm_tel(v_tel), lower(btrim(v_tel))) then
      v_dif := v_dif || jsonb_build_object('telefono',
        jsonb_build_object('ficha', c.telefono, 'alumno', v_tel, 'estado', 'pendiente'));
    end if;
  end if;

  if v_dif is distinct from o.diferencias then
    update public.cs_onboardings set diferencias = v_dif, updated_at = now() where id = o.id;
  end if;
end;
$fn$;

-- Completa un paso: marca el avance, las casillas, el contacto y, si era el
-- último, cierra el onboarding. El que llama ya tiene la fila bloqueada.
create or replace function public.cs_ob_cerrar_paso(p_id uuid, p_paso jsonb)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  o       public.cs_onboardings;
  v_key   text := p_paso->>'key';
  v_pasos jsonb;
  v_resp  jsonb;
  v_req   int;
  v_seg   numeric;
  v_visto boolean := false;
begin
  -- Video: "visto" = llegó al tiempo del video (si se conoce). Se guarda aparte de
  -- completado_at: un video opcional se puede seguir de largo sin verlo.
  if p_paso->>'tipo' = 'video' then
    v_req := public.cs_ob_video_requerido(p_paso);
    select coalesce((o2.progreso -> v_key ->> 'segundos')::numeric, 0) into v_seg
      from public.cs_onboardings o2 where o2.id = p_id;
    v_visto := v_req is not null and coalesce(v_seg, 0) >= v_req;
  end if;

  update public.cs_onboardings
     set progreso    = jsonb_set(progreso, array[v_key]::text[],
                         coalesce(progreso -> v_key, '{}'::jsonb) || jsonb_build_object('completado_at', now())
                         || case when v_visto then jsonb_build_object('visto_at', now()) else '{}'::jsonb end, true),
         iniciado_at = coalesce(iniciado_at, now()),
         estado      = case when estado = 'pendiente' then 'en_curso' else estado end,
         updated_at  = now()
   where id = p_id;

  if p_paso->>'tipo' in ('video', 'formulario', 'texto') then
    perform public.cs_ob_marcar_casilla(p_id, p_paso->>'casilla');
  end if;

  if p_paso->>'tipo' = 'formulario' then
    select r.respuestas into v_resp from public.cs_onboarding_respuestas r
     where r.onboarding_id = p_id and r.paso_key = v_key;
    if v_resp is not null then
      perform public.cs_ob_contacto(p_id, p_paso, v_resp);
    end if;
  end if;

  select * into o from public.cs_onboardings where id = p_id;
  select pasos into v_pasos from public.cs_onboarding_plantillas where id = o.plantilla_id;

  if o.estado <> 'completado' and public.cs_ob_hechos(v_pasos, o.progreso) = public.cs_ob_total(v_pasos) then
    update public.cs_onboardings
       set estado = 'completado', completado_at = now(), updated_at = now()
     where id = p_id;
    -- Igual que 004: el accionable de plantilla 'formulario_onboarding' se cierra solo.
    update public.cs_accionables a
       set estado = 'completado'
     where a.cliente_id = o.cliente_id
       and a.plantilla_key = 'formulario_onboarding'
       and a.estado <> 'completado';
  end if;
end;
$fn$;

-- El estado público de un onboarding: lo único que ve la landing.
create or replace function public.cs_ob_armar_estado(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  o      public.cs_onboardings;
  pl     public.cs_onboarding_plantillas;
  v_prod text;
  v_marca text;
  v_alum text;
  v_base jsonb;
begin
  select * into o from public.cs_onboardings where id = p_id;
  select * into pl from public.cs_onboarding_plantillas where id = o.plantilla_id;
  select p.marca into v_marca from public.cs_programas p where p.id = o.programa_id;
  select pr.nombre into v_prod
    from public.cs_clientes c left join public.cs_productos pr on pr.id = c.producto_id
   where c.id = o.cliente_id;
  select split_part(btrim(c.nombre), ' ', 1) into v_alum from public.cs_clientes c where c.id = o.cliente_id;

  v_base := jsonb_build_object(
    'alumno',   v_alum,
    'programa', coalesce(v_prod, pl.nombre),
    'marca',    v_marca,
    'mentor',   pl.mentor);

  if o.estado = 'completado' then
    return v_base || jsonb_build_object('estado', 'completado');
  end if;
  if o.vence_at < now() then
    return v_base || jsonb_build_object('estado', 'vencido');
  end if;

  return v_base || jsonb_build_object(
    'estado', 'ok',
    'pasos',  pl.pasos,
    'actual', public.cs_ob_actual(pl.pasos, o.progreso),
    'progreso', (
      select coalesce(jsonb_object_agg(s->>'key', jsonb_build_object(
               'completado', (o.progreso -> (s->>'key') ->> 'completado_at') is not null,
               'segundos',   coalesce((o.progreso -> (s->>'key') ->> 'segundos')::numeric, 0)::int,
               'enlaces',    coalesce((select jsonb_object_agg(k, true)
                                         from jsonb_object_keys(
                                                coalesce(o.progreso -> (s->>'key') -> 'enlaces', '{}'::jsonb)) as k),
                                      '{}'::jsonb)
             )), '{}'::jsonb)
      from jsonb_array_elements(pl.pasos) s),
    -- PRIVACIDAD: solo el BORRADOR del formulario en curso (completo = false), para que
    -- el alumno pueda retomar. Un formulario ya enviado NO vuelve por la vía pública
    -- nunca más: el estado solo dice que el paso está completo. Quien tiene el link
    -- (el closer lo recibe siempre) no puede leer lo ya enviado.
    -- RIESGO ACEPTADO: quien tiene el link ve el borrador mientras el alumno lo llena.
    'respuestas', (
      select coalesce(jsonb_object_agg(r.paso_key, r.respuestas), '{}'::jsonb)
      from public.cs_onboarding_respuestas r
      where r.onboarding_id = o.id
        and not r.completo
        and (o.progreso -> r.paso_key ->> 'completado_at') is null)
  );
end;
$fn$;


-- =====================================================================
-- 4. RPC PÚBLICAS (anon)
-- =====================================================================
-- Estado completo de un link. Registra la primera apertura.
create or replace function public.cs_ob_estado(p_token text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  o public.cs_onboardings;
begin
  o := public.cs_ob_cargar(p_token);
  if o.abierto_at is null and o.estado <> 'completado' and o.vence_at >= now() then
    update public.cs_onboardings set abierto_at = now(), updated_at = now() where id = o.id;
  end if;
  return public.cs_ob_armar_estado(o.id);
end;
$fn$;

-- Latido del video: suma el tiempo que la landing estuvo abierta y visible con
-- ese video en pantalla. Cuenta en el servidor, entre latidos de hasta 30 s, con
-- un máximo de 15 s por latido y sin sumar nada si llegan más seguidos que cada 5 s.
-- Sirve tanto para el video obligatorio (exige el tiempo) como para el opcional
-- (solo lo registra: le sirve a la CSM).
create or replace function public.cs_ob_latido(p_token text, p_paso text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  o       public.cs_onboardings;
  v_pasos jsonb;
  v_paso  jsonb;
  v_idx   int;
  v_prev  jsonb;
  v_seg   numeric;
  v_ult   timestamptz;
  v_dt    numeric;
  v_req   int;
  v_cap   int;
begin
  o := public.cs_ob_cargar(p_token);
  if o.estado = 'completado' or o.vence_at < now() then
    raise exception 'Link inválido' using errcode = 'P0001';
  end if;
  select pasos into v_pasos from public.cs_onboarding_plantillas where id = o.plantilla_id;
  select t.s, (t.i - 1)::int into v_paso, v_idx
    from jsonb_array_elements(v_pasos) with ordinality as t(s, i)
   where t.s->>'key' = p_paso and t.s->>'tipo' = 'video';
  if v_paso is null then
    raise exception 'Paso inexistente' using errcode = 'P0001';
  end if;
  if public.cs_ob_bloqueado(v_pasos, o.progreso, v_idx) then
    raise exception 'Completá primero el paso anterior.' using errcode = 'P0001';
  end if;

  -- v_req es NULL si el video no declara duración: se guardan los segundos igual,
  -- con un tope de 1 hora para que un latido infinito no crezca sin límite.
  v_req  := public.cs_ob_video_requerido(v_paso);
  v_cap  := coalesce(v_req, 3600);
  v_prev := coalesce(o.progreso -> p_paso, '{}'::jsonb);
  v_seg  := coalesce((v_prev ->> 'segundos')::numeric, 0);
  if (v_prev ->> 'completado_at') is not null or v_seg >= v_cap then
    return jsonb_build_object('segundos', least(v_seg, v_cap)::int, 'requerido', v_req);
  end if;

  v_ult := nullif(v_prev ->> 'ultimo_latido', '')::timestamptz;
  v_dt  := case when v_ult is null then null else extract(epoch from (now() - v_ult)) end;

  if v_dt is not null and v_dt < 5 then
    return jsonb_build_object('segundos', v_seg::int, 'requerido', v_req);
  end if;
  if v_dt is not null and v_dt <= 30 then
    v_seg := least(v_seg + least(v_dt, 15), v_cap);
  end if;

  update public.cs_onboardings
     set progreso    = jsonb_set(progreso, array[p_paso]::text[],
                         v_prev || jsonb_build_object('segundos', round(v_seg, 1), 'ultimo_latido', now()), true),
         iniciado_at = coalesce(iniciado_at, now()),
         estado      = case when estado = 'pendiente' then 'en_curso' else estado end,
         updated_at  = now()
   where id = o.id;

  return jsonb_build_object('segundos', v_seg::int, 'requerido', v_req);
end;
$fn$;

-- Guardar un paso: borrador de un formulario (p_completar = false), enviar
-- un formulario, o dar por visto un video / leído un texto.
create or replace function public.cs_ob_avanzar(
  p_token      text,
  p_paso       text,
  p_respuestas jsonb default '{}'::jsonb,
  p_completar  boolean default true
)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  c_max_esc  constant int := 400;
  c_max_byte constant int := 20000;
  c_val      constant text := 'Revisá los campos del formulario e intentá de nuevo';
  o       public.cs_onboardings;
  v_pasos jsonb;
  v_paso  jsonb;
  v_idx   int;
  v_limp  jsonb;
  v_seg   numeric;
  v_req   int;
begin
  if p_respuestas is null or jsonb_typeof(p_respuestas) is distinct from 'object'
     or octet_length(p_respuestas::text) > c_max_byte then
    raise exception '%', c_val using errcode = 'P0001';
  end if;

  o := public.cs_ob_cargar(p_token);
  if o.estado = 'completado' then
    raise exception 'Este onboarding ya está completo.' using errcode = 'P0001';
  end if;
  if o.vence_at < now() or o.escrituras >= c_max_esc then
    raise exception 'Link inválido' using errcode = 'P0001';
  end if;

  select pasos into v_pasos from public.cs_onboarding_plantillas where id = o.plantilla_id;
  select t.s, (t.i - 1)::int into v_paso, v_idx
    from jsonb_array_elements(v_pasos) with ordinality as t(s, i)
   where t.s->>'key' = p_paso;
  if v_paso is null or v_paso->>'tipo' in ('final', 'acceso') then
    raise exception 'Paso inexistente' using errcode = 'P0001';
  end if;
  if public.cs_ob_bloqueado(v_pasos, o.progreso, v_idx) then
    raise exception 'Completá primero el paso anterior.' using errcode = 'P0001';
  end if;
  if (o.progreso -> p_paso ->> 'completado_at') is not null then
    return public.cs_ob_armar_estado(o.id);        -- paso ya hecho: no se reescribe
  end if;

  update public.cs_onboardings
     set escrituras = escrituras + 1, abierto_at = coalesce(abierto_at, now()),
         iniciado_at = coalesce(iniciado_at, now()),
         estado = case when estado = 'pendiente' then 'en_curso' else estado end,
         updated_at = now()
   where id = o.id;

  if v_paso->>'tipo' = 'formulario' then
    v_limp := public.cs_ob_limpiar(v_paso, p_respuestas, coalesce(p_completar, true));
    insert into public.cs_onboarding_respuestas (onboarding_id, programa_id, cliente_id, paso_key, respuestas, completo)
    values (o.id, o.programa_id, o.cliente_id, p_paso, v_limp, coalesce(p_completar, true))
    on conflict (onboarding_id, paso_key) do update
      set respuestas = excluded.respuestas, completo = excluded.completo, updated_at = now();
    if coalesce(p_completar, true) then
      perform public.cs_ob_cerrar_paso(o.id, v_paso);
    end if;

  elsif v_paso->>'tipo' = 'video' then
    if not coalesce(p_completar, true) then
      raise exception '%', c_val using errcode = 'P0001';
    end if;
    -- Solo el video obligatorio exige tiempo. El opcional se puede seguir de
    -- largo; si llegó al tiempo del video, cerrar_paso deja la marca "visto".
    if coalesce(v_paso->>'obligatorio', 'true') <> 'false' then
      v_req := public.cs_ob_video_requerido(v_paso);
      v_seg := coalesce((o.progreso -> p_paso ->> 'segundos')::numeric, 0);
      if v_req is not null and v_seg < v_req then
        raise exception 'Todavía falta tiempo de video para poder continuar.' using errcode = 'P0001';
      end if;
    end if;
    perform public.cs_ob_cerrar_paso(o.id, v_paso);

  elsif v_paso->>'tipo' = 'texto' then
    if not coalesce(p_completar, true) then
      raise exception '%', c_val using errcode = 'P0001';
    end if;
    perform public.cs_ob_cerrar_paso(o.id, v_paso);
  end if;

  return public.cs_ob_armar_estado(o.id);
end;
$fn$;

-- Confirmar un acceso ("ya lo hice"). Cuando están todos, el paso queda completo.
create or replace function public.cs_ob_confirmar(p_token text, p_paso text, p_enlace text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  c_max_esc constant int := 400;
  o       public.cs_onboardings;
  v_pasos jsonb;
  v_paso  jsonb;
  v_idx   int;
  v_en    jsonb;
  v_prev  jsonb;
begin
  o := public.cs_ob_cargar(p_token);
  if o.estado = 'completado' then
    raise exception 'Este onboarding ya está completo.' using errcode = 'P0001';
  end if;
  if o.vence_at < now() or o.escrituras >= c_max_esc then
    raise exception 'Link inválido' using errcode = 'P0001';
  end if;

  select pasos into v_pasos from public.cs_onboarding_plantillas where id = o.plantilla_id;
  select t.s, (t.i - 1)::int into v_paso, v_idx
    from jsonb_array_elements(v_pasos) with ordinality as t(s, i)
   where t.s->>'key' = p_paso and t.s->>'tipo' = 'acceso';
  if v_paso is null then
    raise exception 'Paso inexistente' using errcode = 'P0001';
  end if;
  if public.cs_ob_bloqueado(v_pasos, o.progreso, v_idx) then
    raise exception 'Completá primero el paso anterior.' using errcode = 'P0001';
  end if;
  if (o.progreso -> p_paso ->> 'completado_at') is not null then
    return public.cs_ob_armar_estado(o.id);
  end if;

  select e2.value into v_en from jsonb_array_elements(v_paso->'enlaces') as e2
   where e2.value->>'key' = p_enlace;
  if v_en is null then
    raise exception 'Paso inexistente' using errcode = 'P0001';
  end if;

  v_prev := coalesce(o.progreso -> p_paso, '{}'::jsonb);
  update public.cs_onboardings
     set progreso = jsonb_set(progreso, array[p_paso]::text[],
                      v_prev || jsonb_build_object('enlaces',
                        coalesce(v_prev -> 'enlaces', '{}'::jsonb) || jsonb_build_object(p_enlace, now())), true),
         escrituras = escrituras + 1, abierto_at = coalesce(abierto_at, now()),
         iniciado_at = coalesce(iniciado_at, now()),
         estado = case when estado = 'pendiente' then 'en_curso' else estado end,
         updated_at = now()
   where id = o.id;

  perform public.cs_ob_marcar_casilla(o.id, v_en->>'casilla');

  select * into o from public.cs_onboardings where id = o.id;
  if not exists (
    select 1 from jsonb_array_elements(v_paso->'enlaces') en
    where (o.progreso -> p_paso -> 'enlaces' ->> (en->>'key')) is null
  ) then
    perform public.cs_ob_cerrar_paso(o.id, v_paso);
  end if;

  return public.cs_ob_armar_estado(o.id);
end;
$fn$;


-- =====================================================================
-- 5. RPC DE LA APP (authenticated)
-- =====================================================================
-- Crea el onboarding del alumno (o devuelve el que ya existe) y su token.
-- Un link vencido y sin completar se renueva con token nuevo. NO chequea
-- permisos: es interna (nadie la ejecuta suelta) y la llaman, ya con su propio
-- chequeo, cs_onboarding_link (edición del programa) y cs_onboarding_link_closer.
create or replace function public.cs_ob_generar_link(p_cliente uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  c   public.cs_clientes;
  v_pl public.cs_onboarding_plantillas;
  o   public.cs_onboardings;
  v_creado boolean := false;
begin
  select * into c from public.cs_clientes where id = p_cliente;
  if c.id is null then
    raise exception 'cs: el cliente no existe' using errcode = 'P0002';
  end if;
  if c.estado in ('finalizado', 'baja') then
    raise exception 'cs: el cliente está finalizado o dado de baja' using errcode = '23514';
  end if;
  if c.producto_id is null then
    raise exception 'cs: el cliente no tiene producto: elegilo en la ficha para saber qué onboarding le toca' using errcode = '23514';
  end if;

  select pl.* into v_pl
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas pl on pl.id = pp.plantilla_id
   where pp.producto_id = c.producto_id and pl.activa;
  if v_pl.id is null then
    raise exception 'cs: el producto de este cliente no tiene un onboarding asignado' using errcode = '23514';
  end if;

  select * into o from public.cs_onboardings where cliente_id = c.id for update;
  if o.id is null then
    insert into public.cs_onboardings (cliente_id, programa_id, plantilla_id, vence_at)
    values (c.id, c.programa_id, v_pl.id, now() + make_interval(days => v_pl.validez_dias))
    returning * into o;
    v_creado := true;
  elsif o.estado <> 'completado' then
    update public.cs_onboardings
       set plantilla_id = v_pl.id,
           token = case when o.vence_at < now()
                        then replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
                        else o.token end,
           vence_at = case when o.vence_at < now()
                           then now() + make_interval(days => v_pl.validez_dias)
                           else o.vence_at end,
           updated_at = now()
     where id = o.id
    returning * into o;
  end if;

  return jsonb_build_object(
    'token', o.token, 'estado', o.estado, 'creado', v_creado,
    'vence_at', o.vence_at, 'plantilla', v_pl.nombre);
end;
$fn$;

-- Desde la app de Producto: escribe quien tiene edición del programa
-- (fundador y producto); 'cliente' es de lectura.
create or replace function public.cs_onboarding_link(p_cliente uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_prog text;
  v_res  jsonb;
begin
  select programa_id into v_prog from public.cs_clientes where id = p_cliente;
  if v_prog is null then
    raise exception 'cs: el cliente no existe' using errcode = 'P0002';
  end if;
  if not public.cs_puede_editar(v_prog) then
    raise exception 'cs: no tenés permiso para generar el link de onboarding' using errcode = '42501';
  end if;
  v_res := public.cs_ob_generar_link(p_cliente);
  -- Pedir el link desde la ficha (fundador o producto) reinicia el contador de
  -- escrituras del link (tope anti-abuso): conserva el avance y destraba un link
  -- que llegó al tope. El closer (cs_onboarding_link_closer) NO lo reinicia.
  update public.cs_onboardings
     set escrituras = 0, updated_at = now()
   where cliente_id = p_cliente and estado <> 'completado' and escrituras > 0;
  return v_res;
end;
$fn$;

-- Desde Ventas: el closer (rol ventas o closer) genera el link de un alumno de
-- un cliente que tiene asignado en crm_asignaciones. Permiso mínimo: NO lee
-- respuestas, ni el programa, ni el Maestro (no tiene cs_puede_ver). Recibe lo
-- que el closer conoce del alumno (teléfono y, si lo tiene, nombre), nunca un
-- id de la ficha. Encuentra al alumno con la misma regla que cs_altas_pendientes
-- (070): últimos 8 dígitos del teléfono o nombre normalizado sin orden. Una sola
-- coincidencia o error: jamás elige entre varias y NUNCA crea al alumno (el alta
-- la hace la CSM desde "Clientes nuevos", con producto).
create or replace function public.cs_onboarding_link_closer(
  p_programa text,
  p_telefono text,
  p_nombre   text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_tel  text := public.cs_norm_tel(p_telefono);
  v_nom  text := public.cs_ob_nombre_clave(p_nombre);
  v_ids  uuid[];
  v_inac int;
  v_res  jsonb;
begin
  if v_uid is null
     or p_programa is null
     or not exists (select 1
                      from public.crm_members m
                      join public.crm_asignaciones a on a.user_id = m.user_id
                     where m.user_id = v_uid
                       and m.rol in ('ventas', 'closer')
                       and a.cliente_id::text = p_programa) then
    raise exception 'cs: no tenés permiso para generar el link de onboarding de este cliente' using errcode = '42501';
  end if;
  if v_tel is null and v_nom is null then
    raise exception 'cs: pasá el teléfono del alumno (o su nombre) para encontrarlo' using errcode = '22023';
  end if;

  select array_agg(c.id) into v_ids
    from public.cs_clientes c
   where c.programa_id = p_programa
     and c.estado not in ('finalizado', 'baja')
     and ((v_tel is not null and public.cs_norm_tel(c.telefono) = v_tel)
          or (v_nom is not null and public.cs_ob_nombre_clave(c.nombre) = v_nom));

  -- Error FIJO para el front de Ventas: SQLSTATE P0002, message que empieza con
  -- 'ALUMNO_SIN_ALTA' y hint = 'ALUMNO_SIN_ALTA' (error.code / error.hint en supabase-js).
  -- Sin activos pero con uno finalizado o dado de baja: error distinto y claro.
  if v_ids is null then
    select count(*) into v_inac
      from public.cs_clientes c
     where c.programa_id = p_programa
       and c.estado in ('finalizado', 'baja')
       and ((v_tel is not null and public.cs_norm_tel(c.telefono) = v_tel)
            or (v_nom is not null and public.cs_ob_nombre_clave(c.nombre) = v_nom));
    if v_inac > 0 then
      raise exception 'ALUMNO_INACTIVO: el alumno figura finalizado o dado de baja en Producto. Avisale a la CSM.'
        using errcode = 'P0002', hint = 'ALUMNO_INACTIVO';
    end if;
  end if;
  if v_ids is null then
    raise exception 'ALUMNO_SIN_ALTA: el alumno todavía no está dado de alta en Producto. Lo da de alta la CSM desde Clientes nuevos.'
      using errcode = 'P0002', hint = 'ALUMNO_SIN_ALTA';
  end if;
  if cardinality(v_ids) > 1 then
    raise exception 'cs: hay más de un alumno que coincide con esos datos: avisale a Producto' using errcode = '23505';
  end if;

  v_res := public.cs_ob_generar_link(v_ids[1]);
  -- Solo lo que necesita el closer para mandar el link y confirmar a quién.
  return jsonb_build_object(
    'token', v_res->'token', 'estado', v_res->'estado', 'vence_at', v_res->'vence_at',
    'alumno', (select split_part(btrim(c.nombre), ' ', 1) from public.cs_clientes c where c.id = v_ids[1]));
end;
$fn$;

-- Avance y respuestas de un alumno para la ficha. Sin token.
create or replace function public.cs_onboarding_ficha(p_cliente uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  c  public.cs_clientes;
  o  public.cs_onboardings;
  pl public.cs_onboarding_plantillas;
begin
  select * into c from public.cs_clientes where id = p_cliente;
  if c.id is null or not public.cs_puede_ver(c.programa_id) then
    raise exception 'cs: el cliente no existe o no tenés acceso' using errcode = 'P0002';
  end if;
  select * into o from public.cs_onboardings where cliente_id = c.id;
  if o.id is null then
    return null;
  end if;
  select * into pl from public.cs_onboarding_plantillas where id = o.plantilla_id;

  return jsonb_build_object(
    'estado', o.estado,
    'vence_at', o.vence_at,
    'abierto_at', o.abierto_at,
    'iniciado_at', o.iniciado_at,
    'completado_at', o.completado_at,
    'plantilla', pl.nombre,
    'mentor', pl.mentor,
    'pasos', pl.pasos,
    'progreso', o.progreso,
    'diferencias', o.diferencias,
    'hechos', public.cs_ob_hechos(pl.pasos, o.progreso),
    'total', public.cs_ob_total(pl.pasos),
    'puede_editar', public.cs_puede_editar(c.programa_id),
    'respuestas', (select coalesce(jsonb_object_agg(r.paso_key, jsonb_build_object(
                           'respuestas', r.respuestas, 'completo', r.completo, 'updated_at', r.updated_at)),
                           '{}'::jsonb)
                   from public.cs_onboarding_respuestas r where r.onboarding_id = o.id));
end;
$fn$;

-- La CSM decide un dato de contacto que difiere: 'aplicar' (usa el del alumno)
-- o 'descartar' (queda el de la ficha).
create or replace function public.cs_onboarding_diferencia_resolver(p_cliente uuid, p_campo text, p_accion text)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  c   public.cs_clientes;
  o   public.cs_onboardings;
  v_d jsonb;
begin
  if p_campo not in ('nombre', 'email', 'telefono') or p_accion not in ('aplicar', 'descartar') then
    raise exception 'cs: dato o acción no válidos' using errcode = '22023';
  end if;
  select * into c from public.cs_clientes where id = p_cliente;
  if c.id is null or not public.cs_puede_editar(c.programa_id) then
    raise exception 'cs: el cliente no existe o no tenés permiso' using errcode = '42501';
  end if;
  select * into o from public.cs_onboardings where cliente_id = c.id for update;
  v_d := o.diferencias -> p_campo;
  if o.id is null or v_d is null or v_d->>'estado' <> 'pendiente' then
    raise exception 'cs: no hay una diferencia pendiente en %', p_campo using errcode = 'P0002';
  end if;

  if p_accion = 'aplicar' then
    if p_campo = 'nombre' then
      update public.cs_clientes set nombre = v_d->>'alumno' where id = c.id;
    elsif p_campo = 'email' then
      -- El alumno pudo escribir un mail mal formado (queda como diferencia): el
      -- CHECK de cs_clientes lo rechazaría con un error poco claro.
      if coalesce(v_d->>'alumno', '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        raise exception 'cs: el mail que escribió el alumno no es válido: descartalo o corregilo en la ficha' using errcode = '22023';
      end if;
      update public.cs_clientes set email = v_d->>'alumno' where id = c.id;
    else
      update public.cs_clientes set telefono = v_d->>'alumno' where id = c.id;
    end if;
  end if;

  update public.cs_onboardings
     set diferencias = jsonb_set(diferencias, array[p_campo, 'estado']::text[],
                         to_jsonb(case when p_accion = 'aplicar' then 'aplicada' else 'descartada' end), true),
         updated_at = now()
   where id = o.id;
end;
$fn$;

-- Avance por alumno para el Maestro. security invoker: respeta la RLS.
create or replace function public.cs_onboarding_avance(p_programa text)
returns table (
  cliente_id uuid,
  estado     text,
  hechos     int,
  total      int,
  ultimo_at  timestamptz
)
language sql stable security invoker set search_path = public
as $$
  select o.cliente_id, o.estado,
         public.cs_ob_hechos(pl.pasos, o.progreso),
         public.cs_ob_total(pl.pasos),
         coalesce(o.completado_at, o.updated_at)
  from public.cs_onboardings o
  join public.cs_onboarding_plantillas pl on pl.id = o.plantilla_id
  where o.programa_id = p_programa
$$;

-- Avisos para Hoy: completaron en los últimos 7 días y los que llevan más de
-- 3 días empezados sin terminar. security invoker.
create or replace function public.cs_onboarding_hoy(p_programa text)
returns table (
  cliente_id uuid,
  cliente    text,
  tipo       text,
  dias       int,
  hechos     int,
  total      int,
  fecha      timestamptz
)
language sql stable security invoker set search_path = public
as $$
  select o.cliente_id, c.nombre,
         case when o.estado = 'completado' then 'completo' else 'demorado' end,
         case when o.estado = 'completado'
              then greatest(extract(day from now() - o.completado_at)::int, 0)
              else greatest(extract(day from now() - coalesce(o.iniciado_at, o.abierto_at))::int, 0) end,
         public.cs_ob_hechos(pl.pasos, o.progreso),
         public.cs_ob_total(pl.pasos),
         coalesce(o.completado_at, o.iniciado_at, o.abierto_at)
  from public.cs_onboardings o
  join public.cs_onboarding_plantillas pl on pl.id = o.plantilla_id
  join public.cs_clientes c on c.id = o.cliente_id
  where o.programa_id = p_programa
    and c.estado not in ('finalizado', 'baja')
    and (
      (o.estado = 'completado' and o.completado_at >= now() - interval '7 days')
      or (o.estado <> 'completado'
          and coalesce(o.iniciado_at, o.abierto_at) is not null
          and coalesce(o.iniciado_at, o.abierto_at) < now() - interval '3 days')
    )
  order by 3, 7
$$;


-- =====================================================================
-- 6. PERMISOS DE FUNCIONES
-- =====================================================================
-- Primero se saca todo (incluida la ejecución por defecto de Supabase a anon
-- y authenticated); después se da solo lo que corresponde.
revoke all on function
  public.cs_validar_onboarding_pasos_motivo(jsonb),
  public.cs_validar_onboarding_pasos(jsonb),
  public.cs_ob_total(jsonb),
  public.cs_ob_hechos(jsonb, jsonb),
  public.cs_ob_actual(jsonb, jsonb),
  public.cs_ob_bloqueado(jsonb, jsonb, int),
  public.cs_ob_video_requerido(jsonb),
  public.cs_ob_nombre_clave(text),
  public.cs_ob_cargar(text),
  public.cs_ob_limpiar(jsonb, jsonb, boolean),
  public.cs_ob_marcar_casilla(uuid, text),
  public.cs_ob_contacto(uuid, jsonb, jsonb),
  public.cs_ob_cerrar_paso(uuid, jsonb),
  public.cs_ob_armar_estado(uuid),
  public.cs_ob_estado(text),
  public.cs_ob_latido(text, text),
  public.cs_ob_avanzar(text, text, jsonb, boolean),
  public.cs_ob_confirmar(text, text, text),
  public.cs_ob_generar_link(uuid),
  public.cs_onboarding_link(uuid),
  public.cs_onboarding_link_closer(text, text, text),
  public.cs_onboarding_ficha(uuid),
  public.cs_onboarding_diferencia_resolver(uuid, text, text),
  public.cs_onboarding_avance(text),
  public.cs_onboarding_hoy(text)
from public, anon, authenticated;

grant execute on function
  public.cs_ob_estado(text),
  public.cs_ob_latido(text, text),
  public.cs_ob_avanzar(text, text, jsonb, boolean),
  public.cs_ob_confirmar(text, text, text)
to anon, authenticated;

grant execute on function
  public.cs_onboarding_link(uuid),
  public.cs_onboarding_link_closer(text, text, text),
  public.cs_onboarding_ficha(uuid),
  public.cs_onboarding_diferencia_resolver(uuid, text, text),
  public.cs_onboarding_avance(text),
  public.cs_onboarding_hoy(text)
to authenticated;
-- cs_validar_onboarding_pasos, cs_ob_total/hechos/actual y compañía las usan las
-- RPC (que corren como dueño) y los CHECK; ni anon ni authenticated las ejecutan.
-- cs_onboarding_avance y cs_onboarding_hoy son security invoker: llaman a
-- cs_ob_total / cs_ob_hechos con el rol de quien consulta, así que esas dos sí
-- necesitan execute para authenticated:
grant execute on function
  public.cs_ob_total(jsonb),
  public.cs_ob_hechos(jsonb, jsonb)
to authenticated;


-- =====================================================================
-- 7. MAESTRO: columna calculada y casillas de liam
-- =====================================================================
-- 'onb_avance' pasa a ser una clave del sistema (renombrable / ocultable). La
-- lista se mantiene igual que 071, con una clave más.
create or replace function public.cs_maestro_claves_sistema()
returns text[]
language sql immutable parallel safe set search_path = public
as $$
  select array[
    'nombre', 'prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha',
    'nota_csm', 'testimonio', 'renovacion_estado', 'renovacion_producto',
    'aviso_1_at', 'aviso_2_at', 'estado', 'producto', 'etapa', 'dias_restantes',
    'acc', 'dev_pendientes', 'ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
    'proximo_contacto', 'renovaciones_count', 'onb_avance'
  ]::text[]
$$;

-- Casillas por paso (tipo casilla, 071). El valor va a campos_extra[clave].
-- x_unio_school (079) ya cubre Skool. Las marca el alumno al confirmar; la CSM
-- las puede corregir a mano desde el Maestro.
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, tipo)
select 'liam', v.clave, false, v.etiqueta,
       coalesce((select max(c.orden) from public.cs_maestro_columnas c where c.programa_id = 'liam'), 1000) + v.pos,
       'casilla'
from (values
  (1, 'x_ob_video',       'Onboarding: video visto'),
  (2, 'x_ob_formularios', 'Onboarding: formularios completos'),
  (3, 'x_ob_wpp',         'Onboarding: grupo de WhatsApp'),
  (4, 'x_ob_escribio',    'Onboarding: le escribió a Liam')
) as v(pos, clave, etiqueta)
where exists (select 1 from public.cs_programas where id = 'liam')
on conflict (programa_id, clave) do nothing;


-- =====================================================================
-- 8. CARGA DE LIAM: dos plantillas
-- =====================================================================
-- Textos, links y preguntas de datos/onboarding-liam (12/10/2026). Corregidos
-- los tipeos evidentes; "Cuáles eran tus problemas principales" pasa a casillas
-- (la ayuda decía "Podés elegir varias") y "cuánto tardaste en decidirte" suma
-- "3 a 6 meses". Ninguna pregunta cambió de sentido y no se agregó ninguna.

-- Las dos plantillas se cargan desde un DO: antes de insertar se pasan por
-- cs_validar_onboarding_pasos_motivo(), y si alguna falla el error dice QUÉ paso
-- y QUÉ regla (el CHECK de la tabla solo diría "viola la restricción").

do $seed$
declare
  v_motivo text;

-- ---------- Variante 1 a 1 ----------
  v_1a1 jsonb := $j$[
  {"key":"bienvenida","tipo":"video","titulo":"Bienvenido a Blueprint Financiero",
   "texto":"Gracias por sumarte a Blueprint Financiero. Es un proceso claro y sencillo, y en este video te explicamos todo paso a paso. Te recomendamos verlo completo antes de seguir.",
   "url":"https://www.loom.com/share/ee9aaaeaea5747808b8ac8be1a1c4cbd","duracion_seg":360,
   "obligatorio":false,
   "tiempo":"6 minutos","casilla":"x_ob_video","boton":"Continuar"},

  {"key":"datos_contacto","tipo":"formulario","titulo":"Paso 1: Datos de contacto",
   "texto":"Queremos conocerte mejor. Es el primer formulario, con tus datos básicos de contacto.",
   "tiempo":"3 minutos","casilla":"x_ob_formularios",
   "secciones":[{"campos":[
     {"key":"nombre","label":"Nombre","tipo":"texto","requerido":true,"contacto":"nombre"},
     {"key":"email","label":"Correo electrónico","tipo":"texto","requerido":true,"contacto":"email"},
     {"key":"telefono","label":"Número de teléfono","tipo":"texto","requerido":true,"contacto":"telefono"},
     {"key":"comentarios","label":"Comentarios","tipo":"parrafo"}
   ]}]},

  {"key":"diagnostico","tipo":"formulario","titulo":"Paso 2: Diagnóstico financiero",
   "texto":"Este formulario tiene como objetivo conocer tu situación financiera actual de manera integral: ingresos, gastos, ahorros, deudas, inversiones y metas. La información que compartas será tratada con total confidencialidad y nos permitirá diseñar un plan personalizado para ayudarte a organizar tus finanzas, optimizar tus recursos y proyectar tus objetivos a corto, mediano y largo plazo.",
   "tiempo":"8 a 10 minutos","casilla":"x_ob_formularios",
   "secciones":[
     {"titulo":"Datos básicos","campos":[
       {"key":"nombre_apellido","label":"Nombre y apellido","tipo":"texto","requerido":true},
       {"key":"edad","label":"Edad","tipo":"texto","requerido":true},
       {"key":"hijos","label":"Hijos / personas a cargo","tipo":"texto","requerido":true},
       {"key":"ocupacion","label":"Ocupación / trabajo","tipo":"texto","requerido":true}]},
     {"titulo":"Ingresos","campos":[
       {"key":"ingreso_mensual","label":"¿De cuánto es tu ingreso mensual neto? (en USD)","tipo":"texto","requerido":true},
       {"key":"ingresos_adicionales","label":"¿Tenés ingresos adicionales (freelance, rentas, dividendos, etc.)?","tipo":"opcion","requerido":true,"opciones":["Sí","No","Tal vez"]},
       {"key":"promedio_3_meses","label":"¿Cuál es tu promedio de ingresos de los últimos 3 meses?","tipo":"texto","requerido":true}]},
     {"titulo":"Ahorros","campos":[
       {"key":"tiene_ahorros","label":"¿Contás con ahorros?","tipo":"opcion","requerido":true,"opciones":["Sí","No"]},
       {"key":"fondo_emergencia","label":"¿Contás con un fondo de emergencia? (entre 3 a 6 meses de tu sueldo promedio ahorrado)","tipo":"opcion","requerido":true,"opciones":["Sí","No"]},
       {"key":"en_que_ahorra","label":"¿En qué ahorrás? (instrumento o moneda)","tipo":"texto","requerido":true},
       {"key":"porcentaje_ahorro","label":"¿Qué porcentaje aproximado de tus ingresos podés ahorrar cada mes?","tipo":"opcion","requerido":true,"opciones":["Entre 0-10%","10% a 30%","30 a 50%","50-60%","+60%"]}]},
     {"titulo":"Gastos","campos":[
       {"key":"gasto_mensual","label":"¿Cuál es tu gasto mensual promedio?","tipo":"texto","requerido":true},
       {"key":"categorias_gasto","label":"Principales categorías de gasto (hogar, transporte, alimentación, ocio, salud, educación)","tipo":"opcion","requerido":true,"opciones":["Hogar","Transporte","Ocio","Salud","Alimentación","Otro"]},
       {"key":"tiene_deudas","label":"¿Tenés deudas? (sí/no)","tipo":"opcion","requerido":true,"opciones":["Sí","No"]},
       {"key":"tipo_deuda","label":"En caso de que sí, ¿qué tipo de deuda?","tipo":"texto","requerido":true}]},
     {"titulo":"Inversiones","campos":[
       {"key":"activos","label":"¿Tenés inversiones en alguno de estos activos? (selección múltiple)","tipo":"casillas","requerido":true,"opciones":["Acciones","Bonos","ETFs / Fondos","Criptomonedas","Bienes raíces","Plazo fijo","Otros"]},
       {"key":"patrimonio_invertido","label":"¿Qué porcentaje de tu patrimonio está invertido?","tipo":"opcion","requerido":true,"opciones":["0-20%","20-50%","50-70%","+70%"]},
       {"key":"experiencia","label":"¿Cómo describirías tu experiencia en inversiones? (principiante, intermedio, avanzado)","tipo":"parrafo","requerido":true}]},
     {"titulo":"Objetivos financieros","campos":[
       {"key":"objetivos_corto","label":"¿Cuáles son tus principales objetivos financieros en el corto plazo (1-3 años)?","tipo":"parrafo","requerido":true},
       {"key":"objetivos_largo","label":"¿Y en el mediano/largo plazo (5-15 años)?","tipo":"parrafo","requerido":true},
       {"key":"que_esperas","label":"¿Qué esperás lograr trabajando en tu plan financiero?","tipo":"parrafo","requerido":true},
       {"key":"preocupacion","label":"¿Qué te preocupa más hoy de tus finanzas?","tipo":"parrafo","requerido":true},
       {"key":"areas_ayuda","label":"¿En qué áreas sentís que necesitás más ayuda? (ej: control de gastos, inversiones, planificación de jubilación, deudas, impuestos)","tipo":"parrafo","requerido":true}]}
   ]},

  {"key":"perfil_inversor","tipo":"formulario","titulo":"Paso 3: Perfil inversor",
   "texto":"Esta información me ayuda a conocerte mejor a la hora de invertir :) No hay respuestas correctas, solo quiero conocerte más.",
   "tiempo":"5 a 7 minutos","casilla":"x_ob_formularios",
   "secciones":[{"campos":[
     {"key":"nombre_apellido","label":"Nombre y apellido","tipo":"texto","requerido":true},
     {"key":"experiencia","label":"¿Tenés experiencia invirtiendo? ¿En qué instrumentos?","tipo":"casillas","requerido":true,"opciones":["Acciones","Fondos comunes de inversión","Bonos","No tengo experiencia / solo dólar o plazo fijo","Cripto","Otros"]},
     {"key":"objetivo","label":"¿Cuál es tu objetivo principal al invertir?","tipo":"opcion","requerido":true,"opciones":["Proteger capital","Crecer capital","Ingresos pasivos"]},
     {"key":"plazo","label":"¿Durante cuánto tiempo podés mantener una inversión sin necesidad de retirarla?","tipo":"texto","requerido":true},
     {"key":"tolera_perdida","label":"¿Estás dispuesto/a a perder parte de tu inversión a corto plazo si hay potencial de ganancia a largo plazo?","tipo":"texto","requerido":true},
     {"key":"porcentaje_capital","label":"¿Qué porcentaje de tu capital total estás dispuesto/a a invertir?","tipo":"opcion","requerido":true,"opciones":["0-20%","20-40%","40-60%","60% o más"]},
     {"key":"caida_30","label":"¿Qué harías si una inversión baja un 30% en poco tiempo?","tipo":"texto","requerido":true},
     {"key":"aportes","label":"¿Vas a hacer aportes periódicos? ¿De cuánto y con qué frecuencia?","tipo":"parrafo","requerido":true},
     {"key":"preferencia_moneda","label":"¿Tenés preferencia por inversiones en pesos, dólares, cripto, o acciones?","tipo":"texto"},
     {"key":"activos_excluidos","label":"¿Hay activos o sectores en los que no quieras invertir por principios o nivel de riesgo?","tipo":"parrafo","requerido":true},
     {"key":"rentabilidad","label":"¿Qué rentabilidad en dólares anual esperás obtener? (realista, no ideal)","tipo":"parrafo","requerido":true}
   ]}]},

  {"key":"hoja_de_ruta","tipo":"video","titulo":"Iniciación a Blueprint: Hoja de ruta",
   "texto":"Un último video para que sepas cómo sigue el camino dentro del programa. Te recomendamos verlo antes de seguir.",
   "url":"https://www.loom.com/share/23ad07256fbb429eb0af42b44e94c2b5",
   "obligatorio":false,"boton":"Continuar"},

  {"key":"accesos","tipo":"acceso","titulo":"Último paso: tus accesos",
   "texto":"Entrá a cada uno desde su botón y, cuando lo hayas hecho, tocá “Ya lo hice”.",
   "enlaces":[
     {"key":"whatsapp_grupo","label":"Unite al grupo de WhatsApp","url":"https://chat.whatsapp.com/Knad3NZG4LgHKu9s7xX7gF","boton":"Abrir el grupo","casilla":"x_ob_wpp"},
     {"key":"skool","label":"Entrá a la plataforma Skool","url":"https://www.skool.com/blueprint-financiero-3945/about?ref=9285ea556ef24f2e8f1bb6b588ee2ceb","boton":"Abrir Skool","casilla":"x_unio_school"},
     {"key":"escribir_liam","label":"Escribile por WhatsApp a Liam","url":"https://wa.me/message/ZDXQYORY7FJQG1","boton":"Escribirle a Liam","casilla":"x_ob_escribio"}
   ]},

  {"key":"final","tipo":"final","titulo":"¡Felicitaciones! Completaste el onboarding",
   "texto":"Ya está todo listo. Tus respuestas llegaron al equipo y vamos a ponernos en contacto con vos para empezar. Si tenés alguna duda, escribile a Liam por WhatsApp."}
]$j$::jsonb;

-- ---------- Variante Grupal ----------
-- La pregunta 18 ("Qué fue lo último que te convenció...") queda SIN ayuda: en
-- el formulario original la ayuda traía tres ejemplos que no se pudieron
-- cargar y no se inventan. Cuando se tengan, agregar "ayuda" a ese campo.
  v_grupal jsonb := $j$[
  {"key":"bienvenida","tipo":"video","titulo":"Bienvenido a Blueprint Financiero",
   "texto":"Gracias por sumarte a Blueprint Financiero. En este video te explicamos todo el proceso paso a paso. Te recomendamos verlo completo antes de seguir.",
   "url":"https://www.loom.com/share/ee9aaaeaea5747808b8ac8be1a1c4cbd","duracion_seg":360,
   "obligatorio":false,
   "tiempo":"6 minutos","casilla":"x_ob_video","boton":"Continuar"},

  {"key":"formulario_onboarding","tipo":"formulario","titulo":"Onboarding Liam Wickham",
   "texto":"Este es un formulario obligatorio para comenzar tu proceso conmigo. Completalo con toda la información solicitada para que podamos avanzar con tu ingreso. Te va a llevar solo unos minutos.",
   "tiempo":"unos minutos","casilla":"x_ob_formularios",
   "secciones":[
     {"titulo":"Tus datos","campos":[
       {"key":"nombre","label":"Nombre","tipo":"texto","requerido":true,"contacto":"nombre"},
       {"key":"apellido","label":"Apellido","tipo":"texto","requerido":true,"contacto":"apellido"},
       {"key":"telefono","label":"Número de teléfono (con prefijo)","tipo":"texto","requerido":true,"contacto":"telefono"},
       {"key":"mail","label":"Mail","tipo":"texto","requerido":true,"contacto":"email"}]},
     {"titulo":"Cómo llegaste a Liam","campos":[
       {"key":"identificado","label":"¿Con cuál de estos te sentís más identificado?","tipo":"casillas","requerido":true,"opciones":["Estoy empezando de cero con las inversiones","Tengo algo de noción de inversiones pero nunca invertí","Estoy invirtiendo pero sin un criterio claro","Tengo un criterio y entiendo lo que hago pero quiero mejores resultados","Otros"]},
       {"key":"como_conociste","label":"¿Por dónde me conociste?","tipo":"casillas","requerido":true,"opciones":["Instagram","YouTube","TikTok","Recomendación (te enviaron mi contenido)","Otros"]},
       {"key":"formato","label":"¿Qué formato de mi contenido te aporta o te gusta más?","tipo":"casillas","requerido":true,"opciones":["Reels","Historias","YouTube","TikTok","Otros"]},
       {"key":"por_que_formato","label":"¿Por qué elegiste ese formato?","tipo":"parrafo","requerido":true},
       {"key":"temas","label":"¿Qué temas te gustaría que hable en el contenido?","tipo":"casillas","requerido":true,"opciones":["Cómo empezar a invertir","Cómo ordenar tus finanzas personales","Cómo elegir acciones que superen al SP500","Qué acciones comprar y cuáles vender","Estrategia de Crypto","Contenido de mentalidad en las inversiones","Cómo armar un portfolio de jubilación","Otros"]}]},
     {"titulo":"Tu decisión de entrar","campos":[
       {"key":"que_te_hizo_decir_si","label":"¿Qué te hizo finalmente decir \"SÍ\" y entrar a trabajar conmigo?","tipo":"casillas","requerido":true,"opciones":["Me diste confianza en el contenido","La información que vi dentro del programa","La claridad que me pueden dar","Tu estilo de vida","Validación de otras personas","Los casos de éxito","Otros"]},
       {"key":"motivo_accion","label":"¿Qué te motivó específicamente a tomar acción?","ayuda":"Desarrollá tu respuesta anterior (es clave para entender cómo ayudarte)","tipo":"parrafo"},
       {"key":"que_esperas","label":"¿Qué es lo que esperás de nosotros?","tipo":"parrafo","requerido":true},
       {"key":"tiempo_decision","label":"¿Cuánto tiempo tardaste en decidirte a trabajar con nosotros?","tipo":"opcion","opciones":["1 mes","1 a 3 meses","3 a 6 meses","Más de 6 meses"]},
       {"key":"que_habria_funcionado","label":"¿Qué crees que podría haber funcionado mejor para que te decidieras a hacerlo antes?","tipo":"casillas","opciones":["Mejor llamada de venta","Mejor proceso de agenda","Más frecuencia de contenido","Más temas/ángulos en el contenido","Más testimonios/casos de éxito","Conocer más la vida personal de Liam","Conocer más el producto/programa por dentro"]},
       {"key":"que_mejorar","label":"¿Qué aspecto del punto que elegiste antes creés que se podría mejorar?","ayuda":"Claridad en lo que ofrecen, producto por dentro, más contenido de valor, comunicación, etc.","tipo":"parrafo"},
       {"key":"problemas_principales","label":"¿Cuáles eran tus problemas principales cuando buscaste ayuda?","ayuda":"Podés elegir varias","tipo":"casillas","opciones":["Invertir por emociones","Me estafaron previamente","Estaba invirtiendo con un asesor financiero del broker y tenía malos resultados","Tengo plata parada y pierde valor","Falta de claridad sobre cómo tomar decisiones","Desorganización en finanzas personales","No sabía qué hacer con mi portfolio actual","Tuve una herencia/indemnización y no sabía qué hacer con eso"]},
       {"key":"conviccion_previa","label":"Antes de la llamada, ¿qué tan convencido estabas de ingresar, en una escala del 1 al 10?","tipo":"escala_1_10","extremos":["Poco interés en trabajar con ustedes","Súper convencido"]},
       {"key":"ultimo_empujon","label":"¿Qué fue lo último que te convenció para tomar la decisión?","tipo":"parrafo"},
       {"key":"que_impedia","label":"¿Qué fue lo que impedía que compraras?","tipo":"opcion","opciones":["Precio","Confianza","Tiempo","Falta de claridad en el servicio"]}]},
     {"titulo":"Tu situación y tus objetivos","campos":[
       {"key":"otras_mentorias","label":"¿Antes de entrar a trabajar con Liam habías estado en otras mentorías o servicios? ¿Con quién? ¿Qué experiencia tuviste?","tipo":"parrafo"},
       {"key":"top_3_problemas","label":"¿Cuáles son tus top 3 problemas que querés solucionar conmigo y mi equipo?","tipo":"parrafo"},
       {"key":"objetivo_principal","label":"¿Cuál es tu principal objetivo dentro de la consultoría?","tipo":"parrafo"}]}
   ]},

  {"key":"accesos","tipo":"acceso","titulo":"Último paso: tu acceso a Skool",
   "texto":"Entrá a Skool desde el botón y, cuando lo hayas hecho, tocá “Ya lo hice”.",
   "enlaces":[
     {"key":"skool","label":"Entrá a la plataforma Skool","url":"https://www.skool.com/blueprint-financiero-3945/about?ref=9285ea556ef24f2e8f1bb6b588ee2ceb","boton":"Abrir Skool","casilla":"x_unio_school"}
   ]},

  {"key":"final","tipo":"final","titulo":"¡Felicitaciones! Completaste el onboarding",
   "texto":"Ya está todo listo. Tus respuestas llegaron al equipo y vamos a ponernos en contacto con vos para empezar."}
]$j$::jsonb;
begin
  if not exists (select 1 from public.cs_programas where id = 'liam') then
    return;   -- ya avisó el autochequeo
  end if;

  v_motivo := public.cs_validar_onboarding_pasos_motivo(v_1a1);
  if v_motivo is not null then
    raise exception 'cs 093: la plantilla 1a1 de liam no pasa la validación: %', v_motivo;
  end if;
  insert into public.cs_onboarding_plantillas (programa_id, clave, nombre, mentor, validez_dias, pasos)
  values ('liam', '1a1', 'Onboarding 1 a 1', 'Liam Wickham', 30, v_1a1)
  on conflict (programa_id, clave) do update
    set nombre = excluded.nombre, mentor = excluded.mentor, validez_dias = excluded.validez_dias,
        pasos = excluded.pasos, activa = true, updated_at = now();

  v_motivo := public.cs_validar_onboarding_pasos_motivo(v_grupal);
  if v_motivo is not null then
    raise exception 'cs 093: la plantilla grupal de liam no pasa la validación: %', v_motivo;
  end if;
  insert into public.cs_onboarding_plantillas (programa_id, clave, nombre, mentor, validez_dias, pasos)
  values ('liam', 'grupal', 'Onboarding Grupal', 'Liam Wickham', 30, v_grupal)
  on conflict (programa_id, clave) do update
    set nombre = excluded.nombre, mentor = excluded.mentor, validez_dias = excluded.validez_dias,
        pasos = excluded.pasos, activa = true, updated_at = now();
end
$seed$;

-- ---------- Asignación a productos (nombre exacto) ----------
-- 1 a 1: los tres productos 1-1. Grupal: BPF Grupal, que cubre "Grupal Anual" y
-- "Grupal 4 meses": un solo producto y una sola plantilla ('grupal'). Lo que no
-- coincida queda sin asignar y se ve en el control Q01 de la 093b.
insert into public.cs_onboarding_plantilla_productos (producto_id, programa_id, plantilla_id)
select pr.id, pr.programa_id, pl.id
from public.cs_productos pr
join public.cs_onboarding_plantillas pl
  on pl.programa_id = pr.programa_id
 and pl.clave = case when pr.nombre in ('BPF 1-1 4 Meses', 'BPF 1-1 6 Meses', 'BPF 1-1 12 Meses') then '1a1'
                     when pr.nombre = 'BPF Grupal' then 'grupal' end
where pr.programa_id = 'liam'
  and pr.nombre in ('BPF 1-1 4 Meses', 'BPF 1-1 6 Meses', 'BPF 1-1 12 Meses', 'BPF Grupal')
on conflict (producto_id) do update set plantilla_id = excluded.plantilla_id;

commit;
