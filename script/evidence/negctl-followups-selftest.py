#!/usr/bin/env python3
"""Offline regressions against pinned pre-fix sources and reviewer mutations."""
import os
import pathlib
import re
import shutil
import subprocess
import sys

tmp, table, log = map(pathlib.Path, sys.argv[1:])
BASE = "94e940c5a1cfaf836ff9dfe55bb75a5736aba06a"
HELPER = "script/evidence/require-revert.sh"
SCANNER = "script/evidence/check-url-residue.sh"
HARNESS = "script/evidence/a2-read-failclosed-negctl.sh"
SELFTEST = "script/evidence/negctl-rg-absence-selftest.sh"
failures = 0


def run(argv, **kwargs):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def old(path):
    result = run(["git", "show", BASE + ":" + path])
    if result.returncode:
        raise RuntimeError(result.stderr.decode())
    return result.stdout.decode()


def save(name, content):
    path = tmp / name
    path.write_text(content)
    return str(path)


def row(name, old_rc, new_rc, expected, proof):
    global failures
    ok = (old_rc, new_rc) == expected
    failures += not ok
    with table.open("a") as stream:
        stream.write(f"{name}\t{old_rc}\t{new_rc}\t{proof}\n")
    with log.open("a") as stream:
        stream.write(f"{name}: old/mutant={old_rc} new={new_rc} expected={expected} {'PASS' if ok else 'FAIL'}\n")


old_helper = save("old-helper.sh", old(HELPER))
old_scanner = save("old-scanner.sh", old(SCANNER))
current_helper = pathlib.Path(HELPER).read_text()
reason = "execution reverted: custom error 0x118cdaa7"


def control(helper, message, expected, command_rc=1, newline=True, logfile=None):
    env = dict(os.environ, MESSAGE=message, EXPECTED=expected, RC=str(command_rc),
               FORMAT="%s\n" if newline else "%s")
    script = 'source "$1"; fake() { printf "$FORMAT" "$MESSAGE"; return "$RC"; }; require_revert "$2" probe "$EXPECTED" fake'
    return run(["bash", "-c", script, "bash", helper, str(logfile or tmp / "followup.log")], env=env).returncode


row("cast-missing-selector", control(old_helper, "Error: " + reason, "execution reverted"),
    control(HELPER, "Error: " + reason, "execution reverted: custom error "),
    (0, 2), "pinned-helper")

for name, message in [
    ("cast-wrong-selector", "Error: execution reverted: custom error 0xc52a9bd3"),
    ("cast-invalid-implementation", "Error: execution reverted: ERC1967InvalidImplementation"),
]:
    row(name, control(old_helper, message, "execution reverted"), control(HELPER, message, reason),
        (0, 2), "pinned-helper")

for name, prefix in [("estimate", "Error: Failed to estimate gas: server returned an error response: error code 3: "),
                     ("server", "Error: server returned an error response: error code 3: "),
                     ("direct", "Error: ")]:
    message = prefix + reason + ', data: "0x118cdaa7": OwnableUnauthorizedAccount'
    row("cast-format-" + name, control(old_helper, message, "execution reverted"),
        control(HELPER, message, reason), (0, 0), "real-cast-format")

row("cast-final-line-no-newline", control(old_helper, "Error: " + reason, "execution reverted", newline=False),
    control(HELPER, "Error: " + reason, reason, newline=False), (2, 0), "pinned-helper")

# Removing transport rejection must be caught even when revert evidence is present.
transport_start = current_helper.index("  if env -u GREP_OPTIONS")
transport_end = current_helper.index("  while IFS=", transport_start)
transport_mutant = save("transport-mutant.sh", current_helper[:transport_start] + current_helper[transport_end:])
message = "Error: " + reason + " (connection refused)"
row("transport-with-valid-revert", control(transport_mutant, message, reason),
    control(HELPER, message, reason), (0, 2), "M5-mutant")

for mutation, replacement in [("M2", '*"$expected"*'), ("M4", '*"script failed: $expected"*')]:
    needle = '"Error: script failed: $expected"*'
    assert current_helper.count(needle) == 1
    mutant = save(mutation + ".sh", current_helper.replace(needle, replacement))
    for name, message in [("trace", "└─ ← [Revert] roles attestation: missing; script failed: roles attestation: missing"),
                          ("source", '  revert("roles attestation: missing; script failed: roles attestation: missing")')]:
        row(f"forge-{name}-quote-{mutation}", control(mutant, message, "roles attestation: missing"),
            control(HELPER, message, "roles attestation: missing"), (0, 2), mutation + "-mutant")

for kind in ("cast", "forge"):
    logfile = tmp / (kind + "-readonly.log")
    expected = reason if kind == "cast" else "roles attestation: missing"
    message = "Error: " + reason if kind == "cast" else "Error: script failed: " + expected
    logfile.write_text(message + "\n")
    logfile.chmod(0o444)
    old_rc = control(old_helper, message, "execution reverted" if kind == "cast" else expected, 0, logfile=logfile)
    new_rc = control(HELPER, message, expected, 0, logfile=logfile)
    row(kind + "-readonly-stale-log", old_rc, new_rc, (0, 2), "pinned-helper")
    logfile.chmod(0o644)

# An unwritable log must reject before the command runs.
directory_log = tmp / "directory-log"
directory_log.mkdir()
marker = tmp / "command-ran"
script = 'source "$1"; fake() { : >"$MARKER"; }; require_revert "$2" probe "$3" fake'
env = dict(os.environ, MARKER=str(marker))
old_rc = run(["bash", "-c", script, "bash", old_helper, str(directory_log), reason], env=env).returncode
old_ran = marker.exists()
if old_ran:
    marker.unlink()
rc = run(["bash", "-c", script, "bash", HELPER, str(directory_log), reason], env=env).returncode
row("unwritable-log-command-not-run", 0 if old_ran else 2,
    rc if not marker.exists() else 0, (2, 2), "pinned-helper-command-invocation")

for name in ("sibling-cycle", "outside-cycle", "diamond"):
    root = tmp / name
    root.mkdir()
    target = root if name != "outside-cycle" else tmp / "outside-cycle-target"
    if target != root:
        target.mkdir()
        (root / "external").symlink_to(target, target_is_directory=True)
    (target / "a").mkdir()
    (target / "b").mkdir()
    (target / "a" / "tob").symlink_to("../b", target_is_directory=True)
    if name != "diamond":
        (target / "b" / "toa").symlink_to("../a", target_is_directory=True)
    for path in (tmp / "no-rg", tmp / "with-rg"):
        env = dict(os.environ, PATH=str(path))
        old_rc = run(["bash", old_scanner, str(root)], env=env).returncode
        new_rc = run(["bash", SCANNER, str(root)], env=env).returncode
        has_rg = (path / "rg").exists()
        expected = (0, 0) if name == "diamond" else (2 if has_rg else 0, 2)
        row(name + "-" + path.name, old_rc, new_rc, expected, "pinned-scanner")


def redactor(source):
    return source.split("import os, pathlib, re, sys\n", 1)[1].split("\nPY\n", 1)[0]


for name, source in [("old", old(HARNESS)), ("new", pathlib.Path(HARNESS).read_text())]:
    root = tmp / (name + "-hardlink-root")
    root.mkdir()
    outside = tmp / (name + "-hardlink-outside")
    outside.write_text("https://example.invalid/hardlink\n")
    os.link(outside, root / "hard")
    script = save(name + "-redactor.py", "import os, pathlib, re, sys\n" + redactor(source))
    rc = run([sys.executable, script, str(root)]).returncode
    untouched = outside.read_text() == "https://example.invalid/hardlink\n"
    if name == "old":
        old_rc = rc if not untouched else 2
    else:
        row("redactor-outside-hardlink", old_rc, rc if untouched else 0, (0, 1), "pinned-redactor")

for kind, path in [("fork", "script/evidence/d5b-fork-rehearsal.sh"), ("anvil", "scripts/d5b-anvil-rehearsal.sh")]:
    source = pathlib.Path(path).read_text()
    readiness = source.split("anvil_ready=0\n", 1)[1].split('\nif [ "$anvil_ready" -ne 1 ]; then', 1)
    readiness = "anvil_ready=0\n" + readiness[0] + '\nif [ "$anvil_ready" -ne 1 ]; then' + readiness[1].split("\n", 1)[0]
    mutant_ready = readiness.replace("exit 1", ":")
    assert mutant_ready != readiness
    setup = 'cast() { return 1; }; sleep() { :; }; CAST=cast; OUT="$1"; RPC=offline; '
    def ready_rc(body):
        return run(["bash", "-c", setup + body + "\nexit 0", "bash", str(tmp)]).returncode
    row("readiness-guard-" + kind, ready_rc(mutant_ready), ready_rc(readiness), (0, 1), "T2-guard-mutant")
    wrapper = re.search(r"^must_fail\(\) \{.*?^\}", source, re.M | re.S).group() if kind == "fork" else re.search(r"^must_fail\(\).*", source, re.M).group()
    mutant = wrapper.replace('[ "$rc" -eq 0 ] || exit "$rc"', ':') if kind == "fork" else wrapper.replace('|| exit $?', '|| :')
    assert mutant != wrapper
    for name, message, command_rc in [("fake-exit-0", "Error: " + reason, 0),
                                       ("wrong-selector", "Error: execution reverted: custom error 0xc52a9bd3", 1),
                                       ("expected-revert", "Error: " + reason, 1)]:
        env = dict(os.environ, OUT=str(tmp), W=str(tmp))
        command = f'fake() {{ printf "%s\\n" "{message}"; return {command_rc}; }}; must_fail probe "{reason}" fake; exit 0'
        def wrapper_rc(body):
            return run(["bash", "-c", 'source "$1"; ' + body + "\n" + command, "bash", HELPER], env=env).returncode
        row(f"wrapper-{kind}-{name}", wrapper_rc(mutant), wrapper_rc(wrapper),
            (0, 0 if command_rc == 1 and name == "expected-revert" else 2), "M10/M11-mutant")

for name, source, missing in [("harness", pathlib.Path(HARNESS).read_text(), "git"),
                              ("scanner", pathlib.Path(SCANNER).read_text(), "grep")]:
    guard = re.search(r"^for tool in .*?^done", source, re.M | re.S).group() if name == "harness" else next(
        line for line in source.splitlines() if line.startswith("command -v grep"))
    setup = 'command() { if [ "$*" = "-v $MISSING" ]; then return 1; fi; builtin command "$@"; }; '
    env = dict(os.environ, MISSING=missing)
    def guard_rc(body):
        return run(["bash", "-c", setup + body + "\nexit 0"], env=env).returncode
    row("required-tool-guard-" + name, guard_rc(guard.replace("exit 2", ":")),
        guard_rc(guard), (0, 2), "T2-guard-mutant")

# Evaluate all five exact cast call-site lines using a local cast sig and an offline send fake.
cast = os.environ.get("CAST_BIN") or shutil.which("cast") or str(pathlib.Path.home() / ".foundry/bin/cast")
signatures = {
    "old EOA owner": ("OwnableUnauthorizedAccount(address)", "0x118cdaa7"),
    "guardian unpause": ("Unauthorized()", "0x82b42900"),
    "execute acceptOwnership": ("TimelockUnexpectedOperationState(bytes32,bytes32)", "0x5ead8eb5"),
}
for label, (signature, selector) in signatures.items():
    actual = run([cast, "sig", signature]).stdout.decode().strip()
    row("selector-" + signature.split("(")[0], "NA", 0 if actual == selector else 1,
        ("NA", 0), "local-cast-sig")

for path in (SCANNER, SELFTEST):
    mode = run(["git", "ls-tree", BASE, "--", path]).stdout.decode().split()[0]
    row("executable-" + pathlib.Path(path).stem, 0 if mode == "100755" else 1,
        0 if os.access(path, os.X_OK) else 1, (1, 0), "pinned-git-mode")

old_selftest, new_selftest = old(SELFTEST), pathlib.Path(SELFTEST).read_text()
def pinned(source):
    line = next(line for line in source.splitlines() if line.startswith("OLDREF="))
    return 0 if re.fullmatch(r"OLDREF=[0-9a-f]{40}", line) else 1
row("selftest-pinned-oldref", pinned(old_selftest), pinned(new_selftest), (1, 0), "source-pin")

# Simulate a host without rg or the Codex app bundle, using only discovery code.
old_discovery = old_selftest.split("rg_bin=", 1)[1].split("\ntmp=", 1)[0]
old_discovery = "rg_bin=" + old_discovery.replace("/Applications/Codex.app/Contents/Resources/rg", str(tmp / "absent-app-rg"))
new_discovery = "rg_bin=" + new_selftest.split("rg_bin=", 1)[1].split("\ntmp=", 1)[0]
env = dict(os.environ, PATH=str(tmp / "no-rg"), RG_BIN="")
old_rc = run(["bash", "-c", old_discovery], env=env).returncode
new_rc = run(["bash", "-c", new_discovery], env=env).returncode
row("selftest-optional-rg-no-app-bundle", old_rc, new_rc, (2, 0), "pinned-discovery-absent-installation")

for kind, path in [("fork", "script/evidence/d5b-fork-rehearsal.sh"), ("anvil", "scripts/d5b-anvil-rehearsal.sh")]:
    for line in pathlib.Path(path).read_text().splitlines():
        if not line.startswith("must_fail ") or not any(label in line for label in signatures):
            continue
        label = next(label for label in signatures if label in line)
        signature, selector = signatures[label]
        prelude = '''source "$1"
OUT="$2"; W="$2"; RPC=offline; OWNER=owner; MULTISIG=guardian; GOV_MULTISIG=governor
SP=proxy; NEW_SP=implementation; CURRENT_SP_IMPL=implementation; FRESH_TL=timelock
CAPPED=token; ACC_DATA=0x; ZERO32=zero; ACC_SALT=salt; CAST=cast
cast() {
  if [ "$1" = sig ]; then "$3" "$@"; return $?; fi
  if [[ " $* " == *" upgradeToAndCall(address,bytes) proxy "* ]]; then
    echo 'Error: execution reverted: ERC1967InvalidImplementation'; return 1
  fi
  echo "Error: execution reverted: custom error $SELECTOR"; return 1
}
must_fail() { require_revert "$OUT/callsite.log" "$@" || exit $?; }
'''.replace('"$3" "$@"', '"$REAL_CAST" "$@"')
        old_line = next(l for l in old(path).splitlines() if l.startswith("must_fail ") and label in l)
        for name, injected, want_old, want_new in [("expected", selector, 0, 0), ("wrong", "0xc52a9bd3", 0, 2)]:
            env = dict(os.environ, SELECTOR=injected, REAL_CAST=cast)
            def callsite_rc(source_line, helper):
                return run(["bash", "-c", prelude + source_line, "bash", helper, str(tmp)], env=env).returncode
            row(f"callsite-{kind}-{label.replace(' ', '-')}-{name}", callsite_rc(old_line, old_helper), callsite_rc(line, HELPER),
                (want_old, want_new), "pinned-callsite-offline-fake")
        if kind == "fork" and label == "old EOA owner":
            # Authorization removed: a proxy argument still reverts; a real implementation succeeds.
            no_auth = prelude.replace('echo "Error: execution reverted: custom error $SELECTOR"; return 1', 'return 0')
            env = dict(os.environ, SELECTOR=selector, REAL_CAST=cast)
            def no_auth_rc(source_line, helper):
                return run(["bash", "-c", no_auth + source_line, "bash", helper, str(tmp)], env=env).returncode
            row("fork-upgrade-authorization-removed", no_auth_rc(old_line, old_helper), no_auth_rc(line, HELPER),
                (0, 2), "pinned-callsite-offline-fake")

sys.exit(1 if failures else 0)
