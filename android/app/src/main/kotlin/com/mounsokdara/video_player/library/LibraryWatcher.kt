package com.mounsokdara.video_player

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import java.io.File

class LibraryWatcher(
    private val context: Context,
    private val onRefresh: () -> Unit
) {
    private val main = Handler(Looper.getMainLooper())
    private val ping = Runnable { onRefresh() }
    private var mediaObserver: ContentObserver? = null
    private val fileObservers = ArrayList<FileObserver>()
    private val watched = HashSet<String>()

    @Synchronized
    fun start(roots: List<File>) {
        stop()
        registerMediaStore()
        for (root in roots) {
            if (!root.exists() || !root.isDirectory) continue
            watchDir(root, 0)
            for (name in COMMON_DIRS) {
                watchTree(File(root, name), 1)
            }
            try {
                val children = root.listFiles() ?: continue
                for (child in children) {
                    if (!child.isDirectory) continue
                    if (child.name.startsWith(".")) {
                        watchTree(child, 1)
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    @Synchronized
    fun stop() {
        main.removeCallbacks(ping)
        mediaObserver?.let {
            try {
                context.contentResolver.unregisterContentObserver(it)
            } catch (_: Exception) {
            }
        }
        mediaObserver = null
        for (obs in fileObservers) {
            try {
                obs.stopWatching()
            } catch (_: Exception) {
            }
        }
        fileObservers.clear()
        watched.clear()
    }

    private fun registerMediaStore() {
        val observer = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                schedule()
            }

            override fun onChange(selfChange: Boolean, uri: Uri?) {
                schedule()
            }
        }
        mediaObserver = observer
        val cr = context.contentResolver
        try {
            cr.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, observer)
        } catch (_: Exception) {
        }
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                cr.registerContentObserver(
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL),
                    true,
                    observer
                )
            } catch (_: Exception) {
            }
            try {
                cr.registerContentObserver(MediaStore.Files.getContentUri("external"), true, observer)
            } catch (_: Exception) {
            }
        }
    }

    private fun watchTree(dir: File, depth: Int) {
        if (depth > 4 || watched.size >= MAX_WATCHERS) return
        if (!dir.exists() || !dir.isDirectory) return
        watchDir(dir, depth)
        val children = try {
            dir.listFiles()
        } catch (_: Exception) {
            null
        } ?: return
        for (child in children) {
            if (watched.size >= MAX_WATCHERS) return
            if (!child.isDirectory) continue
            if (shouldSkip(child.name)) continue
            watchTree(child, depth + 1)
        }
    }

    @Suppress("DEPRECATION")
    private fun watchDir(dir: File, depth: Int) {
        val path = dir.absolutePath
        if (!watched.add(path)) return
        if (watched.size > MAX_WATCHERS) {
            watched.remove(path)
            return
        }
        val mask = FileObserver.CREATE or
            FileObserver.DELETE or
            FileObserver.MOVED_FROM or
            FileObserver.MOVED_TO or
            FileObserver.CLOSE_WRITE or
            FileObserver.DELETE_SELF or
            FileObserver.MOVE_SELF
        val obs = object : FileObserver(path, mask) {
            override fun onEvent(event: Int, fileName: String?) {
                val e = event and FileObserver.ALL_EVENTS
                if (e == 0) return
                if (fileName != null) {
                    val ext = fileName.substringAfterLast('.', missingDelimiterValue = "")
                    if (ext.isNotEmpty() && ext.lowercase() !in NativeConstants.VIDEO_EXT) {
                        if ((e and FileObserver.CREATE) != 0 || (e and FileObserver.MOVED_TO) != 0) {
                            val child = File(dir, fileName)
                            if (child.isDirectory && depth < 4 && !shouldSkip(fileName)) {
                                main.post { watchDir(child, depth + 1) }
                            }
                        }
                        return
                    }
                    if (ext.isEmpty() && ((e and FileObserver.CREATE) != 0 || (e and FileObserver.MOVED_TO) != 0)) {
                        val child = File(dir, fileName)
                        if (child.isDirectory && depth < 4 && !shouldSkip(fileName)) {
                            main.post { watchDir(child, depth + 1) }
                        }
                    }
                }
                schedule()
            }
        }
        try {
            obs.startWatching()
            fileObservers.add(obs)
        } catch (_: Exception) {
            watched.remove(path)
        }
    }

    private fun schedule() {
        main.removeCallbacks(ping)
        main.postDelayed(ping, 800L)
    }

    private fun shouldSkip(name: String): Boolean {
        val low = name.lowercase()
        return low == "android" ||
            low == "lost.dir" ||
            low == "thumbnails" ||
            low == ".thumbnails" ||
            low == "obb" ||
            low == "data" ||
            low == "cache" ||
            low == "code_cache" ||
            low == "no_backup" ||
            low == "node_modules" ||
            low == ".git" ||
            low == ".trashed" ||
            low == "alarms" ||
            low == "ringtones" ||
            low == "notifications"
    }

    companion object {
        private const val MAX_WATCHERS = 80
        private val COMMON_DIRS = listOf(
            "DCIM",
            "Movies",
            "Download",
            "Downloads",
            "Pictures",
            "Documents",
            "Video",
            "Videos",
            "WhatsApp",
            "Telegram",
            "Camera"
        )
    }
}
