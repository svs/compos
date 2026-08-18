import unittest

from calculator import clamp


class ClampTest(unittest.TestCase):
    def test_inside_interval_is_unchanged(self):
        self.assertEqual(5, clamp(5, 0, 10))

    def test_below_interval_uses_lower_bound(self):
        self.assertEqual(0, clamp(-2, 0, 10))

    def test_above_interval_uses_upper_bound(self):
        self.assertEqual(10, clamp(12, 0, 10))


if __name__ == "__main__":
    unittest.main()
