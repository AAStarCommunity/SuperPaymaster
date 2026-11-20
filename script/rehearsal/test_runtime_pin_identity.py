import copy
import unittest
from runtime_pins import check_runtime_pins


class RuntimePinIdentityTest(unittest.TestCase):
    def setUp(self):
        self.expected = {'artifacts': {'Example': {
            'immutableRanges': [
                dict(id='1', start='1', length='32', name='owner', type='address'),
                dict(id='1', start='40', length='32', name='owner', type='address')],
            'rawRuntimeKeccak': 'raw', 'maskedRuntimeKeccak': 'masked',
            'runtimeLength': '100', 'optimizerRuns': '500', 'hasImmutables': True}}}
        self.actual = copy.deepcopy(self.expected)
        for ref in self.actual['artifacts']['Example']['immutableRanges']:
            ref.pop('name')
            ref.pop('type')

    def test_ids_only(self):
        for ref in self.actual['artifacts']['Example']['immutableRanges']:
            ref['id'] = '999'
        check_runtime_pins(self.expected, self.actual, compare_types=False)

    def test_grouping_of_ranges_still_compares(self):
        # Ids are canonicalised per artifact by first appearance, so which ranges share an immutable
        # is still compared: the committed pin has both ranges on one immutable (same id).
        split = copy.deepcopy(self.actual)
        split['artifacts']['Example']['immutableRanges'][1]['id'] = '2'
        with self.assertRaisesRegex(ValueError, 'runtime pin mismatch'):
            check_runtime_pins(self.expected, split, compare_types=False)
        expected = copy.deepcopy(self.expected)
        expected['artifacts']['Example']['immutableRanges'][1].update(id='7', name='admin')
        merged = copy.deepcopy(self.actual)
        with self.assertRaisesRegex(ValueError, 'runtime pin mismatch'):
            check_runtime_pins(expected, merged, compare_types=False)
        renamed = copy.deepcopy(split)
        renamed['artifacts']['Example']['immutableRanges'][0]['id'] = '500'
        renamed['artifacts']['Example']['immutableRanges'][1]['id'] = '501'
        check_runtime_pins(expected, renamed, compare_types=False)

    def test_typed_build_ignores_ids_but_still_checks_descriptions(self):
        actual = copy.deepcopy(self.expected)
        for ref in actual['artifacts']['Example']['immutableRanges']:
            ref['id'] = '999'
        check_runtime_pins(self.expected, actual)
        actual['artifacts']['Example']['immutableRanges'][0]['type'] = 'uint256'
        with self.assertRaises(ValueError):
            check_runtime_pins(self.expected, actual)

    def test_other_fields_stay_strict(self):
        for key in ('rawRuntimeKeccak', 'maskedRuntimeKeccak', 'runtimeLength',
                    'optimizerRuns', 'hasImmutables'):
            actual = copy.deepcopy(self.actual)
            actual['artifacts']['Example'][key] = 'changed'
            with self.subTest(key=key), self.assertRaises(ValueError):
                check_runtime_pins(self.expected, actual, compare_types=False)

    def test_range_mutations(self):
        for mutation in ('start', 'length', 'count', 'order'):
            actual = copy.deepcopy(self.actual)
            refs = actual['artifacts']['Example']['immutableRanges']
            if mutation in ('start', 'length'):
                refs[0][mutation] = str(int(refs[0][mutation]) + 1)
            elif mutation == 'count':
                refs.pop()
            else:
                refs.reverse()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                check_runtime_pins(self.expected, actual, compare_types=False)

    def test_committed_descriptions_stay_validated_by_local_id(self):
        for mutation in ('missing', 'inconsistent'):
            expected = copy.deepcopy(self.expected)
            ref = expected['artifacts']['Example']['immutableRanges'][1]
            if mutation == 'missing':
                for item in expected['artifacts']['Example']['immutableRanges']:
                    item.pop('name')
            else:
                ref['type'] = 'uint256'
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                check_runtime_pins(expected, self.actual, compare_types=False)
