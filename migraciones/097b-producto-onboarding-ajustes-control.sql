-- =====================================================================
-- 097b-producto-onboarding-ajustes-control.sql  ·  controles de la 097
-- =====================================================================
-- Consultas SUELTAS: correr de a una (comentario inicial hasta el `;`), después
-- de correr la 097. Las pruebas de humo escriben adentro y se deshacen solas:
-- terminan SIEMPRE con un error "HUMO OK" o "HUMO FALLÓ".
-- Orden: Q00 a Q03 (solo lectura), Q04 (función pura), Q05, Q06 y Q07 (humo).


-- Q00 · ¿Qué quedó aplicado? Esperado: todo en true.
select
  to_regprocedure('public.cs_onboarding_link_estado_closer(text, text, text)') is not null as funcion_nueva,
  (select count(*) from public.cs_bak_097_funciones) = 3 as respaldo_funciones_3,
  (select count(*) from public.cs_bak_097_plantillas) >= 1 as respaldo_plantilla,
  pg_get_functiondef(to_regprocedure('public.cs_ob_limpiar(jsonb, jsonb, boolean)')) like '%(097)%' as limpiar_097,
  pg_get_functiondef(to_regprocedure('public.cs_ob_armar_estado(uuid)')) like '%(097)%' as armar_estado_097,
  pg_get_functiondef(to_regprocedure('public.cs_onboarding_lista(text)')) like '%(097)%' as lista_097;


-- Q01 · Tipo del campo problemas_principales en las plantillas.
-- Esperado: 1a1 = casillas (nueva); grupal = casillas (como en la 093).
select p.clave, c.value ->> 'tipo' as tipo, (c.value ? 'otro') as con_otros
  from public.cs_onboarding_plantillas p,
       jsonb_array_elements(p.pasos) e,
       jsonb_array_elements(coalesce(e -> 'secciones', '[]'::jsonb)) s,
       jsonb_array_elements(coalesce(s -> 'campos', '[]'::jsonb)) c
 where p.programa_id = 'liam' and c.value ->> 'key' = 'problemas_principales'
 order by 1;


-- Q02 · Permisos. Esperado: anon = false en todas; authenticated = true solo en
-- cs_onboarding_lista y cs_onboarding_link_estado_closer.
select f.n as funcion,
       has_function_privilege('anon', to_regprocedure('public.' || f.n), 'execute') as anon,
       has_function_privilege('authenticated', to_regprocedure('public.' || f.n), 'execute') as authenticated
from unnest(array[
       'cs_ob_limpiar(jsonb, jsonb, boolean)', 'cs_ob_armar_estado(uuid)',
       'cs_onboarding_lista(text)', 'cs_onboarding_link_estado_closer(text, text, text)']) as f(n)
order by 1;


-- Q03 · La 097 no tocó respuestas ni onboardings: comparar con el respaldo de la
-- plantilla (solo cambia el tipo de un campo). Esperado: una fila, cambios = 1.
select count(*) as cambios
  from public.cs_bak_097_plantillas b
  join public.cs_onboarding_plantillas p on p.id = b.id
 where b.pasos is distinct from p.pasos
   and jsonb_array_length(b.pasos) = jsonb_array_length(p.pasos);


-- Q04 · cs_ob_limpiar (función pura, no escribe). Termina con "HUMO OK: n".
-- Comprueba: casillas con texto viejo, casillas con lista, "Otros" sin texto
-- (error al enviar, ok en borrador), "Otros" con texto, teléfono mal y bien.
do $humo$
declare
  v_paso jsonb := $j$
  {"key":"p","tipo":"formulario","secciones":[{"campos":[
    {"key":"probs","label":"Problemas","tipo":"casillas","opciones":["A","B","Otros"],"otro":"Otros"},
    {"key":"tel","label":"Teléfono","tipo":"texto","requerido":true,"contacto":"telefono"}
  ]}]}$j$::jsonb;
  v_r    jsonb;
  v_f    text := '';
  v_n    int := 0;
begin
  -- 1. valor viejo (texto) en casillas: queda como lista de una opción
  v_n := v_n + 1;
  v_r := public.cs_ob_limpiar(v_paso, '{"probs":"A","tel":"+54 9 11 5555-1234"}', true);
  if v_r -> 'probs' is distinct from '["A"]'::jsonb then v_f := v_f || ' [texto viejo: ' || v_r::text || ']'; end if;

  -- 2. varias
  v_n := v_n + 1;
  v_r := public.cs_ob_limpiar(v_paso, '{"probs":["A","B"],"tel":"11 5555 1234"}', true);
  if v_r -> 'probs' is distinct from '["A","B"]'::jsonb then v_f := v_f || ' [varias: ' || v_r::text || ']'; end if;

  -- 3. "Otros" elegido sin texto, al enviar: error
  v_n := v_n + 1;
  begin
    perform public.cs_ob_limpiar(v_paso, '{"probs":["Otros"],"tel":"11 5555 1234"}', true);
    v_f := v_f || ' [Otros sin texto aceptado al enviar]';
  exception when others then
    if sqlstate <> 'P0001' or sqlerrm not like 'Falta completar%' then
      v_f := v_f || ' [Otros sin texto: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 4. lo mismo con solo espacios en el texto
  v_n := v_n + 1;
  begin
    perform public.cs_ob_limpiar(v_paso, '{"probs":["Otros"],"probs_otro":"   ","tel":"11 5555 1234"}', true);
    v_f := v_f || ' [Otros con espacios aceptado al enviar]';
  exception when others then
    if sqlstate <> 'P0001' then v_f := v_f || ' [Otros espacios: ' || sqlstate || ' ' || sqlerrm || ']'; end if;
  end;

  -- 5. en borrador no frena
  v_n := v_n + 1;
  v_r := public.cs_ob_limpiar(v_paso, '{"probs":["Otros"]}', false);
  if v_r -> 'probs' is distinct from '["Otros"]'::jsonb then v_f := v_f || ' [borrador Otros: ' || v_r::text || ']'; end if;

  -- 6. "Otros" con texto: se guarda
  v_n := v_n + 1;
  v_r := public.cs_ob_limpiar(v_paso, '{"probs":["B","Otros"],"probs_otro":"Un amigo","tel":"11 5555 1234"}', true);
  if v_r ->> 'probs_otro' is distinct from 'Un amigo' then v_f := v_f || ' [Otros con texto: ' || v_r::text || ']'; end if;

  -- 7. texto de Otros sin la opción elegida: se descarta
  v_n := v_n + 1;
  v_r := public.cs_ob_limpiar(v_paso, '{"probs":["A"],"probs_otro":"suelto","tel":"11 5555 1234"}', true);
  if v_r ? 'probs_otro' then v_f := v_f || ' [texto de Otros sin elegir se guardó]'; end if;

  -- 8. teléfono con letras y teléfono corto: error al enviar
  v_n := v_n + 1;
  begin
    perform public.cs_ob_limpiar(v_paso, '{"tel":"prueba"}', true);
    v_f := v_f || ' [teléfono "prueba" aceptado]';
  exception when others then
    if sqlstate <> 'P0001' or sqlerrm not like 'Revisá el teléfono%' then
      v_f := v_f || ' [teléfono letras: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;
  v_n := v_n + 1;
  begin
    perform public.cs_ob_limpiar(v_paso, '{"tel":"1234567"}', true);
    v_f := v_f || ' [teléfono de 7 dígitos aceptado]';
  exception when others then
    if sqlstate <> 'P0001' then v_f := v_f || ' [teléfono corto: ' || sqlstate || ' ' || sqlerrm || ']'; end if;
  end;

  -- 9. formatos válidos
  v_n := v_n + 1;
  v_r := public.cs_ob_limpiar(v_paso, '{"tel":"+54 (011) 15-5555.1234"}', true);
  if v_r ->> 'tel' is distinct from '+54 (011) 15-5555.1234' then v_f := v_f || ' [teléfono válido: ' || v_r::text || ']'; end if;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- Q05 · PRUEBA DE HUMO de cs_onboarding_link_estado_closer (escribe y se deshace)
-- Toma un usuario ventas o closer asignado a liam (ver Q09 de la 093b), simula su
-- sesión y comprueba: alumno sin alta, alumno con alta y link (coincide con
-- cs_onboarding_link_closer y no trae token), alumno con alta SIN link (la función
-- no crea nada), alumno inactivo, búsqueda por teléfono en otro formato, datos
-- faltantes y cliente no asignado.
do $humo$
declare
  v_uid  uuid;
  v_prod uuid;
  v_j    jsonb;
  v_l    jsonb;
  v_f    text := '';
  v_n    int := 0;
  v_cnt  int;
  v_id   uuid;
begin
  select m.user_id into v_uid
    from public.crm_members m
    join public.crm_asignaciones a on a.user_id = m.user_id and a.cliente_id::text = 'liam'
   where m.rol in ('ventas', 'closer')
   limit 1;
  if v_uid is null then
    raise exception 'HUMO NO CORRIÓ: ningún usuario ventas o closer está asignado a liam en crm_asignaciones';
  end if;
  select pp.producto_id into v_prod
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas t on t.id = pp.plantilla_id
    join public.cs_productos pr on pr.id = pp.producto_id and pr.activo
   where t.programa_id = 'liam' and t.clave = '1a1'
   limit 1;
  if v_prod is null then
    raise exception 'HUMO NO CORRIÓ: ningún producto activo de liam tiene la plantilla 1a1';
  end if;

  -- Alumnos de prueba creados como dueño, antes de simular la sesión:
  -- uno con alta y sin link, y uno que después se marca finalizado.
  insert into public.cs_clientes (programa_id, nombre, telefono, fecha_inicio, estado, producto_id)
  values ('liam', 'Humo097 Sin Link', '+54 9 11 0000 1097', public.cs_hoy(), 'onboarding', v_prod);
  insert into public.cs_clientes (programa_id, nombre, telefono, fecha_inicio, estado, producto_id)
  values ('liam', 'Humo097 Inactivo', '+54 9 11 0000 2097', public.cs_hoy(), 'onboarding', v_prod)
  returning id into v_id;
  update public.cs_clientes set estado = 'finalizado' where id = v_id;

  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- 1. sin alta
  v_n := v_n + 1;
  v_j := public.cs_onboarding_link_estado_closer('liam', '+54 9 11 0000 9999', 'Humo097 Nadie');
  if (v_j ->> 'alta')::boolean is not false or (v_j ->> 'tiene_link')::boolean is not false
     or (v_j ->> 'inactivo')::boolean is not false or v_j -> 'alumno' <> 'null'::jsonb then
    v_f := v_f || ' [sin alta: ' || v_j::text || ']';
  end if;

  -- 2. con alta y SIN link: no crea el link
  v_n := v_n + 1;
  v_j := public.cs_onboarding_link_estado_closer('liam', null, 'Sin Link Humo097');
  if (v_j ->> 'alta')::boolean is not true or (v_j ->> 'tiene_link')::boolean is not false
     or v_j ->> 'alumno' <> 'Humo097' or (v_j ->> 'con_onboarding')::boolean is not true
     or v_j ->> 'estado' is not null then
    v_f := v_f || ' [alta sin link: ' || v_j::text || ']';
  end if;
  v_n := v_n + 1;
  select count(*) into v_cnt from public.cs_onboardings o
    join public.cs_clientes c on c.id = o.cliente_id where c.nombre = 'Humo097 Sin Link';
  if v_cnt <> 0 then v_f := v_f || ' [la función de lectura creó un onboarding]'; end if;

  -- 3. con alta y con link: se crea con la función de siempre y coincide
  v_n := v_n + 1;
  v_l := public.cs_onboarding_link_closer('liam', '+54 9 11 0000 1097', null);
  v_j := public.cs_onboarding_link_estado_closer('liam', '(011) 15 0000-1097', null);   -- otro formato
  if (v_j ->> 'alta')::boolean is not true or (v_j ->> 'tiene_link')::boolean is not true
     or v_j ->> 'estado' is distinct from v_l ->> 'estado'
     or v_j ->> 'vence_at' is distinct from v_l ->> 'vence_at'
     or (v_j ->> 'vencido')::boolean is not false then
    v_f := v_f || ' [con link: ' || v_j::text || ' vs ' || v_l::text || ']';
  end if;

  -- 4. no devuelve el token ni nada más que lo del contrato
  v_n := v_n + 1;
  if v_j ? 'token' or v_j::text like '%' || (v_l ->> 'token') || '%'
     or (select count(*) from jsonb_object_keys(v_j)) <> 9 then
    v_f := v_f || ' [claves inesperadas: ' || v_j::text || ']';
  end if;

  -- 5. inactivo
  v_n := v_n + 1;
  v_j := public.cs_onboarding_link_estado_closer('liam', '+54 9 11 0000 2097', null);
  if (v_j ->> 'alta')::boolean is not true or (v_j ->> 'inactivo')::boolean is not true then
    v_f := v_f || ' [inactivo: ' || v_j::text || ']';
  end if;
  begin
    perform public.cs_onboarding_link_closer('liam', '+54 9 11 0000 2097', null);
    v_f := v_f || ' [link_closer dio link a un inactivo]';
  exception when others then
    if sqlerrm not like 'ALUMNO_INACTIVO%' then v_f := v_f || ' [link_closer inactivo: ' || sqlerrm || ']'; end if;
  end;

  -- 6. sin teléfono ni nombre
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_link_estado_closer('liam', null, null);
    v_f := v_f || ' [sin datos aceptado]';
  exception when others then
    if sqlstate <> '22023' then v_f := v_f || ' [sin datos: ' || sqlstate || ' ' || sqlerrm || ']'; end if;
  end;

  -- 7. cliente no asignado
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_link_estado_closer('cliente_sin_asignar', '+54 9 11 0000 1097', null);
    v_f := v_f || ' [cliente no asignado aceptado]';
  exception when others then
    if sqlstate <> '42501' or sqlerrm not like 'SIN_PERMISO%' then
      v_f := v_f || ' [no asignado: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien. Nada quedó guardado.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- Q06 · PRUEBA DE HUMO de cs_ob_armar_estado: precarga del contacto (se deshace sola)
-- Un alumno 1 a 1 con nombre, mail y teléfono: el estado público trae "contacto"
-- con esos tres datos y nada más; al completar el paso de contacto deja de salir.
do $humo$
declare
  v_uid  uuid;
  v_prod uuid;
  v_cli  uuid;
  v_tok  text;
  v_e    jsonb;
  v_f    text := '';
  v_n    int := 0;
begin
  select m.user_id into v_uid from public.crm_members m where m.rol = 'fundador' limit 1;
  if v_uid is null then raise exception 'HUMO NO CORRIÓ: no hay ningún fundador en crm_members'; end if;
  select pp.producto_id into v_prod
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas t on t.id = pp.plantilla_id
   where t.programa_id = 'liam' and t.clave = '1a1' limit 1;
  if v_prod is null then raise exception 'HUMO NO CORRIÓ: ningún producto de liam tiene la plantilla 1a1'; end if;

  insert into public.cs_clientes (programa_id, nombre, email, telefono, fecha_inicio, estado, producto_id)
  values ('liam', 'Humo097 Contacto Prueba', 'humo097@example.com', '+54 9 11 0000 3097',
          public.cs_hoy(), 'onboarding', v_prod)
  returning id into v_cli;

  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
  v_tok := (public.cs_onboarding_link(v_cli)) ->> 'token';

  -- 1. el estado público trae el contacto (solo esas 3 claves)
  v_n := v_n + 1;
  v_e := public.cs_ob_estado(v_tok);
  if v_e #>> '{contacto,nombre}' is distinct from 'Humo097 Contacto Prueba'
     or v_e #>> '{contacto,email}' is distinct from 'humo097@example.com'
     or v_e #>> '{contacto,telefono}' is distinct from '+54 9 11 0000 3097'
     or (select count(*) from jsonb_object_keys(v_e -> 'contacto')) <> 3 then
    v_f := v_f || ' [contacto: ' || coalesce((v_e -> 'contacto')::text, 'null') || ']';
  end if;

  -- 2. completado el paso de contacto (el único con esos campos en el 1 a 1) no sale más
  v_n := v_n + 1;
  v_e := public.cs_ob_avanzar(v_tok, 'bienvenida', '{}', true);
  v_e := public.cs_ob_avanzar(v_tok, 'datos_contacto',
           '{"nombre":"Humo097","apellido":"Contacto Prueba","email":"humo097@example.com","telefono":"+54 9 11 0000 3097"}', true);
  if v_e -> 'contacto' is not null and v_e -> 'contacto' <> 'null'::jsonb then
    v_f := v_f || ' [el contacto sigue saliendo: ' || (v_e -> 'contacto')::text || ']';
  end if;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien. Nada quedó guardado.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- Q07 · Accesos de la pestaña según la plantilla (solo lectura, con sesión de
-- fundador simulada). Termina con un error "RESULTADO: ..." que lista, por
-- plantilla, cuántos alumnos tienen skool y wpp evaluados (no null). Esperado:
-- grupal con wpp evaluado en 0; 1a1 con skool y wpp evaluados en todos sus
-- alumnos (si las columnas existen en el Maestro de liam).
do $q$
declare
  v_uid uuid;
  v_txt text;
begin
  select m.user_id into v_uid from public.crm_members m where m.rol = 'fundador' limit 1;
  if v_uid is null then raise exception 'NO CORRIÓ: no hay ningún fundador en crm_members'; end if;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
  select string_agg(coalesce(x.clave, 'sin plantilla') || ': ' || x.alumnos || ' alumnos, skool evaluado en '
                    || x.con_skool || ', wpp evaluado en ' || x.con_wpp, E'\n' order by x.clave)
    into v_txt
    from (select pl.clave,
                 count(*) as alumnos,
                 count(*) filter (where l.skool is not null) as con_skool,
                 count(*) filter (where l.wpp is not null)   as con_wpp
            from public.cs_onboarding_lista('liam') l
            join public.cs_clientes c on c.id = l.cliente_id
            left join public.cs_onboarding_plantilla_productos pp on pp.producto_id = c.producto_id
            left join public.cs_onboarding_plantillas pl on pl.id = pp.plantilla_id
           group by 1) x;
  raise exception E'RESULTADO:\n%', v_txt;
end
$q$;
