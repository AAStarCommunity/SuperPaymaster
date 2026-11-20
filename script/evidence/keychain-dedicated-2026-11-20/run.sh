#!/bin/bash
# Live run of the dedicated-keychain flow with a FAKE keystore + FAKE passwords. Restores the user search list on exit.
set -u
R="$1"; CASTDIR="$2"; HELPER="$3"
KC="$R/aastar-rq3-fake.keychain-db"; KCPW=kc-fake-pw-not-secret; KSPW=ks-fake-pw-not-secret; NAME=rq3-fake-test
ORIG=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
restore() {
  security delete-generic-password -s aastar-rq3-keystore -a $NAME "$KC" >/dev/null 2>&1
  # shellcheck disable=SC2086
  security list-keychains -d user -s $ORIG
  security delete-keychain "$KC" 2>/dev/null
  echo "RESTORE search list now:"; security list-keychains -d user
}
trap restore EXIT
step() { echo "== $*"; }
export PATH="$CASTDIR:/usr/bin:/bin"
step "cast $(cast --version | head -1)"
step "fake keystore"
ADDR=$(cast wallet new "$R/home/.foundry/keystores" "$NAME" --unsafe-password "$KSPW" 2>&1 | grep -oE '0x[0-9a-fA-F]{40}' | head -1); echo "addr=$ADDR"; ls "$R/home/.foundry/keystores"
step "1 create-keychain"; security create-keychain -p "$KCPW" "$KC"; echo rc=$?
step "2 set-keychain-settings -l -u -t 600"; security set-keychain-settings -l -u -t 600 "$KC"; echo rc=$?; security show-keychain-info "$KC" 2>&1
step "3 add to user search list"; security list-keychains -d user -s $ORIG "$KC"; echo rc=$?; security list-keychains -d user
step "4 add entry"; security add-generic-password -s aastar-rq3-keystore -a $NAME -w "$KSPW" "$KC"; echo rc=$?
step "5 dump ACL"; security dump-keychain -a "$KC" 2>/dev/null | grep -iE "applications|security|decrypt" | head -6
HASH=0x$(printf 'aastar-rq3-fake' | shasum -a 256 | cut -d' ' -f1)
sign() { HOME="$R/home" /usr/bin/python3 -I -B "$HELPER" --timeout "${1:-30}" cast wallet sign --account $NAME --no-hash "$HASH"; }
step "6 helper sign (unlocked)"; SIG=$(sign 30); echo "rc=$? sig=${SIG:0:12}…"
[ -n "$SIG" ] && { REC=$(cast wallet verify --address "$ADDR" --no-hash "$HASH" "$SIG" 2>&1 | tail -1); echo "verify: $REC"; }
step "7 lock-keychain; helper must fail closed"; security lock-keychain "$KC"; echo lockrc=$?; T=$(date +%s); OUT=$(sign 20 2>&1); echo "rc=$? after $(( $(date +%s)-T ))s out=[$OUT]"
step "8 unlock-keychain; helper recovers"; security unlock-keychain -p "$KCPW" "$KC"; SIG2=$(sign 30); echo "rc=$? sig=${SIG2:0:12}…"
step "9 delete entry; read-only check"; security delete-generic-password -s aastar-rq3-keystore -a $NAME "$KC" >/dev/null; echo rc=$?; security find-generic-password -s aastar-rq3-keystore -a $NAME >/dev/null 2>&1; echo "find rc=$? (44 = not found)"
