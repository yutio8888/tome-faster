import math
import unittest
from analyze_cpu import paired_summary


class PairedAnalysisChecks(unittest.TestCase):
    def test_constant_under_threshold(self):
        base = [100 + i for i in range(30)]
        result = paired_summary(base, [v * 1.005 for v in base])
        self.assertTrue(result['passes_less_than_1pct_added_user_cpu'])
        self.assertAlmostEqual(result['paired_geomean_change_pct'], .5, places=10)
        self.assertAlmostEqual(result['one_sided_95pct_upper_change_pct'], .5, places=10)

    def test_constant_over_threshold(self):
        result = paired_summary([100] * 30, [101.01] * 30)
        self.assertFalse(result['passes_less_than_1pct_added_user_cpu'])

    def test_variance_is_not_hidden_by_point_estimate(self):
        result = paired_summary([100] * 30, [95, 105] * 15)
        self.assertLess(result['paired_geomean_change_pct'], 0)
        self.assertGreater(result['one_sided_95pct_upper_change_pct'], 1)
        self.assertFalse(result['passes_less_than_1pct_added_user_cpu'])
        self.assertAlmostEqual(result['order_geomean_change_pct']['AB'], -5)
        self.assertAlmostEqual(result['order_geomean_change_pct']['BA'], 5)

    def test_bad_or_incomplete_samples_rejected(self):
        for values in ([1] * 29, [1] * 31, [1] * 29 + [0], [1] * 29 + [math.nan]):
            with self.assertRaises(ValueError):
                paired_summary(values, [1] * 30)


if __name__ == '__main__':
    unittest.main()
