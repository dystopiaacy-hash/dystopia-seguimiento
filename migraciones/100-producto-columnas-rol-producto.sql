-- =====================================================================
-- 100-producto-columnas-rol-producto.sql  ·  PRODUCTO: el CSM configura las columnas
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global asignada por el jefe: 100.
-- Evitar :00, :15, :30 y :45 y las 9:00.
--
-- Pedido: el rol producto (producto@liam) tiene que poder mover, ocultar,
-- renombrar y agregar columnas del Maestro. La configuración ya es UNA SOLA
-- por programa (cs_maestro_columnas.programa_id), compartida por todos los
-- que entran a ese programa: no hay config por usuario ni en localStorage.
-- Borrar columnas (archivar y recuperar) sigue SOLO para el fundador.
--
-- Cómo estaba: las 4 funciones de estructura de la 071 llamaban a
-- cs_maestro_exigir_fundador() y daban 42501 a cualquiera que no fuera
-- fundador, aunque tuviera nivel 'edicion' en cs_accesos (079).
--
-- Qué hace:
--   1. cs_maestro_exigir_edicion(programa): exige cs_puede_editar(programa)
--      (fundador, o nivel 'edicion' en ESE programa). 'lectura' (cliente@)
--      sigue sin poder: 42501.
--   2. Reemplaza (create or replace, misma firma, mismos grants) las funciones
--      que cambian estructura SIN borrar:
--        cs_maestro_columna_guardar    (renombrar, ocultar/mostrar, opciones)
--        cs_maestro_columna_crear      (columna nueva, mismos 6 tipos)
--        cs_maestro_columnas_ordenar   (mover)
--        cs_maestro_opcion_renombrar   (renombrar opción y valores cargados)
--      Cuerpo idéntico al de la 071; solo cambia el chequeo de permiso.
--   3. NO cambia cs_maestro_columna_archivar (borrar): sigue exigiendo
--      fundador. La tabla cs_maestro_columnas no tiene permiso de escritura
--      para authenticated (solo select), así que no hay otro camino por API.
--   4. cs_guardar_campo_extra (cargar datos) no se toca: ya es security invoker
--      y escribe por la RLS de cs_clientes (cs_puede_editar, 079).
--
-- No pisa datos: no modifica filas de cs_maestro_columnas ni de cs_clientes.
-- La configuración actual (orden, ocultas, nombres, columnas nuevas) queda como está.
-- Respaldo de las 4 definiciones viejas en cs_bak_100_funciones.
-- No hay políticas RLS nuevas, por eso no hay helpers que envolver en (select ...).
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo: lo que usa esta migración tiene que existir.
do $$
declare
  v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values
    ('cs_puede_editar(text)'), ('cs_maestro_exigir_fundador()'), ('cs_maestro_opciones_limpias(jsonb)'),
    ('cs_maestro_claves_sistema()'), ('cs_maestro_columna_archivar(text,text,boolean)')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 100: faltan funciones (corrieron la 071 y la 079?): %', v_falta;
  end if;
  if to_regclass('public.cs_maestro_columnas') is null then
    raise exception 'cs 100: falta la tabla cs_maestro_columnas (071)';
  end if;
end $$;

-- Respaldo de las definiciones que se reemplazan.
create table if not exists public.cs_bak_100_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_100_funciones from public, anon, authenticated;

insert into public.cs_bak_100_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('cs_maestro_columna_guardar', 'cs_maestro_columna_crear',
                    'cs_maestro_columnas_ordenar', 'cs_maestro_opcion_renombrar')
on conflict (funcion) do nothing;


-- =====================================================================
-- 1. PERMISO DE ESTRUCTURA: quien edita el programa
-- =====================================================================
create or replace function public.cs_maestro_exigir_edicion(p_programa text)
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.cs_puede_editar(p_programa), false) then
    raise exception 'cs: no tenés permiso para cambiar las columnas de este programa' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.cs_maestro_exigir_edicion(text) from public, anon, authenticated;


-- =====================================================================
-- 2. FUNCIONES QUE CAMBIAN ESTRUCTURA SIN BORRAR (cuerpo de la 071)
-- =====================================================================
create or replace function public.cs_maestro_columna_guardar(
  p_programa text,
  p_clave    text,
  p_etiqueta text,
  p_visible  boolean default true,
  p_opciones jsonb default null
)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_col public.cs_maestro_columnas%rowtype;
  v_et  text := nullif(btrim(coalesce(p_etiqueta, '')), '');
begin
  perform public.cs_maestro_exigir_edicion(p_programa);

  select * into v_col from public.cs_maestro_columnas
  where programa_id = p_programa and clave = p_clave;

  if v_col.id is null then
    if not (p_clave = any (public.cs_maestro_claves_sistema())) then
      raise exception 'cs: la columna % no existe en el programa %', p_clave, p_programa using errcode = 'P0002';
    end if;
    insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, visible)
    values (p_programa, p_clave, true, v_et, coalesce(p_visible, true));
    return;
  end if;

  if not v_col.sistema and v_et is null then
    raise exception 'cs: una columna nueva necesita nombre' using errcode = '22023';
  end if;

  -- No toca archivada: archivar y recuperar es solo del fundador.
  update public.cs_maestro_columnas
     set etiqueta   = v_et,
         visible    = coalesce(p_visible, visible),
         opciones   = case when tipo = 'opcion' and p_opciones is not null
                           then public.cs_maestro_opciones_limpias(p_opciones) else opciones end,
         updated_at = now()
   where id = v_col.id;
end;
$fn$;

create or replace function public.cs_maestro_columna_crear(
  p_programa text,
  p_etiqueta text,
  p_tipo     text,
  p_opciones jsonb default '[]'::jsonb
)
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  v_et    text := nullif(btrim(coalesce(p_etiqueta, '')), '');
  v_slug  text;
  v_clave text;
  v_orden int;
begin
  perform public.cs_maestro_exigir_edicion(p_programa);
  if v_et is null then
    raise exception 'cs: la columna necesita nombre' using errcode = '22023';
  end if;
  if p_tipo not in ('texto','numero','fecha','casilla','opcion','link') then
    raise exception 'cs: tipo de columna inválido (%)', p_tipo using errcode = '22023';
  end if;
  if not exists (select 1 from public.cs_programas where id = p_programa) then
    raise exception 'cs: el programa % no existe', p_programa using errcode = 'P0002';
  end if;

  v_slug := left(trim(both '_' from regexp_replace(
              translate(lower(v_et), 'áéíóúñü', 'aeiounu'), '[^a-z0-9]+', '_', 'g')), 40);
  if v_slug = '' then v_slug := 'col'; end if;
  v_clave := 'x_' || v_slug || '_' || substr(md5(random()::text || clock_timestamp()::text), 1, 4);

  select coalesce(max(orden), 1000) + 1 into v_orden
  from public.cs_maestro_columnas where programa_id = p_programa;

  insert into public.cs_maestro_columnas (programa_id, clave, sistema, etiqueta, orden, tipo, opciones)
  values (p_programa, v_clave, false, v_et, v_orden, p_tipo,
          case when p_tipo = 'opcion' then public.cs_maestro_opciones_limpias(coalesce(p_opciones, '[]'::jsonb))
               else '[]'::jsonb end);
  return v_clave;
end;
$fn$;

create or replace function public.cs_maestro_columnas_ordenar(p_programa text, p_claves text[])
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_mal text;
begin
  perform public.cs_maestro_exigir_edicion(p_programa);
  if p_claves is null or cardinality(p_claves) = 0 then
    raise exception 'cs: falta el orden de las columnas' using errcode = '22023';
  end if;
  if cardinality(p_claves) <> (select count(distinct x) from unnest(p_claves) x) then
    raise exception 'cs: hay columnas repetidas en el orden' using errcode = '22023';
  end if;

  select x into v_mal from unnest(p_claves) x
  where not (x = any (public.cs_maestro_claves_sistema()))
    and not exists (select 1 from public.cs_maestro_columnas c
                    where c.programa_id = p_programa and c.clave = x and not c.sistema)
  limit 1;
  if v_mal is not null then
    raise exception 'cs: la columna % no existe en el programa %', v_mal, p_programa using errcode = 'P0002';
  end if;

  insert into public.cs_maestro_columnas (programa_id, clave, sistema, orden)
  select p_programa, x, true, (o * 10)::int
  from unnest(p_claves) with ordinality as t(x, o)
  where x = any (public.cs_maestro_claves_sistema())
  on conflict (programa_id, clave) do update
    set orden = excluded.orden, updated_at = now();

  update public.cs_maestro_columnas c
     set orden = (t.o * 10)::int, updated_at = now()
  from unnest(p_claves) with ordinality as t(x, o)
  where c.programa_id = p_programa and c.clave = t.x and not c.sistema;
end;
$fn$;

create or replace function public.cs_maestro_opcion_renombrar(
  p_programa text, p_clave text, p_viejo text, p_nuevo text)
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_col public.cs_maestro_columnas%rowtype;
  v_nuevo text := btrim(coalesce(p_nuevo, ''));
  v_n int;
begin
  perform public.cs_maestro_exigir_edicion(p_programa);
  select * into v_col from public.cs_maestro_columnas
  where programa_id = p_programa and clave = p_clave and tipo = 'opcion';
  if v_col.id is null then
    raise exception 'cs: % no es una columna de opciones', p_clave using errcode = 'P0002';
  end if;
  if v_nuevo = '' then
    raise exception 'cs: la opción necesita nombre' using errcode = '22023';
  end if;
  if not (v_col.opciones ? p_viejo) then
    raise exception 'cs: la opción "%" no existe', p_viejo using errcode = 'P0002';
  end if;

  update public.cs_maestro_columnas
     set opciones = public.cs_maestro_opciones_limpias(
                      (select jsonb_agg(case when e = p_viejo then v_nuevo else e end order by o)
                       from jsonb_array_elements_text(opciones) with ordinality as t(e, o))),
         updated_at = now()
   where id = v_col.id;

  update public.cs_clientes
     set campos_extra = jsonb_set(campos_extra, array[p_clave], to_jsonb(v_nuevo))
   where programa_id = p_programa and campos_extra->>p_clave = p_viejo;
  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;

-- Mismos permisos que la 071 (create or replace los conserva; se repiten por claridad).
revoke all on function public.cs_maestro_columna_guardar(text, text, text, boolean, jsonb) from public, anon;
revoke all on function public.cs_maestro_columna_crear(text, text, text, jsonb) from public, anon;
revoke all on function public.cs_maestro_columnas_ordenar(text, text[]) from public, anon;
revoke all on function public.cs_maestro_opcion_renombrar(text, text, text, text) from public, anon;
grant execute on function public.cs_maestro_columna_guardar(text, text, text, boolean, jsonb) to authenticated;
grant execute on function public.cs_maestro_columna_crear(text, text, text, jsonb) to authenticated;
grant execute on function public.cs_maestro_columnas_ordenar(text, text[]) to authenticated;
grant execute on function public.cs_maestro_opcion_renombrar(text, text, text, text) to authenticated;


-- =====================================================================
-- 3. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
do $humo$
declare
  v_prog text := 'humo100';
  v_fund uuid;
  v_edit uuid;
  v_lect uuid;
  v_k    text;
  v_err  text;
begin
  begin
    select user_id into v_fund from public.crm_members where rol = 'fundador' limit 1;
    select u.id into v_edit from auth.users u
      where u.id <> v_fund and not exists (select 1 from public.crm_members m where m.user_id = u.id and m.rol = 'fundador')
      order by u.created_at limit 1;
    select u.id into v_lect from auth.users u
      where u.id not in (v_fund, v_edit) and not exists (select 1 from public.crm_members m where m.user_id = u.id and m.rol = 'fundador')
      order by u.created_at limit 1;
    if v_fund is null or v_edit is null or v_lect is null then
      raise exception 'faltan usuarios para probar (fundador + 2 no fundadores en auth.users)';
    end if;

    perform set_config('request.jwt.claim.sub', v_fund::text, true);
    insert into public.cs_programas (id, nombre, activo) values (v_prog, '__humo100__', true);
    insert into public.cs_accesos (user_id, programa_id, nivel) values (v_edit, v_prog, 'edicion'), (v_lect, v_prog, 'lectura');
    v_k := public.cs_maestro_columna_crear(v_prog, 'Col fundador', 'texto');

    -- edicion: crea, renombra, oculta, ordena, renombra opción; NO archiva ni recupera
    perform set_config('request.jwt.claim.sub', v_edit::text, true);
    v_k := public.cs_maestro_columna_crear(v_prog, 'Col producto', 'opcion', '["A","B"]');
    perform public.cs_maestro_columna_guardar(v_prog, v_k, 'Col producto 2', true);
    perform public.cs_maestro_columna_guardar(v_prog, 'etapa', 'Fase', false);
    perform public.cs_maestro_columnas_ordenar(v_prog, array['nombre', v_k, 'etapa']);
    if public.cs_maestro_opcion_renombrar(v_prog, v_k, 'A', 'AA') <> 0 then
      raise exception 'humo 1: renombrar opción sin valores debía dar 0';
    end if;
    begin
      perform public.cs_maestro_columna_archivar(v_prog, v_k, true);
      raise exception 'humo 2: edicion archivó';
    exception when insufficient_privilege then null;
    end;
    -- otro programa: sin acceso
    begin
      perform public.cs_maestro_columna_crear('liam', 'Intruso', 'texto');
      -- si el usuario tiene edicion real en liam esto no falla; no es error de la migración
    exception when insufficient_privilege then null;
    end;

    -- lectura: nada
    perform set_config('request.jwt.claim.sub', v_lect::text, true);
    begin
      perform public.cs_maestro_columna_crear(v_prog, 'Intruso', 'texto');
      raise exception 'humo 3: lectura creó';
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.cs_maestro_columnas_ordenar(v_prog, array['nombre', 'etapa']);
      raise exception 'humo 4: lectura ordenó';
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.cs_maestro_columna_guardar(v_prog, 'etapa', 'X', true);
      raise exception 'humo 5: lectura renombró';
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.cs_maestro_columna_archivar(v_prog, v_k, true);
      raise exception 'humo 6: lectura archivó';
    exception when insufficient_privilege then null;
    end;

    -- fundador: archiva
    perform set_config('request.jwt.claim.sub', v_fund::text, true);
    perform public.cs_maestro_columna_archivar(v_prog, v_k, true);

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '100 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 4. CONTROLES (correr de a uno, después del Success)
-- =====================================================================
-- C1. Quién puede qué, por función. Después de la 100: guardar, crear, ordenar
--     y opcion_renombrar usan cs_maestro_exigir_edicion; archivar usa
--     cs_maestro_exigir_fundador. ANTES de la 100 las cinco decían fundador
--     (columna usa_edicion = false).
-- select p.proname,
--        pg_get_functiondef(p.oid) like '%cs_maestro_exigir_edicion%'   as usa_edicion,
--        pg_get_functiondef(p.oid) like '%cs_maestro_exigir_fundador%'  as usa_fundador
-- from pg_proc p
-- where p.pronamespace = 'public'::regnamespace
--   and p.proname in ('cs_maestro_columna_guardar','cs_maestro_columna_crear',
--                     'cs_maestro_columnas_ordenar','cs_maestro_opcion_renombrar','cs_maestro_columna_archivar')
-- order by 1;
-- Esperado después: archivar = (false, true); las otras cuatro = (true, false).

-- C2. Por rol, sobre la tabla (nadie escribe directo): authenticated solo select.
--     Esperado: select = true, insert = false, update = false, delete = false.
-- select has_table_privilege('authenticated', 'public.cs_maestro_columnas', 'select')  as sel,
--        has_table_privilege('authenticated', 'public.cs_maestro_columnas', 'insert')  as ins,
--        has_table_privilege('authenticated', 'public.cs_maestro_columnas', 'update')  as upd,
--        has_table_privilege('authenticated', 'public.cs_maestro_columnas', 'delete')  as del;

-- C3. Quién tiene qué acceso a liam hoy (fundador no necesita fila).
--     Esperado: producto@liam = edicion, cliente@liam = lectura.
-- select u.email, a.nivel
-- from public.cs_accesos a join auth.users u on u.id = a.user_id
-- where a.programa_id = 'liam' order by 1;

-- C4. Simulación por usuario sobre liam (se revierte sola: termina en error "RESULTADO: ...").
--     Corre crear / ordenar / renombrar / archivar como cada mail y dice permitido o denegado.
--     ANTES de la 100: producto@ = crear denegado, ordenar denegado, renombrar denegado, archivar denegado.
--     DESPUES: producto@ = permitido, permitido, permitido, denegado. cliente@ = todo denegado.
--     fundador@ (el mail que tenga rol fundador en crm_members) = todo permitido.
-- do $c4$
-- declare
--   v_res text := '';
--   v_mail text;
--   v_uid uuid;
--   v_k text;
--   v_ok text;
-- begin
--   for v_mail in select unnest(array['producto@liam.dystopia', 'cliente@liam.dystopia']) loop
--     select id into v_uid from auth.users where lower(email) = v_mail;
--     if v_uid is null then v_res := v_res || v_mail || ': no existe; '; continue; end if;
--     perform set_config('request.jwt.claim.sub', v_uid::text, true);
--     v_res := v_res || v_mail || ' -> ';
--     begin v_k := public.cs_maestro_columna_crear('liam', '__c4__', 'texto'); v_ok := 'permitido';
--     exception when insufficient_privilege then v_ok := 'denegado'; v_k := null; end;
--     v_res := v_res || 'crear ' || v_ok || ', ';
--     begin perform public.cs_maestro_columna_guardar('liam', 'etapa', null, true); v_ok := 'permitido';
--     exception when insufficient_privilege then v_ok := 'denegado'; end;
--     v_res := v_res || 'renombrar ' || v_ok || ', ';
--     begin perform public.cs_maestro_columnas_ordenar('liam', array['nombre', 'etapa']); v_ok := 'permitido';
--     exception when insufficient_privilege then v_ok := 'denegado'; end;
--     v_res := v_res || 'ordenar ' || v_ok || ', ';
--     begin perform public.cs_maestro_columna_archivar('liam', coalesce(v_k, 'x_no_existe'), true); v_ok := 'permitido';
--     exception when insufficient_privilege then v_ok := 'denegado'; end;
--     v_res := v_res || 'archivar ' || v_ok || '; ';
--   end loop;
--   raise exception 'RESULTADO: %', v_res;   -- revierte todo lo probado
-- end $c4$;

-- C5. La configuración existente no cambió: mismas filas que antes de la 100.
--     (La 100 no escribe en cs_maestro_columnas; compará con el conteo previo.)
-- select programa_id, count(*) as columnas, count(*) filter (where archivada) as archivadas
-- from public.cs_maestro_columnas group by 1 order by 1;

-- C6. Respaldo de las funciones reemplazadas. Esperado: 4 filas.
-- select funcion, respaldada from public.cs_bak_100_funciones order by 1;


-- =====================================================================
-- 5. VUELTA ATRAS (comentada; correr solo si hace falta)
-- =====================================================================
-- begin;
-- do $rb$
-- declare r record;
-- begin
--   for r in select definicion from public.cs_bak_100_funciones loop
--     execute r.definicion;
--   end loop;
-- end $rb$;
-- drop function if exists public.cs_maestro_exigir_edicion(text);
-- commit;
-- (La tabla cs_bak_100_funciones se puede borrar a mano cuando ya no haga falta.)
