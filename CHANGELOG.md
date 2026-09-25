# Changelog

## 1.0.2

### Added
- H.265 / HEVC Main 10 hardware decode (MediaCodec), with FFmpeg software fallback
- HDR tone-mapping for HLG / PQ / BT.2020; the HDR/SDR button now drives the player

### Changed
- Hardware decode uses MediaCodec direct instead of copy (10-bit HEVC was stalling)
- Library scan lists the system videos first, then SD / USB in parallel, without opening every file in a decoder

### Fixed
- Only one video plays at a time, even with more than one window
- Playback notification title, play/pause, and position stay in sync
- Leaving a video no longer crashes when the notification starts
- YouTube landscape no longer crashes on a narrow or split-screen window
- Picture pan and pinch need two fingers; one finger stays seek / brightness / volume
- Sitting unused no longer shows a false crash report

## 1.0.1

### Added
- Playlist UI style: bottom dialog sheet (default) or YouTube watch page
- In-app video picker for other apps' Open-from / Get content / Pick

### Changed
- Videos tab: whole row is tappable; checkbox sits on the right while selecting
- YouTube style is a watch page (video, details, Up next), not a bottom sheet
- Maximize only shows with the player controls
- Mini player window scales to the screen (16:9 landscape, 9:16 portrait)

### Fixed
- Pinch zoom no longer starts seek at the same time
- Original size uses the video's real pixels and never upscales
- Pinch resize on the mini player no longer loops or resets
