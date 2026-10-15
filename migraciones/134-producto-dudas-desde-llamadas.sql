-- =====================================================================
-- 134 · Producto · dudas frecuentes a partir de las llamadas de Fathom (SIN IA)
-- Número asignado por el jefe. SIN CORRER: el agente no pudo correr SQL.
-- Requiere: 106 (cs_dudas, cs_duda_menciones), 122 (fuente fathom), 124 (consultores, cliente),
--           127 (cs_clientes_alias). No toca Fathom (cs_fathom_*), Finanzas, cs_servicio_*, 128/130/133.
--
-- Qué hace
--   1. cs_duda_candidatas: preguntas del ALUMNO detectadas en la transcripción de una llamada de
--      Fathom ya asignada a un alumno. Estado pendiente / agregada / descartada. Única por
--      (llamada, texto normalizado): reprocesar no duplica ni pisa lo ya decidido.
--   2. cs_dudas_procesadas: qué llamadas ya se leyeron (y con qué resultado). Sirve para el
--      botón "Reprocesar" y para saber cuántas faltan.
--   3. Detección por reglas (sin modelo):
--        cs_dudas_hablantes(llamada)  quién habla: alumno / consultor / otro
--        cs_dudas_extraer(llamada)    las oraciones candidatas (no escribe)
--        cs_dudas_detectar_llamada    inserta candidatas + marca la llamada como procesada
--      Se corre sola al entrar la transcripción (trigger sobre cs_llamada_transcripciones, con
--      excepción atrapada: si falla NO frena a Fathom ni a nadie) y a mano con cs_dudas_reprocesar
--      (solo fundador, en tandas de 40 llamadas).
--   4. Acciones (RPC, security definer, permiso adentro): cs_duda_cand_agregar (suma una mención a
--      una duda existente), cs_duda_cand_crear (duda nueva con texto editable + mención),
--      cs_duda_cand_descartar (varias), cs_duda_cand_reabrir.
--   5. Lugar para una IA futura (no implementado): origen_sugerencia ('manual' | 'regla' | 'ia') en
--      cs_dudas y en cs_duda_candidatas, y en candidatas duda_sugerida_id y texto_sugerido (null hoy).
--
-- Permisos
--   Ver candidatas: cs_puede_ver(programa) (misma regla que la ficha y que cs_llamadas).
--   Agregar / crear / descartar / reabrir: fundador, rol cliente con acceso al programa, o edición.
--   Reprocesar: solo fundador. La tabla no acepta escrituras directas (solo por las RPC).
--
-- Regla de detección: ver cs_dudas_extraer (comentario de la función) y la nota de ESTADO-APP.
-- No usa pg_trgm: la similitud para sugerir dudas parecidas se calcula en el navegador.
-- Correr fuera de :00/:15/:30/:45 y de las 9:00. No manda nada a Discord ni escribe datos reales
-- (no hace backfill: las candidatas de llamadas viejas aparecen al apretar "Reprocesar").
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Autochequeo
do $$
declare
  v_falta text;
begin
  select string_agg(r.f, ', ') into v_falta
  from (values
    ('cs_hoy()'), ('es_fundador()'), ('cs_puede_ver(text)'), ('cs_puede_editar(text)'),
    ('cs_norm_nombre(text)'), ('cs_tg_updated_at()'), ('cs_fathom_es_cliente_de(uuid,text)')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 134: faltan funciones (corrieron 070, 106 y 124?): %', v_falta;
  end if;
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_programas'), ('cs_clientes'), ('cs_llamadas'), ('cs_llamada_transcripciones'),
               ('cs_dudas'), ('cs_duda_menciones'), ('cs_clientes_alias'), ('cs_fathom_consultores')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 134: faltan tablas (106, 122, 124, 127): %', v_falta;
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'cs_llamadas' and column_name in ('fuente', 'consultor')) <> 2 then
    raise exception 'cs 134: cs_llamadas no tiene fuente y consultor (122 y 124)';
  end if;
end $$;

lock table public.cs_programas, public.cs_clientes, public.cs_llamadas,
           public.cs_llamada_transcripciones, public.cs_dudas, public.cs_duda_menciones
  in share row exclusive mode;


-- =====================================================================
-- 1. Tablas
-- =====================================================================
alter table public.cs_dudas
  add column if not exists origen_sugerencia text not null default 'manual'
    check (origen_sugerencia in ('manual', 'regla', 'ia'));
comment on column public.cs_dudas.origen_sugerencia is
  '134: como se armo la duda. manual = escrita por una persona; regla = salio de una candidata detectada por reglas; ia = reservado para cuando haya IA.';

create table if not exists public.cs_duda_candidatas (
  id                uuid primary key default gen_random_uuid(),
  programa_id       text not null references public.cs_programas(id),
  cliente_id        uuid not null,
  llamada_id        uuid not null,
  fecha             date not null,
  consultor         text,
  hablante          text not null,
  texto             text not null check (btrim(texto) <> '' and char_length(texto) <= 300),
  texto_norm        text generated always as (public.cs_norm_nombre(texto)) stored,
  regla             text not null check (regla in ('signo', 'palabra')),
  estado            text not null default 'pendiente' check (estado in ('pendiente', 'agregada', 'descartada')),
  duda_id           uuid references public.cs_dudas(id) on delete set null,
  origen_sugerencia text not null default 'regla' check (origen_sugerencia in ('manual', 'regla', 'ia')),
  duda_sugerida_id  uuid references public.cs_dudas(id) on delete set null,   -- reservado: agrupacion propuesta por una IA
  texto_sugerido    text check (texto_sugerido is null or char_length(texto_sugerido) <= 300), -- reservado: redaccion propuesta por una IA
  created_at        timestamptz not null default now(),
  resuelta_at       timestamptz,
  resuelta_por      uuid,
  constraint cs_duda_cand_texto_norm_chk check (texto_norm is not null),
  constraint cs_duda_cand_llamada_fk foreign key (llamada_id, cliente_id)
    references public.cs_llamadas (id, cliente_id) on delete cascade,
  constraint cs_duda_cand_cliente_fk foreign key (cliente_id, programa_id)
    references public.cs_clientes (id, programa_id) on delete cascade
);
create unique index if not exists cs_duda_cand_llamada_texto_uk
  on public.cs_duda_candidatas (llamada_id, texto_norm);
create index if not exists cs_duda_cand_programa_idx
  on public.cs_duda_candidatas (programa_id, estado, fecha desc);
create index if not exists cs_duda_cand_cliente_idx on public.cs_duda_candidatas (cliente_id);
comment on table public.cs_duda_candidatas is
  '134: preguntas del alumno detectadas por reglas en la transcripcion de una llamada de Fathom. Una persona las agrega a una duda, crea una duda nueva o las descarta. Sin IA.';

create table if not exists public.cs_dudas_procesadas (
  llamada_id    uuid primary key references public.cs_llamadas(id) on delete cascade,
  programa_id   text not null references public.cs_programas(id),
  procesada_at  timestamptz not null default now(),
  estado        text not null check (estado in ('ok', 'sin_hablante', 'sin_formato')),
  candidatas    int not null default 0
);
create index if not exists cs_dudas_procesadas_programa_idx on public.cs_dudas_procesadas (programa_id);
comment on table public.cs_dudas_procesadas is
  '134: llamadas ya leidas por el detector. sin_hablante = ninguna voz se pudo atribuir al alumno; sin_formato = la transcripcion no tiene el formato [hora] Nombre: texto.';

alter table public.cs_duda_candidatas enable row level security;
revoke all on table public.cs_duda_candidatas from anon, authenticated;
grant select on table public.cs_duda_candidatas to authenticated;
drop policy if exists cs_select on public.cs_duda_candidatas;
create policy cs_select on public.cs_duda_candidatas for select to authenticated
  using (public.cs_puede_ver(programa_id));

alter table public.cs_dudas_procesadas enable row level security;
revoke all on table public.cs_dudas_procesadas from anon, authenticated;
grant select on table public.cs_dudas_procesadas to authenticated;
drop policy if exists cs_select on public.cs_dudas_procesadas;
create policy cs_select on public.cs_dudas_procesadas for select to authenticated
  using (public.cs_puede_ver(programa_id));


-- =====================================================================
-- 2. Quién habla en la llamada
-- =====================================================================
-- Formato de la transcripcion (fathom-sync, textoTranscripcion): una linea por intervencion,
-- "[hh:mm:ss] Nombre visible: texto". Rol de cada hablante:
--   consultor: todas sus palabras (3+ letras) estan en el nombre del consultor de la llamada o en su id;
--   alumno:    comparte al menos una palabra (3+ letras) con el nombre del alumno o con sus alias;
--   otro:      el resto. Si nadie matchea como alumno y hay UN solo 'otro', ese es el alumno (1 a 1).
create or replace function public.cs_dudas_hablantes(p_llamada uuid)
returns table (hablante text, lineas int, rol text)
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_texto text;
  v_cli   uuid;
  v_cons  text;
  v_alu   text[];
  v_con   text[];
  v_stop  text[] := array['del', 'los', 'las', 'van', 'von', 'dos', 'das', 'con', 'por'];
begin
  select t.texto, l.cliente_id, l.consultor
    into v_texto, v_cli, v_cons
  from public.cs_llamadas l
  join public.cs_llamada_transcripciones t on t.llamada_id = l.id
  where l.id = p_llamada and l.fuente = 'fathom';
  if v_texto is null then
    return;
  end if;

  select coalesce(array_agg(distinct x.w), '{}') into v_alu
  from (
    select unnest(string_to_array(public.cs_norm_nombre(c.nombre), ' ')) as w
      from public.cs_clientes c where c.id = v_cli
    union all
    select unnest(string_to_array(a.alias, ' ')) as w
      from public.cs_clientes_alias a where a.cliente_id = v_cli
  ) x
  where char_length(x.w) >= 3 and x.w <> all (v_stop);

  select coalesce(array_agg(distinct x.w), '{}') into v_con
  from (
    select unnest(string_to_array(public.cs_norm_nombre(k.nombre), ' ')) as w
      from public.cs_fathom_consultores k where k.id = v_cons
    union all
    select v_cons
  ) x
  where x.w is not null and char_length(x.w) >= 3;

  return query
  with l as (
    select btrim((regexp_match(ln, '^\[[^\]]*\]\s*([^:]{1,80}):\s*\S'))[1]) as quien
    from regexp_split_to_table(v_texto, E'\r?\n') ln
  ),
  sp as (
    select l.quien, count(*)::int as cant from l where l.quien is not null group by l.quien
  ),
  w as (
    select sp.quien, sp.cant,
           array(select p from unnest(string_to_array(public.cs_norm_nombre(sp.quien), ' ')) p
                  where char_length(p) >= 3 and p <> all (v_stop)) as ws
    from sp
  ),
  r as (
    select w.quien, w.cant,
           case when cardinality(w.ws) > 0 and w.ws <@ v_con then 'consultor'
                when w.ws && v_alu then 'alumno'
                else 'otro' end as papel
    from w
  )
  select r.quien, r.cant,
         case when r.papel = 'otro'
                   and not exists (select 1 from r r2 where r2.papel = 'alumno')
                   and (select count(*) from r r3 where r3.papel = 'otro') = 1
              then 'alumno' else r.papel end
  from r;
end;
$fn$;


-- =====================================================================
-- 3. Extraer preguntas (no escribe)
-- =====================================================================
-- REGLA (solo lineas del alumno; se parte cada linea en oraciones en . ! ? …):
--   - si la oracion trae "¿", se toma desde el ULTIMO "¿" (descarta el saludo de antes);
--   - se normaliza (sin acentos ni signos) y se sacan muletillas del inicio (eh, bueno, y, pero,
--     "una pregunta", "queria saber"…);
--   - regla 'signo':   termina en "?" y tiene 4 palabras o mas; no se acepta si es solo una
--                      muletilla de confirmacion al final ("…, no?", "…, viste?") sin palabra
--                      interrogativa al inicio;
--   - regla 'palabra': NO termina en "?" pero empieza con una palabra de pregunta (como, que,
--                      cuando, donde, por que, cuanto/a/os/as, cual/es, quien/es, se puede, hay que,
--                      puedo, podria, podemos, podes, puedes, tengo que, debo, deberia, conviene,
--                      es posible, existe, hay alguna/algun/forma/manera) y tiene 5 palabras o mas;
--   - se descartan las de ruido de la llamada (me escuchas, se corta, camara, microfono, audio…) y
--     las que no son preguntas ("como te decia…", "que bueno…", "cuando quieras…");
--   - largo maximo 300 caracteres.
create or replace function public.cs_dudas_extraer(p_llamada uuid)
returns table (hablante text, texto text, regla text)
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_texto text;
begin
  select t.texto into v_texto
  from public.cs_llamadas l
  join public.cs_llamada_transcripciones t on t.llamada_id = l.id
  where l.id = p_llamada and l.fuente = 'fathom';
  if v_texto is null then
    return;
  end if;

  return query
  with al as (
    select h.hablante as quien from public.cs_dudas_hablantes(p_llamada) h where h.rol = 'alumno'
  ),
  ln as (
    select btrim(m[1]) as quien, btrim(m[2]) as txt
    from regexp_split_to_table(v_texto, E'\r?\n') x,
         lateral (select regexp_match(x, '^\[[^\]]*\]\s*([^:]{1,80}):\s*(.*)$') as m) q
    where q.m is not null
  ),
  se as (
    select ln.quien, btrim(s.s) as s
    from ln, lateral regexp_split_to_table(ln.txt, '(?<=[.!?…])\s+') as s(s)
    where ln.quien in (select al.quien from al)
  ),
  q as (
    select se.quien,
           btrim(case when position('¿' in se.s) > 0 then substring(se.s from '¿[^¿]*$') else se.s end) as s2
    from se
  ),
  n as (
    select q.quien, q.s2,
           public.cs_norm_nombre(q.s2) as nn,
           (q.s2 ~ '\?[\s"”)]*$') as con_signo
    from q
  ),
  k as (
    select n.*,
           regexp_replace(n.nn,
             '^((eh|em|este|bueno|pero|y|o|entonces|mira|che|ok|dale|osea|o sea|igual|ah|a ver|disculpa|perdon|una pregunta|una duda|te queria preguntar|queria preguntar|queria saber) )+',
             '') as n2
    from n
    where n.nn is not null
  ),
  z as (
    select k.*,
           coalesce(array_length(string_to_array(k.n2, ' '), 1), 0) as nw,
           (k.n2 ~ '^(como|que|cuando|donde|por que|cuanto|cuanta|cuantos|cuantas|cual|cuales|quien|quienes|se puede|se pueden|hay que|puedo|podria|podemos|podes|puedes|tengo que|debo|deberia|conviene|es posible|existe|hay alguna|hay algun|hay forma|hay manera)( |$)') as empieza,
           (k.nn ~ '\m(escuch|oyen|oyes|congel|microfon|camar|conexion|audio)' or k.nn ~ '\m(me|se) ves?\M') as ruido,
           (k.n2 ~ '^(como (te|les|le|ya|dije|dijimos|vimos|siempre|quedamos|hablamos|mencione|comentaba|decia)|que (bueno|lindo|bien|genial|barbaro|se yo|tal|loco|mal|pena|raro)|cuando (quieras|puedas)|donde (quieras|sea))') as no_preg,
           (k.nn ~ ' (no|si|verdad|cierto|viste|entendes|entiendes|ok|dale|te parece)$') as tag
    from k
  )
  select z.quien, left(btrim(z.s2), 300),
         case when z.con_signo then 'signo' else 'palabra' end
  from z
  where not z.ruido and not z.no_preg
    and ((z.con_signo and z.nw >= 4 and (z.empieza or not z.tag))
         or (not z.con_signo and z.empieza and z.nw >= 5));
end;
$fn$;


-- =====================================================================
-- 4. Detectar (escribe) y reprocesar
-- =====================================================================
create or replace function public.cs_dudas_detectar_llamada(p_llamada uuid)
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_ll     record;
  v_nuevas int := 0;
  v_tot    int;
  v_alu    int;
  v_estado text;
begin
  select l.id, l.cliente_id, l.programa_id, l.fecha, l.consultor, l.fuente
    into v_ll from public.cs_llamadas l where l.id = p_llamada;
  if not found or v_ll.fuente <> 'fathom' then
    return 0;
  end if;
  if not exists (select 1 from public.cs_llamada_transcripciones t where t.llamada_id = p_llamada) then
    return 0;
  end if;

  insert into public.cs_duda_candidatas (programa_id, cliente_id, llamada_id, fecha, consultor, hablante, texto, regla)
  select v_ll.programa_id, v_ll.cliente_id, v_ll.id, v_ll.fecha, v_ll.consultor, e.hablante, e.texto, e.regla
  from public.cs_dudas_extraer(p_llamada) e
  on conflict (llamada_id, texto_norm) do nothing;
  get diagnostics v_nuevas = row_count;

  select count(*), count(*) filter (where h.rol = 'alumno') into v_tot, v_alu
  from public.cs_dudas_hablantes(p_llamada) h;
  v_estado := case when v_tot = 0 then 'sin_formato' when v_alu = 0 then 'sin_hablante' else 'ok' end;

  insert into public.cs_dudas_procesadas (llamada_id, programa_id, procesada_at, estado, candidatas)
  values (p_llamada, v_ll.programa_id, now(), v_estado,
          (select count(*) from public.cs_duda_candidatas c where c.llamada_id = p_llamada))
  on conflict (llamada_id) do update
    set procesada_at = excluded.procesada_at, estado = excluded.estado, candidatas = excluded.candidatas;
  return v_nuevas;
end;
$fn$;

-- Trigger: al entrar o cambiar una transcripcion. Nunca rompe la escritura original.
create or replace function public.cs_tg_dudas_transcripcion()
returns trigger
language plpgsql security definer set search_path = public
as $fn$
begin
  begin
    perform public.cs_dudas_detectar_llamada(new.llamada_id);
  exception when others then
    raise warning 'cs 134: no se pudo detectar dudas de la llamada %: %', new.llamada_id, sqlerrm;
  end;
  return null;
end;
$fn$;
drop trigger if exists cs_dudas_transcripcion_after on public.cs_llamada_transcripciones;
create trigger cs_dudas_transcripcion_after
  after insert or update of texto on public.cs_llamada_transcripciones
  for each row execute function public.cs_tg_dudas_transcripcion();

-- Botón "Reprocesar" (solo fundador). Una tanda de hasta p_limite llamadas por vez; la pantalla
-- repite hasta que restantes = 0 pasando el mismo corte. Reprocesar es idempotente: lo ya decidido
-- (agregada / descartada) no se toca y nada se duplica.
create or replace function public.cs_dudas_reprocesar(
  p_programa text,
  p_corte    timestamptz default null,
  p_limite   int default 40
)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_corte    timestamptz := coalesce(p_corte, now());
  v_limite   int := least(greatest(coalesce(p_limite, 40), 1), 100);
  v_id       uuid;
  v_procesadas int := 0;
  v_nuevas   int := 0;
  v_rest     int;
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador reprocesa las dudas' using errcode = '42501';
  end if;
  if not exists (select 1 from public.cs_programas p where p.id = p_programa) then
    raise exception 'cs: programa inexistente' using errcode = '22023';
  end if;

  for v_id in
    select l.id
    from public.cs_llamadas l
    join public.cs_llamada_transcripciones t on t.llamada_id = l.id
    where l.programa_id = p_programa and l.fuente = 'fathom'
      and not exists (select 1 from public.cs_dudas_procesadas x
                       where x.llamada_id = l.id and x.procesada_at >= v_corte)
    order by l.fecha desc, l.id
    limit v_limite
  loop
    v_nuevas := v_nuevas + public.cs_dudas_detectar_llamada(v_id);
    v_procesadas := v_procesadas + 1;
  end loop;

  select count(*) into v_rest
  from public.cs_llamadas l
  join public.cs_llamada_transcripciones t on t.llamada_id = l.id
  where l.programa_id = p_programa and l.fuente = 'fathom'
    and not exists (select 1 from public.cs_dudas_procesadas x
                     where x.llamada_id = l.id and x.procesada_at >= v_corte);
  return jsonb_build_object('corte', v_corte, 'procesadas', v_procesadas, 'nuevas', v_nuevas, 'restantes', v_rest);
end;
$fn$;

-- Conteos para la pantalla (quien ve el programa).
create or replace function public.cs_dudas_estado(p_programa text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
begin
  if not coalesce(public.cs_puede_ver(p_programa), false) then
    raise exception 'cs: sin acceso al programa' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'pendientes',  (select count(*) from public.cs_duda_candidatas c where c.programa_id = p_programa and c.estado = 'pendiente'),
    'agregadas',   (select count(*) from public.cs_duda_candidatas c where c.programa_id = p_programa and c.estado = 'agregada'),
    'descartadas', (select count(*) from public.cs_duda_candidatas c where c.programa_id = p_programa and c.estado = 'descartada'),
    'llamadas',    (select count(*) from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
                     where l.programa_id = p_programa and l.fuente = 'fathom'),
    'sin_procesar',(select count(*) from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
                     where l.programa_id = p_programa and l.fuente = 'fathom'
                       and not exists (select 1 from public.cs_dudas_procesadas x where x.llamada_id = l.id)),
    'sin_hablante',(select count(*) from public.cs_dudas_procesadas x
                     where x.programa_id = p_programa and x.estado <> 'ok'));
end;
$fn$;


-- =====================================================================
-- 5. Acciones sobre candidatas
-- =====================================================================
create or replace function public.cs_duda_puede_gestionar(p_programa text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
      or coalesce(public.cs_fathom_es_cliente_de(auth.uid(), p_programa), false)
      or coalesce(public.cs_puede_editar(p_programa), false)
$$;

-- Suma una mencion (alumno y fecha de la llamada) a una duda existente del mismo programa.
create or replace function public.cs_duda_cand_agregar(p_candidata uuid, p_duda uuid)
returns uuid
language plpgsql security definer set search_path = public
as $fn$
declare
  c public.cs_duda_candidatas;
begin
  select * into c from public.cs_duda_candidatas where id = p_candidata for update;
  if not found then
    raise exception 'cs: la pregunta ya no existe' using errcode = '22023';
  end if;
  if not public.cs_duda_puede_gestionar(c.programa_id) then
    raise exception 'cs: sin permiso para gestionar las dudas de este programa' using errcode = '42501';
  end if;
  if c.estado <> 'pendiente' then
    raise exception 'cs: esa pregunta ya esta resuelta (%)', c.estado using errcode = '22023';
  end if;
  if p_duda is null or not exists (select 1 from public.cs_dudas d where d.id = p_duda and d.programa_id = c.programa_id) then
    raise exception 'cs: la duda no existe en este programa' using errcode = '22023';
  end if;

  insert into public.cs_duda_menciones (programa_id, duda_id, cliente_id, fecha, origen, llamada_id)
  values (c.programa_id, p_duda, c.cliente_id, c.fecha, 'llamada', c.llamada_id)
  on conflict (duda_id, cliente_id, fecha) do nothing;

  update public.cs_duda_candidatas
     set estado = 'agregada', duda_id = p_duda, resuelta_at = now(), resuelta_por = auth.uid()
   where id = p_candidata;
  return p_duda;
end;
$fn$;

-- Duda nueva con el texto editado (o el de la candidata) + la mencion. Si ya hay una duda con el
-- mismo texto normalizado en el programa, se usa esa (no se duplica).
create or replace function public.cs_duda_cand_crear(p_candidata uuid, p_texto text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  c       public.cs_duda_candidatas;
  v_texto text;
  v_norm  text;
  v_duda  uuid;
  v_nueva boolean := false;
begin
  select * into c from public.cs_duda_candidatas where id = p_candidata for update;
  if not found then
    raise exception 'cs: la pregunta ya no existe' using errcode = '22023';
  end if;
  if not public.cs_duda_puede_gestionar(c.programa_id) then
    raise exception 'cs: sin permiso para gestionar las dudas de este programa' using errcode = '42501';
  end if;
  if c.estado <> 'pendiente' then
    raise exception 'cs: esa pregunta ya esta resuelta (%)', c.estado using errcode = '22023';
  end if;

  v_texto := btrim(coalesce(nullif(btrim(p_texto), ''), c.texto));
  if char_length(v_texto) > 300 then
    raise exception 'cs: la duda no puede pasar de 300 caracteres' using errcode = '22023';
  end if;
  v_norm := public.cs_norm_nombre(v_texto);
  if v_norm is null then
    raise exception 'cs: escribi la duda' using errcode = '22023';
  end if;

  select d.id into v_duda from public.cs_dudas d
   where d.programa_id = c.programa_id and d.texto_norm = v_norm;
  if v_duda is null then
    insert into public.cs_dudas (programa_id, texto, origen, origen_sugerencia)
    values (c.programa_id, v_texto, 'llamada', 'regla')
    returning id into v_duda;
    v_nueva := true;
  end if;

  insert into public.cs_duda_menciones (programa_id, duda_id, cliente_id, fecha, origen, llamada_id)
  values (c.programa_id, v_duda, c.cliente_id, c.fecha, 'llamada', c.llamada_id)
  on conflict (duda_id, cliente_id, fecha) do nothing;

  update public.cs_duda_candidatas
     set estado = 'agregada', duda_id = v_duda, resuelta_at = now(), resuelta_por = auth.uid()
   where id = p_candidata;
  return jsonb_build_object('duda_id', v_duda, 'nueva', v_nueva);
end;
$fn$;

-- Descarta varias pendientes. Devuelve cuantas descartó (las que no puede gestionar no se tocan).
create or replace function public.cs_duda_cand_descartar(p_ids uuid[])
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_n int;
begin
  update public.cs_duda_candidatas c
     set estado = 'descartada', resuelta_at = now(), resuelta_por = auth.uid()
   where c.id = any (coalesce(p_ids, '{}'))
     and c.estado = 'pendiente'
     and public.cs_duda_puede_gestionar(c.programa_id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;

create or replace function public.cs_duda_cand_reabrir(p_candidata uuid)
returns boolean
language plpgsql security definer set search_path = public
as $fn$
declare
  v_n int;
begin
  update public.cs_duda_candidatas c
     set estado = 'pendiente', resuelta_at = null, resuelta_por = null
   where c.id = p_candidata and c.estado = 'descartada'
     and public.cs_duda_puede_gestionar(c.programa_id);
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$fn$;

-- Permisos: extraer / hablantes / detectar son internas (las usan las funciones de arriba y el SQL Editor).
revoke all on function public.cs_dudas_hablantes(uuid) from public, anon, authenticated;
revoke all on function public.cs_dudas_extraer(uuid) from public, anon, authenticated;
revoke all on function public.cs_dudas_detectar_llamada(uuid) from public, anon, authenticated;
revoke all on function public.cs_tg_dudas_transcripcion() from public, anon, authenticated;
revoke all on function public.cs_dudas_reprocesar(text, timestamptz, int) from public, anon;
revoke all on function public.cs_dudas_estado(text) from public, anon;
revoke all on function public.cs_duda_puede_gestionar(text) from public, anon;
revoke all on function public.cs_duda_cand_agregar(uuid, uuid) from public, anon;
revoke all on function public.cs_duda_cand_crear(uuid, text) from public, anon;
revoke all on function public.cs_duda_cand_descartar(uuid[]) from public, anon;
revoke all on function public.cs_duda_cand_reabrir(uuid) from public, anon;
grant execute on function public.cs_dudas_reprocesar(text, timestamptz, int) to authenticated;
grant execute on function public.cs_dudas_estado(text) to authenticated;
grant execute on function public.cs_duda_puede_gestionar(text) to authenticated;
grant execute on function public.cs_duda_cand_agregar(uuid, uuid) to authenticated;
grant execute on function public.cs_duda_cand_crear(uuid, text) to authenticated;
grant execute on function public.cs_duda_cand_descartar(uuid[]) to authenticated;
grant execute on function public.cs_duda_cand_reabrir(uuid) to authenticated;


-- =====================================================================
-- 6. PRUEBA DE HUMO (se revierte sola; no manda nada a Discord)
-- =====================================================================
do $$
declare
  v_c     record;
  v_fund  uuid;
  v_ll    uuid := gen_random_uuid();
  v_n     int;
  v_ids   uuid[];
  v_c1    uuid;
  v_c2    uuid;
  v_c3    uuid;
  v_duda  uuid;
  v_j     jsonb;
  v_ok    boolean;
begin
  begin
    select c.id, c.programa_id, c.nombre into v_c
      from public.cs_clientes c
     where public.cs_norm_nombre(c.nombre) ~ '[a-z]{3}' and position(':' in c.nombre) = 0
       and char_length(c.nombre) <= 80
     order by c.created_at limit 1;
    if not found then
      raise notice 'smoke 134: no hay alumnos; se omite la parte con datos';
      raise exception 'SMOKE_OK';
    end if;

    insert into public.cs_llamadas (id, programa_id, cliente_id, fecha, titulo, externo_id, fuente)
    values (v_ll, v_c.programa_id, v_c.id, public.cs_hoy() - 1, 'Humo 134', 'smoke134:' || v_ll::text, 'fathom');

    -- el trigger corre solo al entrar la transcripcion
    insert into public.cs_llamada_transcripciones (llamada_id, programa_id, cliente_id, texto)
    values (v_ll, v_c.programa_id, v_c.id,
      '[00:00:01] Coach Humo: ¿Cómo te fue con el reel de la semana pasada?' || E'\n' ||
      '[00:00:09] ' || v_c.nombre || ': Hola, ¿cómo hago para subir un reel de humo? Bueno perfecto gracias.' || E'\n' ||
      '[00:00:20] ' || v_c.nombre || ': Cómo configuro el pixel de mi tienda de humo' || E'\n' ||
      '[00:00:30] ' || v_c.nombre || ': ¿Me escuchas bien? ¿Sí? Esto sale así, ¿no? Qué bueno que llegamos hasta acá.' || E'\n' ||
      '[00:00:40] ' || v_c.nombre || ': ¿Cuánto tarda en aprobar la cuenta publicitaria?');

    -- 1. hablantes: el alumno y el otro
    select count(*) into v_n from public.cs_dudas_hablantes(v_ll) h where h.rol = 'alumno' and h.hablante = v_c.nombre;
    if v_n <> 1 then raise exception 'smoke 134: hablante alumno = %', v_n; end if;
    select count(*) into v_n from public.cs_dudas_hablantes(v_ll) h where h.hablante = 'Coach Humo' and h.rol = 'otro';
    if v_n <> 1 then raise exception 'smoke 134: hablante coach = %', v_n; end if;

    -- 2. exactamente 3 candidatas (2 por signo, 1 por palabra); ni ruido, ni confirmaciones, ni consultor
    select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll;
    if v_n <> 3 then raise exception 'smoke 134: candidatas = % (esperaba 3)', v_n; end if;
    select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll and regla = 'palabra';
    if v_n <> 1 then raise exception 'smoke 134: por palabra = % (esperaba 1)', v_n; end if;
    select count(*) into v_n from public.cs_duda_candidatas
     where llamada_id = v_ll and (texto ilike '%escuch%' or texto ilike '%bueno%' or texto ilike '%reel de la semana%');
    if v_n <> 0 then raise exception 'smoke 134: entraron oraciones que no son del alumno o son ruido (%)', v_n; end if;

    -- 3. idempotencia: reprocesar no duplica
    v_n := public.cs_dudas_detectar_llamada(v_ll);
    if v_n <> 0 then raise exception 'smoke 134: reprocesar agrego % filas', v_n; end if;
    select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll;
    if v_n <> 3 then raise exception 'smoke 134: tras reprocesar hay % (esperaba 3)', v_n; end if;
    select count(*) into v_n from public.cs_dudas_procesadas where llamada_id = v_ll and estado = 'ok' and candidatas = 3;
    if v_n <> 1 then raise exception 'smoke 134: procesada mal marcada'; end if;

    select id into v_c1 from public.cs_duda_candidatas where llamada_id = v_ll and texto ilike '%subir un reel%';
    select id into v_c2 from public.cs_duda_candidatas where llamada_id = v_ll and texto ilike '%pixel%';
    select id into v_c3 from public.cs_duda_candidatas where llamada_id = v_ll and texto ilike '%cuenta publicitaria%';
    if v_c1 is null or v_c2 is null or v_c3 is null then raise exception 'smoke 134: faltan candidatas esperadas'; end if;

    -- 4. sin sesion de fundador, cliente ni edicion no se puede gestionar
    begin
      perform public.cs_duda_cand_crear(v_c1, null);
      raise exception 'smoke 134: sin sesion dejo crear';
    exception when sqlstate '42501' then
      null;
    end;
    if public.cs_duda_cand_descartar(array[v_c3]) <> 0 then
      raise exception 'smoke 134: sin sesion dejo descartar';
    end if;

    -- 5. como fundador
    select m.user_id into v_fund from public.crm_members m where m.rol = 'fundador' limit 1;
    if v_fund is null then
      raise notice 'smoke 134: no hay fundador en crm_members; se omiten las acciones';
    else
      perform set_config('request.jwt.claim.sub', v_fund::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', v_fund, 'role', 'authenticated')::text, true);

      v_j := public.cs_duda_cand_crear(v_c1, 'Como subo un reel (humo 134)');
      v_duda := (v_j ->> 'duda_id')::uuid;
      if v_duda is null or not (v_j ->> 'nueva')::boolean then raise exception 'smoke 134: crear = %', v_j; end if;
      select count(*) into v_n from public.cs_dudas
       where id = v_duda and origen = 'llamada' and origen_sugerencia = 'regla' and texto = 'Como subo un reel (humo 134)';
      if v_n <> 1 then raise exception 'smoke 134: la duda creada no quedo como se esperaba'; end if;
      select count(*) into v_n from public.cs_duda_menciones
       where duda_id = v_duda and cliente_id = v_c.id and fecha = public.cs_hoy() - 1 and llamada_id = v_ll and origen = 'llamada';
      if v_n <> 1 then raise exception 'smoke 134: mencion = %', v_n; end if;

      -- agregar a la existente (mismo alumno y fecha: la mencion no se duplica, la candidata queda agregada)
      perform public.cs_duda_cand_agregar(v_c2, v_duda);
      select count(*) into v_n from public.cs_duda_candidatas where id = v_c2 and estado = 'agregada' and duda_id = v_duda;
      if v_n <> 1 then raise exception 'smoke 134: agregar no marco la candidata'; end if;
      select count(*) into v_n from public.cs_duda_menciones where duda_id = v_duda;
      if v_n <> 1 then raise exception 'smoke 134: menciones tras agregar = % (esperaba 1)', v_n; end if;

      -- una resuelta no se resuelve dos veces
      begin
        perform public.cs_duda_cand_agregar(v_c1, v_duda);
        raise exception 'smoke 134: dejo agregar dos veces';
      exception when sqlstate '22023' then
        null;
      end;

      -- descartar y reabrir
      if public.cs_duda_cand_descartar(array[v_c3]) <> 1 then raise exception 'smoke 134: descartar'; end if;
      if not public.cs_duda_cand_reabrir(v_c3) then raise exception 'smoke 134: reabrir'; end if;

      -- reprocesar no pisa lo decidido
      v_n := public.cs_dudas_detectar_llamada(v_ll);
      select count(*) into v_n from public.cs_duda_candidatas where llamada_id = v_ll and estado = 'agregada';
      if v_n <> 2 then raise exception 'smoke 134: reprocesar pisó estados (agregadas = %)', v_n; end if;

      -- boton Reprocesar (estructura y corte)
      v_j := public.cs_dudas_reprocesar(v_c.programa_id, null, 5);
      if v_j -> 'restantes' is null or v_j -> 'corte' is null then
        raise exception 'smoke 134: reprocesar = %', v_j;
      end if;
      v_j := public.cs_dudas_estado(v_c.programa_id);
      if v_j -> 'pendientes' is null then raise exception 'smoke 134: estado = %', v_j; end if;

      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '', true);
    end if;

    -- 6. permisos
    if has_table_privilege('authenticated', 'public.cs_duda_candidatas', 'insert')
       or has_table_privilege('authenticated', 'public.cs_duda_candidatas', 'update')
       or has_table_privilege('authenticated', 'public.cs_duda_candidatas', 'delete')
       or has_table_privilege('anon', 'public.cs_duda_candidatas', 'select') then
      raise exception 'smoke 134: permisos de tabla incorrectos';
    end if;
    if has_function_privilege('authenticated', 'public.cs_dudas_extraer(uuid)', 'execute')
       or has_function_privilege('authenticated', 'public.cs_dudas_detectar_llamada(uuid)', 'execute')
       or has_function_privilege('anon', 'public.cs_duda_cand_crear(uuid,text)', 'execute') then
      raise exception 'smoke 134: permisos de funcion incorrectos';
    end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 134: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

commit;

-- =====================================================================
-- CONTROLES (de a uno, después de correr)
-- =====================================================================
-- C1. Objetos en su lugar (esperado: 2 tablas, 1 columna, 1 trigger, 11 funciones).
--   select (select count(*) from pg_class where oid in ('public.cs_duda_candidatas'::regclass, 'public.cs_dudas_procesadas'::regclass)) as tablas,
--          (select count(*) from information_schema.columns where table_name = 'cs_dudas' and column_name = 'origen_sugerencia') as columna,
--          (select count(*) from pg_trigger where tgname = 'cs_dudas_transcripcion_after' and not tgisinternal) as trigger,
--          (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in
--             ('cs_dudas_hablantes','cs_dudas_extraer','cs_dudas_detectar_llamada','cs_tg_dudas_transcripcion',
--              'cs_dudas_reprocesar','cs_dudas_estado','cs_duda_puede_gestionar','cs_duda_cand_agregar',
--              'cs_duda_cand_crear','cs_duda_cand_descartar','cs_duda_cand_reabrir')) as funciones;
--
-- C2. CUANTAS candidatas detectaría hoy, por programa (no escribe). Antes de apretar "Reprocesar".
--   select l.programa_id, count(distinct l.id) as llamadas, count(*) as candidatas,
--          count(*) filter (where e.regla = 'signo') as por_signo, count(*) filter (where e.regla = 'palabra') as por_palabra
--   from public.cs_llamadas l
--   join public.cs_llamada_transcripciones t on t.llamada_id = l.id
--   cross join lateral public.cs_dudas_extraer(l.id) e
--   where l.fuente = 'fathom'
--   group by 1 order by 1;
--
-- C3. Llamadas con transcripción por programa y cuántas no tienen ninguna voz atribuida al alumno
--     (esas darían 0 candidatas: revisar el nombre del alumno o sus alias).
--   select l.programa_id, count(*) as llamadas,
--          count(*) filter (where not exists (select 1 from public.cs_dudas_hablantes(l.id) h where h.rol = 'alumno')) as sin_alumno_reconocido
--   from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
--   where l.fuente = 'fathom' group by 1 order by 1;
--
-- C4. Quién habla en las 20 llamadas más recientes (esperado: una fila 'alumno' por llamada; 'consultor' puede faltar).
--   select l.fecha, l.programa_id, h.hablante, h.lineas, h.rol
--   from (select l2.* from public.cs_llamadas l2 join public.cs_llamada_transcripciones t on t.llamada_id = l2.id
--          where l2.fuente = 'fathom' order by l2.fecha desc limit 20) l
--   cross join lateral public.cs_dudas_hablantes(l.id) h order by l.fecha desc, l.id, h.rol;
--
-- C5. MUESTRA para revisar a ojo la calidad de la regla (30 al azar; ajustar la regla si hay muchas falsas).
--   select l.programa_id, e.regla, e.hablante, e.texto
--   from public.cs_llamadas l join public.cs_llamada_transcripciones t on t.llamada_id = l.id
--   cross join lateral public.cs_dudas_extraer(l.id) e
--   where l.fuente = 'fathom' order by random() limit 30;
--
-- C6. Sin duplicados (esperado: 0 filas).
--   select llamada_id, texto_norm, count(*) from public.cs_duda_candidatas group by 1, 2 having count(*) > 1;
--
-- C7. Estado de lo procesado, por programa (después de "Reprocesar").
--   select programa_id, estado, count(*), sum(candidatas) from public.cs_dudas_procesadas group by 1, 2 order by 1, 2;
--
-- C8. Permisos (esperado: authenticated sin insert/update/delete en la tabla; sin execute en las 3 internas).
--   select has_table_privilege('authenticated', 'public.cs_duda_candidatas', 'insert') as ins,
--          has_function_privilege('authenticated', 'public.cs_dudas_extraer(uuid)', 'execute') as extraer,
--          has_function_privilege('authenticated', 'public.cs_dudas_detectar_llamada(uuid)', 'execute') as detectar,
--          has_function_privilege('authenticated', 'public.cs_duda_cand_crear(uuid,text)', 'execute') as crear;
--
-- C9. Las llamadas de Fathom nuevas siguen entrando (el trigger no las frena): comparar con la corrida de
--     la sync de hoy y mirar que `procesada_at` de las nuevas sea de hoy.
--   select l.fecha, l.fuente, p.estado, p.candidatas, p.procesada_at
--   from public.cs_llamadas l left join public.cs_dudas_procesadas p on p.llamada_id = l.id
--   where l.fuente = 'fathom' order by l.created_at desc limit 20;

-- =====================================================================
-- VUELTA ATRÁS (en este orden; no toca ninguna otra tabla ni dato de la 106)
-- =====================================================================
--   begin;
--   drop trigger if exists cs_dudas_transcripcion_after on public.cs_llamada_transcripciones;
--   drop function if exists public.cs_tg_dudas_transcripcion();
--   drop function if exists public.cs_duda_cand_reabrir(uuid);
--   drop function if exists public.cs_duda_cand_descartar(uuid[]);
--   drop function if exists public.cs_duda_cand_crear(uuid, text);
--   drop function if exists public.cs_duda_cand_agregar(uuid, uuid);
--   drop function if exists public.cs_duda_puede_gestionar(text);
--   drop function if exists public.cs_dudas_estado(text);
--   drop function if exists public.cs_dudas_reprocesar(text, timestamptz, int);
--   drop function if exists public.cs_dudas_detectar_llamada(uuid);
--   drop function if exists public.cs_dudas_extraer(uuid);
--   drop function if exists public.cs_dudas_hablantes(uuid);
--   drop table if exists public.cs_dudas_procesadas;
--   drop table if exists public.cs_duda_candidatas;
--   alter table public.cs_dudas drop column if exists origen_sugerencia;
--   commit;
--   -- Las menciones y dudas ya creadas desde candidatas quedan (son datos de la 106). Para borrarlas:
--   --   delete from public.cs_duda_menciones where origen = 'llamada' and llamada_id is not null;  (revisar antes)
