-- =====================================================================
-- 193 · Fathom: nombres del EQUIPO (no alumnos) para que la IA no los confunda con un alumno
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 124 (cs_tg_updated_at / es_fundador ya existen desde 039).
--
-- Qué hace
--   A. Tabla cs_fathom_equipo_nombres (nombre, nota, activo). RLS como la configuración de Fathom:
--      lee, agrega y edita SOLO el fundador (es_fundador()); sin delete (se desactiva). La Edge Function
--      ia-fathom-clasificar la lee con service_role.
--   B. Semilla: Teo North, Joaco Fernandez, Ignacio Colombetti, Tomas Ouper, Martina Chimienti, Morello Valentin.
--      El orden nombre/apellido no importa (la función compara sin orden): "Valentin Morello" ya queda cubierto.
--      NO se cargan clientes: Constantino Barreira, Martina Roman, Valentina Vergini, Valentin Romero.
--   Único por nombre normalizado (minúsculas, sin acentos). No toca llamadas, hablantes ni propuestas.
--
-- Correr en una sola ejecución, evitando los minutos :00, :15, :30 y :45 y las 9:00.
-- Después: desplegar ia-fathom-clasificar (v4) y controles C1 a C4.
-- =====================================================================

begin;
set local lock_timeout = '8s';

do $chk$
begin
  if to_regprocedure('public.es_fundador()') is null or to_regprocedure('public.cs_tg_updated_at()') is null then
    raise exception '193: faltan es_fundador() / cs_tg_updated_at()';
  end if;
  if to_regclass('public.cs_fathom_equipo_nombres') is not null then
    raise exception '193: ya fue corrida (existe cs_fathom_equipo_nombres)';
  end if;
end
$chk$;

create table public.cs_fathom_equipo_nombres (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null check (btrim(nombre) <> '' and char_length(nombre) <= 80),
  nota        text check (nota is null or char_length(nota) <= 200),
  activo      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.cs_fathom_equipo_nombres is
  '193: nombres de personas del EQUIPO (no alumnos) tal como aparecen en Fathom. ia-fathom-clasificar los saca de los hablantes antes de buscar al alumno. Orden nombre/apellido indistinto.';

create unique index cs_fathom_equipo_nombres_uq
  on public.cs_fathom_equipo_nombres (lower(btrim(nombre)));

create trigger cs_fathom_equipo_nombres_upd before update on public.cs_fathom_equipo_nombres
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_fathom_equipo_nombres enable row level security;
revoke all on table public.cs_fathom_equipo_nombres from public, anon, authenticated;
grant select, insert, update on table public.cs_fathom_equipo_nombres to authenticated;
grant select on table public.cs_fathom_equipo_nombres to service_role;
create policy cs_fundador_select on public.cs_fathom_equipo_nombres for select to authenticated
  using (coalesce(public.es_fundador(), false));
create policy cs_fundador_insert on public.cs_fathom_equipo_nombres for insert to authenticated
  with check (coalesce(public.es_fundador(), false));
create policy cs_fundador_update on public.cs_fathom_equipo_nombres for update to authenticated
  using (coalesce(public.es_fundador(), false)) with check (coalesce(public.es_fundador(), false));

insert into public.cs_fathom_equipo_nombres (nombre, nota) values
  ('Teo North',          'Consultor teo'),
  ('Joaco Fernandez',    'Fundador'),
  ('Ignacio Colombetti', 'Nacho, agencia'),
  ('Tomas Ouper',        'Ex equipo'),
  ('Martina Chimienti',  'Martu, consultora'),
  ('Morello Valentin',   'Valen, agencia (Fathom lo muestra así; también puede aparecer Valentin Morello)');

do $ver$
begin
  if (select count(*) from public.cs_fathom_equipo_nombres where activo) <> 6 then
    raise exception '193: la semilla debía dejar 6 nombres activos';
  end if;
end
$ver$;

commit;

-- =====================================================================
-- CONTROLES (correr de a uno)
-- =====================================================================
-- C1. Semilla: 6 filas activas, y ningún cliente en la lista (0 filas):
-- select nombre, nota, activo from public.cs_fathom_equipo_nombres order by nombre;
-- select nombre from public.cs_fathom_equipo_nombres
--  where lower(nombre) ~ '(barreira|roman|vergini|romero)';
-- C2. RLS activa y sin delete (rls = true; privilegios solo select/insert/update):
-- select relrowsecurity as rls from pg_class where oid = 'public.cs_fathom_equipo_nombres'::regclass;
-- select policyname, cmd from pg_policies where tablename = 'cs_fathom_equipo_nombres' order by 1;
-- C3. Después de desplegar la función, diagnóstico (equipo_leido = true, equipo_nombres >= 9 con los consultores,
--     hablantes_del_equipo_descartados > 0, y "TEO NORTH" / "Joaco Fernandez" ya no cuentan):
--     POST /functions/v1/ia-fathom-clasificar  {"diagnostico": true}
-- C4. Tras re-clasificar las pendientes, propuestas por confianza (las de "alta" solo deberían ser por mail o por nombre completo):
-- select origen, confianza, count(*) from public.cs_fathom_propuestas where estado = 'pendiente' group by 1, 2 order by 1, 2;
--
-- VUELTA ATRÁS (solo si hace falta; la función sigue andando sin la tabla):
-- drop table public.cs_fathom_equipo_nombres;
