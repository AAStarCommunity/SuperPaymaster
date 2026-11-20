#!/usr/bin/env python3
# Test-only stand-in for macOS `security`; never the real keychain.
import json, os, sys
rec = os.environ['FAKE_DIR']
with open(os.path.join(rec, 'records', 'security-%d.json' % os.getpid()), 'w') as f:
    json.dump({'argv': sys.argv, 'env': dict(os.environ)}, f)
a = sys.argv[1:]
ok = len(a) == 6 and a[0] == 'find-generic-password' and a[1] == '-s' and a[3] == '-a' and a[5] == '-w'
db = json.load(open(os.path.join(rec, 'keychain.json')))
key = '%s|%s' % (a[2], a[4]) if ok else None
if key not in db:
    sys.stderr.write('security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n')
    sys.exit(44)
sys.stdout.write(db[key] + '\n')
