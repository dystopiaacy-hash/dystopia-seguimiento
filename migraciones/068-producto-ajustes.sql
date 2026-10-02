-- =====================================================================
-- 068-producto-ajustes.sql  ·  PRODUCTO, fase 1 (PLAN-PRODUCTO.md)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
-- Evitar los minutos :00, :15, :30 y :45 (sync de Finanzas) y las 9:00
-- (chequeo diario de Producto).
--
-- Qué hace:
--   1. Testimonio: suma el estado 'coordinado' (está en el desplegable de
--      BPF y la app no lo tenía).
--   2. cs_clientes.pausa_motivo: texto opcional al pausar (hasta 500).
--   3. cs_programas.maestro_cortado_en: desde cuándo el CSM carga solo en
--      la app. null = la planilla todavía se usa. Lo marca la fase 2.
--   4. liam: segundo aviso de renovación a 10 días (antes 5). En la
--      planilla el CSM marcó "10D" 49 veces y "5D" una sola.
--   5. liam: 4 accionables nuevos en la plantilla (estaban en la planilla
--      y no en la app):
--        pedir_referidos  día 0,  vence a los 14
--        fup_1            día 14, vence a los 14 (semana 2 a 4)
--        fup_2            día 28, vence a los 28 (semana 4 a 8)
--        fup_3            día 56, vence a los 28 (semana 8 a 12)
--      Para no llenar de vencidos el chequeo de mañana, los que ya
--      vencieron se crean COMPLETADOS con la leyenda
--      "Histórico: anterior a la 068" (mismo criterio que la limpieza de
--      la importación del 29/09). Los que todavía no vencen los crea el
--      chequeo diario como pendientes, que es trabajo real.
--
-- No toca: métricas, devoluciones de Loom, accionables existentes, días
-- restantes ni ningún dato de clientes salvo los accionables históricos.
-- Se puede correr dos veces: la segunda no cambia nada.
--
-- Efecto visible mañana a las 9: los clientes de liam con 6 a 10 días
-- restantes pasan de "aviso 1" a "aviso 2" (si no tienen el aviso 2
-- hecho). Es el cambio buscado.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Todos los locks juntos al principio (lección del deadlock de la 066).
-- cs_programas y cs_clientes reciben ALTER: access exclusive desde el
-- arranque, así no hay que escalar el lock en el medio.
lock table public.cs_programas, public.cs_clientes in access exclusive mode;
lock table public.cs_accionables in share row exclusive mode;


-- =====================================================================
-- 1. TESTIMONIO: 'coordinado'
-- =====================================================================
alter table public.cs_clientes drop constraint if exists cs_clientes_testimonio_chk;
alter table public.cs_clientes add constraint cs_clientes_testimonio_chk
  check (testimonio in ('sin_pedir','pitchiado','coordinado','grabado','no_quiere'));


-- =====================================================================
-- 2. MOTIVO DE LA PAUSA
-- =====================================================================
alter table public.cs_clientes add column if not exists pausa_motivo text;
alter table public.cs_clientes drop constraint if exists cs_clientes_pausa_motivo_chk;
alter table public.cs_clientes add constraint cs_clientes_pausa_motivo_chk
  check (pausa_motivo is null or char_length(pausa_motivo) <= 500);
comment on column public.cs_clientes.pausa_motivo is
  'Por qué se pausó (opcional). Se conserva al reanudar como último motivo.';


-- =====================================================================
-- 3. CORTE DEL MAESTRO
-- =====================================================================
alter table public.cs_programas add column if not exists maestro_cortado_en timestamptz;
comment on column public.cs_programas.maestro_cortado_en is
  'Desde cuándo el CSM carga solo en la app (corte de la planilla maestro). null = todavía usa la planilla.';


-- =====================================================================
-- 4. LIAM: AVISOS A 21 Y 10 DÍAS
-- =====================================================================
update public.cs_programas
set aviso_2_dias = 10
where id = 'liam' and aviso_2_dias is distinct from 10;


-- =====================================================================
-- 5. LIAM: REFERIDOS Y FOLLOW UPS EN LA PLANTILLA
-- =====================================================================
-- Se agregan al final solo las keys que no estén (idempotente).
with nuevos(item) as (
  values
    ('{"key":"pedir_referidos","titulo":"Pedir referidos","responsable":"bpf","disparo":"inicio","dia_offset":0,"vence_en_dias":14}'::jsonb),
    ('{"key":"fup_1","titulo":"Follow up 1 (semana 2 a 4)","responsable":"bpf","disparo":"inicio","dia_offset":14,"vence_en_dias":14}'::jsonb),
    ('{"key":"fup_2","titulo":"Follow up 2 (semana 4 a 8)","responsable":"bpf","disparo":"inicio","dia_offset":28,"vence_en_dias":28}'::jsonb),
    ('{"key":"fup_3","titulo":"Follow up 3 (semana 8 a 12)","responsable":"bpf","disparo":"inicio","dia_offset":56,"vence_en_dias":28}'::jsonb)
),
faltan as (
  select coalesce(jsonb_agg(n.item), '[]'::jsonb) as items
  from nuevos n
  join public.cs_programas p on p.id = 'liam'
  where not exists (
    select 1 from jsonb_array_elements(p.plantilla_accionables) e
    where e->>'key' = n.item->>'key')
)
update public.cs_programas p
set plantilla_accionables = p.plantilla_accionables || f.items
from faltan f
where p.id = 'liam' and jsonb_array_length(f.items) > 0;

-- Históricos: los ítems nuevos que para un cliente vivo ya vencieron.
-- Misma fecha que usa cs_aplicar_plantillas: inicio + dia_offset + vence_en_dias.
-- Incluye pausados (al reanudar, el chequeo los crearía vencidos).
insert into public.cs_accionables
  (programa_id, cliente_id, responsable, titulo, descripcion, estado, vence, origen, plantilla_key)
select c.programa_id, c.id, e->>'responsable', e->>'titulo',
       'Histórico: anterior a la 068', 'completado',
       c.fecha_inicio + (e->>'dia_offset')::int + (e->>'vence_en_dias')::int,
       'plantilla', e->>'key'
from public.cs_clientes c
join public.cs_programas p on p.id = c.programa_id
cross join lateral jsonb_array_elements(p.plantilla_accionables) e
where c.programa_id = 'liam'
  and c.estado in ('onboarding', 'activo', 'en_renovacion', 'pausado')
  and e->>'key' in ('pedir_referidos', 'fup_1', 'fup_2', 'fup_3')
  and c.fecha_inicio + (e->>'dia_offset')::int + (e->>'vence_en_dias')::int < public.cs_hoy()
on conflict (cliente_id, plantilla_key) do nothing;


-- =====================================================================
-- 6. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
-- Corre adentro de un bloque que siempre termina con error 'humo_ok' y
-- deshace todo lo que hizo. Cualquier otro error aborta la migración
-- entera y no queda nada aplicado.
do $humo$
declare
  v_prog  text := 'humo068';
  v_cli   uuid;
  v_n     int;
  v_err   text;
begin
  begin
    insert into public.cs_programas (id, nombre, activo, plantilla_accionables)
    select v_prog, '__humo068__', true, plantilla_accionables
    from public.cs_programas where id = 'liam';

    -- cliente que arrancó hace 70 días: referidos, fup_1 y fup_2 ya
    -- vencieron; fup_3 (56 + 28 = 84) no.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'humo 068', public.cs_hoy() - 70, public.cs_hoy() + 50, 'activo')
    returning id into v_cli;

    -- 1. 'coordinado' entra; un valor inventado no
    update public.cs_clientes set testimonio = 'coordinado' where id = v_cli;
    begin
      update public.cs_clientes set testimonio = 'inventado' where id = v_cli;
      raise exception 'humo 1: aceptó un testimonio inventado';
    exception when check_violation then null;
    end;

    -- 2. motivo de pausa: más de 500 caracteres se rechaza
    begin
      update public.cs_clientes set pausa_motivo = repeat('x', 501) where id = v_cli;
      raise exception 'humo 2: aceptó un motivo de 501 caracteres';
    exception when check_violation then null;
    end;

    -- 3. el chequeo diario, corrido hoy, no deja vencidos de liam con las
    --    keys nuevas (todo lo vencido ya está como histórico)
    perform public.cs_aplicar_plantillas();
    select count(*) into v_n
    from public.cs_accionables a
    where a.programa_id = 'liam'
      and a.plantilla_key in ('pedir_referidos', 'fup_1', 'fup_2', 'fup_3')
      and a.estado <> 'completado'
      and a.vence < public.cs_hoy();
    if v_n <> 0 then
      raise exception 'humo 3: quedarían % vencidos nuevos en liam', v_n;
    end if;

    -- 4. el cliente de humo recibe los 4 ítems: fup_3 pendiente con
    --    vencimiento a futuro (los otros tres los crea el chequeo
    --    vencidos, porque humo068 no tiene históricos: es lo esperado)
    select count(*) into v_n from public.cs_accionables
    where cliente_id = v_cli and plantilla_key = 'fup_3'
      and estado = 'pendiente' and vence = public.cs_hoy() + 14;
    if v_n <> 1 then
      raise exception 'humo 4: fup_3 del cliente de humo no quedó pendiente a 14 días (n=%)', v_n;
    end if;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '068 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 7. CONTROLES (correr de a uno, después del Success)
-- =====================================================================
-- C1. Testimonio con 'coordinado'. Tiene que dar 1 fila que lo incluya.
-- select pg_get_constraintdef(oid) from pg_constraint
-- where conname = 'cs_clientes_testimonio_chk';

-- C2. Avisos y corte de liam. Tiene que dar 21 | 10 | null.
-- select aviso_1_dias, aviso_2_dias, maestro_cortado_en
-- from public.cs_programas where id = 'liam';

-- C3. Plantilla de liam. Tiene que dar 13 ítems y las 4 keys nuevas.
-- select jsonb_array_length(plantilla_accionables) as items,
--        (select string_agg(e->>'key', ', ') from jsonb_array_elements(plantilla_accionables) e
--         where e->>'key' in ('pedir_referidos','fup_1','fup_2','fup_3')) as nuevas
-- from public.cs_programas where id = 'liam';

-- C4. Históricos y vencidos de las keys nuevas. vencidos_pendientes
--     tiene que dar 0. historicos: un número cercano a 4 por cada
--     cliente vivo con más de 3 meses.
-- select count(*) filter (where descripcion = 'Histórico: anterior a la 068') as historicos,
--        count(*) filter (where estado <> 'completado' and vence < public.cs_hoy()) as vencidos_pendientes
-- from public.cs_accionables
-- where programa_id = 'liam' and plantilla_key in ('pedir_referidos','fup_1','fup_2','fup_3');

-- C5. Qué va a crear el chequeo de mañana (pendientes reales, no vencidos).
-- select e->>'key' as key, count(*) as clientes
-- from public.cs_clientes c
-- join public.cs_programas p on p.id = c.programa_id
-- cross join lateral jsonb_array_elements(p.plantilla_accionables) e
-- where c.programa_id = 'liam'
--   and c.estado in ('onboarding','activo','en_renovacion')
--   and e->>'key' in ('pedir_referidos','fup_1','fup_2','fup_3')
--   and (e->>'dia_offset')::int <= public.cs_hoy() + 1 - c.fecha_inicio
--   and not exists (select 1 from public.cs_accionables a
--                   where a.cliente_id = c.id and a.plantilla_key = e->>'key')
-- group by 1 order by 1;
