-- =====================================================================
-- 004_formularios_publicos.sql  —  Dystopia Seguimiento, FASE 5.1
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
--
-- Migración PURAMENTE ADITIVA sobre objetos cs_*: crea 3 funciones nuevas.
-- No modifica tablas, ni políticas, ni datos, ni nada crm_*.
-- No requiere backup previo. Es idempotente (create or replace).
--
-- Estructura:
--   1. cs_form_resolver()     -> table   (interna, nadie la ejecuta suelta)
--   2. cs_form_publico()      -> jsonb   (pública, execute para anon)
--   3. cs_enviar_respuesta()  -> jsonb   (pública, execute para anon)
--   4. Permisos
--   5. PRUEBA DE HUMO (crea datos, los verifica como anon y los deshace)
--   6. QUERY DE CONTROL
--
-- Qué se REUTILIZA de 001/002 (no se reimplementa nada de esto):
--   - cs_validar_campos(jsonb): el CHECK de cs_formularios.campos ya
--     garantiza array de {key,label,tipo,opciones,requerido,es_metrica},
--     keys únicas, 'opcion' con opciones y un solo es_metrica de tipo
--     escala_0_10. Acá NO se vuelve a validar la definición del
--     formulario: solo se valida la RESPUESTA contra esa definición.
--   - Trigger cs_tg_respuestas_programa (001): deriva programa_id desde
--     el formulario, verifica que el cliente sea del mismo programa y
--     extrae cs_respuestas.puntaje del campo es_metrica. Acá NO se
--     calcula el puntaje a mano: se inserta y se lee lo que dejó el
--     trigger.
--   - CHECK de cs_respuestas.respuestas: objeto y <= 20000 bytes. El
--     tope de 20 KB de acá es el mismo número, aplicado ANTES de
--     procesar para no trabajar sobre un payload gigante.
--   - cs_hoy(): el "día" del rate limit es el día de Buenos Aires.
--   - cs_alertas.clave_dedupe (unique, 001) es lo que evita alertas
--     duplicadas.
--   - cs_tg_accionables_estado (001): completa completado_at.
--
-- SEGURIDAD
--   - Las dos RPC son SECURITY DEFINER y son lo ÚNICO que anon puede
--     ejecutar. anon sigue sin ningún privilegio sobre ninguna tabla
--     cs_* (revoke de 001) y sin execute sobre ninguna otra función.
--   - Hacia afuera hay DOS mensajes fijos, ninguno más:
--       a) 'Link inválido o formulario no disponible'
--          Tokens, formulario inactivo, cliente en baja, cliente de otro
--          programa y rate limit. Todo lo que tiene que ver con SI el
--          link sirve. Uno solo para los cinco casos: el que tiene el
--          link no puede distinguir "formulario inexistente" de
--          "inactivo" ni de "cliente de otro programa".
--       b) 'Revisá los campos del formulario e intentá de nuevo'
--          Requerido faltante, opción inválida, escala fuera de rango,
--          tipo incorrecto y payload de más de 20 KB. No revela nada:
--          la definición de campos ya es pública vía cs_form_publico.
--     Cuál de los dos campos falló NO se dice: eso lo marca la
--     validación en el navegador (5.3).
--   - cs_form_publico devuelve del cliente SOLO el primer nombre. Ni
--     email, ni teléfono, ni estado, ni programa, ni ids.
-- =====================================================================

begin;

-- =====================================================================
-- 1. cs_form_resolver(p_form_token, p_cliente_token)
-- =====================================================================
-- Única implementación de "este par de tokens es válido". Las dos RPC
-- públicas la llaman: así la validación no está escrita dos veces y no
-- pueden quedar desalineadas.
--
-- Válido = el formulario existe y está activo, el cliente existe, es del
-- MISMO programa que el formulario y no está en baja.
-- Si no, levanta el mensaje (a) 'Link inválido o formulario no disponible'.
create or replace function public.cs_form_resolver(
  p_form_token    uuid,
  p_cliente_token uuid
)
returns table (
  formulario_id  uuid,
  programa_id    text,
  nombre_form    text,
  tipo           text,
  campos         jsonb,
  cliente_id     uuid,
  primer_nombre  text,
  umbral_bajo    numeric
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  return query
  select f.id,
         f.programa_id,
         f.nombre,
         f.tipo,
         f.campos,
         c.id,
         split_part(btrim(c.nombre), ' ', 1),
         p.satisfaccion_umbral_bajo
  from public.cs_formularios f
  join public.cs_clientes c
    on c.token_publico = p_cliente_token
   and c.programa_id   = f.programa_id      -- cliente y formulario del mismo programa
   and c.estado <> 'baja'
  join public.cs_programas p
    on p.id = f.programa_id
  where f.token = p_form_token
    and f.activo;

  if not found then
    raise exception 'Link inválido o formulario no disponible' using errcode = 'P0001';
  end if;
end;
$fn$;


-- =====================================================================
-- 2. cs_form_publico(p_form_token, p_cliente_token) -> jsonb
-- =====================================================================
-- Lo único que la página pública necesita para dibujar el formulario:
--   { nombre_formulario, campos, nombre_cliente }
-- nombre_cliente es SOLO el primer nombre. Nada más del cliente ni del
-- programa sale de acá.
create or replace function public.cs_form_publico(
  p_form_token    uuid,
  p_cliente_token uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  r record;
begin
  select * into r from public.cs_form_resolver(p_form_token, p_cliente_token);

  return jsonb_build_object(
    'nombre_formulario', r.nombre_form,
    'campos',            r.campos,
    'nombre_cliente',    r.primer_nombre
  );
end;
$fn$;


-- =====================================================================
-- 3. cs_enviar_respuesta(p_form_token, p_cliente_token, p_respuestas)
-- =====================================================================
-- Devuelve {"ok": true} o levanta uno de los dos mensajes fijos.
--
-- Orden: guardas baratas -> tokens -> rate limit -> validación de campos
-- -> insert -> alerta -> accionable de onboarding.
create or replace function public.cs_enviar_respuesta(
  p_form_token    uuid,
  p_cliente_token uuid,
  p_respuestas    jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  -- Mensaje (a): el link no sirve. Mismo texto que cs_form_resolver.
  -- Lo usan los tokens (vía la resolver) y el rate limit.
  c_msg      constant text := 'Link inválido o formulario no disponible';
  -- Mensaje (b): el link sirve, lo que vino mal es la respuesta.
  c_val      constant text := 'Revisá los campos del formulario e intentá de nuevo';
  -- Máximo de envíos por cliente, por formulario, por día (Buenos Aires).
  c_max_dia  constant int  := 5;
  -- Tope de la respuesta cruda, en bytes. Mismo número que el CHECK de
  -- cs_respuestas.respuestas en 001.
  c_max_byte constant int  := 20000;
  -- Key de la plantilla de accionables que cierra el formulario de
  -- onboarding. Es la key de 002 para 'liam'; el título es editable
  -- desde Config, la key no.
  c_key_onb  constant text := 'formulario_onboarding';

  r          record;
  v_campo    jsonb;
  v_key      text;
  v_tipo     text;
  v_val      jsonb;
  v_txt      text;
  v_limpias  jsonb := '{}'::jsonb;
  v_id       uuid;
  v_puntaje  numeric;
  v_n        int;
begin
  -- ---------- guardas baratas sobre el payload ----------
  if p_respuestas is null or jsonb_typeof(p_respuestas) is distinct from 'object' then
    raise exception '%', c_val using errcode = 'P0001';
  end if;
  if octet_length(p_respuestas::text) > c_max_byte then
    raise exception '%', c_val using errcode = 'P0001';
  end if;

  -- ---------- tokens (mismas validaciones que cs_form_publico) ----------
  select * into r from public.cs_form_resolver(p_form_token, p_cliente_token);

  -- ---------- rate limit: 5 por cliente por formulario por día ----------
  select count(*) into v_n
  from public.cs_respuestas x
  where x.cliente_id    = r.cliente_id
    and x.formulario_id = r.formulario_id
    and (x.created_at at time zone 'America/Argentina/Buenos_Aires')::date = public.cs_hoy();

  if v_n >= c_max_dia then
    raise exception '%', c_msg using errcode = 'P0001';
  end if;

  -- ---------- requeridos y tipos contra campos ----------
  -- Se recorre la DEFINICIÓN, no el payload: las keys que no existan en
  -- campos quedan afuera solas (nunca se copian a v_limpias).
  for v_campo in select e from jsonb_array_elements(r.campos) e loop
    v_key  := v_campo->>'key';
    v_tipo := v_campo->>'tipo';
    v_val  := p_respuestas->v_key;

    -- ausente, null o string vacío = sin contestar
    if v_val is null
       or jsonb_typeof(v_val) = 'null'
       or (jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') = '') then
      if coalesce(v_campo->>'requerido', 'false') = 'true' then
        raise exception '%', c_val using errcode = 'P0001';
      end if;
      continue;
    end if;

    -- ningún campo acepta objetos ni arrays
    if jsonb_typeof(v_val) in ('object', 'array') then
      raise exception '%', c_val using errcode = 'P0001';
    end if;

    v_txt := btrim(v_val #>> '{}');   -- el escalar, como texto

    if v_tipo in ('texto', 'parrafo') then
      v_val := to_jsonb(v_txt);

    elsif v_tipo = 'numero' then
      if v_txt !~ '^-?\d+(\.\d+)?$' then
        raise exception '%', c_val using errcode = 'P0001';
      end if;
      v_val := to_jsonb(v_txt::numeric);

    elsif v_tipo = 'escala_0_10' then
      -- se guarda como número: así el trigger cs_tg_respuestas_programa
      -- lo reconoce con su regex y completa puntaje.
      if v_txt !~ '^\d+(\.\d+)?$' or v_txt::numeric not between 0 and 10 then
        raise exception '%', c_val using errcode = 'P0001';
      end if;
      v_val := to_jsonb(v_txt::numeric);

    elsif v_tipo = 'opcion' then
      if not exists (
        select 1 from jsonb_array_elements_text(v_campo->'opciones') o where o = v_txt
      ) then
        raise exception '%', c_val using errcode = 'P0001';
      end if;
      v_val := to_jsonb(v_txt);

    elsif v_tipo = 'si_no' then
      if lower(v_txt) in ('true', 'si', 'sí', '1') then
        v_val := to_jsonb(true);
      elsif lower(v_txt) in ('false', 'no', '0') then
        v_val := to_jsonb(false);
      else
        raise exception '%', c_val using errcode = 'P0001';
      end if;

    else
      -- inalcanzable: cs_validar_campos no deja guardar otros tipos
      raise exception '%', c_val using errcode = 'P0001';
    end if;

    v_limpias := v_limpias || jsonb_build_object(v_key, v_val);
  end loop;

  -- ---------- insert ----------
  -- programa_id y puntaje los completa cs_tg_respuestas_programa (001).
  insert into public.cs_respuestas (programa_id, formulario_id, cliente_id, respuestas)
  values (r.programa_id, r.formulario_id, r.cliente_id, v_limpias)
  returning id, puntaje into v_id, v_puntaje;

  -- ---------- alerta de satisfacción baja ----------
  -- Una alerta por respuesta (la clave lleva el id de la respuesta), así
  -- dos respuestas bajas del mismo cliente no se pisan. La resuelve una
  -- persona: cs_generar_alertas (003) no toca este tipo.
  if v_puntaje is not null and v_puntaje <= r.umbral_bajo then
    insert into public.cs_alertas (programa_id, cliente_id, tipo, mensaje, clave_dedupe)
    values (r.programa_id,
            r.cliente_id,
            'satisfaccion_baja',
            format('Satisfacción %s/10 en "%s"', v_puntaje, r.nombre_form),
            'satisfaccion_baja:' || v_id)
    on conflict (clave_dedupe) do nothing;
  end if;

  -- ---------- accionable de onboarding ----------
  -- Se busca por plantilla_key, NO por título (el título se edita desde
  -- Config). completado_at lo pone cs_tg_accionables_estado (001).
  if r.tipo = 'onboarding' then
    update public.cs_accionables a
       set estado = 'completado'
     where a.cliente_id    = r.cliente_id
       and a.plantilla_key = c_key_onb
       and a.estado <> 'completado';
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;


-- =====================================================================
-- 4. PERMISOS
-- =====================================================================
-- Nada para public. anon SOLO las dos RPC (ninguna tabla, ninguna otra
-- función: eso ya lo dejó 001 y esta migración no lo toca).
revoke all on function
  public.cs_form_resolver(uuid, uuid),
  public.cs_form_publico(uuid, uuid),
  public.cs_enviar_respuesta(uuid, uuid, jsonb)
from public, anon, authenticated;

-- cs_form_resolver es interna: la llaman las dos RPC, que corren como
-- dueño. Nadie más la ejecuta (ni anon ni authenticated).

grant execute on function
  public.cs_form_publico(uuid, uuid),
  public.cs_enviar_respuesta(uuid, uuid, jsonb)
to anon;

-- También para authenticated: form.html vive en el mismo origen que la
-- app, así que supabase-js le restaura la sesión al que ya está logueado
-- y manda el JWT (rol authenticated). Sin este grant, abrir el link
-- estando logueado daría "permission denied" en vez de funcionar.
grant execute on function
  public.cs_form_publico(uuid, uuid),
  public.cs_enviar_respuesta(uuid, uuid, jsonb)
to authenticated;

commit;


-- =====================================================================
-- 5. PRUEBA DE HUMO (no deja datos)
-- =====================================================================
-- Crea formularios y clientes de prueba, ejercita las dos RPC CON EL ROL
-- anon (set local role anon), verifica que anon NO pueda leer ninguna
-- tabla cs_ ni llamar la resolver, y después fuerza un error para
-- deshacer TODO. Los resultados se juntan en una variable, que sobrevive
-- al rollback, y se vuelcan a una tabla temporal.
drop table if exists pg_temp.cs_smoke4;
create temp table cs_smoke4 (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res       text[] := '{}';
  -- Los dos mensajes fijos: cada rechazo tiene que dar EXACTAMENTE uno
  -- de estos dos, y el que le corresponde.
  c_msg     constant text := 'Link inválido o formulario no disponible';
  c_val     constant text := 'Revisá los campos del formulario e intentá de nuevo';

  v_prog_b  text;
  v_form_a  uuid;   -- satisfacción, activo
  v_form_b  uuid;   -- onboarding, activo
  v_form_c  uuid;   -- satisfacción, INACTIVO
  v_tok_a   uuid;
  v_tok_b   uuid;
  v_tok_c   uuid;
  v_cli_a   uuid;   -- liam, onboarding
  v_cli_b   uuid;   -- liam, baja
  v_cli_c   uuid;   -- otro programa
  v_ctok_a  uuid;
  v_ctok_b  uuid;
  v_ctok_c  uuid;

  v_j       jsonb;
  v_n       int;
  v_n2      int;
  v_txt     text;
  v_bool    boolean;
  v_i       int;
  v_tabla   text;
begin
  begin
    -- =================================================================
    -- datos de prueba (como dueño)
    -- =================================================================
    select p.id into v_prog_b from public.cs_programas p where p.id <> 'liam' limit 1;

    insert into public.cs_formularios (programa_id, nombre, tipo, activo, campos)
    values ('liam', '__humo004_satisfaccion__', 'satisfaccion', true, '[
      {"key":"nps",        "label":"Puntaje",     "tipo":"escala_0_10", "requerido":true,  "es_metrica":true},
      {"key":"comentario", "label":"Comentario",  "tipo":"parrafo",     "requerido":false},
      {"key":"canal",      "label":"Canal",       "tipo":"opcion",      "requerido":false, "opciones":["whatsapp","mail"]},
      {"key":"recomienda", "label":"Recomendas?", "tipo":"si_no",       "requerido":false}
    ]'::jsonb)
    returning id, token into v_form_a, v_tok_a;

    insert into public.cs_formularios (programa_id, nombre, tipo, activo, campos)
    values ('liam', '__humo004_onboarding__', 'onboarding', true, '[
      {"key":"objetivo", "label":"Objetivo", "tipo":"texto", "requerido":true}
    ]'::jsonb)
    returning id, token into v_form_b, v_tok_b;

    insert into public.cs_formularios (programa_id, nombre, tipo, activo, campos)
    values ('liam', '__humo004_inactivo__', 'satisfaccion', false, '[
      {"key":"nps", "label":"Puntaje", "tipo":"escala_0_10", "requerido":true, "es_metrica":true}
    ]'::jsonb)
    returning id, token into v_form_c, v_tok_c;

    -- cliente A: nombre compuesto, arranca en onboarding -> el trigger
    -- de 001 le crea el accionable de plantilla 'formulario_onboarding'
    insert into public.cs_clientes (programa_id, nombre, email, telefono, estado)
    values ('liam', '__humo004a__ Perez Gomez', 'humo004a@ejemplo.com', '+5491100000000', 'onboarding')
    returning id, token_publico into v_cli_a, v_ctok_a;

    insert into public.cs_clientes (programa_id, nombre, estado)
    values ('liam', '__humo004b__ Baja', 'baja')
    returning id, token_publico into v_cli_b, v_ctok_b;

    if v_prog_b is not null then
      insert into public.cs_clientes (programa_id, nombre, estado)
      values (v_prog_b, '__humo004c__ Otro programa', 'activo')
      returning id, token_publico into v_cli_c, v_ctok_c;
    end if;

    -- 0. el trigger de 001 dejó el accionable de onboarding pendiente
    select count(*) into v_n from public.cs_accionables a
    where a.cliente_id = v_cli_a and a.plantilla_key = 'formulario_onboarding'
      and a.estado <> 'completado';
    res := res || format('el cliente nuevo arranca con el accionable de onboarding pendiente|%s|n=%s',
                         v_n = 1, v_n);

    -- =================================================================
    -- A PARTIR DE ACÁ, TODO COMO anon
    -- =================================================================
    execute 'set local role anon';

    -- 1. cs_form_publico devuelve exactamente 3 claves
    v_j := public.cs_form_publico(v_tok_a, v_ctok_a);
    select count(*) into v_n from jsonb_object_keys(v_j) k;
    res := res || format('cs_form_publico devuelve solo 3 claves|%s|claves=%s',
                         v_n = 3 and v_j ? 'nombre_formulario' and v_j ? 'campos' and v_j ? 'nombre_cliente',
                         (select string_agg(k, ',' order by k) from jsonb_object_keys(v_j) k));

    -- 2. solo el primer nombre del cliente
    res := res || format('cs_form_publico devuelve solo el primer nombre|%s|nombre_cliente=%s',
                         v_j->>'nombre_cliente' = '__humo004a__', v_j->>'nombre_cliente');

    -- 3. no se filtra ningún otro dato del cliente ni del programa
    res := res || format('no filtra email/telefono/ids/programa|%s|%s',
                         v_j::text not like '%humo004a@ejemplo.com%'
                         and v_j::text not like '%+5491100000000%'
                         and v_j::text not like '%liam%'
                         and v_j::text not like '%' || v_cli_a::text || '%',
                         'sin datos extra');

    -- 4. formulario inactivo -> mensaje (a) de link
    begin
      v_j := public.cs_form_publico(v_tok_c, v_ctok_a);
      res := res || 'formulario inactivo -> mensaje (a) de link|false|no dio error';
    exception when others then
      res := res || format('formulario inactivo -> mensaje (a) de link|%s|%s', sqlerrm = c_msg, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 5. cliente en baja -> mismo mensaje
    begin
      v_j := public.cs_form_publico(v_tok_a, v_ctok_b);
      res := res || 'cliente en baja -> mensaje (a) de link|false|no dio error';
    exception when others then
      res := res || format('cliente en baja -> mensaje (a) de link|%s|%s', sqlerrm = c_msg, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 6. cliente de otro programa -> mismo mensaje
    if v_ctok_c is not null then
      begin
        v_j := public.cs_form_publico(v_tok_a, v_ctok_c);
        res := res || 'cliente de otro programa -> mensaje (a) de link|false|no dio error';
      exception when others then
        res := res || format('cliente de otro programa -> mensaje (a) de link|%s|%s', sqlerrm = c_msg, replace(sqlerrm, '|', '/'));
      end;
      execute 'set local role anon';
    else
      res := res || 'cliente de otro programa -> mensaje (a) de link|true|salteado: no hay otro programa';
    end if;

    -- 7. token de formulario inexistente -> mismo mensaje
    begin
      v_j := public.cs_form_publico(gen_random_uuid(), v_ctok_a);
      res := res || 'token de formulario inexistente -> mensaje (a) de link|false|no dio error';
    exception when others then
      res := res || format('token de formulario inexistente -> mensaje (a) de link|%s|%s', sqlerrm = c_msg, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 8. envío válido con puntaje bajo, y dos keys que no existen en campos
    v_j := public.cs_enviar_respuesta(v_tok_a, v_ctok_a, jsonb_build_object(
      'nps',        '3',
      'comentario', '  esto se limpia  ',
      'canal',      'whatsapp',
      'recomienda', 'no',
      'no_existe',  'basura',
      'programa_id', 'agus'
    ));
    res := res || format('cs_enviar_respuesta devuelve ok|%s|%s', v_j->>'ok' = 'true', v_j::text);

    execute 'reset role';

    -- 9. quedó una respuesta, con programa_id y puntaje del trigger de 001
    select x.respuestas, x.puntaje, x.programa_id into v_j, v_n2, v_txt
    from public.cs_respuestas x where x.formulario_id = v_form_a;
    res := res || format('el trigger de 001 completa programa_id y puntaje|%s|programa=%s puntaje=%s',
                         v_txt = 'liam' and v_n2 = 3, v_txt, v_n2);

    -- 10. se ignoran las keys que no existen en campos
    select count(*) into v_n from jsonb_object_keys(v_j) k;
    res := res || format('ignora las keys que no existen en campos|%s|claves=%s',
                         v_n = 4 and not (v_j ? 'no_existe') and not (v_j ? 'programa_id'),
                         (select string_agg(k, ',' order by k) from jsonb_object_keys(v_j) k));

    -- 11. tipos normalizados: número, texto trimeado, booleano
    res := res || format('normaliza tipos (numero / texto trimeado / si_no)|%s|nps=%s comentario=[%s] recomienda=%s',
                         jsonb_typeof(v_j->'nps') = 'number'
                         and v_j->>'comentario' = 'esto se limpia'
                         and v_j->'recomienda' = 'false'::jsonb,
                         v_j->>'nps', v_j->>'comentario', v_j->>'recomienda');

    -- 12. alerta de satisfacción baja (umbral de liam = 6, puntaje 3)
    select count(*) into v_n from public.cs_alertas a
    where a.cliente_id = v_cli_a and a.tipo = 'satisfaccion_baja' and not a.resuelta;
    res := res || format('puntaje bajo crea alerta satisfaccion_baja|%s|n=%s', v_n = 1, v_n);

    -- 13. un formulario que no es de onboarding no toca el accionable
    select count(*) into v_n from public.cs_accionables a
    where a.cliente_id = v_cli_a and a.plantilla_key = 'formulario_onboarding'
      and a.estado = 'completado';
    res := res || format('un formulario que no es onboarding no cierra el accionable|%s|completados=%s',
                         v_n = 0, v_n);

    -- =================================================================
    execute 'set local role anon';

    -- 14. falta un requerido -> mensaje (b) de campos
    begin
      v_j := public.cs_enviar_respuesta(v_tok_a, v_ctok_a, '{"comentario":"sin puntaje"}'::jsonb);
      res := res || 'requerido faltante -> mensaje (b) de campos|false|no dio error';
    exception when others then
      res := res || format('requerido faltante -> mensaje (b) de campos|%s|%s', sqlerrm = c_val, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 15. opción fuera de la lista -> mensaje (b) de campos
    begin
      v_j := public.cs_enviar_respuesta(v_tok_a, v_ctok_a, '{"nps":"8","canal":"paloma"}'::jsonb);
      res := res || 'opcion invalida -> mensaje (b) de campos|false|no dio error';
    exception when others then
      res := res || format('opcion invalida -> mensaje (b) de campos|%s|%s', sqlerrm = c_val, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 16. escala fuera de 0..10 -> mensaje (b) de campos
    begin
      v_j := public.cs_enviar_respuesta(v_tok_a, v_ctok_a, '{"nps":"11"}'::jsonb);
      res := res || 'escala fuera de 0..10 -> mensaje (b) de campos|false|no dio error';
    exception when others then
      res := res || format('escala fuera de 0..10 -> mensaje (b) de campos|%s|%s', sqlerrm = c_val, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 17. payload de más de 20 KB -> mensaje (b) de campos
    begin
      v_j := public.cs_enviar_respuesta(v_tok_a, v_ctok_a,
               jsonb_build_object('nps', '8', 'comentario', repeat('x', 25000)));
      res := res || 'payload > 20 KB -> mensaje (b) de campos|false|no dio error';
    exception when others then
      res := res || format('payload > 20 KB -> mensaje (b) de campos|%s|%s', sqlerrm = c_val, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 18. rate limit: ya hay 1 envío bueno; 4 más llegan a 5, el 6to falla con el mensaje (a) de link
    for v_i in 2..5 loop
      v_j := public.cs_enviar_respuesta(v_tok_a, v_ctok_a, jsonb_build_object('nps', '9'));
    end loop;
    begin
      v_j := public.cs_enviar_respuesta(v_tok_a, v_ctok_a, jsonb_build_object('nps', '9'));
      res := res || 'rate limit corta en 5 -> mensaje (a) de link|false|el 6to envio paso';
    exception when others then
      res := res || format('rate limit corta en 5 -> mensaje (a) de link|%s|%s', sqlerrm = c_msg, replace(sqlerrm, '|', '/'));
    end;
    execute 'set local role anon';

    -- 19. el rate limit es POR formulario: el de onboarding sigue libre
    v_j := public.cs_enviar_respuesta(v_tok_b, v_ctok_a, '{"objetivo":"ordenar mi portafolio"}'::jsonb);
    res := res || format('el rate limit es por formulario, no por cliente|%s|%s',
                         v_j->>'ok' = 'true', v_j::text);

    -- =================================================================
    -- 20..22. anon no puede tocar NADA fuera de las dos RPC
    -- =================================================================
    v_n := 0;
    foreach v_tabla in array array['cs_programas','cs_integraciones','cs_clientes','cs_accionables',
                                   'cs_devoluciones','cs_calls','cs_renovaciones','cs_formularios',
                                   'cs_respuestas','cs_chequeos','cs_historial','cs_alertas'] loop
      begin
        execute format('select 1 from public.%I limit 1', v_tabla);
        -- si llegó acá, anon pudo leer: no se cuenta como denegada
      exception when others then
        if sqlstate = '42501' then v_n := v_n + 1; end if;
      end;
      execute 'set local role anon';
    end loop;
    res := res || format('anon no puede leer ninguna tabla cs_|%s|denegadas=%s de 12', v_n = 12, v_n);

    -- 21. anon tampoco puede llamar la resolver ni cs_hoy
    v_n := 0;
    begin
      perform * from public.cs_form_resolver(v_tok_a, v_ctok_a);
    exception when others then
      if sqlstate = '42501' then v_n := v_n + 1; end if;
    end;
    execute 'set local role anon';
    begin
      perform public.cs_hoy();
    exception when others then
      if sqlstate = '42501' then v_n := v_n + 1; end if;
    end;
    execute 'set local role anon';
    res := res || format('anon no puede ejecutar cs_form_resolver ni cs_hoy|%s|denegadas=%s de 2', v_n = 2, v_n);

    -- 22. anon no puede insertar en cs_respuestas por fuera de la RPC
    v_txt := '(sin error)';
    begin
      execute format('insert into public.cs_respuestas (programa_id, formulario_id, cliente_id, respuestas)
                      values (%L, %L, %L, %L::jsonb)', 'liam', v_form_a, v_cli_a, '{"nps":10}');
      v_bool := false;
    exception when others then
      v_bool := (sqlstate = '42501');
      v_txt  := sqlstate;
    end;
    execute 'reset role';
    res := res || format('anon no puede insertar directo en cs_respuestas|%s|sqlstate=%s', v_bool, v_txt);

    -- =================================================================
    -- de vuelta como dueño: efectos del formulario de onboarding
    -- =================================================================
    -- 23. el envío del formulario de onboarding cerró el accionable
    select count(*) into v_n from public.cs_accionables a
    where a.cliente_id = v_cli_a and a.plantilla_key = 'formulario_onboarding'
      and a.estado = 'completado' and a.completado_at is not null;
    res := res || format('el formulario de onboarding cierra el accionable por plantilla_key|%s|completados=%s',
                         v_n = 1, v_n);

    -- 24. el rate limit dejó pasar exactamente 5
    select count(*) into v_n from public.cs_respuestas x where x.formulario_id = v_form_a;
    res := res || format('quedaron exactamente 5 respuestas en el formulario|%s|n=%s', v_n = 5, v_n);

    -- 25. solo la respuesta bajo el umbral generó alerta (las de 9 no)
    select count(*) into v_n from public.cs_alertas a
    where a.cliente_id = v_cli_a and a.tipo = 'satisfaccion_baja';
    res := res || format('solo las respuestas bajo el umbral alertan|%s|alertas=%s', v_n = 1, v_n);

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s (%s)', replace(sqlerrm, '|', '/'), sqlstate);
    end if;
  end;

  execute 'reset role';

  insert into cs_smoke4 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 6. QUERY DE CONTROL (una sola tabla de resultados; mirar la columna ok)
-- =====================================================================
with
nuevas as (
  select p.oid,
         p.proname::text as proname,
         p.prosecdef,
         coalesce(array_to_string(p.proconfig, ','), '') as config
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('cs_form_resolver', 'cs_form_publico', 'cs_enviar_respuesta')
),
anon_tablas as (
  select c.relname::text as tabla,
         coalesce(array_to_string(array(
           select pr from unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) pr
           where has_table_privilege('anon', c.oid, pr)
         ), ','), '') as privs
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'v') and c.relname like 'cs\_%'
),
anon_funcs as (
  -- toda función cs_* que anon pueda ejecutar
  select p.proname::text as proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname like 'cs\_%'
    and has_function_privilege('anon', p.oid, 'EXECUTE')
)
select '01 funciones nuevas' as control, 'cantidad' as objeto, '3' as esperado,
       (select count(*) from nuevas)::text as obtenido, (select count(*) from nuevas) = 3 as ok
union all
select '02 security definer', f.proname, 'true', f.prosecdef::text, f.prosecdef from nuevas f
union all
select '03 search_path', f.proname, 'search_path=public', f.config, f.config ~ 'search_path=public' from nuevas f
union all
select '04 execute para anon', f.proname,
       case when f.proname = 'cs_form_resolver' then 'false' else 'true' end,
       has_function_privilege('anon', f.oid, 'EXECUTE')::text,
       has_function_privilege('anon', f.oid, 'EXECUTE') = (f.proname <> 'cs_form_resolver')
from nuevas f
union all
select '05 execute para authenticated', f.proname,
       case when f.proname = 'cs_form_resolver' then 'false' else 'true' end,
       has_function_privilege('authenticated', f.oid, 'EXECUTE')::text,
       has_function_privilege('authenticated', f.oid, 'EXECUTE') = (f.proname <> 'cs_form_resolver')
from nuevas f
union all
select '06 anon sin privilegios en tablas/vistas cs_', 'objetos con algun privilegio', '0',
       coalesce((select string_agg(tabla || '(' || privs || ')', ', ' order by tabla)
                 from anon_tablas where privs <> ''), '0'),
       (select count(*) from anon_tablas where privs <> '') = 0
union all
select '07 anon ejecuta SOLO las dos RPC', 'funciones cs_ ejecutables por anon',
       'cs_enviar_respuesta, cs_form_publico',
       coalesce((select string_agg(proname, ', ' order by proname) from anon_funcs), '(ninguna)'),
       coalesce((select string_agg(proname, ', ' order by proname) from anon_funcs), '')
         = 'cs_enviar_respuesta, cs_form_publico'
union all
select '08 la prueba de humo no dejo datos', 'formularios __humo004_*', '0',
       (select count(*) from public.cs_formularios where nombre like '\_\_humo004\_%')::text,
       (select count(*) from public.cs_formularios where nombre like '\_\_humo004\_%') = 0
union all
select '08 la prueba de humo no dejo datos', 'clientes __humo004*', '0',
       (select count(*) from public.cs_clientes where nombre like '\_\_humo004%')::text,
       (select count(*) from public.cs_clientes where nombre like '\_\_humo004%') = 0
union all
select '08 la prueba de humo no dejo datos', 'alertas satisfaccion_baja sin cliente', '0',
       (select count(*) from public.cs_alertas a
         where a.tipo = 'satisfaccion_baja' and a.cliente_id is null)::text,
       (select count(*) from public.cs_alertas a
         where a.tipo = 'satisfaccion_baja' and a.cliente_id is null) = 0
union all
select '09 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke4 s
order by 1, 2;
