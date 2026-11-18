#!/usr/bin/env python3
"""Line protocol: Python gates request reads from the formal.mjs archived transport."""
import json
import sys
import plan_three_arm as q

def rpc(method,params):
    print(json.dumps(dict(method=method,params=params)),flush=True)
    response=json.loads(sys.stdin.readline())
    if 'result' not in response: raise ValueError('archived read failed')
    return response['result']

def main():
    request=json.loads(sys.stdin.readline()); bundle=q.load(request['bundle'])
    step=bundle['steps'][request['index']]; index,sid=step['id'].split('/',1)
    # JSON output is sorted by sender, so locate by the step's owner/step identity instead of map order.
    plan=next(p for p in bundle['plans'].values() if any(s['tx']==step['tx'] and s['id']==sid for s in p['steps']))
    local=next(s for s in plan['steps'] if s['id']==sid)
    if request['action']=='precheck':
        q.pre_send(rpc,plan)
        q.m.phase_c_pre_send(rpc,plan,local,{},deployment=plan['deploymentContext'])
    elif request['action']=='readback':
        for check in local['readbacks']: q.m.check_predicate(rpc,check,int(request['timestamp']))
    else: raise ValueError('unknown gate action')
    print(json.dumps(dict(done=True)),flush=True)

if __name__=='__main__':
    try: main()
    except Exception as error:
        print(json.dumps(dict(error=getattr(error,'record',{'gate':type(error).__name__}))),flush=True)
        sys.exit(1)
