#!/usr/bin/env python3
"""Execute DeployLive with pinned tool paths and a sanitized environment."""
import os
import runpy
import subprocess
import sys
from pinned_tools import PinnedTools
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]



def main():
    block,*arguments=sys.argv[1:]
    checker=ROOT/'script/rehearsal/deploylive_postdeploy_check.py'
    tools=PinnedTools()
    os.environ['DEPLOYLIVE_SNAPSHOT_BLOCK_HASH'] = block
    tools.env['DEPLOYLIVE_SNAPSHOT_BLOCK_HASH'] = block
    subprocess.run=tools.run
    sys.path.insert(0,str(checker.parent))
    sys.argv=[str(checker),*arguments]
    runpy.run_path(str(checker),run_name='__main__')


if __name__=='__main__':main()
