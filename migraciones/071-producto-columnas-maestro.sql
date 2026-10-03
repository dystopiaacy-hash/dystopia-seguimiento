-- =====================================================================
-- 071-producto-columnas-maestro.sql  ·  PRODUCTO: columnas configurables
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
-- Evitar :00, :15, :30 y :45 y las 9:00.
--
-- Pedido: en el Maestro se puede renombrar, mover, ocultar y agregar
-- columnas, como en una planilla. Decisiones (03/10):
--   - Cambia la estructura SOLO un fundador. El resto edita valores.
--   - Una sola configuración por programa, igual para todos.
--   - Las columnas nuevas son por programa (liam no ve las de teo).
--
-- Qué hace:
--   1. cs_maestro_columnas: una fila por columna que se tocó.
--        - Columnas del sistema (las 21 de hoy): solo se guarda nombre
--          visible, orden y si se muestra. Su clave interna NO cambia:
--          renombrar "Resell" a "Pipeline" no rompe métricas ni filtros.
--          Una del sistema se oculta, no se borra. "nombre" no se oculta.
--        - Columnas nuevas: tipo texto | numero | fecha | casilla |
--          opcion | link. Las de tipo opcion tienen su lista de opciones.
--          Borrar = archivar: el dato queda guardado y se puede volver.
--      Si un programa no tiene filas, la app muestra el orden de hoy.
--   2. cs_clientes.campos_extra (jsonb): los valores de las columnas
--      nuevas, {clave: valor}. Se escribe de a una clave por vez, así dos
--      personas editando columnas distintas del mismo cliente no se pisan.
--   3. cs_v_maestro: suma campos_extra al final.
--   4. Funciones:
--        cs_maestro_columna_guardar(programa, clave, etiqueta, visible, opciones)
--        cs_maestro_columna_crear(programa, etiqueta, tipo, opciones) -> clave
--        cs_maestro_columnas_ordenar(programa, claves[])
--        cs_maestro_columna_archivar(programa, clave, archivar)
--        cs_maestro_opcion_renombrar(programa, clave, viejo, nuevo)
--          (renombra la opción Y los valores ya cargados)
--        cs_guardar_campo_extra(cliente, clave, valor jsonb)  -- cualquiera
--          con acceso al programa; valida el tipo
--
-- No toca: datos de clientes, métricas, avisos, accionables, Loom.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Locks juntos al principio: cs_clientes recibe ALTER y la vista se
-- reemplaza.
lock table public.cs_clientes in access exclusive mode;


-- =====================================================================
-- 1. CLAVES DEL SISTEMA (las columnas que dibuja la app hoy)
-- =====================================================================
create or replace function public.cs_maestro_claves_sistema()
returns text[]
language sql immutable parallel safe set search_path = public
as $$
  select array[
    'nombre', 'prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha',
    'nota_csm', 'testimonio', 'renovacion_estado', 'renovacion_producto',
    'aviso_1_at', 'aviso_2_at', 'estado', 'producto', 'etapa', 'dias_restantes',
    'acc', 'dev_pendientes', 'ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
    'proximo_contacto', 'renovaciones_count'
  ]::text[]
$$;


-- =====================================================================
-- 2. CONFIGURACIÓN DE COLUMNAS
-- =====================================================================
create table if not exists public.cs_maestro_columnas (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id) on delete cascade,
  clave        text not null check (clave ~ '^[a-z][a-z0-9_]{0,62}$'),
  sistema      boolean not null,
  etiqueta     text check (etiqueta is null or (btrim(etiqueta) <> '' and char_length(etiqueta) <= 60)),
  orden        int,
  visible      boolean not null default true,
  tipo         text check (tipo is null or tipo in ('texto','numero','fecha','casilla','opcion','link')),
  opciones     jsonb not null default '[]'::jsonb check (jsonb_typeof(opciones) = 'array'),
  archivada    boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint cs_maestro_columnas_key unique (programa_id, clave),
  -- del sistema: sin tipo ni opciones, no se archiva; nuevas: con tipo y prefijo x_
  constraint cs_maestro_columnas_sistema_chk check (
    (sistema and tipo is null and not archivada and clave = any (public.cs_maestro_claves_sistema()))
    or (not sistema and tipo is not null and clave like 'x\_%' and etiqueta is not null)),
  constraint cs_maestro_columnas_nombre_visible check (clave <> 'nombre' or visible),
  constraint cs_maestro_columnas_opciones_chk check (tipo = 'opcion' or opciones = '[]'::jsonb)
);
comment on table public.cs_maestro_columnas is
  'Columnas del Maestro por programa (071): nombre visible, orden, visibilidad y columnas nuevas. Escribe solo fundador.';

alter table public.cs_maestro_columnas enable row level security;
revoke all on table public.cs_maestro_columnas from anon;
grant select on table public.cs_maestro_columnas to authenticated;
drop policy if exists cs_maestro_columnas_ver on public.cs_maestro_columnas;
create policy cs_maestro_columnas_ver on public.cs_maestro_columnas
  for select to authenticated using (public.cs_puede_ver(programa_id));
-- Escritura solo por las funciones de abajo (security definer + es_fundador).


-- =====================================================================
-- 3. VALORES DE LAS COLUMNAS NUEVAS
-- =====================================================================
alter table public.cs_clientes
  add column if not exists campos_extra jsonb not null default '{}'::jsonb;
alter table public.cs_clientes drop constraint if exists cs_clientes_campos_extra_chk;
alter table public.cs_clientes add constraint cs_clientes_campos_extra_chk
  check (jsonb_typeof(campos_extra) = 'object');
comment on column public.cs_clientes.campos_extra is
  'Valores de las columnas nuevas del Maestro (071): {clave: valor}. Se escribe con cs_guardar_campo_extra.';


-- =====================================================================
-- 4. VISTA DEL MAESTRO: + campos_extra al final
-- =====================================================================
create or replace view public.cs_v_maestro
with (security_invoker = on) as
select
  v.id,
  v.programa_id,
  v.nombre,
  v.email,
  v.telefono,
  v.plan,
  v.responsable,
  c.prioridad,
  c.proxima_accion,
  c.proxima_accion_fecha,
  c.nota_csm,
  v.etapa,
  v.estado,
  v.fecha_inicio,
  v.fecha_fin,
  v.semaforo,
  v.motivos_semaforo,
  v.dias_restantes,
  v.pct_programa,
  v.acc_bpf_pendientes,
  v.acc_bpf_vencidos,
  v.acc_cliente_pendientes,
  v.acc_cliente_vencidos,
  v.dev_pendientes,
  v.dev_vencidas_sla,
  v.ultimo_chequeo_at,
  v.dias_sin_chequeo,
  v.renovaciones_count,
  r.id               as renovacion_id,
  r.estado           as renovacion_estado,
  r.resell_producto  as renovacion_producto,
  r.iniciada_at      as renovacion_iniciada_at,
  r.resultado_at     as renovacion_resultado_at,
  r.nueva_fecha_fin  as renovacion_nueva_fecha_fin,
  r.motivo           as renovacion_motivo,
  v.updated_at,
  s.fecha            as ultimo_seguimiento_fecha,
  s.avance           as ultimo_seguimiento_avance,
  s.proximo_contacto,
  coalesce(s.proximo_contacto < public.cs_hoy()
           and v.estado not in ('finalizado', 'baja'), false) as proximo_contacto_vencido,
  c.producto_id,
  pr.nombre          as producto,
  c.testimonio,
  c.aviso_1_at,
  c.aviso_2_at,
  c.pausado_desde,
  -- 071
  c.campos_extra
from public.cs_v_clientes v
join public.cs_clientes c on c.id = v.id
left join public.cs_productos pr on pr.id = c.producto_id
left join lateral (
  select x.id, x.estado, x.resell_producto, x.iniciada_at, x.resultado_at, x.nueva_fecha_fin, x.motivo
  from public.cs_renovaciones x
  where x.cliente_id = v.id
  order by public.cs_ren_abierta(x.estado) desc, x.iniciada_at desc
  limit 1
) r on true
left join lateral (
  select y.fecha, y.avance, y.proximo_contacto
  from public.cs_seguimientos y
  where y.cliente_id = v.id
  order by y.fecha desc, y.created_at desc
  limit 1
) s on true;


-- =====================================================================
-- 5. FUNCIONES DE ESTRUCTURA (solo fundador)
-- =====================================================================
create or replace function public.cs_maestro_exigir_fundador()
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo un fundador cambia las columnas del Maestro' using errcode = '42501';
  end if;
end;
$$;

-- Opciones: lista de textos, sin vacíos ni repetidos, hasta 50.
create or replace function public.cs_maestro_opciones_limpias(p jsonb)
returns jsonb
language plpgsql immutable set search_path = public
as $$
declare
  v jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    raise exception 'cs: las opciones van como lista' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(o order by n), '[]'::jsonb) into v
  from (
    select btrim(e) as o, min(ord) as n
    from jsonb_array_elements_text(p) with ordinality as t(e, ord)
    where btrim(e) <> ''
    group by btrim(e)
  ) x;
  if jsonb_array_length(v) > 50 then
    raise exception 'cs: hasta 50 opciones por columna' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements_text(v) e where char_length(e) > 60) then
    raise exception 'cs: cada opción tiene hasta 60 caracteres' using errcode = '22023';
  end if;
  return v;
end;
$$;

-- Renombrar / mostrar u ocultar / opciones. Sirve para las del sistema
-- (crea la fila la primera vez) y para las nuevas. etiqueta null = nombre
-- por defecto (solo sistema).
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
  perform public.cs_maestro_exigir_fundador();

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

  update public.cs_maestro_columnas
     set etiqueta   = v_et,
         visible    = coalesce(p_visible, visible),
         opciones   = case when tipo = 'opcion' and p_opciones is not null
                           then public.cs_maestro_opciones_limpias(p_opciones) else opciones end,
         updated_at = now()
   where id = v_col.id;
end;
$fn$;

-- Columna nueva. Devuelve la clave (x_<nombre>_<4 hex>). Queda al final.
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
  perform public.cs_maestro_exigir_fundador();
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

-- Orden completo: la app manda todas las claves en el orden nuevo.
-- Las del sistema que no tenían fila se crean. Claves desconocidas: error.
create or replace function public.cs_maestro_columnas_ordenar(p_programa text, p_claves text[])
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_mal text;
begin
  perform public.cs_maestro_exigir_fundador();
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

-- Archivar (borrar sin perder datos) o recuperar una columna nueva.
create or replace function public.cs_maestro_columna_archivar(p_programa text, p_clave text, p_archivar boolean default true)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  perform public.cs_maestro_exigir_fundador();
  update public.cs_maestro_columnas
     set archivada = coalesce(p_archivar, true), updated_at = now()
   where programa_id = p_programa and clave = p_clave and not sistema;
  if not found then
    raise exception 'cs: solo se archivan columnas nuevas (las del sistema se ocultan)' using errcode = '22023';
  end if;
end;
$fn$;

-- Renombrar una opción y los valores ya cargados con ese texto.
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
  perform public.cs_maestro_exigir_fundador();
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


-- =====================================================================
-- 6. GUARDAR UN VALOR (cualquiera con acceso al programa)
-- =====================================================================
-- valor null (o string vacío) borra el dato de esa columna.
create or replace function public.cs_guardar_campo_extra(p_cliente uuid, p_clave text, p_valor jsonb)
returns jsonb
language plpgsql security invoker set search_path = public
as $fn$
declare
  v_prog text;
  v_col  public.cs_maestro_columnas%rowtype;
  v      jsonb := p_valor;
begin
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: el cliente no existe o no tenés acceso' using errcode = '42501';
  end if;

  select * into v_col from public.cs_maestro_columnas
  where programa_id = v_prog and clave = p_clave and not sistema and not archivada;
  if v_col.id is null then
    raise exception 'cs: la columna % no existe en este programa', p_clave using errcode = 'P0002';
  end if;

  if v is not null and jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '' then
    v := null;
  end if;
  if v is not null and jsonb_typeof(v) = 'null' then
    v := null;
  end if;

  if v is not null then
    case v_col.tipo
      when 'texto' then
        if jsonb_typeof(v) <> 'string' or char_length(v #>> '{}') > 2000 then
          raise exception 'cs: % espera texto (hasta 2000)', v_col.etiqueta using errcode = '22023';
        end if;
        v := to_jsonb(btrim(v #>> '{}'));
      when 'numero' then
        if jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^\s*-?\d+([.,]\d+)?\s*$' then
          v := to_jsonb(replace(btrim(v #>> '{}'), ',', '.')::numeric);
        end if;
        if jsonb_typeof(v) <> 'number' then
          raise exception 'cs: % espera un número', v_col.etiqueta using errcode = '22023';
        end if;
      when 'fecha' then
        if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
          raise exception 'cs: % espera una fecha (AAAA-MM-DD)', v_col.etiqueta using errcode = '22023';
        end if;
        perform (v #>> '{}')::date;   -- falla si la fecha no existe (ej. 31/02)
      when 'casilla' then
        if jsonb_typeof(v) <> 'boolean' then
          raise exception 'cs: % espera sí o no', v_col.etiqueta using errcode = '22023';
        end if;
      when 'opcion' then
        if jsonb_typeof(v) <> 'string' or not (v_col.opciones ? (v #>> '{}')) then
          raise exception 'cs: "%" no es una opción de %', v #>> '{}', v_col.etiqueta using errcode = '22023';
        end if;
      when 'link' then
        if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~* '^https?://\S+$' or char_length(v #>> '{}') > 1000 then
          raise exception 'cs: % espera un link que empiece con http', v_col.etiqueta using errcode = '22023';
        end if;
    end case;
  end if;

  update public.cs_clientes
     set campos_extra = case when v is null then campos_extra - p_clave
                             else jsonb_set(campos_extra, array[p_clave], v) end
   where id = p_cliente;

  return v;
end;
$fn$;


-- =====================================================================
-- 7. PERMISOS
-- =====================================================================
revoke all on function public.cs_maestro_claves_sistema() from public, anon;
grant execute on function public.cs_maestro_claves_sistema() to authenticated;
revoke all on function public.cs_maestro_exigir_fundador() from public, anon, authenticated;
revoke all on function public.cs_maestro_opciones_limpias(jsonb) from public, anon, authenticated;
revoke all on function public.cs_maestro_columna_guardar(text, text, text, boolean, jsonb) from public, anon;
revoke all on function public.cs_maestro_columna_crear(text, text, text, jsonb) from public, anon;
revoke all on function public.cs_maestro_columnas_ordenar(text, text[]) from public, anon;
revoke all on function public.cs_maestro_columna_archivar(text, text, boolean) from public, anon;
revoke all on function public.cs_maestro_opcion_renombrar(text, text, text, text) from public, anon;
revoke all on function public.cs_guardar_campo_extra(uuid, text, jsonb) from public, anon;
grant execute on function public.cs_maestro_columna_guardar(text, text, text, boolean, jsonb) to authenticated;
grant execute on function public.cs_maestro_columna_crear(text, text, text, jsonb) to authenticated;
grant execute on function public.cs_maestro_columnas_ordenar(text, text[]) to authenticated;
grant execute on function public.cs_maestro_columna_archivar(text, text, boolean) to authenticated;
grant execute on function public.cs_maestro_opcion_renombrar(text, text, text, text) to authenticated;
grant execute on function public.cs_guardar_campo_extra(uuid, text, jsonb) to authenticated;
revoke all on table public.cs_v_maestro from anon;
revoke insert, update, delete on table public.cs_v_maestro from authenticated;
grant select on table public.cs_v_maestro to authenticated;


-- =====================================================================
-- 8. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
do $humo$
declare
  v_prog text := 'humo071';
  v_cli  uuid;
  v_k    text;
  v_n    int;
  v_j    jsonb;
  v_err  text;
begin
  begin
    perform set_config('request.jwt.claim.sub',
      (select user_id::text from public.crm_members where rol = 'fundador' limit 1), true);

    insert into public.cs_programas (id, nombre, activo) values (v_prog, '__humo071__', true);
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'humo 071', public.cs_hoy() - 10, public.cs_hoy() + 80, 'activo') returning id into v_cli;

    -- 1. renombrar y ocultar una del sistema; "nombre" no se oculta
    perform public.cs_maestro_columna_guardar(v_prog, 'renovacion_estado', 'Pipeline', true);
    perform public.cs_maestro_columna_guardar(v_prog, 'etapa', null, false);
    select count(*) into v_n from public.cs_maestro_columnas
    where programa_id = v_prog and ((clave = 'renovacion_estado' and etiqueta = 'Pipeline')
                                  or (clave = 'etapa' and not visible));
    if v_n <> 2 then raise exception 'humo 1: renombrar/ocultar (n=%)', v_n; end if;
    begin
      perform public.cs_maestro_columna_guardar(v_prog, 'nombre', null, false);
      raise exception 'humo 2: dejó ocultar nombre';
    exception when check_violation then null;
    end;

    -- 2. columna nueva de opciones + valor
    v_k := public.cs_maestro_columna_crear(v_prog, 'Canal de ingreso', 'opcion', '["Instagram"," YouTube ","Instagram",""]');
    if v_k !~ '^x_canal_de_ingreso_[0-9a-f]{4}$' then raise exception 'humo 3: clave %', v_k; end if;
    select opciones into v_j from public.cs_maestro_columnas where programa_id = v_prog and clave = v_k;
    if v_j <> '["Instagram","YouTube"]'::jsonb then raise exception 'humo 4: opciones %', v_j; end if;
    perform public.cs_guardar_campo_extra(v_cli, v_k, '"YouTube"');
    begin
      perform public.cs_guardar_campo_extra(v_cli, v_k, '"TikTok"');
      raise exception 'humo 5: aceptó una opción inexistente';
    exception when invalid_parameter_value then null;
    end;

    -- 3. renombrar la opción arrastra el valor cargado
    v_n := public.cs_maestro_opcion_renombrar(v_prog, v_k, 'YouTube', 'YT');
    if v_n <> 1 or (select campos_extra->>v_k from public.cs_clientes where id = v_cli) <> 'YT' then
      raise exception 'humo 6: renombrar opción (n=%)', v_n;
    end if;

    -- 4. tipos: número con coma, fecha inválida, vacío borra
    v_k := public.cs_maestro_columna_crear(v_prog, 'Capital inicial', 'numero');
    v_j := public.cs_guardar_campo_extra(v_cli, v_k, '"1500,5"');
    if v_j <> '1500.5'::jsonb then raise exception 'humo 7: número %', v_j; end if;
    perform public.cs_guardar_campo_extra(v_cli, v_k, '""');
    if (select campos_extra ? v_k from public.cs_clientes where id = v_cli) then
      raise exception 'humo 8: el vacío no borró';
    end if;
    v_k := public.cs_maestro_columna_crear(v_prog, 'Firmó', 'fecha');
    begin
      perform public.cs_guardar_campo_extra(v_cli, v_k, '"2026-02-31"');
      raise exception 'humo 9: aceptó 31/02';
    exception when datetime_field_overflow or invalid_datetime_format then null;
    end;

    -- 5. orden: las del sistema se crean, las nuevas se mueven; repetidas no
    perform public.cs_maestro_columnas_ordenar(v_prog, array['nombre', v_k, 'prioridad']);
    select count(*) into v_n from public.cs_maestro_columnas
    where programa_id = v_prog and ((clave = 'nombre' and orden = 10) or (clave = v_k and orden = 20)
                                  or (clave = 'prioridad' and orden = 30));
    if v_n <> 3 then raise exception 'humo 10: orden (n=%)', v_n; end if;
    begin
      perform public.cs_maestro_columnas_ordenar(v_prog, array['nombre', 'nombre']);
      raise exception 'humo 11: aceptó repetidas';
    exception when invalid_parameter_value then null;
    end;

    -- 6. archivar: el valor queda, pero ya no se puede escribir
    perform public.cs_maestro_columna_archivar(v_prog, v_k, true);
    begin
      perform public.cs_guardar_campo_extra(v_cli, v_k, '"2026-01-01"');
      raise exception 'humo 12: escribió en una archivada';
    exception when no_data_found then null;
    end;
    begin
      perform public.cs_maestro_columna_archivar(v_prog, 'prioridad', true);
      raise exception 'humo 13: archivó una del sistema';
    exception when invalid_parameter_value then null;
    end;

    -- 7. un no fundador no cambia estructura
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000dead', true);
    begin
      perform public.cs_maestro_columna_crear(v_prog, 'Intruso', 'texto');
      raise exception 'humo 14: un no fundador creó una columna';
    exception when insufficient_privilege then null;
    end;

    -- 8. la vista trae campos_extra
    perform set_config('request.jwt.claim.sub',
      (select user_id::text from public.crm_members where rol = 'fundador' limit 1), true);
    select count(*) into v_n from public.cs_v_maestro where id = v_cli and campos_extra ? (
      select clave from public.cs_maestro_columnas where programa_id = v_prog and tipo = 'opcion');
    if v_n <> 1 then raise exception 'humo 15: la vista no trae campos_extra'; end if;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '071 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 9. CONTROLES (correr de a uno, después del Success)
-- =====================================================================
-- C1. Lo nuevo existe. Tiene que dar 1 | 1 | 6 | 21.
-- select (select count(*) from information_schema.tables where table_name = 'cs_maestro_columnas') as tabla,
--        (select count(*) from information_schema.columns where table_name = 'cs_clientes' and column_name = 'campos_extra') as columna,
--        (select count(*) from pg_proc where proname in ('cs_maestro_columna_guardar','cs_maestro_columna_crear',
--           'cs_maestro_columnas_ordenar','cs_maestro_columna_archivar','cs_maestro_opcion_renombrar',
--           'cs_guardar_campo_extra')) as funciones,
--        cardinality(public.cs_maestro_claves_sistema()) as claves_sistema;

-- C2. Nada cambió todavía para la app: 0 columnas configuradas y todos
--     los clientes con campos_extra vacío. Tiene que dar 0 | 0.
-- select (select count(*) from public.cs_maestro_columnas) as configuradas,
--        (select count(*) from public.cs_clientes where campos_extra <> '{}'::jsonb) as con_extras;

-- C3. La vista del Maestro sigue devolviendo a todos los clientes de liam.
--     Tiene que dar 133 (o los que haya hoy) y la última columna campos_extra.
-- select count(*) from public.cs_v_maestro where programa_id = 'liam';
