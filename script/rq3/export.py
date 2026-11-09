"""Offline CSV export and cross-window inventory verification using the pinned gate."""
import argparse
import csv
import importlib.util
import json
from pathlib import Path
from schedule import digest
from manifests import WindowStop

VENDOR = Path(__file__).parent / 'vendor' / 'paired_stats@82453054.py'
spec = importlib.util.spec_from_file_location('paired_stats_pinned', VENDOR)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
COLUMNS = sorted(gate.REQUIRED_COLUMNS | set(gate.OPTIONAL_INT_COLUMNS) |
                 {'sender', 'precheck_refused', 'failure_reason', 'retry_of', 'contextLength',
                  'C_POSTOP', 'C_WRAP', 'bufGas', 'feeSnap', 'price', 'decimals', 'aPriceUSD',
                  'unverified_columns', 'unusedGasPenaltyMin', 'unusedGasPenaltyMax',
                  'gasBeforePenaltyCandidates', 'actualTokenPriceWithMarkup', 'stop_reason', 'diagnostic',
                  'tokenChargeWeiVerified', 'reserveDeltaVerified', 'reserveDeltaDiagnostic',
                  'priceMarkup', 'preMarkupPriceMin', 'preMarkupPriceMax', 'eventTokenChargeWei', 'tokenChargeDiagnostic',
                  'blockNumber', 'tpmWindowFirstBlock', 'tpmWindowLastBlock',
                  'tpmWindowFirstBlockHash', 'tpmWindowLastBlockHash'})
ENVELOPE = ('tpmWindowFirstBlock', 'tpmWindowLastBlock', 'tpmWindowFirstBlockHash', 'tpmWindowLastBlockHash')


def check_tpm_envelope(rows):
    """DSR C: ONE first..last envelope per window, covering every broadcast row of the window.
    Per-row envelopes could skip a block between two attempts (Codex r9), missing a ConfigUpdated."""
    has_block = lambda r: r['blockNumber'] not in ('', None)
    tpm = [r for r in rows if r['arm'] == 'TokenPaymaster' and r['tpmWindowFirstBlockHash'] not in ('', None)]
    if not tpm:
        # A broadcast TPM row without any envelope in the window (e.g. missing settlement event)
        # would otherwise skip the ConfigUpdated scan entirely (Codex r10).
        if any(r['arm'] == 'TokenPaymaster' and has_block(r) for r in rows):
            raise ValueError('window_stop: tpm_window_envelope_missing')
        return
    envelopes = {tuple(str(r[k]) for k in ENVELOPE) for r in tpm}
    if len(envelopes) != 1:
        raise ValueError('window_stop: tpm_window_envelope_inconsistent')
    first, last = int(tpm[0]['tpmWindowFirstBlock']), int(tpm[0]['tpmWindowLastBlock'])
    blocks = [int(r['blockNumber']) for r in rows if has_block(r)]
    if blocks and not (first <= min(blocks) and max(blocks) <= last):
        raise ValueError('window_stop: tpm_window_envelope_does_not_cover_window')
def unverified(row):
    if row['arm'] == 'TokenPaymaster' and row.get('tokenChargeWeiVerified') is not True:
        return ['tokenChargeWei'] if row['tokenChargeWei'] not in ('', None) or row.get('tokenChargeDiagnostic') == 'pre_markup_price_ambiguous' else []
    return []


def normalized(records, include_unverified=False):
    rows = []
    for record in records:
        row = {key: record.get(key, '') for key in COLUMNS}
        if row['arm'] == 'SP' and str(row['feeSnap']) == '0':
            raise ValueError('window_stop: legacy_sp_context')
        # Always recomputed here; an incoming value is never trusted.
        flagged = unverified(row)
        row['unverified_columns'] = ';'.join(flagged)
        if not include_unverified:
            for key in flagged:
                row[key] = ''
        for field in ('success', 'warmup', 'injected', 'precheck_refused'):
            if type(row[field]) is not bool:
                raise ValueError(f'{field} must be a boolean')
        expected = gate.expected_exclusion(row)
        if row['exclusion_reason'] not in ('', expected):
            raise ValueError('wrong exclusion_reason')
        row['exclusion_reason'] = expected
        if row['precheck_refused']:
            if row['arm'] != 'SP' or row['success']:
                raise ValueError('only unsuccessful SP may be precheck_refused')
            for field in (*gate.BROADCAST_ONLY_COLUMNS, 'contextLength', 'bufGas', 'feeSnap', 'C_POSTOP', 'C_WRAP'):
                if row[field] not in ('', None):
                    raise ValueError('broadcast field on refused row: ' + field)
        if not row['success'] and not row['failure_reason']:
            raise ValueError('unsuccessful attempt requires failure_reason')
        if row['arm'] == 'SP' and int(row['paymasterPostOpGasLimit']) < 480000:
            raise ValueError('SP postOp limit must be >= 480000')
        rows.append(row)
    check_tpm_envelope(rows)
    return rows


def write_csv(path, rows):
    with Path(path).open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: str(v).lower() if type(v) is bool else v for k, v in row.items()})


def reject_stopped_rows(path):
    with Path(path).open(newline='') as handle:
        stopped = [r for r in csv.DictReader(handle) if r.get('stop_reason')]
    if stopped:
        error = WindowStop(stopped[0]['stop_reason'])
        error.rows = stopped
        error.diagnostic = stopped[0].get('diagnostic', '')
        error.args = (f"{error}: {stopped[0]['window_id']}/{stopped[0]['userOpHash']}: {error.diagnostic}",)
        raise error


def validate_csv(path):
    reject_stopped_rows(path)
    # Real gate parsing and row reconciliation, with cheap fixture statistics.
    # Official CLI uses its unchanged 10,000-resample constants.
    report = gate.analyse(Path(path), 'aoa', None, None, gate.BOOTSTRAP_SEED, 100)
    rows, _, _ = gate.load_rows(Path(path))
    incomplete = {b['pair_id']: b['block_slot'] for b in report['incomplete_blocks']}
    for row in rows:
        retry = row.get('retry_of')
        if retry and (retry not in incomplete or incomplete[retry] >= row['block_slot']):
            raise ValueError('retry must reference an earlier incomplete block in this window')
    return report


def inventory_entry(path):
    result = validate_csv(path)
    rows, sha, _ = gate.load_rows(Path(path))
    formal = [r for r in rows if not r['warmup'] and not r['injected']]
    slots = sorted({r['block_slot'] for r in formal})
    prior = result['schedule']['prior_formal_slots']
    if not slots or slots != list(range(prior, max(slots) + 1)):
        raise ValueError('inventory requires every consumed slot, including incomplete slots')
    return dict(window_id=result['window_id'], experiment_id=result['experiment_id'], csv_sha256=sha,
                prior_formal_slots=prior, slots=slots,
                reserve_delta_verified_count=sum(r['arm'] == 'SP' and r.get('reserveDeltaVerified') == 'true' for r in rows),
                # DSR 2026-11-09: TPM rows whose pre-markup interval does not fix the wei are left out of s_c
                # (tokenChargeWei exported empty, so the gate's sc_wei skips them); counted here per window.
                tpm_sc_excluded_unverified_count=sum(r['arm'] == 'TokenPaymaster' and r['success'] and
                                                     'tokenChargeWei' in str(r.get('unverified_columns') or '').split(';')
                                                     for r in rows),
                attempts=[{k: r[k] for k in ('pair_id', 'block_slot', 'arm', 'attempt_index', 'userOpHash')}
                          for r in formal])


def build_inventory(paths):
    windows, next_slot, pair_ids, hashes = [], 0, set(), set()
    for path in paths:
        entry = inventory_entry(path)
        if entry['prior_formal_slots'] != next_slot:
            raise ValueError('prior_formal_slots does not match earlier window inventory')
        if windows and (entry['experiment_id'] != windows[0]['experiment_id'] or
                        entry['window_id'] in {w['window_id'] for w in windows}):
            raise ValueError('mixed experiment or repeated window')
        pairs = {a['pair_id'] for a in entry['attempts']}
        ops = {a['userOpHash'] for a in entry['attempts'] if a['userOpHash']}
        if pairs & pair_ids or ops & hashes:
            raise ValueError('cross-window pair/userOp reuse')
        pair_ids.update(pairs)
        hashes.update(ops)
        next_slot = max(entry['slots']) + 1
        windows.append(entry)
    payload = dict(schema='rq3-attempt-inventory-v1', windows=windows, consumed_formal_slots=next_slot)
    return dict(payload=payload, sha256=digest(payload))


def export(path, records, include_unverified=False):
    rows = normalized(records, include_unverified)
    write_csv(path, rows)
    reject_stopped_rows(path)  # Keep the evidence CSV; never feed a stopped window to the gate.
    try:
        validate_csv(path)
    except Exception:
        Path(path).unlink()
        raise
    return rows


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--records', type=Path, required=True, help='JSON array of extracted attempts')
    parser.add_argument('--csv', type=Path, required=True)
    parser.add_argument('--earlier-csv', type=Path, action='append', default=[])
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--include-unverified', action='store_true',
                        help='keep supplied-state columns (still named in unverified_columns)')
    args = parser.parse_args()
    export(args.csv, json.loads(args.records.read_text()), args.include_unverified)
    args.inventory.write_text(json.dumps(build_inventory([*args.earlier_csv, args.csv]), indent=2) + '\n')
