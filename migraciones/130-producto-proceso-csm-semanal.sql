-- =====================================================================
-- 130-producto-proceso-csm-semanal.sql  ·  PRODUCTO: proceso CSM semanal (referidos y resell)
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Evitar los minutos :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
-- Requiere 003/039 (accionables y chequeo diario), 069 (cola de Hoy), 106 (wins) y 123 (aviso de servicio).
-- NO depende de la 128: usa fecha_inicio / fecha_fin de cs_clientes tal como estén. Si la 128 corre después,
-- cambia fecha_fin y el próximo chequeo recalcula los resell pendientes (ver 4).
-- NO tiene datos personales. NO manda nada a Discord (ni la prueba de humo ni los controles).
--
-- Del SOP de Service Delivery: el CSM sigue a cada alumno activo con un ritmo fijo.
--   * Pedir referidos en las semanas 2, 4 y 6 del programa (desde fecha_inicio).
--   * Resell (renovación): avisos a 21, 14 y 7 días antes de fecha_fin.
--
-- Qué había (y se reutiliza):
--   * cs_accionables con plantilla_key unique (cliente_id, plantilla_key) + origen 'plantilla' + responsable.
--   * El chequeo diario cs_correr_diario() (003), que ya corre cs_aplicar_plantillas / cs_cerrar_vencidos /
--     cs_generar_alertas. El proceso CSM se engancha ahí: no hay cron nuevo.
--   * La cola de Hoy (cs_cola_hoy, 069) y el aviso diario de servicio (cs_servicio_armar, 123).
--   * La plantilla 'pedir_referidos' de liam (068, día 0, vence a los 14) y los wins (106).
--   Lo que NO había: nada de "semana N" ni de resell por días en accionables. Los avisos de renovación
--   (aviso_1 / aviso_2) viven aparte, en cs_clientes.aviso_1_at / aviso_2_at, y NO se tocan.
--
-- Qué hace:
--   1. cs_proceso_csm_config (una fila por programa, solo el fundador escribe): activo, semanas de referidos
--      (default 2, 4, 6) y días antes del fin para resell (default 21, 14, 7). Queda prendido en teo y liam,
--      apagado en el resto (agus y los demás hasta que tengan alumnos).
--   2. cs_csm_plan(): calcula, sin escribir nada, cada paso de cada alumno vivo (onboarding / activo /
--      en_renovacion; el pausado no) y qué se haría con él. Lo usan el generador y los controles.
--        Referido semana N: vence = fecha_inicio + 7 * (N - 1) (el primer día de esa semana).
--        Resell faltan D días: vence = fecha_fin - D.
--        Títulos: "Pedir referido (semana N)" y "Resell: faltan D días". Responsable bpf, origen 'plantilla'.
--        plantilla_key estable: csm:ref:N  y  csm:res:D:<fecha_fin>  (el resell lleva la fecha de fin del
--        ciclo: al renovar nace un juego nuevo y el del ciclo anterior queda como historia).
--   3. cs_csm_generar(): idempotente (on conflict do nothing sobre la unique existente). Crea solo los pasos
--      con vence entre hoy - 7 y hoy + 7. Los que vencieron hace más de 7 días NO se crean (no se inunda de
--      atrasos): quedan contados como 'saltado_viejo' en los controles.
--   4. Renovación / cambio de fecha_fin: los resell PENDIENTES se renombran a la fecha nueva y se
--      recalcula su vence (los ya hechos quedan). Si el alumno entra en renovación (renovación abierta o
--      estado en_renovacion), los resell pendientes se cierran solos: ya hay un pipeline de renovación.
--   5. Wins: si el alumno cargó un win con fecha entre 7 días antes del inicio de esa semana y 6 días
--      después, el referido de esa semana se crea (o queda) COMPLETADO, "Cubierto por un win cargado",
--      porque el win ya deja su propio pendiente "Pedir referido a <alumno>" (106). Se eligió completar y
--      no omitir para que quede la traza y para que borrar el win no reabra un paso viejo. Un trigger en
--      cs_wins lo hace al instante para los que ya estaban pendientes.
--   6. Coexistencia con la plantilla 'pedir_referidos' (068): si el alumno la tiene, la primera semana
--      configurada (la 2) no se crea ('cubierto_plantilla'): sería el mismo pedido dos veces.
--   7. cs_correr_diario() corre cs_csm_generar() (protegido: si falla no tira abajo el chequeo; el error
--      va en la clave proceso_csm del resultado).
--   8. Hoy y aviso de servicio: bloque "Proceso CSM de hoy" = pasos del proceso que vencen hoy o están
--      vencidos hasta 7 días. NO se duplican con "Accionables vencidos": los csm dentro de esa ventana salen
--      SOLO en el bloque nuevo; los vencidos hace más de 7 días vuelven al bloque de accionables vencidos
--      (así nada queda sin mostrar). Reemplaza cs_cola_hoy (069), cs_servicio_armar (123) y
--      cs_correr_diario (003); respaldo de las tres en cs_bak_130_funciones.
--   9. RPC para la Configuración del programa: cs_csm_resumen() (vista previa, no escribe) y
--      cs_csm_generar() (botón "Generar ahora"), ambas solo fundador.
--
-- Qué NO toca: 128 y sus archivos, Fathom, finanzas, crm, ventas, cs_aplicar_plantillas, los avisos de
-- renovación (aviso_1 / aviso_2), el cron (cs_diario sigue llamando a cs_correr_diario), ningún cliente.
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
    ('cs_hoy()'), ('es_fundador()'), ('cs_puede_ver(text)'), ('cs_tg_updated_at()'),
    ('cs_ren_abierta(text)'), ('cs_correr_diario()'), ('cs_cola_hoy(text,int)'),
    ('cs_servicio_armar(text,date)'), ('cs_servicio_limpio(text)')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 130: faltan funciones (corrieron 037, 069, 106 y 123?): %', v_falta;
  end if;
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_programas'), ('cs_clientes'), ('cs_accionables'), ('cs_renovaciones'), ('cs_wins'),
               ('cs_servicio_config')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 130: faltan tablas (corrieron 106 y 123?): %', v_falta;
  end if;
end $$;

-- Locks juntos al principio (regla del deadlock): FK a cs_programas, trigger en cs_wins.
lock table public.cs_programas, public.cs_clientes, public.cs_accionables, public.cs_wins
  in share row exclusive mode;

-- Respaldo de las tres funciones que se reemplazan.
create table if not exists public.cs_bak_130_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_130_funciones from public, anon, authenticated;
insert into public.cs_bak_130_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('cs_cola_hoy', 'cs_servicio_armar', 'cs_correr_diario')
on conflict (funcion) do nothing;


-- =====================================================================
-- 1. CADENCIA POR PROGRAMA
-- =====================================================================
create table if not exists public.cs_proceso_csm_config (
  programa_id        text primary key references public.cs_programas(id) on delete cascade,
  activo             boolean not null default false,
  -- semanas del programa (desde fecha_inicio) en las que se pide referidos
  referidos_semanas  int[] not null default '{2,4,6}'
                     check (cardinality(referidos_semanas) <= 8
                            and 1 <= all (referidos_semanas) and 52 >= all (referidos_semanas)),
  -- días antes de fecha_fin en los que se avisa el resell
  resell_dias        int[] not null default '{21,14,7}'
                     check (cardinality(resell_dias) <= 6
                            and 1 <= all (resell_dias) and 365 >= all (resell_dias)),
  updated_at         timestamptz not null default now()
);
comment on table public.cs_proceso_csm_config is
  'Cadencia del proceso CSM semanal por programa (130): semanas de referidos y días antes del fin para resell. Lectura: quien ve el programa; escritura: fundador.';

drop trigger if exists cs_proceso_csm_config_updated_at on public.cs_proceso_csm_config;
create trigger cs_proceso_csm_config_updated_at before update on public.cs_proceso_csm_config
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_proceso_csm_config enable row level security;
revoke all on table public.cs_proceso_csm_config from anon, authenticated;
grant select, insert, update, delete on table public.cs_proceso_csm_config to authenticated;
drop policy if exists cs_ver on public.cs_proceso_csm_config;
create policy cs_ver on public.cs_proceso_csm_config for select to authenticated
  using (public.cs_puede_ver(programa_id));
drop policy if exists cs_fundador_ins on public.cs_proceso_csm_config;
create policy cs_fundador_ins on public.cs_proceso_csm_config for insert to authenticated
  with check (public.es_fundador());
drop policy if exists cs_fundador_upd on public.cs_proceso_csm_config;
create policy cs_fundador_upd on public.cs_proceso_csm_config for update to authenticated
  using (public.es_fundador()) with check (public.es_fundador());
drop policy if exists cs_fundador_del on public.cs_proceso_csm_config;
create policy cs_fundador_del on public.cs_proceso_csm_config for delete to authenticated
  using (public.es_fundador());

-- Una fila por programa existente: prendido en teo y liam, apagado en el resto.
insert into public.cs_proceso_csm_config (programa_id, activo)
select p.id, p.id in ('teo', 'liam') from public.cs_programas p
on conflict (programa_id) do nothing;


-- =====================================================================
-- 2. PLAN (no escribe nada)
-- =====================================================================
-- Un renglón por alumno vivo y por paso configurado, con la acción que corresponde:
--   crear               se crea pendiente (vence entre hoy - 7 y hoy + 7)
--   cubierto_win        se crea completado: hay un win en esa semana
--   cubierto_plantilla  no se crea: el alumno tiene la plantilla 'pedir_referidos' (primera semana)
--   renovacion_en_curso no se crea: resell de un alumno que ya está en renovación
--   saltado_viejo       no se crea: venció hace más de 7 días
--   futuro              todavía no (vence a más de 7 días)
--   fuera_de_ciclo      resell con fecha_fin pasada, o referido posterior a fecha_fin
-- p_incluir_apagado: para la vista previa de un programa que todavía está apagado.
create or replace function public.cs_csm_plan(
  p_programa         text default null,
  p_hoy              date default null,
  p_incluir_apagado  boolean default false
)
returns table (
  programa_id    text,
  cliente_id     uuid,
  paso           text,
  n              int,
  plantilla_key  text,
  titulo         text,
  vence          date,
  fecha_fin      date,
  accion         text
)
language sql
stable
security definer
set search_path = public
as $fn$
  with prm as (
    select coalesce(p_hoy, public.cs_hoy()) as hoy
  ),
  base as (
    select c.id as cliente_id, c.programa_id, c.estado, c.fecha_inicio, c.fecha_fin,
           k.referidos_semanas, k.resell_dias,
           exists (select 1 from public.cs_renovaciones r
                   where r.cliente_id = c.id and public.cs_ren_abierta(r.estado)) as ren_abierta,
           exists (select 1 from public.cs_accionables a
                   where a.cliente_id = c.id and a.plantilla_key = 'pedir_referidos') as tiene_pedir_ref
    from public.cs_clientes c
    join public.cs_proceso_csm_config k
      on k.programa_id = c.programa_id and (k.activo or p_incluir_apagado)
    where c.estado in ('onboarding', 'activo', 'en_renovacion')
      and (p_programa is null or c.programa_id = p_programa)
  ),
  pasos as (
    select b.*, 'ref'::text as paso, u.s as n,
           b.fecha_inicio + 7 * (u.s - 1) as vence,
           'csm:ref:' || u.s as plantilla_key,
           'Pedir referido (semana ' || u.s || ')' as titulo,
           (u.s = min(u.s) over (partition by b.cliente_id)) as primero
    from base b
    cross join lateral (select distinct x as s from unnest(b.referidos_semanas) x) u
    union all
    select b.*, 'res'::text, u.d,
           b.fecha_fin - u.d,
           'csm:res:' || u.d || ':' || to_char(b.fecha_fin, 'YYYY-MM-DD'),
           case when u.d = 1 then 'Resell: falta 1 día' else 'Resell: faltan ' || u.d || ' días' end,
           false
    from base b
    cross join lateral (select distinct x as d from unnest(b.resell_dias) x) u
  )
  select p.programa_id, p.cliente_id, p.paso, p.n, p.plantilla_key, p.titulo, p.vence, p.fecha_fin,
         case
           when p.paso = 'res' and p.fecha_fin < prm.hoy then 'fuera_de_ciclo'
           when p.paso = 'ref' and p.vence > p.fecha_fin then 'fuera_de_ciclo'
           when p.vence < prm.hoy - 7 then 'saltado_viejo'
           when p.vence > prm.hoy + 7 then 'futuro'
           when p.paso = 'res' and (p.ren_abierta or p.estado = 'en_renovacion') then 'renovacion_en_curso'
           when p.paso = 'ref' and p.primero and p.tiene_pedir_ref then 'cubierto_plantilla'
           when p.paso = 'ref' and exists (
                  select 1 from public.cs_wins w
                  where w.cliente_id = p.cliente_id
                    and w.fecha between p.vence - 7 and p.vence + 6
                    and w.fecha <= prm.hoy) then 'cubierto_win'
           else 'crear'
         end
  from pasos p
  cross join prm;
$fn$;

comment on function public.cs_csm_plan(text, date, boolean) is
  'Plan del proceso CSM (130): cada paso de cada alumno vivo y qué se haría. No escribe. Interna.';


-- =====================================================================
-- 3. GENERADOR (idempotente)
-- =====================================================================
create or replace function public.cs_csm_generar(p_programa text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_recalc   int := 0;
  v_obsol    int := 0;
  v_ren      int := 0;
  v_win      int := 0;
  v_creados  int := 0;
  v_comp     int := 0;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede correr el proceso CSM' using errcode = '42501';
  end if;

  -- 1. Resell pendiente de un ciclo anterior: pasa a la fecha de fin vigente (clave y vence nuevos).
  --    Solo si el nuevo no existe ya. Los completados no se tocan.
  with mov as (
    update public.cs_accionables a
       set plantilla_key = 'csm:res:' || split_part(a.plantilla_key, ':', 3) || ':' || to_char(c.fecha_fin, 'YYYY-MM-DD'),
           vence = c.fecha_fin - split_part(a.plantilla_key, ':', 3)::int
      from public.cs_clientes c
      join public.cs_proceso_csm_config k on k.programa_id = c.programa_id and k.activo
     where c.id = a.cliente_id
       and a.plantilla_key ~ '^csm:res:[0-9]+:[0-9]{4}-[0-9]{2}-[0-9]{2}$'
       and a.estado <> 'completado'
       and a.origen = 'plantilla'
       and split_part(a.plantilla_key, ':', 4) <> to_char(c.fecha_fin, 'YYYY-MM-DD')
       and (p_programa is null or c.programa_id = p_programa)
       and not exists (
         select 1 from public.cs_accionables x
         where x.cliente_id = a.cliente_id
           and x.plantilla_key = 'csm:res:' || split_part(a.plantilla_key, ':', 3) || ':' || to_char(c.fecha_fin, 'YYYY-MM-DD'))
    returning 1)
  select count(*) into v_recalc from mov;

  -- 1b. Los que quedaron de un ciclo anterior porque el juego nuevo ya existía: se cierran.
  with obs as (
    update public.cs_accionables a
       set estado = 'completado',
           descripcion = left(btrim(coalesce(a.descripcion, '') || ' Cerrado: cambió la fecha de fin del programa.'), 500)
      from public.cs_clientes c
     where c.id = a.cliente_id
       and a.plantilla_key ~ '^csm:res:[0-9]+:[0-9]{4}-[0-9]{2}-[0-9]{2}$'
       and a.estado <> 'completado'
       and a.origen = 'plantilla'
       and split_part(a.plantilla_key, ':', 4) <> to_char(c.fecha_fin, 'YYYY-MM-DD')
       and (p_programa is null or c.programa_id = p_programa)
    returning 1)
  select count(*) into v_obsol from obs;

  -- 2. Alumno ya en renovación: los resell pendientes se cierran solos.
  with ren as (
    update public.cs_accionables a
       set estado = 'completado',
           descripcion = left(btrim(coalesce(a.descripcion, '') || ' Cerrado: renovación en curso.'), 500)
      from public.cs_clientes c
     where c.id = a.cliente_id
       and a.plantilla_key like 'csm:res:%'
       and a.estado <> 'completado'
       and a.origen = 'plantilla'
       and (p_programa is null or c.programa_id = p_programa)
       and (c.estado = 'en_renovacion'
            or exists (select 1 from public.cs_renovaciones r
                       where r.cliente_id = c.id and public.cs_ren_abierta(r.estado)))
    returning 1)
  select count(*) into v_ren from ren;

  -- 3. Referido pendiente con un win cargado en esa semana: completado.
  with win as (
    update public.cs_accionables a
       set estado = 'completado',
           descripcion = left(btrim(coalesce(a.descripcion, '') || ' Cubierto por un win cargado.'), 500)
     where a.plantilla_key ~ '^csm:ref:[0-9]+$'
       and a.estado <> 'completado'
       and a.origen = 'plantilla'
       and a.vence is not null
       and (p_programa is null or a.programa_id = p_programa)
       and exists (select 1 from public.cs_wins w
                   where w.cliente_id = a.cliente_id
                     and w.fecha between a.vence - 7 and a.vence + 6
                     and w.fecha <= public.cs_hoy())
    returning 1)
  select count(*) into v_win from win;

  -- 4. Altas: crear (pendiente) y cubierto_win (completado). on conflict: la unique de 001.
  with nuevos as (
    insert into public.cs_accionables
      (programa_id, cliente_id, responsable, titulo, descripcion, estado, vence, origen, plantilla_key)
    select pl.programa_id, pl.cliente_id, 'bpf', pl.titulo,
           case when pl.accion = 'cubierto_win' then 'Proceso CSM. Cubierto por un win cargado.'
                when pl.paso = 'ref' then 'Proceso CSM: pedir referido (semana ' || pl.n || ' del programa).'
                else 'Proceso CSM: la renovación vence el ' || to_char(pl.fecha_fin, 'DD/MM/YYYY') || '.' end,
           case when pl.accion = 'cubierto_win' then 'completado' else 'pendiente' end,
           pl.vence, 'plantilla', pl.plantilla_key
    from public.cs_csm_plan(p_programa, null, false) pl
    where pl.accion in ('crear', 'cubierto_win')
    on conflict (cliente_id, plantilla_key) do nothing
    returning estado)
  select count(*), count(*) filter (where estado = 'completado') into v_creados, v_comp from nuevos;

  return jsonb_build_object(
    'creados',               v_creados,
    'creados_ya_cubiertos',  v_comp,
    'resell_recalculados',   v_recalc,
    'resell_cerrados_ciclo', v_obsol,
    'resell_cerrados_renov', v_ren,
    'referidos_cerrados_win', v_win,
    'corrido_at',            now());
end;
$fn$;

comment on function public.cs_csm_generar(text) is
  'Genera los accionables del proceso CSM (130). Idempotente. Lo llama cs_correr_diario y el botón de Configuración (fundador).';

-- Vista previa para la Configuración: cuenta lo que haría hoy, sin escribir. Incluye programas apagados.
create or replace function public.cs_csm_resumen(p_programa text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_j jsonb;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede ver el proceso CSM' using errcode = '42501';
  end if;
  select coalesce(jsonb_object_agg(z.accion, z.n), '{}'::jsonb) into v_j
  from (select pl.accion, count(*) as n
        from public.cs_csm_plan(p_programa, null, true) pl
        group by pl.accion) z;
  return v_j;
end;
$fn$;


-- =====================================================================
-- 4. WINS: el referido de esa semana se completa al cargar el win
-- =====================================================================
create or replace function public.cs_tg_csm_win()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.cs_accionables a
     set estado = 'completado',
         descripcion = left(btrim(coalesce(a.descripcion, '') || ' Cubierto por un win cargado.'), 500)
   where a.cliente_id = new.cliente_id
     and a.plantilla_key ~ '^csm:ref:[0-9]+$'
     and a.estado <> 'completado'
     and a.origen = 'plantilla'
     and a.vence is not null
     and new.fecha between a.vence - 7 and a.vence + 6;
  return null;
end;
$fn$;

drop trigger if exists cs_trg_csm_win on public.cs_wins;
create trigger cs_trg_csm_win after insert on public.cs_wins
  for each row execute function public.cs_tg_csm_win();


-- =====================================================================
-- 5. CHEQUEO DIARIO (003) + proceso CSM
-- =====================================================================
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
  v_csm jsonb;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede correr el chequeo' using errcode = '42501';
  end if;

  v_acc := public.cs_aplicar_plantillas();
  v_ven := public.cs_cerrar_vencidos();
  v_ale := public.cs_generar_alertas();

  -- 130: proceso CSM. Aislado: si falla, el chequeo y las alertas siguen y el error queda en el resultado.
  begin
    v_csm := public.cs_csm_generar();
  exception when others then
    v_csm := jsonb_build_object('error', sqlerrm);
  end;

  return jsonb_build_object(
    'accionables_creados',   v_acc,
    'clientes_finalizados',  (v_ven->>'clientes_finalizados')::int,
    'renovaciones_cerradas', (v_ven->>'renovaciones_cerradas')::int,
    'alertas_creadas',       (v_ale->>'creadas')::int,
    'alertas_resueltas',     (v_ale->>'resueltas')::int,
    'proceso_csm',           v_csm,
    'corrido_at',            now()
  );
end;
$fn$;


-- =====================================================================
-- 6. COLA DE HOY (069) + tipo 'proceso_csm'
-- =====================================================================
-- Igual que 069. Cambios: (a) los accionables csm:% con vence entre hoy - 7 y hoy salen como tipo
-- 'proceso_csm' (no como 'accionable'); (b) rama nueva 'proceso_csm' (alumnos vivos no pausados).
-- Los csm próximos (hasta la ventana) y los vencidos hace más de 7 días siguen como 'accionable'.
create or replace function public.cs_cola_hoy(p_programa text, p_dias_adelante int default 3)
returns table (
  tipo         text,
  cuando       text,
  fecha        date,
  dias_atraso  int,
  cliente_id   uuid,
  cliente      text,
  titulo       text,
  detalle      text,
  ref_id       uuid,
  orden        int
)
language sql
stable
security invoker
set search_path = public
as $fn$
  with prm as (
    select public.cs_hoy() as hoy,
           public.cs_hoy() + greatest(coalesce(p_dias_adelante, 3), 0) as hasta
  ),
  prog as (
    select p.* from public.cs_programas p where p.id = p_programa
  ),
  vivos as (
    select c.*, pr.aviso_1_dias, pr.aviso_2_dias, pr.sla_onboarding_dias, pr.sla_devolucion_horas
    from public.cs_clientes c
    join prog pr on pr.id = c.programa_id
    where c.estado not in ('finalizado', 'baja')
  ),
  ult_seg as (
    select v.id as cliente_id, s.fecha as ult_fecha, s.proximo_contacto
    from vivos v
    left join lateral (
      select x.fecha, x.proximo_contacto
      from public.cs_seguimientos x
      where x.cliente_id = v.id
      order by x.fecha desc, x.created_at desc
      limit 1
    ) s on true
  ),
  tareas as (
    -- aviso 1: entra en la ventana el día fecha_fin - aviso_1_dias
    select 'aviso_1'::text as tipo, v.fecha_fin - v.aviso_1_dias as fecha,
           v.id as cliente_id, v.nombre as cliente,
           format('Aviso de renovación (%s días)', v.aviso_1_dias) as titulo,
           format('Vence el %s', to_char(v.fecha_fin, 'DD/MM')) as detalle,
           v.id as ref_id, 2 as prio
    from vivos v, prm
    where v.estado <> 'pausado'
      and v.aviso_1_at is null
      and v.fecha_fin >= prm.hoy
      and v.fecha_fin - prm.hoy > v.aviso_2_dias
      and v.fecha_fin - v.aviso_1_dias <= prm.hasta

    union all
    select 'aviso_2', v.fecha_fin - v.aviso_2_dias, v.id, v.nombre,
           format('Aviso de renovación (%s días)', v.aviso_2_dias),
           format('Vence el %s', to_char(v.fecha_fin, 'DD/MM')),
           v.id, 1
    from vivos v, prm
    where v.estado <> 'pausado'
      and v.aviso_2_at is null
      and v.fecha_fin >= prm.hoy
      and v.fecha_fin - v.aviso_2_dias <= prm.hasta

    union all
    -- accionables del equipo de clientes vivos (130: sin los del proceso CSM de la ventana de 7 días)
    select 'accionable', a.vence, v.id, v.nombre, a.titulo,
           nullif(a.descripcion, ''), a.id, 3
    from vivos v
    join public.cs_accionables a on a.cliente_id = v.id
    cross join prm
    where a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence is not null
      and a.vence <= prm.hasta
      and not (a.plantilla_key like 'csm:%' and a.vence between prm.hoy - 7 and prm.hoy)

    union all
    -- 130: proceso CSM de hoy = referidos y resell que vencen hoy o vencieron hace hasta 7 días
    select 'proceso_csm', a.vence, v.id, v.nombre, a.titulo,
           nullif(a.descripcion, ''), a.id, 2
    from vivos v
    join public.cs_accionables a on a.cliente_id = v.id
    cross join prm
    where v.estado <> 'pausado'
      and a.plantilla_key like 'csm:%'
      and a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence between prm.hoy - 7 and prm.hoy

    union all
    -- offboarding de clientes cerrados (ítems de cierre)
    select 'accionable', a.vence, c.id, c.nombre, a.titulo,
           'Offboarding', a.id, 3
    from public.cs_clientes c
    join prog pr on pr.id = c.programa_id
    join public.cs_accionables a on a.cliente_id = c.id
    cross join prm
    where c.estado in ('finalizado', 'baja')
      and a.plantilla_key like 'cierre:%'
      and a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence is not null
      and a.vence <= prm.hasta

    union all
    -- próximo contacto agendado en el último seguimiento
    select 'contacto', u.proximo_contacto, v.id, v.nombre,
           'Contactar', format('Último contacto el %s', to_char(u.ult_fecha, 'DD/MM')),
           v.id, 4
    from vivos v
    join ult_seg u on u.cliente_id = v.id
    cross join prm
    where u.proximo_contacto is not null
      and u.proximo_contacto <= prm.hasta

    union all
    -- renovación abierta sin movimiento: 7 días desde el último contacto
    -- (o desde que se abrió) y sin próximo contacto agendado
    select 'renovacion', greatest(u.ult_fecha, (r.iniciada_at at time zone 'America/Argentina/Buenos_Aires')::date) + 7,
           v.id, v.nombre, 'Mover la renovación',
           format('Etapa: %s', replace(r.estado, '_', ' ')), r.id, 2
    from vivos v
    join ult_seg u on u.cliente_id = v.id
    join public.cs_renovaciones r on r.cliente_id = v.id and public.cs_ren_abierta(r.estado)
    cross join prm
    where v.estado <> 'pausado'
      and u.proximo_contacto is null
      and greatest(u.ult_fecha, (r.iniciada_at at time zone 'America/Argentina/Buenos_Aires')::date) + 7 <= prm.hasta

    union all
    -- call de onboarding sin agendar (la última call de onboarding)
    select 'onboarding', v.fecha_inicio + v.sla_onboarding_dias, v.id, v.nombre,
           'Agendar call de onboarding', null, k.id, 1
    from vivos v
    cross join lateral (
      select x.id, x.estado from public.cs_calls x
      where x.cliente_id = v.id and x.tipo = 'onboarding'
      order by x.created_at desc limit 1
    ) k
    cross join prm
    where k.estado = 'pendiente_agendar'
      and v.fecha_inicio + v.sla_onboarding_dias <= prm.hasta

    union all
    -- devoluciones pendientes, con fecha = vencimiento del SLA
    select 'devolucion',
           ((d.solicitada_at + make_interval(hours => v.sla_devolucion_horas))
              at time zone 'America/Argentina/Buenos_Aires')::date,
           v.id, v.nombre, 'Devolución: ' || d.titulo, null, d.id, 2
    from vivos v
    join public.cs_devoluciones d on d.cliente_id = v.id
    cross join prm
    where d.estado in ('pendiente', 'en_proceso')
      and ((d.solicitada_at + make_interval(hours => v.sla_devolucion_horas))
             at time zone 'America/Argentina/Buenos_Aires')::date <= prm.hasta
  )
  select t.tipo,
         case when t.fecha < prm.hoy then 'atrasado'
              when t.fecha = prm.hoy then 'hoy'
              else 'proximo' end,
         t.fecha,
         greatest(prm.hoy - t.fecha, 0),
         t.cliente_id, t.cliente, t.titulo, t.detalle, t.ref_id,
         (row_number() over (
            order by case when t.fecha < prm.hoy then 0 when t.fecha = prm.hoy then 1 else 2 end,
                     t.fecha, t.prio, t.cliente))::int
  from tareas t cross join prm
  order by 10;
$fn$;

comment on function public.cs_cola_hoy(text, int) is
  'Cola de trabajo del CSM, en vivo: avisos, accionables del equipo, proceso CSM, contactos, renovaciones sin movimiento, onboarding y devoluciones. Ver 069 y 130.';

revoke all on function public.cs_cola_hoy(text, int) from public, anon;
grant execute on function public.cs_cola_hoy(text, int) to authenticated;


-- =====================================================================
-- 7. AVISO DE SERVICIO (123) + bloque "Proceso CSM de hoy"
-- =====================================================================
-- Igual que 123. Cambios: (a) loop nuevo del proceso CSM (vence entre hoy - 7 y hoy), (b) el loop de
-- accionables vencidos excluye los csm de esa ventana (así no se repiten), (c) el bloque nuevo y su
-- conteo 'proceso_csm' en cuentas. Vale la misma regla de nombres (cs_discord_canales.incluir_nombre).
create or replace function public.cs_servicio_armar(p_programa text, p_fecha date default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_hoy     date := coalesce(p_fecha, public.cs_hoy());
  v_prog    text;
  v_cfg     public.cs_servicio_config%rowtype;
  v_aviso   int;
  v_alerta  int;
  v_mor     int;
  v_accl    int;
  v_base    text;
  v_nom     boolean := true;
  v_monto   boolean := false;
  r         record;
  l_alerta  text[] := '{}';  n_alerta int := 0;
  l_aviso   text[] := '{}';  n_aviso  int := 0;
  n_nunca   int := 0;
  l_csm     text[] := '{}';  n_csm    int := 0;
  l_acc     text[] := '{}';  n_acc    int := 0;
  l_accl    text[] := '{}';  n_accl   int := 0;
  l_sat     text[] := '{}';  n_sat    int := 0;
  l_mor     text[] := '{}';  n_mor    int := 0;
  n_sincruz int := 0;
  v_lineas  text[] := '{}';
  v_partes  text[] := '{}';
  v_titulo  text;
  v_cur     text;
  v_hdr     text;
  v_l       text;
  v_txt     text;
  v_es_h    boolean;
  v_dias    text[] := array['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
  v_vivos   text[] := array['onboarding', 'activo', 'en_renovacion'];
  v_total   int;
  v_ref     text;
begin
  select p.nombre into v_prog from public.cs_programas p where p.id = p_programa;
  if v_prog is null then
    raise exception 'cs: programa inexistente: %', p_programa using errcode = '22023';
  end if;

  select * into v_cfg from public.cs_servicio_config c where c.programa_id = p_programa;
  v_aviso  := coalesce(v_cfg.llamada_aviso_dias, 7);
  v_alerta := coalesce(v_cfg.llamada_alerta_dias, 10);
  v_mor    := coalesce(v_cfg.morosos_dias, 14);
  v_accl   := coalesce(v_cfg.acc_llamada_dias, 0);
  v_base   := rtrim(coalesce(v_cfg.url_app, 'https://producto.dystopia.com.ar'), '/');

  select coalesce(k.incluir_nombre, true), coalesce(k.incluir_monto, false)
    into v_nom, v_monto
  from public.cs_discord_canales k
  where k.programa_id = p_programa and k.tipo = 'servicio';
  v_nom := coalesce(v_nom, true);
  v_monto := coalesce(v_monto, false);

  -- ---------- sin llamada (solo alumnos vivos; cualquier llamada asignada al alumno) ----------
  for r in
    select c.id, c.nombre,
           case when u.ultima_llamada is null then null else greatest(0, v_hoy - u.ultima_llamada) end as dias
    from public.cs_clientes c
    left join public.cs_v_ultima_llamada u on u.cliente_id = c.id
    where c.programa_id = p_programa
      and c.estado = any (v_vivos)
    order by greatest(0, v_hoy - u.ultima_llamada) desc nulls last, c.nombre
  loop
    v_ref := case when v_nom
                  then '• [' || public.cs_servicio_limpio(r.nombre) || '](<' || v_base || '/#/p/' || p_programa || '/c/' || r.id || '>)'
                  else null end;
    if r.dias is null then
      n_nunca := n_nunca + 1;
    elsif r.dias >= v_alerta then
      n_alerta := n_alerta + 1;
      if v_nom then l_alerta := l_alerta || (v_ref || ' · ' || r.dias || ' días'); end if;
    elsif r.dias >= v_aviso then
      n_aviso := n_aviso + 1;
      if v_nom then l_aviso := l_aviso || (v_ref || ' · ' || r.dias || ' días'); end if;
    end if;
  end loop;

  -- ---------- proceso CSM de hoy (130): referidos y resell que vencen hoy o hace hasta 7 días ----------
  for r in
    select c.id, c.nombre, a.titulo, a.vence, (v_hoy - a.vence) as atraso
    from public.cs_accionables a
    join public.cs_clientes c on c.id = a.cliente_id
    where a.programa_id = p_programa
      and a.plantilla_key like 'csm:%'
      and a.responsable = 'bpf'
      and a.estado <> 'completado'
      and a.vence between v_hoy - 7 and v_hoy
      and c.estado = any (v_vivos)
    order by a.vence, c.nombre
  loop
    n_csm := n_csm + 1;
    if v_nom then
      l_csm := l_csm || ('• [' || public.cs_servicio_limpio(r.nombre) || '](<' || v_base || '/#/p/' || p_programa || '/c/' || r.id || '>)'
        || ' · ' || left(public.cs_servicio_limpio(r.titulo), 50)
        || case when r.atraso = 0 then ' · vence hoy'
                else ' · venció ' || to_char(r.vence, 'DD/MM') || ' (' || r.atraso || ' d)' end);
    end if;
  end loop;

  -- ---------- accionables vencidos (cs_accionables: tienen vencimiento y responsable) ----------
  -- 130: los del proceso CSM de la ventana de 7 días salen solo en su bloque.
  for r in
    select c.id, c.nombre, a.titulo, a.responsable, (v_hoy - a.vence) as atraso, a.vence
    from public.cs_accionables a
    join public.cs_clientes c on c.id = a.cliente_id
    where a.programa_id = p_programa
      and a.estado <> 'completado'
      and a.vence < v_hoy
      and c.estado = any (v_vivos)
      and not (a.plantilla_key like 'csm:%' and a.vence >= v_hoy - 7 and a.responsable = 'bpf')
    order by a.vence, c.nombre
  loop
    n_acc := n_acc + 1;
    if v_nom then
      l_acc := l_acc || ('• [' || public.cs_servicio_limpio(r.nombre) || '](<' || v_base || '/#/p/' || p_programa || '/c/' || r.id || '>)'
        || ' · ' || left(public.cs_servicio_limpio(r.titulo), 50)
        || ' · ' || case r.responsable when 'bpf' then 'BPF' else 'Cliente' end
        || ' · venció ' || to_char(r.vence, 'DD/MM') || ' (' || r.atraso || ' d)');
    end if;
  end loop;

  -- ---------- accionables de llamadas sin completar (opcional) ----------
  if v_accl > 0 then
    for r in
      select c.id, c.nombre, count(*) as n, min(l.fecha) as desde
      from public.cs_llamada_accionables a
      join public.cs_llamadas l on l.id = a.llamada_id
      join public.cs_clientes c on c.id = a.cliente_id
      where a.programa_id = p_programa
        and not a.hecho
        and l.fecha <= v_hoy - v_accl
        and c.estado = any (v_vivos)
      group by c.id, c.nombre
      order by min(l.fecha), c.nombre
    loop
      n_accl := n_accl + 1;
      if v_nom then
        l_accl := l_accl || ('• [' || public.cs_servicio_limpio(r.nombre) || '](<' || v_base || '/#/p/' || p_programa || '/c/' || r.id || '?sec=llamadas>)'
          || ' · ' || r.n || case when r.n = 1 then ' pendiente' else ' pendientes' end
          || ' desde el ' || to_char(r.desde, 'DD/MM'));
      end if;
    end loop;
  end if;

  -- ---------- formularios de satisfacción para enviar (misma regla que cs_satisf_pendientes, 106) ----------
  for r in
    select c.id, c.nombre, m.nombre as momento, h.hito
    from public.cs_satisf_momentos m
    join public.cs_clientes c on c.programa_id = m.programa_id
    left join public.cs_onboardings ob on ob.cliente_id = c.id and ob.estado = 'completado'
    cross join lateral (
      select case m.tipo
               when 'onboarding_completo' then (ob.completado_at at time zone 'America/Argentina/Buenos_Aires')::date
               when 'dias_desde_inicio'   then c.fecha_inicio + m.valor
               when 'porcentaje_ciclo'    then c.fecha_inicio + ((c.fecha_fin - c.fecha_inicio) * m.valor / 100)
               when 'dias_antes_fin'      then c.fecha_fin - m.valor
             end as hito
    ) h
    left join public.cs_satisf_envios e on e.cliente_id = c.id and e.momento_id = m.id
    where m.programa_id = p_programa
      and m.activo
      and c.estado = any (v_vivos)
      and h.hito is not null
      and h.hito <= v_hoy
      and h.hito >= m.desde
      and (e.id is null or e.enviado_at is null)
    order by h.hito, c.nombre
  loop
    n_sat := n_sat + 1;
    if v_nom then
      l_sat := l_sat || ('• [' || public.cs_servicio_limpio(r.nombre) || '](<' || v_base || '/#/p/' || p_programa || '/c/' || r.id || '>)'
        || ' · ' || left(public.cs_servicio_limpio(r.momento), 40));
    end if;
  end loop;

  -- ---------- morosos (Finanzas, solo lectura) ----------
  begin
    for r in
      select m.cliente_id, m.cuotas, m.dias_max, m.pendiente, c.nombre, c.estado
      from public.cs_servicio_morosos(p_programa, v_mor, v_hoy) m
      left join public.cs_clientes c on c.id = m.cliente_id
      order by m.dias_max desc, c.nombre
    loop
      if r.cliente_id is null then
        n_sincruz := n_sincruz + r.cuotas;
      else
        n_mor := n_mor + 1;
        if v_nom then
          l_mor := l_mor || ('• [' || public.cs_servicio_limpio(r.nombre) || '](<' || v_base || '/#/p/' || p_programa || '/c/' || r.cliente_id || '>)'
            || ' · ' || r.cuotas || case when r.cuotas = 1 then ' cuota' else ' cuotas' end
            || ' · ' || r.dias_max || ' días de atraso'
            || case when v_monto then ' · USD ' || round(r.pendiente)::text else '' end
            || case when r.estado = any (v_vivos) then '' else ' · ' || r.estado end);
        end if;
      end if;
    end loop;
  exception when others then
    -- Finanzas no disponible o sin permiso: el aviso sale igual, sin ese bloque.
    n_mor := 0; l_mor := '{}'; n_sincruz := 0;
  end;

  -- ---------- armado ----------
  v_titulo := '**Servicio · ' || public.cs_servicio_limpio(v_prog) || '** — '
              || v_dias[extract(isodow from v_hoy)::int] || ' ' || to_char(v_hoy, 'DD/MM');

  v_total := n_alerta + n_aviso + n_nunca + n_csm + n_acc + n_accl + n_sat + n_mor;

  if v_total = 0 then
    v_partes := array[v_titulo || E'\n' || '✅ Todo al día'];
    return jsonb_build_object('partes', to_jsonb(v_partes),
      'cuentas', jsonb_build_object('alerta', 0, 'aviso', 0, 'nunca', 0, 'proceso_csm', 0, 'accionables', 0,
        'acc_llamadas', 0, 'formularios', 0, 'morosos', 0, 'morosos_sin_cruzar', n_sincruz,
        'con_nombre', v_nom));
  end if;

  -- el prefijo chr(1) marca una línea de encabezado de bloque
  if n_alerta > 0 then
    v_lineas := v_lineas || (chr(1) || '🔴 **Sin llamada hace ' || v_alerta || ' días o más** (' || n_alerta || ')') || l_alerta;
  end if;
  if n_aviso > 0 then
    v_lineas := v_lineas || (chr(1) || '🟡 **Sin llamada hace ' || v_aviso || ' a ' || (v_alerta - 1) || ' días** (' || n_aviso || ')') || l_aviso;
  end if;
  if n_nunca > 0 then
    v_lineas := v_lineas || (chr(1) || '⚪ **Sin ninguna llamada registrada**: ' || n_nunca
      || case when n_nunca = 1 then ' alumno activo' else ' alumnos activos' end);
  end if;
  if n_csm > 0 then
    v_lineas := v_lineas || (chr(1) || '🤝 **Proceso CSM de hoy** (' || n_csm || ')') || l_csm;
  end if;
  if n_acc > 0 then
    v_lineas := v_lineas || (chr(1) || '⏰ **Accionables vencidos** (' || n_acc || ')') || l_acc;
  end if;
  if n_accl > 0 then
    v_lineas := v_lineas || (chr(1) || '📝 **Accionables de llamadas sin completar, de hace ' || v_accl || ' días o más** (' || n_accl || ' alumnos)') || l_accl;
  end if;
  if n_sat > 0 then
    v_lineas := v_lineas || (chr(1) || '📋 **Formularios de satisfacción para enviar** (' || n_sat || ')') || l_sat;
  end if;
  if n_mor > 0 then
    v_lineas := v_lineas || (chr(1) || '💸 **Morosos de más de ' || v_mor || ' días** (' || n_mor || ')') || l_mor;
  end if;
  if n_sincruz > 0 and (n_mor > 0 or v_total > 0) then
    v_lineas := v_lineas || ('_' || n_sincruz || case when n_sincruz = 1 then ' cuota atrasada' else ' cuotas atrasadas' end
      || ' de Finanzas no se pudo cruzar con un alumno de forma segura: revisar en Finanzas._');
  end if;

  -- partido en mensajes de hasta ~1800 caracteres (Discord corta en 2000)
  v_cur := v_titulo;
  foreach v_l in array v_lineas loop
    v_es_h := left(v_l, 1) = chr(1);
    v_txt  := case when v_es_h then substr(v_l, 2) else v_l end;
    if v_es_h then v_hdr := v_txt; end if;
    if char_length(v_cur) + 1 + char_length(v_txt) > 1800 then
      v_partes := v_partes || v_cur;
      v_cur := v_titulo || ' (cont.)';
      if not v_es_h and v_hdr is not null then
        v_cur := v_cur || E'\n' || v_hdr || ' (cont.)';
      end if;
    end if;
    v_cur := v_cur || E'\n' || v_txt;
  end loop;
  v_partes := v_partes || v_cur;

  -- tope de 6 mensajes por día y programa
  if cardinality(v_partes) > 6 then
    v_partes := v_partes[1:6];
    v_partes[6] := v_partes[6] || E'\n' || '… y más en la app (Hoy).';
  end if;

  return jsonb_build_object('partes', to_jsonb(v_partes),
    'cuentas', jsonb_build_object('alerta', n_alerta, 'aviso', n_aviso, 'nunca', n_nunca,
      'proceso_csm', n_csm, 'accionables', n_acc, 'acc_llamadas', n_accl, 'formularios', n_sat, 'morosos', n_mor,
      'morosos_sin_cruzar', n_sincruz, 'con_nombre', v_nom));
end;
$fn$;


-- =====================================================================
-- 8. PERMISOS
-- =====================================================================
revoke all on function public.cs_csm_plan(text, date, boolean) from public, anon, authenticated;
revoke all on function public.cs_csm_generar(text) from public, anon;
grant execute on function public.cs_csm_generar(text) to authenticated;   -- valida fundador adentro
revoke all on function public.cs_csm_resumen(text) from public, anon;
grant execute on function public.cs_csm_resumen(text) to authenticated;   -- valida fundador adentro
revoke all on function public.cs_tg_csm_win() from public, anon, authenticated;
revoke all on function public.cs_servicio_armar(text, date) from public, anon, authenticated;
revoke all on function public.cs_correr_diario() from public, anon;
grant execute on function public.cs_correr_diario() to authenticated;


-- =====================================================================
-- 9. PRUEBA DE HUMO (se revierte sola; no manda nada a Discord)
-- =====================================================================
-- Programa de prueba sin webhook ni canales. Termina siempre con 'humo_ok' y deshace todo.
do $humo$
declare
  v_prog  text := 'humo130';
  v_hoy   date := public.cs_hoy();
  v_a     uuid;
  v_b     uuid;
  v_c     uuid;
  v_e     uuid;
  v_n     int;
  v_n2    int;
  v_j     jsonb;
  v_t     text;
  v_err   text;
begin
  begin
    insert into public.cs_programas (id, nombre, activo, plantilla_accionables)
    values (v_prog, '__humo130__', true, '[]'::jsonb);
    insert into public.cs_proceso_csm_config (programa_id, activo)
    values (v_prog, true)
    on conflict (programa_id) do update set activo = true;

    -- A: empezó hace 14 días. ref 2 vence hoy-7 (crear), ref 4 hoy+7 (crear), ref 6 hoy+21 (futuro).
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'Csm Alfa', v_hoy - 14, v_hoy + 100, 'activo') returning id into v_a;
    -- B: 60 días, termina en 14. ref viejos saltados (3), resell 21/14/7 vencen hoy-7 / hoy / hoy+7 (crear 3).
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'Csm Beta', v_hoy - 60, v_hoy + 14, 'activo') returning id into v_b;
    -- C: como A, con un win de hace 5 días: ref 2 cubierto por win, ref 4 crear.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'Csm Gamma', v_hoy - 14, v_hoy + 100, 'activo') returning id into v_c;
    insert into public.cs_wins (programa_id, cliente_id, fecha, texto)
    values (v_prog, v_c, v_hoy - 5, 'Win de humo');
    -- E: como A, con la plantilla pedir_referidos: ref 2 cubierto_plantilla, ref 4 crear.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'Csm Epsilon', v_hoy - 14, v_hoy + 100, 'activo') returning id into v_e;
    insert into public.cs_accionables (programa_id, cliente_id, responsable, titulo, vence, origen, plantilla_key)
    values (v_prog, v_e, 'bpf', 'Pedir referidos', v_hoy, 'plantilla', 'pedir_referidos');
    -- G: en renovación: resell no se crea (3), ref viejos saltados (3).
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'Csm Iota', v_hoy - 60, v_hoy + 14, 'en_renovacion');
    -- D pausado y F finalizado: afuera.
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado, pausado_desde)
    values (v_prog, 'Csm Delta', v_hoy - 14, v_hoy + 100, 'pausado', v_hoy - 5);
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values (v_prog, 'Csm Fin', v_hoy - 100, v_hoy - 1, 'finalizado');

    -- 1. plan: 7 crear, 1 win, 1 plantilla, 3 renovación, 6 saltados, 12 futuros
    select count(*) filter (where accion = 'crear'),
           count(*) filter (where accion = 'cubierto_win') * 100
           + count(*) filter (where accion = 'cubierto_plantilla') * 10
    into v_n, v_n2
    from public.cs_csm_plan(v_prog);
    if v_n <> 7 or v_n2 <> 110 then
      raise exception 'humo 1: plan crear=% win/plantilla=% (esperado 7 y 110)', v_n, v_n2;
    end if;
    select count(*) filter (where accion = 'renovacion_en_curso') * 1000
           + count(*) filter (where accion = 'saltado_viejo') * 10
           + count(*) filter (where accion = 'futuro')
    into v_n from public.cs_csm_plan(v_prog);
    if v_n <> 3000 + 60 + 12 then
      raise exception 'humo 1b: renovacion/saltados/futuros = % (esperado 3072)', v_n;
    end if;
    select count(distinct cliente_id) into v_n from public.cs_csm_plan(v_prog);
    if v_n <> 5 then
      raise exception 'humo 1c: el plan tiene % alumnos (esperado 5: sin pausado ni finalizado)', v_n;
    end if;

    -- 2. generar: 8 filas (7 pendientes + 1 completada por win); la segunda corrida no agrega nada
    v_j := public.cs_csm_generar(v_prog);
    if (v_j ->> 'creados')::int <> 8 or (v_j ->> 'creados_ya_cubiertos')::int <> 1 then
      raise exception 'humo 2: generar devolvió % (esperado creados 8, cubiertos 1)', v_j;
    end if;
    v_j := public.cs_csm_generar(v_prog);
    if (v_j ->> 'creados')::int <> 0 then
      raise exception 'humo 2b: la segunda corrida creó % (no es idempotente)', v_j ->> 'creados';
    end if;
    select count(*) into v_n from public.cs_accionables
    where programa_id = v_prog and plantilla_key like 'csm:%';
    if v_n <> 8 then
      raise exception 'humo 2c: hay % accionables csm (esperado 8)', v_n;
    end if;
    select count(*) into v_n from public.cs_accionables
    where programa_id = v_prog and plantilla_key = 'csm:ref:2' and cliente_id = v_c
      and estado = 'completado' and responsable = 'bpf' and origen = 'plantilla';
    if v_n <> 1 then
      raise exception 'humo 2d: el referido semana 2 de Gamma no quedó completado por el win';
    end if;
    select count(*) into v_n from public.cs_accionables
    where programa_id = v_prog and plantilla_key like 'csm:res:%'
      and cliente_id = v_b and estado = 'pendiente'
      and vence = v_hoy + 14 - split_part(plantilla_key, ':', 3)::int
      and titulo like 'Resell: faltan % días';
    if v_n <> 3 then
      raise exception 'humo 2e: Beta tiene % resell pendientes bien armados (esperado 3)', v_n;
    end if;

    -- 3. Hoy: 3 del proceso (Alfa ref 2, Beta 21 y 14); ninguno repetido como 'accionable'
    select count(*) filter (where tipo = 'proceso_csm'),
           count(*) filter (where tipo = 'accionable' and (titulo like 'Pedir referido (semana%' or titulo like 'Resell:%'))
    into v_n, v_n2 from public.cs_cola_hoy(v_prog);
    if v_n <> 3 or v_n2 <> 0 then
      raise exception 'humo 3: cola proceso_csm=% accionable csm=% (esperado 3 y 0)', v_n, v_n2;
    end if;

    -- 4. aviso de servicio: el mismo bloque, sin repetir en accionables vencidos
    v_j := public.cs_servicio_armar(v_prog) -> 'cuentas';
    v_t := array_to_string(array(select jsonb_array_elements_text(public.cs_servicio_armar(v_prog) -> 'partes')), E'\n');
    if (v_j ->> 'proceso_csm')::int <> 3 or (v_j ->> 'accionables')::int <> 0
       or v_t not like '%Proceso CSM de hoy** (3)%'
       or v_t not like '%Pedir referido (semana 2) · venció%'
       or v_t not like '%Resell: faltan 14 días · vence hoy%' then
      raise exception 'humo 4: aviso % / %', v_j, left(replace(v_t, E'\n', ' / '), 200);
    end if;

    -- 5. vencido hace más de 7 días: vuelve a "Accionables vencidos" y sale del bloque
    update public.cs_accionables set vence = v_hoy - 9
    where cliente_id = v_a and plantilla_key = 'csm:ref:2';
    v_j := public.cs_servicio_armar(v_prog) -> 'cuentas';
    if (v_j ->> 'proceso_csm')::int <> 2 or (v_j ->> 'accionables')::int <> 1 then
      raise exception 'humo 5: aviso con un csm de 9 días de atraso: %', v_j;
    end if;
    select count(*) filter (where tipo = 'proceso_csm'),
           count(*) filter (where tipo = 'accionable' and titulo like 'Pedir referido (semana%')
    into v_n, v_n2 from public.cs_cola_hoy(v_prog);
    if v_n <> 2 or v_n2 <> 1 then
      raise exception 'humo 5b: cola proceso_csm=% accionable=% (esperado 2 y 1)', v_n, v_n2;
    end if;

    -- 6. renovación: nueva fecha_fin de Beta, los 3 resell pendientes se mueven (no se duplican)
    update public.cs_clientes set fecha_fin = v_hoy + 14 + 180 where id = v_b;
    v_j := public.cs_csm_generar(v_prog);
    select count(*) into v_n from public.cs_accionables
    where cliente_id = v_b and plantilla_key like 'csm:res:%' and estado = 'pendiente'
      and split_part(plantilla_key, ':', 4) = to_char(v_hoy + 14 + 180, 'YYYY-MM-DD')
      and vence = (v_hoy + 14 + 180) - split_part(plantilla_key, ':', 3)::int;
    select count(*) into v_n2 from public.cs_accionables where cliente_id = v_b and plantilla_key like 'csm:res:%';
    if v_n <> 3 or v_n2 <> 3 or (v_j ->> 'resell_recalculados')::int <> 3 then
      raise exception 'humo 6: renovación: bien=% total=% recalculados=%', v_n, v_n2, v_j ->> 'resell_recalculados';
    end if;

    -- 7. win nuevo de Alfa hoy: el referido de la semana 4 (vence hoy+7) se completa al instante
    insert into public.cs_wins (programa_id, cliente_id, fecha, texto) values (v_prog, v_a, v_hoy, 'Win humo 2');
    select count(*) into v_n from public.cs_accionables
    where cliente_id = v_a and plantilla_key = 'csm:ref:4' and estado = 'completado';
    select count(*) into v_n2 from public.cs_accionables
    where cliente_id = v_a and plantilla_key = 'csm:ref:2' and estado = 'pendiente';
    if v_n <> 1 or v_n2 <> 1 then
      raise exception 'humo 7: win: ref4 completado=% ref2 pendiente=% (esperado 1 y 1)', v_n, v_n2;
    end if;

    -- 8. apagado: el plan no devuelve nada
    update public.cs_proceso_csm_config set activo = false where programa_id = v_prog;
    select count(*) into v_n from public.cs_csm_plan(v_prog);
    if v_n <> 0 then
      raise exception 'humo 8: apagado y el plan devolvió % filas', v_n;
    end if;

    -- 9. el chequeo diario llama al proceso (solo se mira la definición: no se corre el chequeo real)
    select count(*) into v_n from pg_proc p
    where p.oid = 'public.cs_correr_diario()'::regprocedure
      and pg_get_functiondef(p.oid) like '%cs_csm_generar%';
    if v_n <> 1 then
      raise exception 'humo 9: cs_correr_diario no llama a cs_csm_generar';
    end if;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '130 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 10. CONTROLES (correr de a uno, después del Success; ninguno escribe ni manda a Discord)
-- =====================================================================
-- C1. Cadencia por programa. Tiene que dar teo y liam en true, el resto en false; 2,4,6 y 21,14,7.
-- select programa_id, activo, referidos_semanas, resell_dias from public.cs_proceso_csm_config order by 1;

-- C2. Funciones y trigger. Tiene que dar 6 filas (plan, generar, resumen, tg win, cola, correr_diario) y 1 trigger.
-- select p.proname, p.oid::regprocedure::text from pg_proc p
-- where p.pronamespace = 'public'::regnamespace
--   and p.proname in ('cs_csm_plan','cs_csm_generar','cs_csm_resumen','cs_tg_csm_win','cs_cola_hoy','cs_correr_diario')
-- order by 1;
-- select tgname from pg_trigger where tgname = 'cs_trg_csm_win' and not tgisinternal;

-- C3. CUÁNTOS ACCIONABLES GENERARÍA HOY por programa (sin generarlos). se_crean = pendientes nuevos;
--     ya_cubiertos = se crean completados por un win; saltados_viejos = vencieron hace más de 7 días y
--     NO se crean (el dato para decidir si está bien); en_ventana_proxima = los de hoy+1 a hoy+7 ya incluidos en se_crean.
-- select pl.programa_id, k.activo,
--        count(*) filter (where pl.accion = 'crear') as se_crean,
--        count(*) filter (where pl.accion = 'crear' and pl.paso = 'ref') as referidos,
--        count(*) filter (where pl.accion = 'crear' and pl.paso = 'res') as resell,
--        count(*) filter (where pl.accion = 'cubierto_win') as ya_cubiertos_por_win,
--        count(*) filter (where pl.accion = 'cubierto_plantilla') as cubiertos_por_pedir_referidos,
--        count(*) filter (where pl.accion = 'renovacion_en_curso') as resell_con_renovacion_en_curso,
--        count(*) filter (where pl.accion = 'saltado_viejo') as saltados_viejos,
--        count(*) filter (where pl.accion = 'futuro') as futuros_sin_crear,
--        count(*) filter (where pl.accion = 'fuera_de_ciclo') as fuera_de_ciclo,
--        count(distinct pl.cliente_id) as alumnos
-- from public.cs_csm_plan(null, null, true) pl
-- join public.cs_proceso_csm_config k on k.programa_id = pl.programa_id
-- group by 1, 2 order by 1;

-- C4. Detalle de lo que se crearía hoy, por paso. (n = semana o días)
-- select pl.programa_id, pl.paso, pl.n, pl.vence - public.cs_hoy() as dias_a_vencer, count(*) as alumnos
-- from public.cs_csm_plan(null, null, false) pl
-- where pl.accion = 'crear'
-- group by 1, 2, 3, 4 order by 1, 2, 3, 4;

-- C5. Dos o más pasos distintos para el mismo alumno y la misma key (tiene que dar 0 filas: la unique lo impide).
-- select cliente_id, plantilla_key, count(*) from public.cs_accionables
-- where plantilla_key like 'csm:%' group by 1, 2 having count(*) > 1;

-- C6. Después del primer chequeo (o de "Generar ahora"): lo que existe por programa y estado.
-- select programa_id, estado, count(*) from public.cs_accionables
-- where plantilla_key like 'csm:%' group by 1, 2 order by 1, 2;

-- C7. Resell pendientes con la fecha de fin vieja (tiene que dar 0 después de un chequeo).
-- select a.programa_id, count(*) from public.cs_accionables a
-- join public.cs_clientes c on c.id = a.cliente_id
-- where a.plantilla_key like 'csm:res:%' and a.estado <> 'completado'
--   and split_part(a.plantilla_key, ':', 4) <> to_char(c.fecha_fin, 'YYYY-MM-DD')
-- group by 1;

-- C8. Hoy: tareas del proceso CSM en la cola (por programa). Cambiar 'liam' por 'teo'.
-- select tipo, cuando, count(*) from public.cs_cola_hoy('liam') group by 1, 2 order by 1, 2;

-- C9. Aviso de servicio de hoy, solo cuentas (arma el mensaje, NO lo manda). Debe traer proceso_csm.
-- select public.cs_servicio_armar('liam') -> 'cuentas';

-- C10. El cron sigue igual: 1 job que llama a cs_correr_diario (no se tocó el cron).
-- select jobname, schedule, active, command from cron.job where command ~ 'cs_correr_diario';


-- =====================================================================
-- 11. VUELTA ATRÁS (comentada; correr completa en una sola ejecución si hace falta)
-- =====================================================================
-- begin;
-- -- 1. funciones anteriores (respaldadas al principio de esta migración)
-- do $$
-- declare r record;
-- begin
--   for r in select definicion from public.cs_bak_130_funciones
--            where funcion in ('cs_cola_hoy(text,integer)', 'cs_servicio_armar(text,date)', 'cs_correr_diario()')
--   loop
--     execute r.definicion;
--   end loop;
-- end $$;
-- -- 2. lo nuevo
-- drop trigger if exists cs_trg_csm_win on public.cs_wins;
-- drop function if exists public.cs_tg_csm_win();
-- drop function if exists public.cs_csm_resumen(text);
-- drop function if exists public.cs_csm_generar(text);
-- drop function if exists public.cs_csm_plan(text, date, boolean);
-- -- 3. accionables generados (solo los del proceso; los completados a mano también se van: revisar antes)
-- -- delete from public.cs_accionables where plantilla_key like 'csm:%' and origen = 'plantilla';
-- -- 4. cadencia
-- -- drop table if exists public.cs_proceso_csm_config;
-- commit;
-- -- Después de la vuelta atrás: select pg_get_functiondef('public.cs_cola_hoy(text,int)'::regprocedure) debe
-- -- no mencionar 'proceso_csm', y revocar / otorgar los permisos como en 069, 123 y 003 si hiciera falta.
