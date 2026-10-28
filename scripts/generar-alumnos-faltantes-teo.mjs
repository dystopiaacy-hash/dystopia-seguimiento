/* Genera la carga de los alumnos de teo (NEC) que están en el Maestro del 28/10 y todavía no tienen ficha en la app (246).
   Fuente única: insumos/sheets-2026-10-28/MAESTRO_DE_CLIENTES_-_NEC/Hoja_1.csv (no hay xlsx de Finanzas en esa carpeta; la 125 ya cargó los de Pagos).
   Es una fila por pago: se juntan por nombre normalizado. Cada alumno nuevo trae además Concepto, Semana 2 / 4 / 6 y "Lo saqué del WPP / DS / skool"
   en campos_extra (las mismas claves que la 245), así que el orden entre la 245 y la 246 no importa.

   Uso (desde la carpeta del repo):
     node scripts/generar-alumnos-faltantes-teo.mjs --numero N [--hoy AAAA-MM-DD] [--dir insumos/sheets-2026-10-28]
   Salida: migraciones/N-maestros-datos-alumnos-teo.sql (gitignorado: datos personales). Se corre DOS veces (simulacro con error + resumen, después aplicar = 'si').

   Matcheo previo para no duplicar (en la base, con cs_norm_nombre / cs_norm_tel de la 070), contra TODAS las fichas de teo:
     - mismo nombre normalizado o misma pago_clave ('teo-xlsx|<nombre>', la de la 125)  -> ya existe: no se crea.
     - mismo teléfono (últimos 8 dígitos) o las palabras del nombre incluidas en las de otra ficha (o al revés) -> DUDOSO: no se crea, sale en la lista.
     - nada de lo anterior -> se crea.
   Reglas de la 125/128: plan Grupal / 1 a 1; fecha de inicio = primera fila del alumno; fin = inicio + 4 meses (6 si su primera fila es un RESELL);
   activo si el fin no pasó, finalizado si pasó, baja si lo sacaron del WPP / DS / skool antes de terminar. Nunca actualiza fichas existentes. */
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const QUI = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = n => { const i = args.indexOf(n); return i >= 0 ? args.splice(i, 2)[1] : null; };
const numero = flag('--numero');
const DIR = flag('--dir') || join(QUI, '..', 'insumos', 'sheets-2026-10-28');
let hoy = flag('--hoy');
if (!hoy) { const d = new Date(); hoy = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; }
if (!/^\d+$/.test(numero || '')) { console.error('Falta --numero N (el número lo asigna el jefe).'); process.exit(1); }
if (!/^\d{4}-\d{2}-\d{2}$/.test(hoy)) { console.error('--hoy debe ser AAAA-MM-DD'); process.exit(1); }

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
const norm = s => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const q = s => (s == null || String(s).trim() === '' ? 'null' : `'${String(s).trim().replace(/'/g, "''")}'`);
const fecha = v => { const m = /^(\d{4}-\d{2}-\d{2})/.exec(String(v ?? '').trim()); return m ? m[1] : null; };
const verdadero = v => /^(true|verdadero|si|sí|1)$/i.test(String(v ?? '').trim());
const tel = v => String(v ?? '').replace(/\.0+$/, '').replace(/[‪-‮]/g, '').trim();
/* Suma meses calendario (como la 128): 31/10 + 4 meses = 28/2 si hace falta, sin pasarse al mes siguiente. */
function sumarMeses(f, n) {
  const [a, m, d] = f.split('-').map(Number);
  const ult = new Date(Date.UTC(a, m - 1 + n + 1, 0)).getUTCDate();
  return new Date(Date.UTC(a, m - 1 + n, Math.min(d, ult))).toISOString().slice(0, 10);
}

const nec = csv(join(DIR, 'MAESTRO_DE_CLIENTES_-_NEC', 'Hoja_1.csv'));
const hn = nec[0].map(norm);
const ix = (...p) => hn.findIndex(h => p.some(x => h.startsWith(x)));
const N = { fecha: ix('fecha de carga'), prog: ix('programa'), nombre: ix('nombre del alumno'), tel: ix('numero'), concepto: ix('concepto'),
  s2: ix('semana 2'), s4: ix('semana 4'), s6: ix('semana 6'), wpp: ix('lo saque del wpp'), ds: ix('lo saque del ds'), skool: ix('lo saque de skool') };
for (const [k, v] of Object.entries(N)) if (v < 0) { console.error(`NEC: no encontré la columna "${k}". Encabezados: ${nec[0].join(' | ')}`); process.exit(1); }

const porNombre = new Map();
for (const f of nec.slice(1)) {
  const nombre = String(f[N.nombre] ?? '').replace(/\s+/g, ' ').trim();
  if (!nombre) continue;
  const k = norm(nombre);
  if (!porNombre.has(k)) porNombre.set(k, []);
  porNombre.get(k).push({ nombre, fecha: fecha(f[N.fecha]), prog: String(f[N.prog] ?? '').trim(), tel: tel(f[N.tel]), concepto: String(f[N.concepto] ?? '').trim(),
    s2: verdadero(f[N.s2]), s4: verdadero(f[N.s4]), s6: verdadero(f[N.s6]), wpp: verdadero(f[N.wpp]), ds: verdadero(f[N.ds]), skool: verdadero(f[N.skool]) });
}

const sinFecha = [];
const personas = [...porNombre.entries()].map(([k, rs]) => {
  rs.sort((a, b) => (a.fecha || '9999').localeCompare(b.fecha || '9999'));
  const primera = rs[0], ultima = rs[rs.length - 1];
  const inicio = rs.find(r => r.fecha)?.fecha || null;
  if (!inicio) sinFecha.push(primera.nombre);
  const ini = inicio && inicio <= hoy ? inicio : hoy;
  const fin = sumarMeses(ini, /resell|renov/i.test(primera.concepto) ? 6 : 4);
  const sacado = rs.some(r => r.wpp || r.ds || r.skool);
  const vigente = fin >= hoy;
  const plan = /1\s*a\s*1/i.test(ultima.prog) ? '1 a 1' : 'Grupal';
  const extra = { alta246: true };
  const conc = [...rs].reverse().find(r => r.concepto)?.concepto;
  if (conc) extra.x_concepto = conc;
  if (rs.some(r => r.s2)) extra.x_semana_2 = true;
  if (rs.some(r => r.s4)) extra.x_semana_4 = true;
  if (rs.some(r => r.s6)) extra.x_semana_6 = true;
  if (rs.some(r => r.wpp)) extra.x_saque_wpp = true;
  if (rs.some(r => r.ds)) extra.x_saque_ds = true;
  if (rs.some(r => r.skool)) extra.x_saque_skool = true;
  return { k, nombre: [...rs].sort((a, b) => b.nombre.length - a.nombre.length)[0].nombre, tel: rs.find(r => r.tel)?.tel || '', inicio: ini, fin,
    estado: sacado && vigente ? 'baja' : vigente ? 'activo' : 'finalizado', plan, extra };
});
personas.sort((a, b) => a.k.localeCompare(b.k));

const valores = personas.map(p => `  (${q('teo-xlsx|' + p.k)}, ${q(p.nombre)}, ${q(p.tel)}, '${p.inicio}', '${p.fin}', ${q(p.estado)}, ${q(p.plan)}, `
  + `${q('Alta desde el Maestro NEC del 28/10/2026 (246).')}, ${q(JSON.stringify(p.extra))}::jsonb)`).join(',\n');
const porEstado = personas.reduce((a, p) => (a[p.estado] = (a[p.estado] || 0) + 1, a), {});

const sql = `-- =====================================================================
-- ${numero}-maestros-datos-alumnos-teo.sql  ·  PRODUCTO: alumnos de teo (NEC) que faltan en la app
-- =====================================================================
-- GENERADO por scripts/generar-alumnos-faltantes-teo.mjs desde MAESTRO_DE_CLIENTES_-_NEC/Hoja_1.csv (${personas.length} alumnos distintos, hoy ${hoy}).
-- TIENE DATOS PERSONALES: gitignorado. No lo subas ni lo pegues en chats.
-- Correr DOS veces, evitando :00, :15, :30, :45 y las 9:00: 1) tal cual = SIMULACRO (termina en error con el resumen, no guarda nada);
-- 2) con aplicar = 'si' (sección 0). Requiere la 238 (columnas de teo) y la 113 (productos Grupal / 1 a 1). Se puede correr antes o después de la 245.
-- Matcheo previo (cs_norm_nombre / cs_norm_tel): mismo nombre o misma clave = ya existe; mismo teléfono o nombre contenido = DUDOSO (no se crea,
-- sale en el resumen); si no, se crea. Nunca actualiza fichas existentes. Cada ficha creada lleva campos_extra.alta246 = true (para deshacer).
-- Fecha de fin = inicio + 4 meses (6 si la primera fila es RESELL), como la 128. Estados al ${hoy}: ${Object.entries(porEstado).map(([k, v]) => `${k} ${v}`).join(', ')}.
-- =====================================================================
begin;
set local lock_timeout = '8s';
lock table public.cs_clientes, public.cs_accionables, public.cs_calls, public.cs_historial in share row exclusive mode;

-- 0. PARÁMETROS
drop table if exists pg_temp.imp_param;
create temp table imp_param (clave text primary key, valor text not null);
insert into imp_param values ('aplicar', 'no');   -- cambiá 'no' por 'si' para guardar

do $$
begin
  if not exists (select 1 from public.cs_programas where id = 'teo') then raise exception 'cs ${numero}: no existe el programa teo.'; end if;
  if to_regprocedure('public.cs_norm_nombre(text)') is null or to_regprocedure('public.cs_norm_tel(text)') is null then
    raise exception 'cs ${numero}: faltan cs_norm_nombre / cs_norm_tel (070).';
  end if;
  if not exists (select 1 from public.cs_maestro_columnas where programa_id = 'teo' and clave = 'x_concepto') then
    raise exception 'cs ${numero}: falta correr la 238 (teo no tiene la columna x_concepto).';
  end if;
  if to_regclass('public.cs_bak_${numero}_creados') is not null then raise exception 'cs ${numero}: ya se corrió (existe cs_bak_${numero}_creados).'; end if;
end $$;

-- 1. PLANILLA (un alumno por nombre normalizado)
drop table if exists pg_temp.imp${numero};
create temp table imp${numero} (clave text primary key, nombre text not null, telefono text, fecha_inicio date not null, fecha_fin date not null,
  estado text not null, plan text not null, notas text, campos_extra jsonb not null);
${personas.length ? `insert into imp${numero} values\n${valores};` : '-- (sin alumnos)'}

-- 2. CLASIFICACIÓN contra las fichas que ya hay en teo
drop table if exists pg_temp.clas${numero};
create temp table clas${numero} as
select i.*,
       exists (select 1 from public.cs_clientes c where c.programa_id = 'teo'
                 and (c.pago_clave = i.clave or public.cs_norm_nombre(c.nombre) = public.cs_norm_nombre(i.nombre))) as ya_existe,
       (select string_agg(c.nombre, ' / ') from public.cs_clientes c where c.programa_id = 'teo'
          and public.cs_norm_tel(i.telefono) is not null and public.cs_norm_tel(c.telefono) = public.cs_norm_tel(i.telefono)) as mismo_tel,
       (select string_agg(c.nombre, ' / ') from public.cs_clientes c where c.programa_id = 'teo'
          and public.cs_norm_nombre(c.nombre) is not null and public.cs_norm_nombre(c.nombre) <> public.cs_norm_nombre(i.nombre)
          and (string_to_array(public.cs_norm_nombre(c.nombre), ' ') <@ string_to_array(public.cs_norm_nombre(i.nombre), ' ')
            or string_to_array(public.cs_norm_nombre(i.nombre), ' ') <@ string_to_array(public.cs_norm_nombre(c.nombre), ' '))) as nombre_parecido
from imp${numero} i;

-- 3. ALTA (solo los que no existen y no son dudosos)
do $$
declare
  v_n int;
  v_txt text;
begin
  insert into public.cs_clientes
    (programa_id, nombre, email, telefono, fecha_inicio, fecha_fin, estado, plan, producto_id, notas, pago_clave, campos_extra)
  select 'teo', c.nombre, null, nullif(btrim(c.telefono), ''), c.fecha_inicio, c.fecha_fin, c.estado, c.plan,
         (select pr.id from public.cs_productos pr where pr.programa_id = 'teo'
            and public.cs_norm_nombre(pr.nombre) = public.cs_norm_nombre(c.plan) order by pr.orden limit 1),
         c.notas, c.clave, c.campos_extra
  from clas${numero} c
  where not c.ya_existe and c.mismo_tel is null and c.nombre_parecido is null
  order by c.nombre;
  get diagnostics v_n = row_count;

  create table public.cs_bak_${numero}_creados as
    select x.id, x.nombre, x.pago_clave, now() as creado_at from public.cs_clientes x
    where x.programa_id = 'teo' and x.campos_extra ? 'alta246';
  alter table public.cs_bak_${numero}_creados enable row level security;
  revoke all on table public.cs_bak_${numero}_creados from anon, authenticated;

  v_txt := format('alumnos distintos en NEC: %s | ya existían: %s | CREADOS: %s | DUDOSOS (no se crean): %s',
    (select count(*) from clas${numero}), (select count(*) from clas${numero} where ya_existe), v_n,
    (select count(*) from clas${numero} where not ya_existe and (mismo_tel is not null or nombre_parecido is not null)))
    || E'\\nDUDOSOS: ' || coalesce((select string_agg(nombre || ' -> ' || coalesce('mismo teléfono que ' || mismo_tel, '') ||
          case when mismo_tel is not null and nombre_parecido is not null then '; ' else '' end ||
          coalesce('nombre parecido a ' || nombre_parecido, ''), E'\\n  ' order by nombre)
        from clas${numero} where not ya_existe and (mismo_tel is not null or nombre_parecido is not null)), '-')
    || E'\\nCREADOS: ' || coalesce((select string_agg(nombre, '; ' order by nombre) from clas${numero}
        where not ya_existe and mismo_tel is null and nombre_parecido is null), '-');
  if (select valor from imp_param where clave = 'aplicar') <> 'si' then
    raise exception E'SIMULACRO (no se guardó nada). %', v_txt;
  end if;
  raise notice '%', v_txt;
end $$;

commit;

-- =====================================================================
-- CONTROLES (después del commit, de a uno)
-- =====================================================================
-- C1. Creados (los ids quedan en el respaldo). Estado y plan:
--   select estado, plan, count(*) from public.cs_clientes where programa_id = 'teo' and campos_extra ? 'alta246' group by 1, 2 order by 1, 2;
-- C2. Ninguno repetido por nombre normalizado en teo (esperado 0 filas):
--   select public.cs_norm_nombre(nombre), count(*) from public.cs_clientes where programa_id = 'teo' group by 1 having count(*) > 1;
-- C3. Segunda corrida: crea 0 (todos ya existen).
-- VUELTA ATRÁS (solo los creados por esta migración; si ya tienen llamadas o wins, revisar antes):
--   delete from public.cs_clientes c using public.cs_bak_${numero}_creados b where b.id = c.id;
`;

writeFileSync(join(QUI, '..', 'migraciones', `${numero}-maestros-datos-alumnos-teo.sql`), sql);
console.log(`Escribí migraciones/${numero}-maestros-datos-alumnos-teo.sql: ${personas.length} alumnos distintos en NEC. Estados: ${JSON.stringify(porEstado)}.`);
if (sinFecha.length) console.log(`Sin fecha de carga válida (se usa hoy): ${sinFecha.length}`);
