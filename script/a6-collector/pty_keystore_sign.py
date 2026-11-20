#!/usr/bin/python3
"""Sign one digest with `cast wallet sign`, typing the keystore password from the macOS Keychain.

Opt-in password source for castSigner (formal.mjs, `keystorePasswordSource: 'keychain'`).
Usage (the only accepted shape; anything else exits 2 before touching the keychain):

    pty_keystore_sign.py [--timeout SECONDS] cast wallet sign --account NAME --no-hash 0x<32 bytes>

* The password is read here, from `security find-generic-password -s aastar-rq3-keystore
  -a NAME -w`, into a bytearray. It is never accepted via argv or the environment and never
  passes through Node.
* cast runs on a fresh pseudo-terminal as its controlling terminal (new session). Its stdout is
  a separate pipe; the pty carries only the prompt and cast's stderr.
* The password is written exactly once, and only after the prompt has appeared on the pty AND
  the terminal's ECHO flag is off. The buffer is then zeroed.
* Only a single 0x-signature line from cast's stdout is relayed. pty output is drained and
  discarded: it is never printed, stored, or put into an error message.
* Any failure (no keychain entry, prompt or ECHO-off not seen in time, cast nonzero, unexpected
  stdout) exits nonzero with a fixed message. There is no fallback to another password source.

Standard library only.
"""
import os
import pty
import re
import resource
import select
import signal
import subprocess
import sys
import termios
import time

SERVICE = 'aastar-rq3-keystore'
NAME_RE = re.compile(r'[\w.-]+', re.ASCII)
HASH_RE = re.compile(r'0x[0-9a-fA-F]{64}', re.ASCII)
SIG_RE = re.compile(rb'^0x[0-9a-fA-F]{130}\n$')
PROMPT = b'Enter keystore password:'
DEFAULT_TIMEOUT = 120.0
# macOS canonical input allows 1024 bytes including the terminating newline.
MAX_SECRET = 1023


class Fail(Exception):
    """Carries only a fixed stage label and exit code; never any captured bytes."""

    def __init__(self, code, stage):
        super().__init__(stage)
        self.code = code
        self.stage = stage


def parse(argv):
    timeout = DEFAULT_TIMEOUT
    if argv[:1] == ['--timeout']:
        try:
            timeout = float(argv[1])
        except (IndexError, ValueError):
            raise Fail(2, 'usage')
        if not 0 < timeout <= 600:
            raise Fail(2, 'usage')
        argv = argv[2:]
    if (len(argv) != 7 or argv[:4] != ['cast', 'wallet', 'sign', '--account'] or argv[5] != '--no-hash'
            or not NAME_RE.fullmatch(argv[4]) or not HASH_RE.fullmatch(argv[6])):
        raise Fail(2, 'usage')
    return timeout, argv


def zero(buf):
    for i in range(len(buf)):
        buf[i] = 0


def read_keychain(name, deadline, security_path='/usr/bin/security'):
    """Return one preallocated buffer and its used length; caller zeroes the buffer."""
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    try:
        proc = subprocess.Popen([security_path, 'find-generic-password', '-s', SERVICE, '-a', name, '-w'],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                bufsize=0)
    except OSError:
        raise Fail(3, 'keychain unavailable')
    buf = bytearray(MAX_SECRET + 2)
    n = 0
    transferred = False
    try:
        fd = proc.stdout.fileno()
        while n < len(buf):
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                raise Fail(3, 'keychain timeout')
            got = proc.stdout.readinto(memoryview(buf)[n:])
            if not got:
                break
            n += got
        if n >= len(buf):
            raise Fail(3, 'keychain entry too long')
        try:
            status = proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise Fail(3, 'keychain timeout')
        if status != 0:
            raise Fail(3, 'keychain entry missing')
        if n and buf[n - 1] == 0x0A:
            n -= 1
        if n > MAX_SECRET:
            raise Fail(3, 'keychain entry too long')
        if n == 0 or any(buf[i] in (0x0A, 0x0D) for i in range(n)):
            raise Fail(3, 'keychain entry unusable')
        transferred = True
        return buf, n
    finally:
        if not transferred:
            zero(buf)
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        proc.stdout.close()


def drain(fd, sink):
    """Read whatever is available from fd into sink; return False on EOF."""
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        return False
    if not chunk:
        return False
    sink += chunk
    return True


def kill(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def sign(timeout, argv, security_path='/usr/bin/security', cast_path='cast'):
    deadline = time.monotonic() + timeout
    secret, secret_len = read_keychain(argv[4], deadline, security_path)
    out_r = out_w = None
    try:
        out_r, out_w = os.pipe()
        pid, master = pty.fork()
    except OSError:
        zero(secret)
        for fd in (out_r, out_w):
            if fd is not None:
                os.close(fd)
        raise Fail(4, 'pty unavailable')
    if pid == 0:
        # Child: new session with the pty slave as controlling terminal (pty.fork does setsid).
        try:
            zero(secret)
            os.dup2(out_w, 1)
            os.close(out_r)
            os.close(out_w)
            os.execvp(cast_path, argv)
        finally:
            os._exit(127)
    os.close(out_w)
    tty_seen = bytearray()   # pty output: inspected for the prompt only, then discarded
    stdout = bytearray()
    written = False
    exited = None
    succeeded = False
    try:
        # Phase 1: wait for the prompt AND ECHO off, then type the password once.
        while not written:
            if time.monotonic() >= deadline:
                raise Fail(5, 'password prompt timeout')
            if PROMPT in tty_seen:
                try:
                    lflag = termios.tcgetattr(master)[3]
                except termios.error:
                    raise Fail(5, 'pty closed before prompt')
                if not lflag & termios.ECHO:
                    view = memoryview(secret)[:secret_len]
                    try:
                        while view:
                            view = view[os.write(master, view):]
                        os.write(master, b'\n')
                    finally:
                        view.release()
                        zero(secret)
                    written = True
                    break
            ready = select.select([master, out_r], [], [], 0.01)[0]
            if master in ready and not drain(master, tty_seen):
                raise Fail(5, 'pty closed before prompt')
            if out_r in ready and not drain(out_r, stdout):
                raise Fail(5, 'cast exited before prompt')
            if len(tty_seen) > 65536:
                del tty_seen[:-1024]
        # Phase 2: collect stdout until cast exits.
        fds = [master, out_r]
        while exited is None or out_r in fds:
            if time.monotonic() >= deadline:
                raise Fail(6, 'cast timeout')
            if exited is None:
                wpid, status = os.waitpid(pid, os.WNOHANG)
                if wpid:
                    exited = status
            ready = select.select(fds, [], [], 0.01)[0] if fds else []
            if master in ready and not drain(master, tty_seen):
                fds.remove(master)
            if len(tty_seen) > 65536:
                del tty_seen[:]
            if out_r in ready and not drain(out_r, stdout):
                fds.remove(out_r)
            if len(stdout) > 4096:
                raise Fail(7, 'unexpected cast output')
        if not os.WIFEXITED(exited) or os.WEXITSTATUS(exited) != 0:
            raise Fail(6, 'cast failed')
        if not SIG_RE.match(bytes(stdout)):
            raise Fail(7, 'unexpected cast output')
        result = bytes(stdout)
        succeeded = True
        return result
    finally:
        zero(secret)
        zero(tty_seen)
        if not succeeded:
            # Descendants may still own the PTY/stdout after the leader was reaped.
            kill(pid)
        for fd in (master, out_r):
            try:
                os.close(fd)
            except OSError:
                pass
        zero(stdout)


def main(argv):
    try:
        timeout, cast_argv = parse(argv)
        signature = sign(timeout, cast_argv)
    except Fail as e:
        sys.stderr.write('pty keystore signing failed: %s\n' % e.stage)
        return e.code
    except Exception:  # never let a traceback (with locals/bytes) reach stderr
        sys.stderr.write('pty keystore signing failed: internal error\n')
        return 9
    sys.stdout.write(signature.decode('ascii'))
    sys.stdout.flush()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
