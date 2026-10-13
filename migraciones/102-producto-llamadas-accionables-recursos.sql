-- =====================================================================
-- 102-producto-llamadas-accionables-recursos.sql  ·  PRODUCTO: llamadas, accionables por llamada y recursos
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), primero en el banco de pruebas.
-- Numeración global asignada por el jefe: 102.
-- Evitar :00, :15, :30 y :45 (sync de Finanzas) y las 9:00 (cron diario de Producto).
--
-- Pedido (por alumno, para el CSM):
--   1. Accionables por llamada: cada llamada (fecha + título opcional) tiene tareas,
--      con check, quién y cuándo las marcó, y un nivel de subtareas.
--   2. Semáforo de última llamada: una vista con la fecha de la última llamada por alumno.
--   3. Recursos por alumno: links compartidos (título, URL, tipo, llamada opcional).
--
-- Qué hace:
--   A. Tablas nuevas (no pisa ni mueve nada):
--        cs_llamadas              (id, programa, cliente, fecha, titulo)
--        cs_llamada_accionables   (llamada, padre opcional, texto, hecho, hecho_at, hecho_por)
--        cs_llamada_recursos      (cliente, llamada opcional, titulo, url, tipo)
--   B. RLS igual que el resto de cs_* tras la 079:
--        ver = cs_puede_ver(programa) · crear/editar = cs_puede_editar(programa)
--        borrar = cs_puede_borrar() (solo fundador).  anon no tiene nada.
--      "Quién marcó y cuándo" lo escribe un trigger desde auth.uid(): el cliente no lo puede falsear.
--   C. Vista cs_v_ultima_llamada (security_invoker): la última llamada por alumno =
--        la más reciente entre cs_llamadas, cs_calls con estado 'realizada' y
--        cs_seguimientos con canal 'call' o 'reunion'. No toca cs_v_clientes ni cs_v_maestro.
--   D. cs_maestro_claves_sistema(): suma 'ultima_llamada' (columna calculada del Maestro,
--      renombrable/ocultable como las demás). Misma lista que la 093 + una clave.
--
-- No se tocan: cs_accionables (los accionables de plantilla, vencimientos y métricas siguen igual),
-- cs_calls, cs_seguimientos, cs_clientes, el cron ni las alertas.
-- Respaldo de la definición vieja de cs_maestro_claves_sistema en cs_bak_102_funciones.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo: lo que usa esta migración tiene que existir.
do $$
declare
  v_falta text;
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception 'cs 102: hace falta Postgres 15 o más (security_invoker y ON DELETE SET NULL (col))';
  end if;
  select string_agg(r.f, ', ') into v_falta
  from (values
    ('cs_puede_ver(text)'), ('cs_puede_editar(text)'), ('cs_puede_borrar()'),
    ('cs_hoy()'), ('cs_tg_updated_at()'), ('cs_maestro_claves_sistema()')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 102: faltan funciones (corrieron la 001, 071 y 079?): %', v_falta;
  end if;
  select string_agg(t, ', ') into v_falta
  from unnest(array['cs_programas', 'cs_clientes', 'cs_calls', 'cs_seguimientos', 'crm_members']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception 'cs 102: faltan tablas: %', v_falta;
  end if;
end $$;

-- cs_clientes lleva FK desde las tablas nuevas: lock antes de crearlas (regla del deadlock).
lock table public.cs_programas, public.cs_clientes in share row exclusive mode;


-- =====================================================================
-- 1. cs_llamadas
-- =====================================================================
create table if not exists public.cs_llamadas (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id),
  cliente_id   uuid not null,
  fecha        date not null default public.cs_hoy(),
  titulo       text check (titulo is null or (btrim(titulo) <> '' and char_length(titulo) <= 120)),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  constraint cs_llamadas_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  -- permite que accionables y recursos apunten a (llamada, cliente) y no puedan cruzarse de alumno
  constraint cs_llamadas_id_cliente_uk unique (id, cliente_id)
);
create index if not exists cs_llamadas_cliente_fecha_idx
  on public.cs_llamadas (cliente_id, fecha desc, created_at desc);
create index if not exists cs_llamadas_programa_idx on public.cs_llamadas (programa_id);

comment on table public.cs_llamadas is
  'Llamadas registradas por alumno (102): fecha y título opcional. De acá cuelgan los accionables y recursos por llamada.';

drop trigger if exists cs_llamadas_updated_at on public.cs_llamadas;
create trigger cs_llamadas_updated_at before update on public.cs_llamadas
  for each row execute function public.cs_tg_updated_at();

-- La fecha no puede ser futura (una llamada que ya pasó) y no cambia de alumno.
create or replace function public.cs_tg_llamadas_before()
returns trigger language plpgsql set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' and (new.cliente_id is distinct from old.cliente_id
                           or new.programa_id is distinct from old.programa_id) then
    raise exception 'cs: una llamada no cambia de alumno' using errcode = '22023';
  end if;
  if new.fecha > public.cs_hoy() and (tg_op = 'INSERT' or new.fecha is distinct from old.fecha) then
    raise exception 'cs: la fecha de la llamada no puede ser futura (%)', new.fecha using errcode = 'check_violation';
  end if;
  return new;
end;
$fn$;
drop trigger if exists cs_llamadas_before on public.cs_llamadas;
create trigger cs_llamadas_before before insert or update on public.cs_llamadas
  for each row execute function public.cs_tg_llamadas_before();


-- =====================================================================
-- 2. cs_llamada_accionables
-- =====================================================================
create table if not exists public.cs_llamada_accionables (
  id               uuid primary key default gen_random_uuid(),
  programa_id      text not null references public.cs_programas(id),
  cliente_id       uuid not null,
  llamada_id       uuid not null,
  padre_id         uuid,
  texto            text not null check (btrim(texto) <> '' and char_length(texto) <= 500),
  orden            int not null default 0,
  hecho            boolean not null default false,
  hecho_at         timestamptz,
  hecho_por        uuid,
  hecho_por_nombre text check (hecho_por_nombre is null or char_length(hecho_por_nombre) <= 80),
  created_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now(),
  constraint cs_llamada_acc_hecho_chk check (
    (hecho and hecho_at is not null) or (not hecho and hecho_at is null and hecho_por is null)),
  constraint cs_llamada_acc_padre_distinto_chk check (padre_id is null or padre_id <> id),
  constraint cs_llamada_acc_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  constraint cs_llamada_acc_llamada_fk foreign key (llamada_id, cliente_id)
    references public.cs_llamadas (id, cliente_id) on delete cascade,
  constraint cs_llamada_acc_id_llamada_uk unique (id, llamada_id),
  -- la subtarea es de la misma llamada que su padre; borrar el padre borra sus subtareas
  constraint cs_llamada_acc_padre_fk foreign key (padre_id, llamada_id)
    references public.cs_llamada_accionables (id, llamada_id) on delete cascade
);
create index if not exists cs_llamada_acc_llamada_idx on public.cs_llamada_accionables (llamada_id, orden, created_at);
create index if not exists cs_llamada_acc_cliente_idx on public.cs_llamada_accionables (cliente_id, hecho);
create index if not exists cs_llamada_acc_programa_idx on public.cs_llamada_accionables (programa_id);

comment on table public.cs_llamada_accionables is
  'Accionables por llamada (102). Un nivel de subtareas (padre_id). hecho_at, hecho_por y hecho_por_nombre los escribe el trigger. Distinto de cs_accionables (plantilla, vencimientos, métricas).';

drop trigger if exists cs_llamada_acc_updated_at on public.cs_llamada_accionables;
create trigger cs_llamada_acc_updated_at before update on public.cs_llamada_accionables
  for each row execute function public.cs_tg_updated_at();

-- security definer: lee el nombre en crm_members/auth.users aunque el usuario no pueda.
create or replace function public.cs_tg_llamada_acc_before()
returns trigger language plpgsql security definer set search_path = public
as $fn$
declare
  v_nombre text;
begin
  if tg_op = 'UPDATE' and (new.programa_id is distinct from old.programa_id
                           or new.cliente_id is distinct from old.cliente_id
                           or new.llamada_id is distinct from old.llamada_id
                           or new.padre_id is distinct from old.padre_id) then
    raise exception 'cs: un accionable no cambia de llamada, alumno ni padre' using errcode = '22023';
  end if;

  -- un solo nivel de subtareas (padre_id no cambia en UPDATE, así que alcanza con mirar al insertar)
  if new.padre_id is not null and exists (
       select 1 from public.cs_llamada_accionables p where p.id = new.padre_id and p.padre_id is not null) then
    raise exception 'cs: las subtareas tienen un solo nivel' using errcode = '22023';
  end if;

  -- quién y cuándo lo marcó: lo pone la base, siempre
  if new.hecho then
    if tg_op = 'INSERT' or not old.hecho then
      new.hecho_at := now();
      new.hecho_por := auth.uid();
      select left(coalesce(nullif(btrim(m.nombre), ''), u.email), 80) into v_nombre
      from auth.users u
      left join public.crm_members m on m.user_id = u.id
      where u.id = auth.uid();
      new.hecho_por_nombre := v_nombre;
    else
      new.hecho_at := old.hecho_at;
      new.hecho_por := old.hecho_por;
      new.hecho_por_nombre := old.hecho_por_nombre;
    end if;
  else
    new.hecho_at := null;
    new.hecho_por := null;
    new.hecho_por_nombre := null;
  end if;
  return new;
end;
$fn$;

drop trigger if exists cs_llamada_acc_before on public.cs_llamada_accionables;
create trigger cs_llamada_acc_before before insert or update on public.cs_llamada_accionables
  for each row execute function public.cs_tg_llamada_acc_before();


-- =====================================================================
-- 3. cs_llamada_recursos
-- =====================================================================
create table if not exists public.cs_llamada_recursos (
  id           uuid primary key default gen_random_uuid(),
  programa_id  text not null references public.cs_programas(id),
  cliente_id   uuid not null,
  llamada_id   uuid,
  titulo       text not null check (btrim(titulo) <> '' and char_length(titulo) <= 200),
  url          text not null check (url ~* '^https?://[^[:space:]]+$' and char_length(url) <= 1000),
  tipo         text not null default 'otro'
               check (tipo in ('doc', 'sheet', 'slides', 'drive', 'youtube', 'loom', 'otro')),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  constraint cs_llamada_rec_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade,
  -- si se borra la llamada, el recurso queda del alumno sin llamada (no se pierde el link)
  constraint cs_llamada_rec_llamada_fk foreign key (llamada_id, cliente_id)
    references public.cs_llamadas (id, cliente_id) on delete set null (llamada_id)
);
create index if not exists cs_llamada_rec_cliente_idx on public.cs_llamada_recursos (cliente_id, created_at desc);
create index if not exists cs_llamada_rec_llamada_idx on public.cs_llamada_recursos (llamada_id);
create index if not exists cs_llamada_rec_programa_idx on public.cs_llamada_recursos (programa_id);

comment on table public.cs_llamada_recursos is
  'Links compartidos con el alumno (102). tipo lo detecta la app por el dominio; llamada_id es opcional. Solo http(s).';

drop trigger if exists cs_llamada_rec_updated_at on public.cs_llamada_recursos;
create trigger cs_llamada_rec_updated_at before update on public.cs_llamada_recursos
  for each row execute function public.cs_tg_updated_at();

create or replace function public.cs_tg_llamada_rec_before()
returns trigger language plpgsql set search_path = public
as $fn$
begin
  if tg_op = 'UPDATE' and (new.programa_id is distinct from old.programa_id
                           or new.cliente_id is distinct from old.cliente_id) then
    raise exception 'cs: un recurso no cambia de alumno' using errcode = '22023';
  end if;
  return new;
end;
$fn$;
drop trigger if exists cs_llamada_rec_before on public.cs_llamada_recursos;
create trigger cs_llamada_rec_before before insert or update on public.cs_llamada_recursos
  for each row execute function public.cs_tg_llamada_rec_before();


-- =====================================================================
-- 4. RLS
-- =====================================================================
do $$
declare
  t text;
begin
  foreach t in array array['cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('grant select, insert, update, delete on table public.%I to authenticated', t);

    execute format('drop policy if exists cs_select on public.%I', t);
    execute format('create policy cs_select on public.%I for select to authenticated
                      using (public.cs_puede_ver(programa_id))', t);

    execute format('drop policy if exists cs_insert on public.%I', t);
    execute format('create policy cs_insert on public.%I for insert to authenticated
                      with check (public.cs_puede_editar(programa_id))', t);

    execute format('drop policy if exists cs_update on public.%I', t);
    execute format('create policy cs_update on public.%I for update to authenticated
                      using (public.cs_puede_editar(programa_id))
                      with check (public.cs_puede_editar(programa_id))', t);

    -- borrar: solo fundador (cs_puede_borrar = es_fundador), igual que cs_accionables
    execute format('drop policy if exists cs_delete on public.%I', t);
    execute format('create policy cs_delete on public.%I for delete to authenticated
                      using (public.cs_puede_borrar())', t);
  end loop;
end $$;

revoke all on function public.cs_tg_llamadas_before() from public, anon, authenticated;
revoke all on function public.cs_tg_llamada_acc_before() from public, anon, authenticated;
revoke all on function public.cs_tg_llamada_rec_before() from public, anon, authenticated;


-- =====================================================================
-- 5. cs_v_ultima_llamada
-- =====================================================================
-- Una fila por alumno que tiene alguna llamada. Los que no figuran = sin llamadas.
-- fuente = de dónde salió la fecha: 'llamada' (cs_llamadas) | 'call' (cs_calls realizada)
--          | 'seguimiento' (canal call o reunion). Ante empate gana la primera de la lista.
-- Para cambiar qué cuenta como llamada se edita SOLO esta vista.
create or replace view public.cs_v_ultima_llamada
with (security_invoker = on) as
select x.cliente_id,
       x.programa_id,
       max(x.fecha) as ultima_llamada,
       (array_agg(x.fuente order by x.fecha desc, x.prio))[1] as fuente
from (
  select l.cliente_id, l.programa_id, l.fecha, 'llamada'::text as fuente, 1 as prio
  from public.cs_llamadas l
  union all
  select c.cliente_id, c.programa_id,
         (c.fecha at time zone 'America/Argentina/Buenos_Aires')::date, 'call'::text, 2
  from public.cs_calls c
  where c.estado = 'realizada' and c.fecha is not null
  union all
  select s.cliente_id, s.programa_id, s.fecha, 'seguimiento'::text, 3
  from public.cs_seguimientos s
  where s.canal in ('call', 'reunion')
) x
group by x.cliente_id, x.programa_id;

revoke all on table public.cs_v_ultima_llamada from anon;
revoke insert, update, delete on table public.cs_v_ultima_llamada from authenticated;
grant select on table public.cs_v_ultima_llamada to authenticated;


-- =====================================================================
-- 6. MAESTRO: 'ultima_llamada' pasa a ser clave del sistema
-- =====================================================================
create table if not exists public.cs_bak_102_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_102_funciones from public, anon, authenticated;

insert into public.cs_bak_102_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.proname = 'cs_maestro_claves_sistema'
on conflict (funcion) do nothing;

-- Misma lista que la 093 (21 de la 071 + onb_avance) y una clave más. Las filas ya
-- guardadas en cs_maestro_columnas siguen cumpliendo el CHECK (la lista solo crece).
create or replace function public.cs_maestro_claves_sistema()
returns text[]
language sql immutable parallel safe set search_path = public
as $$
  select array[
    'nombre', 'prioridad', 'responsable', 'proxima_accion', 'proxima_accion_fecha',
    'nota_csm', 'testimonio', 'renovacion_estado', 'renovacion_producto',
    'aviso_1_at', 'aviso_2_at', 'estado', 'producto', 'etapa', 'dias_restantes',
    'acc', 'dev_pendientes', 'ultimo_seguimiento_fecha', 'ultimo_seguimiento_avance',
    'proximo_contacto', 'renovaciones_count', 'onb_avance', 'ultima_llamada'
  ]::text[]
$$;
revoke all on function public.cs_maestro_claves_sistema() from public, anon;
grant execute on function public.cs_maestro_claves_sistema() to authenticated;

commit;


-- =====================================================================
-- CONTROLES (correr de a uno, después de la migración)
-- =====================================================================
-- C1. Tablas, RLS y políticas. Esperado: 3 filas, rls = true, politicas = 4.
-- select c.relname, c.relrowsecurity as rls,
--        (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as politicas
-- from pg_class c
-- where c.relnamespace = 'public'::regnamespace
--   and c.relname in ('cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos')
-- order by 1;
--
-- C2. Nada para anon y borrar solo por cs_puede_borrar. Esperado: 0 filas en anon;
--     en cs_delete, qual = cs_puede_borrar() en las 3.
-- select table_name, privilege_type from information_schema.role_table_grants
-- where table_schema = 'public' and grantee = 'anon'
--   and table_name in ('cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos', 'cs_v_ultima_llamada');
-- select tablename, policyname, cmd, qual, with_check from pg_policies
-- where schemaname = 'public' and tablename in ('cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos')
-- order by 1, 3;
--
-- C3. La vista responde y es security_invoker. Esperado: opts = {security_invoker=on}; filas >= 0.
-- select c.reloptions as opts, (select count(*) from public.cs_v_ultima_llamada) as filas
-- from pg_class c where c.oid = 'public.cs_v_ultima_llamada'::regclass;
--
-- C4. Última llamada por fuente (informativo: de dónde sale hoy el dato de liam).
-- select fuente, count(*) as alumnos, min(ultima_llamada) as mas_vieja, max(ultima_llamada) as mas_nueva
-- from public.cs_v_ultima_llamada where programa_id = 'liam' group by 1 order by 1;
--
-- C5. La clave nueva quedó. Esperado: true, 23.
-- select 'ultima_llamada' = any (public.cs_maestro_claves_sistema()) as ok,
--        cardinality(public.cs_maestro_claves_sistema()) as claves;
--
-- C6. Datos existentes intactos (comparar con antes de correr). Esperado: mismos conteos de siempre.
-- select (select count(*) from public.cs_clientes) as clientes,
--        (select count(*) from public.cs_accionables) as accionables,
--        (select count(*) from public.cs_calls) as calls,
--        (select count(*) from public.cs_seguimientos) as seguimientos,
--        (select count(*) from public.cs_maestro_columnas) as columnas_maestro;
--
-- C7. PRUEBA DE HUMO (se revierte sola: termina en error "HUMO OK"). Necesita un fundador y
--     dos usuarios no fundadores en auth.users. Crea y borra un programa de prueba.
-- do $humo$
-- declare
--   v_prog text := 'humo102'; v_fund uuid; v_edit uuid; v_lect uuid;
--   v_cli uuid; v_ll uuid; v_acc uuid; v_sub uuid; v_n int; v_h record; v_err text; v_ok int := 0;
-- begin
--   select user_id into v_fund from public.crm_members where rol = 'fundador' limit 1;
--   select u.id into v_edit from auth.users u where u.id <> v_fund
--     and not exists (select 1 from public.crm_members m where m.user_id = u.id and m.rol = 'fundador')
--     order by u.created_at limit 1;
--   select u.id into v_lect from auth.users u where u.id not in (v_fund, v_edit)
--     and not exists (select 1 from public.crm_members m where m.user_id = u.id and m.rol = 'fundador')
--     order by u.created_at limit 1;
--   if v_fund is null or v_edit is null or v_lect is null then
--     raise exception 'faltan usuarios para probar';
--   end if;
--   perform set_config('request.jwt.claim.sub', v_fund::text, true);
--   set local role authenticated;
--   insert into public.cs_programas (id, nombre, activo) values (v_prog, '__humo102__', true);
--   reset role;
--   insert into public.cs_accesos (user_id, programa_id, nivel) values (v_edit, v_prog, 'edicion'), (v_lect, v_prog, 'lectura');
--   insert into public.cs_clientes (programa_id, nombre, estado, fecha_inicio) values (v_prog, 'Humo 102', 'activo', public.cs_hoy())
--     returning id into v_cli;
--
--   -- edicion: crea llamada, accionable y subtarea, y los marca
--   perform set_config('request.jwt.claim.sub', v_edit::text, true);
--   set local role authenticated;
--   insert into public.cs_llamadas (programa_id, cliente_id, fecha, titulo) values (v_prog, v_cli, public.cs_hoy(), 'Llamada de prueba') returning id into v_ll;
--   insert into public.cs_llamada_accionables (programa_id, cliente_id, llamada_id, texto) values (v_prog, v_cli, v_ll, 'Tarea') returning id into v_acc;
--   insert into public.cs_llamada_accionables (programa_id, cliente_id, llamada_id, padre_id, texto) values (v_prog, v_cli, v_ll, v_acc, 'Subtarea') returning id into v_sub;
--   update public.cs_llamada_accionables set hecho = true where id = v_acc;
--   select hecho_at, hecho_por into v_h from public.cs_llamada_accionables where id = v_acc;
--   if v_h.hecho_at is null or v_h.hecho_por is distinct from v_edit then raise exception 'HUMO FALLA: quien marco'; end if;
--   v_ok := v_ok + 1;
--   begin  -- subtarea de subtarea: error
--     insert into public.cs_llamada_accionables (programa_id, cliente_id, llamada_id, padre_id, texto) values (v_prog, v_cli, v_ll, v_sub, 'Nieta');
--     raise exception 'HUMO FALLA: dejo crear una nieta';
--   exception when sqlstate '22023' then v_ok := v_ok + 1; end;
--   begin  -- borrar: edicion no puede (la RLS filtra, 0 filas)
--     delete from public.cs_llamada_accionables where id = v_sub;
--     get diagnostics v_n = row_count;
--     if v_n <> 0 then raise exception 'HUMO FALLA: edicion borro un accionable'; end if;
--     v_ok := v_ok + 1;
--   end;
--   -- la vista ve la llamada de hoy
--   select count(*) into v_n from public.cs_v_ultima_llamada where cliente_id = v_cli and ultima_llamada = public.cs_hoy();
--   if v_n <> 1 then raise exception 'HUMO FALLA: la vista no ve la llamada'; end if;
--   v_ok := v_ok + 1;
--
--   -- lectura: ve y no escribe
--   reset role;
--   perform set_config('request.jwt.claim.sub', v_lect::text, true);
--   set local role authenticated;
--   select count(*) into v_n from public.cs_llamadas where cliente_id = v_cli;
--   if v_n <> 1 then raise exception 'HUMO FALLA: lectura no ve'; end if;
--   begin
--     insert into public.cs_llamadas (programa_id, cliente_id, fecha) values (v_prog, v_cli, public.cs_hoy());
--     raise exception 'HUMO FALLA: lectura pudo crear';
--   exception when insufficient_privilege then v_ok := v_ok + 1; end;
--
--   -- fundador: borra la llamada y se van los accionables en cascada
--   reset role;
--   perform set_config('request.jwt.claim.sub', v_fund::text, true);
--   set local role authenticated;
--   delete from public.cs_llamadas where id = v_ll;
--   reset role;
--   select count(*) into v_n from public.cs_llamada_accionables where llamada_id = v_ll;
--   if v_n <> 0 then raise exception 'HUMO FALLA: cascada'; end if;
--   v_ok := v_ok + 1;
--   raise exception 'HUMO OK: % comprobaciones (se revierte)', v_ok;
-- end
-- $humo$;
--
-- =====================================================================
-- VUELTA ATRÁS (solo si hace falta; borra los datos cargados en las 3 tablas nuevas)
-- =====================================================================
-- begin;
-- drop view if exists public.cs_v_ultima_llamada;
-- drop table if exists public.cs_llamada_recursos;
-- drop table if exists public.cs_llamada_accionables;
-- drop table if exists public.cs_llamadas;
-- drop function if exists public.cs_tg_llamada_rec_before();
-- drop function if exists public.cs_tg_llamada_acc_before();
-- drop function if exists public.cs_tg_llamadas_before();
-- -- La clave 'ultima_llamada' no se puede sacar de la lista si algún programa ya guardó config de esa columna:
-- -- primero  delete from public.cs_maestro_columnas where clave = 'ultima_llamada' and sistema;
-- do $$ declare d text; begin
--   select definicion into d from public.cs_bak_102_funciones where funcion like 'cs_maestro_claves_sistema%';
--   if d is not null then execute d; end if;
-- end $$;
-- commit;
-- (La tabla cs_bak_102_funciones se puede borrar a mano cuando ya no haga falta.)
