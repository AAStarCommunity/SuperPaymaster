"""Reduce Forge debug chunks to a complete, reviewable postOp gas trajectory.

At a child call, gas_cost includes forwarded gas. Retain the caller's unforwarded
regular gas and add it to each child step. Resume from the engine's actual caller
gas on return (which includes Amsterdam state-gas credits). Never sum clamped
nonnegative opcode costs to infer net consumption.
"""
import json, pathlib, sys

def reduce_trace(path):
    arena = json.loads(pathlib.Path(path).read_text())['debug_arena']
    assert len(postop_starts(arena)) == 1, 'exactly one proxy postOp required'
    result = reduce_arena(arena)[0]
    assert result['initial'] == 440000
    return result

def postop_starts(arena):
    return [i for i,n in enumerate(arena) if n["calldata"].startswith("0x7c627b21") and n["step_offset"] == 0 and n["kind"] == "CALL"]

def reduce_arena(arena):
    return [reduce_frame(arena, start) for start in postop_starts(arena)]

def reduce_frame(arena, start):
    first = arena[start]
    root = first['trace_node_idx']
    stack = []
    chunks = []
    low = initial = first['steps'][0]['gas_remaining']
    terminal = None
    for n in arena[start:]:
        idx = n['trace_node_idx']
        if stack and idx not in [f['id'] for f in stack] and stack[-1]['terminal']:
            break
        if idx in [f['id'] for f in stack]:
            while stack[-1]['id'] != idx: stack.pop()
        else:
            if stack:
                assert stack[-1]['last']['op'] in (0xf1,0xf2,0xf4,0xfa), 'descent must follow call'
                step = stack[-1]['last']
                stack[-1]['held'] = step['gas_remaining'] - step['gas_cost']
            stack.append({'id':idx, 'held':0, 'terminal':False})
        held = sum(f['held'] for f in stack[:-1])
        compact = []
        for s in n['steps']:
            total = held + s['gas_remaining']
            low = min(low, total)
            compact.append([s['pc'],s['op'],s['gas_remaining'],s['gas_cost'],s['state_gas_reservoir'],total])
        last = n['steps'][-1]
        stack[-1].update(last=last, terminal=last['op'] in (0x00,0xf3,0xfd,0xfe,0xff))
        chunks.append({'node':idx, 'kind':n['kind'], 'selector':n['calldata'][:10], 'step_offset':n['step_offset'], 'held_by_ancestors':held,'steps':compact})
        if idx == root and stack[-1]['terminal']:
            terminal = last['gas_remaining'] - last['gas_cost']
            low = min(low, terminal)
            break
    assert terminal is not None and initial > 0
    return {'columns':['pc','opcode','gas_remaining','gas_cost','state_gas_reservoir','regular_gas_in_frame_and_descendants'], 'initial':initial,'minimum_remaining':low,'peak':initial-low,'net':initial-terminal,'terminal':terminal,'chunks':chunks}

if __name__ == '__main__':
    result = reduce_trace(sys.argv[1])
    pathlib.Path(sys.argv[2]).write_text(json.dumps(result, separators=(',',':'))+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('chunks','columns')},indent=2))
