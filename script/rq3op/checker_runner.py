#!/usr/bin/env python3
"""Execute the unchanged DeployLive checker with all state reads at one block."""
import json
import re
import runpy
import subprocess
import sys
from pinned_tools import PinnedTools
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]


def pin_command(command,block):
    if not re.fullmatch(r'0x[0-9a-fA-F]+',block):raise ValueError('invalid checker block')
    args=list(command)
    if Path(args[0]).name!='cast':return args
    if args[1] in ('keccak','calldata','sig','abi-encode'):return args
    if args[1] in ('call','code','balance','storage'):
        return [*args,'--block',block]
    if args[1]=='rpc':
        method=args[2]
        if method=='eth_chainId':return args
        if method=='eth_call':args[4]=block;return args
        if method=='eth_getLogs':
            query=json.loads(args[3]);query['toBlock']=block;args[3]=json.dumps(query);return args
    raise ValueError('unrecognized checker read')


def main():
    block,*arguments=sys.argv[1:]
    checker=ROOT/'script/rehearsal/deploylive_postdeploy_check.py'
    tools=PinnedTools()
    def pinned(command,*args,**kwargs):return tools.run(pin_command(command,block),*args,**kwargs)
    subprocess.run=pinned
    sys.path.insert(0,str(checker.parent))
    sys.argv=[str(checker),*arguments]
    runpy.run_path(str(checker),run_name='__main__')


if __name__=='__main__':main()
