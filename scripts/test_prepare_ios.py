import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare-ios.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ConfigurationTests(unittest.TestCase):
    def test_only_key_enters_config(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory)/'.env', Path(directory)/'Local.xcconfig'
            source.write_text('DROPBOX_APP_KEY="synthetic123"\nDROPBOX_APP_SECRET=never_copy_me\nOTHER=$(touch /tmp/should_not_exist)\n')
            module.prepare(source, output)
            self.assertEqual(output.read_text().splitlines()[-1], 'DROPBOX_APP_KEY = synthetic123')
            self.assertNotIn('never_copy_me', output.read_text())
            self.assertNotIn('OTHER', output.read_text())
    def test_rejects_executable_and_config_injection(self):
        for value in ['$(whoami)', 'abc // comment', 'abc\\nINJECT=1', '']:
            with tempfile.TemporaryDirectory() as directory:
                source, output = Path(directory)/'.env', Path(directory)/'out'
                source.write_text('DROPBOX_APP_KEY=' + value)
                with self.assertRaises(ValueError): module.prepare(source, output)
                self.assertFalse(output.exists())

if __name__ == '__main__': unittest.main()
