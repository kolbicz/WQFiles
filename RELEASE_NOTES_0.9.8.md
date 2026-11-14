> **Requires:** iOS 27, or iOS 26.0 – 26.7.2. Tested on iOS 27.0.1, 27.2.1, 26.7.1 and the 27.3 beta (confirmed by a user).
> **Needs:** a sideloading tool that keeps the App Group entitlement; see [Signing](https://github.com/kolbicz/WQFiles#signing-the-app-group) in the README.

# Worse Query Files 0.9.8

## New

- **Reset Access Cache in Settings:** under **Settings → Troubleshooting**, in both designs. Until now it only appeared on the startup check screen when sandbox access failed, so it couldn't be reached after **Continue Anyway** or when access broke later. It puts WQ Files' own cache folder in the App Group back; nothing is deleted.

## Changed

- **Clearer Log when access is blocked:** when the access cache can't be repaired automatically, the Log now says why and what it found (swap marker, preserved Caches folder, what Caches is now) and points to **Reset Access Cache**. The same failure is logged once instead of for every folder.
- **Translations** for the new texts in all languages.

## Credit

New design: GpGp700. Sandbox technique: [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit). Container enumeration: [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus. Translations: iosrxwy (Simplified Chinese), hfip (Arabic), hooray804 (Korean), Reinascape (Russian), buraakkcayir (Turkish review). Thanks to everyone who sent Logs and ideas. GPL-3.0-or-later.

SHA-256 of WQFiles.ipa: `7459ded30f5aa740a49060e1497ddf7eafa7b0152290b8104d336338de9a050c`
