from pathlib import Path
import subprocess
baseline=Path('cache/deploylive-tests/round6b/baseline')
empty=Path('cache/deploylive-tests/round6b/empty');empty.write_text('')
p=Path('script/rehearsal/DEPLOYLIVE_VALIDATION.md')
prefix=p.read_text().split('## Round-6b per-file line counts')[0]
paths={str(f.relative_to(baseline)) for f in baseline.rglob('*') if f.is_file()}
paths.update(['contracts/test/scripts/DeployLiveNonce.t.sol'])
paths.update(str(f) for f in Path('contracts/test/fixtures/deploylive').glob('*'))
for _ in range(5):
 rows=[];removed=[]
 for name in sorted(paths):
  old=baseline/name;new=Path(name)
  if old.exists() and new.exists() and old.read_bytes()==new.read_bytes():continue
  r=subprocess.run(['git','diff','--no-index','--numstat',str(old if old.exists() else empty),str(new if new.exists() else empty)],capture_output=True,text=True)
  if not r.stdout:continue
  added,deleted,_=r.stdout.split('\t',2)
  if not new.exists():removed.append((Path(name).name,added,deleted))
  else:rows.append((name,added,deleted))
 text=prefix+'''## Round-6b per-file line counts

Compared with the starting uncommitted round-six snapshot using `git diff
--no-index --numstat`. Unchanged round-six files are omitted. Generated command
logs, compiler outputs, caches and the archival copy are excluded.

| File | Added | Deleted |
|---|---:|---:|
'''
 for name,a,d in rows:text+=f'| `{name}` | {a} | {d} |\n'
 text+='\nRemoved generated JSON records from the former rehearsal evidence directory\n(the pin contents are now in the fixture files above):\n\n| Removed file | Added | Deleted |\n|---|---:|---:|\n'
 for name,a,d in removed:text+=f'| `{name}` | {a} | {d} |\n'
 if text==p.read_text():break
 p.write_text(text)
print(p.read_text().split('## Round-6b per-file line counts')[1])
