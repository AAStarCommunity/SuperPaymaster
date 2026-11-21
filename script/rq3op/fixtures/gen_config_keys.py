#!/usr/bin/env python3
"""Extract only top-level key names and the exact-byte digest of a DeployLive config."""

import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    raw = args.config.read_bytes()
    config = json.loads(raw)
    if not isinstance(config, dict):
        parser.error('DeployLive config must be a JSON object')
    record = dict(schema='deploylive-config-keys/1',
                  sourceSha256=hashlib.sha256(raw).hexdigest(), keys=sorted(config))
    args.out.write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
