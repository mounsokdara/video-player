package com.mounsokdara.video_player

object NativeConstants {
    const val CHANNEL = "app.videoplayer/android"
    const val EVENTS = "app.videoplayer/events"
    const val PICK_VIDEO_CODE = 47
    const val EQ_RETRY_MS = 450L
    const val HIDE_RETRY_MS = 120L
    const val EQ_BANDS = 10
    const val EQ_MIN = -1500
    const val EQ_MAX = 1500
    const val BASS_MAX = 1000
    const val PREVIEW_W = 180
    const val PREVIEW_H = 102
    const val SCAN_BUDGET = 2500
    const val INDEXED_CAP = 5000
    const val JPEG_QUALITY = 95
    const val PREVIEW_JPEG_QUALITY = 40
    const val PIXEL_DARK = 48
    const val STT_TIMEOUT_MS = 12000L
    const val FILE_CRASH = "last_crash.txt"
    const val FILE_DIRTY = "session_dirty.txt"
    const val FILE_ACTION = "last_action.txt"
    const val FILE_EQ_DIRTY = "eq_dirty.txt"
    const val FILE_DEBUG = "debug_log.txt"

    val TEN_BAND_HZ = intArrayOf(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)

    val VIDEO_EXT = setOf(
        "mp4", "mkv", "webm", "avi", "mov", "m4v", "3gp", "flv", "wmv",
        "mpeg", "mpg", "m2ts", "mts", "vob", "f4v", "ogv"
    )
    val TEXT_EXT = setOf(
        "ts", "tsx", "js", "jsx", "mjs", "cjs", "json", "txt", "md", "css",
        "html", "htm", "xml", "svg", "map", "yml", "yaml", "py", "java",
        "kt", "dart", "c", "h", "cpp", "go", "rs", "sh", "log", "csv",
        "toml", "ini", "cfg", "d.ts"
    )

    object Orient {
        const val LANDSCAPE = "landscape"
        const val PORTRAIT = "portrait"
        const val LANDSCAPE_NORMAL = "landscape_normal"
        const val LANDSCAPE_REVERSE = "landscape_reverse"
        const val PORTRAIT_NORMAL = "portrait_normal"
        const val PORTRAIT_REVERSE = "portrait_reverse"
        const val LOCKED = "locked"
        const val USER = "user"
        const val SENSOR = "sensor"
        const val AUTO = "auto"
        const val NONE = "none"
        const val UNSPECIFIED = "unspecified"
    }

    object Method {
        const val APPLY_SYSTEM_BARS = "applySystemBars"
        const val SET_ORIENTATION = "setOrientation"
        const val REQUEST_AUDIO_FOCUS = "requestAudioFocus"
        const val ABANDON_AUDIO_FOCUS = "abandonAudioFocus"
        const val APPLY_EQUALIZER = "applyEqualizer"
        const val OPEN_CRASH_REPORT = "openCrashReport"
        const val OPEN_ABOUT = "openAbout"
        const val DEBUG_LOG = "debugLog"
    }
}
