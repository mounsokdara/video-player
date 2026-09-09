# Video Player

Material 3 Android video player for local files — internal storage, SD cards, and USB/OTG.

**Download APK:** [v1.0.0_Indev](https://github.com/mounsokdara/video-player/releases/download/v1.0.0_Indev/app-release.apk)

Version **1.0.0_Indev** (development).

## Features

- Library of all videos on the device (Videos / Folders / Settings)
- Hide individual library tabs; hidden ones move to the 3-dot menu (keep at least one)
- Gesture playback: seek, brightness, volume, double-tap ripples (paused / playing / skip), 2× long-press with a persistent badge
- Pinch-to-zoom inside the picture (on by default)
- Previous / play / next stay centered; lock and screen mode sit to the right
- Playlist modes: order, loop all, repeat one, shuffle, no autoplay
- Aspect modes including fit, zoom, stretch, original pixel size, and forced ratios
- Quick actions: screenshot, background play, speed
- Background play uses a music-style notification with play / pause / next / previous
- Open a video from another file manager
- Screenshot the current frame to `DCIM/Screenshots`
- Ten-band equalizer with presets, on/off on the player top bar, bass boost, and surround
- Pitch shift (or time-stretch when off)
- Color correction toggle + sliders
- Always hide navigation bar, or show system bars only while the controller is visible
- Properties include frame rate
- Auto-refresh library toggle and pull-to-refresh on Videos / Folders
- Settings persist (equalizer, tabs, resume, zoom, playback)
- Deletes use `MANAGE_MEDIA` so Android does not show a confirmation sheet
- Skips plain text and TypeScript files (`.ts` only if it is MPEG-TS)
- Pop-up / PiP off by default and only while a video is actually playing
- Wide / large-DPI layout (navigation rail on tablets)

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
- **Media management** (`MANAGE_MEDIA`) so deletes skip the system confirmation sheet
- USB host (OTG) and removable volumes
- Notifications / foreground media playback for background play
- Picture-in-picture and display-over-apps for pop-up play

On first launch, grant **All files access** in system settings. If access is already granted and the library is empty, the app tells you there are no videos — it does not keep asking for permission.

## License

Personal project. Source: this repository.
