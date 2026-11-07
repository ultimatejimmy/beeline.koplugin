import importlib.util
import pathlib
import tempfile
import unittest


SCRIPT_PATH = pathlib.Path(__file__).parents[1] / "tools" / "sync_translations.py"
SPEC = importlib.util.spec_from_file_location("sync_translations", SCRIPT_PATH)
sync_translations = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_translations)


class SyncTranslationTests(unittest.TestCase):
    def test_po_round_trip_is_byte_stable(self):
        translations = {
            "btn_check_files": "Check for Incoming Files",
        }
        en_final = {
            "btn_check_files": "Check for Incoming Files",
        }
        with tempfile.TemporaryDirectory(dir=SCRIPT_PATH.parent) as directory:
            path = pathlib.Path(directory) / "hu.po"
            sync_translations.save_po(
                path, "Hungarian", "hu", translations.keys(), translations, {}, en_final
            )
            first = path.read_bytes()
            parsed = {
                entry["msgid"]: entry["msgstr"]
                for entry in sync_translations.parse_po(path)
                if entry["msgid"]
            }
            sync_translations.save_po(
                path, "Hungarian", "hu", parsed.keys(), parsed, {}, en_final
            )
            self.assertEqual(first, path.read_bytes())

    def test_provider_validation_rejects_english_fallback(self):
        requested = {
            "btn_check_files": "Check for Incoming Files",
        }
        errors = sync_translations.validate_translations(
            "hu", requested, {"btn_check_files": "Check for Incoming Files"}
        )
        self.assertTrue(errors)

    def test_provider_validation_rejects_changed_format_specifier(self):
        requested = {
            "picker_create_subfolder": "Create subfolder in '%s':",
        }
        errors = sync_translations.validate_translations(
            "hu",
            requested,
            {"picker_create_subfolder": "Almappa letrehozasa itt:"},
        )
        self.assertTrue(errors)

    def test_fallback_scraper_unescapes_lua_quotes(self):
        val = 'Created \\"%s\\"'
        unescaped = val.replace('\\"', '"').replace('\\\\', '\\')
        self.assertEqual(unescaped, 'Created "%s"')
        encoded = sync_translations.encode_po_string(unescaped)
        self.assertEqual(encoded, 'Created \\"%s\\"')


if __name__ == "__main__":
    unittest.main()
