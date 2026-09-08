# Video Player

Material 3 Android video player for local files — internal storage, SD cards, and USB/OTG.

## Features

- Library of all videos on the device (Videos / Folders / Settings)
- Gesture playback: seek, brightness, volume, YouTube-style double-tap, 2× long-press
- Playlist modes: order, loop all, repeat one, shuffle, no autoplay
- Aspect modes including fit, zoom, stretch, original pixel size, and forced ratios
- AB repeat, sleep timer, equalizer, night mode, color filters, HDR toggle
- All-files access so you can rename, share, and delete

## Build

```bash
flutter pub get
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

Package ID: `com.mounsokdara.video_player`

CI on `main` publishes the APK to GitHub Releases.

## Permissions

The app requests:

- Read/write media and **all-files** access (`MANAGE_EXTERNAL_STORAGE`)
- USB host (OTG) and removable volumes
- Notifications / foreground media playback for background play
- Picture-in-picture and display-over-apps for pop-up play

On first launch, grant **All files access** in system settings.

## License

Personal project. Source: this repository.
