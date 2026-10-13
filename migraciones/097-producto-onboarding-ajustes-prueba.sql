-- =====================================================================
-- 097-producto-onboarding-ajustes-prueba.sql  ·  PRODUCTO, ajustes tras probar la 096
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), DESPUÉS de
-- probarla en un banco de pruebas con la 093 y la 096 aplicadas. Numeración
-- global: este número lo asignó el jefe. Los controles van en
-- 097b-producto-onboarding-ajustes-control.sql (consultas sueltas, de a una).
-- Evitar los minutos :00, :15, :30 y :45 (sync de Finanzas) y las 9:00.
--
-- Requiere: 093 (onboarding por link), 096 (paso como_nos_conociste, Otros con
-- texto libre, cs_ob_es_closer, cs_onboarding_lista), 079 (cs_puede_ver), 070
-- (cs_norm_tel).
--
-- Qué hace
--   1. Respaldo (tablas normales) de lo que pisa: la plantilla 1a1 de liam y la
--      definición de las funciones que reemplaza.
--   2. cs_onboarding_link_estado_closer(programa, telefono, nombre): lectura pura
--      para Ventas. Dice si el alumno tiene alta y link SIN generar nada ni
--      devolver el token. Busca igual que cs_onboarding_link_closer (093).
--   3. Plantilla 1a1 de liam: "problemas_principales" pasa de opción única a
--      casillas (varias). La Grupal ya lo tenía como casillas (093): no se toca.
--      Las respuestas ya guardadas como texto NO se convierten ni se borran.
--   4. cs_ob_limpiar (validación del servidor al guardar un paso):
--        - casillas acepta un texto suelto (borradores viejos) como una sola opción;
--        - si "Otros" está elegido y no hay texto, al ENVIAR el paso da error
--          ("Falta completar: ..."); en borrador no frena;
--        - un campo contacto = telefono se valida al enviar: solo dígitos, +, (),
--          puntos, espacios y guiones, con 8 a 15 dígitos.
--   5. cs_ob_armar_estado: agrega "contacto" (nombre, email y teléfono del propio
--      alumno) solo mientras queda un paso con campos de contacto sin completar.
--      Sirve para precargar el paso "Datos de contacto".
--   6. cs_onboarding_lista: Skool y WhatsApp salen null (no se evalúan) si la
--      plantilla del alumno no pide ese acceso. Resuelve "Falta WhatsApp" en un
--      Grupal, cuyo onboarding solo pide Skool.
--
-- Qué NO hace: no borra nada; no toca alumnos, onboardings, progreso ni
-- respuestas; no vuelve a correr la 093 ni la 096; la plantilla Grupal queda igual.
-- Pisa: el campo problemas_principales de la plantilla 1a1 de liam (respaldada) y
-- 3 funciones (respaldadas): cs_ob_limpiar, cs_ob_armar_estado, cs_onboarding_lista.
-- Crea 1 función nueva y 2 tablas de respaldo.
--
-- Re-ejecutable: si el campo ya es casillas no lo toca; los respaldos se hacen una
-- sola vez (conservan el original de la 096); las funciones son create or replace.
-- Si falla: el mensaje empieza con "cs 097:". Nada queda aplicado (una transacción).
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- 0. DIAGNÓSTICO Y GUARDAS (antes de crear o tocar nada)
-- ---------------------------------------------------------------------
do $chk$
declare
  v_falta       text;
  v_tipo        text;
  v_esperado_tipo_antes   constant text := 'opcion';
  v_esperado_tipo_despues constant text := 'casillas';
  v_esperado_plantillas_1a1 constant int := 1;
  v_n           int;
begin
  select string_agg(r.t, ', ' order by r.t) into v_falta
    from (values ('cs_programas'), ('cs_productos'), ('cs_clientes'), ('cs_maestro_columnas'),
                 ('cs_onboarding_plantillas'), ('cs_onboarding_plantilla_productos'),
                 ('cs_onboardings'), ('cs_onboarding_respuestas'),
                 ('crm_members'), ('crm_asignaciones')) as r(t)
   where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 097: faltan tablas: %. Tienen que estar corridas la 093 y la 096.', v_falta;
  end if;

  select string_agg(f, ', ' order by f) into v_falta
    from unnest(array[
           'public.cs_norm_tel(text)', 'public.cs_ob_nombre_clave(text)',
           'public.cs_ob_es_closer(text)', 'public.cs_ob_limpiar(jsonb, jsonb, boolean)',
           'public.cs_ob_armar_estado(uuid)', 'public.cs_onboarding_lista(text)',
           'public.cs_validar_onboarding_pasos(jsonb)',
           'public.cs_validar_onboarding_pasos_motivo(jsonb)',
           'public.cs_validar_onboarding_otros(jsonb)',
           'public.cs_onboarding_link_closer(text, text, text)',
           'public.cs_ob_hechos_est(text, jsonb, jsonb)', 'public.cs_ob_progreso_ultimo(jsonb)',
           'public.cs_ob_total(jsonb)', 'public.cs_ob_actual(jsonb, jsonb)',
           'auth.uid()']) as f
   where to_regprocedure(f) is null;
  if v_falta is not null then
    raise exception 'cs 097: faltan funciones: %. La 096 no está aplicada completa (control Q00 de la 096b).', v_falta;
  end if;

  -- La plantilla 1a1 de liam tiene que tener el paso de la 096 y el campo como
  -- lo dejó la 096 (opcion) o ya cambiado (casillas, re-ejecución).
  select count(*) into v_n from public.cs_onboarding_plantillas where programa_id = 'liam' and clave = '1a1';
  if v_n <> v_esperado_plantillas_1a1 then
    raise exception 'cs 097: se esperaba % plantilla 1a1 de liam y hay %.', v_esperado_plantillas_1a1, v_n;
  end if;
  select c.value ->> 'tipo' into v_tipo
    from public.cs_onboarding_plantillas p,
         jsonb_array_elements(p.pasos) e,
         jsonb_array_elements(coalesce(e -> 'secciones', '[]'::jsonb)) s,
         jsonb_array_elements(coalesce(s -> 'campos', '[]'::jsonb)) c
   where p.programa_id = 'liam' and p.clave = '1a1'
     and e ->> 'key' = 'como_nos_conociste'
     and c.value ->> 'key' = 'problemas_principales';
  if v_tipo is null then
    raise exception 'cs 097: la plantilla 1a1 de liam no tiene el paso como_nos_conociste con el campo problemas_principales (¿falta la 096?).';
  end if;
  if v_tipo not in (v_esperado_tipo_antes, v_esperado_tipo_despues) then
    raise exception 'cs 097: problemas_principales tiene tipo [%] y se esperaba [%] o [%]. Alguien la editó a mano.',
      v_tipo, v_esperado_tipo_antes, v_esperado_tipo_despues;
  end if;
end
$chk$;

-- Locks juntos y primero (regla del deadlock). Si no los consigue en 8 s, aborta limpio.
lock table public.cs_onboarding_plantillas in share row exclusive mode;


-- =====================================================================
-- 1. RESPALDO
-- =====================================================================
-- Tablas normales (no temporales): sobreviven a la transacción. Solo la primera
-- corrida respalda (conserva siempre el original de la 096).
create table if not exists public.cs_bak_097_plantillas as
  select now() as respaldado_at, p.* from public.cs_onboarding_plantillas p where false;

create table if not exists public.cs_bak_097_funciones (
  nombre        text primary key,
  definicion    text not null,
  respaldado_at timestamptz not null default now()
);

alter table public.cs_bak_097_plantillas enable row level security;
alter table public.cs_bak_097_funciones  enable row level security;
revoke all on table public.cs_bak_097_plantillas from public, anon, authenticated;
revoke all on table public.cs_bak_097_funciones  from public, anon, authenticated;

insert into public.cs_bak_097_plantillas
select now(), p.*
  from public.cs_onboarding_plantillas p
 where p.programa_id = 'liam' and p.clave = '1a1'
   and not exists (select 1 from public.cs_bak_097_plantillas b where b.id = p.id);

insert into public.cs_bak_097_funciones (nombre, definicion)
select f.n, pg_get_functiondef(to_regprocedure('public.' || f.n))
  from unnest(array[
         'cs_ob_limpiar(jsonb, jsonb, boolean)', 'cs_ob_armar_estado(uuid)', 'cs_onboarding_lista(text)'
       ]) as f(n)
on conflict (nombre) do nothing;


-- =====================================================================
-- 2. PLANTILLA 1 A 1 DE LIAM: problemas_principales = casillas
-- =====================================================================
do $paso$
declare
  v_pl     public.cs_onboarding_plantillas;
  v_nuevos jsonb;
  v_motivo text;
begin
  select * into v_pl from public.cs_onboarding_plantillas where programa_id = 'liam' and clave = '1a1';

  if not exists (
       select 1
         from jsonb_array_elements(v_pl.pasos) e,
              jsonb_array_elements(coalesce(e -> 'secciones', '[]'::jsonb)) s,
              jsonb_array_elements(coalesce(s -> 'campos', '[]'::jsonb)) c
        where e ->> 'key' = 'como_nos_conociste'
          and c.value ->> 'key' = 'problemas_principales'
          and c.value ->> 'tipo' = 'opcion') then
    raise notice 'cs 097: problemas_principales ya es casillas: la plantilla no se toca.';
    return;
  end if;

  -- Reconstruye pasos -> secciones -> campos cambiando solo el tipo de ese campo.
  select jsonb_agg(
           case when e.value ->> 'key' = 'como_nos_conociste'
                then jsonb_set(e.value, '{secciones}', (
                       select jsonb_agg(
                                jsonb_set(s.value, '{campos}', (
                                  select jsonb_agg(
                                           case when c.value ->> 'key' = 'problemas_principales'
                                                then jsonb_set(c.value, '{tipo}', '"casillas"'::jsonb)
                                                else c.value end
                                           order by c.ord)
                                    from jsonb_array_elements(s.value -> 'campos') with ordinality as c(value, ord)))
                                order by s.ord)
                         from jsonb_array_elements(e.value -> 'secciones') with ordinality as s(value, ord)))
                else e.value end
           order by e.ord)
    into v_nuevos
    from jsonb_array_elements(v_pl.pasos) with ordinality as e(value, ord);

  v_motivo := coalesce(public.cs_validar_onboarding_pasos_motivo(v_nuevos), public.cs_validar_onboarding_otros(v_nuevos));
  if v_motivo is not null then
    raise exception 'cs 097: la plantilla 1a1 de liam con el campo en casillas no pasa la validación: %', v_motivo;
  end if;
  if jsonb_array_length(v_nuevos) <> jsonb_array_length(v_pl.pasos) then
    raise exception 'cs 097: la reconstrucción de la plantilla cambió la cantidad de pasos (% a %)',
      jsonb_array_length(v_pl.pasos), jsonb_array_length(v_nuevos);
  end if;

  update public.cs_onboarding_plantillas
     set pasos = v_nuevos, updated_at = now()
   where id = v_pl.id;
  raise notice 'cs 097: problemas_principales de la plantilla 1a1 de liam ahora es casillas.';
end
$paso$;


-- =====================================================================
-- 3. cs_ob_limpiar: casillas con texto viejo, "Otros" obligatorio, teléfono
-- =====================================================================
-- Igual que la de la 096 + los tres cambios marcados con (097).
create or replace function public.cs_ob_limpiar(p_paso jsonb, p_resp jsonb, p_completo boolean)
returns jsonb
language plpgsql immutable set search_path = public
as $fn$
declare
  s        jsonb;
  c        jsonb;
  v_out    jsonb := '{}'::jsonb;
  v_key    text;
  v_tipo   text;
  v_val    jsonb;
  v_txt    text;
  v_req    boolean;
  v_lab    text;
  v_lim    int;
  v_otro   text;
  v_elegido boolean;
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
        -- (097) Teléfono: se exige bien formado al enviar el paso (en borrador no frena).
        if p_completo and (c->>'contacto') = 'telefono' then
          if v_txt !~ '^[0-9+().[:space:]-]+$'
             or char_length(regexp_replace(v_txt, '[^0-9]', '', 'g')) not between 8 and 15 then
            raise exception 'Revisá el teléfono: escribilo con prefijo, solo con números, +, espacios o guiones (mínimo 8 dígitos).'
              using errcode = 'P0001';
          end if;
        end if;
        v_out := v_out || jsonb_build_object(v_key, v_txt);

      elsif v_tipo = 'opcion' then
        if jsonb_typeof(v_val) <> 'string'
           or not exists (select 1 from jsonb_array_elements_text(c->'opciones') o where o = btrim(v_val #>> '{}')) then
          raise exception 'Revisá este campo: %', v_lab using errcode = 'P0001';
        end if;
        v_out := v_out || jsonb_build_object(v_key, btrim(v_val #>> '{}'));

      elsif v_tipo = 'casillas' then
        -- (097) Un texto suelto (respuesta o borrador de cuando era opción única)
        -- se toma como una sola opción elegida.
        if jsonb_typeof(v_val) = 'string' then
          v_val := jsonb_build_array(btrim(v_val #>> '{}'));
        end if;
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

      -- "Otros" con texto libre: solo cuenta si esa opción quedó elegida.
      if v_tipo in ('opcion', 'casillas') and coalesce(c->>'otro', '') <> '' then
        v_otro := nullif(btrim(coalesce(p_resp ->> (v_key || '_otro'), '')), '');
        v_elegido := (v_tipo = 'opcion' and (v_out ->> v_key) = (c->>'otro'))
                     or (v_tipo = 'casillas' and exists (select 1 from jsonb_array_elements_text(v_out -> v_key) x
                                                          where x = (c->>'otro')));
        -- (097) Elegida "Otros" sin texto: al enviar el paso es error.
        if coalesce(v_elegido, false) and v_otro is null and p_completo then
          raise exception 'Falta completar: escribí tu respuesta en "%" (%)', c->>'otro', v_lab
            using errcode = 'P0001';
        end if;
        if v_otro is not null then
          if char_length(v_otro) > 300 then
            raise exception 'Revisá este campo (muy largo): %', v_lab using errcode = 'P0001';
          end if;
          if coalesce(v_elegido, false) then
            v_out := v_out || jsonb_build_object(v_key || '_otro', v_otro);
          end if;
        end if;
      end if;
    end loop;
  end loop;
  return v_out;
end;
$fn$;


-- =====================================================================
-- 4. cs_ob_armar_estado: datos de contacto del propio alumno
-- =====================================================================
-- Igual que la de la 093 + "contacto" (097). Solo mientras haya un paso con
-- campos de contacto sin completar; cuando todos están hechos no sale.
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
  v_contacto jsonb;
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

  -- (097) Nombre, mail y teléfono del propio alumno (nada más de la ficha), solo
  -- si queda un formulario con campos de contacto por completar.
  select jsonb_build_object('nombre', c.nombre, 'email', c.email, 'telefono', c.telefono)
    into v_contacto
    from public.cs_clientes c
   where c.id = o.cliente_id
     and exists (
           select 1
             from jsonb_array_elements(pl.pasos) as st(v),
                  jsonb_array_elements(coalesce(st.v -> 'secciones', '[]'::jsonb)) as se(v),
                  jsonb_array_elements(coalesce(se.v -> 'campos', '[]'::jsonb)) as ca(v)
            where coalesce(ca.v ->> 'contacto', '') <> ''
              and (o.progreso -> (st.v ->> 'key') ->> 'completado_at') is null);

  return v_base || jsonb_build_object(
    'estado', 'ok',
    'pasos',  pl.pasos,
    'actual', public.cs_ob_actual(pl.pasos, o.progreso),
    'contacto', v_contacto,
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
-- 5. cs_onboarding_lista: accesos según la plantilla del alumno
-- =====================================================================
-- Igual que la de la 096. Cambia solo skool y wpp: null (no se muestra ni se
-- evalúa) si la plantilla del alumno no tiene un enlace con esa casilla, además
-- de si la columna no existe en el Maestro del programa.
create or replace function public.cs_onboarding_lista(p_programa text)
returns table (
  cliente_id        uuid,
  nombre            text,
  estado_cliente    text,
  producto_id       uuid,
  producto          text,
  resell            boolean,
  fecha_alta        date,
  onboarding        text,
  hechos            int,
  total             int,
  paso_actual       text,
  ultimo_movimiento timestamptz,
  link_vence_at     timestamptz,
  skool             boolean,
  wpp               boolean
)
language plpgsql stable security definer set search_path = public
as $fn$
begin
  if p_programa is null or not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: no tenés acceso a este programa' using errcode = '42501';
  end if;
  return query
  select c.id, c.nombre, c.estado, c.producto_id, pr.nombre,
         coalesce((c.campos_extra -> 'x_resell') = 'true'::jsonb, false),
         c.fecha_inicio,
         case when o.id is not null then o.estado
              when pl.id is null then 'sin_plantilla'
              else 'sin_link' end,
         case when o.id is null or pl.id is null then 0
              else public.cs_ob_hechos_est(o.estado, pl.pasos, o.progreso) end,
         case when pl.id is null then null else public.cs_ob_total(pl.pasos) end,
         case when o.id is not null and o.estado <> 'completado'
              then (pl.pasos -> public.cs_ob_actual(pl.pasos, o.progreso)) ->> 'titulo'
              else null end,
         case when o.id is null then null
              else greatest(public.cs_ob_progreso_ultimo(o.progreso), o.abierto_at, o.iniciado_at, o.completado_at,
                            (select max(r.updated_at) from public.cs_onboarding_respuestas r
                              where r.onboarding_id = o.id)) end,
         o.vence_at,
         -- (097) solo si la plantilla pide Skool Y la columna existe en el Maestro
         case when pl.id is not null
                   and exists (select 1
                                 from jsonb_array_elements(pl.pasos) as st(v),
                                      jsonb_array_elements(coalesce(st.v -> 'enlaces', '[]'::jsonb)) as en(v)
                                where en.v ->> 'casilla' = 'x_unio_school')
                   and exists (select 1 from public.cs_maestro_columnas m
                                where m.programa_id = c.programa_id and m.clave = 'x_unio_school' and not m.archivada)
              then coalesce((c.campos_extra -> 'x_unio_school') = 'true'::jsonb, false)
              else null end,
         -- (097) idem WhatsApp
         case when pl.id is not null
                   and exists (select 1
                                 from jsonb_array_elements(pl.pasos) as st(v),
                                      jsonb_array_elements(coalesce(st.v -> 'enlaces', '[]'::jsonb)) as en(v)
                                where en.v ->> 'casilla' = 'x_ob_wpp')
                   and exists (select 1 from public.cs_maestro_columnas m
                                where m.programa_id = c.programa_id and m.clave = 'x_ob_wpp' and not m.archivada)
              then coalesce((c.campos_extra -> 'x_ob_wpp') = 'true'::jsonb, false)
              else null end
    from public.cs_clientes c
    left join public.cs_productos pr on pr.id = c.producto_id
    left join public.cs_onboardings o on o.cliente_id = c.id
    left join public.cs_onboarding_plantilla_productos pp on pp.producto_id = c.producto_id
    left join public.cs_onboarding_plantillas pl on pl.id = coalesce(o.plantilla_id, pp.plantilla_id)
   where c.programa_id = p_programa
     and c.estado not in ('finalizado', 'baja')
   order by c.fecha_inicio desc, c.nombre;
end;
$fn$;


-- =====================================================================
-- 6. VENTAS: ESTADO DEL ALUMNO SIN GENERAR NADA
-- =====================================================================
-- Solo lectura (stable, ningún insert/update). Mismas restricciones que
-- cs_onboarding_link_closer: rol ventas o closer con el programa asignado
-- (cs_ob_es_closer) y la MISMA búsqueda del alumno (últimos 8 dígitos del
-- teléfono normalizado o nombre normalizado sin orden, entre alumnos activos),
-- para que las dos funciones nunca se contradigan. No devuelve el token.
--
-- Devuelve siempre un objeto con estas claves:
--   alta           bool   hay un alumno que coincide (activo o no)
--   inactivo       bool   el que coincide está finalizado o dado de baja (con
--                         alta=true; cs_onboarding_link_closer da ALUMNO_INACTIVO)
--   tiene_link     bool   existe su onboarding (link generado)
--   estado         text   pendiente | en_curso | completado; null si no hay link
--   vence_at       timestamptz  null si no hay link
--   vencido        bool   el link existe, no está completado y ya venció
--                         (cs_onboarding_link_closer lo renueva)
--   alumno         text   primer nombre; null si no hay alta
--   producto       text   nombre del producto; null si no hay alta o producto
--   con_onboarding bool   su producto tiene plantilla activa (false: link_closer
--                         fallaría con PRODUCTO_SIN_ONBOARDING / sin producto)
-- Errores: 42501 SIN_PERMISO, 22023 DATOS_INVALIDOS (sin teléfono ni nombre),
-- 23505 (más de un alumno activo coincide, igual que link_closer).
create or replace function public.cs_onboarding_link_estado_closer(
  p_programa text,
  p_telefono text,
  p_nombre   text default null
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_tel      text := public.cs_norm_tel(p_telefono);
  v_nom      text := public.cs_ob_nombre_clave(p_nombre);
  v_ids      uuid[];
  v_c        public.cs_clientes;
  v_o        public.cs_onboardings;
  v_inactivo boolean := false;
  v_prod     text;
  v_con      boolean := false;
begin
  if auth.uid() is null or not public.cs_ob_es_closer(p_programa) then
    raise exception 'SIN_PERMISO: no tenés permiso para este cliente' using errcode = '42501', hint = 'SIN_PERMISO';
  end if;
  if v_tel is null and v_nom is null then
    raise exception 'DATOS_INVALIDOS: pasá el teléfono del alumno (o su nombre) para encontrarlo'
      using errcode = '22023', hint = 'DATOS_INVALIDOS';
  end if;

  -- Misma condición que cs_onboarding_link_closer (093).
  select array_agg(c.id) into v_ids
    from public.cs_clientes c
   where c.programa_id = p_programa
     and c.estado not in ('finalizado', 'baja')
     and ((v_tel is not null and public.cs_norm_tel(c.telefono) = v_tel)
          or (v_nom is not null and public.cs_ob_nombre_clave(c.nombre) = v_nom));

  if v_ids is not null and cardinality(v_ids) > 1 then
    raise exception 'cs: hay más de un alumno que coincide con esos datos: avisale a Producto' using errcode = '23505';
  end if;

  if v_ids is not null then
    select * into v_c from public.cs_clientes where id = v_ids[1];
  else
    -- Sin activos: ¿hay uno finalizado o dado de baja? (el más reciente)
    select c.* into v_c
      from public.cs_clientes c
     where c.programa_id = p_programa
       and c.estado in ('finalizado', 'baja')
       and ((v_tel is not null and public.cs_norm_tel(c.telefono) = v_tel)
            or (v_nom is not null and public.cs_ob_nombre_clave(c.nombre) = v_nom))
     order by c.fecha_inicio desc nulls last, c.id
     limit 1;
    v_inactivo := v_c.id is not null;
  end if;

  if v_c.id is null then
    return jsonb_build_object(
      'alta', false, 'inactivo', false, 'tiene_link', false, 'estado', null,
      'vence_at', null, 'vencido', false, 'alumno', null, 'producto', null,
      'con_onboarding', false);
  end if;

  select pr.nombre into v_prod from public.cs_productos pr where pr.id = v_c.producto_id;
  v_con := exists (select 1
                     from public.cs_onboarding_plantilla_productos pp
                     join public.cs_onboarding_plantillas pl on pl.id = pp.plantilla_id
                    where pp.producto_id = v_c.producto_id and pl.activa);
  select * into v_o from public.cs_onboardings where cliente_id = v_c.id;

  return jsonb_build_object(
    'alta',           true,
    'inactivo',       v_inactivo,
    'tiene_link',     v_o.id is not null,
    'estado',         v_o.estado,
    'vence_at',       v_o.vence_at,
    'vencido',        coalesce(v_o.id is not null and v_o.estado <> 'completado' and v_o.vence_at < now(), false),
    'alumno',         split_part(btrim(v_c.nombre), ' ', 1),
    'producto',       v_prod,
    'con_onboarding', v_con);
end;
$fn$;


-- =====================================================================
-- 7. PERMISOS
-- =====================================================================
-- cs_ob_limpiar y cs_ob_armar_estado son internas; cs_onboarding_lista la usa la
-- app. create or replace conserva los permisos de la 093 y la 096: se vuelven a
-- afirmar por si algo se tocó a mano.
revoke all on function
  public.cs_ob_limpiar(jsonb, jsonb, boolean),
  public.cs_ob_armar_estado(uuid),
  public.cs_onboarding_lista(text),
  public.cs_onboarding_link_estado_closer(text, text, text)
from public, anon, authenticated;

grant execute on function
  public.cs_onboarding_lista(text),
  public.cs_onboarding_link_estado_closer(text, text, text)
to authenticated;

commit;
