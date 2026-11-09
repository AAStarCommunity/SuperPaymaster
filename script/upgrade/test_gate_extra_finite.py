"""Constant contract-name domains found in the final R caller review."""
import ast
import copy
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch
from gate_assertions import assert_stop
import gate_r_domains as domains
import test_old_owner_isolation as fixture

CASES=[]


class FiniteIsolationTests(unittest.TestCase):
    pass


def extract_control(line,label,gate):
    def test(self):
        with tempfile.TemporaryDirectory() as directory:
            tree=Path(directory);arts=fixture.fixture_ast(tree)
            path=tree/'out/build-info/test.json';data=json.loads(path.read_text())
            source='contracts/src/'+('core/' if label=='Registry' else '')+label+'.sol'
            if source not in data['output']['sources']:
                clone=copy.deepcopy(data['output']['sources']['contracts/src/GToken.sol'])
                clone['ast']['nodes'][0]['name']=label
                data['output']['sources'][source]=clone
                data['input']['sources'][source]=copy.deepcopy(data['input']['sources']['contracts/src/GToken.sol'])
                arts[label]=copy.deepcopy(arts['GToken'])
                # Only the requested contract is selected by extract.
                del data['output']['sources']['contracts/src/GToken.sol']
            root=data['output']['sources'][source]['ast']['nodes'][0]
            if line==530:
                root['nodes']=[n for n in root['nodes'] if not n.get('constant')]
                if not any(n.get('name')=='hasRole' for n in arts[label]['abi']):
                    arts[label]['abi'].append(dict(type='function',name='hasRole',inputs=[dict(type='bytes32'),dict(type='address')],outputs=[dict(type='bool')]))
            path.write_text(json.dumps(data))
            if line==525:
                other=copy.deepcopy(data)
                members=other['output']['sources'][source]['ast']['nodes'][0]['nodes']
                # A second build artifact with a different source-derived authority/role.
                if any(n.get('name')=='owner' for n in members):
                    members[:]=[n for n in members if n.get('name')!='owner']
                else:
                    next(n for n in members if n.get('constant'))['value']=dict(nodeType='Literal',value='0')
                (path.parent/'zduplicate.json').write_text(json.dumps(other))
            with patch.object(fixture.a,'raw_artifact',side_effect=lambda t,n:arts[n]):
                with assert_stop(self,gate):fixture.o.extract(tree,(label,))
    return test


def event_control(label,gate):
    def test(self):
        # Execute the actual nested production code with a minimal role-history
        # fixture; no source predicates or gate calls are replaced.
        code=next(c for c in fixture.o.audit.__code__.co_consts if isinstance(c,types.CodeType) and c.co_name=='check_target')
        role=fixture.inventory()['TimelockController']['roles'][0]['value']
        spec=dict(hasRole=True,roles=[],authorities=[],mappings=[])
        bindings=dict(inventory={label:spec},pin={},histories={},history_counts={},declared_never={},
                      control_holders=set(),never_reads=[],old_role=lambda target,role:1,
                      negative=lambda *args:None,recorded=lambda *args:None,
                      role_control=lambda *args:None,role_owner=lambda *args:None,
                      word=lambda *args:0,addr=lambda *args:fixture.a.ZERO,probe=lambda *args:None)
        def cell(value):return (lambda:value).__closure__[0]
        fn=types.FunctionType(code,fixture.o.__dict__,closure=tuple(cell(bindings[k]) for k in code.co_freevars))
        with patch.object(fixture.o,'role_history',return_value=[role]):
            with assert_stop(self,gate):fn(label,fixture.u.TL)
    return test


for line in (525,530,704):
    for label in domains.isolation_labels(line):
        # old_owner_role_init_ids stops this input first; its shadow control and
        # paired deletion probe live in test_gate_dsr2.py / probe_gate_dsr2.py.
        if (line,label)==(530,'Registry'):continue
        gate={525:'old_owner_duplicate_source_',530:'old_owner_extraction_roles_',704:'old_owner_event_role_member_'}[line]+label
        name='test_extra_'+str(line)+'_'+label
        setattr(FiniteIsolationTests,name,event_control(label,gate) if line==704 else extract_control(line,label,gate))
        CASES.append((FiniteIsolationTests,name,gate,line))


if __name__=='__main__':unittest.main()
