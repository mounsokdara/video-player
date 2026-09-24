# Changelog

## 1.0.2

Library
- Video scan is much faster: the system video list shows first, then SD / USB folders fill in
- Scan no longer opens every file in a decoder just to list it
- SD and USB volumes are scanned together
- Text files named like videos are still skipped
- `.nomedia` folders are still skipped by default

Player
- Only one video plays at a time, even with more than one window
- The playback notification keeps title, play/pause, and position in sync
- Leaving a video no longer crashes when the notification starts
- YouTube landscape no longer crashes on a narrow or split-screen window
- Picture pan and pinch need two fingers; one finger stays seek / brightness / volume
- Sitting unused no longer shows a false crash report

## 1.0.1

Library
- Videos tab: the whole row is tappable again (not only the thumbnail)
- Videos tab: checkbox sits on the right while selecting, like Folders
- Other apps' Open-from / Get content / Pick opens the in-app video picker instead of a Files folder

Player style
- Playlist UI style is now Player style: bottom dialog sheet (default) or YouTube watch page
- YouTube style is a watch page, not a bottom sheet
- Watch page: video on top, details under the frame, Up next list below (or on the right in landscape)
- Portrait watch frame grows and shrinks with scroll, up to 9:16
- Landscape / wide: video top-left, details under it, list on the right
- Animated maximize and minimize
- Title-bar buttons stay available on the minimized YouTube frame
- No playlist button on YouTube style
- Maximize only shows with the player controls (no floating maximize)
- Filter chips scroll horizontally

Gestures and picture
- Only one gesture at a time: pinch zoom no longer starts seek
- Quick gestures stay off while the YouTube frame is minimized
- Double-tap seek works on the minimized watch frame, with Material 3 ripples
- Zoom resets when minimizing
- Original size uses the video's real pixels and never upscales

Mini player
- Window scales to the screen
- Landscape docks at 16:9, portrait at 9:16
- Pinch resize no longer loops or resets
