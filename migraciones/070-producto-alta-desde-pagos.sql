-- =====================================================================
-- 070-producto-alta-desde-pagos.sql  ·  PRODUCTO, fase 5 (PLAN-PRODUCTO.md)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
-- Evitar :00, :15, :30 y :45 (sync de Finanzas) y las 9:00.
--
-- Problema: hoy el CSM copia a mano nombre, número y concepto desde la
-- hoja de Pagos al maestro. Acá la venta que carga Finanzas aparece en
-- Producto como "cliente nuevo para dar de alta", con los datos ya puestos.
--
-- Qué hace:
--   1. cs_clientes.pago_clave: el pago que originó el alta
--      (fin_pagos.clave, 062). Nunca fin_pagos.id, que cambia con la sync.
--      Límite conocido (igual que 062): hasta el corte de Pagos, si
--      alguien corrige alumno, fecha, monto o concepto en la planilla, la
--      clave cambia. El vínculo es informativo, no se usa para plata.
--   2. cs_altas_descartadas: "esto no es un cliente nuevo" (por ejemplo
--      una venta mal cargada, o alguien que ya está con otro nombre). Un
--      descarte no vuelve a aparecer.
--   3. cs_altas_pendientes(programa, desde): por cada alumno con su
--      PRIMER pago de categoría venta_nueva (catálogo de Finanzas, 031)
--      desde la fecha indicada, si no existe ya como cliente. Se considera
--      que ya existe si coincide el nombre normalizado (sin tildes,
--      minúsculas, espacios simples), los últimos 8 dígitos del teléfono,
--      o la clave del pago.
--      desde por defecto: el corte del maestro si hay; si no, hace 30 días.
--      Devuelve SOLO fecha, alumno, teléfono, programa, concepto y clave:
--      ningún monto. Producto no ve caja.
--   4. cs_crear_cliente_desde_pago(programa, clave, producto, estado):
--      crea el cliente con el nombre, teléfono y fecha del pago. Dispara
--      los mismos triggers que un alta manual (plantilla, call de
--      onboarding si arranca en onboarding).
--   5. cs_descartar_alta(programa, clave, motivo).
--
-- Seguridad: 3, 4 y 5 son security definer porque leen fin_pagos (el CSM
-- no tiene permiso sobre Finanzas), y por eso cada una verifica primero
-- cs_puede_ver(programa). Ninguna escribe en tablas fin_*.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Locks juntos al principio: cs_clientes recibe ALTER; fin_pagos lo
-- escribe la prueba de humo (se revierte) y lo escribe la sync.
lock table public.cs_clientes in access exclusive mode;
lock table public.fin_pagos in share row exclusive mode;


-- =====================================================================
-- 1. VÍNCULO CON EL PAGO
-- =====================================================================
alter table public.cs_clientes add column if not exists pago_clave text;
comment on column public.cs_clientes.pago_clave is
  'fin_pagos.clave del pago que originó el alta (070). Informativo: hasta el corte de Pagos puede cambiar si se edita la planilla.';
create index if not exists cs_clientes_pago_clave_idx
  on public.cs_clientes (programa_id, pago_clave) where pago_clave is not null;


-- =====================================================================
-- 2. DESCARTES
-- =====================================================================
create table if not exists public.cs_altas_descartadas (
  id            uuid primary key default gen_random_uuid(),
  programa_id   text not null references public.cs_programas(id) on delete cascade,
  pago_clave    text not null,
  motivo        text check (motivo is null or char_length(motivo) <= 300),
  descartado_por uuid default auth.uid(),
  descartado_en timestamptz not null default now(),
  constraint cs_altas_descartadas_key unique (programa_id, pago_clave)
);
comment on table public.cs_altas_descartadas is
  'Ventas de Finanzas que el CSM marcó como "no es un cliente nuevo" (070).';

alter table public.cs_altas_descartadas enable row level security;
revoke all on table public.cs_altas_descartadas from anon;
grant select on table public.cs_altas_descartadas to authenticated;
drop policy if exists cs_altas_descartadas_ver on public.cs_altas_descartadas;
create policy cs_altas_descartadas_ver on public.cs_altas_descartadas
  for select to authenticated using (public.cs_puede_ver(programa_id));
-- Escritura solo por cs_descartar_alta (security definer).


-- =====================================================================
-- 3. NORMALIZACIÓN
-- =====================================================================
create or replace function public.cs_norm_nombre(p text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select nullif(btrim(regexp_replace(
           translate(lower(coalesce(p, '')), 'áéíóúàèìòùäëïöüâêîôûñç', 'aeiouaeiouaeiouaeiounc'),
           '[^a-z0-9]+', ' ', 'g')), '')
$$;

create or replace function public.cs_norm_tel(p text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  -- últimos 8 dígitos: ignora 54, 9, 0 y 15 de los distintos formatos
  select case when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 8
              then right(regexp_replace(p, '\D', '', 'g'), 8) end
$$;


-- =====================================================================
-- 4. ALTAS PENDIENTES
-- =====================================================================
create or replace function public.cs_altas_pendientes(p_programa text, p_desde date default null)
returns table (
  pago_clave  text,
  fecha       date,
  alumno      text,
  telefono    text,
  programa    text,
  concepto    text
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_desde date;
begin
  if not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: sin acceso al programa %', p_programa using errcode = '42501';
  end if;

  select coalesce(p_desde,
                  (p.maestro_cortado_en at time zone 'America/Argentina/Buenos_Aires')::date,
                  public.cs_hoy() - 30)
    into v_desde
  from public.cs_programas p where p.id = p_programa;

  return query
  with ventas as (
    select f.clave, f.fecha, f.alumno, f.telefono, f.programa, f.concepto,
           public.cs_norm_nombre(f.alumno) as nom,
           public.cs_norm_tel(f.telefono)  as tel
    from public.fin_pagos f
    where f.cliente_id = p_programa
      and f.clave is not null
      and public.fin_categoria_concepto(f.cliente_id, f.concepto) = 'venta_nueva'
  ),
  primera as (
    -- el primer pago de venta nueva de cada alumno, en toda la historia
    select distinct on (v.nom) v.*
    from ventas v
    where v.nom is not null
    order by v.nom, v.fecha, v.clave
  ),
  clientes as (
    select public.cs_norm_nombre(c.nombre) as nom,
           public.cs_norm_tel(c.telefono)  as tel,
           c.pago_clave
    from public.cs_clientes c
    where c.programa_id = p_programa
  )
  select pr.clave, pr.fecha, pr.alumno, pr.telefono, pr.programa, pr.concepto
  from primera pr
  where pr.fecha >= v_desde
    and not exists (select 1 from clientes c
                    where c.nom = pr.nom
                       or (pr.tel is not null and c.tel = pr.tel)
                       or c.pago_clave = pr.clave)
    and not exists (select 1 from public.cs_altas_descartadas d
                    where d.programa_id = p_programa and d.pago_clave = pr.clave)
  order by pr.fecha, pr.alumno;
end;
$fn$;

comment on function public.cs_altas_pendientes(text, date) is
  'Ventas nuevas de Finanzas que todavía no son clientes de Producto. Sin montos. Ver 070.';


-- =====================================================================
-- 5. CREAR DESDE PAGO
-- =====================================================================
create or replace function public.cs_crear_cliente_desde_pago(
  p_programa  text,
  p_clave     text,
  p_producto  uuid,
  p_estado    text default 'onboarding'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_pago record;
  v_id   uuid;
begin
  if not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: sin acceso al programa %', p_programa using errcode = '42501';
  end if;
  if p_estado not in ('onboarding', 'activo') then
    raise exception 'cs: un alta arranca en onboarding o activo (vino %)', p_estado using errcode = '22023';
  end if;
  if exists (select 1 from public.cs_clientes c where c.programa_id = p_programa and c.pago_clave = p_clave) then
    raise exception 'cs: ese pago ya tiene un cliente creado' using errcode = '23505';
  end if;

  select f.fecha, f.alumno, f.telefono into v_pago
  from public.fin_pagos f
  where f.cliente_id = p_programa and f.clave = p_clave;
  if v_pago.alumno is null then
    raise exception 'cs: no encontré ese pago (puede haber cambiado en la planilla; recargá)' using errcode = 'P0002';
  end if;

  insert into public.cs_clientes (programa_id, nombre, telefono, fecha_inicio, producto_id, estado, pago_clave, created_by)
  values (p_programa, btrim(v_pago.alumno), nullif(btrim(v_pago.telefono), ''), v_pago.fecha,
          p_producto, p_estado, p_clave, auth.uid())
  returning id into v_id;
  return v_id;
end;
$fn$;


-- =====================================================================
-- 6. DESCARTAR
-- =====================================================================
create or replace function public.cs_descartar_alta(p_programa text, p_clave text, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: sin acceso al programa %', p_programa using errcode = '42501';
  end if;
  insert into public.cs_altas_descartadas (programa_id, pago_clave, motivo, descartado_por)
  values (p_programa, p_clave, nullif(btrim(p_motivo), ''), auth.uid())
  on conflict (programa_id, pago_clave) do nothing;
end;
$fn$;


-- =====================================================================
-- 7. PERMISOS
-- =====================================================================
revoke all on function public.cs_norm_nombre(text) from public, anon;
revoke all on function public.cs_norm_tel(text) from public, anon;
grant execute on function public.cs_norm_nombre(text), public.cs_norm_tel(text) to authenticated;
revoke all on function public.cs_altas_pendientes(text, date) from public, anon;
revoke all on function public.cs_crear_cliente_desde_pago(text, text, uuid, text) from public, anon;
revoke all on function public.cs_descartar_alta(text, text, text) from public, anon;
grant execute on function public.cs_altas_pendientes(text, date) to authenticated;
grant execute on function public.cs_crear_cliente_desde_pago(text, text, uuid, text) to authenticated;
grant execute on function public.cs_descartar_alta(text, text, text) to authenticated;


-- =====================================================================
-- 8. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
-- Usa el cliente 'liam' con 3 pagos de humo (fila 99001 a 99003) que se
-- deshacen al final. fin_pagos solo tiene triggers before insert (clave y
-- catálogos), sin efectos fuera de la base.
do $humo$
declare
  v_n   int;
  v_id  uuid;
  v_prod uuid;
  v_err text;
  v_fuente bigint;
  v_ka text; v_kb text; v_kc text;
begin
  begin
    -- sin fundador en la sesión: cs_puede_ver da false, se simula acceso
    -- con la misma función que usa la app. En el SQL Editor corre como
    -- postgres, así que se llama directo a la lógica con un set_config.
    perform set_config('request.jwt.claim.sub',
      (select user_id::text from public.crm_members where rol = 'fundador' limit 1), true);

    select id into v_fuente from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos' limit 1;
    select id into v_prod from public.cs_productos where programa_id = 'liam' order by orden limit 1;

    -- la clave la pone el trigger de 062/065: se lee de vuelta
    insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, telefono, concepto,
                                  monto_usd, monto_origen, moneda_origen)
    values ('liam', v_fuente, 99001, public.cs_hoy() - 1, 'Humo Setenta Nuevo', '+54 9 11 9999-0070', 'FEE', 1, 1, 'USD')
    returning clave into v_ka;
    insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, telefono, concepto,
                                  monto_usd, monto_origen, moneda_origen)
    values ('liam', v_fuente, 99002, public.cs_hoy(), 'humo setenta nuevo', null, 'COMPLETA PIF', 1, 1, 'USD')
    returning clave into v_kb;
    insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, telefono, concepto,
                                  monto_usd, monto_origen, moneda_origen)
    values ('liam', v_fuente, 99003, public.cs_hoy(), 'Humo Descartable', null, 'PIF', 1, 1, 'USD')
    returning clave into v_kc;
    if v_ka is null or v_kb is null or v_kc is null then
      raise exception 'humo 0: el trigger no completó la clave de los pagos de humo';
    end if;

    -- 1. aparece una sola vez por alumno, con el primer pago
    select count(*) into v_n from public.cs_altas_pendientes('liam') a where a.pago_clave in (v_ka, v_kb, v_kc);
    if v_n <> 2 then raise exception 'humo 1: esperaba 2 altas pendientes de humo, hay %', v_n; end if;
    select count(*) into v_n from public.cs_altas_pendientes('liam') a where a.pago_clave = v_ka;
    if v_n <> 1 then raise exception 'humo 2: el alta no usa el primer pago'; end if;

    -- 2. crear desde el pago: nombre, teléfono y fecha del pago
    v_id := public.cs_crear_cliente_desde_pago('liam', v_ka, v_prod, 'onboarding');
    select count(*) into v_n from public.cs_clientes
    where id = v_id and nombre = 'Humo Setenta Nuevo' and fecha_inicio = public.cs_hoy() - 1
      and producto_id = v_prod and pago_clave = v_ka;
    if v_n <> 1 then raise exception 'humo 3: el cliente no quedó con los datos del pago'; end if;

    -- 3. ya no aparece (ni con el segundo pago del mismo alumno)
    select count(*) into v_n from public.cs_altas_pendientes('liam') a where a.pago_clave in (v_ka, v_kb);
    if v_n <> 0 then raise exception 'humo 4: sigue pendiente después de crearlo (n=%)', v_n; end if;

    -- 4. no se crea dos veces
    begin
      perform public.cs_crear_cliente_desde_pago('liam', v_ka, v_prod, 'onboarding');
      raise exception 'humo 5: creó dos veces el mismo pago';
    exception when unique_violation then null;
    end;

    -- 5. descartar saca de la lista
    perform public.cs_descartar_alta('liam', v_kc, 'prueba');
    select count(*) into v_n from public.cs_altas_pendientes('liam') a where a.pago_clave = v_kc;
    if v_n <> 0 then raise exception 'humo 6: el descartado sigue apareciendo'; end if;

    -- 6. sin acceso no ve nada
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000dead', true);
    begin
      perform * from public.cs_altas_pendientes('liam');
      raise exception 'humo 7: un usuario sin acceso vio las altas';
    exception when insufficient_privilege then null;
    end;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '070 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 9. CONTROLES (correr de a uno, después del Success)
-- =====================================================================
-- C1. Lo nuevo existe. Tiene que dar 1 | 1 | 4.
-- select (select count(*) from information_schema.columns
--          where table_name = 'cs_clientes' and column_name = 'pago_clave') as columna,
--        (select count(*) from information_schema.tables
--          where table_name = 'cs_altas_descartadas') as tabla,
--        (select count(*) from pg_proc
--          where proname in ('cs_altas_pendientes','cs_crear_cliente_desde_pago',
--                            'cs_descartar_alta','cs_norm_nombre')) as funciones;

-- C2. Altas pendientes de liam en los últimos 30 días (sin montos).
--     Corre como postgres en el editor, así que hay que simular un
--     fundador: reemplazá TU-UUID por tu user_id de crm_members.
--     Esperado: las ventas nuevas de septiembre que no están en el maestro
--     importado el 29/09 (deberían ser pocas). Si salen muchas, son
--     diferencias de nombre entre Pagos y el maestro: me pasás la cuenta.
-- select set_config('request.jwt.claim.sub', 'TU-UUID', false);
-- select count(*) as pendientes, min(fecha), max(fecha)
-- from public.cs_altas_pendientes('liam');
