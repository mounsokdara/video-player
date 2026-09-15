# Video Player

Material 3 local video player for Android. Playback uses [media_kit](https://pub.dev/packages/media_kit) (libmpv).

**v1.0.0** · `com.mounsokdara.video_player`

[Download APK](https://github.com/mounsokdara/video-player/releases/download/v1.0.0/com.mounsokdara.video_player.apk)

Uninstall any older build before installing this one.

## Features

- Library of videos on internal storage, SD cards, and USB drives, including hidden files
- Library auto-refresh when files are added, changed, or deleted
- Videos tab: hold a clip for actions, tap a thumbnail to select
- Folders tab: hold for play queue, copy, cut, share, bookmark, pin, properties, delete
- Rename only when one item is selected
- Paste is a bottom-right button and clears after one paste
- Mini player scales to the screen and snaps to **16:9** or **9:16**
- HUD buttons only show with the player controls
- Playlist as a bottom sheet (default) or a YouTube-style queue
- Dynamic color from the wallpaper; seed picker greys out while that is on
- Speed changes video and audio together; pitch shift is optional
- Background audio with a notification; pause stays paused
- Ten-band equalizer, gestures, sleep timer, PIP

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
