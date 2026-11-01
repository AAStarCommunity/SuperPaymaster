import { realpathSync, readdirSync, lstatSync, readFileSync, writeFileSync, openSync, closeSync, existsSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { pathToFileURL } from 'node:url';
import { sha256 } from './evidence.mjs';
export function freeze(window, sampling) {
  window = resolve(window);
  sampling = resolve(sampling);
  if (realpathSync(window) !== window || realpathSync(sampling) !== sampling) throw new Error('symlink ancestors forbidden');
  if (existsSync(resolve(window,'manifest.json')) || existsSync(resolve(window,'manifest.sha256'))) throw new Error('window already frozen');
  // Exclusive persistent lock: an interrupted freeze requires investigation, never a retry that silently overwrites.
  closeSync(openSync(resolve(window,'.freeze-lock'), 'wx', 0o600));
  if (lstatSync(window).isSymbolicLink() || lstatSync(sampling).isSymbolicLink()) throw new Error('symlinks forbidden');
  const sample = readFileSync(sampling);
  if (resolve(sampling) !== resolve(window,'sampling-input.json')) writeFileSync(resolve(window,'sampling-input.json'), sample, { flag:'wx', mode:0o600 });
  const files = [];
  function walk(dir) {
    for (const name of readdirSync(dir).sort()) {
      const path = resolve(dir,name), stat = lstatSync(path);
      if (stat.isSymbolicLink()) throw new Error('symlinks forbidden in frozen window');
      if (stat.isDirectory()) walk(path);
      else if (stat.isFile()) {
        if (relative(window,path).startsWith('raw/') && path.endsWith('.ndjson') && readFileSync(path,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse).some(r=>r.credentialFlag)) throw new Error('credential flagged archive cannot be frozen');
        files.push({ path:relative(window,path), sha256:sha256(readFileSync(path)) }); }
      else throw new Error('non-regular window entry');
    }
  }
  walk(window);
  const manifest = JSON.stringify({ schemaVersion:'a6-freeze/1', frozenAt:new Date().toISOString(), sampling:{ path:'sampling-input.json', sha256:sha256(sample) }, files }, null, 2)+'\n';
  writeFileSync(resolve(window,'manifest.json'), manifest, { flag:'wx', mode:0o600 });
  writeFileSync(resolve(window,'manifest.sha256'), sha256(manifest)+'  manifest.json\n', { flag:'wx', mode:0o600 });
  return JSON.parse(manifest);
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { if (process.argv[3] !== '--sampling' || !process.argv[4]) throw new Error('usage: freeze.mjs <window> --sampling <DSR-file>'); freeze(process.argv[2],process.argv[4]); }
  catch(e) { console.error(e.message); process.exitCode=2; }
}
