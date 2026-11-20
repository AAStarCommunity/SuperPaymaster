# Dedicated-keychain live run (2026-11-20)

`run.sh` is the end-to-end run behind the optional dedicated-keychain sequence in
`script/a6-collector/README.md`. Inputs: a **fake** keystore (`cast wallet new`) and **fake** passwords, both written
inline in the script and never used anywhere else. No real keystore, no real Keychain entry. On exit, a trap restores the
user keychain search list.

`bash run.sh <dir> <cast-dir> <helper>`. The fake keystore lives under `<dir>/home/.foundry/keystores`. `<dir>/home/Library`
was a symlink to the real `~/Library`: `security` reads the user search list from `$HOME/Library/Preferences`, and under a
different HOME it sees only the System keychain, so the first attempt failed closed with `keychain entry missing`.

Logs: `run-nightly.log` (cast 1.8.7-nightly 4e8874b) and `run-171.log` (cast 1.7.1). Both show the same sequence:
- step 6: signed, and `cast wallet verify` accepted it;
- step 7: after `lock-keychain`, failed closed within about 1 s with no dialog;
- step 8: after unlock, signed again;
- step 9: after deleting the entry, the lookup returns exit code 44;
- on exit: the search list is restored.

After the runs, `diff` against the saved original search list was empty. The auto-lock timer itself was not waited out.
