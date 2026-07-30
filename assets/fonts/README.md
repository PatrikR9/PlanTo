# Fonts

Inter is **not** committed (it is ~1 MB of binary and the licence asks you to
ship the licence text, not the repo history).

Download from https://rsms.me/inter/ and drop these four files here:

    Inter-Regular.ttf     (400)
    Inter-Medium.ttf      (500)
    Inter-SemiBold.ttf    (600)
    Inter-Bold.ttf        (700)

Then in `pubspec.yaml` uncomment the `fonts:` block, and in
`lib/core/design_system/tokens/typography.dart` set

    const bool kUseBundledInter = true;

Until then the app uses the platform default (Roboto on Android), which looks
fine and keeps the build green.

Licence: SIL Open Font License 1.1 — free for commercial use. Add the licence
text to the in-app licences screen in M11.
