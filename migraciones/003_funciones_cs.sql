-- =====================================================================
-- 003_funciones_cs.sql  —  Dystopia Seguimiento, FASE 4.1: funciones CS
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
--
-- Migración PURAMENTE ADITIVA sobre objetos cs_*: crea 4 funciones nuevas,
-- 1 función de trigger nueva y 1 trigger nuevo. No modifica tablas, ni
-- políticas, ni datos, ni nada crm_*. No requiere backup previo.
-- Es idempotente (create or replace / create or replace trigger).
--
-- El cambio va dentro de una transacción: si algo falla, no queda nada a
-- medias. No usa pg_cron ni pg_net (no están instaladas).
--
-- Estructura:
--   1. cs_aplicar_plantillas()  -> int
--   2. cs_cerrar_vencidos()     -> jsonb
--   3. cs_generar_alertas()     -> jsonb
--   4. cs_correr_diario()       -> jsonb   (entrada única; valida fundador)
--   5. Trigger: borrar una renovación en_proceso destraba al cliente
--   6. Permisos
--   7. PRUEBA DE HUMO (crea datos, los verifica y los deshace)
--   8. QUERY DE CONTROL
--
-- Criterios que se reutilizan de 001/002 (no se inventan otros):
--   - vence de un accionable de plantilla = fecha_inicio + dia_offset +
--     vence_en_dias (igual que el seed 002 y que cs_tg_clientes_after_insert).
--   - "cliente vivo" = estado en (onboarding, activo, en_renovacion),
--     igual que cs_tg_clientes_after_insert.
--   - condiciones de alerta = las mismas expresiones del semáforo de
--     cs_v_clientes, para que alerta y semáforo no se contradigan.
--   - unicidad: cs_accionables (cliente_id, plantilla_key) y
--     cs_alertas.clave_dedupe, las dos de 001.
-- =====================================================================

begin;

-- =====================================================================
-- 1. cs_aplicar_plantillas()
-- =====================================================================
-- Para cada cliente vivo, crea los accionables de plantilla cuyo
-- dia_offset ya pasó y que todavía no existen. La unique
-- (cliente_id, plantilla_key) de 001 es la que garantiza no duplicar:
-- correrla dos veces no crea nada la segunda vez.
-- Devuelve cuántos accionables creó.
create or replace function public.cs_aplicar_plantillas()
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int;
begin
  with nuevos as (
    insert into public.cs_accionables
      (programa_id, cliente_id, responsable, titulo, descripcion, vence, origen, plantilla_key)
    select c.programa_id,
           c.id,
           e->>'responsable',
           e->>'titulo',
           nullif(e->>'descripcion', ''),
           -- mismo criterio que el seed 002: inicio + dia_offset + vence_en_dias
           -- (null si al ítem le falta alguno de los dos: son opcionales)
           c.fecha_inicio + (e->>'dia_offset')::int + (e->>'vence_en_dias')::int,
           'plantilla',
           e->>'key'
    from public.cs_clientes c
    join public.cs_programas p on p.id = c.programa_id
    cross join lateral jsonb_array_elements(p.plantilla_accionables) e
    where c.estado in ('onboarding', 'activo', 'en_renovacion')
      and coalesce((e->>'dia_offset')::int, 0) <= public.cs_hoy() - c.fecha_inicio
    on conflict (cliente_id, plantilla_key) do nothing
    returning 1
  )
  select count(*) into v_n from nuevos;
  return v_n;
end;
$fn$;


-- =====================================================================
-- 2. cs_cerrar_vencidos()
-- =====================================================================
-- Clientes cuyo programa ya venció y que no tienen una renovación
-- 'renovado' que los extienda -> 'finalizado'. Después, las renovaciones
-- que hayan quedado 'en_proceso' de esos clientes -> 'no_renovado' con
-- motivo "Vencido sin respuesta".
--
-- Orden: primero los clientes, después las renovaciones. Así el contador
-- de clientes finalizados queda completo; al revés, el trigger
-- cs_tg_renovaciones_after ya habría finalizado a algunos y no se
-- contarían. Cerrar la renovación después no vuelve a tocar al cliente,
-- porque ese trigger solo actúa sobre estado = 'en_renovacion'.
create or replace function public.cs_cerrar_vencidos()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_cli int;
  v_ren int;
begin
  -- 1. clientes vencidos -> finalizado
  with cerrados as (
    update public.cs_clientes c
       set estado = 'finalizado'
     where c.fecha_fin < public.cs_hoy()
       and c.estado not in ('finalizado', 'baja')
       and not exists (
         select 1 from public.cs_renovaciones r
         where r.cliente_id = c.id
           and r.estado = 'renovado'
           and r.nueva_fecha_fin >= public.cs_hoy()
       )
    returning 1
  )
  select count(*) into v_cli from cerrados;

  -- 2. renovaciones que quedaron abiertas de clientes ya cerrados -> no_renovado
  with cerradas as (
    update public.cs_renovaciones r
       set estado = 'no_renovado',
           motivo = 'Vencido sin respuesta'
     where r.estado = 'en_proceso'
       and exists (
         select 1 from public.cs_clientes c
         where c.id = r.cliente_id
           and c.fecha_fin < public.cs_hoy()
           and c.estado in ('finalizado', 'baja')
       )
    returning 1
  )
  select count(*) into v_ren from cerradas;

  return jsonb_build_object('clientes_finalizados', v_cli,
                            'renovaciones_cerradas', v_ren);
end;
$fn$;


-- =====================================================================
-- 3. cs_generar_alertas()
-- =====================================================================
-- Inserta las alertas vigentes (on conflict do nothing sobre
-- clave_dedupe: correrla dos veces no duplica) y resuelve las que ya no
-- corresponden.
--
-- NO toca las alertas de tipo 'satisfaccion_baja': esas nacen del
-- formulario (Fase 5) y las resuelve una persona, no el chequeo diario.
--
-- clave_dedupe = tipo + la fila o el ciclo al que pertenece la alerta.
-- Cuando el ciclo cambia (nueva fecha_fin al renovar, nuevo chequeo,
-- nuevo inicio) la clave cambia y puede volver a alertar. Mientras el
-- ciclo es el mismo hay una sola alerta, aunque el chequeo corra todos
-- los días.
create or replace function public.cs_generar_alertas()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_creadas   int;
  v_resueltas int;
begin
  with base as (
    select c.id                             as cliente_id,
           c.programa_id,
           c.fecha_inicio,
           c.fecha_fin,
           p.aviso_renovacion_dias,
           p.sla_devolucion_horas,
           p.sla_onboarding_dias,
           p.dias_sin_chequeo_alerta,
           c.fecha_fin - public.cs_hoy()    as dias_restantes,
           public.cs_hoy() - c.fecha_inicio as dias_transcurridos,
           (coalesce(c.ultimo_chequeo_at, c.created_at)
              at time zone 'America/Argentina/Buenos_Aires')::date as base_chequeo
    from public.cs_clientes c
    join public.cs_programas p on p.id = c.programa_id
    -- un cliente finalizado o dado de baja no genera trabajo: al salir de
    -- este conjunto, sus alertas abiertas se resuelven solas más abajo.
    where c.estado not in ('finalizado', 'baja')
  ),
  estado_ren as (
    select b.cliente_id,
           (select r.estado
              from public.cs_renovaciones r
             where r.cliente_id = b.cliente_id
             -- si hay una en_proceso manda esa; si no, la más reciente (igual que cs_v_clientes)
             order by (r.estado = 'en_proceso') desc, r.iniciada_at desc
             limit 1) as renovacion_estado
    from base b
  ),
  estado_onb as (
    select b.cliente_id,
           (select k.estado
              from public.cs_calls k
             where k.cliente_id = b.cliente_id and k.tipo = 'onboarding'
             order by k.created_at desc
             limit 1) as onboarding_estado
    from base b
  ),
  vigentes as (
    -- renovacion_proxima: entró en la ventana de aviso y nadie inició la renovación
    select b.programa_id,
           b.cliente_id,
           'renovacion_proxima'::text as tipo,
           format('Vence en %s día(s) sin renovación iniciada', b.dias_restantes) as mensaje,
           'renovacion_proxima:' || b.cliente_id || ':' || b.fecha_fin as clave_dedupe
    from base b
    join estado_ren r on r.cliente_id = b.cliente_id
    where b.dias_restantes >= 0
      and b.dias_restantes <= b.aviso_renovacion_dias
      and coalesce(r.renovacion_estado, '') not in ('en_proceso', 'no_renovado')

    union all
    -- programa_vencido: red de seguridad. Si corrió el chequeo completo,
    -- cs_cerrar_vencidos ya finalizó a estos clientes y esto no dispara.
    -- Si aparece, es un cliente vencido que no se pudo cerrar.
    select b.programa_id,
           b.cliente_id,
           'programa_vencido',
           format('Programa vencido hace %s día(s) y el cliente sigue abierto', -b.dias_restantes),
           'programa_vencido:' || b.cliente_id || ':' || b.fecha_fin
    from base b
    where b.dias_restantes < 0

    union all
    -- devolucion_vencida: una por devolución fuera del SLA
    select b.programa_id,
           b.cliente_id,
           'devolucion_vencida',
           format('Devolución "%s" fuera del SLA de %s h', d.titulo, b.sla_devolucion_horas),
           'devolucion_vencida:' || d.id
    from base b
    join public.cs_devoluciones d on d.cliente_id = b.cliente_id
    where d.estado in ('pendiente', 'en_proceso')
      and d.solicitada_at + make_interval(hours => b.sla_devolucion_horas) < now()

    union all
    -- onboarding_demorado: la call de onboarding sigue sin agendar
    select b.programa_id,
           b.cliente_id,
           'onboarding_demorado',
           format('Onboarding sin agendar hace %s día(s)', b.dias_transcurridos),
           'onboarding_demorado:' || b.cliente_id || ':' || b.fecha_inicio
    from base b
    join estado_onb o on o.cliente_id = b.cliente_id
    where o.onboarding_estado = 'pendiente_agendar'
      and b.dias_transcurridos > b.sla_onboarding_dias

    union all
    -- accionable_bpf_vencido: una por accionable del equipo vencido
    select b.programa_id,
           b.cliente_id,
           'accionable_bpf_vencido',
           format('Accionable BPF vencido: %s (vencía el %s)', a.titulo, a.vence),
           'accionable_bpf_vencido:' || a.id
    from base b
    join public.cs_accionables a on a.cliente_id = b.cliente_id
    where a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence < public.cs_hoy()

    union all
    -- sin_chequeo: una por racha sin chequear (la clave cambia con cada chequeo)
    select b.programa_id,
           b.cliente_id,
           'sin_chequeo',
           format('Sin chequeo hace %s día(s)', public.cs_hoy() - b.base_chequeo),
           'sin_chequeo:' || b.cliente_id || ':' || b.base_chequeo
    from base b
    where public.cs_hoy() - b.base_chequeo > b.dias_sin_chequeo_alerta
  ),
  creadas as (
    insert into public.cs_alertas (programa_id, cliente_id, tipo, mensaje, clave_dedupe)
    select v.programa_id, v.cliente_id, v.tipo, v.mensaje, v.clave_dedupe
    from vigentes v
    on conflict (clave_dedupe) do nothing
    returning 1
  ),
  resueltas as (
    update public.cs_alertas a
       set resuelta = true          -- resuelta_at lo completa cs_tg_alertas_before
     where a.resuelta = false
       and a.tipo in ('renovacion_proxima', 'devolucion_vencida', 'onboarding_demorado',
                      'accionable_bpf_vencido', 'sin_chequeo', 'programa_vencido')
       and not exists (select 1 from vigentes v where v.clave_dedupe = a.clave_dedupe)
    returning 1
  )
  select (select count(*) from creadas), (select count(*) from resueltas)
    into v_creadas, v_resueltas;

  return jsonb_build_object('creadas', v_creadas, 'resueltas', v_resueltas);
end;
$fn$;


-- =====================================================================
-- 4. cs_correr_diario()
-- =====================================================================
-- Entrada única del chequeo. La puede ejecutar 'authenticated' (la UI la
-- llama con el botón "Correr chequeo ahora" de Config), pero adentro
-- valida que sea el fundador y si no corta con error.
--
-- La excepción es la llamada sin sesión (auth.uid() is null): el SQL
-- Editor y el cron de la Fase 6 con service_role. 'anon' no llega acá
-- porque tiene el execute revocado.
create or replace function public.cs_correr_diario()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_acc int;
  v_ven jsonb;
  v_ale jsonb;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede correr el chequeo' using errcode = '42501';
  end if;

  v_acc := public.cs_aplicar_plantillas();
  v_ven := public.cs_cerrar_vencidos();
  v_ale := public.cs_generar_alertas();

  return jsonb_build_object(
    'accionables_creados',   v_acc,
    'clientes_finalizados',  (v_ven->>'clientes_finalizados')::int,
    'renovaciones_cerradas', (v_ven->>'renovaciones_cerradas')::int,
    'alertas_creadas',       (v_ale->>'creadas')::int,
    'alertas_resueltas',     (v_ale->>'resueltas')::int,
    'corrido_at',            now()
  );
end;
$fn$;


-- =====================================================================
-- 5. Trigger: borrar una renovación en_proceso destraba al cliente
-- =====================================================================
-- Sin esto el cliente quedaba en 'en_renovacion' para siempre: el efecto
-- sobre el cliente lo hace cs_tg_renovaciones_after, que es after insert
-- or update of estado y no ve los delete.
-- Usa el mismo criterio que la rama 'no_renovado' de ese trigger: vuelve
-- a 'activo', salvo que el programa ya haya vencido, en cuyo caso queda
-- 'finalizado' (un cliente 'activo' con fecha_fin pasada sería un estado
-- inconsistente).
create or replace function public.cs_tg_renovaciones_after_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if old.estado <> 'en_proceso' then
    return null;
  end if;

  update public.cs_clientes c
     set estado = case when c.fecha_fin < public.cs_hoy() then 'finalizado' else 'activo' end
   where c.id = old.cliente_id
     and c.estado = 'en_renovacion'
     -- si quedó otra renovación abierta, el cliente sigue en renovación
     and not exists (
       select 1 from public.cs_renovaciones r
       where r.cliente_id = old.cliente_id and r.estado = 'en_proceso'
     );
  return null;
end;
$fn$;

create or replace trigger cs_trg_after_delete after delete on public.cs_renovaciones
  for each row execute function public.cs_tg_renovaciones_after_delete();


-- =====================================================================
-- 6. PERMISOS
-- =====================================================================
-- Nada para public ni anon en ninguna función nueva.
revoke all on function
  public.cs_aplicar_plantillas(), public.cs_cerrar_vencidos(),
  public.cs_generar_alertas(), public.cs_correr_diario(),
  public.cs_tg_renovaciones_after_delete()
from public, anon;

-- Las tres funciones de trabajo no se llaman sueltas desde la UI: solo a
-- través de cs_correr_diario(), que es SECURITY DEFINER y las ejecuta con
-- los permisos del dueño.
revoke all on function
  public.cs_aplicar_plantillas(), public.cs_cerrar_vencidos(),
  public.cs_generar_alertas(), public.cs_tg_renovaciones_after_delete()
from authenticated;

grant execute on function public.cs_correr_diario() to authenticated;

commit;


-- =====================================================================
-- 7. PRUEBA DE HUMO (no deja datos)
-- =====================================================================
-- Crea 3 clientes de prueba en 'liam', ejercita las 4 funciones y el
-- trigger nuevo, y después fuerza un error para deshacer TODO (incluidos
-- los accionables y las alertas que las funciones hayan creado para los
-- clientes demo reales). Los resultados se juntan en una variable, que
-- sobrevive al rollback, y se vuelcan a una tabla temporal.
drop table if exists pg_temp.cs_smoke3;
create temp table cs_smoke3 (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res      text[] := '{}';
  v_cli_a  uuid;
  v_cli_b  uuid;
  v_cli_c  uuid;
  v_ren_b  uuid;
  v_ren_c  uuid;
  v_n      int;
  v_n2     int;
  v_esp    int;
  v_txt    text;
  v_txt2   text;
  v_fecha  date;
  v_bool   boolean;
  v_j      jsonb;
  v_clave  text;
  v_motivo text;
begin
  begin
    -- ---------- cliente A: 40 días de programa, vence en 5 ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('liam', '__humo003_a__', public.cs_hoy() - 40, public.cs_hoy() + 5, 'activo')
    returning id into v_cli_a;

    -- 1. cs_aplicar_plantillas crea los ítems cuyo dia_offset ya pasó
    select count(*) into v_esp
    from public.cs_programas p
    cross join lateral jsonb_array_elements(p.plantilla_accionables) e
    where p.id = 'liam' and coalesce((e->>'dia_offset')::int, 0) <= 40;

    v_n := public.cs_aplicar_plantillas();
    select count(*) into v_n2 from public.cs_accionables
    where cliente_id = v_cli_a and origen = 'plantilla';
    res := res || format('aplicar_plantillas crea los items ya vencidos|%s|cliente=%s esperados=%s',
                         v_n2 = v_esp, v_n2, v_esp);

    -- 2. vence = fecha_inicio + dia_offset + vence_en_dias
    select a.vence into v_fecha
    from public.cs_accionables a
    where a.cliente_id = v_cli_a and a.plantilla_key = 'portafolio_inicial';
    res := res || format('vence = inicio + dia_offset + vence_en_dias|%s|vence=%s esperado=%s',
                         v_fecha = public.cs_hoy() - 40 + 7 + 5, v_fecha, public.cs_hoy() - 40 + 7 + 5);

    -- 3. correrla de nuevo no duplica
    v_n := public.cs_aplicar_plantillas();
    select count(*) into v_n2 from public.cs_accionables
    where cliente_id = v_cli_a and origen = 'plantilla';
    res := res || format('aplicar_plantillas 2a corrida no duplica|%s|cliente=%s', v_n2 = v_esp, v_n2);

    -- ---------- cliente B: vencido hace 5 días, con renovación abierta ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('liam', '__humo003_b__', public.cs_hoy() - 100, public.cs_hoy() - 5, 'activo')
    returning id into v_cli_b;
    insert into public.cs_renovaciones (cliente_id) values (v_cli_b) returning id into v_ren_b;

    -- 4. generar_alertas crea alertas del cliente A
    v_j := public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas where cliente_id = v_cli_a and not resuelta;
    res := res || format('generar_alertas crea alertas del cliente A|%s|alertas=%s retorno=%s',
                         v_n > 0, v_n, replace(v_j::text, '|', '/'));

    -- 5. programa_vencido para el cliente B (todavía no se cerró)
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_cli_b and tipo = 'programa_vencido' and not resuelta;
    res := res || format('alerta programa_vencido del cliente B|%s|alertas=%s', v_n = 1, v_n);

    -- 6. segunda corrida: no duplica nada
    select count(*) into v_n from public.cs_alertas where cliente_id in (v_cli_a, v_cli_b);
    v_j := public.cs_generar_alertas();
    select count(*) into v_n2 from public.cs_alertas where cliente_id in (v_cli_a, v_cli_b);
    res := res || format('generar_alertas 2a corrida no duplica|%s|antes=%s despues=%s creadas=%s',
                         v_n = v_n2 and v_n > 0, v_n, v_n2, v_j->>'creadas');

    -- ---------- auto resolución ----------
    -- 7. devolución fuera de SLA -> alerta abierta
    insert into public.cs_devoluciones (cliente_id, titulo, solicitada_at)
    values (v_cli_a, '__humo003_dev__', now() - interval '5 days');
    v_j := public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_cli_a and tipo = 'devolucion_vencida' and not resuelta;
    res := res || format('devolucion fuera de SLA genera alerta|%s|abiertas=%s', v_n = 1, v_n);

    -- 8. al entregarla, esa alerta se resuelve sola
    update public.cs_devoluciones
       set estado = 'entregada', loom_url = 'https://www.loom.com/share/humo003'
     where cliente_id = v_cli_a and titulo = '__humo003_dev__';
    v_j := public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_cli_a and tipo = 'devolucion_vencida' and resuelta and resuelta_at is not null;
    res := res || format('al entregar, la alerta se resuelve sola|%s|resueltas=%s en_retorno=%s',
                         v_n = 1, v_n, v_j->>'resueltas');

    -- 9. satisfaccion_baja NO la resuelve la función (la resuelve una persona)
    v_clave := 'humo003_satisfaccion:' || v_cli_a;
    insert into public.cs_alertas (programa_id, cliente_id, tipo, mensaje, clave_dedupe)
    values ('liam', v_cli_a, 'satisfaccion_baja', 'prueba de humo', v_clave);
    v_j := public.cs_generar_alertas();
    select a.resuelta into v_bool from public.cs_alertas a where a.clave_dedupe = v_clave;
    res := res || format('satisfaccion_baja no se resuelve sola|%s|resuelta=%s', v_bool = false, v_bool);

    -- ---------- cierre de vencidos ----------
    -- 10. cliente B: finalizado + renovación no_renovado con motivo
    v_j := public.cs_cerrar_vencidos();
    select c.estado into v_txt from public.cs_clientes c where c.id = v_cli_b;
    select r.estado, r.motivo into v_txt2, v_motivo from public.cs_renovaciones r where r.id = v_ren_b;
    res := res || format('cerrar_vencidos finaliza al cliente vencido|%s|estado=%s retorno=%s',
                         v_txt = 'finalizado', v_txt, replace(v_j::text, '|', '/'));
    res := res || format('cerrar_vencidos cierra la renovacion abierta|%s|estado=%s motivo=%s',
                         v_txt2 = 'no_renovado' and v_motivo = 'Vencido sin respuesta', v_txt2, v_motivo);

    -- 11. al quedar finalizado, sus alertas se resuelven solas
    v_j := public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas where cliente_id = v_cli_b and not resuelta;
    res := res || format('alertas del cliente finalizado se resuelven|%s|abiertas=%s', v_n = 0, v_n);

    -- ---------- trigger de borrado de renovación ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('liam', '__humo003_c__', public.cs_hoy() - 10, public.cs_hoy() + 80, 'activo')
    returning id into v_cli_c;
    insert into public.cs_renovaciones (cliente_id) values (v_cli_c) returning id into v_ren_c;

    -- 12. abrir la renovación deja al cliente en_renovacion (trigger de 001)
    select c.estado into v_txt from public.cs_clientes c where c.id = v_cli_c;
    res := res || format('abrir renovacion -> cliente en_renovacion|%s|estado=%s',
                         v_txt = 'en_renovacion', v_txt);

    -- 13. borrarla lo devuelve a activo (trigger nuevo de esta migración)
    delete from public.cs_renovaciones where id = v_ren_c;
    select c.estado into v_txt from public.cs_clientes c where c.id = v_cli_c;
    res := res || format('borrar la renovacion -> cliente activo|%s|estado=%s',
                         v_txt = 'activo', v_txt);

    -- ---------- entrada única ----------
    -- 14. cs_correr_diario devuelve los cinco contadores
    v_j := public.cs_correr_diario();
    res := res || format('correr_diario devuelve los contadores|%s|%s',
                         (v_j->>'accionables_creados') is not null
                         and (v_j->>'clientes_finalizados') is not null
                         and (v_j->>'renovaciones_cerradas') is not null
                         and (v_j->>'alertas_creadas') is not null
                         and (v_j->>'alertas_resueltas') is not null,
                         replace(v_j::text, '|', '/'));

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s', replace(sqlerrm, '|', '/'));
    end if;
  end;

  insert into cs_smoke3 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 8. QUERY DE CONTROL (una sola tabla de resultados; mirar la columna ok)
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
    and p.proname in ('cs_aplicar_plantillas', 'cs_cerrar_vencidos', 'cs_generar_alertas',
                      'cs_correr_diario', 'cs_tg_renovaciones_after_delete')
),
trg as (
  -- tgenabled es de tipo "char": sin ::text, el || de abajo rompe con
  -- ERROR 42725 operator is not unique: text || "char"
  select t.tgname::text as tgname, t.tgenabled::text as tgenabled
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'cs_renovaciones'
    and not t.tgisinternal
    and t.tgname = 'cs_trg_after_delete'
)
select '01 funciones nuevas' as control, 'cantidad' as objeto, '5' as esperado,
       (select count(*) from nuevas)::text as obtenido, (select count(*) from nuevas) = 5 as ok
union all
select '02 security definer', f.proname, 'true', f.prosecdef::text, f.prosecdef from nuevas f
union all
select '03 search_path', f.proname, 'search_path=public', f.config, f.config ~ 'search_path=public' from nuevas f
union all
select '04 sin execute para anon', f.proname, 'false',
       has_function_privilege('anon', f.oid, 'EXECUTE')::text,
       not has_function_privilege('anon', f.oid, 'EXECUTE')
from nuevas f
union all
select '05 execute para authenticated', f.proname,
       case when f.proname = 'cs_correr_diario' then 'true' else 'false' end,
       has_function_privilege('authenticated', f.oid, 'EXECUTE')::text,
       has_function_privilege('authenticated', f.oid, 'EXECUTE') = (f.proname = 'cs_correr_diario')
from nuevas f
union all
select '06 trigger de borrado', 'cs_renovaciones / cs_trg_after_delete', 'existe y habilitado',
       coalesce((select tgname || ' (tgenabled=' || tgenabled || ')' from trg), '(no existe)'),
       coalesce((select tgenabled = 'O' from trg), false)
union all
select '07 la prueba de humo no dejo datos', 'clientes __humo003_*', '0',
       (select count(*) from public.cs_clientes where nombre like '\_\_humo003\_%')::text,
       (select count(*) from public.cs_clientes where nombre like '\_\_humo003\_%') = 0
union all
select '07 la prueba de humo no dejo datos', 'alertas humo003*', '0',
       (select count(*) from public.cs_alertas where clave_dedupe like 'humo003%')::text,
       (select count(*) from public.cs_alertas where clave_dedupe like 'humo003%') = 0
union all
select '07 la prueba de humo no dejo datos', 'accionables/devoluciones humo003*', '0',
       ((select count(*) from public.cs_devoluciones where titulo like '\_\_humo003\_%')
        + (select count(*) from public.cs_accionables a
           join public.cs_clientes c on c.id = a.cliente_id
           where c.nombre like '\_\_humo003\_%'))::text,
       ((select count(*) from public.cs_devoluciones where titulo like '\_\_humo003\_%')
        + (select count(*) from public.cs_accionables a
           join public.cs_clientes c on c.id = a.cliente_id
           where c.nombre like '\_\_humo003\_%')) = 0
union all
select '08 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke3 s
order by 1, 2;
