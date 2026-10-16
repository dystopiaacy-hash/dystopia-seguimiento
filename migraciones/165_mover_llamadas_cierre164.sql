-- =====================================================================
-- 165_mover_llamadas_cierre164.sql  ·  PRODUCTO: mover las llamadas (y lo que cuelga) de las 3 fichas cerradas por la 164
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución), DESPUÉS de la 164. Evitar los minutos :00, :15,
-- :30 y :45 (sync de Finanzas), las 9:00 (cron diario de Producto) y las corridas de fathom-sync.
-- Requiere 102 (llamadas), 106 (wins, satisfacción, dudas, transcripciones), 122 (cs_fathom_sin_asignar),
-- 134 (candidatas de duda), 157 (consultorías) y la 164 corrida. No crea ni cambia funciones, vistas ni crons.
-- NO tiene datos personales: las fichas se identifican solo por el prefijo del uuid. Nada se borra.
--
-- Pares (cerrada por la 164 -> vigente):  e4c8102a -> 28d200e3 · be2a3e68 -> 5955e47d · 2375ab58 -> 17d1c875
--
-- Por qué hace falta una migración aparte: cs_llamadas y sus hijas tienen triggers que prohíben cambiar de alumno
-- (cs_llamadas_before, cs_llamada_acc_before, cs_llamada_rec_before, cs_duda_menciones_before, cs_wins_before) y FKs
-- compuestas (llamada_id, cliente_id) -> cs_llamadas (id, cliente_id), sin ON UPDATE y no diferibles. Por eso:
--   - los 5 triggers se desactivan con ALTER TABLE ... DISABLE TRIGGER SOLO dentro de esta transacción (con las tablas
--     bloqueadas) y se vuelven a habilitar antes del COMMIT; la verificación final exige que los 5 estén en 'O'.
--     Si algo falla, el ROLLBACK de la transacción deja todo como estaba (DDL transaccional en Postgres);
--   - la llamada y todas sus hijas se actualizan en UNA sola sentencia con CTEs que modifican datos: las FKs se
--     chequean al final de la sentencia, cuando padre e hijas ya apuntan a la ficha vigente.
--
-- QUÉ MUEVE (de la ficha cerrada a la vigente):
--   1. cs_llamadas, salvo las duplicadas (ver abajo), con TODO lo que cuelga: cs_llamada_accionables,
--      cs_llamada_transcripciones, cs_duda_candidatas, cs_fathom_sin_asignar.llamada_id (puntero, si lo hay) y los
--      cs_llamada_recursos de esas llamadas. Los recursos sin llamada (links del alumno) también se mueven.
--   2. cs_wins (salvo duplicados). Ojo: el "Pedir referido" pendiente de un win aparecerá en Hoy bajo la ficha vigente.
--   3. cs_satisf_envios: todos los de la cerrada, salvo los de un momento que la vigente ya tiene (índice único
--      (cliente_id, momento_id)); esos se quedan en la cerrada y se informan.
--   4. cs_duda_menciones: las de la cerrada que no chocan con la vigente en (duda, fecha). Una que choca y apunta a
--      una llamada movida queda en la cerrada con llamada_id = null (si no, la FK compuesta lo impediría).
--   5. cs_onboardings (+ cs_onboarding_respuestas): solo si la vigente NO tiene onboarding (es único por alumno).
--   6. cs_consultoria_asistentes: las consultorías a las que asistió la cerrada y la vigente no tiene registradas
--      (así el semáforo de un alumno grupal, que se mide por asistencia, no pierde la historia).
--
-- LLAMADAS DUPLICADAS (criterio): una llamada de la cerrada es duplicada si la vigente tiene otra de la MISMA FECHA
--   con el mismo inicio_at, o la misma grabacion_url, o el mismo título (sin mayúsculas ni espacios de más).
--   (externo_id es único global, así que la misma reunión de Fathom no puede estar en las dos fichas; el caso real
--   es una carga manual más la de Fathom.) La duplicada NO se mueve ni se borra: se queda en la cerrada y se
--   informa en la corrida (NOTICE) y en el control C5, para decidir a mano. Los wins se comparan igual: misma fecha
--   y mismo texto normalizado.
--
-- QUÉ NO MUEVE y por qué:
--   - cs_alertas: clave_dedupe es única global y las alertas de una ficha cerrada (ej. programa_vencido) describen
--     a ESA ficha; trasladarlas generaría ruido en la vigente. Se quedan (control C6 las lista).
--   - cs_chequeos, cs_historial: son historia de la ficha cerrada.
--   - cs_en_que_esta, cs_riesgo_abandono, cs_upsell_marcas: una fila por alumno (PK cliente_id), derivadas de las
--     llamadas por IA o marca manual; la vigente ya puede tener la suya. "En qué está" detecta llamadas nuevas por
--     llamadas_ids, así que la IA la regenera sola en la próxima corrida; el riesgo se reevalúa si cambia su huella.
--   - cs_calls (tabla vieja de llamadas) y cs_dudas_procesadas (clave solo llamada_id, sigue válida): sin cambios.
--     cs_calls NO se movió porque no está en el alcance pedido; si las fichas cerradas tienen calls 'realizada', siguen
--     contando para la cerrada (control C6 las cuenta).
--   - "días sin llamada" / última llamada: NO se guarda en columnas. Sale de la vista cs_v_ultima_llamada (sobre
--     cs_llamadas, cs_calls y cs_seguimientos), así que queda consistente sola. La verificación final lo comprueba.
--
-- Respaldo: cs_bak_165_hijos (con RLS, sin políticas). Una fila por fila movida, con la fila completa en jsonb
-- (sin el token de onboardings y envíos, y sin el texto de las transcripciones: no cambian). Los controles C1 a C8 y la
-- vuelta atrás están comentados al final.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- Objetivos (prefijos de uuid)
-- ---------------------------------------------------------------------
create temp table pares165_pref (cierra text primary key, queda text not null) on commit drop;
insert into pares165_pref (cierra, queda) values
  ('e4c8102a', '28d200e3'),
  ('be2a3e68', '5955e47d'),
  ('2375ab58', '17d1c875');


-- ---------------------------------------------------------------------
-- Autochequeo: lo que usa esta migración tiene que existir.
-- ---------------------------------------------------------------------
do $$
declare
  v_falta text;
begin
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_clientes'), ('cs_llamadas'), ('cs_llamada_accionables'), ('cs_llamada_recursos'),
               ('cs_llamada_transcripciones'), ('cs_duda_candidatas'), ('cs_duda_menciones'), ('cs_wins'),
               ('cs_satisf_envios'), ('cs_onboardings'), ('cs_onboarding_respuestas'),
               ('cs_consultoria_asistentes'), ('cs_fathom_sin_asignar')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 165: faltan tablas (corrieron 102, 106, 122, 134 y 157?): %', v_falta;
  end if;

  select string_agg(r.n, ', ') into v_falta
  from (values ('cs_llamadas', 'cs_llamadas_before'), ('cs_llamada_accionables', 'cs_llamada_acc_before'),
               ('cs_llamada_recursos', 'cs_llamada_rec_before'), ('cs_duda_menciones', 'cs_duda_menciones_before'),
               ('cs_wins', 'cs_wins_before')) as r(t, n)
  where not exists (select 1 from pg_trigger g
                    where g.tgrelid = ('public.' || r.t)::regclass and g.tgname = r.n and not g.tgisinternal);
  if v_falta is not null then
    raise exception 'cs 165: faltan los triggers que esta migración desactiva un momento: %', v_falta;
  end if;
end $$;

-- Todas las tablas que se tocan, juntas y al principio (ya hubo un deadlock por no hacerlo).
-- SHARE ROW EXCLUSIVE también es el lock que pide ALTER TABLE ... DISABLE TRIGGER.
lock table public.cs_clientes, public.cs_llamadas, public.cs_llamada_accionables, public.cs_llamada_recursos,
           public.cs_llamada_transcripciones, public.cs_duda_candidatas, public.cs_duda_menciones, public.cs_wins,
           public.cs_satisf_envios, public.cs_onboardings, public.cs_onboarding_respuestas,
           public.cs_consultoria_asistentes, public.cs_fathom_sin_asignar
  in share row exclusive mode;


-- ---------------------------------------------------------------------
-- Resolución de ids + GUARDAS
-- ---------------------------------------------------------------------
create temp table pares165 on commit drop as
select pc.cierra as pref_cierra, pc.queda as pref_queda, cc.id as cierra_id, qq.id as queda_id
from pares165_pref pc
join public.cs_clientes cc on cc.id::text like pc.cierra || '%'
join public.cs_clientes qq on qq.id::text like pc.queda || '%';

do $$
declare
  v_mal text;
  v_n   int;
begin
  -- A. cada prefijo resuelve exactamente UNA ficha y hay 3 pares
  select string_agg(x.p || ' (' || x.n || ')', ', ') into v_mal
  from (select pc.cierra as p, (select count(*) from public.cs_clientes c where c.id::text like pc.cierra || '%') as n from pares165_pref pc
        union all
        select pc.queda,  (select count(*) from public.cs_clientes c where c.id::text like pc.queda  || '%') from pares165_pref pc) x
  where x.n <> 1;
  if v_mal is not null then
    raise exception 'cs 165: prefijos que no resuelven exactamente una ficha (prefijo (cantidad)): %', v_mal;
  end if;
  select count(*) into v_n from pares165;
  if v_n <> 3 then raise exception 'cs 165: esperaba 3 pares, hay %', v_n; end if;

  -- B. la 164 SE CORRIÓ: cada cerrada está 'finalizado' con cierre164 y duplicada_de = su vigente
  select string_agg(p.pref_cierra, ', ') into v_mal
  from pares165 p join public.cs_clientes c on c.id = p.cierra_id
  where c.estado <> 'finalizado'
     or not (coalesce(c.campos_extra, '{}'::jsonb) ? 'cierre164')
     or (c.campos_extra -> 'cierre164' ->> 'duplicada_de') is distinct from p.queda_id::text;
  if v_mal is not null then
    raise exception 'cs 165: estas fichas no están cerradas por la 164 (finalizado + cierre164 apuntando a la vigente). Correr la 164 antes: %', v_mal;
  end if;

  -- C. las vigentes son de liam y no están cerradas ni de baja
  select string_agg(p.pref_queda, ', ') into v_mal
  from pares165 p join public.cs_clientes q on q.id = p.queda_id join public.cs_clientes c on c.id = p.cierra_id
  where q.programa_id <> 'liam' or c.programa_id <> 'liam' or q.estado in ('baja', 'finalizado')
     or coalesce(q.campos_extra, '{}'::jsonb) ? 'cierre164';
  if v_mal is not null then
    raise exception 'cs 165: vigente que no es de liam, o está de baja / finalizada / cerrada por la 164: %', v_mal;
  end if;

  -- D. NO se corrió ya la 165: el respaldo no existe o está vacío
  if to_regclass('public.cs_bak_165_hijos') is not null then
    execute 'select count(*) from public.cs_bak_165_hijos' into v_n;
    if v_n > 0 then
      raise exception 'cs 165: ya se corrió (cs_bak_165_hijos tiene % filas). No se repite.', v_n;
    end if;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- Qué se mueve (todo en tablas temporales, para respaldar y mover EXACTAMENTE lo mismo)
-- ---------------------------------------------------------------------
-- Llamadas de las cerradas, con la marca de duplicada (criterio en el encabezado).
create temp table ll165 on commit drop as
select l.id, p.cierra_id, p.queda_id, l.fecha,
       exists (select 1 from public.cs_llamadas v
               where v.cliente_id = p.queda_id and v.fecha = l.fecha
                 and ((l.inicio_at is not null and v.inicio_at = l.inicio_at)
                   or (l.grabacion_url is not null and v.grabacion_url = l.grabacion_url)
                   or (l.titulo is not null and v.titulo is not null
                       and lower(btrim(l.titulo)) = lower(btrim(v.titulo))))) as dup
from public.cs_llamadas l
join pares165 p on p.cierra_id = l.cliente_id;

create temp table mv_ll165 on commit drop as
select id, cierra_id, queda_id, fecha from ll165 where not dup;

create temp table mv_acc165 on commit drop as
select a.id, l.queda_id from public.cs_llamada_accionables a join mv_ll165 l on l.id = a.llamada_id;

create temp table mv_rec165 on commit drop as
select r.id, p.queda_id
from public.cs_llamada_recursos r
join pares165 p on p.cierra_id = r.cliente_id
left join ll165 l on l.id = r.llamada_id
where r.llamada_id is null or (l.id is not null and not l.dup);

create temp table mv_tr165 on commit drop as
select t.llamada_id, l.queda_id from public.cs_llamada_transcripciones t join mv_ll165 l on l.id = t.llamada_id;

create temp table mv_cand165 on commit drop as
select c.id, l.queda_id from public.cs_duda_candidatas c join mv_ll165 l on l.id = c.llamada_id;

create temp table mv_sin165 on commit drop as
select s.id, l.queda_id from public.cs_fathom_sin_asignar s join mv_ll165 l on l.id = s.llamada_id and s.cliente_id = l.cierra_id;

-- Menciones de duda: se mueven las que no chocan en (duda, fecha) con la vigente y no cuelgan de una llamada duplicada.
create temp table mv_men165 on commit drop as
select m.id, p.queda_id
from public.cs_duda_menciones m
join pares165 p on p.cierra_id = m.cliente_id
left join ll165 l on l.id = m.llamada_id
where (m.llamada_id is null or (l.id is not null and not l.dup))
  and not exists (select 1 from public.cs_duda_menciones x
                  where x.cliente_id = p.queda_id and x.duda_id = m.duda_id and x.fecha = m.fecha);

-- Menciones que chocan pero cuelgan de una llamada que se mueve: quedan en la cerrada con llamada_id = null.
create temp table mv_men_null165 on commit drop as
select m.id
from public.cs_duda_menciones m
join pares165 p on p.cierra_id = m.cliente_id
join mv_ll165 l on l.id = m.llamada_id
where exists (select 1 from public.cs_duda_menciones x
              where x.cliente_id = p.queda_id and x.duda_id = m.duda_id and x.fecha = m.fecha);

create temp table mv_win165 on commit drop as
select w.id, p.queda_id
from public.cs_wins w
join pares165 p on p.cierra_id = w.cliente_id
where not exists (select 1 from public.cs_wins x
                  where x.cliente_id = p.queda_id and x.fecha = w.fecha
                    and lower(btrim(x.texto)) = lower(btrim(w.texto)));

create temp table mv_env165 on commit drop as
select e.id, p.queda_id
from public.cs_satisf_envios e
join pares165 p on p.cierra_id = e.cliente_id
where e.momento_id is null
   or not exists (select 1 from public.cs_satisf_envios x where x.cliente_id = p.queda_id and x.momento_id = e.momento_id);

create temp table mv_onb165 on commit drop as
select o.id, p.queda_id
from public.cs_onboardings o
join pares165 p on p.cierra_id = o.cliente_id
where not exists (select 1 from public.cs_onboardings x where x.cliente_id = p.queda_id);

create temp table mv_resp165 on commit drop as
select r.onboarding_id, r.paso_key, o.queda_id
from public.cs_onboarding_respuestas r join mv_onb165 o on o.id = r.onboarding_id;

create temp table mv_asis165 on commit drop as
select a.consultoria_id, p.cierra_id, p.queda_id
from public.cs_consultoria_asistentes a
join pares165 p on p.cierra_id = a.cliente_id
where not exists (select 1 from public.cs_consultoria_asistentes x
                  where x.consultoria_id = a.consultoria_id and x.cliente_id = p.queda_id);

-- Última llamada (vista) de las vigentes ANTES, para comprobar la consistencia después.
create temp table ult165 (queda_id uuid primary key, antes date, mueve date) on commit drop;
insert into ult165 (queda_id, antes, mueve)
select p.queda_id,
       (select max(u.ultima_llamada) from public.cs_v_ultima_llamada u where u.cliente_id = p.queda_id),
       (select max(m.fecha) from mv_ll165 m where m.queda_id = p.queda_id)
from pares165 p;

-- Conteos por ficha y tabla ANTES.
create temp table cnt165 (momento text, tabla text, ficha uuid, n int) on commit drop;
do $$
declare
  t text;
begin
  foreach t in array array['cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos', 'cs_llamada_transcripciones',
                           'cs_duda_candidatas', 'cs_duda_menciones', 'cs_wins', 'cs_satisf_envios', 'cs_onboardings',
                           'cs_onboarding_respuestas', 'cs_consultoria_asistentes'] loop
    execute format('insert into cnt165 select %L, %L, f.id, (select count(*)::int from public.%I x where x.cliente_id = f.id)
                    from (select cierra_id as id from pares165 union all select queda_id from pares165) f',
                   'antes', t, t);
  end loop;
end $$;

-- Resumen de lo que va a pasar (sin nombres).
do $$
declare
  r record;
begin
  for r in
    select p.pref_cierra as cierra, p.pref_queda as queda,
           (select count(*) from ll165 l where l.cierra_id = p.cierra_id) as llamadas,
           (select count(*) from ll165 l where l.cierra_id = p.cierra_id and l.dup) as llamadas_duplicadas,
           (select count(*) from mv_win165 w where w.queda_id = p.queda_id) as wins_a_mover,
           (select count(*) from public.cs_wins w where w.cliente_id = p.cierra_id) as wins_total,
           (select count(*) from mv_env165 e where e.queda_id = p.queda_id) as envios_a_mover,
           (select count(*) from public.cs_satisf_envios e where e.cliente_id = p.cierra_id) as envios_total,
           (select count(*) from mv_onb165 o where o.queda_id = p.queda_id) as onboarding_a_mover
    from pares165 p order by 1
  loop
    raise notice 'cs 165: % -> %: llamadas % (duplicadas, se quedan: %), wins % de %, envios % de %, onboarding a mover %',
      r.cierra, r.queda, r.llamadas, r.llamadas_duplicadas, r.wins_a_mover, r.wins_total, r.envios_a_mover, r.envios_total,
      r.onboarding_a_mover;
  end loop;

  if not exists (select 1 from mv_ll165) and not exists (select 1 from mv_win165) and not exists (select 1 from mv_env165)
     and not exists (select 1 from mv_onb165) and not exists (select 1 from mv_asis165) and not exists (select 1 from mv_rec165) then
    raise exception 'cs 165: no hay nada para mover (las fichas cerradas no tienen llamadas ni nada de lo que cuelga). Revisar antes de seguir.';
  end if;
end $$;


-- =====================================================================
-- 0. RESPALDO (cs_bak_165_hijos, con RLS)
-- =====================================================================
create table if not exists public.cs_bak_165_hijos (
  n                  bigserial primary key,
  tabla              text not null,
  fila               jsonb not null,     -- fila ANTES de moverla (sin token ni texto de transcripción)
  cliente_id_antes   uuid,
  cliente_id_despues uuid,
  respaldado_at      timestamptz not null default now()
);
create index if not exists cs_bak_165_hijos_tabla_idx on public.cs_bak_165_hijos (tabla);
revoke all on table public.cs_bak_165_hijos from public, anon, authenticated;
alter table public.cs_bak_165_hijos enable row level security;

insert into public.cs_bak_165_hijos (tabla, fila, cliente_id_antes, cliente_id_despues)
select 'cs_llamadas', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_llamadas x join mv_ll165 m on m.id = x.id
union all
select 'cs_llamada_accionables', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_llamada_accionables x join mv_acc165 m on m.id = x.id
union all
select 'cs_llamada_recursos', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_llamada_recursos x join mv_rec165 m on m.id = x.id
union all
select 'cs_llamada_transcripciones', to_jsonb(x) - 'texto', x.cliente_id, m.queda_id
  from public.cs_llamada_transcripciones x join mv_tr165 m on m.llamada_id = x.llamada_id
union all
select 'cs_duda_candidatas', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_duda_candidatas x join mv_cand165 m on m.id = x.id
union all
select 'cs_fathom_sin_asignar', to_jsonb(x) - 'transcripcion', x.cliente_id, m.queda_id
  from public.cs_fathom_sin_asignar x join mv_sin165 m on m.id = x.id
union all
select 'cs_duda_menciones', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_duda_menciones x join mv_men165 m on m.id = x.id
union all
select 'cs_duda_menciones_llamada_null', to_jsonb(x), x.cliente_id, x.cliente_id
  from public.cs_duda_menciones x join mv_men_null165 m on m.id = x.id
union all
select 'cs_wins', to_jsonb(x), x.cliente_id, m.queda_id from public.cs_wins x join mv_win165 m on m.id = x.id
union all
select 'cs_satisf_envios', to_jsonb(x) - 'token', x.cliente_id, m.queda_id from public.cs_satisf_envios x join mv_env165 m on m.id = x.id
union all
select 'cs_onboardings', to_jsonb(x) - 'token', x.cliente_id, m.queda_id from public.cs_onboardings x join mv_onb165 m on m.id = x.id
union all
select 'cs_onboarding_respuestas', to_jsonb(x), x.cliente_id, m.queda_id
  from public.cs_onboarding_respuestas x join mv_resp165 m on m.onboarding_id = x.onboarding_id and m.paso_key = x.paso_key
union all
select 'cs_consultoria_asistentes', to_jsonb(x) - 'intervenciones', x.cliente_id, m.queda_id
  from public.cs_consultoria_asistentes x join mv_asis165 m on m.consultoria_id = x.consultoria_id and m.cierra_id = x.cliente_id;


-- =====================================================================
-- 1. MOVER (triggers apagados SOLO acá, dentro de la transacción)
-- =====================================================================
create temp table trg165 (tabla text, trigger text) on commit drop;
insert into trg165 values
  ('cs_llamadas', 'cs_llamadas_before'),
  ('cs_llamada_accionables', 'cs_llamada_acc_before'),
  ('cs_llamada_recursos', 'cs_llamada_rec_before'),
  ('cs_duda_menciones', 'cs_duda_menciones_before'),
  ('cs_wins', 'cs_wins_before');

do $$
declare
  t record;
begin
  for t in select * from trg165 loop
    execute format('alter table public.%I disable trigger %I', t.tabla, t.trigger);
  end loop;
end $$;

-- 1a. Llamadas + todo lo que cuelga de ellas, en UNA sola sentencia (las FKs compuestas se chequean al final).
with
  u_ll   as (update public.cs_llamadas x set cliente_id = m.queda_id from mv_ll165 m where x.id = m.id returning x.id),
  u_acc  as (update public.cs_llamada_accionables x set cliente_id = m.queda_id from mv_acc165 m where x.id = m.id returning x.id),
  u_rec  as (update public.cs_llamada_recursos x set cliente_id = m.queda_id from mv_rec165 m where x.id = m.id returning x.id),
  u_tr   as (update public.cs_llamada_transcripciones x set cliente_id = m.queda_id from mv_tr165 m where x.llamada_id = m.llamada_id returning x.llamada_id),
  u_cand as (update public.cs_duda_candidatas x set cliente_id = m.queda_id from mv_cand165 m where x.id = m.id returning x.id),
  u_men  as (update public.cs_duda_menciones x set cliente_id = m.queda_id from mv_men165 m where x.id = m.id returning x.id),
  u_men0 as (update public.cs_duda_menciones x set llamada_id = null from mv_men_null165 m where x.id = m.id returning x.id),
  u_sin  as (update public.cs_fathom_sin_asignar x set cliente_id = m.queda_id from mv_sin165 m where x.id = m.id returning x.id)
select 1;

-- 1b. Wins, envíos de satisfacción, onboardings (con sus respuestas) y asistencia a consultorías.
with
  u_win  as (update public.cs_wins x set cliente_id = m.queda_id from mv_win165 m where x.id = m.id returning x.id),
  u_env  as (update public.cs_satisf_envios x set cliente_id = m.queda_id from mv_env165 m where x.id = m.id returning x.id),
  u_onb  as (update public.cs_onboardings x set cliente_id = m.queda_id from mv_onb165 m where x.id = m.id returning x.id),
  u_resp as (update public.cs_onboarding_respuestas x set cliente_id = m.queda_id from mv_resp165 m
              where x.onboarding_id = m.onboarding_id and x.paso_key = m.paso_key returning x.onboarding_id),
  u_asis as (update public.cs_consultoria_asistentes x set cliente_id = m.queda_id from mv_asis165 m
              where x.consultoria_id = m.consultoria_id and x.cliente_id = m.cierra_id returning x.consultoria_id)
select 1;

-- Triggers de vuelta, siempre.
do $$
declare
  t record;
begin
  for t in select * from trg165 loop
    execute format('alter table public.%I enable trigger %I', t.tabla, t.trigger);
  end loop;
end $$;


-- =====================================================================
-- VERIFICACIÓN dentro de la transacción: si algo no quedó como se espera, aborta y no se guarda nada
-- =====================================================================
do $$
declare
  t       text;
  v_sale  bigint;
  v_entra bigint;
  v_bak   bigint;
  v_n     bigint;
  v_mal   text;
begin
  -- conteos DESPUÉS
  foreach t in array array['cs_llamadas', 'cs_llamada_accionables', 'cs_llamada_recursos', 'cs_llamada_transcripciones',
                           'cs_duda_candidatas', 'cs_duda_menciones', 'cs_wins', 'cs_satisf_envios', 'cs_onboardings',
                           'cs_onboarding_respuestas', 'cs_consultoria_asistentes'] loop
    execute format('insert into cnt165 select %L, %L, f.id, (select count(*)::int from public.%I x where x.cliente_id = f.id)
                    from (select cierra_id as id from pares165 union all select queda_id from pares165) f',
                   'despues', t, t);

    -- lo que sale de las cerradas = lo que entra a las vigentes = lo respaldado
    select coalesce(sum(a.n - d.n), 0) into v_sale
    from cnt165 a join cnt165 d on d.tabla = a.tabla and d.ficha = a.ficha and d.momento = 'despues'
    where a.momento = 'antes' and a.tabla = t and a.ficha in (select cierra_id from pares165);
    select coalesce(sum(d.n - a.n), 0) into v_entra
    from cnt165 a join cnt165 d on d.tabla = a.tabla and d.ficha = a.ficha and d.momento = 'despues'
    where a.momento = 'antes' and a.tabla = t and a.ficha in (select queda_id from pares165);
    select count(*) into v_bak from public.cs_bak_165_hijos b where b.tabla = t;
    if v_sale <> v_entra or v_sale <> v_bak then
      raise exception 'cs 165: % no cuadra: salen % de las cerradas, entran % a las vigentes, respaldadas % ', t, v_sale, v_entra, v_bak;
    end if;
  end loop;

  -- por par: lo que sale de la cerrada es lo que entra a SU vigente
  select string_agg(p.pref_cierra || '/' || x.tabla, ', ') into v_mal
  from pares165 p
  join (select distinct tabla from cnt165) x on true
  where (select n from cnt165 where momento = 'antes' and tabla = x.tabla and ficha = p.cierra_id)
      - (select n from cnt165 where momento = 'despues' and tabla = x.tabla and ficha = p.cierra_id)
     <> (select n from cnt165 where momento = 'despues' and tabla = x.tabla and ficha = p.queda_id)
      - (select n from cnt165 where momento = 'antes' and tabla = x.tabla and ficha = p.queda_id);
  if v_mal is not null then raise exception 'cs 165: un par no cuadra (cerrada/tabla): %', v_mal; end if;

  -- las cerradas se quedan solo con las llamadas duplicadas (y lo que cuelga de ellas)
  select count(*) into v_n from public.cs_llamadas l join pares165 p on p.cierra_id = l.cliente_id;
  if v_n <> (select count(*) from ll165 where dup) then
    raise exception 'cs 165: quedaron % llamadas en las cerradas y las duplicadas son %', v_n, (select count(*) from ll165 where dup);
  end if;
  select count(*) into v_n from public.cs_llamadas l join mv_ll165 m on m.id = l.id and l.cliente_id = m.queda_id;
  if v_n <> (select count(*) from mv_ll165) then raise exception 'cs 165: no todas las llamadas quedaron en la vigente'; end if;

  -- nada colgado de una llamada que ya no es del mismo alumno (las FKs ya lo garantizan; doble control)
  select count(*) into v_n from public.cs_llamada_accionables a join public.cs_llamadas l on l.id = a.llamada_id where l.cliente_id <> a.cliente_id;
  if v_n > 0 then raise exception 'cs 165: % accionables de llamada con otro alumno que su llamada', v_n; end if;
  select count(*) into v_n from public.cs_fathom_sin_asignar s join mv_ll165 m on m.id = s.llamada_id where s.cliente_id is distinct from m.queda_id;
  if v_n > 0 then raise exception 'cs 165: % punteros de cs_fathom_sin_asignar sin actualizar', v_n; end if;

  -- última llamada (vista): la de la vigente debería ser la mayor entre la anterior y la mayor de las movidas.
  -- Solo AVISA (no frena): para un alumno grupal la vista (157) mide por asistencia a consultorías y no por llamadas.
  if to_regclass('public.cs_v_ultima_llamada') is not null then
    select string_agg(left(u.queda_id::text, 8), ', ') into v_mal
    from ult165 u
    where (select max(v.ultima_llamada) from public.cs_v_ultima_llamada v where v.cliente_id = u.queda_id)
          is distinct from greatest(u.antes, u.mueve);
    if v_mal is not null then
      raise notice 'cs 165: la última llamada de la vista no es la esperada para (revisar con C4; puede ser alumno grupal): %', v_mal;
    end if;
  end if;

  -- los 5 triggers quedaron habilitados ('O' = origin)
  select string_agg(r.trigger, ', ') into v_mal
  from trg165 r
  join pg_trigger g on g.tgrelid = ('public.' || r.tabla)::regclass and g.tgname = r.trigger
  where g.tgenabled <> 'O';
  if v_mal is not null then raise exception 'cs 165: triggers que quedaron deshabilitados: %', v_mal; end if;
  select count(*) into v_n from trg165 r
  join pg_trigger g on g.tgrelid = ('public.' || r.tabla)::regclass and g.tgname = r.trigger and g.tgenabled = 'O';
  if v_n <> (select count(*) from trg165) then raise exception 'cs 165: faltan triggers'; end if;

  -- RLS del respaldo (y de todas las cs_bak_*, como dejó la 164)
  select count(*) into v_n from pg_tables where schemaname = 'public' and tablename like 'cs\_bak\_%' and not rowsecurity;
  if v_n <> 0 then raise exception 'cs 165: quedan % tablas cs_bak_* sin RLS', v_n; end if;

  -- aviso (no frena): si alguna vez se agrega una columna que guarde la última llamada en cs_clientes
  select string_agg(column_name, ', ') into v_mal from information_schema.columns
   where table_schema = 'public' and table_name = 'cs_clientes' and column_name ~* '(ultima|last).*(llamada|call)';
  if v_mal is not null then raise notice 'cs 165: cs_clientes tiene columnas de última llamada (%): revisar si hay que recalcularlas', v_mal; end if;
end $$;

commit;


-- =====================================================================
-- CONTROLES (comentados; correr de a uno DESPUÉS del commit; sin nombres de alumnos)
-- =====================================================================
-- C1. Conteos por ficha cerrada y vigente (esperado: cerradas solo con las llamadas duplicadas; vigentes con las suyas + las movidas).
-- select left(c.id::text, 8) as ficha, (c.campos_extra ? 'cierre164') as cerrada,
--        (select count(*) from public.cs_llamadas x where x.cliente_id = c.id) as llamadas,
--        (select count(*) from public.cs_llamada_accionables x where x.cliente_id = c.id) as acc_llamada,
--        (select count(*) from public.cs_llamada_recursos x where x.cliente_id = c.id) as recursos,
--        (select count(*) from public.cs_llamada_transcripciones x where x.cliente_id = c.id) as transcripciones,
--        (select count(*) from public.cs_duda_candidatas x where x.cliente_id = c.id) as candidatas,
--        (select count(*) from public.cs_duda_menciones x where x.cliente_id = c.id) as menciones,
--        (select count(*) from public.cs_wins x where x.cliente_id = c.id) as wins,
--        (select count(*) from public.cs_satisf_envios x where x.cliente_id = c.id) as satisfaccion,
--        (select count(*) from public.cs_onboardings x where x.cliente_id = c.id) as onboardings,
--        (select count(*) from public.cs_consultoria_asistentes x where x.cliente_id = c.id) as consultorias
-- from public.cs_clientes c
-- where c.id::text like any (array['e4c8102a%','28d200e3%','be2a3e68%','5955e47d%','2375ab58%','17d1c875%']) order by 1;
--
-- C2. Qué se movió, por tabla (suma de lo respaldado).
-- select tabla, count(*) as filas, count(distinct cliente_id_despues) as vigentes from public.cs_bak_165_hijos group by 1 order by 1;
--
-- C3. Los 5 triggers habilitados (esperado: 5 filas, todas 'O').
-- select c.relname as tabla, g.tgname, g.tgenabled
-- from pg_trigger g join pg_class c on c.oid = g.tgrelid
-- where not g.tgisinternal and c.relnamespace = 'public'::regnamespace
--   and g.tgname in ('cs_llamadas_before', 'cs_llamada_acc_before', 'cs_llamada_rec_before', 'cs_duda_menciones_before', 'cs_wins_before')
-- order by 1;
--
-- C4. Última llamada de las 3 vigentes y las 3 cerradas (la vista; "días sin llamada" sale de acá).
-- select left(u.cliente_id::text, 8) as ficha, u.ultima_llamada, u.fuente, (current_date - u.ultima_llamada) as dias
-- from public.cs_v_ultima_llamada u
-- where u.cliente_id::text like any (array['e4c8102a%','28d200e3%','be2a3e68%','5955e47d%','2375ab58%','17d1c875%']) order by 1;
--
-- C5. Lo que se quedó en las cerradas (esperado: 0 filas, o solo las llamadas duplicadas que se decidieron dejar). Mirar a mano.
-- select left(l.cliente_id::text, 8) as cerrada, l.fecha, l.titulo, l.fuente, l.externo_id is not null as de_fathom, left(l.id::text, 8) as llamada
-- from public.cs_llamadas l where l.cliente_id::text like any (array['e4c8102a%','be2a3e68%','2375ab58%']) order by 1, 2;
--
-- C6. Lo que NO se movió a propósito (informativo): alertas sin resolver, calls viejas, wins / envíos / menciones que chocaron.
-- select left(c.id::text, 8) as cerrada,
--        (select count(*) from public.cs_alertas x where x.cliente_id = c.id and not x.resuelta) as alertas_sin_resolver,
--        (select count(*) from public.cs_calls x where x.cliente_id = c.id) as calls_viejas,
--        (select count(*) from public.cs_wins x where x.cliente_id = c.id) as wins_que_quedaron,
--        (select count(*) from public.cs_satisf_envios x where x.cliente_id = c.id) as envios_que_quedaron,
--        (select count(*) from public.cs_duda_menciones x where x.cliente_id = c.id) as menciones_que_quedaron,
--        (select count(*) from public.cs_onboardings x where x.cliente_id = c.id) as onboardings_que_quedaron
-- from public.cs_clientes c where c.campos_extra ? 'cierre164' order by 1;
--
-- C7. Integridad: ninguna hija con otro alumno que su llamada (esperado: 0 en las tres).
-- select (select count(*) from public.cs_llamada_accionables a join public.cs_llamadas l on l.id = a.llamada_id where l.cliente_id <> a.cliente_id) as acc,
--        (select count(*) from public.cs_llamada_transcripciones a join public.cs_llamadas l on l.id = a.llamada_id where l.cliente_id <> a.cliente_id) as transc,
--        (select count(*) from public.cs_duda_candidatas a join public.cs_llamadas l on l.id = a.llamada_id where l.cliente_id <> a.cliente_id) as cand;
--
-- C8. RLS del respaldo (esperado: rowsecurity = true; 0 filas en políticas).
-- select tablename, rowsecurity from pg_tables where schemaname = 'public' and tablename = 'cs_bak_165_hijos';
-- select policyname from pg_policies where schemaname = 'public' and tablename = 'cs_bak_165_hijos';


-- =====================================================================
-- VUELTA ATRÁS (comentada; correr completa y en una sola transacción, solo si hace falta)
-- =====================================================================
-- Devuelve cada fila respaldada a su ficha cerrada (cliente_id_antes). Mismo método que la ida: triggers apagados solo
-- dentro de la transacción y llamada + hijas en una sola sentencia. Lo que se haya cargado DESPUÉS de la 165 en la
-- vigente (llamadas nuevas de Fathom, etc.) no se toca. Los respaldos se dejan (con RLS).
-- begin;
-- set local lock_timeout = '8s';
-- lock table public.cs_clientes, public.cs_llamadas, public.cs_llamada_accionables, public.cs_llamada_recursos,
--   public.cs_llamada_transcripciones, public.cs_duda_candidatas, public.cs_duda_menciones, public.cs_wins,
--   public.cs_satisf_envios, public.cs_onboardings, public.cs_onboarding_respuestas,
--   public.cs_consultoria_asistentes, public.cs_fathom_sin_asignar in share row exclusive mode;
-- alter table public.cs_llamadas disable trigger cs_llamadas_before;
-- alter table public.cs_llamada_accionables disable trigger cs_llamada_acc_before;
-- alter table public.cs_llamada_recursos disable trigger cs_llamada_rec_before;
-- alter table public.cs_duda_menciones disable trigger cs_duda_menciones_before;
-- alter table public.cs_wins disable trigger cs_wins_before;
-- with
--   u_ll   as (update public.cs_llamadas x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_llamadas' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_acc  as (update public.cs_llamada_accionables x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_llamada_accionables' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_rec  as (update public.cs_llamada_recursos x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_llamada_recursos' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_tr   as (update public.cs_llamada_transcripciones x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_llamada_transcripciones' and x.llamada_id = (b.fila->>'llamada_id')::uuid returning x.llamada_id),
--   u_cand as (update public.cs_duda_candidatas x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_duda_candidatas' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_men  as (update public.cs_duda_menciones x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_duda_menciones' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_men0 as (update public.cs_duda_menciones x set llamada_id = (b.fila->>'llamada_id')::uuid from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_duda_menciones_llamada_null' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_sin  as (update public.cs_fathom_sin_asignar x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_fathom_sin_asignar' and x.id = (b.fila->>'id')::uuid returning x.id)
-- select 1;
-- with
--   u_win  as (update public.cs_wins x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_wins' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_env  as (update public.cs_satisf_envios x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_satisf_envios' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_onb  as (update public.cs_onboardings x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_onboardings' and x.id = (b.fila->>'id')::uuid returning x.id),
--   u_resp as (update public.cs_onboarding_respuestas x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_onboarding_respuestas' and x.onboarding_id = (b.fila->>'onboarding_id')::uuid
--                 and x.paso_key = b.fila->>'paso_key' returning x.onboarding_id),
--   u_asis as (update public.cs_consultoria_asistentes x set cliente_id = b.cliente_id_antes from public.cs_bak_165_hijos b
--               where b.tabla = 'cs_consultoria_asistentes' and x.consultoria_id = (b.fila->>'consultoria_id')::uuid
--                 and x.cliente_id = b.cliente_id_despues returning x.consultoria_id)
-- select 1;
-- alter table public.cs_llamadas enable trigger cs_llamadas_before;
-- alter table public.cs_llamada_accionables enable trigger cs_llamada_acc_before;
-- alter table public.cs_llamada_recursos enable trigger cs_llamada_rec_before;
-- alter table public.cs_duda_menciones enable trigger cs_duda_menciones_before;
-- alter table public.cs_wins enable trigger cs_wins_before;
-- -- Verificar C3 antes de dar por buena la vuelta atrás. Para correr la 165 de nuevo hay que vaciar el respaldo:
-- --   delete from public.cs_bak_165_hijos;   (o dropear la tabla), porque la guarda lo detecta como "ya corrida".
-- commit;
