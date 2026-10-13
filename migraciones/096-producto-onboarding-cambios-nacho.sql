-- =====================================================================
-- 096-producto-onboarding-cambios-nacho.sql  ·  PRODUCTO, cambios de la reunión del 12/10
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), DESPUÉS de
-- probarla en un banco de pruebas. Numeración global: este número lo asignó el
-- jefe. Los controles van en 096b-producto-onboarding-cambios-control.sql
-- (consultas sueltas, de a una).
-- Evitar los minutos :00, :15, :30 y :45 (sync de Finanzas) y las 9:00.
--
-- Requiere: 093 (todo el onboarding por link), 071 (campos_extra,
-- cs_maestro_columnas), 079 (cs_puede_ver / cs_puede_editar), 070
-- (cs_norm_tel), 039 (cs_productos) y crm_members / crm_asignaciones (CRM).
--
-- Qué hace
--   1. Respaldo (tablas normales) de lo que pisa: la plantilla 1a1 de liam y la
--      definición de las funciones que reemplaza.
--   2. Campo "Otros" con texto libre en los formularios del onboarding: un campo
--      opcion/casillas puede declarar "otro": "<texto de la opción>"; el texto
--      libre viaja en la clave "<key>_otro". Validador nuevo
--      cs_validar_onboarding_otros y cs_ob_limpiar actualizada.
--   3. Plantilla 1a1 de liam: paso nuevo "como_nos_conociste" (preguntas 6 a 21
--      del formulario de Liam) entre "perfil_inversor" y "hoja_de_ruta".
--      Obligatorio (el 1 a 1 pasa de 4 a 5 pasos obligatorios). Los alumnos con
--      link ya generado conservan todo lo hecho: el paso nuevo les aparece
--      pendiente (progreso va por clave de paso). Los que ya estaban COMPLETADOS
--      quedan completados (ver 096b, utilidad B, para reabrir alguno a mano).
--   4. Avance de un onboarding completado = total (no "4 de 5" por el paso
--      nuevo): cs_ob_hechos_est y las tres funciones que muestran el avance.
--   5. Marca Resell: columna "Resell" (casilla, x_resell, valor en
--      cs_clientes.campos_extra) disponible pero OCULTA en el Maestro de cada
--      programa. No existía un dato equivalente: renovaciones_count cuenta las
--      renovaciones hechas dentro de la app, no un alumno que compró de vuelta.
--   6. Ventas (closer) da el alta: cs_closer_productos(programa) y
--      cs_onboarding_alta_closer(...). Mismas restricciones que
--      cs_onboarding_link_closer: solo su cliente asignado, sin lectura de cs_*.
--   7. Pestaña "Onboarding" de Producto: cs_onboarding_lista(programa).
--
-- Qué NO hace: no borra nada; no toca alumnos, respuestas ni progreso; no
-- vuelve a correr la 093 (sus plantillas quedan como están salvo el paso nuevo).
-- Pisa: pasos de la plantilla 1a1 de liam (respaldada) y 6 funciones (respaldadas).
--
-- Re-ejecutable: si el paso ya está en la plantilla no lo toca; los respaldos se
-- hacen una sola vez; las columnas con on conflict do nothing.
-- Si falla: el mensaje empieza con "cs 096:". Nada queda aplicado (una transacción).
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- 0. DIAGNÓSTICO Y GUARDAS (antes de crear o tocar nada)
-- ---------------------------------------------------------------------
do $chk$
declare
  v_falta       text;
  v_encontrado  text;
  v_esperado_pasos_antes   constant text := 'bienvenida,datos_contacto,diagnostico,perfil_inversor,hoja_de_ruta,accesos,final';
  v_esperado_pasos_despues constant text := 'bienvenida,datos_contacto,diagnostico,perfil_inversor,como_nos_conociste,hoja_de_ruta,accesos,final';
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
    raise exception 'cs 096: faltan tablas: %. Tiene que estar corrida la 093 (y 071, 079, 039).', v_falta;
  end if;

  select string_agg(r.t || '.' || r.c, ', ' order by r.t, r.c) into v_falta
    from (values
      ('cs_clientes', 'id'), ('cs_clientes', 'programa_id'), ('cs_clientes', 'nombre'),
      ('cs_clientes', 'email'), ('cs_clientes', 'telefono'), ('cs_clientes', 'estado'),
      ('cs_clientes', 'producto_id'), ('cs_clientes', 'campos_extra'),
      ('cs_clientes', 'fecha_inicio'), ('cs_clientes', 'created_by'),
      ('cs_productos', 'id'), ('cs_productos', 'programa_id'), ('cs_productos', 'nombre'),
      ('cs_productos', 'duracion_dias'), ('cs_productos', 'activo'), ('cs_productos', 'orden'),
      ('cs_maestro_columnas', 'programa_id'), ('cs_maestro_columnas', 'clave'),
      ('cs_maestro_columnas', 'sistema'), ('cs_maestro_columnas', 'etiqueta'),
      ('cs_maestro_columnas', 'orden'), ('cs_maestro_columnas', 'tipo'),
      ('cs_maestro_columnas', 'visible'), ('cs_maestro_columnas', 'archivada'),
      ('cs_onboardings', 'cliente_id'), ('cs_onboardings', 'programa_id'),
      ('cs_onboardings', 'plantilla_id'), ('cs_onboardings', 'estado'),
      ('cs_onboardings', 'progreso'), ('cs_onboardings', 'vence_at'),
      ('cs_onboardings', 'abierto_at'), ('cs_onboardings', 'iniciado_at'),
      ('cs_onboardings', 'completado_at'), ('cs_onboardings', 'updated_at'),
      ('cs_onboarding_respuestas', 'onboarding_id'), ('cs_onboarding_respuestas', 'updated_at'),
      ('cs_onboarding_plantillas', 'pasos'), ('cs_onboarding_plantillas', 'activa'),
      ('cs_onboarding_plantilla_productos', 'producto_id'),
      ('cs_onboarding_plantilla_productos', 'plantilla_id'),
      ('crm_members', 'user_id'), ('crm_members', 'rol'),
      ('crm_asignaciones', 'user_id'), ('crm_asignaciones', 'cliente_id')
    ) as r(t, c)
   where not exists (select 1 from information_schema.columns k
                      where k.table_schema = 'public' and k.table_name = r.t and k.column_name = r.c);
  if v_falta is not null then
    raise exception 'cs 096: faltan columnas: %.', v_falta;
  end if;

  select string_agg(f, ', ' order by f) into v_falta
    from unnest(array[
           'public.cs_puede_ver(text)', 'public.cs_puede_editar(text)',
           'public.cs_norm_tel(text)', 'public.cs_ob_nombre_clave(text)',
           'public.cs_ob_total(jsonb)', 'public.cs_ob_hechos(jsonb, jsonb)',
           'public.cs_ob_actual(jsonb, jsonb)', 'public.cs_ob_generar_link(uuid)',
           'public.cs_ob_limpiar(jsonb, jsonb, boolean)',
           'public.cs_validar_onboarding_pasos(jsonb)',
           'public.cs_validar_onboarding_pasos_motivo(jsonb)',
           'public.cs_onboarding_ficha(uuid)', 'public.cs_onboarding_avance(text)',
           'public.cs_onboarding_hoy(text)', 'public.cs_onboarding_link_closer(text, text, text)',
           'auth.uid()']) as f
   where to_regprocedure(f) is null;
  if v_falta is not null then
    raise exception 'cs 096: faltan funciones: %. La 093 no está aplicada completa (control Q00 de la 093b).', v_falta;
  end if;

  -- Plantilla 1a1 de liam: tiene que estar como la dejó la 093 (7 pasos) o ya
  -- con el paso nuevo (8 pasos, re-ejecución). Cualquier otra cosa: se corta
  -- mostrando qué pasos hay, porque alguien la editó a mano.
  select count(*) into v_n from public.cs_onboarding_plantillas where programa_id = 'liam' and clave = '1a1';
  if v_n <> v_esperado_plantillas_1a1 then
    raise exception 'cs 096: se esperaba % plantilla 1a1 de liam y hay %. (Si liam no existe en este banco, cargarlo antes.)',
      v_esperado_plantillas_1a1, v_n;
  end if;
  select string_agg(e.value ->> 'key', ',' order by e.ord) into v_encontrado
    from public.cs_onboarding_plantillas p,
         jsonb_array_elements(p.pasos) with ordinality as e(value, ord)
   where p.programa_id = 'liam' and p.clave = '1a1';
  if v_encontrado is distinct from v_esperado_pasos_antes
     and v_encontrado is distinct from v_esperado_pasos_despues then
    raise exception 'cs 096: la plantilla 1a1 de liam no tiene los pasos esperados. Esperado: [%] (o [%]). Encontrado: [%]',
      v_esperado_pasos_antes, v_esperado_pasos_despues, v_encontrado;
  end if;

  -- La columna x_resell, si ya existe en algún programa, tiene que ser una casilla propia.
  select string_agg(c.programa_id || '(sistema=' || c.sistema::text || ', tipo=' || coalesce(c.tipo, 'null') || ')', ', ')
    into v_falta
    from public.cs_maestro_columnas c
   where c.clave = 'x_resell' and (c.sistema or c.tipo is distinct from 'casilla');
  if v_falta is not null then
    raise exception 'cs 096: ya existe una columna x_resell que no es una casilla: %. Revisar antes de seguir.', v_falta;
  end if;
end
$chk$;

-- Locks juntos y primero (regla del deadlock). Si no los consigue en 8 s, aborta limpio.
lock table public.cs_programas, public.cs_maestro_columnas, public.cs_onboarding_plantillas
  in share row exclusive mode;


-- =====================================================================
-- 1. RESPALDO
-- =====================================================================
-- Tablas normales (no temporales): sobreviven a la transacción. Solo la primera
-- corrida respalda (conserva siempre el original de la 093).
create table if not exists public.cs_bak_096_plantillas as
  select now() as respaldado_at, p.* from public.cs_onboarding_plantillas p where false;

create table if not exists public.cs_bak_096_funciones (
  nombre       text primary key,
  definicion   text not null,
  respaldado_at timestamptz not null default now()
);

alter table public.cs_bak_096_plantillas enable row level security;
alter table public.cs_bak_096_funciones  enable row level security;
revoke all on table public.cs_bak_096_plantillas from public, anon, authenticated;
revoke all on table public.cs_bak_096_funciones  from public, anon, authenticated;

insert into public.cs_bak_096_plantillas
select now(), p.*
  from public.cs_onboarding_plantillas p
 where p.programa_id = 'liam' and p.clave = '1a1'
   and not exists (select 1 from jsonb_array_elements(p.pasos) e where e ->> 'key' = 'como_nos_conociste')
   and not exists (select 1 from public.cs_bak_096_plantillas b where b.id = p.id);

insert into public.cs_bak_096_funciones (nombre, definicion)
select f.n, pg_get_functiondef(to_regprocedure('public.' || f.n))
  from unnest(array[
         'cs_validar_onboarding_pasos(jsonb)', 'cs_ob_limpiar(jsonb, jsonb, boolean)',
         'cs_onboarding_ficha(uuid)', 'cs_onboarding_avance(text)', 'cs_onboarding_hoy(text)'
       ]) as f(n)
on conflict (nombre) do nothing;


-- =====================================================================
-- 2. "OTROS" CON TEXTO LIBRE
-- =====================================================================
-- Un campo opcion/casillas puede llevar "otro": "Otros" (el texto de una de sus
-- opciones). Si esa opción está elegida, el alumno puede escribir un texto, que
-- se guarda en la clave "<key>_otro" de las respuestas del paso.
create or replace function public.cs_validar_onboarding_otros(p jsonb)
returns text
language plpgsql immutable set search_path = public
as $fn$
declare
  e    jsonb;
  s    jsonb;
  c    jsonb;
  v_ok boolean;
begin
  if jsonb_typeof(p) is distinct from 'array' then
    return null;   -- la forma general la informa cs_validar_onboarding_pasos_motivo
  end if;
  for e in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(e) is distinct from 'object' or (e ->> 'tipo') is distinct from 'formulario' then
      continue;
    end if;
    if jsonb_typeof(e -> 'secciones') is distinct from 'array' then continue; end if;
    for s in select value from jsonb_array_elements(e -> 'secciones') loop
      if jsonb_typeof(s -> 'campos') is distinct from 'array' then continue; end if;
      for c in select value from jsonb_array_elements(s -> 'campos') loop
        if jsonb_typeof(c) = 'object' and (c -> 'otro') is not null and jsonb_typeof(c -> 'otro') <> 'null' then
          v_ok := jsonb_typeof(c -> 'otro') = 'string'
                  and (c ->> 'tipo') in ('opcion', 'casillas')
                  and jsonb_typeof(c -> 'opciones') = 'array';
          if coalesce(v_ok, false) then
            v_ok := exists (select 1 from jsonb_array_elements_text(c -> 'opciones') o where o = (c ->> 'otro'));
          end if;
          if not coalesce(v_ok, false) then
            return 'paso ' || coalesce(e ->> 'key', '?') || ', campo ' || coalesce(c ->> 'key', '?')
                   || ': otro tiene que ser el texto de una de las opciones (solo en opcion o casillas)';
          end if;
        end if;
      end loop;
    end loop;
  end loop;
  return null;
end;
$fn$;

-- La versión booleana la usa el CHECK de cs_onboarding_plantillas.
create or replace function public.cs_validar_onboarding_pasos(p jsonb)
returns boolean
language sql immutable set search_path = public
as $$
  select public.cs_validar_onboarding_pasos_motivo(p) is null
     and public.cs_validar_onboarding_otros(p) is null
$$;

-- cs_ob_limpiar: igual que en la 093 + el texto libre de "otro".
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
  v_otro text;
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

      -- "Otros" con texto libre: solo cuenta si esa opción quedó elegida.
      if v_tipo in ('opcion', 'casillas') and coalesce(c->>'otro', '') <> '' then
        v_otro := nullif(btrim(coalesce(p_resp ->> (v_key || '_otro'), '')), '');
        if v_otro is not null then
          if char_length(v_otro) > 300 then
            raise exception 'Revisá este campo (muy largo): %', v_lab using errcode = 'P0001';
          end if;
          if (v_tipo = 'opcion' and (v_out ->> v_key) = (c->>'otro'))
             or (v_tipo = 'casillas' and exists (select 1 from jsonb_array_elements_text(v_out -> v_key) x
                                                  where x = (c->>'otro'))) then
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
-- 3. PLANTILLA 1 A 1 DE LIAM: PASO "COMO_NOS_CONOCISTE"
-- =====================================================================
-- Texto tal cual el formulario de Liam (form-contenido-liam.md, preguntas 6 a
-- 21), con tipos del original. Una sola corrección de texto: en la pregunta 18
-- el ejemplo "Vi un video de mauro doende entendi..." pasa a "Vi un video de
-- Liam donde entendí...". Obligatorias: 6 a 10 y 12; el resto opcionales.
-- Pregunta 16: en el original es opción única aunque la ayuda diga "Podes
-- elegir varias": se respeta el tipo del original (cambiar "opcion" por
-- "casillas" en el campo problemas_principales si se prefiere elegir varias).
-- Pregunta 13: el original no tiene el tramo "3 a 6 meses": no se agrega.
do $paso$
declare
  v_paso   jsonb := $j$
  {"key":"como_nos_conociste","tipo":"formulario","titulo":"Paso 4: Cómo nos conociste",
   "texto":"Este es un formulario obligatorio para comenzar tu proceso conmigo. Completalo con toda la información solicitada para que podamos avanzar con tu ingreso. Te va a llevar solo unos minutos.",
   "tiempo":"unos minutos","casilla":"x_ob_formularios",
   "secciones":[
     {"campos":[
       {"key":"como_conociste","label":"Por donde me conociste?","tipo":"casillas","requerido":true,"otro":"Otros",
        "opciones":["Instagram","YouTube","TikTok","Recomendación (te envíaron mi contenido)","Otros"]},
       {"key":"formato","label":"¿Qué formato de mi contenido te aporta o te gusta más?","tipo":"casillas","requerido":true,"otro":"Otros",
        "opciones":["Reels","Historias","Youtube","Tiktok","Otros"]},
       {"key":"por_que_formato","label":"¿Por qué elegiste ese formato?","tipo":"parrafo","requerido":true},
       {"key":"temas","label":"Que temas te guste que hable en el contenido?","tipo":"casillas","requerido":true,"otro":"Otros",
        "opciones":["Como Empezar a Invertir","Como ordenar tus finanzas personales","Como elegir acciones que superen al SP500","Que acciones comprar y cuales vender","Estrategia de Crypto","Contenido de Mentalidad en las Inversiones","Como armar un portfolio de Jubilacion","Otros"]},
       {"key":"que_te_hizo_decir_si","label":"¿Qué te hizo finalmente decir “SÍ” y entrar a trabajar conmigo?","tipo":"casillas","requerido":true,"otro":"Otros",
        "opciones":["Me diste confianza en el contenido","La información que vi dentro del programa","La claridad que me pueden dar","Tu estilo de vida","Validacion de otras personas","Los casos de éxito","Otros"]}
     ]},
     {"campos":[
       {"key":"motivo_accion","label":"¿Qué te motivó específicamente a tomar acción","ayuda":"Desarrolla tu respuesta anterior (es clave para entender como ayudarte)","tipo":"parrafo"},
       {"key":"que_esperas","label":"Que es lo que esperas de nosotros?","tipo":"parrafo","requerido":true},
       {"key":"tiempo_decision","label":"¿Cuánto tiempo tardaste en decidirte a trabajar con nosotros?","tipo":"opcion",
        "opciones":["1 mes","1 a 3 meses","Más de 6 meses"]},
       {"key":"que_habria_funcionado","label":"¿Qué crees que podría haber funcionado mejor para que te decidieras a hacerlo antes?","tipo":"casillas",
        "opciones":["Mejor llamada de Venta","Mejor proceso de Agenda","Más frecuencia de contenido","Más temas/angulos en el contenido","Más testimonios/casos de éxito","Conocer más la vida personal de Liam","Conocer más el producto/programa por dentro"]},
       {"key":"que_mejorar","label":"¿Qué aspecto del punto que elegiste antes creés que se podría mejorar?","ayuda":"Claridad en lo que ofrecen, producto por dentro, más contenido de valor, comunicación, etc.","tipo":"parrafo"},
       {"key":"problemas_principales","label":"¿Cuáles eran tus problemas principales cuando buscaste ayuda?","ayuda":"Podes elegir varias","tipo":"opcion",
        "opciones":["Invertir por Emociones","Me estafaron previamente","Estaba invirtiendo con un asesor financiero del broker y tenia malos resultados","Tengo plata parada y pierde valor","Falta de claridad sobre como tomar decisiones","Desorganizacion en Finanzas Personales","No sabia que hacer con mi portfolio actual","Tuve una herencia/indermizacion y no sabia que hacer con eso"]}
     ]},
     {"campos":[
       {"key":"conviccion_previa","label":"Antes de la llamada ¿Qué tan convencido estaba de ingresar, en una escala del 1/10?","tipo":"escala_1_10",
        "extremos":["POCO INTERES EN TRABAJR CON USTEDES","SUPER CONVENCIDO"]},
       {"key":"ultimo_empujon","label":"¿Qué fue lo último que te convenció para tomar la decisión?","tipo":"parrafo",
        "ayuda":"Ejemplos:\nVi el video que me enviaron por chat y tenía exactamente lo que necesitaba\nen la llamada pudieron darme claridad sobre como solucionar problema que tenía\nVi un video de Liam donde entendí exactamente en que estaba fallando"},
       {"key":"que_impedia","label":"¿Qué fue lo que impedía que compres?","tipo":"opcion",
        "opciones":["Precio","Confianza","Tiempo","Falta de Claridad en Servicio"]},
       {"key":"otras_mentorias","label":"¿Antes de entrar a trabajar con Liam habías estado en otras mentorías o servicios? Con quien? Que experiencia tuviste?","tipo":"parrafo"},
       {"key":"top_3_problemas","label":"¿Cuáles son tu top 3 problemas que queres solucionar conmigo y mi equipo?","tipo":"parrafo"}
     ]}
   ]}
  $j$::jsonb;
  v_pl      public.cs_onboarding_plantillas;
  v_idx     int;
  v_nuevos  jsonb;
  v_motivo  text;
  v_afect   int;
begin
  select * into v_pl from public.cs_onboarding_plantillas where programa_id = 'liam' and clave = '1a1';
  if v_pl.id is null then
    raise exception 'cs 096: no hay plantilla 1a1 de liam';
  end if;

  if exists (select 1 from jsonb_array_elements(v_pl.pasos) e where e ->> 'key' = 'como_nos_conociste') then
    raise notice 'cs 096: la plantilla 1a1 de liam ya tiene el paso como_nos_conociste: no se toca.';
    return;
  end if;

  select t.i::int into v_idx
    from jsonb_array_elements(v_pl.pasos) with ordinality as t(e, i)
   where t.e ->> 'key' = 'perfil_inversor';
  if v_idx is null then
    raise exception 'cs 096: la plantilla 1a1 de liam no tiene el paso perfil_inversor';
  end if;

  select jsonb_agg(x.e order by x.o) into v_nuevos
    from (select t.e as e, (t.i * 2)::int as o
            from jsonb_array_elements(v_pl.pasos) with ordinality as t(e, i)
          union all
          select v_paso, v_idx * 2 + 1) x;

  v_motivo := coalesce(public.cs_validar_onboarding_pasos_motivo(v_nuevos), public.cs_validar_onboarding_otros(v_nuevos));
  if v_motivo is not null then
    raise exception 'cs 096: la plantilla 1a1 de liam con el paso nuevo no pasa la validación: %', v_motivo;
  end if;

  update public.cs_onboarding_plantillas
     set pasos = v_nuevos, updated_at = now()
   where id = v_pl.id;

  select count(*) into v_afect
    from public.cs_onboardings o where o.plantilla_id = v_pl.id and o.estado <> 'completado';
  raise notice 'cs 096: paso agregado a la plantilla 1a1 de liam. Alumnos con link sin completar que lo van a ver pendiente: %.', v_afect;
end
$paso$;


-- =====================================================================
-- 4. AVANCE DE UN COMPLETADO = TOTAL
-- =====================================================================
-- Un onboarding ya completado no se reabre: su avance se muestra completo aunque
-- la plantilla haya ganado un paso después.
create or replace function public.cs_ob_hechos_est(p_estado text, p_pasos jsonb, p_progreso jsonb)
returns int
language sql immutable set search_path = public
as $$
  select case when p_estado = 'completado' then public.cs_ob_total(p_pasos)
              else public.cs_ob_hechos(p_pasos, p_progreso) end
$$;

-- Último movimiento que dejó rastro en el progreso (paso completado, latido de
-- video, enlace confirmado). No se mueve cuando la CSM copia el link.
create or replace function public.cs_ob_progreso_ultimo(p_progreso jsonb)
returns timestamptz
language sql stable set search_path = public
as $$
  select max(q.t) from (
    select nullif(v.value ->> 'completado_at', '')::timestamptz as t
      from jsonb_each(coalesce(p_progreso, '{}'::jsonb)) v
    union all
    select nullif(v.value ->> 'ultimo_latido', '')::timestamptz
      from jsonb_each(coalesce(p_progreso, '{}'::jsonb)) v
    union all
    select nullif(l.value, '')::timestamptz
      from jsonb_each(coalesce(p_progreso, '{}'::jsonb)) v,
           jsonb_each_text(coalesce(v.value -> 'enlaces', '{}'::jsonb)) l
  ) q
$$;

-- cs_onboarding_ficha: igual que la 093, con "hechos" según el estado.
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
    'hechos', public.cs_ob_hechos_est(o.estado, pl.pasos, o.progreso),
    'total', public.cs_ob_total(pl.pasos),
    'puede_editar', public.cs_puede_editar(c.programa_id),
    'respuestas', (select coalesce(jsonb_object_agg(r.paso_key, jsonb_build_object(
                           'respuestas', r.respuestas, 'completo', r.completo, 'updated_at', r.updated_at)),
                           '{}'::jsonb)
                   from public.cs_onboarding_respuestas r where r.onboarding_id = o.id));
end;
$fn$;

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
         public.cs_ob_hechos_est(o.estado, pl.pasos, o.progreso),
         public.cs_ob_total(pl.pasos),
         coalesce(o.completado_at, o.updated_at)
  from public.cs_onboardings o
  join public.cs_onboarding_plantillas pl on pl.id = o.plantilla_id
  where o.programa_id = p_programa
$$;

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
         public.cs_ob_hechos_est(o.estado, pl.pasos, o.progreso),
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
-- 5. MARCA RESELL (columna disponible, oculta, en el Maestro de cada programa)
-- =====================================================================
-- Casilla x_resell (071): el valor va a cs_clientes.campos_extra['x_resell'].
-- Oculta: no cambia lo que se ve hoy; el fundador la muestra desde Columnas.
insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, tipo, visible)
select p.id, 'x_resell', false, 'Resell',
       greatest(coalesce((select max(c.orden) from public.cs_maestro_columnas c where c.programa_id = p.id), 0), 1000) + 1,
       'casilla', false
  from public.cs_programas p
on conflict (programa_id, clave) do nothing;


-- =====================================================================
-- 6. VENTAS (CLOSER) DA EL ALTA Y RECIBE EL LINK
-- =====================================================================
-- Interna: ¿el usuario es closer (rol ventas o closer) con este cliente asignado?
-- Misma regla que cs_onboarding_link_closer de la 093.
create or replace function public.cs_ob_es_closer(p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select auth.uid() is not null
     and p_programa is not null
     and exists (select 1
                   from public.crm_members m
                   join public.crm_asignaciones a on a.user_id = m.user_id
                  where m.user_id = auth.uid()
                    and m.rol in ('ventas', 'closer')
                    and a.cliente_id::text = p_programa)
$$;

-- Productos activos del cliente para el selector de Ventas.
create or replace function public.cs_closer_productos(p_programa text)
returns table (
  producto_id    uuid,
  nombre         text,
  duracion_dias  int,
  con_onboarding boolean
)
language plpgsql stable security definer set search_path = public
as $fn$
begin
  if not public.cs_ob_es_closer(p_programa) then
    raise exception 'SIN_PERMISO: no tenés permiso para este cliente' using errcode = '42501', hint = 'SIN_PERMISO';
  end if;
  return query
    select pr.id, pr.nombre, pr.duracion_dias,
           exists (select 1
                     from public.cs_onboarding_plantilla_productos pp
                     join public.cs_onboarding_plantillas pl on pl.id = pp.plantilla_id
                    where pp.producto_id = pr.id and pl.activa)
      from public.cs_productos pr
     where pr.programa_id = p_programa and pr.activo
     order by pr.orden, pr.nombre;
end;
$fn$;

-- Crea al alumno (como lo crea la CSM: mismo insert en cs_clientes, así se
-- disparan los mismos triggers: call de onboarding y accionables de plantilla)
-- y devuelve el link de onboarding en la misma llamada.
-- Si ya hay un alumno ACTIVO con ese nombre (sin importar el orden ni las
-- tildes) o ese teléfono: NO crea otro ni entrega su link; error ALUMNO_YA_EXISTE.
-- Para obtener el link de uno que ya existe: cs_onboarding_link_closer.
create or replace function public.cs_onboarding_alta_closer(
  p_programa text,
  p_nombre   text,
  p_producto uuid,
  p_telefono text    default null,
  p_email    text    default null,
  p_resell   boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_nom   text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_clave text := public.cs_ob_nombre_clave(p_nombre);
  v_tel   text := public.cs_norm_tel(p_telefono);
  v_telx  text := nullif(btrim(coalesce(p_telefono, '')), '');
  v_mail  text := nullif(btrim(coalesce(p_email, '')), '');
  v_pr    public.cs_productos;
  v_pl    uuid;
  v_id    uuid;
  v_res   jsonb;
begin
  if v_uid is null or not public.cs_ob_es_closer(p_programa) then
    raise exception 'SIN_PERMISO: no tenés permiso para dar altas de este cliente' using errcode = '42501', hint = 'SIN_PERMISO';
  end if;
  if v_nom is null or v_clave is null then
    raise exception 'DATOS_INVALIDOS: falta el nombre del alumno' using errcode = '22023', hint = 'DATOS_INVALIDOS';
  end if;
  if char_length(v_nom) > 120 then
    raise exception 'DATOS_INVALIDOS: el nombre es muy largo (hasta 120 caracteres)' using errcode = '22023', hint = 'DATOS_INVALIDOS';
  end if;
  if v_mail is not null and v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'DATOS_INVALIDOS: el mail no tiene un formato válido' using errcode = '22023', hint = 'DATOS_INVALIDOS';
  end if;
  if v_telx is not null and char_length(v_telx) > 40 then
    raise exception 'DATOS_INVALIDOS: el teléfono es muy largo (hasta 40 caracteres)' using errcode = '22023', hint = 'DATOS_INVALIDOS';
  end if;
  if p_producto is null then
    raise exception 'DATOS_INVALIDOS: falta elegir el producto' using errcode = '22023', hint = 'DATOS_INVALIDOS';
  end if;

  select * into v_pr from public.cs_productos
   where id = p_producto and programa_id = p_programa and activo;
  if v_pr.id is null then
    raise exception 'PRODUCTO_INVALIDO: el producto no existe, no está activo o no es de este cliente'
      using errcode = 'P0002', hint = 'PRODUCTO_INVALIDO';
  end if;

  select pl.id into v_pl
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas pl on pl.id = pp.plantilla_id
   where pp.producto_id = v_pr.id and pl.activa;
  if v_pl is null then
    raise exception 'PRODUCTO_SIN_ONBOARDING: ese producto no tiene un onboarding configurado. Avisale a Producto.'
      using errcode = '23514', hint = 'PRODUCTO_SIN_ONBOARDING';
  end if;

  -- Dos altas simultáneas del mismo cliente se hacen en fila (evita duplicados por doble clic).
  perform pg_advisory_xact_lock(hashtext('cs_alta_closer:' || p_programa));

  if exists (select 1
               from public.cs_clientes c
              where c.programa_id = p_programa
                and c.estado not in ('finalizado', 'baja')
                and (public.cs_ob_nombre_clave(c.nombre) = v_clave
                     or (v_tel is not null and public.cs_norm_tel(c.telefono) = v_tel))) then
    raise exception 'ALUMNO_YA_EXISTE: ya hay un alumno con ese nombre o teléfono en Producto. Pedile el link con cs_onboarding_link_closer.'
      using errcode = '23505', hint = 'ALUMNO_YA_EXISTE';
  end if;

  insert into public.cs_clientes (programa_id, nombre, email, telefono, producto_id, estado, campos_extra, created_by)
  values (p_programa, v_nom, v_mail, v_telx, v_pr.id, 'onboarding',
          case when coalesce(p_resell, false) then jsonb_build_object('x_resell', true) else '{}'::jsonb end,
          v_uid)
  returning id into v_id;

  v_res := public.cs_ob_generar_link(v_id);

  return jsonb_build_object(
    'token',    v_res -> 'token',
    'path',     '/onboarding?t=' || (v_res ->> 'token'),
    'estado',   v_res -> 'estado',
    'vence_at', v_res -> 'vence_at',
    'alumno',   split_part(v_nom, ' ', 1),
    'producto', v_pr.nombre,
    'resell',   coalesce(p_resell, false),
    'creado',   true);
end;
$fn$;


-- =====================================================================
-- 7. PESTAÑA "ONBOARDING" DE PRODUCTO
-- =====================================================================
-- Una fila por alumno no finalizado ni dado de baja. security definer con
-- cs_puede_ver adentro (fundador, producto y cliente del programa). No devuelve
-- el token ni ninguna respuesta (esas salen por cs_onboarding_ficha).
--   onboarding: sin_link | pendiente (link generado, no empezó) | en_curso |
--               completado | sin_plantilla (su producto no tiene onboarding)
--   skool / wpp: null si la columna no existe en el Maestro del programa.
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
         case when exists (select 1 from public.cs_maestro_columnas m
                            where m.programa_id = c.programa_id and m.clave = 'x_unio_school' and not m.archivada)
              then coalesce((c.campos_extra -> 'x_unio_school') = 'true'::jsonb, false)
              else null end,
         case when exists (select 1 from public.cs_maestro_columnas m
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
-- 8. PERMISOS
-- =====================================================================
revoke all on function
  public.cs_validar_onboarding_otros(jsonb),
  public.cs_validar_onboarding_pasos(jsonb),
  public.cs_ob_limpiar(jsonb, jsonb, boolean),
  public.cs_ob_hechos_est(text, jsonb, jsonb),
  public.cs_ob_progreso_ultimo(jsonb),
  public.cs_ob_es_closer(text),
  public.cs_onboarding_ficha(uuid),
  public.cs_onboarding_avance(text),
  public.cs_onboarding_hoy(text),
  public.cs_closer_productos(text),
  public.cs_onboarding_alta_closer(text, text, uuid, text, text, boolean),
  public.cs_onboarding_lista(text)
from public, anon, authenticated;

-- security invoker: llaman a estas con el rol de quien consulta (como cs_ob_total/hechos en la 093).
grant execute on function
  public.cs_ob_hechos_est(text, jsonb, jsonb),
  public.cs_onboarding_ficha(uuid),
  public.cs_onboarding_avance(text),
  public.cs_onboarding_hoy(text),
  public.cs_closer_productos(text),
  public.cs_onboarding_alta_closer(text, text, uuid, text, text, boolean),
  public.cs_onboarding_lista(text)
to authenticated;
-- cs_ob_hechos_est, cs_ob_total y cs_ob_hechos: las tres las usan funciones security invoker.
grant execute on function public.cs_ob_total(jsonb), public.cs_ob_hechos(jsonb, jsonb) to authenticated;

commit;
