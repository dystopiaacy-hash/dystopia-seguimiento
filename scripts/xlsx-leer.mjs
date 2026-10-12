/* Lector mínimo de xlsx (zip + XML), sin dependencias.
   leerXlsx(ruta) -> { hoja: filas[][] }. Las celdas con formato de fecha vienen
   como { fecha: <número de serie> }; las vacías, undefined. */
import fs from 'node:fs';
import zlib from 'node:zlib';

function unzip(buf) {
  let e = buf.length - 22;
  while (e >= 0 && buf.readUInt32LE(e) !== 0x06054b50) e--;
  if (e < 0) throw new Error('No es un xlsx válido (no se encontró el directorio del zip).');
  const n = buf.readUInt16LE(e + 10);
  let p = buf.readUInt32LE(e + 16);
  const files = {};
  for (let i = 0; i < n; i++) {
    const method = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const nlen = buf.readUInt16LE(p + 28), elen = buf.readUInt16LE(p + 30), clen = buf.readUInt16LE(p + 32);
    const off = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nlen);
    const lh = off + 30 + buf.readUInt16LE(off + 26) + buf.readUInt16LE(off + 28);
    const raw = buf.subarray(lh, lh + csize);
    files[name] = method === 0 ? raw : zlib.inflateRawSync(raw);
    p += 46 + nlen + elen + clen;
  }
  return files;
}

const dec = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'")
  .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(+d))
  .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
  .replace(/&amp;/g, '&');
const colNum = c => c.split('').reduce((a, ch) => a * 26 + ch.charCodeAt(0) - 64, 0) - 1;

export function leerXlsx(ruta) {
  const files = unzip(fs.readFileSync(ruta));
  const txt = n => (files[n] ? files[n].toString('utf8') : '');
  const sst = [];
  for (const m of txt('xl/sharedStrings.xml').matchAll(/<si>([\s\S]*?)<\/si>/g)) {
    sst.push(dec([...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map(x => x[1]).join('')));
  }
  const wb = txt('xl/workbook.xml');
  const rels = {};
  for (const m of txt('xl/_rels/workbook.xml.rels').matchAll(/<Relationship [^>]*>/g)) {
    const id = /Id="([^"]+)"/.exec(m[0])[1], t = /Target="([^"]+)"/.exec(m[0])[1];
    rels[id] = t.startsWith('/') ? t.slice(1) : 'xl/' + t;
  }
  const styles = txt('xl/styles.xml');
  const numFmts = {};
  for (const m of styles.matchAll(/<numFmt [^>]*numFmtId="(\d+)"[^>]*formatCode="([^"]*)"/g)) numFmts[m[1]] = m[2];
  const cellXfs = (/<cellXfs[^>]*>([\s\S]*?)<\/cellXfs>/.exec(styles) || [, ''])[1];
  const xfDate = [...cellXfs.matchAll(/<xf [^>]*numFmtId="(\d+)"/g)].map(m => {
    const id = +m[1];
    if ((id >= 14 && id <= 22) || (id >= 45 && id <= 47)) return true;
    const f = numFmts[m[1]];
    return !!f && /[dmy]/i.test(f.replace(/"[^"]*"|\[[^\]]*\]/g, '')) && !/^[#0.,%]+$/.test(f);
  });
  const out = {};
  for (const m of wb.matchAll(/<sheet [^>]*>/g)) {
    const name = dec(/name="([^"]*)"/.exec(m[0])[1]);
    const rid = /r:id="([^"]+)"/.exec(m[0])[1];
    const xml = txt(rels[rid]);
    const rows = [];
    for (const r of xml.matchAll(/<row [^>]*?r="(\d+)"[^>]*?(?:\/>|>([\s\S]*?)<\/row>)/g)) {
      const rn = +r[1];
      const cells = [];
      for (const c of (r[2] || '').matchAll(/<c ([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const a = c[1];
        const ref = /r="([A-Z]+)\d+"/.exec(a);
        if (!ref) continue;
        const t = (/t="([^"]+)"/.exec(a) || [])[1];
        const s = +((/s="(\d+)"/.exec(a) || [, 0])[1]);
        const body = c[2] || '';
        const v = (/<v>([\s\S]*?)<\/v>/.exec(body) || [])[1];
        let val = null;
        if (t === 's' && v != null) val = sst[+v];
        else if (t === 'inlineStr') val = dec([...body.matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map(x => x[1]).join(''));
        else if (t === 'str' || t === 'e') val = v != null ? dec(v) : null;
        else if (t === 'b') val = v === '1';
        else if (v != null) val = xfDate[s] ? { fecha: +v } : +v;
        if (val !== null && val !== '') cells[colNum(ref[1])] = val;
      }
      rows[rn - 1] = cells;
    }
    out[name] = rows;
  }
  return out;
}
