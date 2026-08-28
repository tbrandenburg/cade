import unittest

from hello import greeting


class GreetingTest(unittest.TestCase):
    def test_default_greeting(self) -> None:
        self.assertEqual(greeting(), "Hello, world!")

    def test_named_greeting(self) -> None:
        self.assertEqual(greeting("Coder"), "Hello, Coder!")

    def test_empty_name_raises(self) -> None:
        with self.assertRaises(ValueError):
            greeting("")


if __name__ == "__main__":
    unittest.main()
