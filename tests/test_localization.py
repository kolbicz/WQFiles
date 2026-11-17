import json
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENTRY = re.compile(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");$')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztLq])?[@diuoxXfFeEgGaAcCsSpn%]")


def read_table(path: Path) -> dict[str, str]:
    entries = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("/*"):
            continue
        match = ENTRY.match(line)
        if not match:
            raise AssertionError(f"{path.name}:{line_number}: malformed .strings entry")
        key = json.loads(match.group(1))
        value = json.loads(match.group(2))
        if key in entries:
            raise AssertionError(f"{path.name}:{line_number}: duplicate key {key!r}")
        entries[key] = value
    return entries


LANGUAGES = ("zh-Hans", "de", "ar", "it", "es", "ko", "pt-BR", "ru", "pl", "tr", "th", "vi", "ja")
# Embeddings, overrides and isolates can hide or reorder text; the plain
# LRM/RLM marks are allowed (Arabic uses LRM before a path like /private/var).
BIDI_CONTROLS = re.compile("[\u202a-\u202e\u2066-\u2069]")


class LocalizationTests(unittest.TestCase):
    def test_every_language_matches_english(self):
        english = read_table(ROOT / "en.lproj/Localizable.strings")
        for language in LANGUAGES:
            table = read_table(ROOT / f"{language}.lproj/Localizable.strings")
            self.assertEqual(set(english), set(table), language)
            for key, value in table.items():
                self.assertEqual(PLACEHOLDER.findall(key), PLACEHOLDER.findall(value), f"{language}: {key}")
                self.assertTrue(value.strip() or not key.strip(), f"{language}: empty value for {key}")
                self.assertIsNone(BIDI_CONTROLS.search(value), f"{language}: direction control in {key}")

    def test_language_tables_have_identical_keys(self):
        english = read_table(ROOT / "en.lproj/Localizable.strings")
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        self.assertEqual(set(english), set(chinese))
        self.assertGreater(len(chinese), 600)

    def test_placeholders_are_preserved(self):
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        for key, value in chinese.items():
            self.assertEqual(PLACEHOLDER.findall(key), PLACEHOLDER.findall(value), key)

    def test_critical_ui_terms_are_translated(self):
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        expected = {
            "App Data": "应用数据",
            "App Groups": "应用组",
            "Signing problem: no App Group": "签名问题：缺少应用组",
            "Cancel": "取消",
            "OK": "好",
            "Allow Deleting": "允许删除",
            "Show Item Counts": "显示项目数量",
            "Restore Backup…": "还原备份…",
            "Deleting is turned off": "删除功能已关闭",
        }
        for key, value in expected.items():
            self.assertEqual(chinese.get(key), value)

    def test_unused_restore_keys_are_removed(self):
        english = read_table(ROOT / "en.lproj/Localizable.strings")
        chinese = read_table(ROOT / "zh-Hans.lproj/Localizable.strings")
        for key in ("Restore.FileBackup", "Restore.AppBackup"):
            self.assertNotIn(key, english)
            self.assertNotIn(key, chinese)

    def test_plural_suffixes_are_not_localized_as_placeholders(self):
        legacy_keys = {
            "This permanently removes %lu complete backup%@ and everything inside them. It cannot be undone.",
            "Delete Library/Caches and tmp for %lu app%@, plus Crash Logs",
            "Delete Library/Caches and tmp for %lu app%@",
            "%lu container enumeration%@ failed",
            "%lu container%@ had limited access",
            "%lu cache tree measurement%@ was limited",
            "%lu container%@ had no identifier or identity",
            "No %@ container%@ found.",
            "%@ selected in %lu item%@",
            "Created %@. %lu symbolic link%@ or special file%@ were left out.",
            "Extracted %lu file%@ into %@. %lu symbolic link%@ in the ZIP were left out.",
        }
        english = read_table(ROOT / "en.lproj/Localizable.strings")
        self.assertFalse(legacy_keys & set(english))
        for path in ROOT.glob("*.m"):
            source = path.read_text(encoding="utf-8")
            self.assertNotRegex(source, r'\?\s*@""\s*:\s*@"(?:s|es)"', str(path))

    def test_plist_date_and_data_actions_stay_distinct(self):
        # The Add sheet localizes the type key exactly once. A second lookup
        # of the translated "Date" ("Data" in it/pl/pt-BR) would yield the
        # translation of the Data type and collapse the two actions.
        for language in ("it", "pl", "pt-BR"):
            table = read_table(ROOT / f"{language}.lproj/Localizable.strings")
            date_label, data_label = table["Date"], table["Data"]
            self.assertNotEqual(date_label, data_label, language)
            self.assertEqual(table.get(date_label), data_label, f"{language}: double lookup hazard no longer present?")
        source = (ROOT / "WQPlistEditor.m").read_text(encoding="utf-8")
        self.assertIn("wq_alert_action(wqp_type_key(t)", source)
        self.assertNotRegex(source, r"wq_alert_action\(\s*wqp_type_name\(")
        self.assertIn("return WQVerbatim(WQLocalized(wqp_type_key(t)));", source)

    def test_localized_lookup_honors_verbatim(self):
        source = (ROOT / "WQLocalization.m").read_text(encoding="utf-8")
        self.assertRegex(source, r"if \(!key\.length \|\| WQIsVerbatim\(key\)\) return key;")

    def test_bundle_and_build_declare_localizations(self):
        info = plistlib.loads((ROOT / "Info.plist").read_bytes())
        self.assertEqual(set(info["CFBundleLocalizations"]), {"en", *LANGUAGES})
        build = (ROOT / "build.sh").read_text(encoding="utf-8")
        self.assertIn('for lproj in "$ROOT"/*.lproj', build)
        self.assertIn('cp -R "$lproj" "$APP/"', build)


if __name__ == "__main__":
    unittest.main()
