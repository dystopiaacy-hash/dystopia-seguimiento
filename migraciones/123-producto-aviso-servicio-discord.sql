-- =====================================================================
-- 123-producto-aviso-servicio-discord.sql  ·  PRODUCTO: aviso diario de servicio a Discord
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecución).
-- Numeración global asignada por el jefe: 123. Requiere 102 (llamadas), 106 (canales de
-- Discord y satisfacción). Se puede correr dos veces.
-- Correr evitando los minutos :00, :15, :30 y :45 y las 9:00 (cron diario de Producto).
--
-- Qué hace:
--   1. Parámetros por programa en cs_servicio_config: umbral "sin llamada" 7 (aviso, amarillo)
--      y 10 (alerta, rojo), hora del aviso (default 9, hora Argentina), días de atraso para
--      "moroso" (14), días para "accionable de llamada sin completar" (0 = apagado) y la
--      URL de la app para los links. Lectura: quien ve el programa. Escritura: solo fundador.
--      La app (semáforo de Hoy, ficha, Clientes y Maestro) lee estos mismos dos números.
--   2. cs_discord_canales acepta el tipo 'servicio' (webhook por programa, activo,
--      incluir_nombre, incluir_monto = montos de morosos). Se siembran las filas de liam, agus
--      y teo SIN webhook y desactivadas: el webhook lo carga Joaquín desde Configuración.
--   3. Aviso diario de servicio, un mensaje por programa (partido en varios si pasa los
--      ~1800 caracteres), con bloques que si están vacíos no se muestran:
--        Sin llamada: alertas (N+ días) y avisos (de aviso a alerta - 1), con los días
--           desde la última llamada; y una línea con los que nunca tuvieron una llamada.
--        Accionables vencidos (cs_accionables: vencimiento y responsable BPF/cliente).
--        Accionables de llamadas sin completar (cs_llamada_accionables no tiene vencimiento
--           ni responsable: se cuentan los de llamadas de hace más de N días; N = 0 apaga).
--        Formularios de satisfacción para enviar (los que hoy salen en la tarjeta de Hoy).
--        Morosos de más de N días (fin_cuotas / fin_v_cobranzas, solo lectura), con el
--           alumno cruzado por teléfono o nombre solo si el cruce es único; sin montos salvo
--           incluir_monto del canal.
--      Todo vacío = una línea "Todo al día". Sin nombres si incluir_nombre = false.
--   4. Envío: cron horario cs_servicio a los 12 minutos. Cada corrida manda a los programas
--      con canal activo y webhook cuya hora ya llegó y que hoy no tienen un envío ok.
--      Reintenta hasta 3 veces en el día (mira net._http_response, igual que Finanzas 103).
--      Registro en cs_servicio_envios y en cs_discord_avisos. Sin webhook: no manda, no rompe.
--   5. Botón "Probar aviso de servicio": cs_servicio_probar(programa), solo fundador, manda
--      el mensaje real del día al canal aunque esté desactivado. No cuenta como el envío del día.
--   6. Digest viejo (036/038/039): se APAGA. El cron cs_diario pasa a correr solo
--      cs_correr_diario() (recalcula alertas a las 9:00, imprescindible) y cs_semanal se
--      desprograma. Las funciones cs_digest_diario / cs_resumen_semanal y cs_integraciones NO
--      se tocan ni se borran datos. Motivo abajo en 6.
--
-- Qué NO toca: Fathom (cs_fathom_*), finanzas, crm, ventas (de Finanzas solo lee), cs_v_clientes,
-- cs_v_ultima_llamada, cs_satisf_*. Reemplaza UNA función: cs_probar_discord_canal (acepta
-- 'servicio'; respaldo en cs_bak_123_funciones). Respaldo de los jobs de cron en cs_bak_123_cron.
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
    ('cs_norm_nombre(text)'), ('cs_norm_tel(text)'), ('cs_probar_discord_canal(text,text)'),
    ('cs_correr_diario()')
  ) as r(f)
  where to_regprocedure('public.' || r.f) is null;
  if v_falta is not null then
    raise exception 'cs 123: faltan funciones (corrieron 070, 106 y 036?): %', v_falta;
  end if;
  select string_agg(r.t, ', ') into v_falta
  from (values ('cs_programas'), ('cs_clientes'), ('cs_discord_canales'), ('cs_discord_avisos'),
               ('cs_accionables'), ('cs_llamadas'), ('cs_llamada_accionables'), ('cs_v_ultima_llamada'),
               ('cs_satisf_momentos'), ('cs_satisf_envios'), ('cs_onboardings')) as r(t)
  where to_regclass('public.' || r.t) is null;
  if v_falta is not null then
    raise exception 'cs 123: faltan tablas o vistas (corrieron 102 y 106?): %', v_falta;
  end if;
  if to_regnamespace('net') is null then
    raise exception 'cs 123: falta pg_net (net.http_post)';
  end if;
  if to_regclass('cron.job') is null then
    raise exception 'cs 123: falta pg_cron';
  end if;
end $$;

-- Locks juntos al principio (regla del deadlock): FK a cs_programas y cambio de CHECK en canales.
lock table public.cs_programas, public.cs_clientes, public.cs_discord_canales
  in share row exclusive mode;

-- Respaldos.
create table if not exists public.cs_bak_123_funciones (
  funcion     text primary key,
  definicion  text not null,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_123_funciones from public, anon, authenticated;
insert into public.cs_bak_123_funciones (funcion, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.proname = 'cs_probar_discord_canal'
on conflict (funcion) do nothing;

create table if not exists public.cs_bak_123_cron (
  jobname     text primary key,
  schedule    text not null,
  command     text not null,
  active      boolean,
  respaldada  timestamptz not null default now()
);
revoke all on table public.cs_bak_123_cron from public, anon, authenticated;
insert into public.cs_bak_123_cron (jobname, schedule, command, active)
select j.jobname::text, j.schedule::text, j.command::text, j.active
from cron.job j
where j.jobname in ('cs_diario', 'cs_semanal')
on conflict (jobname) do nothing;


-- =====================================================================
-- 1. PARÁMETROS POR PROGRAMA
-- =====================================================================
create table if not exists public.cs_servicio_config (
  programa_id          text primary key references public.cs_programas(id) on delete cascade,
  -- días desde la última llamada: aviso (amarillo) y alerta (rojo). Lo leen la app y el aviso.
  llamada_aviso_dias   int not null default 7  check (llamada_aviso_dias between 1 and 365),
  llamada_alerta_dias  int not null default 10 check (llamada_alerta_dias between 2 and 365),
  hora_aviso           int not null default 9  check (hora_aviso between 0 and 23),
  morosos_dias         int not null default 14 check (morosos_dias between 1 and 365),
  -- 0 = no se avisan los accionables de llamadas sin completar (no tienen vencimiento propio)
  acc_llamada_dias     int not null default 0  check (acc_llamada_dias between 0 and 365),
  url_app              text not null default 'https://producto.dystopia.com.ar'
                       check (url_app ~ '^https://[^[:space:]]+$' and char_length(url_app) <= 200),
  updated_at           timestamptz not null default now(),
  constraint cs_servicio_config_umbral_chk check (llamada_alerta_dias > llamada_aviso_dias)
);
comment on table public.cs_servicio_config is
  'Parámetros de servicio por programa (123): umbral sin llamada 7/10, hora del aviso diario a Discord, morosos. Lectura: quien ve el programa; escritura: fundador.';

drop trigger if exists cs_servicio_config_updated_at on public.cs_servicio_config;
create trigger cs_servicio_config_updated_at before update on public.cs_servicio_config
  for each row execute function public.cs_tg_updated_at();

alter table public.cs_servicio_config enable row level security;
revoke all on table public.cs_servicio_config from anon, authenticated;
grant select, insert, update, delete on table public.cs_servicio_config to authenticated;
drop policy if exists cs_ver on public.cs_servicio_config;
create policy cs_ver on public.cs_servicio_config for select to authenticated
  using (public.cs_puede_ver(programa_id));
drop policy if exists cs_fundador_ins on public.cs_servicio_config;
create policy cs_fundador_ins on public.cs_servicio_config for insert to authenticated
  with check (public.es_fundador());
drop policy if exists cs_fundador_upd on public.cs_servicio_config;
create policy cs_fundador_upd on public.cs_servicio_config for update to authenticated
  using (public.es_fundador()) with check (public.es_fundador());
drop policy if exists cs_fundador_del on public.cs_servicio_config;
create policy cs_fundador_del on public.cs_servicio_config for delete to authenticated
  using (public.es_fundador());

-- Una fila por programa existente, con 7 / 10, 9:00, 14 días.
insert into public.cs_servicio_config (programa_id)
select p.id from public.cs_programas p
on conflict (programa_id) do nothing;


-- =====================================================================
-- 2. CANAL 'servicio' EN cs_discord_canales
-- =====================================================================
do $$
declare
  v_c record;
begin
  for v_c in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'public.cs_discord_canales'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ~ 'satisfaccion'
  loop
    execute format('alter table public.cs_discord_canales drop constraint %I', v_c.conname);
  end loop;
end $$;
alter table public.cs_discord_canales drop constraint if exists cs_discord_canales_tipo_chk;
alter table public.cs_discord_canales add constraint cs_discord_canales_tipo_chk
  check (tipo in ('satisfaccion', 'wins', 'servicio'));

-- Filas del canal servicio sin webhook y desactivadas (no pisa lo que ya exista).
insert into public.cs_discord_canales (programa_id, tipo, webhook_url, activo, incluir_nombre, incluir_monto)
select p.id, 'servicio', null, false, true, false
from public.cs_programas p
where p.id in ('liam', 'agus', 'teo')
on conflict (programa_id, tipo) do nothing;


-- =====================================================================
-- 3. REGISTRO DE ENVÍOS
-- =====================================================================
create table if not exists public.cs_servicio_envios (
  id           bigserial primary key,
  programa_id  text not null,
  fecha        date not null,
  -- cron: lo manda el job (cuenta para el tope de 3 por día). manual: botón Probar (no cuenta).
  origen       text not null default 'cron' check (origen in ('cron', 'manual')),
  intento      int  not null default 1,
  estado       text not null default 'enviando' check (estado in ('enviando', 'ok', 'fallo')),
  partes       int  not null default 1,
  request_ids  bigint[] not null default '{}',
  cuentas      jsonb,
  detalle      text,
  creado       timestamptz not null default now()
);
create unique index if not exists cs_servicio_envios_cron_uk
  on public.cs_servicio_envios (programa_id, fecha, intento) where origen = 'cron';
create index if not exists cs_servicio_envios_estado_idx
  on public.cs_servicio_envios (estado) where estado = 'enviando';
comment on table public.cs_servicio_envios is
  'Registro del aviso diario de servicio (123): un renglón por intento. Solo fundador.';

alter table public.cs_servicio_envios enable row level security;
revoke all on table public.cs_servicio_envios from anon, authenticated;
revoke all on sequence public.cs_servicio_envios_id_seq from anon, authenticated;
grant select on table public.cs_servicio_envios to authenticated;
drop policy if exists cs_fundador on public.cs_servicio_envios;
create policy cs_fundador on public.cs_servicio_envios for select to authenticated
  using (public.es_fundador());


-- =====================================================================
-- 4. FUNCIONES
-- =====================================================================

-- Texto seguro para Discord: sin saltos, sin caracteres de formato ni menciones, hasta 60.
create or replace function public.cs_servicio_limpio(p text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[*_`~|<>@\[\]\\]', '', 'g'),
                                   '\s+', ' ', 'g')), 60)
$$;

-- Morosos cruzados con un alumno de Producto. Solo lectura sobre Finanzas.
-- Cruce: teléfono (últimos 8 dígitos) o nombre normalizado, SOLO si apunta a un único alumno
-- del programa y, cuando coinciden los dos, al mismo. Si no, cliente_id = null (sin cruzar).
-- Devuelve una fila por alumno cruzado y una fila con cliente_id null para las que no se cruzaron.
create or replace function public.cs_servicio_morosos(p_programa text, p_dias int, p_hoy date default null)
returns table (cliente_id uuid, cuotas int, dias_max int, pendiente numeric)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_hoy date := coalesce(p_hoy, public.cs_hoy());
begin
  if to_regclass('public.fin_v_cobranzas') is null or to_regclass('public.fin_cuotas') is null
     or to_regclass('public.fin_fuentes') is null then
    return;
  end if;
  return query
  with cuotas as (
    select v.id,
           public.cs_norm_nombre(v.alumno) as nom,
           public.cs_norm_tel(v.telefono)  as tel,
           (v_hoy - v.fecha_pago)          as atraso,
           greatest(coalesce(v.monto, 0) - coalesce(v.monto_cobrado, 0), 0) as pend
    from public.fin_v_cobranzas v
    join public.fin_cuotas q on q.id = v.id
    join public.fin_fuentes f on f.id = q.fuente_id
    where v.cliente_id = p_programa
      and f.activo
      and v.fecha_pago is not null
      and (v_hoy - v.fecha_pago) > p_dias
  ),
  alumnos as (
    select c.id, public.cs_norm_nombre(c.nombre) as nom, public.cs_norm_tel(c.telefono) as tel
    from public.cs_clientes c
    where c.programa_id = p_programa
  ),
  cruce as (
    select q.*,
           (select array_agg(distinct a.id) from alumnos a where q.tel is not null and a.tel = q.tel) as por_tel,
           (select array_agg(distinct a.id) from alumnos a where q.nom is not null and a.nom = q.nom) as por_nom
    from cuotas q
  ),
  resuelto as (
    select r.atraso, r.pend,
           case
             when cardinality(coalesce(r.por_tel, '{}')) = 1
                  and (r.por_nom is null or r.por_nom = r.por_tel) then r.por_tel[1]
             when cardinality(coalesce(r.por_tel, '{}')) = 0
                  and cardinality(coalesce(r.por_nom, '{}')) = 1 then r.por_nom[1]
             when cardinality(coalesce(r.por_tel, '{}')) > 1
                  and cardinality(coalesce(r.por_nom, '{}')) = 1
                  and r.por_nom[1] = any (r.por_tel) then r.por_nom[1]
             else null
           end as alumno_id
    from cruce r
  )
  select z.alumno_id, count(*)::int, max(z.atraso)::int, sum(z.pend)
  from resuelto z
  group by z.alumno_id;
end;
$fn$;

-- Arma el mensaje del día. Interna (no se expone a la app): la llaman el cron y el botón.
-- p_fecha: solo para pruebas. Devuelve {partes: text[], cuentas: {...}}.
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
           greatest(0, v_hoy - u.ultima_llamada) as dias
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

  -- ---------- accionables vencidos (cs_accionables: tienen vencimiento y responsable) ----------
  for r in
    select c.id, c.nombre, a.titulo, a.responsable, (v_hoy - a.vence) as atraso, a.vence
    from public.cs_accionables a
    join public.cs_clientes c on c.id = a.cliente_id
    where a.programa_id = p_programa
      and a.estado <> 'completado'
      and a.vence < v_hoy
      and c.estado = any (v_vivos)
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

  v_total := n_alerta + n_aviso + n_nunca + n_acc + n_accl + n_sat + n_mor;

  if v_total = 0 then
    v_partes := array[v_titulo || E'\n' || '✅ Todo al día'];
    return jsonb_build_object('partes', to_jsonb(v_partes),
      'cuentas', jsonb_build_object('alerta', 0, 'aviso', 0, 'nunca', 0, 'accionables', 0,
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
      'accionables', n_acc, 'acc_llamadas', n_accl, 'formularios', n_sat, 'morosos', n_mor,
      'morosos_sin_cruzar', n_sincruz, 'con_nombre', v_nom));
end;
$fn$;

-- Manda el mensaje armado. Interna. Devuelve {resultado: enviado|sin_webhook|vista_previa, ...}.
-- p_enviar = false: arma y devuelve, sin POST ni registro (prueba de humo y vista previa).
create or replace function public.cs_servicio_enviar_programa(
  p_programa text,
  p_origen   text,
  p_intento  int,
  p_ahora    timestamptz default now(),
  p_enviar   boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_hoy    date := (p_ahora at time zone 'America/Argentina/Buenos_Aires')::date;
  v_url    text;
  v_a      jsonb;
  v_partes jsonb;
  v_i      int;
  v_txt    text;
  v_req    bigint;
  v_reqs   bigint[] := '{}';
  v_id     bigint;
  v_n      int;
begin
  select k.webhook_url into v_url
  from public.cs_discord_canales k
  where k.programa_id = p_programa and k.tipo = 'servicio';

  if v_url is null then
    return jsonb_build_object('programa_id', p_programa, 'resultado', 'sin_webhook');
  end if;

  v_a := public.cs_servicio_armar(p_programa, v_hoy);
  v_partes := v_a -> 'partes';
  v_n := jsonb_array_length(v_partes);

  if not p_enviar then
    return jsonb_build_object('programa_id', p_programa, 'resultado', 'vista_previa',
                              'partes', v_n, 'cuentas', v_a -> 'cuentas');
  end if;

  for v_i in 0 .. v_n - 1 loop
    v_txt := left(v_partes ->> v_i, 1900);
    v_req := null;
    begin
      v_req := net.http_post(
        url     := v_url || case when v_url like '%?%' then '&' else '?' end || 'wait=true',
        headers := jsonb_build_object('content-type', 'application/json'),
        body    := jsonb_build_object('username', 'Dystopia Producto', 'content', v_txt,
                                      'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)),
        timeout_milliseconds := 10000);
    exception when others then
      v_req := null;
    end;
    if v_req is not null then v_reqs := v_reqs || v_req; end if;
    insert into public.cs_discord_avisos (programa_id, tipo, contenido, request_id)
    values (p_programa, 'servicio', v_txt, v_req);
  end loop;

  insert into public.cs_servicio_envios (programa_id, fecha, origen, intento, estado, partes, request_ids, cuentas, detalle)
  values (p_programa, v_hoy, p_origen, p_intento,
          case when cardinality(v_reqs) = v_n then 'enviando' else 'fallo' end,
          v_n, v_reqs, v_a -> 'cuentas',
          case when cardinality(v_reqs) = v_n then null else 'no se pudo encolar el envío a Discord' end)
  returning id into v_id;

  return jsonb_build_object('programa_id', p_programa, 'resultado',
           case when cardinality(v_reqs) = v_n then 'enviado' else 'fallo' end,
           'envio', v_id, 'partes', v_n, 'cuentas', v_a -> 'cuentas');
end;
$fn$;

-- Mira la respuesta de Discord de lo enviado antes y marca ok / fallo.
create or replace function public.cs_servicio_confirmar(p_ahora timestamptz default now())
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  r      record;
  v_ok   int;
  v_resp int;
  v_n    int := 0;
begin
  for r in
    select e.id, e.creado, e.request_ids
    from public.cs_servicio_envios e
    where e.estado = 'enviando'
    order by e.id
  loop
    select count(*) filter (where h.status_code between 200 and 299), count(*)
      into v_ok, v_resp
    from net._http_response h where h.id = any (r.request_ids);

    if cardinality(r.request_ids) > 0 and v_ok = cardinality(r.request_ids) then
      update public.cs_servicio_envios set estado = 'ok' where id = r.id;
      v_n := v_n + 1;
    elsif v_resp = cardinality(r.request_ids) or r.creado < p_ahora - interval '30 minutes' then
      update public.cs_servicio_envios
         set estado = 'fallo', detalle = 'Discord no confirmó el mensaje (se reintenta)'
       where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$fn$;

-- Lo que corre el cron. p_enviar = false: devuelve a quién le mandaría, sin POST ni escrituras.
create or replace function public.cs_servicio_cron(p_ahora timestamptz default now(), p_enviar boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_hoy  date := (p_ahora at time zone 'America/Argentina/Buenos_Aires')::date;
  v_hora int  := extract(hour from (p_ahora at time zone 'America/Argentina/Buenos_Aires'))::int;
  r      record;
  v_int  int;
  v_res  jsonb := '[]'::jsonb;
begin
  if p_enviar then perform public.cs_servicio_confirmar(p_ahora); end if;

  for r in
    select k.programa_id
    from public.cs_discord_canales k
    join public.cs_programas p on p.id = k.programa_id
    left join public.cs_servicio_config c on c.programa_id = k.programa_id
    where k.tipo = 'servicio'
      and k.activo
      and k.webhook_url is not null
      and p.activo
      and coalesce(c.hora_aviso, 9) <= v_hora
      -- ya salió bien, o hay uno en camino: no se duplica
      and not exists (select 1 from public.cs_servicio_envios e
                      where e.programa_id = k.programa_id and e.fecha = v_hoy and e.origen = 'cron'
                        and e.estado in ('ok', 'enviando'))
      -- hasta 3 intentos en el día
      and (select count(*) from public.cs_servicio_envios e
           where e.programa_id = k.programa_id and e.fecha = v_hoy and e.origen = 'cron') < 3
    order by k.programa_id
  loop
    select count(*) + 1 into v_int from public.cs_servicio_envios e
    where e.programa_id = r.programa_id and e.fecha = v_hoy and e.origen = 'cron';
    begin
      v_res := v_res || public.cs_servicio_enviar_programa(r.programa_id, 'cron', v_int, p_ahora, p_enviar);
    exception when others then
      -- un programa con error no frena a los demás
      v_res := v_res || jsonb_build_object('programa_id', r.programa_id, 'resultado', 'error', 'detalle', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('fecha', v_hoy, 'hora', v_hora, 'envios', v_res);
end;
$fn$;

-- Botón "Probar aviso de servicio" (solo fundador, o llamada sin sesión desde el SQL Editor).
create or replace function public.cs_servicio_probar(p_programa text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_r jsonb;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede probar el aviso de servicio' using errcode = '42501';
  end if;
  if not exists (select 1 from public.cs_programas where id = p_programa) then
    raise exception 'cs: programa inexistente' using errcode = '22023';
  end if;
  v_r := public.cs_servicio_enviar_programa(p_programa, 'manual', 0, now(), true);
  if v_r ->> 'resultado' = 'sin_webhook' then
    raise exception 'cs: no hay webhook cargado para el canal servicio' using errcode = 'P0001';
  end if;
  return v_r;
end;
$fn$;

-- El botón Probar genérico de cada canal acepta también 'servicio' (mensaje de prueba corto).
create or replace function public.cs_probar_discord_canal(p_programa text, p_tipo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id bigint;
  v_nombre text;
begin
  if auth.uid() is not null and not coalesce(public.es_fundador(), false) then
    raise exception 'cs: solo el fundador puede probar Discord' using errcode = '42501';
  end if;
  select nombre into v_nombre from public.cs_programas where id = p_programa;
  if v_nombre is null then
    raise exception 'cs: programa inexistente' using errcode = '22023';
  end if;
  if p_tipo not in ('satisfaccion', 'wins', 'servicio') then
    raise exception 'cs: tipo de aviso invalido' using errcode = '22023';
  end if;
  v_id := public.cs_discord_canal_post(p_programa, p_tipo,
    'Mensaje de prueba de Dystopia Producto · ' || v_nombre || ' · canal ' || p_tipo, true);
  if v_id is null then
    raise exception 'cs: no hay webhook cargado para este canal' using errcode = 'P0001';
  end if;
  return jsonb_build_object('ok', true, 'envio', v_id);
end;
$fn$;

-- Permisos: las internas no las llama la app; solo Probar (y el probar de canal, que ya estaba).
revoke all on function public.cs_servicio_limpio(text) from public, anon, authenticated;
revoke all on function public.cs_servicio_morosos(text, int, date) from public, anon, authenticated;
revoke all on function public.cs_servicio_armar(text, date) from public, anon, authenticated;
revoke all on function public.cs_servicio_enviar_programa(text, text, int, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.cs_servicio_confirmar(timestamptz) from public, anon, authenticated;
revoke all on function public.cs_servicio_cron(timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.cs_servicio_probar(text) from public, anon;
grant execute on function public.cs_servicio_probar(text) to authenticated;
revoke all on function public.cs_probar_discord_canal(text, text) from public, anon;
grant execute on function public.cs_probar_discord_canal(text, text) to authenticated;


-- =====================================================================
-- 5. CRON DEL AVISO DE SERVICIO
-- =====================================================================
-- Cada hora a los :12 (evita :00/:15/:30/:45 de la sync de Finanzas y las 9:00 del chequeo).
-- La hora del aviso de cada programa (default 9) se compara contra la hora Argentina adentro:
-- el primer disparo es a esa hora y :12, y los reintentos caen en las horas siguientes.
select cron.unschedule(jobid) from cron.job where jobname = 'cs_servicio';
select cron.schedule('cs_servicio', '12 * * * *', $cron$ select public.cs_servicio_cron(); $cron$);


-- =====================================================================
-- 6. DIGEST VIEJO (036 / 038 / 039): APAGADO
-- =====================================================================
-- Por qué se apaga:
--   * Lee UN solo webhook por programa (cs_integraciones) y esa tabla está vacía: nunca salió.
--   * "Onboarding pendientes" sale de cs_v_kpis_programa.onboarding_pendientes, que cuenta
--     onboarding_estado = 'pendiente_agendar' (el flujo viejo de 037). Con el onboarding por
--     link (093) ese estado no se usa: da 0 siempre. El número era viejo y engañoso.
--   * El resto (activos, rojo/amarillo, devoluciones, por vencer) ya está en el Dashboard y
--     en la pantalla Hoy; el aviso nuevo lleva lo accionable del día por alumno.
-- Qué queda: cs_correr_diario() a las 9:00 (recalcula alertas y cierra vencidos: no se toca).
-- Funciones, cs_integraciones y cs_discord_envios quedan como están. Vuelta atrás: ver al final.
select cron.unschedule(jobid) from cron.job where jobname in ('cs_diario', 'cs_semanal');
select cron.schedule('cs_diario', '0 12 * * *', $cron$ select public.cs_correr_diario(); $cron$);

commit;


-- =====================================================================
-- 7. PRUEBA DE HUMO (no deja datos, NO llama a net.http_post, no manda nada)
-- =====================================================================
-- Crea tres programas propios (humo123, humo123b, humo123c) y lo deshace todo al final con un
-- error forzado. El cron se prueba solo con p_enviar = false (vista previa).
drop table if exists pg_temp.cs_smoke123;
create temp table cs_smoke123 (orden int, paso text, ok boolean, detalle text);

do $$
declare
  res      text[] := '{}';
  v_hoy    date := public.cs_hoy();
  v_a      jsonb;
  v_c      jsonb;
  v_txt    text;
  v_n      int;
  v_n2     int;
  v_state  text;
  v_t_ok   timestamptz;
  v_t_ant  timestamptz;
  v_prev   jsonb;
  v_ids    uuid[];
  v_cli    uuid;
begin
  begin
    -- ---------- datos ----------
    insert into public.cs_programas (id, nombre, activo) values
      ('humo123', '__humo123__', true), ('humo123b', '__humo123b__', true), ('humo123c', '__humo123c__', true);
    insert into public.cs_servicio_config (programa_id) values ('humo123'), ('humo123c');
    insert into public.cs_discord_canales (programa_id, tipo, webhook_url, activo, incluir_nombre)
    values ('humo123', 'servicio', 'https://discord.com/api/webhooks/0/__humo123__', true, true);

    -- A 12 d (alerta), G 10 d (alerta, borde), B 8 d (aviso), H 7 d (aviso, borde), I 6 d (nada),
    -- D sin llamada, E finalizado y F pausado (afuera aunque tengan 30 y 40 días)
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado) values
      ('humo123', 'Zorzal Alfa',  v_hoy - 60, v_hoy + 30, 'activo'),
      ('humo123', 'Zorzal Gamma', v_hoy - 60, v_hoy + 30, 'activo'),
      ('humo123', 'Zorzal Beta',  v_hoy - 60, v_hoy + 30, 'activo'),
      ('humo123', 'Zorzal Hache', v_hoy - 60, v_hoy + 30, 'activo'),
      ('humo123', 'Zorzal Iota',  v_hoy - 60, v_hoy + 30, 'activo'),
      ('humo123', 'Zorzal Delta', v_hoy - 60, v_hoy + 30, 'activo'),
      ('humo123', 'Zorzal Fin',   v_hoy - 100, v_hoy - 1, 'finalizado');
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado, pausado_desde)
    values ('humo123', 'Zorzal Pausa', v_hoy - 60, v_hoy + 30, 'pausado', v_hoy - 5);

    insert into public.cs_llamadas (programa_id, cliente_id, fecha, titulo)
    select 'humo123', c.id, v_hoy - d.dias, 'humo'
    from (values ('Zorzal Alfa', 12), ('Zorzal Gamma', 10), ('Zorzal Beta', 8), ('Zorzal Hache', 7),
                 ('Zorzal Iota', 6), ('Zorzal Fin', 30), ('Zorzal Pausa', 40)) d(nombre, dias)
    join public.cs_clientes c on c.programa_id = 'humo123' and c.nombre = d.nombre;

    -- accionable vencido de Alfa (BPF) y uno completado que NO tiene que salir
    select id into v_cli from public.cs_clientes where programa_id = 'humo123' and nombre = 'Zorzal Alfa';
    insert into public.cs_accionables (programa_id, cliente_id, responsable, titulo, estado, vence, completado_at) values
      ('humo123', v_cli, 'bpf', 'Mandar portafolio humo', 'pendiente', v_hoy - 4, null),
      ('humo123', v_cli, 'cliente', 'Completado humo', 'completado', v_hoy - 9, now());

    -- ---------- 1. sin llamada: umbral 7/10 y bordes ----------
    v_a := public.cs_servicio_armar('humo123');
    v_c := v_a -> 'cuentas';
    res := res || format('alertas = 2 (12 d y borde 10 d)|%s|%s', (v_c ->> 'alerta')::int = 2, v_c::text);
    res := res || format('avisos = 2 (8 d y borde 7 d)|%s|aviso=%s', (v_c ->> 'aviso')::int = 2, v_c ->> 'aviso');
    res := res || format('nunca = 1 (Delta)|%s|nunca=%s', (v_c ->> 'nunca')::int = 1, v_c ->> 'nunca');
    v_txt := array_to_string(array(select jsonb_array_elements_text(v_a -> 'partes')), E'\n');
    res := res || format('no aparecen finalizado ni pausado|%s|%s',
                         v_txt not like '%Zorzal Fin%' and v_txt not like '%Zorzal Pausa%', 'busca Zorzal Fin / Zorzal Pausa');
    res := res || format('no aparece el de 6 días|%s|%s', v_txt not like '%Zorzal Iota%', 'busca Zorzal Iota');
    res := res || format('muestra días y link a la ficha|%s|%s',
                         v_txt like '%[Zorzal Alfa](<https://producto.dystopia.com.ar/#/p/humo123/c/%>) · 12 días%',
                         left(replace(v_txt, E'\n', ' / '), 160));

    -- ---------- 2. accionables vencidos con responsable ----------
    res := res || format('accionable vencido con responsable BPF|%s|accionables=%s',
                         (v_c ->> 'accionables')::int = 1 and v_txt like '%Mandar portafolio humo · BPF · venció%'
                         and v_txt not like '%Completado humo%', v_c ->> 'accionables');

    -- ---------- 3. umbral por programa ----------
    update public.cs_servicio_config set llamada_aviso_dias = 5, llamada_alerta_dias = 8 where programa_id = 'humo123';
    v_c := public.cs_servicio_armar('humo123') -> 'cuentas';
    res := res || format('umbral editable: con 5/8 hay 3 alertas y 2 avisos|%s|alerta=%s aviso=%s',
                         (v_c ->> 'alerta')::int = 3 and (v_c ->> 'aviso')::int = 2, v_c ->> 'alerta', v_c ->> 'aviso');
    update public.cs_servicio_config set llamada_aviso_dias = 7, llamada_alerta_dias = 10 where programa_id = 'humo123';
    begin
      update public.cs_servicio_config set llamada_aviso_dias = 10, llamada_alerta_dias = 10 where programa_id = 'humo123';
      v_state := 'sin error';
    exception when check_violation then
      v_state := 'check_violation';
    end;
    res := res || format('el CHECK exige alerta mayor que aviso|%s|%s', v_state = 'check_violation', v_state);

    -- ---------- 4. sin nombre ----------
    update public.cs_discord_canales set incluir_nombre = false where programa_id = 'humo123' and tipo = 'servicio';
    v_a := public.cs_servicio_armar('humo123');
    v_txt := array_to_string(array(select jsonb_array_elements_text(v_a -> 'partes')), E'\n');
    res := res || format('incluir_nombre = false: sin nombres ni links, con conteos|%s|%s',
                         v_txt not like '%Zorzal%' and v_txt not like '%humo123/c/%'
                         and (v_a -> 'cuentas' ->> 'alerta')::int = 2 and v_txt like '%🔴 **Sin llamada hace 10 días o más** (2)%',
                         left(replace(v_txt, E'\n', ' / '), 160));
    update public.cs_discord_canales set incluir_nombre = true where programa_id = 'humo123' and tipo = 'servicio';

    -- ---------- 5. todo al día y valores por defecto sin fila de config ----------
    v_a := public.cs_servicio_armar('humo123b');
    res := res || format('programa sin nada: "Todo al día" (y sin fila de config usa 7/10)|%s|%s',
                         (v_a -> 'partes' ->> 0) like '%✅ Todo al día' and jsonb_array_length(v_a -> 'partes') = 1,
                         replace(v_a -> 'partes' ->> 0, E'\n', ' / '));

    -- ---------- 6. mensaje largo: se parte y entran todos ----------
    insert into public.cs_clientes (programa_id, nombre, fecha_inicio, fecha_fin, estado)
    select 'humo123c', 'Zorzal Nombre Largo Numero ' || g, v_hoy - 60, v_hoy + 30, 'activo'
    from generate_series(1, 60) g;
    insert into public.cs_llamadas (programa_id, cliente_id, fecha)
    select programa_id, id, v_hoy - 15 from public.cs_clientes where programa_id = 'humo123c';
    v_a := public.cs_servicio_armar('humo123c');
    v_txt := array_to_string(array(select jsonb_array_elements_text(v_a -> 'partes')), E'\n');
    select max(char_length(x)) into v_n from jsonb_array_elements_text(v_a -> 'partes') x;
    v_n2 := (char_length(v_txt) - char_length(replace(v_txt, 'Zorzal Nombre Largo Numero', '')))
            / char_length('Zorzal Nombre Largo Numero');
    res := res || format('60 alertas: varios mensajes de menos de 2000 caracteres con los 60 alumnos|%s|partes=%s maximo=%s alumnos=%s',
                         jsonb_array_length(v_a -> 'partes') between 2 and 6 and v_n < 2000 and v_n2 = 60,
                         jsonb_array_length(v_a -> 'partes'), v_n, v_n2);

    -- ---------- 7. formularios de satisfacción ----------
    insert into public.cs_satisf_momentos (programa_id, nombre, tipo, valor, desde)
    values ('humo123', 'Momento humo', 'dias_desde_inicio', 1, v_hoy - 400);
    v_c := public.cs_servicio_armar('humo123') -> 'cuentas';
    res := res || format('formularios: los 6 activos (no finalizado ni pausado)|%s|formularios=%s',
                         (v_c ->> 'formularios')::int = 6, v_c ->> 'formularios');

    -- ---------- 8. morosos: sin Finanzas o sin datos no rompe ----------
    select count(*) into v_n from public.cs_servicio_morosos('humo123', 14, v_hoy);
    res := res || format('morosos: sin datos de Finanzas devuelve 0 filas y no rompe|%s|filas=%s', v_n = 0, v_n);

    -- ---------- 9. cron: hora, activo, reintentos, sin duplicar (vista previa, sin POST) ----------
    v_t_ok  := (v_hoy::timestamp + time '09:12') at time zone 'America/Argentina/Buenos_Aires';
    v_t_ant := (v_hoy::timestamp + time '08:12') at time zone 'America/Argentina/Buenos_Aires';
    select count(*) into v_n from public.cs_servicio_envios where programa_id = 'humo123';
    select count(*) into v_n2 from public.cs_discord_avisos where programa_id = 'humo123';

    v_prev := public.cs_servicio_cron(v_t_ok, false);
    res := res || format('9:12 con hora 9: sale|%s|%s',
                         exists (select 1 from jsonb_array_elements(v_prev -> 'envios') e
                                 where e ->> 'programa_id' = 'humo123' and e ->> 'resultado' = 'vista_previa'),
                         left(v_prev::text, 120));
    v_prev := public.cs_servicio_cron(v_t_ant, false);
    res := res || format('8:12 con hora 9: no sale todavía|%s|%s',
                         not exists (select 1 from jsonb_array_elements(v_prev -> 'envios') e where e ->> 'programa_id' = 'humo123'),
                         left(v_prev::text, 120));
    update public.cs_servicio_config set hora_aviso = 11 where programa_id = 'humo123';
    v_prev := public.cs_servicio_cron(v_t_ok, false);
    res := res || format('hora configurable (11): a las 9:12 no sale|%s|%s',
                         not exists (select 1 from jsonb_array_elements(v_prev -> 'envios') e where e ->> 'programa_id' = 'humo123'),
                         left(v_prev::text, 120));
    update public.cs_servicio_config set hora_aviso = 9 where programa_id = 'humo123';

    res := res || format('la vista previa no escribe registros ni avisos|%s|envios=%s avisos=%s',
                         (select count(*) from public.cs_servicio_envios where programa_id = 'humo123') = v_n
                         and (select count(*) from public.cs_discord_avisos where programa_id = 'humo123') = v_n2,
                         (select count(*) from public.cs_servicio_envios where programa_id = 'humo123'),
                         (select count(*) from public.cs_discord_avisos where programa_id = 'humo123'));

    insert into public.cs_servicio_envios (programa_id, fecha, origen, intento, estado, partes)
    values ('humo123', v_hoy, 'cron', 1, 'fallo', 1), ('humo123', v_hoy, 'cron', 2, 'fallo', 1);
    v_prev := public.cs_servicio_cron(v_t_ok, false);
    res := res || format('con 2 fallos todavía reintenta (intento 3)|%s|%s',
                         exists (select 1 from jsonb_array_elements(v_prev -> 'envios') e
                                 where e ->> 'programa_id' = 'humo123' and e ->> 'resultado' = 'vista_previa'),
                         left(v_prev::text, 120));
    insert into public.cs_servicio_envios (programa_id, fecha, origen, intento, estado, partes)
    values ('humo123', v_hoy, 'cron', 3, 'fallo', 1);
    v_prev := public.cs_servicio_cron(v_t_ok, false);
    res := res || format('con 3 fallos no reintenta más ese día|%s|%s',
                         not exists (select 1 from jsonb_array_elements(v_prev -> 'envios') e where e ->> 'programa_id' = 'humo123'),
                         left(v_prev::text, 120));
    update public.cs_servicio_envios set estado = 'ok' where programa_id = 'humo123' and intento = 3;
    v_prev := public.cs_servicio_cron(v_t_ok, false);
    res := res || format('con un envío ok no duplica|%s|%s',
                         not exists (select 1 from jsonb_array_elements(v_prev -> 'envios') e where e ->> 'programa_id' = 'humo123'),
                         left(v_prev::text, 120));

    -- ---------- 10. sin webhook: no manda y no rompe ----------
    delete from public.cs_servicio_envios where programa_id = 'humo123';
    update public.cs_discord_canales set webhook_url = null where programa_id = 'humo123' and tipo = 'servicio';
    v_prev := public.cs_servicio_cron(v_t_ok, false);
    res := res || format('sin webhook: el cron no lo toma y no rompe|%s|%s',
                         not exists (select 1 from jsonb_array_elements(v_prev -> 'envios') e where e ->> 'programa_id' = 'humo123'),
                         left(v_prev::text, 120));
    v_c := public.cs_servicio_enviar_programa('humo123', 'manual', 0, now(), false);
    res := res || format('sin webhook: enviar_programa devuelve sin_webhook|%s|%s', v_c ->> 'resultado' = 'sin_webhook', v_c::text);

    -- ---------- 11. permisos ----------
    perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000123","role":"authenticated"}', true);
    begin
      perform public.cs_servicio_probar('humo123');
      v_state := 'sin error';
    exception when others then
      v_state := sqlstate;
    end;
    perform set_config('request.jwt.claims', '', true);
    res := res || format('probar rechaza a un no fundador|%s|sqlstate=%s', v_state = '42501', v_state);

    -- ---------- 12. el canal acepta el tipo servicio y no otros ----------
    begin
      insert into public.cs_discord_canales (programa_id, tipo) values ('humo123b', 'inventado');
      v_state := 'sin error';
    exception when check_violation then
      v_state := 'check_violation';
    end;
    res := res || format('cs_discord_canales rechaza un tipo inventado|%s|%s', v_state = 'check_violation', v_state);

    raise exception 'cs_smoke_rollback';
  exception when others then
    if sqlerrm <> 'cs_smoke_rollback' then
      res := res || format('ERROR INESPERADO|false|%s (%s)', replace(sqlerrm, '|', '/'), sqlstate);
    end if;
  end;

  insert into cs_smoke123 (orden, paso, ok, detalle)
  select o, split_part(x, '|', 1), nullif(split_part(x, '|', 2), '')::boolean, split_part(x, '|', 3)
  from unnest(res) with ordinality as u(x, o);
end $$;


-- =====================================================================
-- 8. CONTROLES (una sola tabla; mirar la columna ok. Todo tiene que dar true)
-- =====================================================================
with
funcs as (
  select p.oid, p.proname::text as proname, p.prosecdef,
         coalesce(array_to_string(p.proconfig, ','), '') as config
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('cs_servicio_limpio', 'cs_servicio_morosos', 'cs_servicio_armar',
                      'cs_servicio_enviar_programa', 'cs_servicio_confirmar', 'cs_servicio_cron',
                      'cs_servicio_probar', 'cs_probar_discord_canal')
),
jobs as (
  select j.jobname::text as jobname, j.schedule::text as schedule, j.active, j.command::text as command
  from cron.job j
  where j.jobname in ('cs_diario', 'cs_semanal', 'cs_servicio')
     or j.command ~ 'cs_(correr_diario|digest_diario|resumen_semanal|servicio_cron)'
)
select '01 tablas con RLS y sin acceso anon' as control, t.relname::text as objeto,
       'rls=true anon=0' as esperado,
       'rls=' || t.relrowsecurity::text || ' anon=' || (select count(*) from information_schema.role_table_grants g
         where g.grantee = 'anon' and g.table_schema = 'public' and g.table_name = t.relname)::text as obtenido,
       t.relrowsecurity and (select count(*) from information_schema.role_table_grants g
         where g.grantee = 'anon' and g.table_schema = 'public' and g.table_name = t.relname) = 0 as ok
from pg_class t
where t.relnamespace = 'public'::regnamespace and t.relname in ('cs_servicio_config', 'cs_servicio_envios')
union all
select '02 funciones security definer con search_path', f.proname, 'true / search_path=public',
       f.prosecdef::text || ' / ' || f.config, f.prosecdef and f.config ~ 'search_path=public'
from funcs f where f.proname <> 'cs_servicio_limpio'
union all
select '03 solo cs_servicio_probar y cs_probar_discord_canal las ejecuta la app', f.proname,
       case when f.proname in ('cs_servicio_probar', 'cs_probar_discord_canal') then 'true' else 'false' end,
       has_function_privilege('authenticated', f.oid, 'EXECUTE')::text,
       has_function_privilege('authenticated', f.oid, 'EXECUTE') = (f.proname in ('cs_servicio_probar', 'cs_probar_discord_canal'))
         and not has_function_privilege('anon', f.oid, 'EXECUTE')
from funcs f
union all
select '04 tipo servicio permitido en canales', 'cs_discord_canales', 'tipo in (satisfaccion, wins, servicio)',
       (select pg_get_constraintdef(con.oid) from pg_constraint con
         where con.conrelid = 'public.cs_discord_canales'::regclass and con.conname = 'cs_discord_canales_tipo_chk'),
       exists (select 1 from pg_constraint con where con.conrelid = 'public.cs_discord_canales'::regclass
               and con.conname = 'cs_discord_canales_tipo_chk' and pg_get_constraintdef(con.oid) ~ 'servicio')
union all
select '05 canal servicio sembrado (liam, agus, teo)', 'filas', '3 (o las que existan)',
       (select count(*) from public.cs_discord_canales where tipo = 'servicio' and programa_id in ('liam', 'agus', 'teo'))::text,
       (select count(*) from public.cs_discord_canales where tipo = 'servicio' and programa_id in ('liam', 'agus', 'teo'))
         = (select count(*) from public.cs_programas where id in ('liam', 'agus', 'teo'))
union all
select '06 config por programa con 7 / 10', 'programas sin fila o con otros valores', '0',
       ((select count(*) from public.cs_programas p where not exists
          (select 1 from public.cs_servicio_config c where c.programa_id = p.id))
        + (select count(*) from public.cs_servicio_config c
           where c.programa_id in ('liam', 'agus', 'teo')
             and (c.llamada_aviso_dias <> 7 or c.llamada_alerta_dias <> 10)))::text,
       ((select count(*) from public.cs_programas p where not exists
          (select 1 from public.cs_servicio_config c where c.programa_id = p.id))
        + (select count(*) from public.cs_servicio_config c
           where c.programa_id in ('liam', 'agus', 'teo')
             and (c.llamada_aviso_dias <> 7 or c.llamada_alerta_dias <> 10))) = 0
union all
select '07 cron del aviso', 'cs_servicio', '12 * * * * activo',
       coalesce((select schedule || case when active then ' activo' else ' INACTIVO' end from jobs where jobname = 'cs_servicio'), '(no existe)'),
       coalesce((select schedule = '12 * * * *' and active and command ~ 'cs_servicio_cron' from jobs where jobname = 'cs_servicio'), false)
union all
select '08 digest viejo apagado', 'cs_diario sin cs_digest_diario', '0 12 * * * solo cs_correr_diario',
       coalesce((select schedule || ' / ' || command from jobs where jobname = 'cs_diario'), '(no existe)'),
       coalesce((select schedule = '0 12 * * *' and active and command ~ 'cs_correr_diario'
                        and command !~ 'cs_digest_diario' from jobs where jobname = 'cs_diario'), false)
union all
select '08 digest viejo apagado', 'cs_semanal', '(no existe)',
       coalesce((select schedule from jobs where jobname = 'cs_semanal'), '(no existe)'),
       not exists (select 1 from jobs where jobname = 'cs_semanal')
union all
select '08 digest viejo apagado', 'jobs que llaman a cs_correr_diario', '1',
       (select count(*) from jobs where command ~ 'cs_correr_diario')::text,
       (select count(*) from jobs where command ~ 'cs_correr_diario') = 1
union all
select '09 la prueba de humo no dejo datos', 'programas humo123* / canales / envios', '0',
       ((select count(*) from public.cs_programas where id like 'humo123%')
        + (select count(*) from public.cs_servicio_envios where programa_id like 'humo123%')
        + (select count(*) from public.cs_discord_avisos where programa_id like 'humo123%'))::text,
       ((select count(*) from public.cs_programas where id like 'humo123%')
        + (select count(*) from public.cs_servicio_envios where programa_id like 'humo123%')
        + (select count(*) from public.cs_discord_avisos where programa_id like 'humo123%')) = 0
union all
select '10 humo ' || lpad(s.orden::text, 2, '0'), s.paso, 'true', s.detalle, s.ok from cs_smoke123 s
order by 1, 2;


-- =====================================================================
-- DESPUÉS DE CORRER (a mano, de a una)
-- =====================================================================
-- C11. Vista previa del mensaje real de un programa (no manda nada, no escribe nada):
--   select jsonb_pretty(public.cs_servicio_armar('teo'));
--   select jsonb_pretty(public.cs_servicio_armar('liam'));
--
-- C12. Morosos: cuántos se cruzan y cuántos no (liam tiene datos de Finanzas):
--   select * from public.cs_servicio_morosos('liam', 14);   -- cliente_id null = sin cruzar
--
-- C13. Cargar los 3 webhooks en Configuración > "Avisos por tipo" (canal Servicio), activar,
--      y apretar "Probar aviso de servicio". Después:
--   select e.id, e.created_at, e.programa_id, e.tipo, h.status_code, left(e.contenido, 80)
--   from cs_discord_avisos e left join net._http_response h on h.id = e.request_id
--   where e.tipo = 'servicio' order by e.id desc limit 10;
--
-- C14. Corridas del cron y registro por día:
--   select * from cs_servicio_envios order by id desc limit 20;
--   select j.jobname, d.status, d.return_message, d.start_time
--   from cron.job_run_details d join cron.job j using (jobid)
--   where j.jobname in ('cs_servicio', 'cs_diario') order by d.start_time desc limit 10;
--
-- C15. Acciones que NO hace esta migración (revisar a mano):
--   - El aviso de accionables de llamadas queda apagado (acc_llamada_dias = 0). Para prenderlo:
--     update cs_servicio_config set acc_llamada_dias = 7 where programa_id = 'teo';
--   - El digest viejo no se borra; para volver: ver VUELTA ATRÁS.


-- =====================================================================
-- VUELTA ATRÁS (comentada; correr de a bloques si hace falta)
-- =====================================================================
-- Reactivar el digest viejo (solo tiene efecto si cs_integraciones tiene webhook):
--   select cron.unschedule(jobid) from cron.job where jobname in ('cs_diario', 'cs_semanal');
--   select cron.schedule('cs_diario', '0 12 * * *',
--     $cron$ select public.cs_correr_diario(); select public.cs_digest_diario(); $cron$);
--   select cron.schedule('cs_semanal', '10 12 * * 1', $cron$ select public.cs_resumen_semanal(); $cron$);
--   (los valores originales están en cs_bak_123_cron)
--
-- Apagar el aviso de servicio:
--   select cron.unschedule(jobid) from cron.job where jobname = 'cs_servicio';
--
-- Sacar todo lo de la 123 (no borra datos de Producto; borra el registro de envíos de servicio):
--   drop function if exists public.cs_servicio_probar(text);
--   drop function if exists public.cs_servicio_cron(timestamptz, boolean);
--   drop function if exists public.cs_servicio_confirmar(timestamptz);
--   drop function if exists public.cs_servicio_enviar_programa(text, text, int, timestamptz, boolean);
--   drop function if exists public.cs_servicio_armar(text, date);
--   drop function if exists public.cs_servicio_morosos(text, int, date);
--   drop function if exists public.cs_servicio_limpio(text);
--   drop table if exists public.cs_servicio_envios;
--   drop table if exists public.cs_servicio_config;     -- la app vuelve a usar 7 / 10 de js/config.js
--   delete from public.cs_discord_canales where tipo = 'servicio';
--   alter table public.cs_discord_canales drop constraint if exists cs_discord_canales_tipo_chk;
--   alter table public.cs_discord_canales add constraint cs_discord_canales_tipo_check
--     check (tipo in ('satisfaccion', 'wins'));
--   -- cs_probar_discord_canal: restaurar desde cs_bak_123_funciones (definicion)
