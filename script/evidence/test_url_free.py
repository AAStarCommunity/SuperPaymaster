"""Controls for url_free: endpoints are caught, ordinary forge output is not."""
from pathlib import Path
import tempfile
import unittest
from url_free import assert_dir_url_free, url_like

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT/'.codex-work'
TMP.mkdir(parents=True, exist_ok=True)


class UrlFree(unittest.TestCase):
    def test_endpoints_are_caught(self):
        for text, kind in [('rpc https://x.example/v2/key', 'scheme'), ('ws wss://node.invalid', 'scheme'),
                           ('node 1.2.3.4:8545', 'ipv4'), ('peer 10.0.0.1', 'ipv4'),
                           ('anvil localhost:8545', 'localhost-port'),
                           ('eth-sepolia.g.alchemy.com/v2/abc', 'hostname'), ('sepolia.gateway.tenderly.co', 'hostname'),
                           ('error resolving rpc.internal:8545', 'host-port'), ('dial [2001:db8::1]:8545', 'ipv6'),
                           ('peer 2001:db8::1', 'ipv6'), ('node fe80::1', 'ipv6')]:
            with self.subTest(text=text):
                self.assertIn(kind, url_like(text))

    def test_forge_output_is_not_flagged(self):
        for text in ['forge Version: 1.8.7-nightly', 'Solc 0.8.33 finished in 200.53s',
                     'Ran 16 tests for contracts/test/rams/RamsARouteRehearsal.t.sol:RamsARouteRehearsalTest',
                     'import {Vm} from "forge-std/Vm.sol";', 'abis/abi.config.json',
                     '0x0000000071727De22E5E9d8BAf0edAc6f37da032', 'Ran 1 test suite in 1.55s (1.55s CPU time)',
                     'Rams fork=tenderly block=12112256', '<url>',
                     # Paths, source lines, clock times and Rust-style identifiers are not endpoints.
                     '/tmp/work.dev/run/version.log', '~/Dev/x.dev/y', 'contracts/test/rams/RamsARouteRehearsal.t.sol:85',
                     '2026-11-12T01:28:11.5318925Z', 'foundry_evm::executors::invariant', 'abc::def', 'deploy-core.sh']:
            with self.subTest(text=text):
                self.assertEqual(url_like(text), [])

    def test_repository_file_list_is_not_flagged(self):
        # Executed-run snapshots record every tracked path; none may look like a host.
        import subprocess
        paths = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files'], text=True)
        self.assertEqual(url_like(paths), [])
        self.assertIn('hostname', url_like('deploy.example.com'))

    def test_directory_scan_names_file_not_match(self):
        with tempfile.TemporaryDirectory(dir=TMP) as d:
            d = Path(d)
            (d/'out').mkdir()
            (d/'out'/'C.json').write_text('{"urls": ["bzz-raw://abc", "dweb:/ipfs/x"]}')
            (d/'ok.log').write_text('16 tests passed')
            assert_dir_url_free(d)
            (d/'test.log').write_text('fork https://secret.invalid/token')
            with self.assertRaises(ValueError) as cm:
                assert_dir_url_free(d)
            self.assertIn('test.log: scheme', str(cm.exception))
            self.assertNotIn('secret.invalid', str(cm.exception))


if __name__ == '__main__':
    unittest.main(verbosity=2)
