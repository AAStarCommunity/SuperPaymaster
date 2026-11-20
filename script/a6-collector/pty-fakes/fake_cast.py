#!/usr/bin/env python3
# Test-only stand-in for `cast wallet sign`: prompts on /dev/tty with ECHO on, records
# whether input arrived before ECHO was turned off, then reads the password.
import hashlib, json, os, select, sys, termios, time
rec = os.environ['FAKE_DIR']
mode = os.environ.get('FAKE_CAST_MODE', 'normal')
out = {'argv': sys.argv, 'env': dict(os.environ), 'mode': mode}
path = os.path.join(rec, 'records', 'cast-%d.json' % os.getpid())
def save():
    with open(path, 'w') as f: json.dump(out, f)
save()
tty = os.open('/dev/tty', os.O_RDWR)
if mode == 'noprompt':
    time.sleep(30); sys.exit(0)
if mode == 'echo-off-no-prompt':
    attrs = termios.tcgetattr(tty)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(tty, termios.TCSANOW, attrs)
    # Unrelated text containing 'password' must not count as the pinned prompt.
    os.write(tty, b'password backend ready')
    out['received_input'] = bool(select.select([tty], [], [], 1)[0])
    save()
    time.sleep(30); sys.exit(0)
os.write(tty, b'Enter keystore password:')
if mode == 'echo-stays-on':
    time.sleep(30); sys.exit(0)
# ECHO is still on here: any byte that arrives now would be echoed by the terminal.
r, _, _ = select.select([tty], [], [], 0.6)
out['early_input'] = bool(r)
save()
attrs = termios.tcgetattr(tty)
attrs[3] &= ~termios.ECHO
termios.tcsetattr(tty, termios.TCSANOW, attrs)
line = b''
while not line.endswith(b'\n'):
    chunk = os.read(tty, 1024)
    if not chunk: break
    line += chunk
if mode == 'count-lines':
    # Re-prompt and measure every line arriving during the observation window.
    os.write(tty, b'Enter keystore password:')
    until = time.monotonic() + 0.5
    while time.monotonic() < until:
        if select.select([tty], [], [], max(0, until - time.monotonic()))[0]:
            line += os.read(tty, 1024)
pw = line.rstrip(b'\n')
attrs[3] |= termios.ECHO
termios.tcsetattr(tty, termios.TCSANOW, attrs)
out['password_sha256'] = hashlib.sha256(pw).hexdigest()
out['writes'] = line.count(b'\n')
save()
if mode == 'hang-after':
    time.sleep(30)
if mode == 'leaky':
    os.write(tty, b'\r\nyou typed: ' + pw + b'\r\n')
    sys.stderr.write('debug password=' + pw.decode() + '\n')
if mode == 'leaky-stdout':
    sys.stdout.write(pw.decode() + '\n')
if mode == 'fail':
    sys.stderr.write('Error: wrong password ' + pw.decode() + '\n'); sys.exit(1)
sys.stdout.write(os.environ['FAKE_CAST_SIG'] + '\n')
