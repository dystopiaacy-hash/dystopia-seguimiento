-- =====================================================================
-- 038-seguimientos.sql  —  Dystopia Producto: seguimientos del CSM
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global, compartida con CRM, Ventas y Finanzas.
--
-- Qué hace:
--   - Tabla nueva cs_seguimientos: cada contacto con el cliente (canal,
--     resumen, etapa, avance, próximo contacto). Reemplaza a cs_chequeos,
--     que solo guardaba una nota.
--       canal:  whatsapp | mail | call | reunion | otro   (obligatorio)
--       avance: bien | demorado | trabado                 (opcional)
--       etapa:  una de cs_programas.etapas del programa    (opcional)
--   - Triggers de cs_seguimientos, al insertar:
--       * cs_clientes.ultimo_chequeo_at con la MISMA regla que cs_chequeos
--         (el mayor created_at). La métrica "sin chequeo" no cambia.
--       * si viene etapa, pasa a cs_clientes.etapa.
--       * si viene avance, fila en cs_historial (tabla cs_clientes, campo
--         'avance', valor anterior = el avance del seguimiento previo).
--   - cs_chequeos queda OBSOLETA:
--       * sus filas pasan a cs_seguimientos (mismo id y created_at, canal
--         'otro', resumen = la nota) y la tabla queda vacía. No se borra.
--       * un insert que llegue igual (la UI vieja, entre correr esto y
--         publicar) se convierte en seguimiento y la fila se borra: la
--         tabla sigue vacía y el insert de la UI vieja no falla.
--   - Alerta nueva proximo_contacto_vencido: el último seguimiento del
--     cliente fijó un próximo contacto que ya pasó. Clave de dedupe por
--     seguimiento; se resuelve sola cuando se carga uno nuevo.
--   - cs_v_maestro suma al final: ultimo_seguimiento_fecha,
--     ultimo_seguimiento_avance, proximo_contacto, proximo_contacto_vencido.
--   - Digest de Discord: etiqueta legible para el tipo nuevo.
--
-- Toca objetos existentes (todo cs_*):
--   - CHECK de cs_alertas.tipo: se reemplaza por uno con el tipo nuevo.
--   - Funciones reescritas:
--       cs_tg_chequeos_after  (001)  ahora convierte en seguimiento
--       cs_generar_alertas    (037)  + proximo_contacto_vencido
--       cs_digest_diario      (036)  + etiqueta del tipo nuevo
--   - Vista cs_v_maestro (037): columnas nuevas al final.
--   - Publicación supabase_realtime: + cs_seguimientos.
-- Nada crm_* / fin_* / ventas.
-- Es re-ejecutable (if not exists / create or replace / on conflict).
--
-- Estructura:
--   0. Foto de ANTES (chequeos, último chequeo, sin_chequeo, semáforo)
--   1. Tabla cs_seguimientos
--   2. Triggers de cs_seguimientos
--   3. cs_chequeos obsoleta: migración de datos y redirección
--   4. RLS, permisos y realtime
--   5. Alertas: CHECK de tipo, cs_generar_alertas, cs_digest_diario
--   6. Vista cs_v_maestro
--   7. PRUEBA DE HUMO (crea datos, los verifica y los deshace)
--   8. QUERY DE CONTROL
-- =====================================================================


-- =====================================================================
-- 0. FOTO DE ANTES (fuera de la transacción, en tablas temporales)
-- =====================================================================
-- Se comparan en la query de control. Si la migración se corre dos
-- veces, la foto es la del estado ya migrado y la comparación sigue
-- valiendo (cs_chequeos ya está vacía).
drop table if exists pg_temp.cs_038_antes_chq;
create temp table cs_038_antes_chq as
  select id, cliente_id, nota, created_at from public.cs_chequeos;

drop table if exists pg_temp.cs_038_antes_cli;
create temp table cs_038_antes_cli as
  select id, ultimo_chequeo_at, dias_sin_chequeo, semaforo from public.cs_v_clientes;

drop table if exists pg_temp.cs_038_antes_kpi;
create temp table cs_038_antes_kpi as
  select programa_id, sin_chequeo from public.cs_v_kpis_programa;

begin;

-- =====================================================================
-- 1. TABLA cs_seguimientos
-- =====================================================================
create table if not exists public.cs_seguimientos (
  id                uuid primary key default gen_random_uuid(),
  programa_id       text not null references public.cs_programas(id),
  cliente_id        uuid not null,
  fecha             date not null default public.cs_hoy(),
  canal             text not null check (canal in ('whatsapp','mail','call','reunion','otro')),
  resumen           text not null check (btrim(resumen) <> '' and char_length(resumen) <= 2000),
  etapa             text,
  avance            text check (avance in ('bien','demorado','trabado')),
  proximo_contacto  date,
  usuario           uuid default auth.uid(),
  created_at        timestamptz not null default now(),
  constraint cs_seguimientos_proximo_chk check (proximo_contacto is null or proximo_contacto >= fecha),
  constraint cs_seguimientos_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
-- "el último seguimiento" = fecha desc, created_at desc (vista, alerta y UI)
create index if not exists cs_seguimientos_cliente_fecha_idx
  on public.cs_seguimientos (cliente_id, fecha desc, created_at desc);
create index if not exists cs_seguimientos_programa_idx on public.cs_seguimientos (programa_id);

comment on table public.cs_seguimientos is
  'Contactos del CSM con el cliente (038). Reemplaza a cs_chequeos. Al insertar mueve '
  'cs_clientes.ultimo_chequeo_at, la etapa si viene, y registra el avance en cs_historial.';


-- =====================================================================
-- 2. TRIGGERS DE cs_seguimientos
-- =====================================================================

-- ---------- reglas antes de guardar ----------
-- La etapa tiene que ser una de las del programa. La fecha no puede ser
-- futura (el seguimiento es algo que ya pasó; lo que viene va en
-- proximo_contacto). En UPDATE solo se valida lo que cambió, para no
-- trabar la edición de un seguimiento viejo cuya etapa ya no existe.
create or replace function public.cs_tg_seguimientos_before()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.etapa is not null
     and (tg_op = 'INSERT' or new.etapa is distinct from old.etapa)
     and not exists (
       select 1
       from public.cs_programas p, jsonb_array_elements_text(p.etapas) e(etapa)
       where p.id = new.programa_id and e.etapa = new.etapa
     ) then
    raise exception 'La etapa "%" no existe en el programa %', new.etapa, new.programa_id
      using errcode = 'check_violation';
  end if;

  if new.fecha > public.cs_hoy()
     and (tg_op = 'INSERT' or new.fecha is distinct from old.fecha) then
    raise exception 'La fecha del seguimiento no puede ser futura (%)', new.fecha
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- ---------- efecto sobre el cliente ----------
-- ultimo_chequeo_at: misma regla que cs_tg_chequeos_after de 001, el
-- mayor created_at. Solo actualiza si lo mueve, para no tocar updated_at
-- de cs_clientes al migrar chequeos viejos.
create or replace function public.cs_tg_seguimientos_after()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_anterior text;
begin
  update public.cs_clientes
     set ultimo_chequeo_at = new.created_at
   where id = new.cliente_id
     and (ultimo_chequeo_at is null or ultimo_chequeo_at < new.created_at);

  if new.etapa is not null then
    update public.cs_clientes
       set etapa = new.etapa
     where id = new.cliente_id
       and etapa is distinct from new.etapa;
  end if;

  if new.avance is not null then
    select s.avance into v_anterior
    from public.cs_seguimientos s
    where s.cliente_id = new.cliente_id and s.id <> new.id and s.avance is not null
    order by s.fecha desc, s.created_at desc
    limit 1;

    insert into public.cs_historial (tabla, registro_id, programa_id, campo, valor_anterior, valor_nuevo, usuario)
    values ('cs_clientes', new.cliente_id, new.programa_id, 'avance', v_anterior, new.avance, new.usuario);
  end if;
  return null;
end;
$$;

-- programa_id sale del cliente (misma función que el resto de las hijas)
create or replace trigger cs_trg_10_programa before insert or update of cliente_id, programa_id on public.cs_seguimientos
  for each row execute function public.cs_tg_programa_desde_cliente();
create or replace trigger cs_trg_20_reglas before insert or update on public.cs_seguimientos
  for each row execute function public.cs_tg_seguimientos_before();
create or replace trigger cs_trg_after_insert after insert on public.cs_seguimientos
  for each row execute function public.cs_tg_seguimientos_after();


-- =====================================================================
-- 3. cs_chequeos OBSOLETA
-- =====================================================================

-- ---------- migración de las filas existentes ----------
-- Función (y no un insert suelto) para que la prueba de humo pueda
-- correr exactamente lo mismo. Conserva id, usuario y created_at: el
-- trigger de seguimientos no mueve ultimo_chequeo_at porque ya es >= a
-- cada chequeo. fecha = el día del chequeo en hora de Argentina.
create or replace function public.cs_migrar_chequeos()
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_n int;
begin
  with mov as (
    insert into public.cs_seguimientos (id, programa_id, cliente_id, fecha, canal, resumen, usuario, created_at)
    select ch.id,
           ch.programa_id,
           ch.cliente_id,
           (ch.created_at at time zone 'America/Argentina/Buenos_Aires')::date,
           'otro',
           left(coalesce(nullif(btrim(ch.nota), ''), 'Chequeo registrado (sin nota)'), 2000),
           ch.usuario,
           ch.created_at
    from public.cs_chequeos ch
    order by ch.created_at
    on conflict (id) do nothing
    returning 1
  )
  select count(*) into v_n from mov;

  delete from public.cs_chequeos ch
  where exists (select 1 from public.cs_seguimientos s where s.id = ch.id);

  return v_n;
end;
$fn$;

do $$ begin raise notice 'chequeos migrados a cs_seguimientos: %', public.cs_migrar_chequeos(); end $$;

-- ---------- lo que llegue después se convierte en seguimiento ----------
-- Reemplaza la función de 001 (el trigger cs_trg_after_insert de
-- cs_chequeos ya la llama). El insert de la UI vieja devuelve su fila
-- como siempre; acá se copia a cs_seguimientos y se borra.
create or replace function public.cs_tg_chequeos_after()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.cs_seguimientos (id, programa_id, cliente_id, fecha, canal, resumen, usuario, created_at)
  values (new.id, new.programa_id, new.cliente_id,
          (new.created_at at time zone 'America/Argentina/Buenos_Aires')::date,
          'otro',
          left(coalesce(nullif(btrim(new.nota), ''), 'Chequeo registrado (sin nota)'), 2000),
          new.usuario, new.created_at)
  on conflict (id) do nothing;

  delete from public.cs_chequeos where id = new.id;
  return null;
end;
$$;

comment on table public.cs_chequeos is
  'OBSOLETA desde 038: reemplazada por cs_seguimientos. Queda vacía; un insert se convierte '
  'en seguimiento (canal otro) y la fila se borra. Borrar la tabla en una migración futura.';


-- =====================================================================
-- 4. RLS, PERMISOS Y REALTIME
-- =====================================================================
-- Mismo patrón que las hijas de 001: ver, cargar y editar con
-- cs_puede_ver; borrar solo fundador.
alter table public.cs_seguimientos enable row level security;
revoke all on table public.cs_seguimientos from anon;
revoke truncate, references, trigger on table public.cs_seguimientos from authenticated;
grant select, insert, update, delete on table public.cs_seguimientos to authenticated;

drop policy if exists cs_select on public.cs_seguimientos;
create policy cs_select on public.cs_seguimientos for select to authenticated
  using (public.cs_puede_ver(programa_id));

drop policy if exists cs_insert on public.cs_seguimientos;
create policy cs_insert on public.cs_seguimientos for insert to authenticated
  with check (public.cs_puede_ver(programa_id));

drop policy if exists cs_update on public.cs_seguimientos;
create policy cs_update on public.cs_seguimientos for update to authenticated
  using (public.cs_puede_ver(programa_id))
  with check (public.cs_puede_ver(programa_id));

drop policy if exists cs_delete on public.cs_seguimientos;
create policy cs_delete on public.cs_seguimientos for delete to authenticated
  using (public.cs_puede_borrar());

-- Funciones de trigger y la migración: nadie las llama a mano.
revoke all on function public.cs_tg_seguimientos_before() from public, anon, authenticated;
revoke all on function public.cs_tg_seguimientos_after() from public, anon, authenticated;
revoke all on function public.cs_migrar_chequeos() from public, anon, authenticated;

-- Realtime: la ficha y la revisión se refrescan con los seguimientos.
do $$
declare
  v_all boolean;
begin
  select puballtables into v_all from pg_publication where pubname = 'supabase_realtime';
  if v_all is null then
    raise notice 'No existe la publicación supabase_realtime: cs_seguimientos queda sin realtime.';
  elsif v_all then
    raise notice 'supabase_realtime es FOR ALL TABLES: cs_seguimientos ya está incluida.';
  elsif not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'cs_seguimientos'
  ) then
    alter publication supabase_realtime add table public.cs_seguimientos;
  end if;
end $$;


-- =====================================================================
-- 5. ALERTAS
-- =====================================================================

-- ---------- CHECK de cs_alertas.tipo ----------
-- Se busca por definición (el de 001 es anónimo) y se reemplaza.
do $$
declare
  r record;
begin
  for r in
    select c.conname from pg_constraint c
    where c.conrelid = 'public.cs_alertas'::regclass and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ~ 'sin_chequeo'
  loop
    execute format('alter table public.cs_alertas drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.cs_alertas add constraint cs_alertas_tipo_check
  check (tipo in ('renovacion_proxima','devolucion_vencida','onboarding_demorado',
                  'accionable_bpf_vencido','sin_chequeo','satisfaccion_baja',
                  'programa_vencido','proximo_contacto_vencido'));

-- ---------- cs_generar_alertas ----------
-- Igual que 037. Único cambio: proximo_contacto_vencido (CTE ult_seg,
-- una rama más en vigentes y el tipo en la lista de las que se resuelven
-- solas). "Último seguimiento" = fecha desc, created_at desc: si después
-- del vencido se cargó otro, ese pasa a ser el último y la alerta se va.
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
             -- si hay una abierta manda esa; si no, la más reciente (igual que cs_v_clientes)
             order by public.cs_ren_abierta(r.estado) desc, r.iniciada_at desc
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
  ult_seg as (
    select b.cliente_id, s.id as seguimiento_id, s.proximo_contacto
    from base b
    cross join lateral (
      select x.id, x.proximo_contacto
      from public.cs_seguimientos x
      where x.cliente_id = b.cliente_id
      order by x.fecha desc, x.created_at desc
      limit 1
    ) s
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
      and not public.cs_ren_abierta(r.renovacion_estado)
      and coalesce(r.renovacion_estado, '') <> 'no_renovado'

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

    union all
    -- proximo_contacto_vencido: una por seguimiento cuyo próximo contacto
    -- pasó sin que se cargara otro seguimiento después
    select b.programa_id,
           b.cliente_id,
           'proximo_contacto_vencido',
           format('Próximo contacto vencido hace %s día(s) (era el %s)',
                  public.cs_hoy() - s.proximo_contacto, to_char(s.proximo_contacto, 'DD/MM/YYYY')),
           'proximo_contacto_vencido:' || s.seguimiento_id
    from base b
    join ult_seg s on s.cliente_id = b.cliente_id
    where s.proximo_contacto < public.cs_hoy()
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
                      'accionable_bpf_vencido', 'sin_chequeo', 'programa_vencido',
                      'proximo_contacto_vencido')
       and not exists (select 1 from vigentes v where v.clave_dedupe = a.clave_dedupe)
    returning 1
  )
  select (select count(*) from creadas), (select count(*) from resueltas)
    into v_creadas, v_resueltas;

  return jsonb_build_object('creadas', v_creadas, 'resueltas', v_resueltas);
end;
$fn$;

-- ---------- cs_digest_diario ----------
-- Igual que 036. Único cambio: la etiqueta de proximo_contacto_vencido
-- (antes salía el nombre crudo del tipo por el "else x.tipo").
create or replace function public.cs_digest_diario(p_enviar boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r        record;
  k        record;
  v_ids    uuid[];
  v_conteo text;
  v_total  int;
  v_txt    text;
  v_id     bigint;
  v_envios jsonb := '[]'::jsonb;
  v_marcadas int := 0;
begin
  for r in
    select p.id, p.nombre, p.aviso_renovacion_dias
    from public.cs_programas p
    join public.cs_integraciones i on i.programa_id = p.id
    where p.activo and i.discord_activo and i.discord_webhook_url is not null
    order by p.id
  loop
    select * into k from public.cs_v_kpis_programa v where v.programa_id = r.id;

    select coalesce(array_agg(a.id), '{}'), count(*)
      into v_ids, v_total
    from public.cs_alertas a
    where a.programa_id = r.id
      and not a.resuelta
      and a.notificada_discord_at is null;

    -- "3 devoluciones fuera de SLA, 2 onboarding demorados": de más a menos.
    select string_agg(
             x.n || ' ' || case x.tipo
               when 'renovacion_proxima'     then 'por vencer sin renovación iniciada'
               when 'programa_vencido'       then case when x.n = 1 then 'programa vencido sin cerrar' else 'programas vencidos sin cerrar' end
               when 'devolucion_vencida'     then case when x.n = 1 then 'devolución fuera de SLA' else 'devoluciones fuera de SLA' end
               when 'onboarding_demorado'    then case when x.n = 1 then 'onboarding demorado' else 'onboarding demorados' end
               when 'accionable_bpf_vencido' then case when x.n = 1 then 'accionable BPF vencido' else 'accionables BPF vencidos' end
               when 'sin_chequeo'            then 'sin chequeo'
               when 'satisfaccion_baja'      then case when x.n = 1 then 'satisfacción baja' else 'satisfacciones bajas' end
               when 'proximo_contacto_vencido' then case when x.n = 1 then 'próximo contacto vencido' else 'próximos contactos vencidos' end
               else x.tipo
             end, ', ' order by x.n desc, x.tipo)
      into v_conteo
    from (
      select a.tipo, count(*) as n
      from public.cs_alertas a
      where a.id = any (v_ids)
      group by a.tipo
    ) x;

    v_txt := concat_ws(E'\n',
      format('**Producto · %s** — %s', r.nombre, to_char(public.cs_hoy(), 'DD/MM/YYYY')),
      format('Activos: %s | Rojo: %s | Amarillo: %s',
             coalesce(k.clientes_activos, 0), coalesce(k.clientes_rojo, 0), coalesce(k.clientes_amarillo, 0)),
      format('Devoluciones pendientes: %s (%s%%) | Vencidas SLA: %s',
             coalesce(k.dev_pendientes, 0), coalesce(k.pct_dev_pendientes, 0), coalesce(k.dev_vencidas_sla, 0)),
      format('Onboarding pendientes: %s', coalesce(k.onboarding_pendientes, 0)),
      format('Por vencer (%sd): %s | Renovaciones en proceso: %s',
             r.aviso_renovacion_dias, coalesce(k.por_vencer, 0), coalesce(k.en_renovacion, 0)),
      'Nuevas alertas: ' || coalesce(v_conteo, 'ninguna'));

    v_id := public.cs_discord_post(r.id, 'digest', v_txt, p_enviar);

    if v_id is not null and v_total > 0 then
      update public.cs_alertas set notificada_discord_at = now() where id = any (v_ids);
      v_marcadas := v_marcadas + v_total;
    end if;

    v_envios := v_envios || jsonb_build_object('programa_id', r.id, 'envio_id', v_id, 'alertas', v_total);
  end loop;

  return jsonb_build_object('programas', jsonb_array_length(v_envios),
                            'alertas_notificadas', v_marcadas,
                            'envios', v_envios,
                            'corrido_at', now());
end;
$fn$;


-- =====================================================================
-- 6. VISTA cs_v_maestro
-- =====================================================================
-- Igual que 037, con 4 columnas nuevas AL FINAL (create or replace view
-- no deja insertarlas en el medio). Último seguimiento = fecha desc,
-- created_at desc, el mismo criterio que la alerta.
-- proximo_contacto_vencido solo para clientes vivos: un finalizado o de
-- baja no tiene a quién llamar (y tampoco genera la alerta).
create or replace view public.cs_v_maestro
with (security_invoker = on) as
select
  -- identidad
  v.id,
  v.programa_id,
  v.nombre,
  v.email,
  v.telefono,
  v.plan,
  -- editables por el CSM
  v.responsable,
  c.prioridad,
  c.proxima_accion,
  c.proxima_accion_fecha,
  c.nota_csm,
  v.etapa,
  v.estado,
  v.fecha_inicio,
  v.fecha_fin,
  -- calculados (cs_v_clientes)
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
  -- renovación vigente
  r.id               as renovacion_id,
  r.estado           as renovacion_estado,
  r.resell_producto  as renovacion_producto,
  r.iniciada_at      as renovacion_iniciada_at,
  r.resultado_at     as renovacion_resultado_at,
  r.nueva_fecha_fin  as renovacion_nueva_fecha_fin,
  r.motivo           as renovacion_motivo,
  v.updated_at,
  -- último seguimiento (038)
  s.fecha            as ultimo_seguimiento_fecha,
  s.avance           as ultimo_seguimiento_avance,
  s.proximo_contacto,
  coalesce(s.proximo_contacto < public.cs_hoy()
           and v.estado not in ('finalizado', 'baja'), false) as proximo_contacto_vencido
from public.cs_v_clientes v
join public.cs_clientes c on c.id = v.id
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

-- create or replace conserva los permisos de 037; se repiten por las dudas.
revoke all on table public.cs_v_maestro from anon;
revoke insert, update, delete on table public.cs_v_maestro from authenticated;
grant select on table public.cs_v_maestro to authenticated;

commit;


-- =====================================================================
-- 7. PRUEBA DE HUMO (no deja datos)
-- =====================================================================
-- Programa propio (humo038) con las etapas por defecto y
-- dias_sin_chequeo_alerta = 7. Todo lo que se inserta en la misma
-- transacción tiene el mismo created_at (now()): donde importa cuál es
-- "el último seguimiento" se usan fechas distintas o clock_timestamp().
-- Al final fuerza un error para deshacer TODO, incluido lo que
-- cs_generar_alertas y cs_migrar_chequeos le hagan a datos reales, y el
-- disable trigger del paso de migración.
drop table if exists pg_temp.cs_smoke38;
create temp table cs_smoke38 (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res      text[] := '{}';
  v_x      uuid;      -- migración de chequeos, sin_chequeo, etapa, avance
  v_y      uuid;      -- próximo contacto vencido
  v_z      uuid;      -- cliente de baja con próximo contacto vencido
  v_s      uuid;
  v_ch     uuid;
  v_ts     timestamptz;
  v_ts2    timestamptz;
  v_d      int;
  v_d2     int;
  v_n      int;
  v_n2     int;
  v_txt    text;
  v_bool   boolean;
  v_state  text;
begin
  begin
    insert into public.cs_programas (id, nombre, activo) values ('humo038', '__humo038__', true);
    insert into public.cs_integraciones (programa_id, discord_webhook_url, discord_activo)
    values ('humo038', 'https://discord.com/api/webhooks/0/__humo038__', true);

    -- ---------- cliente X: chequeos viejos ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo038', '__humo038_x', public.cs_hoy() - 40, public.cs_hoy() + 50, 'activo')
    returning id into v_x;
    delete from public.cs_accionables where cliente_id = v_x;

    -- Chequeos como los dejaba la app antes de 038: se apaga la conversión
    -- para que queden en cs_chequeos, y ultimo_chequeo_at queda como lo
    -- dejaba el trigger viejo (el mayor created_at).
    alter table public.cs_chequeos disable trigger cs_trg_after_insert;
    insert into public.cs_chequeos (cliente_id, nota, created_at) values
      (v_x, 'nota vieja', now() - interval '10 days'),
      (v_x, null,         now() - interval '20 days');
    update public.cs_clientes set ultimo_chequeo_at = now() - interval '10 days' where id = v_x;
    alter table public.cs_chequeos enable trigger cs_trg_after_insert;

    select ultimo_chequeo_at, dias_sin_chequeo into v_ts, v_d from public.cs_v_clientes where id = v_x;
    select sin_chequeo into v_n from public.cs_v_kpis_programa where programa_id = 'humo038';

    -- 1. línea base: 10 días sin chequeo (> 7) cuenta en la métrica
    res := res || format('linea base: 10 dias sin chequeo -> sin_chequeo=1|%s|dias=%s kpi=%s',
                         v_d = 10 and v_n = 1, v_d, v_n);

    -- 2. la migración mueve los 2 chequeos
    v_n2 := public.cs_migrar_chequeos();
    res := res || format('cs_migrar_chequeos migra los chequeos viejos|%s|migrados=%s', v_n2 = 2, v_n2);

    -- 3. canal otro, resumen = nota (o texto fijo si no había), fecha = día del chequeo
    select count(*) filter (where s.canal = 'otro'),
           string_agg(s.resumen, ' / ' order by s.created_at desc),
           bool_and(s.fecha = (s.created_at at time zone 'America/Argentina/Buenos_Aires')::date)
      into v_n, v_txt, v_bool
    from public.cs_seguimientos s where s.cliente_id = v_x;
    res := res || format('migrados: canal otro, resumen de la nota, fecha del chequeo|%s|%s',
                         v_n = 2 and v_txt = 'nota vieja / Chequeo registrado (sin nota)' and v_bool,
                         replace(coalesce(v_txt, 'null'), '|', '/'));

    -- 4. cs_chequeos queda vacía
    select count(*) into v_n from public.cs_chequeos where cliente_id = v_x;
    res := res || format('cs_chequeos queda vacia|%s|filas=%s', v_n = 0, v_n);

    -- 5. la métrica "sin chequeo" da lo mismo que antes de migrar
    select ultimo_chequeo_at, dias_sin_chequeo into v_ts2, v_d2 from public.cs_v_clientes where id = v_x;
    select sin_chequeo into v_n from public.cs_v_kpis_programa where programa_id = 'humo038';
    res := res || format('migrar no cambia ultimo chequeo ni sin_chequeo|%s|dias %s -> %s, kpi=%s',
                         v_ts2 = v_ts and v_d2 = v_d and v_n = 1, v_d, v_d2, v_n);

    -- 6. correrla de nuevo no duplica
    v_n2 := public.cs_migrar_chequeos();
    select count(*) into v_n from public.cs_seguimientos where cliente_id = v_x;
    res := res || format('migrar dos veces no duplica|%s|migrados=%s seguimientos=%s', v_n2 = 0 and v_n = 2, v_n2, v_n);

    -- 7. un insert en cs_chequeos (UI vieja) devuelve su fila, pasa a seguimiento y no queda
    insert into public.cs_chequeos (cliente_id, nota) values (v_x, 'desde la UI vieja') returning id into v_ch;
    select count(*) into v_n from public.cs_chequeos where id = v_ch;
    select count(*) into v_n2 from public.cs_seguimientos
    where id = v_ch and canal = 'otro' and resumen = 'desde la UI vieja';
    res := res || format('insert en cs_chequeos -> seguimiento, tabla vacia|%s|id=%s chequeos=%s seguimientos=%s',
                         v_ch is not null and v_n = 0 and v_n2 = 1, v_ch is not null, v_n, v_n2);

    -- 8. ...y mueve ultimo_chequeo_at como antes: sin_chequeo 1 -> 0
    select ultimo_chequeo_at, dias_sin_chequeo into v_ts2, v_d2 from public.cs_v_clientes where id = v_x;
    select sin_chequeo into v_n from public.cs_v_kpis_programa where programa_id = 'humo038';
    res := res || format('seguimiento de hoy: ultimo chequeo = created_at, sin_chequeo 0|%s|dias=%s kpi=%s',
                         v_ts2 = now() and v_d2 = 0 and v_n = 0, v_d2, v_n);

    -- 9. un seguimiento cargado con created_at viejo no lo mueve para atrás
    insert into public.cs_seguimientos (cliente_id, canal, resumen, fecha, created_at)
    values (v_x, 'mail', 'cargado tarde', public.cs_hoy() - 30, now() - interval '30 days');
    select ultimo_chequeo_at into v_ts2 from public.cs_clientes where id = v_x;
    res := res || format('created_at viejo no retrocede ultimo_chequeo_at|%s|%s', v_ts2 = now(), v_ts2);

    -- ---------- etapa ----------
    -- 10. etapa del programa -> cs_clientes.etapa
    insert into public.cs_seguimientos (cliente_id, canal, resumen, etapa)
    values (v_x, 'call', 'pasa a diagnóstico', 'Diagnóstico');
    select etapa into v_txt from public.cs_clientes where id = v_x;
    res := res || format('seguimiento con etapa actualiza cs_clientes.etapa|%s|etapa=%s',
                         v_txt = 'Diagnóstico', coalesce(v_txt, 'null'));

    -- 11. sin etapa no la toca
    insert into public.cs_seguimientos (cliente_id, canal, resumen) values (v_x, 'whatsapp', 'sin etapa');
    select etapa into v_txt from public.cs_clientes where id = v_x;
    res := res || format('seguimiento sin etapa no la cambia|%s|etapa=%s', v_txt = 'Diagnóstico', coalesce(v_txt, 'null'));

    -- 12. etapa que no es del programa se rechaza
    begin
      insert into public.cs_seguimientos (cliente_id, canal, resumen, etapa) values (v_x, 'call', 'x', 'Etapa inventada');
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('etapa fuera del programa se rechaza|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 13. fecha futura se rechaza
    begin
      insert into public.cs_seguimientos (cliente_id, canal, resumen, fecha) values (v_x, 'call', 'x', public.cs_hoy() + 1);
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('fecha futura se rechaza|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 14. próximo contacto anterior a la fecha se rechaza
    begin
      insert into public.cs_seguimientos (cliente_id, canal, resumen, fecha, proximo_contacto)
      values (v_x, 'call', 'x', public.cs_hoy() - 2, public.cs_hoy() - 3);
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    res := res || format('proximo contacto antes de la fecha se rechaza|%s|sqlstate=%s', v_state = '23514', v_state);

    -- 15. canal fuera de la lista y resumen vacío se rechazan
    begin
      insert into public.cs_seguimientos (cliente_id, canal, resumen) values (v_x, 'telegram', 'x');
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    begin
      insert into public.cs_seguimientos (cliente_id, canal, resumen) values (v_x, 'call', '   ');
      v_txt := 'sin error';
    exception when others then
      v_txt := sqlstate;
    end;
    res := res || format('canal invalido y resumen vacio se rechazan|%s|canal=%s resumen=%s',
                         v_state = '23514' and v_txt = '23514', v_state, v_txt);

    -- ---------- avance ----------
    -- 16. cada avance queda en cs_historial con el anterior
    insert into public.cs_seguimientos (cliente_id, canal, resumen, avance) values (v_x, 'call', 'viene lento', 'demorado');
    insert into public.cs_seguimientos (cliente_id, canal, resumen, avance) values (v_x, 'call', 'se trabó', 'trabado');
    select count(*), string_agg(coalesce(h.valor_anterior, 'null') || '->' || h.valor_nuevo, ' / ' order by h.id)
      into v_n, v_txt
    from public.cs_historial h
    where h.registro_id = v_x and h.tabla = 'cs_clientes' and h.campo = 'avance';
    res := res || format('avance queda en cs_historial|%s|%s',
                         v_n = 2 and v_txt = 'null->demorado / demorado->trabado', coalesce(v_txt, 'null'));

    -- 17. sin avance no escribe historial
    insert into public.cs_seguimientos (cliente_id, canal, resumen) values (v_x, 'otro', 'nada nuevo');
    select count(*) into v_n from public.cs_historial
    where registro_id = v_x and tabla = 'cs_clientes' and campo = 'avance';
    res := res || format('seguimiento sin avance no escribe historial|%s|filas=%s', v_n = 2, v_n);

    -- ---------- cliente Y: próximo contacto vencido ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo038', '__humo038_y', public.cs_hoy() - 40, public.cs_hoy() + 50, 'activo')
    returning id into v_y;
    delete from public.cs_accionables where cliente_id = v_y;

    insert into public.cs_seguimientos (cliente_id, canal, resumen, fecha, avance, proximo_contacto)
    values (v_y, 'call', 'quedamos en hablar el viernes', public.cs_hoy() - 5, 'bien', public.cs_hoy() - 2)
    returning id into v_s;

    -- 18. el maestro muestra el último seguimiento y el próximo contacto vencido
    select m.ultimo_seguimiento_fecha = public.cs_hoy() - 5
           and m.ultimo_seguimiento_avance = 'bien'
           and m.proximo_contacto = public.cs_hoy() - 2
           and m.proximo_contacto_vencido,
           m.ultimo_seguimiento_fecha || ' / ' || coalesce(m.ultimo_seguimiento_avance, 'null') || ' / '
             || coalesce(m.proximo_contacto::text, 'null') || ' / vencido=' || m.proximo_contacto_vencido
      into v_bool, v_txt
    from public.cs_v_maestro m where m.id = v_y;
    res := res || format('cs_v_maestro: ultimo seguimiento, avance, proximo contacto vencido|%s|%s',
                         coalesce(v_bool, false), coalesce(v_txt, 'null'));

    -- 19. cs_generar_alertas crea la alerta, con clave por seguimiento
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_y and tipo = 'proximo_contacto_vencido' and not resuelta
      and clave_dedupe = 'proximo_contacto_vencido:' || v_s;
    res := res || format('proximo contacto vencido -> alerta|%s|abiertas=%s', v_n = 1, v_n);

    -- 20. el digest de Discord la cuenta con etiqueta legible (sin POST: p_enviar = false)
    perform public.cs_digest_diario(false);
    select e.contenido into v_txt
    from public.cs_discord_envios e
    where e.programa_id = 'humo038' and e.tipo = 'digest'
    order by e.id desc limit 1;
    res := res || format('digest nombra el proximo contacto vencido|%s|%s',
                         coalesce(v_txt like '%Nuevas alertas: %1 próximo contacto vencido%', false),
                         replace(coalesce(split_part(v_txt, E'\n', 6), '(nada)'), '|', '/'));

    -- 21. correrla de nuevo no duplica (dedupe)
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas where cliente_id = v_y and tipo = 'proximo_contacto_vencido';
    res := res || format('generar dos veces no duplica|%s|total=%s', v_n = 1, v_n);

    -- 22. un seguimiento posterior la resuelve (y el maestro deja de marcarlo)
    insert into public.cs_seguimientos (cliente_id, canal, resumen) values (v_y, 'whatsapp', 'hablamos, todo bien');
    perform public.cs_generar_alertas();
    select count(*) filter (where not resuelta), count(*) filter (where resuelta)
      into v_n, v_n2
    from public.cs_alertas where cliente_id = v_y and tipo = 'proximo_contacto_vencido';
    select proximo_contacto_vencido into v_bool from public.cs_v_maestro where id = v_y;
    res := res || format('seguimiento posterior resuelve la alerta|%s|abiertas=%s resueltas=%s vencido=%s',
                         v_n = 0 and v_n2 = 1 and not v_bool, v_n, v_n2, v_bool);

    -- 23. próximo contacto a futuro no alerta
    insert into public.cs_seguimientos (cliente_id, canal, resumen, proximo_contacto, created_at)
    values (v_y, 'reunion', 'reunión de avance agendada', public.cs_hoy() + 3, clock_timestamp());
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas
    where cliente_id = v_y and tipo = 'proximo_contacto_vencido' and not resuelta;
    select proximo_contacto::text || ' / vencido=' || proximo_contacto_vencido into v_txt
    from public.cs_v_maestro where id = v_y;
    res := res || format('proximo contacto a futuro no alerta|%s|abiertas=%s maestro=%s',
                         v_n = 0 and v_txt = (public.cs_hoy() + 3)::text || ' / vencido=false', v_n, v_txt);

    -- 24. cliente de baja con próximo contacto vencido: ni alerta ni rojo en el maestro
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    values ('humo038', '__humo038_z', public.cs_hoy() - 40, public.cs_hoy() + 50, 'activo')
    returning id into v_z;
    insert into public.cs_seguimientos (cliente_id, canal, resumen, fecha, proximo_contacto)
    values (v_z, 'mail', 'le escribo la semana que viene', public.cs_hoy() - 9, public.cs_hoy() - 2);
    update public.cs_clientes set estado = 'baja' where id = v_z;
    perform public.cs_generar_alertas();
    select count(*) into v_n from public.cs_alertas where cliente_id = v_z and tipo = 'proximo_contacto_vencido';
    select proximo_contacto_vencido into v_bool from public.cs_v_maestro where id = v_z;
    res := res || format('cliente de baja: sin alerta ni vencido|%s|alertas=%s vencido=%s',
                         v_n = 0 and not v_bool, v_n, v_bool);

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s (%s)', replace(sqlerrm, '|', '/'), sqlstate);
    end if;
  end;

  insert into cs_smoke38 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 8. QUERY DE CONTROL (una sola tabla de resultados; mirar la columna ok)
-- =====================================================================
with
cols as (
  select column_name::text as c
  from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_seguimientos'
),
cols_m as (
  select column_name::text as c
  from information_schema.columns
  where table_schema = 'public' and table_name = 'cs_v_maestro'
),
pol as (
  select string_agg(p.policyname || ':' || p.cmd, ', ' order by p.policyname) as lista, count(*) as n
  from pg_policies p
  where p.schemaname = 'public' and p.tablename = 'cs_seguimientos'
),
trg as (
  select string_agg(t.tgname::text, ', ' order by t.tgname) as lista, count(*) as n
  from pg_trigger t
  where t.tgrelid = 'public.cs_seguimientos'::regclass and not t.tgisinternal
),
tipo_chk as (
  select string_agg(pg_get_constraintdef(c.oid), ' ; ') as def, count(*) as n
  from pg_constraint c
  where c.conrelid = 'public.cs_alertas'::regclass and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ~ 'sin_chequeo'
),
chq as (
  select count(*) as antes,
         count(s.id) as migrados,
         count(*) filter (where s.id is not null and s.canal = 'otro'
                            and s.resumen = left(coalesce(nullif(btrim(a.nota), ''), 'Chequeo registrado (sin nota)'), 2000)
                            and s.created_at = a.created_at) as iguales
  from cs_038_antes_chq a
  left join public.cs_seguimientos s on s.id = a.id
),
cli as (
  select count(*) filter (where v.id is null
                            or v.ultimo_chequeo_at is distinct from a.ultimo_chequeo_at
                            or v.dias_sin_chequeo is distinct from a.dias_sin_chequeo) as difieren_chq,
         count(*) filter (where v.id is null or v.semaforo is distinct from a.semaforo) as difieren_sem,
         count(*) as total
  from cs_038_antes_cli a
  left join public.cs_v_clientes v on v.id = a.id
),
kpi as (
  select a.programa_id, a.sin_chequeo as antes, k.sin_chequeo as despues
  from cs_038_antes_kpi a
  left join public.cs_v_kpis_programa k on k.programa_id = a.programa_id
)
select '01 tabla cs_seguimientos' as control, 'columnas' as objeto, '11' as esperado,
       (select count(*) from cols)::text as obtenido,
       (select count(*) from cols) = 11
         and (select count(*) from cols where c in ('id', 'programa_id', 'cliente_id', 'fecha', 'canal', 'resumen',
                                                    'etapa', 'avance', 'proximo_contacto', 'usuario', 'created_at')) = 11 as ok
union all
select '02 triggers de cs_seguimientos', 'programa / reglas / after insert', '3', t.n || ': ' || coalesce(t.lista, ''),
       t.n = 3
from trg t
union all
select '03 RLS cs_seguimientos', 'rls activa + 4 politicas', 'true / 4',
       (select relrowsecurity from pg_class where oid = 'public.cs_seguimientos'::regclass)::text || ' / '
         || p.n || ' (' || coalesce(p.lista, '') || ')',
       (select relrowsecurity from pg_class where oid = 'public.cs_seguimientos'::regclass) and p.n = 4
from pol p
union all
select '03 borrar solo fundador', 'politica cs_delete usa cs_puede_borrar', 'true',
       coalesce((select qual ~ 'cs_puede_borrar' from pg_policies
                 where schemaname = 'public' and tablename = 'cs_seguimientos' and policyname = 'cs_delete'), false)::text,
       coalesce((select qual ~ 'cs_puede_borrar' from pg_policies
                 where schemaname = 'public' and tablename = 'cs_seguimientos' and policyname = 'cs_delete'), false)
union all
select '04 permisos', 'anon select / authenticated insert', 'false / true',
       has_table_privilege('anon', 'public.cs_seguimientos', 'SELECT')::text || ' / '
         || has_table_privilege('authenticated', 'public.cs_seguimientos', 'INSERT')::text,
       not has_table_privilege('anon', 'public.cs_seguimientos', 'SELECT')
         and has_table_privilege('authenticated', 'public.cs_seguimientos', 'INSERT')
union all
select '04 permisos', 'cs_migrar_chequeos: authenticated no ejecuta', 'false',
       has_function_privilege('authenticated', 'public.cs_migrar_chequeos()', 'EXECUTE')::text,
       not has_function_privilege('authenticated', 'public.cs_migrar_chequeos()', 'EXECUTE')
union all
select '05 cs_chequeos obsoleta', 'filas / comentario', '0 / OBSOLETA',
       (select count(*) from public.cs_chequeos)::text || ' / '
         || coalesce(left(obj_description('public.cs_chequeos'::regclass, 'pg_class'), 20), 'sin comentario'),
       (select count(*) from public.cs_chequeos) = 0
         and coalesce(obj_description('public.cs_chequeos'::regclass, 'pg_class'), '') ~ '^OBSOLETA'
union all
select '06 chequeos migrados', 'los de la foto, con id, canal otro, nota y created_at', c.antes::text,
       c.migrados || ' migrados, ' || c.iguales || ' iguales',
       c.migrados = c.antes and c.iguales = c.antes
from chq c
union all
select '07 CHECK de cs_alertas.tipo', 'un solo check, con proximo_contacto_vencido', 'n=1',
       'n=' || t.n || ' ' || left(coalesce(t.def, ''), 120),
       t.n = 1 and t.def ~ 'proximo_contacto_vencido' and t.def ~ 'satisfaccion_baja'
from tipo_chk t
union all
select '08 cs_v_maestro columnas nuevas', 'ultimo_seguimiento_fecha, ultimo_seguimiento_avance, proximo_contacto, proximo_contacto_vencido',
       '4', (select count(*) from cols_m where c in ('ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
                                                     'proximo_contacto', 'proximo_contacto_vencido'))::text,
       (select count(*) from cols_m where c in ('ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
                                                'proximo_contacto', 'proximo_contacto_vencido')) = 4
union all
select '08 security_invoker', 'cs_v_maestro', 'security_invoker=on',
       coalesce(array_to_string(c.reloptions, ','), ''),
       coalesce(array_to_string(c.reloptions, ','), '') ~ 'security_invoker=(on|true)'
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'cs_v_maestro'
union all
select '09 ultimo chequeo igual que antes', 'clientes con ultimo_chequeo_at o dias_sin_chequeo distinto', '0',
       x.difieren_chq || ' de ' || x.total, x.difieren_chq = 0
from cli x
union all
select '09 semaforo igual que antes', 'clientes que cambiaron', '0',
       x.difieren_sem || ' de ' || x.total, x.difieren_sem = 0
from cli x
union all
select '10 metrica sin_chequeo igual que antes', k.programa_id,
       coalesce(k.antes::text, 'null'), coalesce(k.despues::text, 'null'),
       k.antes is not distinct from k.despues
from kpi k
union all
select '11 realtime', 'cs_seguimientos en supabase_realtime', 'true',
       (coalesce((select puballtables from pg_publication where pubname = 'supabase_realtime'), false)
        or exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'cs_seguimientos'))::text,
       coalesce((select puballtables from pg_publication where pubname = 'supabase_realtime'), false)
        or exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'cs_seguimientos')
union all
select '12 la prueba de humo no dejo datos', 'programa humo038 / clientes __humo038_', '0',
       ((select count(*) from public.cs_programas where id = 'humo038')
        + (select count(*) from public.cs_clientes where nombre like '\_\_humo038\_%'))::text,
       ((select count(*) from public.cs_programas where id = 'humo038')
        + (select count(*) from public.cs_clientes where nombre like '\_\_humo038\_%')) = 0
union all
select '13 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke38 s
order by 1, 2;
