import unittest

from slugify import slugify


class SlugifyTest(unittest.TestCase):
    def test_simple_title(self):
        self.assertEqual("hello-world", slugify("Hello World"))

    def test_collapses_whitespace_and_punctuation(self):
        self.assertEqual("hello-world", slugify("  Hello,   world!  "))

    def test_transliterates_common_unicode(self):
        self.assertEqual("creme-brulee", slugify("Crème brûlée"))

    def test_empty_punctuation_only_title(self):
        self.assertEqual("", slugify(" --- "))


if __name__ == "__main__":
    unittest.main()
