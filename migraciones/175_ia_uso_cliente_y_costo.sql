-- 175: corrige ia_uso de las filas de Producto: cliente_id = cliente de la agencia (liam | agus | teo | dystopia)
--      y costo_usd recalculado donde está en null / 0 y hay tokens guardados.
-- Requiere: 137 (ia_uso), 001 (cs_programas, cs_clientes). NO corrida. Solo toca filas con app = 'producto'.
--
-- Qué escribía cada función ANTES y qué se hace con sus filas viejas:
--   en_que_esta  -> cliente_id = cs_clientes.id (uuid de la ficha)  => cs_clientes.programa_id
--   riesgo       -> cliente_id = cs_clientes.id (uuid de la ficha)  => cs_clientes.programa_id
--   dudas        -> cliente_id = id de programa                      => ya estaba bien, no se toca
--   chat_interno -> cliente_id = null                                => 'dystopia' (uso interno; antes no tenía cliente)
-- Una ficha que ya no existe en cs_clientes (uuid sin resolver) queda como está; el control C2 las cuenta.
-- Costo: mismos precios que supabase/functions/_shared/ia.ts (USD por millón de tokens):
--   claude-haiku-5-5 0,10 / 0,50 (si entrada > 100K: 0,50 / 2,50), claude-sonnet-5-5 2 / 10,
--   claude-haiku-4-5 y claude-haiku-4-5-20251001 1 / 5. Otro modelo o sin tokens: no se toca.
-- Las filas fallidas sin tokens (ok = false) quedan en null.

begin;
set local lock_timeout = '10s';
lock table public.ia_uso in share row exclusive mode;

do $$
begin
  if to_regclass('public.ia_uso') is null then raise exception '175: falta ia_uso (137)'; end if;
  if to_regclass('public.cs_bak_175_ia_uso') is not null then raise exception '175: ya fue corrida (existe cs_bak_175_ia_uso)'; end if;
end $$;

-- Respaldo: solo las filas que se van a cambiar, con los valores viejos.
create table public.cs_bak_175_ia_uso as
select u.id, u.cliente_id as cliente_id_viejo, u.costo_usd as costo_usd_viejo
from public.ia_uso u
where u.app = 'producto'
  and (
    (u.funcion in ('en_que_esta', 'riesgo')
       and u.cliente_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       and exists (select 1 from public.cs_clientes c where c.id::text = u.cliente_id))
    or (u.funcion = 'chat_interno' and u.cliente_id is null)
    or (coalesce(u.costo_usd, 0) = 0 and u.tokens_entrada is not null and u.tokens_salida is not null
        and u.modelo in ('claude-haiku-5-5', 'claude-sonnet-5-5', 'claude-haiku-4-5', 'claude-haiku-4-5-20251001'))
  );
alter table public.cs_bak_175_ia_uso enable row level security;   -- sin políticas: solo service role / postgres
revoke all on table public.cs_bak_175_ia_uso from public, anon, authenticated;

-- 1. cliente_id: ficha -> programa
update public.ia_uso u
set cliente_id = c.programa_id
from public.cs_clientes c
where u.app = 'producto' and u.funcion in ('en_que_esta', 'riesgo')
  and u.cliente_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and c.id::text = u.cliente_id;

-- 2. chat interno sin cliente -> 'dystopia'
update public.ia_uso set cliente_id = 'dystopia'
where app = 'producto' and funcion = 'chat_interno' and cliente_id is null;

-- 3. costo de las filas en 0 / null con tokens guardados
update public.ia_uso u
set costo_usd = round((
      case
        when u.modelo = 'claude-haiku-5-5' and u.tokens_entrada > 100000 then u.tokens_entrada * 0.50 + u.tokens_salida * 2.50
        when u.modelo = 'claude-haiku-5-5'  then u.tokens_entrada * 0.10 + u.tokens_salida * 0.50
        when u.modelo = 'claude-sonnet-5-5' then u.tokens_entrada * 2    + u.tokens_salida * 10
        else                                     u.tokens_entrada * 1    + u.tokens_salida * 5
      end) / 1000000.0, 6)
where u.id in (select id from public.cs_bak_175_ia_uso)
  and coalesce(u.costo_usd, 0) = 0 and u.tokens_entrada is not null and u.tokens_salida is not null
  and u.modelo in ('claude-haiku-5-5', 'claude-sonnet-5-5', 'claude-haiku-4-5', 'claude-haiku-4-5-20251001');

-- Verificación dentro de la transacción
do $$
declare v_mal int;
begin
  select count(*) into v_mal from public.ia_uso
   where app = 'producto' and funcion in ('en_que_esta', 'riesgo', 'chat_interno')
     and id in (select id from public.cs_bak_175_ia_uso) and cliente_id is null;
  if v_mal > 0 then raise exception '175: % filas siguen sin cliente', v_mal; end if;
end $$;

commit;

-- ---------------------------------------------------------------------
-- CONTROLES (correr de a uno)
-- C1. Filas cambiadas por tipo de cambio.
--   select count(*) as respaldadas,
--          count(*) filter (where b.cliente_id_viejo is distinct from u.cliente_id) as cliente_cambiado,
--          count(*) filter (where b.costo_usd_viejo is distinct from u.costo_usd) as costo_cambiado
--   from public.cs_bak_175_ia_uso b join public.ia_uso u using (id);
-- C2. Filas de Producto cuyo cliente_id NO es un cliente de la agencia (esperado: 0, o las fichas ya borradas).
--   select funcion, count(*) from public.ia_uso
--   where app = 'producto' and (cliente_id is null or cliente_id not in ('liam', 'agus', 'teo', 'dystopia'))
--   group by 1;
-- C3. Filas de Producto con costo 0 o null y por qué (esperado: solo ok = false sin tokens, o modelo sin precio).
--   select modelo, ok, (tokens_entrada is null) as sin_tokens, count(*) from public.ia_uso
--   where app = 'producto' and coalesce(costo_usd, 0) = 0 group by 1, 2, 3;
-- C4. Gasto por cliente y mes (Producto).
--   select date_trunc('month', creado_en)::date as mes, cliente_id, modelo, count(*), sum(costo_usd)
--   from public.ia_uso where app = 'producto' group by 1, 2, 3 order by 1 desc, 5 desc;
-- C5. RLS del respaldo (esperado: true).
--   select relrowsecurity from pg_class where oid = 'public.cs_bak_175_ia_uso'::regclass;
--
-- VUELTA ATRÁS (en una transacción):
--   begin;
--   update public.ia_uso u set cliente_id = b.cliente_id_viejo, costo_usd = b.costo_usd_viejo
--   from public.cs_bak_175_ia_uso b where b.id = u.id;
--   -- drop table public.cs_bak_175_ia_uso;   -- solo si ya no se necesita
--   commit;
