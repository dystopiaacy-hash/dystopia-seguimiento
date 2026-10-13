-- =====================================================================
-- 096b-producto-onboarding-cambios-control.sql  ·  controles de la 096
-- =====================================================================
-- NO se corre entero. Cada consulta (marcada Q00, Q01...) es SUELTA: se
-- selecciona de la línea "-- Qnn" hasta su ";" y se corre sola (el SQL Editor
-- solo muestra el resultado de la última consulta de lo que corras).
-- Todas son de solo lectura, salvo Q07 y Q08 (pruebas de humo): escriben
-- adentro de un bloque que SIEMPRE termina en error y se deshace solo.
-- Las utilidades B y C están comentadas: NO se corren salvo decisión expresa.
-- Correr después de la 096 (Q00 se puede correr siempre). Evitar los minutos
-- :00, :15, :30 y :45.
-- =====================================================================


-- Q00 · ¿Qué quedó aplicado de la 096? (solo lectura)
-- Esperado: todo SÍ y RESUMEN = "APLICADA COMPLETA". Antes de la 096: "NO APLICADA".
-- "PARCIAL" no debería pasar nunca (la 096 es una sola transacción).
with o as (
  select 1 as ord, 'tabla' as tipo, t.n as objeto,
         case when to_regclass('public.' || t.n) is not null then 'SÍ' else 'NO' end as existe
    from unnest(array['cs_bak_096_plantillas', 'cs_bak_096_funciones']) as t(n)
  union all
  select 2, 'función', f.n,
         case when to_regprocedure('public.' || f.n) is not null then 'SÍ' else 'NO' end
    from unnest(array[
           'cs_validar_onboarding_otros(jsonb)', 'cs_ob_hechos_est(text, jsonb, jsonb)',
           'cs_ob_progreso_ultimo(jsonb)', 'cs_ob_es_closer(text)', 'cs_closer_productos(text)',
           'cs_onboarding_alta_closer(text, text, uuid, text, text, boolean)',
           'cs_onboarding_lista(text)']) as f(n)
  union all
  select 3, 'plantilla', 'liam 1a1 tiene el paso como_nos_conociste',
         case when exists (select 1 from public.cs_onboarding_plantillas p, jsonb_array_elements(p.pasos) e
                            where p.programa_id = 'liam' and p.clave = '1a1'
                              and e ->> 'key' = 'como_nos_conociste')
              then 'SÍ' else 'NO' end
  union all
  select 4, 'maestro', 'columna x_resell en ' || p.id,
         case when exists (select 1 from public.cs_maestro_columnas c
                            where c.programa_id = p.id and c.clave = 'x_resell')
              then 'SÍ' else 'NO' end
    from public.cs_programas p
)
select z.tipo, z.objeto, z.existe
from (
  select ord, tipo, objeto, existe from o
  union all
  select 9, 'RESUMEN',
         (count(*) filter (where existe = 'NO'))::text || ' faltan de ' || count(*)::text,
         case when count(*) filter (where existe = 'NO') = 0 then 'APLICADA COMPLETA'
              when count(*) filter (where existe = 'NO') = count(*) then 'NO APLICADA'
              else 'PARCIAL' end
    from o
) z
order by z.ord, z.objeto;


-- Q01 · Plantilla 1a1 de liam: orden de los pasos y qué es obligatorio
-- Esperado: 8 filas; como_nos_conociste en la posición 5, tipo formulario,
-- obligatorio = true; los dos videos opcionales; "oblig. acumulados" llega a 5.
select e.ord as posicion, e.value ->> 'key' as paso, e.value ->> 'tipo' as tipo,
       coalesce(e.value ->> 'obligatorio', 'true') as obligatorio,
       count(*) filter (where e.value ->> 'tipo' <> 'final'
                          and coalesce(e.value ->> 'obligatorio', 'true') <> 'false')
         over (order by e.ord) as oblig_acumulados
from public.cs_onboarding_plantillas p,
     jsonb_array_elements(p.pasos) with ordinality as e(value, ord)
where p.programa_id = 'liam' and p.clave = '1a1'
order by e.ord;


-- Q02 · El paso nuevo, campo por campo (preguntas 6 a 21)
-- Esperado: 16 filas; requerido = true en 6 (como_conociste, formato,
-- por_que_formato, temas, que_te_hizo_decir_si, que_esperas); "otro" = Otros en 4
-- (como_conociste, formato, temas, que_te_hizo_decir_si); 3 secciones.
select s.ord as seccion, c.ord as n, c.value ->> 'key' as campo, c.value ->> 'tipo' as tipo,
       coalesce(c.value ->> 'requerido', 'false') as requerido,
       coalesce(c.value ->> 'otro', '') as otro,
       coalesce(jsonb_array_length(c.value -> 'opciones'), 0) as opciones,
       left(c.value ->> 'label', 70) as pregunta
from public.cs_onboarding_plantillas p,
     jsonb_array_elements(p.pasos) e,
     jsonb_array_elements(e -> 'secciones') with ordinality as s(value, ord),
     jsonb_array_elements(s.value -> 'campos') with ordinality as c(value, ord)
where p.programa_id = 'liam' and p.clave = '1a1' and e ->> 'key' = 'como_nos_conociste'
order by s.ord, c.ord;


-- Q03 · Alumnos 1 a 1 con link y qué ven ahora (solo lectura, sin nombres)
-- "ve_paso_nuevo_pendiente" = no está completado y no tiene el paso nuevo hecho.
-- Los "completado" quedan completados: no ven el paso (ver utilidad B).
select o.estado,
       count(*) as alumnos,
       count(*) filter (where o.estado <> 'completado'
                          and (o.progreso -> 'como_nos_conociste' ->> 'completado_at') is null) as ve_paso_nuevo_pendiente,
       count(*) filter (where (o.progreso -> 'perfil_inversor' ->> 'completado_at') is not null) as con_perfil_hecho
from public.cs_onboardings o
join public.cs_onboarding_plantillas p on p.id = o.plantilla_id
where p.programa_id = 'liam' and p.clave = '1a1'
group by o.estado
order by o.estado;


-- Q04 · Respaldos (solo lectura)
-- Esperado después de la 096: 1 fila de plantilla con 7 pasos (la original de la
-- 093) y 5 funciones. Si la 096 se corrió dos veces no cambia.
select 'plantilla 1a1 original' as respaldo, b.respaldado_at::text as detalle,
       jsonb_array_length(b.pasos)::text || ' pasos' as dato
from public.cs_bak_096_plantillas b
union all
select 'función', f.nombre, length(f.definicion)::text || ' caracteres'
from public.cs_bak_096_funciones f
order by 1, 2;


-- Q05 · Marca Resell por programa (solo lectura)
-- Esperado: una fila por programa, tipo casilla, visible = false (disponible pero
-- oculta hasta que el fundador la muestre desde "Columnas" del Maestro).
select c.programa_id, c.clave, c.etiqueta, c.tipo, c.visible, c.archivada, c.orden
from public.cs_maestro_columnas c
where c.clave = 'x_resell'
order by c.programa_id;


-- Q06 · Permisos de las funciones nuevas (solo lectura)
-- Esperado: anon = false en todas. authenticated = true solo en las que usa la
-- app o Ventas; las internas (validador, progreso_ultimo, es_closer) en false.
select f.n as funcion,
       has_function_privilege('anon', to_regprocedure('public.' || f.n), 'execute') as anon,
       has_function_privilege('authenticated', to_regprocedure('public.' || f.n), 'execute') as authenticated
from unnest(array[
       'cs_validar_onboarding_otros(jsonb)', 'cs_ob_hechos_est(text, jsonb, jsonb)',
       'cs_ob_progreso_ultimo(jsonb)', 'cs_ob_es_closer(text)', 'cs_closer_productos(text)',
       'cs_onboarding_alta_closer(text, text, uuid, text, text, boolean)',
       'cs_onboarding_lista(text)', 'cs_onboarding_ficha(uuid)', 'cs_onboarding_avance(text)',
       'cs_onboarding_hoy(text)']) as f(n)
order by 1;


-- Q07 · PRUEBA DE HUMO del alta del closer (escribe adentro y se deshace sola)
-- Toma un usuario ventas o closer asignado a liam (ver Q09 de la 093b), simula
-- su sesión y comprueba: lista de productos, alta + link en la misma llamada, el
-- alumno queda en Producto con producto, estado, fecha de fin y Resell,
-- duplicado por nombre (otro orden) y por teléfono, producto inválido, producto
-- sin onboarding, datos faltantes, cliente no asignado y que un alta que falla no
-- deja nada creado. Termina SIEMPRE con un error: "HUMO OK" o "HUMO FALLÓ".
do $humo$
declare
  v_uid  uuid;
  v_ver  uuid;
  v_prod uuid;
  v_sin  uuid;
  v_j    jsonb;
  v_j2   jsonb;
  v_cli  uuid;
  v_f    text := '';
  v_n    int := 0;
  v_cnt  int;
  v_row  public.cs_clientes;
begin
  select m.user_id into v_uid
    from public.crm_members m
    join public.crm_asignaciones a on a.user_id = m.user_id and a.cliente_id::text = 'liam'
   where m.rol in ('ventas', 'closer')
   limit 1;
  if v_uid is null then
    raise exception 'HUMO NO CORRIÓ: ningún usuario ventas o closer está asignado a liam en crm_asignaciones';
  end if;
  select u.user_id into v_ver
    from (select a.user_id, 0 as o from public.cs_accesos a where a.programa_id = 'liam'
          union all
          select m.user_id, 1 from public.crm_members m where m.rol = 'fundador') u
   order by u.o
   limit 1;
  select pp.producto_id into v_prod
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas t on t.id = pp.plantilla_id
    join public.cs_productos pr on pr.id = pp.producto_id and pr.activo
   where t.programa_id = 'liam' and t.clave = '1a1'
   limit 1;
  if v_prod is null then
    raise exception 'HUMO NO CORRIÓ: ningún producto activo de liam tiene la plantilla 1a1';
  end if;
  select pr.id into v_sin
    from public.cs_productos pr
   where pr.programa_id = 'liam' and pr.activo
     and not exists (select 1 from public.cs_onboarding_plantilla_productos pp where pp.producto_id = pr.id)
   limit 1;

  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- 1. lista de productos
  v_n := v_n + 1;
  select count(*) into v_cnt from public.cs_closer_productos('liam') x
   where x.producto_id = v_prod and x.con_onboarding;
  if v_cnt <> 1 then v_f := v_f || ' [productos: el producto con onboarding no aparece]'; end if;

  -- 2. alta + link
  v_n := v_n + 1;
  v_j := public.cs_onboarding_alta_closer('liam', 'Humo096 Alta Uno', v_prod, '+54 9 11 0000 0096', null, true);
  if coalesce(v_j ->> 'token', '') !~ '^[0-9a-f]{64}$'
     or v_j ->> 'alumno' <> 'Humo096'
     or (v_j ->> 'path') <> '/onboarding?t=' || (v_j ->> 'token')
     or (v_j ->> 'creado')::boolean is not true
     or (v_j ->> 'resell')::boolean is not true then
    v_f := v_f || ' [alta: ' || left(v_j::text, 160) || ']';
  end if;

  -- 3. el alumno quedó en Producto
  v_n := v_n + 1;
  select c.* into v_row from public.cs_clientes c
   where c.programa_id = 'liam' and c.nombre = 'Humo096 Alta Uno';
  if v_row.id is null then
    v_f := v_f || ' [el alumno no quedó creado]';
  else
    if v_row.estado <> 'onboarding' or v_row.producto_id is distinct from v_prod
       or v_row.fecha_fin is null or v_row.telefono is distinct from '+54 9 11 0000 0096'
       or (v_row.campos_extra -> 'x_resell') is distinct from 'true'::jsonb then
      v_f := v_f || ' [alumno mal armado: ' || v_row.estado || ' / fin ' || coalesce(v_row.fecha_fin::text, 'null') || ']';
    end if;
    select count(*) into v_cnt from public.cs_onboardings o where o.cliente_id = v_row.id;
    if v_cnt <> 1 then v_f := v_f || ' [onboarding: ' || v_cnt || ' filas]'; end if;
    -- 3b. aparece en la lista de la pestaña, con Resell y sin empezar.
    -- cs_onboarding_lista exige cs_puede_ver, que el closer (ventas) no tiene por
    -- diseño: se la consulta con la sesión de un usuario que sí ve liam (acceso en
    -- cs_accesos o fundador) y después se vuelve a la sesión del closer.
    if v_ver is null then
      raise exception 'HUMO NO CORRIÓ: no hay un usuario que pueda ver liam (cs_accesos o fundador en crm_members) para la comprobación 3b';
    end if;
    perform set_config('request.jwt.claim.sub', v_ver::text, true);
    perform set_config('request.jwt.claims',
                       jsonb_build_object('sub', v_ver::text, 'role', 'authenticated')::text, true);
    select count(*) into v_cnt from public.cs_onboarding_lista('liam') l
     where l.cliente_id = v_row.id and l.resell and l.onboarding = 'pendiente' and l.hechos = 0;
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('request.jwt.claims',
                       jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
    if v_cnt <> 1 then v_f := v_f || ' [lista: no aparece como Resell sin empezar]'; end if;
  end if;

  -- 4. mismo nombre en otro orden: no duplica
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_alta_closer('liam', 'Uno Alta humo096', v_prod);
    v_f := v_f || ' [duplicado por nombre aceptado]';
  exception when others then
    if sqlstate <> '23505' or sqlerrm not like 'ALUMNO_YA_EXISTE%' then
      v_f := v_f || ' [dup nombre: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 5. mismo teléfono en otro formato, otro nombre
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_alta_closer('liam', 'Humo096 Otra Persona', v_prod, '(011) 15 0000-0096');
    v_f := v_f || ' [duplicado por teléfono aceptado]';
  exception when others then
    if sqlstate <> '23505' or sqlerrm not like 'ALUMNO_YA_EXISTE%' then
      v_f := v_f || ' [dup teléfono: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 6. el link del existente sale por la RPC de la 093 y es el mismo
  v_n := v_n + 1;
  v_j2 := public.cs_onboarding_link_closer('liam', null, 'Humo096 Alta Uno');
  if v_j2 ->> 'token' is distinct from v_j ->> 'token' then
    v_f := v_f || ' [link_closer devolvió otro link]';
  end if;

  -- 7. producto que no existe
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_alta_closer('liam', 'Humo096 Alta Dos', gen_random_uuid());
    v_f := v_f || ' [producto inexistente aceptado]';
  exception when others then
    if sqlstate <> 'P0002' or sqlerrm not like 'PRODUCTO_INVALIDO%' then
      v_f := v_f || ' [producto inválido: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 8. producto sin onboarding (solo si liam tiene alguno)
  if v_sin is not null then
    v_n := v_n + 1;
    begin
      perform public.cs_onboarding_alta_closer('liam', 'Humo096 Alta Tres', v_sin);
      v_f := v_f || ' [producto sin onboarding aceptado]';
    exception when others then
      if sqlstate <> '23514' or sqlerrm not like 'PRODUCTO_SIN_ONBOARDING%' then
        v_f := v_f || ' [sin onboarding: ' || sqlstate || ' ' || sqlerrm || ']';
      end if;
    end;
  end if;

  -- 9. sin nombre
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_alta_closer('liam', '   ', v_prod);
    v_f := v_f || ' [alta sin nombre aceptada]';
  exception when others then
    if sqlstate <> '22023' or sqlerrm not like 'DATOS_INVALIDOS%' then
      v_f := v_f || ' [sin nombre: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 10. cliente que no tiene asignado
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_alta_closer('cliente_sin_asignar', 'Humo096 Alta Cuatro', v_prod);
    v_f := v_f || ' [cliente no asignado aceptado]';
  exception when others then
    if sqlstate <> '42501' or sqlerrm not like 'SIN_PERMISO%' then
      v_f := v_f || ' [no asignado: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;
  begin
    perform 1 from public.cs_closer_productos('cliente_sin_asignar');
    v_f := v_f || ' [productos de un cliente no asignado aceptados]';
  exception when others then
    if sqlstate <> '42501' then v_f := v_f || ' [productos no asignado: ' || sqlerrm || ']'; end if;
  end;

  -- 11. los intentos que fallaron no dejaron alumnos
  v_n := v_n + 1;
  select count(*) into v_cnt from public.cs_clientes c
   where c.programa_id = 'liam' and c.nombre ilike 'Humo096%';
  if v_cnt <> 1 then v_f := v_f || ' [quedaron ' || v_cnt || ' alumnos Humo096, se esperaba 1]'; end if;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien. Nada quedó guardado.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- Q08 · PRUEBA DE HUMO del recorrido de un alumno con link previo (se deshace sola)
-- Simula a un alumno 1 a 1 que ya había hecho bienvenida, contacto, diagnóstico y
-- perfil antes de la 096, y comprueba: ve el paso nuevo pendiente sin perder lo
-- hecho, no puede saltearlo, el borrador y el envío con "Otros" guardan el texto
-- libre (y lo descartan si "Otros" no está elegido), los obligatorios se exigen, el
-- resto del recorrido sigue igual, un completado queda en 5 de 5 aunque no tenga
-- el paso, y la pestaña lo muestra. Termina SIEMPRE con un error.
do $humo$
declare
  v_uid  uuid;
  v_prod uuid;
  v_cli  uuid;
  v_oid  uuid;
  v_tok  text;
  v_j    jsonb;
  v_e    jsonb;
  v_r    jsonb;
  v_f    text := '';
  v_n    int := 0;
  v_cnt  int;
  v_ok   constant jsonb := '{"como_conociste":["Instagram","Otros"],"como_conociste_otro":"Un amigo",
      "formato":["Reels"],"formato_otro":"no corresponde","por_que_formato":"Es corto",
      "temas":["Estrategia de Crypto"],"que_te_hizo_decir_si":["Tu estilo de vida"],
      "que_esperas":"Ordenarme","conviccion_previa":8,"problemas_principales":"Me estafaron previamente"}';
begin
  select m.user_id into v_uid from public.crm_members m where m.rol = 'fundador' limit 1;
  if v_uid is null then
    raise exception 'HUMO NO CORRIÓ: no hay ningún fundador en crm_members';
  end if;
  select pp.producto_id into v_prod
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas t on t.id = pp.plantilla_id
   where t.programa_id = 'liam' and t.clave = '1a1'
   limit 1;
  if v_prod is null then
    raise exception 'HUMO NO CORRIÓ: ningún producto de liam tiene la plantilla 1a1';
  end if;

  insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado, producto_id)
  values ('liam', '__humo096 Link Viejo', public.cs_hoy(), 'onboarding', v_prod)
  returning id into v_cli;

  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  v_j := public.cs_onboarding_link(v_cli);
  v_tok := v_j ->> 'token';

  -- Estado "de antes de la 096": 4 pasos hechos y un borrador del perfil ya enviado
  update public.cs_onboardings
     set progreso = jsonb_build_object(
           'bienvenida',      jsonb_build_object('completado_at', now()),
           'datos_contacto',  jsonb_build_object('completado_at', now()),
           'diagnostico',     jsonb_build_object('completado_at', now()),
           'perfil_inversor', jsonb_build_object('completado_at', now())),
         estado = 'en_curso', iniciado_at = now()
   where cliente_id = v_cli
  returning id into v_oid;
  insert into public.cs_onboarding_respuestas (onboarding_id, programa_id, cliente_id, paso_key, respuestas, completo)
  values (v_oid, 'liam', v_cli, 'perfil_inversor', '{"nombre_apellido":"Humo Viejo"}'::jsonb, true);

  -- 1. ve el paso nuevo pendiente; lo anterior sigue hecho; lo enviado no vuelve por el link
  v_n := v_n + 1;
  v_e := public.cs_ob_estado(v_tok);
  if ((v_e -> 'pasos') -> (v_e ->> 'actual')::int) ->> 'key' is distinct from 'como_nos_conociste' then
    v_f := v_f || ' [el paso actual no es como_nos_conociste: ' || coalesce(((v_e -> 'pasos') -> (v_e ->> 'actual')::int) ->> 'key', 'null') || ']';
  end if;
  if (v_e -> 'progreso' -> 'perfil_inversor' ->> 'completado')::boolean is not true then
    v_f := v_f || ' [perdió el perfil_inversor hecho]';
  end if;
  if (v_e -> 'respuestas') ? 'perfil_inversor' then
    v_f := v_f || ' [el estado público devuelve respuestas ya enviadas]';
  end if;

  -- 2. no se puede saltear
  v_n := v_n + 1;
  begin
    perform public.cs_ob_avanzar(v_tok, 'hoja_de_ruta', '{}'::jsonb, true);
    v_f := v_f || ' [saltó el paso nuevo]';
  exception when others then
    if sqlstate <> 'P0001' then v_f := v_f || ' [salto: ' || sqlstate || ' ' || sqlerrm || ']'; end if;
  end;

  -- 3. borrador con "Otros"
  v_n := v_n + 1;
  v_e := public.cs_ob_avanzar(v_tok, 'como_nos_conociste',
           '{"como_conociste":["Instagram","Otros"],"como_conociste_otro":"Un amigo"}'::jsonb, false);
  if (v_e -> 'respuestas' -> 'como_nos_conociste' ->> 'como_conociste_otro') is distinct from 'Un amigo' then
    v_f := v_f || ' [el borrador no devolvió el texto de Otros]';
  end if;

  -- 4. envío sin las obligatorias
  v_n := v_n + 1;
  begin
    perform public.cs_ob_avanzar(v_tok, 'como_nos_conociste',
              '{"como_conociste":["Instagram"]}'::jsonb, true);
    v_f := v_f || ' [envío incompleto aceptado]';
  exception when others then
    if sqlstate <> 'P0001' or sqlerrm not like 'Falta completar%' then
      v_f := v_f || ' [envío incompleto: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 5. opción fuera de lista
  v_n := v_n + 1;
  begin
    perform public.cs_ob_avanzar(v_tok, 'como_nos_conociste',
              '{"como_conociste":["Facebook"]}'::jsonb, false);
    v_f := v_f || ' [opción inventada aceptada]';
  exception when others then
    if sqlstate <> 'P0001' then v_f := v_f || ' [opción inventada: ' || sqlerrm || ']'; end if;
  end;

  -- 6. envío completo: guarda el texto de Otros y descarta el que no corresponde
  v_n := v_n + 1;
  v_e := public.cs_ob_avanzar(v_tok, 'como_nos_conociste', v_ok, true);
  select r.respuestas into v_r from public.cs_onboarding_respuestas r
   where r.onboarding_id = v_oid and r.paso_key = 'como_nos_conociste' and r.completo;
  if v_r is null
     or (v_r ->> 'como_conociste_otro') is distinct from 'Un amigo'
     or v_r ? 'formato_otro'
     or (v_r ->> 'conviccion_previa') is distinct from '8' then
    v_f := v_f || ' [respuestas guardadas: ' || coalesce(left(v_r::text, 200), 'null') || ']';
  end if;
  if (v_e -> 'progreso' -> 'como_nos_conociste' ->> 'completado')::boolean is not true
     or (((v_e -> 'pasos') -> (v_e ->> 'actual')::int) ->> 'key') is distinct from 'hoja_de_ruta' then
    v_f := v_f || ' [después del envío no sigue hoja_de_ruta]';
  end if;
  if (v_e -> 'respuestas') ? 'como_nos_conociste' then
    v_f := v_f || ' [el estado público devuelve el formulario recién enviado]';
  end if;

  -- 7. el resto del recorrido: video opcional y accesos -> completado
  v_n := v_n + 1;
  perform public.cs_ob_avanzar(v_tok, 'hoja_de_ruta', '{}'::jsonb, true);
  perform public.cs_ob_confirmar(v_tok, 'accesos', 'whatsapp_grupo');
  perform public.cs_ob_confirmar(v_tok, 'accesos', 'skool');
  v_e := public.cs_ob_confirmar(v_tok, 'accesos', 'escribir_liam');
  if v_e ->> 'estado' is distinct from 'completado' then
    v_f := v_f || ' [no quedó completado: ' || coalesce(v_e ->> 'estado', 'null') || ']';
  end if;

  -- 8. ficha: 5 de 5 con las respuestas del paso nuevo
  v_n := v_n + 1;
  v_j := public.cs_onboarding_ficha(v_cli);
  if (v_j ->> 'hechos')::int <> 5 or (v_j ->> 'total')::int <> 5
     or not ((v_j -> 'respuestas') ? 'como_nos_conociste') then
    v_f := v_f || ' [ficha: ' || (v_j ->> 'hechos') || ' de ' || (v_j ->> 'total') || ']';
  end if;

  -- 9. un completado de ANTES (sin el paso nuevo) se ve 5 de 5, no 4 de 5
  v_n := v_n + 1;
  update public.cs_onboardings set progreso = progreso - 'como_nos_conociste' where id = v_oid;
  v_j := public.cs_onboarding_ficha(v_cli);
  if (v_j ->> 'hechos')::int <> (v_j ->> 'total')::int then
    v_f := v_f || ' [completado viejo: ' || (v_j ->> 'hechos') || ' de ' || (v_j ->> 'total') || ']';
  end if;
  select count(*) into v_cnt from public.cs_onboarding_avance('liam') a
   where a.cliente_id = v_cli and a.estado = 'completado' and a.hechos = a.total;
  if v_cnt <> 1 then v_f := v_f || ' [cs_onboarding_avance de un completado viejo]'; end if;

  -- 10. la pestaña lo muestra completo
  v_n := v_n + 1;
  select count(*) into v_cnt from public.cs_onboarding_lista('liam') l
   where l.cliente_id = v_cli and l.onboarding = 'completado' and l.hechos = l.total
     and l.ultimo_movimiento is not null;
  if v_cnt <> 1 then v_f := v_f || ' [lista: no aparece completado]'; end if;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien. Nada quedó guardado.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- =====================================================================
-- UTILIDADES (comentadas: NO se corren salvo decisión expresa)
-- =====================================================================

-- B · Reabrir un onboarding COMPLETADO para que complete el paso nuevo
-- La 096 deja los completados como están (reabrirlos mandaría de vuelta a una
-- persona que ya terminó). Si Nacho quiere que un alumno concreto lo llene:
-- primero ver quién es (cambiar el nombre) y después descomentar el update.
-- select c.nombre, o.estado, o.completado_at
--   from public.cs_onboardings o join public.cs_clientes c on c.id = o.cliente_id
--  where c.programa_id = 'liam' and c.nombre = 'NOMBRE EXACTO';
-- update public.cs_onboardings o
--    set estado = 'en_curso', completado_at = null, updated_at = now(),
--        vence_at = greatest(vence_at, now() + interval '30 days'), escrituras = 0
--   from public.cs_clientes c
--  where c.id = o.cliente_id and c.programa_id = 'liam' and c.nombre = 'NOMBRE EXACTO'
--    and o.estado = 'completado';
-- (El link es el mismo. Al terminar vuelve a quedar completado solo.)

-- C · Volver la plantilla 1a1 al estado de antes de la 096 (respaldo)
-- Solo la plantilla; las funciones nuevas se pueden dejar. Los alumnos que ya
-- hayan completado el paso nuevo conservan sus respuestas (quedan en
-- cs_onboarding_respuestas pero el paso deja de existir en la plantilla).
-- update public.cs_onboarding_plantillas p
--    set pasos = b.pasos, updated_at = now()
--   from public.cs_bak_096_plantillas b
--  where b.id = p.id;
