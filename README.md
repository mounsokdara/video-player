# Video Player for android

A Material 3 open source Media video player 

This app under development it's may have alot bugs

## Features

- Library of all videos on the device (Videos / Folders / Settings)
- Hide individual library tabs from Settings > General; hidden ones stay reachable from the Videos / Folders 3-dot menu
- Gesture playback: D-pad double-tap skip with accumulating seconds, center double-tap play/pause, 2× long-press
- Previous, play, and next stay centered; lock on the left and screen mode on the right
- YouTube-style mini player with previous, play, next, and close; drag it anywhere
- Brightness only while the player is open; leaving the video restores the system brightness
- Equalizer attaches to the playing video's audio session
- Does not mix with other apps: other media pauses this player, and this player pauses other media
- Playlist modes: order, loop all, repeat one, shuffle, no autoplay
- Aspect modes including fit, zoom, stretch, original pixel size, and forced ratios
- Quick actions: screenshot, background play, speed (reorder and check from player More)
- Background play uses a music-style notification with play / pause / next / previous and a seek bar
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

On first launch, grant **All files access** in system settings. If access is already granted and the library is empty, the app tells you there are no videos - it does not keep asking for permission.

## License

Personal project. Source: this repository.
