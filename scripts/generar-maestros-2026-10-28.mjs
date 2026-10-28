/* Genera la carga de datos que NO cubren los otros generadores, desde los CSV de insumos/sheets-2026-10-28:
     - teo (NEC, Hoja 1): Concepto, Semana 2 / 4 / 6 y "Lo saqué del WPP / DS / skool" en campos_extra de la ficha.
     - liam (BPF, Llamadas Producto): filas de la pestaña en cs_llamadas_producto (238).
   Liam (Maestro) y agus (DCAC) se cargan con sus generadores de siempre (ver ESTADO-APP).

   Uso (desde la carpeta del repo):
     node scripts/generar-maestros-2026-10-28.mjs --numero N [--dir insumos/sheets-2026-10-28]

   - Salida: migraciones/N-maestros-datos-2026-10-28.sql (gitignorado: tiene datos personales).
   - Método de la 080: se corre DOS veces. Tal cual es un SIMULACRO (termina en error con el resumen y los dudosos);
     con aplicar = 'si' (sección 0) guarda. Requiere la 238 corrida.
   - NO crea alumnos de teo: los que no están en la app salen en la lista "no encontrados" (los crea la 246,
     scripts/generar-alumnos-faltantes-teo.mjs, que además les carga estos mismos datos; se puede correr antes o después).
     NO pisa valores que la ficha ya tenga (gana lo que está en la app) y guarda respaldo de campos_extra en cs_bak_N_maestros.
   - Llamadas Producto: la tabla es EDITABLE en la app, así que acá solo se INSERTAN las filas que faltan (por fila de la hoja);
     una fila que ya está (o que se editó) no se pisa. Se empareja con la ficha de liam por nombre normalizado si hay una sola. */
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const QUI = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = n => { const i = args.indexOf(n); return i >= 0 ? args.splice(i, 2)[1] : null; };
const numero = flag('--numero');
const DIR = flag('--dir') || join(QUI, '..', 'insumos', 'sheets-2026-10-28');
if (!/^\d+$/.test(numero || '')) { console.error('Falta --numero N (el número lo asigna el jefe).'); process.exit(1); }

function csv(ruta) {
  const t = readFileSync(ruta, 'utf8').replace(/^﻿/, '');
  const filas = []; let f = [], c = '', q = false;
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    if (q) { if (ch === '"') { if (t[i + 1] === '"') { c += '"'; i++; } else q = false; } else c += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { f.push(c); c = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && t[i + 1] === '\n') i++; f.push(c); c = ''; filas.push(f); f = []; }
    else c += ch;
  }
  if (c !== '' || f.length) { f.push(c); filas.push(f); }
  return filas;
}
const norm = s => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '');
const q = s => (s == null || String(s).trim() === '' ? 'null' : `'${String(s).trim().replace(/'/g, "''")}'`);
const fecha = v => { const m = /^(\d{4}-\d{2}-\d{2})/.exec(String(v ?? '').trim()); return m ? m[1] : null; };
const verdadero = v => /^(true|verdadero|si|sí|1)$/i.test(String(v ?? '').trim());

/* ---------- NEC (teo) ---------- */
const nec = csv(join(DIR, 'MAESTRO_DE_CLIENTES_-_NEC', 'Hoja_1.csv'));
const hn = nec[0].map(norm);
const ix = (...partes) => hn.findIndex(h => partes.some(p => h.startsWith(p)));
const N = { fecha: ix('fechadecarga'), nombre: ix('nombredelalumno'), concepto: ix('concepto'), s2: ix('semana2'), s4: ix('semana4'),
  s6: ix('semana6'), wpp: ix('losaquedelwpp'), ds: ix('losaquedelds'), skool: ix('losaquedeskool') };
for (const [k, v] of Object.entries(N)) if (v < 0) { console.error(`NEC: no encontré la columna "${k}". Encabezados: ${nec[0].join(' | ')}`); process.exit(1); }
const filasNec = nec.slice(1).map((f, i) => ({ fila: i + 2, f })).filter(({ f }) => String(f[N.nombre] ?? '').trim());
const necSql = filasNec.map(({ fila, f }) => `  (${fila}, ${q(f[N.nombre].replace(/\s+/g, ' '))}, ${fecha(f[N.fecha]) ? `'${fecha(f[N.fecha])}'` : 'null'}, `
  + `${q(f[N.concepto])}, ${verdadero(f[N.s2])}, ${verdadero(f[N.s4])}, ${verdadero(f[N.s6])}, `
  + `${verdadero(f[N.wpp])}, ${verdadero(f[N.ds])}, ${verdadero(f[N.skool])})`).join(',\n');

/* ---------- BPF: Llamadas Producto ---------- */
const bpf = csv(join(DIR, 'Maestro_de_Clientes_BPF', 'Llamadas_Producto.csv'));
const filasLp = bpf.slice(1).map((f, i) => ({ fila: i + 2, f })).filter(({ f }) => String(f[3] ?? '').trim());
const lpSql = filasLp.map(({ fila, f }) => {
  const g = i => String(f[i] ?? '').trim();
  const extra = {};
  if (g(14)) extra.sin_nombre_col_15 = g(14);
  return `  (${fila}, ${q(g(0))}, ${fecha(g(1)) ? `'${fecha(g(1))}'` : 'null'}, ${q(g(2))}, ${q(g(3))}, ${q(g(4))}, ${q(g(5))}, ${q(g(6))}, `
    + `${q(g(7))}, ${q(g(8))}, ${q(g(9))}, ${q(g(10))}, ${q(g(11))}, ${q(g(12))}, ${q(g(13))}, ${q(g(15))}, ${q(JSON.stringify(extra))}::jsonb)`;
}).join(',\n');

const sql = `-- =====================================================================
-- ${numero}-maestros-datos-2026-10-28.sql  ·  PRODUCTO: datos extra de teo (NEC) y Llamadas Producto de liam (BPF)
-- =====================================================================
-- GENERADO por scripts/generar-maestros-2026-10-28.mjs (${filasNec.length} filas de NEC, ${filasLp.length} de Llamadas Producto).
-- TIENE DATOS PERSONALES: gitignorado. No lo subas ni lo pegues en chats.
-- Requiere la 238. ORDEN: correr DOS veces. 1) tal cual = SIMULACRO (termina en error con el resumen, no guarda nada);
-- 2) con aplicar = 'si' (sección 0). Evitar :00, :15, :30, :45 y las 9:00.
-- teo: una ficha por nombre normalizado (cs_norm_nombre). 1 ficha = se carga; 0 = "no encontrado"; 2 o más = "dudoso".
--      Dudosos y no encontrados NO se tocan: salen en el resumen. Los valores que la ficha ya tiene no se pisan.
--      Concepto = el de la fila más nueva del alumno; las casillas = true si alguna de sus filas lo marca.
-- =====================================================================
begin;
set local lock_timeout = '8s';
lock table public.cs_clientes in share row exclusive mode;

-- 0. PARÁMETROS
drop table if exists pg_temp.imp_param;
create temp table imp_param (clave text primary key, valor text not null);
insert into imp_param values ('aplicar', 'no');   -- cambiá 'no' por 'si' para guardar

do $$
begin
  if to_regclass('public.cs_llamadas_producto') is null then raise exception 'Falta correr la 238.'; end if;
  if not exists (select 1 from public.cs_maestro_columnas where programa_id = 'teo' and clave = 'x_concepto') then
    raise exception 'Falta correr la 238 (teo no tiene la columna x_concepto).';
  end if;
  if to_regclass('public.cs_bak_${numero}_maestros') is not null then raise exception 'La ${numero} ya se corrió (existe cs_bak_${numero}_maestros).'; end if;
end $$;

-- 1. PLANILLAS
drop table if exists pg_temp.imp_nec;
create temp table imp_nec (fila int, nombre text, fecha date, concepto text, s2 boolean, s4 boolean, s6 boolean,
  wpp boolean, ds boolean, skool boolean);
${filasNec.length ? `insert into imp_nec values\n${necSql};` : '-- (sin filas)'}

drop table if exists pg_temp.imp_lp;
create temp table imp_lp (fila int, encargado text, agendada date, llamada_txt text, nombre text, telefono text, email text, show_up text,
  estado text, contexto text, tipo_venta text, cc1 text, cc_seg text, cc_cerrado text, monto text, phatom text, extra jsonb);
${filasLp.length ? `insert into imp_lp values\n${lpSql};` : '-- (sin filas)'}

-- 2. teo: UNA fila por alumno (nombre normalizado) y su ficha
drop table if exists pg_temp.imp_teo;
create temp table imp_teo as
with por_nombre as (
  select public.cs_norm_nombre(n.nombre) as k, min(n.nombre) as nombre,
         (array_agg(n.concepto order by n.fecha desc nulls last, n.fila desc) filter (where nullif(btrim(n.concepto), '') is not null))[1] as concepto,
         bool_or(n.s2) as s2, bool_or(n.s4) as s4, bool_or(n.s6) as s6,
         bool_or(n.wpp) as wpp, bool_or(n.ds) as ds, bool_or(n.skool) as skool
  from imp_nec n group by 1
)
select p.*, (select count(*) from public.cs_clientes c where c.programa_id = 'teo' and public.cs_norm_nombre(c.nombre) = p.k) as fichas,
       (select c.id from public.cs_clientes c where c.programa_id = 'teo' and public.cs_norm_nombre(c.nombre) = p.k limit 1) as cliente_id
from por_nombre p;

-- 3. RESPALDO + CARGA
create table public.cs_bak_${numero}_maestros as
  select c.id, c.programa_id, c.campos_extra, now() as respaldado_at
  from public.cs_clientes c join imp_teo i on i.cliente_id = c.id and i.fichas = 1;
alter table public.cs_bak_${numero}_maestros enable row level security;
revoke all on table public.cs_bak_${numero}_maestros from anon, authenticated;

create temp table imp_log (clave text primary key, n int not null);
do $$
declare
  v_n int;
begin
  update public.cs_clientes c set campos_extra = c.campos_extra || (
      select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
        select 'x_concepto' as k, to_jsonb(i.concepto) as v where i.concepto is not null and not (c.campos_extra ? 'x_concepto')
        union all select 'x_semana_2', 'true'::jsonb where i.s2 and not (c.campos_extra ? 'x_semana_2')
        union all select 'x_semana_4', 'true'::jsonb where i.s4 and not (c.campos_extra ? 'x_semana_4')
        union all select 'x_semana_6', 'true'::jsonb where i.s6 and not (c.campos_extra ? 'x_semana_6')
        union all select 'x_saque_wpp', 'true'::jsonb where i.wpp and not (c.campos_extra ? 'x_saque_wpp')
        union all select 'x_saque_ds', 'true'::jsonb where i.ds and not (c.campos_extra ? 'x_saque_ds')
        union all select 'x_saque_skool', 'true'::jsonb where i.skool and not (c.campos_extra ? 'x_saque_skool')) z)
  from imp_teo i
  where i.cliente_id = c.id and i.fichas = 1;
  get diagnostics v_n = row_count;
  insert into imp_log values ('teo_fichas_tocadas', v_n);

  insert into public.cs_llamadas_producto (programa_id, fila_origen, encargado, fecha_agendada, fecha_llamada_txt, nombre, telefono, email,
      show_up, estado_llamada, contexto, tipo_venta, cc_dia_1, cc_seguimiento, cc_trato_cerrado, monto_restante, phatom, extra, cliente_id)
  select 'liam', l.fila, l.encargado, l.agendada, l.llamada_txt, l.nombre, l.telefono, l.email, l.show_up, l.estado, l.contexto,
         l.tipo_venta, l.cc1, l.cc_seg, l.cc_cerrado, l.monto, l.phatom, l.extra,
         (select c.id from public.cs_clientes c where c.programa_id = 'liam' and public.cs_norm_nombre(c.nombre) = public.cs_norm_nombre(l.nombre)
            and (select count(*) from public.cs_clientes c2 where c2.programa_id = 'liam'
                   and public.cs_norm_nombre(c2.nombre) = public.cs_norm_nombre(l.nombre)) = 1)
  from imp_lp l
  on conflict (programa_id, fila_origen) do nothing;   -- editable en la app: lo que ya está no se pisa
  get diagnostics v_n = row_count;
  insert into imp_log values ('llamadas_producto_nuevas', v_n);
  insert into imp_log select 'llamadas_producto_ya_estaban', (select count(*) from imp_lp) - v_n;
  insert into imp_log select 'llamadas_producto_con_ficha', count(*) from public.cs_llamadas_producto where programa_id = 'liam' and cliente_id is not null;
end $$;

-- 4. RESUMEN (el simulacro termina acá con error: no guarda nada)
do $$
declare
  v_txt text;
begin
  v_txt := format('alumnos de NEC: %s | con 1 ficha en teo: %s | dudosos (2 o más fichas): %s | no encontrados: %s | %s',
    (select count(*) from imp_teo), (select count(*) from imp_teo where fichas = 1), (select count(*) from imp_teo where fichas > 1),
    (select count(*) from imp_teo where fichas = 0),
    (select string_agg(clave || ' = ' || n, ', ' order by clave) from imp_log));
  v_txt := v_txt || E'\\nDUDOSOS: ' || coalesce((select string_agg(nombre || ' (' || fichas || ')', '; ' order by nombre) from imp_teo where fichas > 1), '-')
                 || E'\\nNO ENCONTRADOS: ' || coalesce((select string_agg(nombre, '; ' order by nombre) from imp_teo where fichas = 0), '-');
  if (select valor from imp_param where clave = 'aplicar') <> 'si' then
    raise exception E'SIMULACRO (no se guardó nada). %', v_txt;
  end if;
  raise notice '%', v_txt;
end $$;

commit;

-- =====================================================================
-- CONTROLES (después del commit, de a uno)
-- =====================================================================
-- C1. Fichas de teo con valores nuevos.
--   select count(*) filter (where campos_extra ? 'x_concepto') as concepto, count(*) filter (where campos_extra ? 'x_saque_wpp') as wpp
--     from public.cs_clientes where programa_id = 'teo';
-- C2. Llamadas Producto (esperado: ${filasLp.length} la primera vez; si se corre de nuevo, 'nuevas' = 0 y 'ya estaban' = ${filasLp.length}).
--   select count(*) from public.cs_llamadas_producto where programa_id = 'liam';
-- VUELTA ATRÁS: update public.cs_clientes c set campos_extra = b.campos_extra from public.cs_bak_${numero}_maestros b where b.id = c.id;
--               delete from public.cs_llamadas_producto where programa_id = 'liam' and created_at >= (select min(respaldado_at) from public.cs_bak_${numero}_maestros);
--               (solo si nadie editó la tabla desde entonces; si ya hay ediciones, borrar a mano las filas de la hoja)
`;

const salida = join(QUI, '..', 'migraciones', `${numero}-maestros-datos-2026-10-28.sql`);
writeFileSync(salida, sql);
console.log(`Escribí ${salida}: NEC ${filasNec.length} filas, Llamadas Producto ${filasLp.length} filas.`);
