# Video Player

Material 3 local video player for Android. Playback uses [media_kit](https://pub.dev/packages/media_kit) (libmpv).

**v1.0.0 pre-Release** · `com.mounsokdara.video_player`

[Download APK](https://github.com/mounsokdara/video-player/releases/download/v1.0.0_pre-Release/com.mounsokdara.video_player.apk)

Uninstall any older build before installing this one.

## Features

- Library of videos on internal storage, SD cards, and USB drives, including hidden files
- Library auto-refresh when files are added, changed, or deleted
- Mini player snaps to **16:9** (landscape) or **9:16** (portrait)
- Speed changes video and audio together; pitch shift is optional
- Gestures, background audio with a notification, ten-band equalizer
- HLS streams and local files through libmpv

## Build

```bash
flutter pub get
flutter build apk --release
```

CI on `main` publishes the APK to GitHub Releases.

## Permissions

On first launch, grant **All files access**. Deletes, renames, and hidden-folder scans need it.

## License

Personal project.
