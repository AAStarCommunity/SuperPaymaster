"""Accounting reconciliation and fail-closed evidence controls (standard library)."""
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('tuple_runner', ROOT/'script/evidence/tuple-validation-run.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
OUT=Path(sys.argv.pop(1)) if len(sys.argv)>1 else ROOT/'docs/design/aoa-balance-mode/data/tuple-validation/run'

class TupleEvidence(unittest.TestCase):
    def test_original_accounting(self):
        frame=(ROOT/'docs/design/aoa-balance-mode/data/nosubsidy-attribution/counterexample-frame-amsterdam.log').read_text().splitlines()[0]
        context=re.search(r'fallback\(1, 0x([a-f0-9]+),',frame)[1]
        words=[int(context[i:i+64],16) for i in range(0,len(context),64)]
        call,post,price,dec,aprice,snap=words[6:]
        self.assertEqual((call,post),(285665,465691))
        minpost,settle,wrap,cpost=[(snap>>(32*i))&((1<<32)-1) for i in range(4)]
        self.assertEqual((minpost,settle,wrap,cpost),(440000,420000,5000,340000))
        feebps=(snap>>128)-1
        self.assertEqual(feebps,1000)
        P=1044007212960250;F=1838299350952020;fee=1864881370
        trace=(ROOT/'docs/design/aoa-balance-mode/data/rams-g7/mechanism-g2-trace.log').read_text()
        entry=next(l for l in trace.splitlines() if 'innerHandleOp' in l and 'userOpHash: 0xb533' in l)
        pre=int(re.search(r'preOpGas: (\d+)',entry)[1])
        self.assertEqual(pre,548219)
        framegas=389218;wrapper=1834
        before=P//fee+framegas+wrapper
        used=before-pre
        penalty=max(0,(call+post-used)//10)
        self.assertEqual((before,used,penalty),(950877,402658,34869))
        self.assertEqual((before+penalty)*fee,F)
        ceil=lambda n,d:(n+d-1)//d
        buf=cpost+wrap+ceil(call+post,10)
        agas=ceil((P+buf*fee)*price*10**18,10**dec*aprice)
        charge=ceil(agas*(10000+feebps),10000)
        net=(charge*10000//(10000+feebps))*10**dec*aprice//(price*10**18)
        self.assertEqual((buf,agas,charge),(420136,189812111780906730370,208793322958997403407))
        self.assertEqual(F-net,10788338725450)
        self.assertEqual((F-net)//fee,5785)

    def test_complete_run(self):
        runner.verify(OUT)

    def test_resealed_missing_and_wrong_selector(self):
        for mutation in ('missing','selector','exit'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(dir='/tmp') as tmp:
                neg=Path(tmp)/'run';shutil.copytree(OUT,neg)
                rows=[json.loads(s) for s in (neg/'commands.jsonl').read_text().splitlines()]
                if mutation=='missing':rows.pop()
                if mutation=='selector':rows[0]['env']['TUPLE_CANDIDATE']='true'
                if mutation=='exit':rows[0]['exit']=99
                (neg/'commands.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
                runner.seal(neg)
                with self.assertRaises(AssertionError):runner.verify(neg)

if __name__=='__main__': unittest.main()
