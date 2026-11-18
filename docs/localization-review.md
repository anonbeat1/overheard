# Localization review

The interface uses Italian source keys. English is the reference translation. The Spanish, French, German, Portuguese, Simplified Chinese, Hindi, Arabic, Japanese, Russian, and Bengali tables started as Google Translate drafts. Portuguese currently follows Brazilian usage; Spanish follows Spain for macOS settings names.

These translations have not been reviewed by native speakers. Apple documentation supplies terminology for macOS controls, not translations or approval of Overheard's sentences.

## Terminology sources

The following Apple pages were consulted on 2026-11-17. Their localized names for System Settings, Privacy & Security, and microphone access guide the permission instructions:

| Locale | Reference | Names used |
| --- | --- | --- |
| Spanish | [Microphone access](https://support.apple.com/es-es/guide/mac-help/mchla1b1e1fe/27/mac/27) | Ajustes del Sistema; Privacidad y seguridad; Micrófono |
| French | [Privacy settings](https://support.apple.com/fr-fr/guide/mac-help/mchl211c911f/mac), [calendar access](https://support.apple.com/fr-cm/guide/mac-help/mh43710/mac) | Réglages Système; Confidentialité et sécurité; Calendriers |
| German | [Microphone access](https://support.apple.com/de-de/guide/mac-help/mchla1b1e1fe/27/mac/27) | Systemeinstellungen; Datenschutz & Sicherheit; Mikrofon |
| Portuguese | [Screen and system audio recording](https://support.apple.com/pt-br/guide/mac-help/mchld6aa7d23/27/mac/27) | Ajustes do Sistema; Privacidade e Segurança |
| Simplified Chinese | [Microphone access](https://support.apple.com/zh-cn/guide/mac-help/mchla1b1e1fe/27/mac/27) | 系统设置; 隐私与安全; 麦克风 |
| Hindi | [Microphone access](https://support.apple.com/hi-in/guide/mac-help/mchla1b1e1fe/mac) | सिस्टम सेटिंग्ज़; गोपनीयता और सुरक्षा |
| Arabic | [Microphone access](https://support.apple.com/ar-sa/guide/mac-help/mchla1b1e1fe/mac), [calendar access](https://support.apple.com/ar-sa/guide/mac-help/mh43710/mac) | إعدادات النظام; الخصوصية والأمن; التقويمات |
| Japanese | [Microphone access](https://support.apple.com/ja-jp/guide/mac-help/mchla1b1e1fe/27/mac/27) | システム設定; プライバシーとセキュリティ; マイク |
| Russian | [Calendar access](https://support.apple.com/ru-ru/guide/mac-help/mh43710/mac) | Системные настройки; Конфиденциальность и безопасность; Календари |
| Bengali | [Microphone access](https://support.apple.com/bn-in/guide/mac-help/mchla1b1e1fe/mac) | The article body serves English labels. The settings path retains System Settings, Privacy & Security, and Calendars. Bengali prose is not verified against an Apple Bengali glossary. |

## Editorial scope

The `avoid-ai-writing` skill was applied to the added interface translations in two editorial passes, using its documentation profile. The review corrected literal calques, vague wording, excessive formality in controls, and inconsistent domain terms. Short button labels, intentional emoji, locale-specific punctuation, and the Italian source keys stay intact. Prose rules about paragraph rhythm do not apply to a string table.

The review focused on onboarding, AI questions, local transcription privacy, permission explanations, audio selection, regeneration, and repeated settings terminology. For example, German `Zugegeben` became `Erlaubt` for a granted permission, and Bengali `সংক্ষিপ্তসার পুনর্জন্ম` became `সারাংশ আবার তৈরি করুন` for generating a summary again. French and Chinese sentences left in English were translated. Explanations of automatic speaker names now match each locale's speaker label.

Product names, command spellings, folder names, format arguments, costs, sizes, and URLs retain their meanings. The privacy descriptions still distinguish local transcription from cloud transcription. This review does not establish linguistic accuracy across every sentence or verify layout, text truncation, or Arabic bidirectional rendering.

## Validation

Run `bash scripts/check-strings.sh` on macOS for the combined release build, source-key coverage check, and localization validation. To validate resource files without compiling, run `python3 scripts/check-localizations.py`. It checks table coverage, language registration, format arguments in order, line breaks, boundary whitespace, required technical literals, English leftovers, leaked translation markers, and permission keys. Legitimately identical English spellings have explicit exceptions.

The validator checks syntax and selected invariants. Native-speaker review and visual checks are still needed. The English and Italian tables have not had an editorial rewrite as part of this review.

## Visual preview

Settings includes an app-language picker with native language names and a System language option. The choice applies after quitting and reopening the app, and is independent of the meeting transcription language. The three picker-related strings bring each reference and added interface table to 341 keys.

Run `bash scripts/preview-localization.sh es` to build and open **Overheard Local** in Spanish. Quit that preview with Command-Q before running the command again with another language code: `fr`, `de`, `pt`, `zh-Hans`, `hi`, `ar`, `ja`, `ru`, `bn`, `en`, or `it`.

The preview uses a separate bundle identifier and preferences, shows the introduction on each launch, and disables automatic recording, retention cleanup, and automatic update checks for that session. It does not replace the installed app. It includes the interface and Sparkle framework, but does not build or bundle the on-device transcriber. It can still display the existing meeting library, so use disposable samples if testing edits or deletion.

Check the introduction, Settings (Command-comma), the menu bar panel, and the meeting library. Look for cut-off text, overlapping controls, remaining Italian or English sentences, and unclear actions. Include German for longer labels, Arabic for text direction and mixed product names, and Chinese or Japanese for font rendering. Compare English or Italian to confirm meaning. Native-speaker review is separate from these visual checks.
