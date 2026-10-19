-- =====================================================================
-- 187 · Fathom: habilitar liam y agus, clases / ventas / internas con su tipo, consultores que revisan,
--        y re-clasificar sin pisar lo ya decidido
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 122, 124, 126, 127, 157 y 186 corridas. No toca fathom-sync ni las funciones de asignación manual
-- (cs_fathom_asignar, cs_fathom_marcar_no_alumno, cs_fathom_reabrir, cs_fathom_aplicar): solo las llama.
--
-- Qué hace
--   A. cs_fathom_config.programas pasa de {teo} a {teo, liam, agus}. EFECTO (leer antes de correr):
--        - fathom-sync empieza a asignar SOLO llamadas nuevas a alumnos de liam y agus (mail principal / extra, y por
--          nombre o alias, marcadas "por nombre" para confirmar), en su ventana incremental (última sync - 2 días).
--          Las ~189 pendientes viejas NO se reasignan solas: se resuelven con las propuestas de la IA.
--        - Los consultores pueden asignar sus llamadas a alumnos de liam y agus (cs_fathom_puede_asignar_llamada).
--        - ia-fathom-clasificar suma esos alumnos al pool de candidatos.
--        - Los usuarios con rol "cliente" ven y resuelven SOLO lo de su propio programa (seccion E): ver abajo.
--   B. cs_fathom_sin_asignar.clasificacion (clase_grupal | venta | interna | otra): lo que una persona decidió
--      cuando la llamada NO es de un alumno. La llamada sigue en estado 'no_alumno' (así fathom-sync y
--      "Volver a pendiente" funcionan igual que siempre) pero ahora tiene su tipo. Un trigger la limpia si la
--      llamada deja de ser 'no_alumno'. cs_v_fathom_llamadas suma la columna (al final).
--   C. Quién revisa: además del fundador y los clientes de programas habilitados, el consultor dueño de la llamada
--      (mismo criterio que "Asignar a alumno" / "No es alumno": cs_fathom_puede_gestionar y, para asignar a un
--      alumno, cs_fathom_puede_asignar_llamada). RLS de cs_fathom_propuestas y las dos funciones de la 186 se amplían.
--   D. cs_fathom_prop_guardar(jsonb) (solo service_role): la usa ia-fathom-clasificar para guardar propuestas. Inserta o
--      ACTUALIZA solo las que siguen pendientes: aceptadas, corregidas y descartadas no se tocan nunca, ni siquiera
--      si alguien las resuelve mientras la IA trabaja.
--
--   E. CADA CLIENTE VE Y RESUELVE SOLO LO DE SU PROGRAMA (en la base, no solo en el front).
--      ANTES de esta migracion (126/127) cs_fathom_ve_privadas() = fundador o cliente de CUALQUIER programa habilitado:
--      un cliente de teo ya veia las pendientes / no es alumno / internas de TODOS los consultores y programas, y
--      podia marcarlas "No es alumno" o reabrirlas. Ahora:
--        - Fundador: ve todo. Consultor: ve las suyas (como hoy). Cliente: ve una llamada pendiente / no es alumno /
--          interna solo si alguno de sus candidatos (cs_fathom_sin_asignar.candidatos, los que dejo la sync) o el alumno
--          propuesto por la IA (cs_fathom_propuestas.alumno_id) es de un programa del cliente (cs_accesos) habilitado en
--          cs_fathom_config. No hay vinculo consultor -> programa en la base: no se usa. Sin ningun alumno de su programa
--          la llamada NO la ve el cliente (solo fundador y consultor). Las llamadas ASIGNADAS ya eran por programa.
--        - Aplica a: RLS de cs_fathom_sin_asignar y de cs_fathom_propuestas (una propuesta cuyo alumno es de OTRO programa
--          tampoco), vista cs_v_fathom_llamadas, cs_fathom_alumnos(), cs_fathom_programas().
--        - Resolver: cs_fathom_prop_resolver, cs_fathom_prop_aceptar_altas, cs_fathom_marcar_no_alumno, cs_fathom_reabrir
--          y cs_fathom_asignar exigen que el usuario vea la llamada; asignar ademas exige alumno de SU programa
--          (cs_fathom_puede_asignar_llamada, sin cambios). cs_fathom_puede_gestionar(text) queda en fundador o consultor.
--        - Cambio de comportamiento: quien solo tiene edicion en un programa (rol producto, no cliente) ya no puede
--          asignar por RPC una pendiente que no ve (nunca la veia en la pantalla).
--
-- Correr en una sola ejecución, evitando los minutos :00, :15, :30 y :45 y las 9:00.
-- Orden: 1) esta migración, 2) desplegar ia-fathom-clasificar (usa cs_fathom_prop_guardar), 3) push del front.
-- =====================================================================

begin;
set local lock_timeout = '8s';

do $chk$
declare v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values ('cs_fathom_ve_privadas()'), ('cs_fathom_asignar(uuid, uuid)'), ('cs_fathom_marcar_no_alumno(uuid)'),
               ('cs_fathom_puede_gestionar(text)'), ('cs_fathom_es_consultor(text)'), ('cs_fathom_es_consultor_alguno()'),
               ('cs_fathom_prop_resolver(uuid, text, uuid, text)'), ('cs_fathom_prop_aceptar_altas(int)'),
               ('cs_fathom_reabrir(uuid)'), ('cs_fathom_programas_cfg()'), ('cs_fathom_puede_asignar_llamada(text, text)'),
               ('cs_fathom_puede_asignar(text)'), ('cs_fathom_programas()'), ('cs_fathom_alumnos()'), ('es_fundador()')) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception '187: faltan funciones (122 a 127 y 186): %', v_falta;
  end if;
  if to_regclass('public.cs_fathom_propuestas') is null then
    raise exception '187: falta la 186 (cs_fathom_propuestas)';
  end if;
  if to_regclass('public.cs_v_fathom_llamadas') is null then
    raise exception '187: falta la vista cs_v_fathom_llamadas (126/127)';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public'
                 and table_name = 'cs_fathom_sin_asignar' and column_name = 'nombres') then
    raise exception '187: falta la 127 (cs_fathom_sin_asignar.nombres)';
  end if;
  if (select count(*) from public.cs_programas where id in ('liam', 'agus')) <> 2 then
    raise exception '187: faltan los programas liam y / o agus en cs_programas';
  end if;
  if (select count(*) from public.cs_fathom_config) <> 1 then
    raise exception '187: cs_fathom_config deberia tener exactamente una fila';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public'
             and table_name = 'cs_fathom_sin_asignar' and column_name = 'clasificacion') then
    raise exception '187: ya fue corrida (existe cs_fathom_sin_asignar.clasificacion)';
  end if;
end
$chk$;

lock table public.cs_fathom_sin_asignar, public.cs_fathom_config, public.cs_fathom_propuestas in share row exclusive mode;

-- Opciones de la vista antes de tocarla (la humo comprueba que no cambian).
create temp table _v187_opciones on commit drop as
select c.reloptions from pg_class c where c.oid = 'public.cs_v_fathom_llamadas'::regclass;

-- Respaldo de lo que se reemplaza (RLS sin políticas, como el resto de los cs_bak_*).
create table public.cs_bak_187_funciones (
  funcion    text primary key,
  definicion text not null,
  created_at timestamptz not null default now()
);
alter table public.cs_bak_187_funciones enable row level security;
revoke all on table public.cs_bak_187_funciones from public, anon, authenticated;
insert into public.cs_bak_187_funciones (funcion, definicion)
select 'cs_fathom_prop_resolver(uuid,text,uuid,text)', pg_get_functiondef('public.cs_fathom_prop_resolver(uuid,text,uuid,text)'::regprocedure);
insert into public.cs_bak_187_funciones (funcion, definicion)
select 'cs_fathom_prop_aceptar_altas(int)', pg_get_functiondef('public.cs_fathom_prop_aceptar_altas(int)'::regprocedure);
insert into public.cs_bak_187_funciones (funcion, definicion)
select 'view public.cs_v_fathom_llamadas', pg_get_viewdef('public.cs_v_fathom_llamadas'::regclass, true);
insert into public.cs_bak_187_funciones (funcion, definicion)
select x.f, pg_get_functiondef(x.f::regprocedure)
from (values ('public.cs_fathom_puede_gestionar(text)'), ('public.cs_fathom_asignar(uuid,uuid)'),
             ('public.cs_fathom_marcar_no_alumno(uuid)'), ('public.cs_fathom_reabrir(uuid)'),
             ('public.cs_fathom_programas()'), ('public.cs_fathom_alumnos()')) as x(f);
insert into public.cs_bak_187_funciones (funcion, definicion)
select 'policy cs_privadas_select', coalesce((select pg_get_expr(p.polqual, p.polrelid) from pg_policy p
  where p.polrelid = 'public.cs_fathom_sin_asignar'::regclass and p.polname = 'cs_privadas_select'), '');
insert into public.cs_bak_187_funciones (funcion, definicion)
select 'policy cs_prop_select', coalesce((select pg_get_expr(p.polqual, p.polrelid) from pg_policy p
  where p.polrelid = 'public.cs_fathom_propuestas'::regclass and p.polname = 'cs_prop_select'), '');
insert into public.cs_bak_187_funciones (funcion, definicion)
select 'config.programas', array_to_string(c.programas, ',') from public.cs_fathom_config c;


-- =====================================================================
-- A. Programas habilitados: se suman liam y agus a los que ya estaban (teo)
-- =====================================================================
update public.cs_fathom_config c
set programas = c.programas || array(select p from unnest(array['liam', 'agus']) p where not (p = any (c.programas)));


-- =====================================================================
-- E1. Quien ve cada llamada sin asignar (helpers de la seccion E; van primero: la vista y las politicas los usan)
-- =====================================================================
-- Programas habilitados de los que el usuario actual es cliente (rol cliente + cs_accesos). '{}' si no es cliente.
create or replace function public.cs_fathom_programas_cliente()
returns text[]
language sql stable security definer set search_path = public
as $$
  select coalesce(array_agg(distinct a.programa_id), '{}'::text[])
  from public.crm_members m
  join public.cs_accesos a on a.user_id = m.user_id
  where m.user_id = auth.uid() and m.rol = 'cliente'
    and a.programa_id = any (public.cs_fathom_programas_cfg())
$$;
revoke all on function public.cs_fathom_programas_cliente() from public, anon, authenticated;

-- Fundador o consultor de esa llamada (los que la ven sin importar el programa).
create or replace function public.cs_fathom_es_gestor_llamada(p_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
      or exists (select 1 from public.cs_fathom_sin_asignar s
                 where s.id = p_id and public.cs_fathom_es_consultor(s.consultor))
$$;
revoke all on function public.cs_fathom_es_gestor_llamada(uuid) from public, anon, authenticated;

-- Ve (y puede resolver) la llamada sin asignar: fundador, su consultor, o un cliente a cuyo programa pertenece
-- algun candidato de la sync o el alumno propuesto por la IA. Sin vinculo seguro con un programa: el cliente no la ve.
create or replace function public.cs_fathom_ve_llamada_id(p_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.cs_fathom_es_gestor_llamada(p_id)
      or (cardinality(public.cs_fathom_programas_cliente()) > 0
          and exists (
            select 1
            from public.cs_fathom_sin_asignar s
            join public.cs_clientes c on c.programa_id = any (public.cs_fathom_programas_cliente())
            where s.id = p_id
              and (c.id = any (coalesce(s.candidatos, '{}'::uuid[]))
                   or exists (select 1 from public.cs_fathom_propuestas p
                              where p.llamada_id = s.id and p.alumno_id = c.id))))
$$;
revoke all on function public.cs_fathom_ve_llamada_id(uuid) from public, anon;
grant execute on function public.cs_fathom_ve_llamada_id(uuid) to authenticated;

-- Ve la propuesta: ve la llamada y, si es cliente, el alumno propuesto (si hay) es de su programa.
create or replace function public.cs_fathom_ve_propuesta(p_llamada uuid, p_alumno uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.cs_fathom_es_gestor_llamada(p_llamada)
      or (public.cs_fathom_ve_llamada_id(p_llamada)
          and (p_alumno is null
               or exists (select 1 from public.cs_clientes c
                          where c.id = p_alumno and c.programa_id = any (public.cs_fathom_programas_cliente()))))
$$;
revoke all on function public.cs_fathom_ve_propuesta(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_ve_propuesta(uuid, uuid) to authenticated;

-- Gestionar por consultor (126): ya no incluye al cliente, que ahora se decide por llamada (cs_fathom_ve_llamada_id).
create or replace function public.cs_fathom_puede_gestionar(p_consultor text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false) or public.cs_fathom_es_consultor(p_consultor)
$$;
revoke all on function public.cs_fathom_puede_gestionar(text) from public, anon;
grant execute on function public.cs_fathom_puede_gestionar(text) to authenticated;

-- RLS de las llamadas sin asignar: por llamada, no por rol.
drop policy if exists cs_privadas_select on public.cs_fathom_sin_asignar;
create policy cs_privadas_select on public.cs_fathom_sin_asignar for select to authenticated
  using (public.cs_fathom_ve_llamada_id(id));


-- =====================================================================
-- B. Tipo de lo que NO es un alumno
-- =====================================================================
alter table public.cs_fathom_sin_asignar add column clasificacion text;
alter table public.cs_fathom_sin_asignar add constraint cs_fathom_sin_asignar_clasif_187
  check (clasificacion is null or (clasificacion in ('clase_grupal', 'venta', 'interna', 'otra') and estado = 'no_alumno'));
comment on column public.cs_fathom_sin_asignar.clasificacion is
  '187: tipo que decidio una persona (aceptando o corrigiendo una propuesta de la IA) para una llamada que no es de un alumno: clase_grupal | venta | interna | otra. Solo con estado no_alumno; null = "No es alumno" a secas.';

create or replace function public.cs_tg_fathom_sin_asignar_clasif()
returns trigger language plpgsql set search_path = public
as $fn$
begin
  if new.estado is distinct from 'no_alumno' then
    new.clasificacion := null;   -- reabierta, asignada o reclasificada por la sync: ya no es "no es alumno"
  end if;
  return new;
end;
$fn$;
revoke all on function public.cs_tg_fathom_sin_asignar_clasif() from public, anon, authenticated;
create trigger cs_fathom_sin_asignar_clasif before insert or update on public.cs_fathom_sin_asignar
  for each row execute function public.cs_tg_fathom_sin_asignar_clasif();

-- La vista de la pantalla "Llamadas": igual que la 127, con `clasificacion` al final.
create or replace view public.cs_v_fathom_llamadas as
select l.id, 'alumno'::text as estado, l.consultor, l.fecha, l.inicio_at, l.titulo, l.tipo, l.duracion_min,
       l.grabacion_url, l.grabacion_share_url, l.resumen, l.en_que_esta, l.proximos_pasos,
       l.cliente_id, l.programa_id, c.nombre as alumno_nombre,
       l.invitados, null::text as motivo, '{}'::uuid[] as candidatos, l.asignada_por,
       null::text as clasificacion
from public.cs_llamadas l
left join public.cs_clientes c on c.id = l.cliente_id
where l.fuente = 'fathom'
  and (coalesce(public.cs_puede_ver(l.programa_id), false) or public.cs_fathom_es_consultor(l.consultor))
union all
select s.id, s.estado, s.consultor, s.fecha, s.inicio_at, s.titulo, s.tipo, s.duracion_min,
       s.grabacion_url, s.grabacion_share_url, s.resumen, s.en_que_esta, s.proximos_pasos,
       null::uuid, null::text, null::text,
       s.invitados, s.motivo, s.candidatos, null::text,
       s.clasificacion
from public.cs_fathom_sin_asignar s
where s.estado in ('pendiente', 'no_alumno', 'interna')
  and public.cs_fathom_ve_llamada_id(s.id);   -- E: fundador, su consultor o el cliente del programa de un candidato / del alumno propuesto
revoke all on public.cs_v_fathom_llamadas from public, anon;
grant select on public.cs_v_fathom_llamadas to authenticated;


-- =====================================================================
-- C. Quién ve y decide las propuestas: fundador, el consultor de la llamada y el cliente SOLO si es de su programa (E)
-- =====================================================================
drop policy if exists cs_prop_select on public.cs_fathom_propuestas;
create policy cs_prop_select on public.cs_fathom_propuestas for select to authenticated
  using (public.cs_fathom_ve_propuesta(llamada_id, alumno_id));

create or replace function public.cs_fathom_prop_resolver(
  p_prop uuid, p_accion text, p_cliente uuid default null, p_tipo text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_p       public.cs_fathom_propuestas%rowtype;
  v_est     text;
  v_cliente uuid;
  v_tipo    text;
  v_res     jsonb := '{}'::jsonb;
  v_nuevo   text;
begin
  if not (coalesce(public.cs_fathom_ve_privadas(), false) or coalesce(public.cs_fathom_es_consultor_alguno(), false)) then
    raise exception 'cs: no tenes permiso para decidir propuestas de llamadas' using errcode = '42501';
  end if;
  if p_accion not in ('aceptar', 'corregir', 'descartar') then
    raise exception 'cs: accion invalida (aceptar | corregir | descartar)' using errcode = '22023';
  end if;
  select * into v_p from public.cs_fathom_propuestas where id = p_prop for update;
  if not found then
    raise exception 'cs: la propuesta no existe' using errcode = '22023';
  end if;
  -- E: fundador, el consultor de la llamada, o un cliente SOLO si la llamada y el alumno propuesto son de su programa.
  if not public.cs_fathom_ve_propuesta(v_p.llamada_id, v_p.alumno_id) then
    raise exception 'cs: no tenes permiso para decidir esa propuesta (no es de tu programa)' using errcode = '42501';
  end if;
  if v_p.estado <> 'pendiente' then
    raise exception 'cs: la propuesta ya fue resuelta' using errcode = '22023';
  end if;
  if p_tipo is not null and p_tipo not in ('consultoria_1a1', 'clase_grupal', 'venta', 'interna', 'otra') then
    raise exception 'cs: tipo invalido' using errcode = '22023';
  end if;

  select s.estado into v_est from public.cs_fathom_sin_asignar s where s.id = v_p.llamada_id for update;
  if not found then
    raise exception 'cs: la llamada de la propuesta no existe' using errcode = '22023';
  end if;

  if p_accion = 'descartar' then
    update public.cs_fathom_propuestas
    set estado = 'descartada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = v_p.id;
    return jsonb_build_object('resultado', 'descartada');
  end if;

  if p_accion = 'aceptar' then
    v_cliente := v_p.alumno_id;
    v_tipo := v_p.tipo;
    v_nuevo := 'aceptada';
  else
    v_cliente := p_cliente;
    v_tipo := coalesce(p_tipo, v_p.tipo);
    v_nuevo := 'corregida';
  end if;
  -- Solo una consultoria 1 a 1 se asigna a un alumno; clase, venta, interna y otra quedan con su tipo.
  if v_tipo <> 'consultoria_1a1' then
    v_cliente := null;
  end if;

  if v_est not in ('pendiente', 'interna') then
    -- Alguien ya la resolvió a mano: la propuesta deja de tener sentido.
    update public.cs_fathom_propuestas
    set estado = 'descartada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = v_p.id;
    return jsonb_build_object('resultado', 'llamada_ya_resuelta');
  end if;

  if v_cliente is not null then
    -- Mismo camino que la asignación manual (valida permiso, aprende mails y alias, crea la llamada en la ficha).
    v_res := public.cs_fathom_asignar(v_p.llamada_id, v_cliente);
  elsif v_tipo = 'consultoria_1a1' then
    raise exception 'cs: una consultoria 1 a 1 necesita alumno: elegilo para corregir' using errcode = '22023';
  else
    perform public.cs_fathom_marcar_no_alumno(v_p.llamada_id);
    update public.cs_fathom_sin_asignar set clasificacion = v_tipo
    where id = v_p.llamada_id and estado = 'no_alumno';
    v_res := jsonb_build_object('resultado', 'no_alumno', 'clasificacion', v_tipo);
  end if;

  update public.cs_fathom_propuestas
  set estado = v_nuevo, tipo_final = v_tipo, alumno_final = v_cliente,
      resuelta_por = auth.uid(), resuelta_at = now()
  where id = v_p.id;
  return coalesce(v_res, '{}'::jsonb);
end;
$fn$;
revoke all on function public.cs_fathom_prop_resolver(uuid, text, uuid, text) from public, anon;
grant execute on function public.cs_fathom_prop_resolver(uuid, text, uuid, text) to authenticated;

create or replace function public.cs_fathom_prop_aceptar_altas(p_limite int default 100)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  r        record;
  v_ok     int := 0;
  v_fallo  int := 0;
  v_errs   jsonb := '[]'::jsonb;
  v_quedan int;
begin
  if not (coalesce(public.cs_fathom_ve_privadas(), false) or coalesce(public.cs_fathom_es_consultor_alguno(), false)) then
    raise exception 'cs: no tenes permiso para decidir propuestas de llamadas' using errcode = '42501';
  end if;
  for r in
    select p.id from public.cs_fathom_propuestas p
    join public.cs_fathom_sin_asignar s on s.id = p.llamada_id and s.estado in ('pendiente', 'interna')
    join public.cs_clientes c on c.id = p.alumno_id
    where p.estado = 'pendiente' and p.confianza = 'alta' and p.alumno_id is not null and p.tipo = 'consultoria_1a1'
      and public.cs_fathom_ve_propuesta(p.llamada_id, p.alumno_id)
      and public.cs_fathom_puede_asignar_llamada(c.programa_id, s.consultor)
    order by s.fecha, p.id
    limit greatest(least(coalesce(p_limite, 100), 300), 1)
  loop
    begin
      perform public.cs_fathom_prop_resolver(r.id, 'aceptar');
      v_ok := v_ok + 1;
    exception when others then
      v_fallo := v_fallo + 1;
      if jsonb_array_length(v_errs) < 10 then
        v_errs := v_errs || jsonb_build_object('propuesta', r.id, 'codigo', sqlstate, 'mensaje', left(sqlerrm, 160));
      end if;
    end;
  end loop;
  select count(*) into v_quedan
  from public.cs_fathom_propuestas p
  join public.cs_fathom_sin_asignar s on s.id = p.llamada_id and s.estado in ('pendiente', 'interna')
  join public.cs_clientes c on c.id = p.alumno_id
  where p.estado = 'pendiente' and p.confianza = 'alta' and p.alumno_id is not null and p.tipo = 'consultoria_1a1'
    and public.cs_fathom_ve_propuesta(p.llamada_id, p.alumno_id)
    and public.cs_fathom_puede_asignar_llamada(c.programa_id, s.consultor);
  return jsonb_build_object('aceptadas', v_ok, 'fallidas', v_fallo, 'errores', v_errs, 'quedan', v_quedan);
end;
$fn$;
revoke all on function public.cs_fathom_prop_aceptar_altas(int) from public, anon;
grant execute on function public.cs_fathom_prop_aceptar_altas(int) to authenticated;


-- =====================================================================
-- D. Guardar propuestas de la IA sin pisar las ya decididas (solo service_role)
-- =====================================================================
-- p = [{llamada_id, tipo, alumno_id, confianza, motivo, origen, modelo, costo_usd}, ...]
-- Inserta las nuevas y actualiza las que siguen 'pendiente'. Las aceptadas / corregidas / descartadas no se tocan.
-- Ignora las llamadas que ya no estan pendientes / internas y los alumnos que ya no existen.
create or replace function public.cs_fathom_prop_guardar(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_n   int;
  v_tot int;
begin
  if jsonb_typeof(p) is distinct from 'array' then
    raise exception 'cs: se esperaba una lista de propuestas' using errcode = '22023';
  end if;
  v_tot := jsonb_array_length(p);
  with ins as (
    insert into public.cs_fathom_propuestas as t (llamada_id, tipo, alumno_id, confianza, motivo, origen, modelo, costo_usd)
    select x.llamada_id, x.tipo,
           case when exists (select 1 from public.cs_clientes c where c.id = x.alumno_id) then x.alumno_id end,
           x.confianza, left(coalesce(x.motivo, ''), 300), coalesce(x.origen, 'ia'), x.modelo, x.costo_usd
    from jsonb_to_recordset(p) as x(llamada_id uuid, tipo text, alumno_id uuid, confianza text, motivo text,
                                    origen text, modelo text, costo_usd numeric)
    join public.cs_fathom_sin_asignar s on s.id = x.llamada_id and s.estado in ('pendiente', 'interna')
    on conflict (llamada_id) do update set
      tipo = excluded.tipo, alumno_id = excluded.alumno_id, confianza = excluded.confianza, motivo = excluded.motivo,
      origen = excluded.origen, modelo = excluded.modelo, costo_usd = excluded.costo_usd
    where t.estado = 'pendiente'
    returning 1)
  select count(*) into v_n from ins;
  return jsonb_build_object('guardadas', v_n, 'omitidas', v_tot - v_n);
end;
$fn$;
revoke all on function public.cs_fathom_prop_guardar(jsonb) from public, anon, authenticated;
grant execute on function public.cs_fathom_prop_guardar(jsonb) to service_role;


-- =====================================================================
-- E2. Acciones manuales: mismo cuerpo que la 126 / 127, con el chequeo "la llamada es de mi programa" (cs_fathom_ve_llamada_id)
-- =====================================================================
create or replace function public.cs_fathom_asignar(p_id uuid, p_cliente uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_row  public.cs_fathom_sin_asignar%rowtype;
  v_prog text;
begin
  select c.programa_id into v_prog from public.cs_clientes c where c.id = p_cliente;
  if v_prog is null then
    raise exception 'cs: el alumno no existe' using errcode = '22023';
  end if;
  select * into v_row from public.cs_fathom_sin_asignar where id = p_id for update;
  if not found then
    raise exception 'cs: la llamada no existe' using errcode = '22023';
  end if;
  -- 187: un cliente solo asigna llamadas de su programa (fundador y el consultor de la llamada, como siempre).
  if not public.cs_fathom_ve_llamada_id(p_id) then
    raise exception 'cs: esa llamada no es de tu programa' using errcode = '42501';
  end if;
  if not public.cs_fathom_puede_asignar_llamada(v_prog, v_row.consultor) then
    raise exception 'cs: no tenes permiso para asignar esa llamada a un alumno de ese programa' using errcode = '42501';
  end if;
  if v_row.estado = 'asignada' then
    raise exception 'cs: esa llamada ya fue asignada' using errcode = '22023';
  end if;
  return public.cs_fathom_aplicar(jsonb_build_object(
    'externo_id', v_row.externo_id, 'cliente_id', p_cliente, 'consultor', v_row.consultor, 'origen', 'manual',
    'inicio_at', coalesce(v_row.inicio_at, v_row.fecha::timestamptz),
    'titulo', v_row.titulo, 'tipo', v_row.tipo, 'duracion_min', v_row.duracion_min,
    'grabacion_url', v_row.grabacion_url, 'grabacion_share_url', v_row.grabacion_share_url,
    'resumen', v_row.resumen, 'en_que_esta', v_row.en_que_esta, 'proximos_pasos', v_row.proximos_pasos,
    'transcripcion', v_row.transcripcion, 'action_items', v_row.action_items,
    'invitados', v_row.invitados, 'nombres', to_jsonb(v_row.nombres)));
end;
$fn$;
revoke all on function public.cs_fathom_asignar(uuid, uuid) from public, anon;
grant execute on function public.cs_fathom_asignar(uuid, uuid) to authenticated;

create or replace function public.cs_fathom_marcar_no_alumno(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  perform 1 from public.cs_fathom_sin_asignar s where s.id = p_id and s.estado in ('pendiente', 'interna');
  if not found then
    raise exception 'cs: la llamada no existe o ya no esta pendiente' using errcode = '22023';
  end if;
  if not public.cs_fathom_ve_llamada_id(p_id) then
    raise exception 'cs: solo el fundador, el consultor de la llamada o el cliente de su programa la marcan como "no es alumno"' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'no_alumno', resuelta_at = now(), resuelta_por = auth.uid()
  where id = p_id and estado in ('pendiente', 'interna');
end;
$fn$;
revoke all on function public.cs_fathom_marcar_no_alumno(uuid) from public, anon;
grant execute on function public.cs_fathom_marcar_no_alumno(uuid) to authenticated;

create or replace function public.cs_fathom_reabrir(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  perform 1 from public.cs_fathom_sin_asignar s where s.id = p_id and s.estado = 'no_alumno';
  if not found then
    raise exception 'cs: la llamada no existe o no esta marcada como "no es alumno"' using errcode = '22023';
  end if;
  if not public.cs_fathom_ve_llamada_id(p_id) then
    raise exception 'cs: solo el fundador, el consultor de la llamada o el cliente de su programa la reabren' using errcode = '42501';
  end if;
  update public.cs_fathom_sin_asignar
  set estado = 'pendiente', resuelta_at = null, resuelta_por = null
  where id = p_id and estado = 'no_alumno';
end;
$fn$;
revoke all on function public.cs_fathom_reabrir(uuid) from public, anon;
grant execute on function public.cs_fathom_reabrir(uuid) to authenticated;

-- Programas habilitados que ve cada uno: fundador y consultor todos; cliente solo los suyos.
create or replace function public.cs_fathom_programas()
returns text[]
language sql stable security definer set search_path = public
as $$
  select case when coalesce(public.es_fundador(), false) or public.cs_fathom_es_consultor_alguno()
              then public.cs_fathom_programas_cfg()
              else public.cs_fathom_programas_cliente() end
$$;
revoke all on function public.cs_fathom_programas() from public, anon;
grant execute on function public.cs_fathom_programas() to authenticated;

-- Alumnos para asignar / corregir: fundador y consultor de todos los programas habilitados; cliente solo los de su
-- programa; edicion en un programa, solo ese (como antes). Sin mails ni telefonos.
create or replace function public.cs_fathom_alumnos()
returns table (id uuid, programa_id text, nombre text, estado text)
language sql stable security definer set search_path = public
as $$
  select c.id, c.programa_id, c.nombre, c.estado
  from public.cs_clientes c
  where c.programa_id = any (public.cs_fathom_programas_cfg())
    and (coalesce(public.es_fundador(), false) or public.cs_fathom_es_consultor_alguno()
         or c.programa_id = any (public.cs_fathom_programas_cliente())
         or coalesce(public.cs_puede_editar(c.programa_id), false))
  order by c.nombre
$$;
revoke all on function public.cs_fathom_alumnos() from public, anon;
grant execute on function public.cs_fathom_alumnos() to authenticated;


-- =====================================================================
-- Humo (se revierte solo)
-- =====================================================================
do $humo$
declare
  v_s    uuid;
  v_s2   uuid;
  v_p    uuid;
  v_tipo text;
  v_r    jsonb;
  v_n    int;
  v_est  text;
  v_cl   text;
  v_f    uuid;
  v_cons text;
  v_cu   uuid;
  v_ant  text[];
  v_des  text[];
begin
  -- A. programas
  if not (select programas @> array['teo', 'liam', 'agus'] from public.cs_fathom_config) then
    raise exception 'HUMO 187: programas no incluye teo, liam y agus';
  end if;

  select c.id into v_cons from public.cs_fathom_consultores c order by c.orden, c.id limit 1;
  insert into public.cs_fathom_sin_asignar (externo_id, fecha, titulo, consultor)
  values ('fathom:humo-187', current_date, 'humo 187', v_cons) returning id into v_s;
  insert into public.cs_fathom_sin_asignar (externo_id, fecha, titulo, consultor)
  values ('fathom:humo-187b', current_date, 'humo 187 b', v_cons) returning id into v_s2;

  -- B. clasificacion: valida, solo con no_alumno, se limpia sola
  begin
    update public.cs_fathom_sin_asignar set estado = 'no_alumno', clasificacion = 'otra_cosa' where id = v_s;
    raise exception 'HUMO 187: dejo pasar una clasificacion invalida';
  exception when check_violation then null;
  end;
  update public.cs_fathom_sin_asignar set clasificacion = 'clase_grupal' where id = v_s;   -- pendiente: el trigger la limpia
  select clasificacion into v_cl from public.cs_fathom_sin_asignar where id = v_s;
  if v_cl is not null then raise exception 'HUMO 187: una pendiente quedo con clasificacion (%)', v_cl; end if;
  update public.cs_fathom_sin_asignar set estado = 'no_alumno', clasificacion = 'clase_grupal' where id = v_s;
  select clasificacion into v_cl from public.cs_fathom_sin_asignar where id = v_s;
  if v_cl is distinct from 'clase_grupal' then raise exception 'HUMO 187: no guardo la clasificacion'; end if;
  update public.cs_fathom_sin_asignar set estado = 'pendiente' where id = v_s;
  select clasificacion into v_cl from public.cs_fathom_sin_asignar where id = v_s;
  if v_cl is not null then raise exception 'HUMO 187: al reabrir no se limpio la clasificacion'; end if;

  if not exists (select 1 from pg_attribute a where a.attrelid = 'public.cs_v_fathom_llamadas'::regclass
                 and a.attname = 'clasificacion' and not a.attisdropped) then
    raise exception 'HUMO 187: la vista no tiene la columna clasificacion';
  end if;
  select reloptions into v_ant from _v187_opciones;
  select c.reloptions into v_des from pg_class c where c.oid = 'public.cs_v_fathom_llamadas'::regclass;
  if v_ant is distinct from v_des then
    raise exception 'HUMO 187: cambiaron las opciones de la vista (antes %, ahora %)', v_ant, v_des;
  end if;

  -- D. guardar: inserta, actualiza la pendiente, no toca la resuelta
  v_r := public.cs_fathom_prop_guardar(jsonb_build_array(jsonb_build_object(
    'llamada_id', v_s, 'tipo', 'venta', 'confianza', 'baja', 'motivo', 'humo', 'origen', 'ia')));
  if (v_r ->> 'guardadas')::int <> 1 then raise exception 'HUMO 187: no inserto la propuesta (%)', v_r; end if;
  v_r := public.cs_fathom_prop_guardar(jsonb_build_array(jsonb_build_object(
    'llamada_id', v_s, 'tipo', 'clase_grupal', 'confianza', 'media', 'motivo', 'humo 2', 'origen', 'ia')));
  select count(*), max(tipo) into v_n, v_tipo from public.cs_fathom_propuestas where llamada_id = v_s;
  if v_n <> 1 or v_tipo <> 'clase_grupal' then
    raise exception 'HUMO 187: re-guardar duplico o no actualizo la pendiente (% filas, tipo %)', v_n, v_tipo;
  end if;
  select id into v_p from public.cs_fathom_propuestas where llamada_id = v_s;
  update public.cs_fathom_propuestas set estado = 'descartada', resuelta_at = now() where id = v_p;
  v_r := public.cs_fathom_prop_guardar(jsonb_build_array(jsonb_build_object(
    'llamada_id', v_s, 'tipo', 'interna', 'confianza', 'alta', 'motivo', 'no debe pisar', 'origen', 'ia')));
  select tipo into v_tipo from public.cs_fathom_propuestas where id = v_p;
  if v_tipo <> 'clase_grupal' or (v_r ->> 'guardadas')::int <> 0 then
    raise exception 'HUMO 187: piso una propuesta ya resuelta (tipo %, %)', v_tipo, v_r;
  end if;
  begin
    perform public.cs_fathom_prop_guardar('{"x": 1}'::jsonb);
    raise exception 'HUMO 187: acepto algo que no es una lista';
  exception when invalid_parameter_value then null;
  end;

  -- C. resolver como fundador (si hay uno): clase_grupal sin alumno queda no_alumno + clasificacion
  select m.user_id into v_f from public.crm_members m where m.rol = 'fundador' limit 1;
  if v_f is not null then
    perform set_config('request.jwt.claim.sub', v_f::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_f, 'role', 'authenticated')::text, true);
    insert into public.cs_fathom_propuestas (llamada_id, tipo, confianza, motivo, origen)
    values (v_s2, 'clase_grupal', 'media', 'humo', 'ia') returning id into v_p;
    v_r := public.cs_fathom_prop_resolver(v_p, 'aceptar');
    select s.estado, s.clasificacion into v_est, v_cl from public.cs_fathom_sin_asignar s where s.id = v_s2;
    if v_est <> 'no_alumno' or v_cl is distinct from 'clase_grupal' then
      raise exception 'HUMO 187: aceptar clase_grupal dejo estado %, clasificacion % (%)', v_est, v_cl, v_r;
    end if;
    select p.estado, p.tipo_final into v_est, v_tipo from public.cs_fathom_propuestas p where p.id = v_p;
    if v_est <> 'aceptada' or v_tipo <> 'clase_grupal' then
      raise exception 'HUMO 187: la propuesta aceptada quedo % / %', v_est, v_tipo;
    end if;
    begin   -- ya resuelta: no se decide dos veces
      perform public.cs_fathom_prop_resolver(v_p, 'descartar');
      raise exception 'HUMO 187: dejo decidir una propuesta ya resuelta';
    exception when invalid_parameter_value then null;
    end;
    perform public.cs_fathom_reabrir(v_s2);
    select s.estado, s.clasificacion into v_est, v_cl from public.cs_fathom_sin_asignar s where s.id = v_s2;
    if v_est <> 'pendiente' or v_cl is not null then
      raise exception 'HUMO 187: reabrir dejo estado %, clasificacion %', v_est, v_cl;
    end if;
  else
    raise notice 'HUMO 187: no hay fundador en crm_members; se omite la prueba del resolver';
  end if;

  -- C. resolver como CONSULTOR de la llamada (si hay uno con usuario): descartar su propuesta
  select u.id, c.id into v_cu, v_cons
  from public.cs_fathom_consultores c join auth.users u on lower(u.email) = c.email_login
  where c.email_login is not null limit 1;
  if v_cu is not null then
    perform set_config('request.jwt.claim.sub', v_cu::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_cu, 'role', 'authenticated')::text, true);
    update public.cs_fathom_sin_asignar set consultor = v_cons where id = v_s2;
    delete from public.cs_fathom_propuestas where llamada_id = v_s2;
    insert into public.cs_fathom_propuestas (llamada_id, tipo, confianza, motivo, origen)
    values (v_s2, 'venta', 'baja', 'humo consultor', 'ia') returning id into v_p;
    v_r := public.cs_fathom_prop_resolver(v_p, 'descartar');
    select p.estado into v_est from public.cs_fathom_propuestas p where p.id = v_p;
    if v_est <> 'descartada' then raise exception 'HUMO 187: el consultor no pudo descartar su propuesta'; end if;
  else
    raise notice 'HUMO 187: ningun consultor con usuario; se omite la prueba de consultor';
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);

  -- Permisos
  if has_function_privilege('anon', 'public.cs_fathom_prop_guardar(jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.cs_fathom_prop_guardar(jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.cs_fathom_prop_guardar(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.cs_fathom_prop_resolver(uuid,text,uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.cs_fathom_prop_aceptar_altas(int)', 'execute')
     or has_table_privilege('anon', 'public.cs_v_fathom_llamadas', 'select')
     or has_table_privilege('anon', 'public.cs_bak_187_funciones', 'select')
     or has_table_privilege('authenticated', 'public.cs_bak_187_funciones', 'select') then
    raise exception 'HUMO 187: permisos de mas o de menos';
  end if;

  delete from public.cs_fathom_propuestas where llamada_id in (v_s, v_s2);
  delete from public.cs_fathom_sin_asignar where id in (v_s, v_s2);
  raise notice 'HUMO OK: 187';
end
$humo$;

-- Humo E: cada cliente ve y resuelve SOLO lo de su programa (como usuario real de liam y de agus, con RLS: rol authenticated).
-- Usa llamadas de prueba que se borran al final; lo que se ejecuta "de verdad" (resolver / aceptar altas) va dentro de un
-- subbloque que se deshace. Si no hay un usuario cliente de liam / agus o alumnos en 2 programas, avisa y sigue (se prueba con C12 / C13).
do $humoe$
declare
  v_progs text[] := array['liam', 'agus', 'teo'];
  v_p text; v_q text;
  v_cons text; v_cons2 text; v_cons_l text;
  v_cu uuid; v_f uuid; v_uid uuid; v_id uuid; v_s uuid; v_huer uuid; v_huer2 uuid;
  v_u jsonb := '{}'::jsonb;    -- programa -> usuario cliente
  v_a jsonb := '{}'::jsonb;    -- programa -> alumno
  v_sc jsonb := '{}'::jsonb;   -- programa -> llamada con candidato de ese programa
  v_sp jsonb := '{}'::jsonb;   -- programa -> llamada sin candidatos, con propuesta (alta, 1 a 1) a un alumno de ese programa
  v_pc jsonb := '{}'::jsonb;   -- programa -> propuesta (venta, sin alumno) de v_sc
  v_pp jsonb := '{}'::jsonb;   -- programa -> propuesta de v_sp
  v_todas uuid[] := '{}'::uuid[];
  v_ids uuid[]; v_sids uuid[]; v_pids uuid[];
  v_n int; v_asig_otros int; v_alu_otros int;
  v_prog text[]; v_est text; v_clas text; v_otras_resueltas int;
  v_r jsonb;
  v_probados int := 0;
begin
  select c.id into v_cons from public.cs_fathom_consultores c order by c.orden, c.id limit 1;

  -- Fixtures: por programa un alumno real (solo se lee), un usuario cliente que no sea consultor ni de otro programa,
  -- una llamada con ese alumno como candidato y otra que solo tiene una propuesta de la IA hacia ese alumno.
  foreach v_p in array v_progs loop
    select c.id into v_id from public.cs_clientes c where c.programa_id = v_p order by c.id limit 1;
    continue when v_id is null;
    v_a := v_a || jsonb_build_object(v_p, v_id);

    select m.user_id into v_uid
    from public.crm_members m join auth.users u on u.id = m.user_id
    where m.rol = 'cliente'
      and exists (select 1 from public.cs_accesos a where a.user_id = m.user_id and a.programa_id = v_p)
      and not exists (select 1 from public.cs_accesos a where a.user_id = m.user_id and a.programa_id <> v_p)
      and not exists (select 1 from public.cs_fathom_consultores c where c.email_login = lower(u.email))
    order by (u.email ilike '%@' || v_p || '.dystopia') desc, u.email limit 1;
    if v_uid is not null then v_u := v_u || jsonb_build_object(v_p, v_uid); end if;

    insert into public.cs_fathom_sin_asignar (externo_id, fecha, titulo, consultor, candidatos)
    values ('fathom:humo-187-c-' || v_p, current_date, 'humo 187 cand ' || v_p, v_cons, array[v_id]) returning id into v_s;
    v_sc := v_sc || jsonb_build_object(v_p, v_s); v_todas := v_todas || v_s;
    insert into public.cs_fathom_propuestas (llamada_id, tipo, confianza, motivo, origen)
    values (v_s, 'venta', 'baja', 'humo 187', 'ia') returning id into v_id;
    v_pc := v_pc || jsonb_build_object(v_p, v_id);

    insert into public.cs_fathom_sin_asignar (externo_id, fecha, titulo, consultor)
    values ('fathom:humo-187-p-' || v_p, current_date, 'humo 187 prop ' || v_p, v_cons) returning id into v_s;
    v_sp := v_sp || jsonb_build_object(v_p, v_s); v_todas := v_todas || v_s;
    insert into public.cs_fathom_propuestas (llamada_id, tipo, alumno_id, confianza, motivo, origen)
    values (v_s, 'consultoria_1a1', (v_a ->> v_p)::uuid, 'alta', 'humo 187', 'ia') returning id into v_id;
    v_pp := v_pp || jsonb_build_object(v_p, v_id);
  end loop;
  -- huerfana: sin candidatos ni propuesta, de un consultor que tiene login si existe (y otra de otro consultor)
  select u.id, c.id into v_cu, v_cons_l
  from public.cs_fathom_consultores c join auth.users u on lower(u.email) = c.email_login
  where c.email_login is not null order by c.orden, c.id limit 1;
  insert into public.cs_fathom_sin_asignar (externo_id, fecha, titulo, consultor)
  values ('fathom:humo-187-h', current_date, 'humo 187 huerfana', coalesce(v_cons_l, v_cons)) returning id into v_huer;
  v_todas := v_todas || v_huer;
  select c.id into v_cons2 from public.cs_fathom_consultores c where c.id <> coalesce(v_cons_l, v_cons) order by c.orden, c.id limit 1;
  if v_cons2 is not null then
    insert into public.cs_fathom_sin_asignar (externo_id, fecha, titulo, consultor)
    values ('fathom:humo-187-h2', current_date, 'humo 187 huerfana 2', v_cons2) returning id into v_huer2;
    v_todas := v_todas || v_huer2;
  end if;

  -- Clientes de liam y de agus
  foreach v_p in array array['liam', 'agus'] loop
    if (v_u ->> v_p) is null or (v_a ->> v_p) is null then
      raise notice 'HUMO 187 E: sin usuario cliente solo de % (o sin alumnos): se omite; probar con el control C12', v_p;
      continue;
    end if;
    v_probados := v_probados + 1;
    v_uid := (v_u ->> v_p)::uuid;
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select coalesce(array_agg(v.id), '{}'::uuid[]) into v_ids from public.cs_v_fathom_llamadas v where v.estado <> 'alumno';
    select count(*) into v_asig_otros from public.cs_v_fathom_llamadas v where v.estado = 'alumno' and v.programa_id <> v_p;
    select coalesce(array_agg(s.id), '{}'::uuid[]) into v_sids from public.cs_fathom_sin_asignar s;
    select coalesce(array_agg(x.id), '{}'::uuid[]) into v_pids from public.cs_fathom_propuestas x;
    select count(*) into v_alu_otros from public.cs_fathom_alumnos() a where a.programa_id <> v_p;
    v_prog := public.cs_fathom_programas();
    reset role;

    if v_asig_otros <> 0 then raise exception 'HUMO 187 E: el cliente de % ve % llamadas asignadas de otros programas', v_p, v_asig_otros; end if;
    if v_alu_otros <> 0 then raise exception 'HUMO 187 E: el cliente de % recibe % alumnos de otros programas', v_p, v_alu_otros; end if;
    if v_prog is distinct from array[v_p] then raise exception 'HUMO 187 E: cs_fathom_programas() del cliente de % da %', v_p, v_prog; end if;
    -- pendientes (vista) y filas de la tabla: todas con un candidato o alumno propuesto de SU programa
    select count(*) into v_n from public.cs_fathom_sin_asignar s
    where (s.id = any (v_ids) or s.id = any (v_sids))
      and not exists (select 1 from public.cs_clientes c where c.programa_id = v_p
                      and (c.id = any (coalesce(s.candidatos, '{}'::uuid[]))
                           or exists (select 1 from public.cs_fathom_propuestas pr where pr.llamada_id = s.id and pr.alumno_id = c.id)));
    if v_n <> 0 then raise exception 'HUMO 187 E: el cliente de % ve % pendientes sin alumno de su programa', v_p, v_n; end if;
    -- propuestas: alumno propuesto de su programa (o ninguno) y llamada suya
    select count(*) into v_n from public.cs_fathom_propuestas x
    where x.id = any (v_pids)
      and ((x.alumno_id is not null and not exists (select 1 from public.cs_clientes c where c.id = x.alumno_id and c.programa_id = v_p))
           or not (x.llamada_id = any (v_sids)));
    if v_n <> 0 then raise exception 'HUMO 187 E: el cliente de % ve % propuestas de otros programas', v_p, v_n; end if;
    -- las llamadas de prueba: ve las de su programa, ninguna de los otros ni la huerfana
    foreach v_q in array v_progs loop
      continue when (v_a ->> v_q) is null;
      if (v_q = v_p) <> ((v_sc ->> v_q)::uuid = any (v_ids) and (v_sp ->> v_q)::uuid = any (v_ids)) then
        raise exception 'HUMO 187 E: el cliente de % % la llamada de prueba de %', v_p, case when v_q = v_p then 'no ve' else 've' end, v_q;
      end if;
      if v_q <> v_p and ((v_sc ->> v_q)::uuid = any (v_ids) or (v_sp ->> v_q)::uuid = any (v_ids)
                         or (v_pc ->> v_q)::uuid = any (v_pids) or (v_pp ->> v_q)::uuid = any (v_pids)) then
        raise exception 'HUMO 187 E: el cliente de % ve llamadas o propuestas de prueba de %', v_p, v_q;
      end if;
    end loop;
    if v_huer = any (v_ids) or v_huer2 = any (v_ids) then
      raise exception 'HUMO 187 E: el cliente de % ve una llamada sin ningun alumno de su programa', v_p;
    end if;

    -- Resolver lo de otro programa: tiene que fallar (42501) por la base, no solo por la pantalla
    set local role authenticated;
    foreach v_q in array v_progs loop
      continue when v_q = v_p or (v_a ->> v_q) is null;
      begin perform public.cs_fathom_prop_resolver((v_pc ->> v_q)::uuid, 'descartar');
        raise exception 'HUMO 187 E: el cliente de % descarto una propuesta de %', v_p, v_q;
      exception when insufficient_privilege then null; end;
      begin perform public.cs_fathom_prop_resolver((v_pc ->> v_q)::uuid, 'aceptar');
        raise exception 'HUMO 187 E: el cliente de % acepto una propuesta de %', v_p, v_q;
      exception when insufficient_privilege then null; end;
      begin perform public.cs_fathom_prop_resolver((v_pp ->> v_q)::uuid, 'aceptar');
        raise exception 'HUMO 187 E: el cliente de % acepto la propuesta con alumno de %', v_p, v_q;
      exception when insufficient_privilege then null; end;
      begin perform public.cs_fathom_marcar_no_alumno((v_sc ->> v_q)::uuid);
        raise exception 'HUMO 187 E: el cliente de % marco "no es alumno" una llamada de %', v_p, v_q;
      exception when insufficient_privilege then null; end;
      begin perform public.cs_fathom_asignar((v_sc ->> v_q)::uuid, (v_a ->> v_q)::uuid);
        raise exception 'HUMO 187 E: el cliente de % asigno una llamada de %', v_p, v_q;
      exception when insufficient_privilege then null; end;
      -- una llamada SUYA a un alumno de otro programa tampoco
      begin perform public.cs_fathom_asignar((v_sc ->> v_p)::uuid, (v_a ->> v_q)::uuid);
        raise exception 'HUMO 187 E: el cliente de % asigno su llamada a un alumno de %', v_p, v_q;
      exception when insufficient_privilege then null; end;
    end loop;
    reset role;

    -- Lo suyo si se puede resolver (subbloque que se deshace: aceptar altas puede tocar propuestas reales de su programa)
    v_est := null; v_clas := null; v_otras_resueltas := null;
    begin
      set local role authenticated;
      v_r := public.cs_fathom_prop_resolver((v_pc ->> v_p)::uuid, 'aceptar');      -- venta sin alumno: queda no_alumno + clasificacion
      v_r := public.cs_fathom_prop_aceptar_altas(1);
      reset role;
      select s.estado, s.clasificacion into v_est, v_clas from public.cs_fathom_sin_asignar s where s.id = (v_sc ->> v_p)::uuid;
      select count(*) into v_otras_resueltas from public.cs_fathom_propuestas x
      where x.estado <> 'pendiente'
        and x.id in (select (v_pp ->> k)::uuid from unnest(v_progs) k where k <> v_p and (v_pp ->> k) is not null);
      raise exception using message = 'HUMO-ROLLBACK';
    exception when others then
      if sqlerrm <> 'HUMO-ROLLBACK' then raise; end if;
    end;
    reset role;
    if v_est is distinct from 'no_alumno' or v_clas is distinct from 'venta' then
      raise exception 'HUMO 187 E: el cliente de % no pudo resolver su propia propuesta (estado %, clasificacion %)', v_p, v_est, v_clas;
    end if;
    if v_otras_resueltas is distinct from 0 then
      raise exception 'HUMO 187 E: "aceptar todas" del cliente de % toco % propuestas de otros programas', v_p, v_otras_resueltas;
    end if;
  end loop;
  if v_probados = 0 then
    raise notice 'HUMO 187 E: no hubo ningun usuario cliente solo de liam ni de agus: nada probado como cliente (correr C12 / C13)';
  end if;

  -- Fundador: ve todas las llamadas de prueba
  select m.user_id into v_f from public.crm_members m where m.rol = 'fundador' limit 1;
  if v_f is not null then
    perform set_config('request.jwt.claim.sub', v_f::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_f, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into v_n from public.cs_v_fathom_llamadas v where v.id = any (v_todas);
    reset role;
    if v_n <> cardinality(v_todas) then raise exception 'HUMO 187 E: el fundador ve % de % llamadas de prueba', v_n, cardinality(v_todas); end if;
  end if;
  -- Consultor con login: ve las suyas y no las de otro consultor
  if v_cu is not null and v_huer2 is not null then
    perform set_config('request.jwt.claim.sub', v_cu::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_cu, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select coalesce(array_agg(v.id), '{}'::uuid[]) into v_ids from public.cs_v_fathom_llamadas v where v.estado <> 'alumno';
    reset role;
    if not (v_huer = any (v_ids)) or v_huer2 = any (v_ids) then
      raise exception 'HUMO 187 E: el consultor no ve exactamente las suyas (propia %, ajena %)', v_huer = any (v_ids), v_huer2 = any (v_ids);
    end if;
  else
    raise notice 'HUMO 187 E: sin consultor con usuario o sin un segundo consultor: se omite la prueba del consultor';
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);

  if has_function_privilege('anon', 'public.cs_fathom_ve_llamada_id(uuid)', 'execute')
     or has_function_privilege('anon', 'public.cs_fathom_ve_propuesta(uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.cs_fathom_programas_cliente()', 'execute')
     or has_function_privilege('authenticated', 'public.cs_fathom_es_gestor_llamada(uuid)', 'execute')
     or has_function_privilege('anon', 'public.cs_fathom_asignar(uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.cs_fathom_alumnos()', 'execute') then
    raise exception 'HUMO 187 E: permisos de mas';
  end if;

  delete from public.cs_fathom_propuestas where llamada_id = any (v_todas);
  delete from public.cs_fathom_sin_asignar where id = any (v_todas);
  raise notice 'HUMO OK: 187 E (clientes probados: %)', v_probados;
end
$humoe$;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- C1. Programas habilitados (esperado: {teo,liam,agus}) y cron.
--   select programas, cron_activo, ia_clasificar_auto from public.cs_fathom_config;
--
-- C2. Columna, check y trigger (esperado: 1 fila de cada una).
--   select column_name from information_schema.columns where table_name = 'cs_fathom_sin_asignar' and column_name = 'clasificacion';
--   select conname from pg_constraint where conrelid = 'public.cs_fathom_sin_asignar'::regclass and conname = 'cs_fathom_sin_asignar_clasif_187';
--   select tgname from pg_trigger where tgrelid = 'public.cs_fathom_sin_asignar'::regclass and tgname = 'cs_fathom_sin_asignar_clasif' and not tgisinternal;
--
-- C3. Permisos (esperado: guardar solo service_role; resolver / altas authenticated sin anon; vista sin anon; respaldo sin lectura).
--   select has_function_privilege('anon', 'public.cs_fathom_prop_guardar(jsonb)', 'execute') as guardar_anon,
--          has_function_privilege('authenticated', 'public.cs_fathom_prop_guardar(jsonb)', 'execute') as guardar_auth,
--          has_function_privilege('service_role', 'public.cs_fathom_prop_guardar(jsonb)', 'execute') as guardar_sr,
--          has_function_privilege('authenticated', 'public.cs_fathom_prop_resolver(uuid,text,uuid,text)', 'execute') as res_auth,
--          has_function_privilege('anon', 'public.cs_fathom_prop_resolver(uuid,text,uuid,text)', 'execute') as res_anon,
--          has_table_privilege('anon', 'public.cs_v_fathom_llamadas', 'select') as vista_anon,
--          has_table_privilege('authenticated', 'public.cs_bak_187_funciones', 'select') as bak_auth;
--
-- C4. Quién puede revisar: consultores con usuario (esperado: uno por consultor con login configurado).
--   select c.id as consultor, c.email_login, exists (select 1 from auth.users u where lower(u.email) = c.email_login) as tiene_usuario
--   from public.cs_fathom_consultores c order by c.orden, c.id;
--
-- C5. DESPUÉS de re-clasificar: propuestas pendientes con alumno por programa del alumno (esperado: aparecen liam y agus).
--   select c.programa_id, p.confianza, count(*) from public.cs_fathom_propuestas p
--   join public.cs_clientes c on c.id = p.alumno_id where p.estado = 'pendiente' group by 1, 2 order by 1, 2;
--
-- C6. Llamadas sin ningún candidato de la IA siguen siendo muchas? (propuestas pendientes sin alumno y de tipo 1 a 1).
--   select tipo, confianza, origen, count(*) from public.cs_fathom_propuestas where estado = 'pendiente' group by 1, 2, 3 order by 1, 2, 3;
--
-- C7. Clases / ventas / internas ya guardadas con su tipo (después de aceptar).
--   select clasificacion, count(*) from public.cs_fathom_sin_asignar where estado = 'no_alumno' group by 1 order by 1;
--
-- C8. Nada debe quedar con clasificación fuera de no_alumno (esperado: 0).
--   select count(*) from public.cs_fathom_sin_asignar where clasificacion is not null and estado <> 'no_alumno';
--
-- C9. Aceptadas / corregidas no se pisan: ninguna con updated_at posterior a su resuelta_at (esperado: 0).
--   select count(*) from public.cs_fathom_propuestas where estado <> 'pendiente' and updated_at > resuelta_at + interval '1 second';
--
-- C10. Efecto en la sync: llamadas nuevas asignadas por fathom-sync a liam / agus desde que se habilitaron
--      (reemplazar el instante por el de la corrida de la migración).
--   select a.programa_id, l.asignada_por, count(*) from public.cs_llamadas l join public.cs_clientes a on a.id = l.cliente_id
--   where l.fuente = 'fathom' and l.created_at > now() - interval '1 day' group by 1, 2 order by 1, 2;
--
-- C11. Costo de la re-clasificación (ia_uso).
--   select date_trunc('day', created_at) as dia, count(*) as pedidos, count(*) filter (where not ok) as fallidos, sum(costo_usd) as usd
--   from public.ia_uso where funcion = 'fathom_clasificar' group by 1 order by 1 desc;
--
-- C12. Cada cliente ve SOLO lo de su programa (E). Primero los usuarios cliente y sus programas:
--   select u.id, u.email, m.rol, array_agg(a.programa_id order by a.programa_id) as programas
--   from auth.users u join public.crm_members m on m.user_id = u.id left join public.cs_accesos a on a.user_id = u.id
--   where m.rol = 'cliente' group by 1, 2, 3 order by 4, 2;
--   Después, UNA VEZ POR CADA cliente de liam (usuario @liam.dystopia) y de agus, en el SQL Editor (se revierte con rollback;
--   reemplazar <UID> y <PROG> = liam | agus). Esperado: las 3 últimas consultas dan 0.
--   begin;
--     select set_config('request.jwt.claim.sub', '<UID>', true),
--            set_config('request.jwt.claims', json_build_object('sub', '<UID>', 'role', 'authenticated')::text, true);
--     set local role authenticated;
--     select v.estado, count(*) as visibles from public.cs_v_fathom_llamadas v group by 1 order by 1;       -- pendientes, no_alumno, interna, alumno
--     select (select count(*) from public.cs_fathom_propuestas) as propuestas_visibles,
--            (select count(*) from public.cs_fathom_sin_asignar) as filas_tabla_visibles,
--            public.cs_fathom_programas() as programas_habilitados_que_ve;                                -- esperado: {<PROG>}
--     select a.programa_id, count(*) from public.cs_fathom_alumnos() a group by 1;                          -- esperado: solo <PROG>
--     select count(*) as asignadas_de_otro_programa from public.cs_v_fathom_llamadas v
--       where v.estado = 'alumno' and v.programa_id <> '<PROG>';                                            -- 0
--     select count(*) as pendientes_sin_alumno_de_su_programa from public.cs_v_fathom_llamadas v
--       where v.estado <> 'alumno' and not exists (select 1 from public.cs_clientes c where c.programa_id = '<PROG>'
--         and (c.id = any (v.candidatos) or c.id in (select p.alumno_id from public.cs_fathom_propuestas p where p.llamada_id = v.id)));  -- 0
--     select count(*) as propuestas_con_alumno_de_otro_programa from public.cs_fathom_propuestas p
--       where p.alumno_id is not null and not exists (select 1 from public.cs_clientes c where c.id = p.alumno_id and c.programa_id = '<PROG>');  -- 0
--   rollback;
--
-- C13. Intento de resolver una propuesta de OTRO programa como ese cliente (esperado: ERROR 42501, nada cambia).
--   Antes, como fundador, una propuesta pendiente cuyo alumno sea de otro programa:
--   select p.id as propuesta, p.llamada_id, c.programa_id from public.cs_fathom_propuestas p
--     join public.cs_clientes c on c.id = p.alumno_id where p.estado = 'pendiente' and c.programa_id <> '<PROG>' limit 3;
--   begin;
--     select set_config('request.jwt.claim.sub', '<UID>', true),
--            set_config('request.jwt.claims', json_build_object('sub', '<UID>', 'role', 'authenticated')::text, true);
--     set local role authenticated;
--     select public.cs_fathom_prop_resolver('<PROPUESTA_OTRO_PROGRAMA>', 'descartar');   -- ERROR 42501
--   rollback;
--   (repetir con 'aceptar', con public.cs_fathom_marcar_no_alumno('<LLAMADA_OTRO_PROGRAMA>') y con
--    public.cs_fathom_asignar('<LLAMADA_PROPIA>', '<ALUMNO_DE_OTRO_PROGRAMA>'): todas deben dar 42501)
--
-- C14. Fundador y consultor siguen igual: como fundador la vista da todas las pendientes; como consultor, solo las suyas
--      (mismo bloque que C12 con el UID del fundador / del consultor y sin el filtro de programa).
--   select u.id, c.id as consultor from public.cs_fathom_consultores c join auth.users u on lower(u.email) = c.email_login;
--   select s.consultor, count(*) from public.cs_fathom_sin_asignar s where s.estado in ('pendiente','no_alumno','interna') group by 1;

-- =====================================================================
-- VUELTA ATRÁS (comentada). Las llamadas que ya se asignaron por la sync a alumnos de liam / agus siguen asignadas
-- (se corrigen con "Corregir"). Las propuestas decididas no se revierten.
-- =====================================================================
--   begin;
--   lock table public.cs_fathom_sin_asignar, public.cs_fathom_config, public.cs_fathom_propuestas in share row exclusive mode;
--   -- 1) programas como estaban
--   update public.cs_fathom_config set programas = string_to_array((select definicion from public.cs_bak_187_funciones where funcion = 'config.programas'), ',');
--   -- 2) la clasificación de lo que quedó "no es alumno" se pierde (vuelven a ser "No es alumno" a secas)
--   drop trigger if exists cs_fathom_sin_asignar_clasif on public.cs_fathom_sin_asignar;
--   drop function if exists public.cs_tg_fathom_sin_asignar_clasif();
--   -- 3) la vista de la 127 (sin la columna): tiene que ir antes de borrar la columna
--   drop view public.cs_v_fathom_llamadas;
--   create view public.cs_v_fathom_llamadas as
--   select l.id, 'alumno'::text as estado, l.consultor, l.fecha, l.inicio_at, l.titulo, l.tipo, l.duracion_min,
--          l.grabacion_url, l.grabacion_share_url, l.resumen, l.en_que_esta, l.proximos_pasos,
--          l.cliente_id, l.programa_id, c.nombre as alumno_nombre,
--          l.invitados, null::text as motivo, '{}'::uuid[] as candidatos, l.asignada_por
--   from public.cs_llamadas l left join public.cs_clientes c on c.id = l.cliente_id
--   where l.fuente = 'fathom' and (coalesce(public.cs_puede_ver(l.programa_id), false) or public.cs_fathom_es_consultor(l.consultor))
--   union all
--   select s.id, s.estado, s.consultor, s.fecha, s.inicio_at, s.titulo, s.tipo, s.duracion_min,
--          s.grabacion_url, s.grabacion_share_url, s.resumen, s.en_que_esta, s.proximos_pasos,
--          null::uuid, null::text, null::text, s.invitados, s.motivo, s.candidatos, null::text
--   from public.cs_fathom_sin_asignar s
--   where s.estado in ('pendiente', 'no_alumno', 'interna') and (public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor(s.consultor));
--   revoke all on public.cs_v_fathom_llamadas from public, anon;
--   grant select on public.cs_v_fathom_llamadas to authenticated;
--   alter table public.cs_fathom_sin_asignar drop constraint if exists cs_fathom_sin_asignar_clasif_187;
--   alter table public.cs_fathom_sin_asignar drop column if exists clasificacion;
--   -- 4) funciones y políticas de antes, desde el respaldo (OJO: vuelve la visibilidad de antes, donde un cliente de un programa
--   --    habilitado ve las pendientes de TODOS los programas; no volver atrás sin necesidad)
--   do $$ declare r record; begin
--     for r in select definicion from public.cs_bak_187_funciones
--              where funcion in ('cs_fathom_prop_resolver(uuid,text,uuid,text)', 'cs_fathom_prop_aceptar_altas(int)',
--                                'public.cs_fathom_puede_gestionar(text)', 'public.cs_fathom_asignar(uuid,uuid)',
--                                'public.cs_fathom_marcar_no_alumno(uuid)', 'public.cs_fathom_reabrir(uuid)',
--                                'public.cs_fathom_programas()', 'public.cs_fathom_alumnos()') loop
--       execute r.definicion;
--     end loop; end $$;
--   drop policy if exists cs_privadas_select on public.cs_fathom_sin_asignar;
--   create policy cs_privadas_select on public.cs_fathom_sin_asignar for select to authenticated
--     using (public.cs_fathom_ve_privadas() or public.cs_fathom_es_consultor(consultor));
--   drop policy if exists cs_prop_select on public.cs_fathom_propuestas;
--   create policy cs_prop_select on public.cs_fathom_propuestas for select to authenticated using (public.cs_fathom_ve_privadas());
--   drop function if exists public.cs_fathom_prop_guardar(jsonb);
--   drop function if exists public.cs_fathom_ve_propuesta(uuid, uuid);
--   drop function if exists public.cs_fathom_ve_llamada_id(uuid);
--   drop function if exists public.cs_fathom_es_gestor_llamada(uuid);
--   drop function if exists public.cs_fathom_programas_cliente();
--   -- 5) respaldo: dejarlo (tiene RLS); borrarlo cuando ya no haga falta
--   --    drop table public.cs_bak_187_funciones;
--   commit;
--   -- Si se vuelve atrás, redesplegar ia-fathom-clasificar de la 186 (no usa cs_fathom_prop_guardar).
