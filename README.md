# hundred_version1

A new Flutter project.

## Team Sync Rules (Windows + macOS)

To keep analysis/build results identical across both computers:

1. Use the same Flutter version on both machines: `3.22.0`.
2. Always pull before starting work.
3. Run `flutter pub get` after pulling.
4. Run `flutter analyze lib` before committing.
5. Do not commit desktop generated plugin files unless intentionally updating plugins.

Recommended start-of-day commands:

```bash
git pull --ff-only origin main
flutter pub get
flutter analyze lib
```

Recommended before push:

```bash
flutter analyze lib
git status
git add lib .gitattributes .editorconfig .fvmrc .github/workflows/flutter_analyze.yml
git commit -m "Your message"
git push origin main
```

If `flutter analyze lib` suddenly shows hundreds of `withValues` errors, it means incompatible API usage was reintroduced for the pinned SDK. Replace `withValues(alpha: x)` with `withOpacity(x)` and run analyze again.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
