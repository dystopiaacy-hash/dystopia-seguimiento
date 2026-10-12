-- =====================================================================
-- 093b-producto-onboarding-control.sql  ·  controles de la 093
-- =====================================================================
-- NO se corre entero. Cada consulta (marcada Q01, Q02...) es SUELTA: se
-- selecciona de la línea "-- Qnn" hasta su ";" y se corre sola (el SQL Editor
-- solo muestra el resultado de la última consulta de lo que corras).
-- Todas son de solo lectura, salvo Q07, Q10 y Q11 (pruebas de humo): escriben
-- adentro de un bloque que SIEMPRE termina en error y se deshace solo.
-- Correr después de la 093 (Q00 se puede correr siempre, también antes o si la
-- 093 falló). Evitar los minutos :00, :15, :30 y :45.
-- =====================================================================


-- Q00 · ¿Qué quedó aplicado de la 093? (solo lectura; NO usa las tablas nuevas)
-- Sirve después de cualquier corrida, también si falló. La 093 es UNA sola
-- transacción: o queda todo o no queda nada. Esperado:
--   corrida buena -> todas las filas en SÍ y RESUMEN = "APLICADA COMPLETA".
--   corrida fallida (o todavía no corrida) -> todo NO y RESUMEN = "NO APLICADA".
--   "PARCIAL" no debería pasar nunca: si aparece, pasar la salida completa.
with o as (
  select 1 as ord, 'tabla' as tipo, t.n as objeto,
         case when to_regclass('public.' || t.n) is not null then 'SÍ' else 'NO' end as existe
    from unnest(array['cs_onboarding_plantillas', 'cs_onboarding_plantilla_productos',
                      'cs_onboardings', 'cs_onboarding_respuestas']) as t(n)
  union all
  select 2, 'función', f.n,
         case when to_regprocedure('public.' || f.n) is not null then 'SÍ' else 'NO' end
    from unnest(array[
           'cs_validar_onboarding_pasos_motivo(jsonb)', 'cs_validar_onboarding_pasos(jsonb)',
           'cs_ob_total(jsonb)', 'cs_ob_hechos(jsonb, jsonb)', 'cs_ob_actual(jsonb, jsonb)',
           'cs_ob_bloqueado(jsonb, jsonb, integer)', 'cs_ob_video_requerido(jsonb)',
           'cs_ob_nombre_clave(text)', 'cs_ob_cargar(text)', 'cs_ob_limpiar(jsonb, jsonb, boolean)',
           'cs_ob_marcar_casilla(uuid, text)', 'cs_ob_contacto(uuid, jsonb, jsonb)',
           'cs_ob_cerrar_paso(uuid, jsonb)', 'cs_ob_armar_estado(uuid)',
           'cs_ob_estado(text)', 'cs_ob_latido(text, text)',
           'cs_ob_avanzar(text, text, jsonb, boolean)', 'cs_ob_confirmar(text, text, text)',
           'cs_ob_generar_link(uuid)', 'cs_onboarding_link(uuid)',
           'cs_onboarding_link_closer(text, text, text)', 'cs_onboarding_ficha(uuid)',
           'cs_onboarding_diferencia_resolver(uuid, text, text)',
           'cs_onboarding_avance(text)', 'cs_onboarding_hoy(text)']) as f(n)
  union all
  select 3, 'política', p.n,
         case when exists (select 1 from pg_policies pp
                            where pp.schemaname = 'public'
                              and pp.tablename || '.' || pp.policyname = p.n)
              then 'SÍ' else 'NO' end
    from unnest(array['cs_onboarding_plantillas.cs_onb_plantillas_ver',
                      'cs_onboarding_plantilla_productos.cs_onb_pp_ver',
                      'cs_onboardings.cs_onb_ver',
                      'cs_onboarding_respuestas.cs_onb_resp_ver']) as p(n)
  union all
  select 4, 'maestro', 'cs_maestro_claves_sistema() incluye onb_avance',
         case when 'onb_avance' = any (public.cs_maestro_claves_sistema()) then 'SÍ' else 'NO' end
  union all
  select 4, 'maestro', 'columna ' || m.n || ' (liam)',
         case when exists (select 1 from public.cs_maestro_columnas c
                            where c.programa_id = 'liam' and c.clave = m.n)
              then 'SÍ' else 'NO' end
    from unnest(array['x_ob_video', 'x_ob_formularios', 'x_ob_wpp', 'x_ob_escribio']) as m(n)
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


-- Q01 · Productos de liam y qué onboarding tienen
-- Esperado: BPF 1-1 4 Meses, BPF 1-1 6 Meses y BPF 1-1 12 Meses con 1a1;
-- BPF Grupal con grupal; "Gestión de Capital" (y cualquier otro) SIN ASIGNAR.
select pr.nombre as producto, coalesce(pl.clave, 'SIN ASIGNAR') as onboarding,
       (select count(*) from public.cs_clientes c where c.producto_id = pr.id) as clientes
from public.cs_productos pr
left join public.cs_onboarding_plantilla_productos pp on pp.producto_id = pr.id
left join public.cs_onboarding_plantillas pl on pl.id = pp.plantilla_id
where pr.programa_id = 'liam'
order by pr.orden, pr.nombre;


-- Q02 · Plantillas cargadas
-- Los videos son opcionales (obligatorio: false): el total cuenta solo los
-- pasos obligatorios (formularios y accesos). Esperado:
--   1a1    | Liam Wickham | 7 pasos | 4 obligatorios | 2 videos opcionales | 38 preguntas
--   grupal | Liam Wickham | 4 pasos | 2 obligatorios | 1 video opcional    | 22 preguntas
select pl.clave, pl.mentor, jsonb_array_length(pl.pasos) as pasos,
       public.cs_ob_total(pl.pasos) as obligatorios,
       (select count(*) from jsonb_array_elements(pl.pasos) s
         where s->>'tipo' = 'video' and s->>'obligatorio' = 'false') as videos_opcionales,
       (select count(*)
          from jsonb_array_elements(pl.pasos) s,
               jsonb_array_elements(coalesce(s->'secciones', '[]'::jsonb)) sec,
               jsonb_array_elements(sec->'campos') c) as preguntas
from public.cs_onboarding_plantillas pl
where pl.programa_id = 'liam'
order by pl.clave;


-- Q03 · Permisos: ok debe ser true en todas las filas
select x.control, x.esperado, x.obtenido, x.esperado = x.obtenido as ok
from (
  select 'anon lee cs_onboardings' as control, 'false' as esperado,
         has_table_privilege('anon', 'public.cs_onboardings', 'select')::text as obtenido
  union all select 'anon lee cs_onboarding_respuestas', 'false',
         has_table_privilege('anon', 'public.cs_onboarding_respuestas', 'select')::text
  union all select 'anon lee cs_onboarding_plantillas', 'false',
         has_table_privilege('anon', 'public.cs_onboarding_plantillas', 'select')::text
  union all select 'anon lee cs_onboarding_plantilla_productos', 'false',
         has_table_privilege('anon', 'public.cs_onboarding_plantilla_productos', 'select')::text
  union all select 'authenticated escribe cs_onboardings', 'false',
         (has_table_privilege('authenticated', 'public.cs_onboardings', 'insert')
          or has_table_privilege('authenticated', 'public.cs_onboardings', 'update')
          or has_table_privilege('authenticated', 'public.cs_onboardings', 'delete'))::text
  union all select 'authenticated lee la columna token', 'false',
         has_column_privilege('authenticated', 'public.cs_onboardings', 'token', 'select')::text
  union all select 'authenticated lee progreso', 'true',
         has_column_privilege('authenticated', 'public.cs_onboardings', 'progreso', 'select')::text
  union all select 'anon ejecuta cs_ob_estado', 'true',
         has_function_privilege('anon', 'public.cs_ob_estado(text)', 'execute')::text
  union all select 'anon ejecuta cs_ob_latido', 'true',
         has_function_privilege('anon', 'public.cs_ob_latido(text, text)', 'execute')::text
  union all select 'anon ejecuta cs_ob_avanzar', 'true',
         has_function_privilege('anon', 'public.cs_ob_avanzar(text, text, jsonb, boolean)', 'execute')::text
  union all select 'anon ejecuta cs_ob_confirmar', 'true',
         has_function_privilege('anon', 'public.cs_ob_confirmar(text, text, text)', 'execute')::text
  union all select 'anon ejecuta cs_onboarding_link', 'false',
         has_function_privilege('anon', 'public.cs_onboarding_link(uuid)', 'execute')::text
  union all select 'anon ejecuta cs_onboarding_ficha', 'false',
         has_function_privilege('anon', 'public.cs_onboarding_ficha(uuid)', 'execute')::text
  union all select 'anon ejecuta cs_onboarding_avance', 'false',
         has_function_privilege('anon', 'public.cs_onboarding_avance(text)', 'execute')::text
  union all select 'anon ejecuta cs_onboarding_hoy', 'false',
         has_function_privilege('anon', 'public.cs_onboarding_hoy(text)', 'execute')::text
  union all select 'anon ejecuta cs_ob_cargar (interna)', 'false',
         has_function_privilege('anon', 'public.cs_ob_cargar(text)', 'execute')::text
  union all select 'anon ejecuta cs_ob_bloqueado (interna)', 'false',
         has_function_privilege('anon', 'public.cs_ob_bloqueado(jsonb, jsonb, integer)', 'execute')::text
  union all select 'anon ejecuta cs_ob_armar_estado (interna)', 'false',
         has_function_privilege('anon', 'public.cs_ob_armar_estado(uuid)', 'execute')::text
  union all select 'authenticated ejecuta cs_ob_cargar (interna)', 'false',
         has_function_privilege('authenticated', 'public.cs_ob_cargar(text)', 'execute')::text
  union all select 'authenticated ejecuta cs_onboarding_link', 'true',
         has_function_privilege('authenticated', 'public.cs_onboarding_link(uuid)', 'execute')::text
  union all select 'authenticated ejecuta cs_onboarding_link_closer', 'true',
         has_function_privilege('authenticated', 'public.cs_onboarding_link_closer(text, text, text)', 'execute')::text
  union all select 'anon ejecuta cs_onboarding_link_closer', 'false',
         has_function_privilege('anon', 'public.cs_onboarding_link_closer(text, text, text)', 'execute')::text
  union all select 'anon ejecuta cs_ob_generar_link (interna)', 'false',
         has_function_privilege('anon', 'public.cs_ob_generar_link(uuid)', 'execute')::text
  union all select 'authenticated ejecuta cs_ob_generar_link (interna)', 'false',
         has_function_privilege('authenticated', 'public.cs_ob_generar_link(uuid)', 'execute')::text
  union all select 'anon ejecuta cs_validar_onboarding_pasos_motivo (interna)', 'false',
         has_function_privilege('anon', 'public.cs_validar_onboarding_pasos_motivo(jsonb)', 'execute')::text
  union all select 'authenticated ejecuta cs_validar_onboarding_pasos (interna)', 'false',
         has_function_privilege('authenticated', 'public.cs_validar_onboarding_pasos(jsonb)', 'execute')::text
) x;


-- Q04 · RLS activa y políticas de las 4 tablas
-- Esperado: 4 filas, relrowsecurity = true y 1 política de lectura cada una.
select c.relname, c.relrowsecurity,
       (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as politicas,
       (select string_agg(distinct p.cmd, ',') from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as comandos
from pg_class c
where c.oid in (to_regclass('public.cs_onboarding_plantillas'),
                to_regclass('public.cs_onboarding_plantilla_productos'),
                to_regclass('public.cs_onboardings'),
                to_regclass('public.cs_onboarding_respuestas'))
order by c.relname;


-- Q05 · Maestro de liam: casillas de onboarding y columna calculada
-- Esperado: 5 casillas visibles (x_unio_school de la 079 + 4 x_ob_*) y una
-- última fila 'onb_avance en claves del sistema' = true.
select c.clave as columna, c.tipo, c.etiqueta, (not c.archivada)::text as visible
from public.cs_maestro_columnas c
where c.programa_id = 'liam'
  and c.clave in ('x_unio_school', 'x_ob_video', 'x_ob_formularios', 'x_ob_wpp', 'x_ob_escribio')
union all
select 'onb_avance en claves del sistema', null, null,
       ('onb_avance' = any (public.cs_maestro_claves_sistema()))::text
order by 1;


-- Q06 · Onboardings existentes (informativo)
-- Antes de probar: 0 filas. Después: una por alumno al que se le generó el link.
select c.nombre as alumno, pr.nombre as producto, o.estado,
       public.cs_ob_hechos(pl.pasos, o.progreso) || ' de ' || public.cs_ob_total(pl.pasos) as avance,
       o.vence_at::date as vence, o.abierto_at, o.completado_at,
       (select count(*) from public.cs_onboarding_respuestas r where r.onboarding_id = o.id) as pasos_con_respuestas
from public.cs_onboardings o
join public.cs_onboarding_plantillas pl on pl.id = o.plantilla_id
join public.cs_clientes c on c.id = o.cliente_id
left join public.cs_productos pr on pr.id = c.producto_id
order by o.created_at desc;


-- Q07 · PRUEBA DE HUMO (escribe adentro y se deshace sola)
-- Crea dos alumnos de prueba y recorre el onboarding 1 a 1 con las RPC públicas,
-- comprobando: orden de los pasos obligatorios, videos opcionales (no bloquean,
-- el tiempo se guarda y "visto" solo si lo vio), formularios, casillas del
-- Maestro, datos de contacto, diferencias y cierre.
--   Alumno A: ve el video de bienvenida y completa todo en orden.
--   Alumno B: se saltea el video (hace el formulario sin pasar por él y después
--             sigue de largo): no queda "visto" ni marca la casilla.
-- Termina SIEMPRE con un error. Si el mensaje empieza con "HUMO OK" salió bien;
-- si empieza con "HUMO FALLÓ" lista qué no cumplió. Nada queda guardado.
-- Si falla con otro error, es el error real de la 093: pasarlo tal cual.
do $humo$
declare
  v_prod   uuid;
  v_pl     uuid;
  v_cli    uuid;
  v_tok    text;
  v_j      jsonb;
  v_pasos  jsonb;
  v_ans    jsonb;
  v_f      text := '';
  v_n      int := 0;
  v_hechos int;
  v_total  int;
  v_extra  jsonb;
  v_cl     public.cs_clientes;
  v_cliB   uuid;
  v_tokB   text;
begin
  select pp.producto_id, pp.plantilla_id into v_prod, v_pl
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas t on t.id = pp.plantilla_id
   where t.programa_id = 'liam' and t.clave = '1a1'
   limit 1;
  if v_prod is null then
    raise exception 'HUMO NO CORRIÓ: ningún producto de liam tiene asignada la plantilla 1a1 (ver Q01)';
  end if;

  insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado, producto_id)
  values ('liam', '__humo093', public.cs_hoy(), 'onboarding', v_prod)
  returning id into v_cli;

  insert into public.cs_onboardings (cliente_id, programa_id, plantilla_id, vence_at)
  values (v_cli, 'liam', v_pl, now() + interval '1 day')
  returning token into v_tok;
  select pasos into v_pasos from public.cs_onboarding_plantillas where id = v_pl;

  -- 1. estado inicial
  v_j := public.cs_ob_estado(v_tok);
  v_n := v_n + 1;
  if v_j->>'estado' <> 'ok' or jsonb_array_length(v_j->'pasos') <> 7 or (v_j->>'actual')::int <> 0
     or (v_j->'pasos'->0->>'obligatorio') is distinct from 'false'
     or (v_j->'pasos'->4->>'obligatorio') is distinct from 'false' then
    v_f := v_f || ' [estado inicial: ' || left(v_j::text, 120) || ']';
  end if;

  -- 2. un paso OBLIGATORIO no se puede saltear (el diagnóstico antes que el contacto)
  v_n := v_n + 1;
  begin
    perform public.cs_ob_avanzar(v_tok, 'diagnostico', '{}'::jsonb, true);
    v_f := v_f || ' [se pudo saltar un paso obligatorio]';
  exception when others then
    if sqlerrm not like 'Completá primero%' then v_f := v_f || ' [salto: ' || sqlerrm || ']'; end if;
  end;

  -- 3. latido: el primero registra, el segundo (menos de 5 s) no suma. Duración 360 s -> 324 s
  v_n := v_n + 1;
  v_j := public.cs_ob_latido(v_tok, 'bienvenida');
  v_j := public.cs_ob_latido(v_tok, 'bienvenida');
  if (v_j->>'segundos')::int <> 0 or (v_j->>'requerido')::int <> 324 then
    v_f := v_f || ' [latido: ' || v_j::text || ']';
  end if;

  -- 4. el video opcional se acepta aun sin tiempo, pero no queda "visto" (alumno B, aparte)
  --    Acá, con el tiempo cumplido: avanza y SÍ queda visto
  update public.cs_onboardings
     set progreso = jsonb_set(progreso, '{bienvenida}',
                      coalesce(progreso->'bienvenida', '{}'::jsonb) || '{"segundos":324}'::jsonb, true)
   where cliente_id = v_cli;
  v_n := v_n + 1;
  v_j := public.cs_ob_avanzar(v_tok, 'bienvenida', '{}'::jsonb, true);
  if (v_j->'progreso'->'bienvenida'->>'completado') <> 'true' or (v_j->>'actual')::int <> 1 then
    v_f := v_f || ' [video no avanzó]';
  end if;
  if (select o.progreso->'bienvenida'->>'visto_at' from public.cs_onboardings o where o.cliente_id = v_cli) is null then
    v_f := v_f || ' [el video visto no quedó registrado]';
  end if;

  -- 5. alumno B: salta el video por la API, hace el formulario y sigue de largo sin verlo
  v_n := v_n + 1;
  insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado, producto_id)
  values ('liam', '__humo093b', public.cs_hoy(), 'onboarding', v_prod)
  returning id into v_cliB;
  insert into public.cs_onboardings (cliente_id, programa_id, plantilla_id, vence_at)
  values (v_cliB, 'liam', v_pl, now() + interval '1 day')
  returning token into v_tokB;
  begin
    v_j := public.cs_ob_avanzar(v_tokB, 'datos_contacto',
      '{"nombre":"__humo093b","email":"humo093b@example.com","telefono":"+54 9 11 5555 0001"}'::jsonb, true);
    if (v_j->'progreso'->'datos_contacto'->>'completado') <> 'true' then
      v_f := v_f || ' [B: el formulario no cerró sin pasar por el video]';
    end if;
    if (v_j->>'actual')::int <> 0 then
      v_f := v_f || ' [B: el video opcional dejó de mostrarse: actual=' || (v_j->>'actual') || ']';
    end if;
    v_j := public.cs_ob_avanzar(v_tokB, 'bienvenida', '{}'::jsonb, true);
    if (v_j->'progreso'->'bienvenida'->>'completado') <> 'true' then
      v_f := v_f || ' [B: el video opcional no se pudo seguir de largo]';
    end if;
    if (select o.progreso->'bienvenida'->>'visto_at' from public.cs_onboardings o where o.cliente_id = v_cliB) is not null then
      v_f := v_f || ' [B: quedó "visto" sin haberlo visto]';
    end if;
    if coalesce((select c.campos_extra->>'x_ob_video' from public.cs_clientes c where c.id = v_cliB), '') = 'true' then
      v_f := v_f || ' [B: marcó la casilla de video sin haberlo visto]';
    end if;
    if (select public.cs_ob_hechos(t.pasos, o.progreso) from public.cs_onboardings o
          join public.cs_onboarding_plantillas t on t.id = o.plantilla_id where o.cliente_id = v_cliB) <> 1 then
      v_f := v_f || ' [B: el avance debería ser 1 de 4 (el video no cuenta)]';
    end if;
  exception when others then
    v_f := v_f || ' [B: ' || sqlerrm || ']';
  end;

  -- 6. datos de contacto: completa mail y teléfono vacíos, deja el nombre como diferencia
  v_n := v_n + 1;
  v_j := public.cs_ob_avanzar(v_tok, 'datos_contacto',
    '{"nombre":"Humo Prueba","email":"humo093@example.com","telefono":"+54 9 11 5555 0000","comentarios":"x"}'::jsonb, true);
  select * into v_cl from public.cs_clientes where id = v_cli;
  if v_cl.email is distinct from 'humo093@example.com' or v_cl.telefono is distinct from '+54 9 11 5555 0000' then
    v_f := v_f || ' [contacto no completó la ficha]';
  end if;
  if (select o.diferencias->'nombre'->>'estado' from public.cs_onboardings o where o.cliente_id = v_cli) is distinct from 'pendiente' then
    v_f := v_f || ' [no marcó la diferencia de nombre]';
  end if;

  -- 7. diagnóstico: borrador incompleto, envío incompleto (falla), envío completo
  select jsonb_object_agg(c->>'key',
           case c->>'tipo'
             when 'opcion' then c->'opciones'->0
             when 'casillas' then jsonb_build_array(c->'opciones'->0)
             when 'escala_1_10' then to_jsonb(5)
             else to_jsonb('respuesta de prueba'::text)
           end)
    into v_ans
    from jsonb_array_elements(v_pasos) p,
         jsonb_array_elements(coalesce(p->'secciones', '[]'::jsonb)) s,
         jsonb_array_elements(s->'campos') c
   where p->>'key' = 'diagnostico';

  v_n := v_n + 1;
  v_j := public.cs_ob_avanzar(v_tok, 'diagnostico', '{"nombre_apellido":"Humo Prueba"}'::jsonb, false);
  if (v_j->'progreso'->'diagnostico'->>'completado') <> 'false' then
    v_f := v_f || ' [el borrador cerró el paso]';
  end if;
  -- Privacidad (a): el BORRADOR del formulario en curso sí vuelve por el estado público (retomar)
  v_n := v_n + 1;
  v_j := public.cs_ob_estado(v_tok);
  if v_j->'respuestas'->'diagnostico'->>'nombre_apellido' is distinct from 'Humo Prueba' then
    v_f := v_f || ' [el borrador no vuelve para retomar: ' || left(coalesce((v_j->'respuestas')::text, 'null'), 100) || ']';
  end if;
  v_n := v_n + 1;
  begin
    perform public.cs_ob_avanzar(v_tok, 'diagnostico', '{"nombre_apellido":"Humo Prueba"}'::jsonb, true);
    v_f := v_f || ' [envío incompleto aceptado]';
  exception when others then
    if sqlerrm not like 'Falta completar%' then v_f := v_f || ' [incompleto: ' || sqlerrm || ']'; end if;
  end;
  v_n := v_n + 1;
  v_j := public.cs_ob_avanzar(v_tok, 'diagnostico', v_ans, true);
  if (v_j->'progreso'->'diagnostico'->>'completado') <> 'true' then
    v_f := v_f || ' [diagnóstico completo no cerró]';
  end if;
  -- Privacidad (b): un formulario ya ENVIADO no vuelve por la vía pública, ni en la
  -- respuesta de cs_ob_avanzar ni en cs_ob_estado (el que tiene el link no lo lee)
  v_n := v_n + 1;
  if (v_j->'respuestas'->'diagnostico') is not null or (v_j->'respuestas'->'datos_contacto') is not null then
    v_f := v_f || ' [avanzar devolvió respuestas ya enviadas]';
  end if;
  v_j := public.cs_ob_estado(v_tok);
  if (v_j->'respuestas'->'diagnostico') is not null or (v_j->'respuestas'->'datos_contacto') is not null
     or (v_j->>'estado') <> 'ok' then
    v_f := v_f || ' [estado público devolvió respuestas ya enviadas: ' || left((v_j->'respuestas')::text, 100) || ']';
  end if;
  -- Tope de escrituras: con el contador al tope el link deja de escribir (sin tocar el avance)
  v_n := v_n + 1;
  update public.cs_onboardings set escrituras = 400 where cliente_id = v_cli;
  begin
    perform public.cs_ob_avanzar(v_tok, 'perfil_inversor', '{}'::jsonb, false);
    v_f := v_f || ' [el link escribió con el contador al tope]';
  exception when others then
    if sqlerrm <> 'Link inválido' then v_f := v_f || ' [tope: ' || sqlerrm || ']'; end if;
  end;
  update public.cs_onboardings set escrituras = 0 where cliente_id = v_cli;

  -- 8. perfil inversor
  select jsonb_object_agg(c->>'key',
           case c->>'tipo'
             when 'opcion' then c->'opciones'->0
             when 'casillas' then jsonb_build_array(c->'opciones'->0)
             else to_jsonb('respuesta de prueba'::text)
           end)
    into v_ans
    from jsonb_array_elements(v_pasos) p,
         jsonb_array_elements(p->'secciones') s,
         jsonb_array_elements(s->'campos') c
   where p->>'key' = 'perfil_inversor';
  v_n := v_n + 1;
  v_j := public.cs_ob_avanzar(v_tok, 'perfil_inversor', v_ans, true);
  if (v_j->'progreso'->'perfil_inversor'->>'completado') <> 'true' then
    v_f := v_f || ' [perfil no cerró]';
  end if;

  -- 9. segundo video (opcional, sin duración declarada): el latido guarda segundos
  --    sin exigir mínimo (requerido = null) y se sigue de largo sin tiempo
  v_n := v_n + 1;
  v_j := public.cs_ob_latido(v_tok, 'hoja_de_ruta');
  if (v_j->>'requerido') is not null or (v_j->>'segundos')::int <> 0 then
    v_f := v_f || ' [latido sin duración: ' || v_j::text || ']';
  end if;
  v_j := public.cs_ob_avanzar(v_tok, 'hoja_de_ruta', '{}'::jsonb, true);
  if (v_j->'progreso'->'hoja_de_ruta'->>'completado') <> 'true' then
    v_f := v_f || ' [hoja de ruta no cerró]';
  end if;

  -- 10. accesos: tres confirmaciones, el paso cierra con la última y el onboarding queda completo
  v_n := v_n + 1;
  v_j := public.cs_ob_confirmar(v_tok, 'accesos', 'whatsapp_grupo');
  v_j := public.cs_ob_confirmar(v_tok, 'accesos', 'skool');
  if (v_j->'progreso'->'accesos'->>'completado') <> 'false' then
    v_f := v_f || ' [accesos cerró antes de tiempo]';
  end if;
  v_j := public.cs_ob_confirmar(v_tok, 'accesos', 'escribir_liam');
  if v_j->>'estado' <> 'completado' then
    v_f := v_f || ' [no quedó completado: ' || (v_j->>'estado') || ']';
  end if;

  -- 11. casillas del Maestro
  select campos_extra into v_extra from public.cs_clientes where id = v_cli;
  v_n := v_n + 1;
  if coalesce(v_extra->>'x_ob_video', '') <> 'true' or coalesce(v_extra->>'x_ob_formularios', '') <> 'true'
     or coalesce(v_extra->>'x_ob_wpp', '') <> 'true' or coalesce(v_extra->>'x_unio_school', '') <> 'true'
     or coalesce(v_extra->>'x_ob_escribio', '') <> 'true' then
    v_f := v_f || ' [casillas: ' || v_extra::text || ']';
  end if;

  -- 12. avance para el Maestro: solo cuentan los obligatorios (contacto, diagnóstico, perfil, accesos)
  v_n := v_n + 1;
  select a.hechos, a.total into v_hechos, v_total from public.cs_onboarding_avance('liam') a where a.cliente_id = v_cli;
  if v_hechos is distinct from 4 or v_total is distinct from 4 then
    v_f := v_f || ' [avance: ' || coalesce(v_hechos::text, 'null') || ' de ' || coalesce(v_total::text, 'null') || ']';
  end if;

  -- 13. completado: el link solo informa y no deja reenviar
  v_n := v_n + 1;
  v_j := public.cs_ob_estado(v_tok);
  if v_j->>'estado' <> 'completado' or (v_j->'pasos') is not null or (v_j->'respuestas') is not null then
    v_f := v_f || ' [link completado devuelve de más: ' || left(v_j::text, 100) || ']';
  end if;
  begin
    perform public.cs_ob_avanzar(v_tok, 'perfil_inversor', v_ans, true);
    v_f := v_f || ' [reenvío aceptado]';
  exception when others then
    null;
  end;

  -- 14. token mal formado y token inexistente
  v_n := v_n + 1;
  begin
    perform public.cs_ob_estado('no-es-un-token');
    v_f := v_f || ' [token inválido aceptado]';
  exception when others then
    if sqlerrm <> 'Link inválido' then v_f := v_f || ' [token inválido: ' || sqlerrm || ']'; end if;
  end;
  begin
    perform public.cs_ob_estado(repeat('a', 64));
    v_f := v_f || ' [token inexistente aceptado]';
  exception when others then
    if sqlerrm <> 'Link inválido' then v_f := v_f || ' [token inexistente: ' || sqlerrm || ']'; end if;
  end;

  -- 15. sin sesión no se genera el link (cs_puede_editar)
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_link(v_cli);
    v_f := v_f || ' [link generado sin sesión]';
  exception when others then
    if sqlstate <> '42501' then v_f := v_f || ' [link sin sesión: ' || sqlerrm || ']'; end if;
  end;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien. Nada quedó guardado.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- Q08 · Resultado de una prueba real con un alumno (cambiar el nombre de abajo)
-- Después de recorrer el link a mano: estado, avance, casillas del Maestro,
-- diferencias de contacto y qué pasos tienen respuestas.
select c.nombre as alumno, o.estado,
       public.cs_ob_hechos(pl.pasos, o.progreso) || ' de ' || public.cs_ob_total(pl.pasos) as avance,
       c.email, c.telefono,
       c.campos_extra - (select coalesce(array_agg(k), array[]::text[])
                           from jsonb_object_keys(c.campos_extra) k where k !~ '^x_(ob_|unio_school)') as casillas,
       o.diferencias,
       (select string_agg(r.paso_key, ', ' order by r.paso_key)
          from public.cs_onboarding_respuestas r where r.onboarding_id = o.id) as pasos_con_respuestas
from public.cs_onboardings o
join public.cs_onboarding_plantillas pl on pl.id = o.plantilla_id
join public.cs_clientes c on c.id = o.cliente_id
where c.nombre = 'PRUEBA ONBOARDING';


-- Q09 · Quién puede generar el link desde Ventas (informativo)
-- Usuarios con rol ventas o closer y los clientes que tienen asignados en
-- crm_asignaciones. Solo los que tienen 'liam' pueden generar el link de un
-- alumno de liam. Ninguno tiene acceso de lectura al área Producto por esto.
select coalesce(au.email, m.user_id::text) as usuario, m.rol,
       coalesce(string_agg(a.cliente_id::text, ', ' order by a.cliente_id::text), '(sin asignaciones)') as clientes_asignados,
       coalesce(bool_or(a.cliente_id::text = 'liam'), false) as puede_generar_link_liam
from public.crm_members m
left join public.crm_asignaciones a on a.user_id = m.user_id
left join auth.users au on au.id = m.user_id
where m.rol in ('ventas', 'closer')
group by au.email, m.user_id, m.rol
order by 1;


-- Q10 · PRUEBA DE HUMO del permiso del closer (escribe adentro y se deshace sola)
-- Toma un usuario ventas o closer asignado a liam (ver Q09), simula su sesión y
-- comprueba: genera el link buscando por teléfono (en otro formato) y por
-- nombre, el link es el mismo las dos veces, no encuentra a quien no existe,
-- no funciona para un cliente que no tiene asignado ni sin sesión, y que ese
-- usuario no puede ver la ficha de onboarding ni generar el link por la vía de
-- Producto. Termina SIEMPRE con un error: "HUMO OK" o "HUMO FALLÓ".
do $humo$
declare
  v_uid  uuid;
  v_prod uuid;
  v_cli  uuid;
  v_j    jsonb;
  v_j2   jsonb;
  v_f    text := '';
  v_n    int := 0;
  v_cnt  int;
begin
  select m.user_id into v_uid
    from public.crm_members m
    join public.crm_asignaciones a on a.user_id = m.user_id and a.cliente_id::text = 'liam'
   where m.rol in ('ventas', 'closer')
   limit 1;
  if v_uid is null then
    raise exception 'HUMO NO CORRIÓ: ningún usuario ventas o closer está asignado a liam en crm_asignaciones (ver Q09)';
  end if;
  select pp.producto_id into v_prod
    from public.cs_onboarding_plantilla_productos pp
    join public.cs_onboarding_plantillas t on t.id = pp.plantilla_id
   where t.programa_id = 'liam' and t.clave = '1a1'
   limit 1;
  if v_prod is null then
    raise exception 'HUMO NO CORRIÓ: ningún producto de liam tiene asignada la plantilla 1a1 (ver Q01)';
  end if;

  insert into public.cs_clientes (programa_id, nombre, telefono, fecha_inicio, estado, producto_id)
  values ('liam', '__humo093c Closer Prueba', '+54 9 11 0000 0093', public.cs_hoy(), 'onboarding', v_prod)
  returning id into v_cli;

  -- sesión del closer
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- 1. por teléfono, en otro formato
  v_n := v_n + 1;
  v_j := public.cs_onboarding_link_closer('liam', '(011) 15 0000-0093', null);
  if coalesce(v_j->>'token', '') !~ '^[0-9a-f]{64}$' or v_j->>'alumno' <> '__humo093c' then
    v_f := v_f || ' [por teléfono: ' || left(v_j::text, 120) || ']';
  end if;

  -- 2. por nombre (otro orden): devuelve el MISMO link
  v_n := v_n + 1;
  v_j2 := public.cs_onboarding_link_closer('liam', null, 'Prueba Closer humo093c');
  if v_j2->>'token' is distinct from v_j->>'token' then
    v_f := v_f || ' [por nombre devolvió otro link]';
  end if;

  -- 3. alumno que no existe: error fijo ALUMNO_SIN_ALTA (SQLSTATE P0002)
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_link_closer('liam', '0000 0094', null);
    v_f := v_f || ' [alumno inexistente aceptado]';
  exception when others then
    if sqlstate <> 'P0002' or sqlerrm not like 'ALUMNO_SIN_ALTA%' then
      v_f := v_f || ' [inexistente: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 4. un cliente que no tiene asignado
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_link_closer('cliente_sin_asignar', '(011) 15 0000-0093', null);
    v_f := v_f || ' [cliente no asignado aceptado]';
  exception when others then
    if sqlstate <> '42501' then v_f := v_f || ' [no asignado: ' || sqlerrm || ']'; end if;
  end;

  -- 5. no puede ver la ficha de onboarding ni usar la vía de Producto
  v_n := v_n + 1;
  begin
    perform public.cs_onboarding_ficha(v_cli);
    v_f := v_f || ' [el closer ve la ficha de onboarding]';
  exception when others then
    if sqlstate <> 'P0002' then v_f := v_f || ' [ficha: ' || sqlerrm || ']'; end if;
  end;
  begin
    perform public.cs_onboarding_link(v_cli);
    v_f := v_f || ' [el closer usó cs_onboarding_link]';
  exception when others then
    if sqlstate <> '42501' then v_f := v_f || ' [link de producto: ' || sqlerrm || ']'; end if;
  end;

  -- 6. lectura directa de las tablas con el rol authenticated
  v_n := v_n + 1;
  begin
    set local role authenticated;
    select count(*) into v_cnt from public.cs_onboarding_respuestas;
    if v_cnt <> 0 then v_f := v_f || ' [el closer lee ' || v_cnt || ' respuestas]'; end if;
    select count(*) into v_cnt from public.cs_onboardings;
    if v_cnt <> 0 then v_f := v_f || ' [el closer lee ' || v_cnt || ' onboardings]'; end if;
    reset role;
  exception when others then
    v_f := v_f || ' [lectura (no concluyente): ' || sqlerrm || ']';
  end;

  -- 6b. privacidad: con el token que obtuvo el closer, el estado público no devuelve un
  --     formulario ya enviado (sí el borrador en curso). Se inserta (como dueño, no como
  --     closer) un envío y un borrador y se pide el estado con ESE token.
  v_n := v_n + 1;
  insert into public.cs_onboarding_respuestas (onboarding_id, programa_id, cliente_id, paso_key, respuestas, completo)
  select o.id, o.programa_id, o.cliente_id, k.paso, '{"nombre_apellido":"__humo093c"}'::jsonb, k.completo
    from public.cs_onboardings o,
         (values ('diagnostico', true), ('perfil_inversor', false)) as k(paso, completo)
   where o.cliente_id = v_cli;
  v_j2 := public.cs_ob_estado(v_j->>'token');
  if (v_j2->'respuestas'->'diagnostico') is not null then
    v_f := v_f || ' [con el token del closer se lee un formulario ya enviado]';
  end if;
  if (v_j2->'respuestas'->'perfil_inversor') is null then
    v_f := v_f || ' [con el token del closer no vuelve el borrador (retomar)]';
  end if;

  -- 6c. alumno finalizado o dado de baja: ALUMNO_INACTIVO (P0002), no ALUMNO_SIN_ALTA
  v_n := v_n + 1;
  insert into public.cs_clientes (programa_id, nombre, telefono, fecha_inicio, estado, producto_id)
  values ('liam', '__humo093d Baja Prueba', '+54 9 11 0000 0095', public.cs_hoy(), 'baja', v_prod);
  begin
    perform public.cs_onboarding_link_closer('liam', '(011) 15 0000-0095', null);
    v_f := v_f || ' [alumno de baja aceptado]';
  exception when others then
    if sqlstate <> 'P0002' or sqlerrm not like 'ALUMNO_INACTIVO%' then
      v_f := v_f || ' [de baja: ' || sqlstate || ' ' || sqlerrm || ']';
    end if;
  end;

  -- 7. sin sesión
  v_n := v_n + 1;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  begin
    perform public.cs_onboarding_link_closer('liam', '(011) 15 0000-0093', null);
    v_f := v_f || ' [link generado sin sesión]';
  exception when others then
    if sqlstate <> '42501' then v_f := v_f || ' [sin sesión: ' || sqlerrm || ']'; end if;
  end;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien. Nada quedó guardado.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- Q11 · PRUEBA DE HUMO del reinicio del contador de escrituras (se deshace sola)
-- Toma un fundador (crm_members), simula su sesión, deja un link en el tope de
-- 400 escrituras (muerto), lo pide desde la vía de Producto (cs_onboarding_link,
-- como el botón "Link de onboarding" de la ficha) y comprueba que el contador
-- vuelve a 0, que el token y el avance se conservan y que el link vuelve a
-- escribir. Termina SIEMPRE con un error: "HUMO OK" o "HUMO FALLÓ".
do $humo$
declare
  v_uid  uuid;
  v_prod uuid;
  v_cli  uuid;
  v_tok  text;
  v_j    jsonb;
  v_esc  int;
  v_f    text := '';
  v_n    int := 0;
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
    raise exception 'HUMO NO CORRIÓ: ningún producto de liam tiene asignada la plantilla 1a1 (ver Q01)';
  end if;

  insert into public.cs_clientes (programa_id, nombre, fecha_inicio, estado, producto_id)
  values ('liam', '__humo093e', public.cs_hoy(), 'onboarding', v_prod)
  returning id into v_cli;

  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
                     jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- 1. se crea el link y se guarda un avance
  v_n := v_n + 1;
  v_j := public.cs_onboarding_link(v_cli);
  v_tok := v_j->>'token';
  v_j := public.cs_ob_avanzar(v_tok, 'bienvenida', '{}'::jsonb, true);
  if (v_j->'progreso'->'bienvenida'->>'completado') <> 'true' then
    v_f := v_f || ' [no se pudo preparar el avance]';
  end if;

  -- 2. el contador llega al tope: el link queda muerto
  v_n := v_n + 1;
  update public.cs_onboardings set escrituras = 400 where cliente_id = v_cli;
  begin
    perform public.cs_ob_avanzar(v_tok, 'datos_contacto', '{}'::jsonb, false);
    v_f := v_f || ' [el link escribió con el contador al tope]';
  exception when others then
    if sqlerrm <> 'Link inválido' then v_f := v_f || ' [tope: ' || sqlerrm || ']'; end if;
  end;

  -- 3. pedirlo de nuevo desde la ficha lo destraba, con el mismo token y el avance
  v_n := v_n + 1;
  v_j := public.cs_onboarding_link(v_cli);
  select o.escrituras into v_esc from public.cs_onboardings o where o.cliente_id = v_cli;
  if v_esc is distinct from 0 or v_j->>'token' is distinct from v_tok then
    v_f := v_f || ' [reinicio: escrituras=' || coalesce(v_esc::text, 'null') || ', mismo token='
           || (v_j->>'token' is not distinct from v_tok)::text || ']';
  end if;
  if (select o.progreso->'bienvenida'->>'completado_at' from public.cs_onboardings o where o.cliente_id = v_cli) is null then
    v_f := v_f || ' [el reinicio borró el avance]';
  end if;

  -- 4. el link vuelve a escribir
  v_n := v_n + 1;
  begin
    perform public.cs_ob_avanzar(v_tok, 'datos_contacto', '{}'::jsonb, false);
  exception when others then
    v_f := v_f || ' [después del reinicio no escribe: ' || sqlerrm || ']';
  end;

  if v_f = '' then
    raise exception 'HUMO OK: % comprobaciones, todas bien. Nada quedó guardado.', v_n;
  else
    raise exception 'HUMO FALLÓ (% comprobaciones):%', v_n, v_f;
  end if;
end
$humo$;


-- =====================================================================
-- UTILIDADES (comentadas: no son controles)
-- =====================================================================
-- A) Asignar a mano un producto que no coincidió por nombre (ver Q01).
--    Reemplazar el nombre del producto y la clave de la plantilla (1a1 o grupal):
--
-- insert into public.cs_onboarding_plantilla_productos (producto_id, programa_id, plantilla_id)
-- select pr.id, pr.programa_id, pl.id
-- from public.cs_productos pr
-- join public.cs_onboarding_plantillas pl on pl.programa_id = pr.programa_id and pl.clave = '1a1'
-- where pr.programa_id = 'liam' and pr.nombre = 'NOMBRE EXACTO DEL PRODUCTO'
-- on conflict (producto_id) do update set plantilla_id = excluded.plantilla_id;
--
-- B) Duración real del Loom "Hoja de ruta" (hoy no se conoce: como el video es
--    opcional, solo se guardan los segundos que el alumno lo tuvo en pantalla y
--    no cuenta para "video visto"). Con la duración, el paso pasa a tener "visto":
--    poner los segundos reales y, si querés que cuente en la casilla, su casilla.
--    Lugar 4 de la plantilla 1a1 (0 = bienvenida, 1 = datos, 2 = diagnóstico,
--    3 = perfil, 4 = hoja de ruta). Ojo: volver a correr la 093 restaura el
--    texto del archivo.
--
-- update public.cs_onboarding_plantillas
--    set pasos = jsonb_set(jsonb_set(pasos, '{4,duracion_seg}', '420'::jsonb, true),
--                          '{4,casilla}', '"x_ob_video"'::jsonb, true),
--        updated_at = now()
--  where programa_id = 'liam' and clave = '1a1';
--
-- B2) Volver OBLIGATORIO un video (ejemplo: el de bienvenida de la 1a1, lugar 0).
--    Es solo el dato: la base exige el tiempo, el botón espera y el paso cuenta
--    en "hechos de total". El video tiene que tener duracion_seg o minimo_seg
--    (si no, la base rechaza el cambio).
--
-- update public.cs_onboarding_plantillas
--    set pasos = jsonb_set(pasos, '{0,obligatorio}', 'true'::jsonb, true), updated_at = now()
--  where programa_id = 'liam' and clave = '1a1';
--
-- C) Otro cliente (agus, teo): insertar una fila en cs_onboarding_plantillas con
--    sus pasos (mismo formato que la 093, validado por la base), asignarla a sus
--    productos como en A, y agregar en cs_maestro_columnas las casillas x_ob_*
--    que use (tipo casilla). No hace falta código.
