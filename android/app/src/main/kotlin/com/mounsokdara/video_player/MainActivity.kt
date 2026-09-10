package com.mounsokdara.video_player

import android.app.PictureInPictureParams
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.util.Rational
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "app.videoplayer/android"
    private val eventName = "app.videoplayer/events"
    private var wantPip = false
    private var isPlaying = false
    private var keepScreenOn = false
    private var pendingOpen: String? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val tenBandHz = intArrayOf(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
    private var tenBandLevels = IntArray(10)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        installCrashHook()
        handleIncoming(intent)
    }

    override fun onDestroy() {
        try {
            File(filesDir, "session_dirty.txt").delete()
            File(filesDir, "last_action.txt").writeText("idle")
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncoming(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    eventsSink = events
                    pendingOpen?.let { emit(mapOf("type" to "open", "path" to it)) }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    eventsSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "hasAllFilesAccess" -> {
                            result.success(
                                if (Build.VERSION.SDK_INT >= 30)
                                    Environment.isExternalStorageManager()
                                else true
                            )
                        }
                        "requestAllFilesAccess" -> {
                            if (Build.VERSION.SDK_INT >= 30) {
                                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                                intent.data = Uri.parse("package:$packageName")
                                startActivity(intent)
                            }
                            result.success(true)
                        }
                        "canManageMedia" -> {
                            result.success(
                                if (Build.VERSION.SDK_INT >= 31) MediaStore.canManageMedia(this) else true
                            )
                        }
                        "requestManageMedia" -> {
                            if (Build.VERSION.SDK_INT >= 31 && !MediaStore.canManageMedia(this)) {
                                startActivity(
                                    Intent(Settings.ACTION_REQUEST_MANAGE_MEDIA).apply {
                                        data = Uri.parse("package:$packageName")
                                    }
                                )
                            }
                            result.success(true)
                        }
                        "listStorageVolumes" -> result.success(listVolumes())
                        "listVideoFiles" -> {
                            val root = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            val hidden = call.argument<Boolean>("includeHidden") ?: false
                            result.success(scanVideos(File(root), 3, hidden))
                        }
                        "deletePath" -> {
                            val path = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            result.success(deleteMediaFile(path))
                        }
                        "deletePaths" -> {
                            val paths = call.argument<List<String>>("paths") ?: emptyList()
                            var ok = true
                            for (path in paths) {
                                if (!deleteMediaFile(path)) ok = false
                            }
                            result.success(ok)
                        }
                        "renamePath" -> {
                            val path = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            val name = call.argument<String>("name")
                                ?: return@setMethodCallHandler result.error("ARG", "name", null)
                            val src = File(path)
                            val dest = File(src.parentFile, name)
                            result.success(if (src.renameTo(dest)) dest.absolutePath else null)
                        }
                        "setOrientation" -> {
                            val mode = call.argument<String>("mode") ?: "auto"
                            requestedOrientation = when (mode) {
                                "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                "portrait" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
                                "landscape_normal" -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                                "landscape_reverse" -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                                "portrait_normal" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                                "portrait_reverse" -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                                "locked" -> ActivityInfo.SCREEN_ORIENTATION_LOCKED
                                else -> ActivityInfo.SCREEN_ORIENTATION_FULL_USER
                            }
                            result.success(true)
                        }
                        "setKeepScreenOn" -> {
                            keepScreenOn = call.argument<Boolean>("on") ?: false
                            runOnUiThread {
                                if (keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                            result.success(true)
                        }
                        "setPlaying" -> {
                            isPlaying = call.argument<Boolean>("on") ?: false
                            result.success(true)
                        }
                        "enterPip" -> {
                            if (!isPlaying) {
                                Toast.makeText(this, "Play a video first", Toast.LENGTH_SHORT).show()
                                result.success(false)
                            } else {
                                wantPip = true
                                runOnUiThread { enterPipNow() }
                                result.success(true)
                            }
                        }
                        "setPipEnabled" -> {
                            wantPip = call.argument<Boolean>("on") ?: false
                            result.success(wantPip)
                        }
                        "isPip" -> result.success(Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode)
                        "initEqualizer" -> {
                            // Never attach android.media.audiofx or walk ExoPlayer internals.
                            // Those paths SIGSEGV on play / equalizer open.
                            breadcrumb("initEqualizer skipped (ui-only)")
                            result.success(emptyFx(0))
                        }
                        "setEqBand" -> {
                            val band = call.argument<Int>("band") ?: 0
                            val level = call.argument<Int>("level") ?: 0
                            if (band in 0..9) tenBandLevels[band] = level
                            result.success(true)
                        }
                        "setEqBands" -> {
                            val levels = call.argument<List<Int>>("levels") ?: emptyList()
                            for (i in 0 until minOf(10, levels.size)) tenBandLevels[i] = levels[i]
                            result.success(true)
                        }
                        "setEqPreset" -> result.success(true)
                        "setEqEnabled" -> result.success(true)
                        "setBassBoost" -> result.success(true)
                        "setVirtualizer" -> result.success(true)
                        "setPlaybackParams" -> {
                            val speed = (call.argument<Double>("speed") ?: 1.0).toFloat()
                            val pitchShift = call.argument<Boolean>("pitchShift") ?: false
                            applyPlaybackParams(speed, pitchShift)
                            result.success(true)
                        }
                        "toast" -> {
                            Toast.makeText(this, call.argument<String>("msg") ?: "", Toast.LENGTH_SHORT).show()
                            result.success(true)
                        }
                        "startBackground" -> {
                            val title = call.argument<String>("title") ?: "Video Player"
                            val artist = call.argument<String>("artist") ?: "Video Player"
                            val playing = call.argument<Boolean>("playing") ?: true
                            val positionMs = call.argument<Int>("positionMs") ?: 0
                            val durationMs = call.argument<Int>("durationMs") ?: 0
                            val intent = Intent(this, PlaybackService::class.java).apply {
                                action = PlaybackService.ACTION_START
                                putExtra("title", title)
                                putExtra("artist", artist)
                                putExtra("playing", playing)
                                putExtra("positionMs", positionMs)
                                putExtra("durationMs", durationMs)
                            }
                            try {
                                if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                            } catch (t: Throwable) {
                                writeCrash("startBackground: ${t.message}\n${Log.getStackTraceString(t)}")
                            }
                            result.success(true)
                        }
                        "updateBackground" -> {
                            val intent = Intent(this, PlaybackService::class.java).apply {
                                action = PlaybackService.ACTION_UPDATE
                                putExtra("playing", call.argument<Boolean>("playing") ?: true)
                                call.argument<Int>("positionMs")?.let { putExtra("positionMs", it) }
                                call.argument<Int>("durationMs")?.let { putExtra("durationMs", it) }
                                call.argument<String>("title")?.let { putExtra("title", it) }
                            }
                            startService(intent)
                            result.success(true)
                        }
                        "stopBackground" -> {
                            stopService(Intent(this, PlaybackService::class.java))
                            result.success(true)
                        }
                        "screenshot" -> {
                            val path = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            val positionMs = call.argument<Int>("positionMs") ?: 0
                            val title = call.argument<String>("title") ?: "frame"
                            io.execute {
                                val saved = captureFrame(path, positionMs.toLong(), title)
                                mainHandler.post { result.success(saved) }
                            }
                        }
                        "previewFrame" -> {
                            val path = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            val positionMs = call.argument<Int>("positionMs") ?: 0
                            io.execute {
                                val bytes = previewJpeg(path, positionMs.toLong())
                                mainHandler.post { result.success(bytes) }
                            }
                        }
                        "saveScreenshotBytes" -> {
                            val bytes = call.argument<ByteArray>("bytes")
                                ?: return@setMethodCallHandler result.error("ARG", "bytes", null)
                            val title = call.argument<String>("title") ?: "frame"
                            io.execute {
                                val saved = saveJpegBytes(bytes, title)
                                mainHandler.post { result.success(saved) }
                            }
                        }
                        "screenshotWindow" -> {
                            val title = call.argument<String>("title") ?: "frame"
                            val path = call.argument<String>("path")
                            val positionMs = call.argument<Int>("positionMs") ?: 0
                            captureVideoShot(title, path, positionMs) { saved ->
                                mainHandler.post { result.success(saved) }
                            }
                        }
                        "listIndexedVideos" -> {
                            io.execute {
                                val list = listIndexedVideos()
                                mainHandler.post { result.success(list) }
                            }
                        }
                        "copyPath" -> {
                            val src = call.argument<String>("src")
                                ?: return@setMethodCallHandler result.error("ARG", "src", null)
                            val dest = call.argument<String>("dest")
                                ?: return@setMethodCallHandler result.error("ARG", "dest", null)
                            result.success(copyFileTo(src, dest))
                        }
                        "movePath" -> {
                            val src = call.argument<String>("src")
                                ?: return@setMethodCallHandler result.error("ARG", "src", null)
                            val dest = call.argument<String>("dest")
                                ?: return@setMethodCallHandler result.error("ARG", "dest", null)
                            result.success(moveFileTo(src, dest))
                        }
                        "fileSize" -> {
                            val path = call.argument<String>("path") ?: ""
                            val f = File(path)
                            result.success(if (f.exists()) f.length() else 0L)
                        }
                        "mediaInfo" -> {
                            val path = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            result.success(readMediaInfo(path))
                        }
                        "pendingOpen" -> {
                            val path = pendingOpen
                            pendingOpen = null
                            result.success(path)
                        }
                        "lastCrash" -> result.success(readLastCrash())
                        "breadcrumb" -> {
                            breadcrumb(call.argument<String>("action") ?: "")
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    writeCrash("channel ${call.method}: ${e.message}\n${Log.getStackTraceString(e)}")
                    result.error("ERR", e.message, null)
                }
            }
    }

    private fun emptyFx(session: Int): Map<String, Any> {
        val map = HashMap<String, Any>()
        map["bands"] = 10
        map["deviceBands"] = 0
        map["min"] = -1500
        map["max"] = 1500
        map["freqs"] = tenBandHz.toList()
        map["levels"] = tenBandLevels.toList()
        map["sessionId"] = session
        map["presets"] = emptyList<String>()
        return map
    }

    private fun readLastCrash(): String? {
        val crash = File(filesDir, "last_crash.txt")
        val dirty = File(filesDir, "session_dirty.txt")
        val actionFile = File(filesDir, "last_action.txt")
        val hasCrash = crash.exists()
        val died = dirty.exists()
        val action = try {
            if (actionFile.exists()) actionFile.readText() else ""
        } catch (_: Exception) {
            ""
        }
        val interesting = action.contains("Open video", ignoreCase = true) ||
            action.contains("Play ", ignoreCase = true) ||
            action.contains("equalizer", ignoreCase = true) ||
            action.contains("initEqualizer", ignoreCase = true) ||
            action.contains("audiofx", ignoreCase = true)
        val buf = StringBuilder()
        if (action.isNotBlank()) buf.append("Last action: ").append(action).append('\n')
        if (hasCrash) {
            buf.append(crash.readText())
            crash.delete()
        } else if (died && interesting) {
            buf.append("===== PROCESS_DIED =====\nThe app process was killed during the last action (native crash / SIGSEGV). No Java stack trace.\n")
        }
        try {
            dirty.delete()
            dirty.writeText("running")
        } catch (_: Exception) {
        }
        val out = buf.toString().trim()
        return if (out.isEmpty() || (!hasCrash && !(died && interesting))) null else out
    }

    @Suppress("DEPRECATION")
    private fun deleteMediaFile(path: String): Boolean {
        val file = File(path)
        if (tryFileDelete(file)) return true
        val uri = mediaUriForPath(path) ?: return tryFileDelete(file) || !file.exists()
        return try {
            val rows = contentResolver.delete(uri, null, null)
            if (rows > 0) {
                tryFileDelete(file)
                true
            } else {
                tryFileDelete(file) || !file.exists()
            }
        } catch (_: SecurityException) {
            // Never launch RecoverableSecurityException's confirmation sheet.
            tryFileDelete(file) || !file.exists()
        } catch (_: Exception) {
            tryFileDelete(file) || !file.exists()
        }
    }

    private fun tryFileDelete(file: File): Boolean {
        return try {
            if (!file.exists()) return true
            if (file.delete()) {
                try {
                    MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf("video/*"), null)
                } catch (_: Exception) {
                }
                true
            } else {
                false
            }
        } catch (_: Exception) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun mediaUriForPath(path: String): Uri? {
        val name = File(path).name
        val collections = ArrayList<Uri>()
        collections.add(MediaStore.Video.Media.EXTERNAL_CONTENT_URI)
        collections.add(MediaStore.Files.getContentUri("external"))
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                collections.add(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL))
            } catch (_: Exception) {
            }
        }
        val projection = arrayOf(MediaStore.Video.Media._ID)
        for (collection in collections.distinct()) {
            try {
                contentResolver.query(
                    collection,
                    projection,
                    "${MediaStore.MediaColumns.DATA}=?",
                    arrayOf(path),
                    null
                )?.use { c ->
                    if (c.moveToFirst()) {
                        val id = c.getLong(0)
                        return ContentUris.withAppendedId(collection, id)
                    }
                }
            } catch (_: Exception) {
            }
        }
        for (collection in collections.distinct()) {
            try {
                contentResolver.query(
                    collection,
                    projection,
                    "${MediaStore.MediaColumns.DISPLAY_NAME}=?",
                    arrayOf(name),
                    null
                )?.use { c ->
                    if (c.count == 1 && c.moveToFirst()) {
                        val id = c.getLong(0)
                        return ContentUris.withAppendedId(collection, id)
                    }
                }
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun captureFrame(path: String, positionMs: Long, title: String): String? {
        val retriever = MediaMetadataRetriever()
        return try {
            val file = File(path)
            if (file.exists()) retriever.setDataSource(path) else retriever.setDataSource(this, Uri.parse(path))
            val bitmap = retriever.getFrameAtTime(positionMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: retriever.frameAtTime
                ?: return null
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val safe = title.replace(Regex("[^A-Za-z0-9._-]"), "_").take(40)
            val name = "VID_${stamp}_$safe.jpg"
            val saved = saveToDcim(bitmap, name)
            bitmap.recycle()
            saved
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun saveToDcim(bitmap: Bitmap, name: String): String? {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_DCIM + "/Screenshots")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return writeLegacy(bitmap, name)
            return try {
                contentResolver.openOutputStream(uri)?.use { out ->
                    if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)) return writeLegacy(bitmap, name)
                } ?: return writeLegacy(bitmap, name)
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                uri.toString()
            } catch (_: Exception) {
                writeLegacy(bitmap, name)
            }
        }
        return writeLegacy(bitmap, name)
    }

    private fun writeLegacy(bitmap: Bitmap, name: String): String? {
        return try {
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM), "Screenshots")
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, name)
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
            }
            MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null)
            file.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun readMediaInfo(path: String): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        val map = HashMap<String, Any?>()
        try {
            val file = File(path)
            if (file.exists()) retriever.setDataSource(path) else retriever.setDataSource(this, Uri.parse(path))
            fun meta(key: Int) = retriever.extractMetadata(key)
            val width = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val height = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val duration = meta(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val bitrate = meta(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
            val mime = meta(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            var fps = 0.0
            if (Build.VERSION.SDK_INT >= 23) {
                fps = meta(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull() ?: 0.0
            }
            var frames = 0
            if (Build.VERSION.SDK_INT >= 28) {
                frames = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull() ?: 0
            }
            if (fps <= 0 && frames > 0 && duration > 0) fps = frames * 1000.0 / duration
            map["width"] = width
            map["height"] = height
            map["durationMs"] = duration
            map["bitrate"] = bitrate
            map["mime"] = mime
            map["fps"] = fps
            map["frameCount"] = frames
        } catch (_: Exception) {
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
        return map
    }

    private fun handleIncoming(intent: Intent?) {
        if (intent == null) return
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW, Intent.ACTION_EDIT -> intent.data
            Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            else -> intent.data
        }
        if (uri == null) return
        val path = resolveUri(uri)
        if (path != null) {
            pendingOpen = path
            emit(mapOf("type" to "open", "path" to path))
        }
    }

    private fun resolveUri(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        if (uri.scheme == "content") {
            queryDisplayName(uri)?.let { name ->
                val cached = File(cacheDir, name)
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        cached.outputStream().use { input.copyTo(it) }
                    }
                    return cached.absolutePath
                } catch (_: Exception) {
                }
            }
            if (uri.path != null && File(uri.path!!).exists()) return uri.path
        }
        return uri.path
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) return c.getString(idx)
            }
        }
        return uri.lastPathSegment
    }

    private fun emit(payload: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(payload)
            eventsSink?.success(payload)
        }
    }

    private fun installCrashHook() {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, e ->
            writeCrash("${e.javaClass.name}: ${e.message}\n${Log.getStackTraceString(e)}")
            try {
                emit(
                    mapOf(
                        "type" to "crash",
                        "message" to "${e.javaClass.name}: ${e.message}",
                        "stack" to Log.getStackTraceString(e)
                    )
                )
            } catch (_: Exception) {
            }
            prev?.uncaughtException(Thread.currentThread(), e)
        }
    }

    private fun writeCrash(text: String) {
        try {
            File(filesDir, "last_crash.txt").writeText(
                "===== NATIVE ${SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())} =====\n$text"
            )
        } catch (_: Exception) {
        }
    }

    private fun breadcrumb(action: String) {
        try {
            File(filesDir, "last_action.txt").writeText(action)
        } catch (_: Exception) {
        }
    }

    private fun enterPipNow() {
        if (!isPlaying) return
        if (Build.VERSION.SDK_INT >= 26 && !isInPictureInPictureMode) {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            enterPictureInPictureMode(params)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (wantPip && isPlaying && Build.VERSION.SDK_INT >= 26) {
            enterPipNow()
        }
    }

    private fun listVolumes(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val sm = getSystemService(STORAGE_SERVICE) as StorageManager
        for (volume in sm.storageVolumes) {
            val path = volumePath(volume)
            val map = HashMap<String, Any?>()
            map["path"] = path
            map["description"] = volume.getDescription(this)
            map["isPrimary"] = volume.isPrimary
            map["isRemovable"] = volume.isRemovable
            map["state"] = volume.state
            map["isSd"] = volume.isRemovable && path?.contains("usb", true) != true
            map["isUsb"] = path?.contains("usb", true) == true ||
                volume.getDescription(this).contains("usb", true) ||
                volume.getDescription(this).contains("otg", true)
            out.add(map)
        }
        val ext = Environment.getExternalStorageDirectory()?.absolutePath
        if (out.none { it["path"] == ext } && ext != null) {
            out.add(
                mapOf(
                    "path" to ext,
                    "description" to "Internal storage",
                    "isPrimary" to true,
                    "isRemovable" to false,
                    "state" to "mounted",
                    "isSd" to false,
                    "isUsb" to false
                )
            )
        }
        return out
    }

    @Suppress("DEPRECATION")
    private fun volumePath(volume: android.os.storage.StorageVolume): String? {
        if (Build.VERSION.SDK_INT >= 30) {
            return volume.directory?.absolutePath
        }
        return try {
            val method = volume.javaClass.getMethod("getPath")
            method.invoke(volume) as? String
        } catch (_: Exception) {
            null
        }
    }

    private fun scanVideos(dir: File, depth: Int, hidden: Boolean): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        scanVideosInto(dir, depth, hidden, out, intArrayOf(2500))
        return out
    }

    private fun scanVideosInto(dir: File, depth: Int, hidden: Boolean, out: ArrayList<Map<String, Any?>>, budget: IntArray) {
        if (budget[0] <= 0 || depth < 0 || !dir.exists() || !dir.canRead()) return
        val files = dir.listFiles() ?: return
        for (f in files) {
            if (budget[0] <= 0) return
            if (f.isDirectory) {
                if (shouldSkipDir(f, hidden)) continue
                scanVideosInto(f, depth - 1, hidden, out, budget)
            } else if (isVideoFile(f)) {
                if (!hidden && f.name.startsWith(".")) continue
                budget[0] = budget[0] - 1
                out.add(
                    mapOf(
                        "path" to f.absolutePath,
                        "name" to f.name,
                        "size" to f.length(),
                        "modified" to f.lastModified(),
                        "folder" to (f.parent ?: "")
                    )
                )
            }
        }
    }

    private fun shouldSkipDir(f: File, hidden: Boolean): Boolean {
        val n = f.name
        if (!hidden && n.startsWith(".")) return true
        val low = n.lowercase()
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

    private fun applyPlaybackParams(speed: Float, pitchShift: Boolean) {
        val pitch = if (pitchShift) speed else 1f
        val exo = findExoPlayer() ?: return
        val params = playbackParameters(speed, pitch) ?: return
        try {
            val method = exo.javaClass.methods.firstOrNull {
                it.name == "setPlaybackParameters" && it.parameterTypes.size == 1
            } ?: return
            method.invoke(exo, params)
            breadcrumb("setPlaybackParams speed=$speed pitch=$pitch")
        } catch (t: Throwable) {
            writeCrash("setPlaybackParams: ${t.message}\n${Log.getStackTraceString(t)}")
        }
    }

    private fun playbackParameters(speed: Float, pitch: Float): Any? {
        val names = arrayOf(
            "androidx.media3.common.PlaybackParameters",
            "com.google.android.exoplayer2.PlaybackParameters"
        )
        for (name in names) {
            try {
                val cls = Class.forName(name)
                val ctor = cls.getConstructor(Float::class.javaPrimitiveType, Float::class.javaPrimitiveType)
                return ctor.newInstance(speed, pitch)
            } catch (_: Throwable) {
            }
        }
        return null
    }

    /**
     * Surgical lookup only: FlutterEngine plugin registry → VideoPlayerPlugin.videoPlayers
     * (LongSparseArray) → VideoPlayer.exoPlayer / player. Never walk media3 internals.
     */
    private fun findExoPlayer(): Any? {
        val engine = flutterEngine ?: return null
        return try {
            val registry = engine.plugins
            val map = fieldValue(registry, "map") ?: fieldValue(registry, "pluginMap") ?: fieldValue(registry, "plugins")
            val plugins: Collection<Any?> = when (map) {
                is Map<*, *> -> map.values
                else -> emptyList()
            }
            for (plugin in plugins) {
                if (plugin == null) continue
                val name = plugin.javaClass.name
                if (!name.contains("videoplayer", ignoreCase = true)) continue
                val array = fieldValue(plugin, "videoPlayers") ?: continue
                val wrapper = lastSparseValue(array) ?: continue
                val exo = fieldValue(wrapper, "exoPlayer")
                    ?: fieldValue(wrapper, "player")
                    ?: fieldValue(wrapper, "exo")
                if (exo != null) return exo
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    private fun findField(obj: Any, name: String): java.lang.reflect.Field? {
        var c: Class<*>? = obj.javaClass
        while (c != null) {
            try {
                val f = c.getDeclaredField(name)
                f.isAccessible = true
                return f
            } catch (_: NoSuchFieldException) {
                c = c.superclass
            }
        }
        return null
    }

    private fun fieldValue(obj: Any, name: String): Any? {
        return try {
            findField(obj, name)?.get(obj)
        } catch (_: Throwable) {
            null
        }
    }

    private fun lastSparseValue(array: Any): Any? {
        return try {
            val size = array.javaClass.getMethod("size").invoke(array) as Int
            if (size <= 0) return null
            array.javaClass.getMethod("valueAt", Int::class.javaPrimitiveType)
                .invoke(array, size - 1)
        } catch (_: Throwable) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun listIndexedVideos(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_MODIFIED,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.MIME_TYPE
        )
        val uri = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        try {
            contentResolver.query(
                uri,
                projection,
                null,
                null,
                "${MediaStore.Video.Media.DATE_MODIFIED} DESC"
            )?.use { c ->
                val iId = c.getColumnIndex(MediaStore.Video.Media._ID)
                val iData = c.getColumnIndex(MediaStore.Video.Media.DATA)
                val iName = c.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME)
                val iSize = c.getColumnIndex(MediaStore.Video.Media.SIZE)
                val iMod = c.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED)
                val iDur = c.getColumnIndex(MediaStore.Video.Media.DURATION)
                val iW = c.getColumnIndex(MediaStore.Video.Media.WIDTH)
                val iH = c.getColumnIndex(MediaStore.Video.Media.HEIGHT)
                val iMime = c.getColumnIndex(MediaStore.Video.Media.MIME_TYPE)
                while (c.moveToNext() && out.size < 5000) {
                    val path = if (iData >= 0) c.getString(iData) else null
                    if (path.isNullOrBlank()) continue
                    val file = File(path)
                    var size = if (iSize >= 0) c.getLong(iSize) else 0L
                    if (size <= 0 && file.exists()) size = file.length()
                    val name = if (iName >= 0) c.getString(iName) ?: file.name else file.name
                    val modified = if (iMod >= 0) c.getLong(iMod) * 1000 else file.lastModified()
                    out.add(
                        mapOf(
                            "id" to if (iId >= 0) c.getLong(iId).toString() else path,
                            "path" to path,
                            "name" to name,
                            "size" to size,
                            "modified" to modified,
                            "durationMs" to if (iDur >= 0) c.getLong(iDur) else 0L,
                            "width" to if (iW >= 0) c.getInt(iW) else 0,
                            "height" to if (iH >= 0) c.getInt(iH) else 0,
                            "mime" to if (iMime >= 0) c.getString(iMime) else null,
                            "folder" to (file.parent ?: "")
                        )
                    )
                }
            }
        } catch (_: Exception) {
        }
        return out
    }

    private fun copyFileTo(src: String, dest: String): Boolean {
        return try {
            val s = File(src)
            val d = File(dest)
            if (!s.exists()) return false
            d.parentFile?.mkdirs()
            s.inputStream().use { input -> d.outputStream().use { input.copyTo(it) } }
            MediaScannerConnection.scanFile(this, arrayOf(d.absolutePath), arrayOf("video/*"), null)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun moveFileTo(src: String, dest: String): String? {
        return try {
            val s = File(src)
            val d = File(dest)
            if (!s.exists()) return null
            d.parentFile?.mkdirs()
            if (s.renameTo(d)) {
                MediaScannerConnection.scanFile(this, arrayOf(d.absolutePath, s.absolutePath), arrayOf("video/*", "video/*"), null)
                return d.absolutePath
            }
            if (copyFileTo(src, dest)) {
                tryFileDelete(s)
                d.absolutePath
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun previewJpeg(path: String, positionMs: Long): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try {
            val file = File(path)
            if (file.exists()) retriever.setDataSource(path) else retriever.setDataSource(this, Uri.parse(path))
            val bmp = retriever.getFrameAtTime(positionMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: retriever.frameAtTime
                ?: return null
            val w = 320
            val scaled = if (bmp.width > w) {
                val h = (bmp.height * w.toFloat() / bmp.width).toInt().coerceAtLeast(1)
                Bitmap.createScaledBitmap(bmp, w, h, true)
            } else {
                bmp
            }
            val out = java.io.ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 52, out)
            if (scaled !== bmp) scaled.recycle()
            bmp.recycle()
            out.toByteArray()
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun collectViews(view: View, surfaces: MutableList<SurfaceView>, textures: MutableList<TextureView>) {
        when (view) {
            is SurfaceView -> surfaces.add(view)
            is TextureView -> textures.add(view)
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                collectViews(view.getChildAt(i), surfaces, textures)
            }
        }
    }

    private fun isMostlyBlack(bmp: Bitmap): Boolean {
        val w = bmp.width
        val h = bmp.height
        if (w < 4 || h < 4) return true
        val stepX = (w / 8).coerceAtLeast(1)
        val stepY = (h / 8).coerceAtLeast(1)
        var dark = 0
        var n = 0
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val c = bmp.getPixel(x, y)
                if (Color.red(c) + Color.green(c) + Color.blue(c) < 48) dark++
                n++
                x += stepX
            }
            y += stepY
        }
        return n == 0 || dark * 10 >= n * 8
    }

    private fun captureVideoShot(title: String, path: String?, positionMs: Int, done: (String?) -> Unit) {
        fun fallback() {
            if (path.isNullOrEmpty()) {
                done(null)
                return
            }
            io.execute { done(captureFrame(path, positionMs.toLong(), title)) }
        }

        fun saveBmp(bmp: Bitmap) {
            io.execute {
                val out = java.io.ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 92, out)
                bmp.recycle()
                done(saveJpegBytes(out.toByteArray(), title))
            }
        }

        val root = window?.decorView
        if (root == null) {
            fallback()
            return
        }
        val surfaces = mutableListOf<SurfaceView>()
        val textures = mutableListOf<TextureView>()
        collectViews(root, surfaces, textures)

        val tex = textures.maxByOrNull { it.width * it.height }
        if (tex != null && tex.isAvailable && tex.width > 8 && tex.height > 8) {
            try {
                val bmp = tex.getBitmap()
                if (bmp != null && !isMostlyBlack(bmp)) {
                    saveBmp(bmp)
                    return
                }
                bmp?.recycle()
            } catch (_: Exception) {
            }
        }

        val surface = surfaces.maxByOrNull { it.width * it.height }
        if (Build.VERSION.SDK_INT >= 24 && surface != null && surface.width > 8 && surface.height > 8) {
            val bmp = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
            try {
                PixelCopy.request(surface, bmp, { code ->
                    if (code == PixelCopy.SUCCESS && !isMostlyBlack(bmp)) {
                        saveBmp(bmp)
                    } else {
                        try {
                            bmp.recycle()
                        } catch (_: Exception) {
                        }
                        fallback()
                    }
                }, mainHandler)
                return
            } catch (_: Exception) {
                try {
                    bmp.recycle()
                } catch (_: Exception) {
                }
            }
        }

        fallback()
    }

    private fun saveJpegBytes(bytes: ByteArray, title: String): String? {
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val safe = title.replace(Regex("[^A-Za-z0-9._-]"), "_").take(40)
        val name = "VID_${stamp}_$safe.jpg"
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_DCIM + "/Screenshots")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: return writeLegacyBytes(bytes, name)
            return try {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: return writeLegacyBytes(bytes, name)
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                uri.toString()
            } catch (_: Exception) {
                writeLegacyBytes(bytes, name)
            }
        }
        return writeLegacyBytes(bytes, name)
    }

    private fun writeLegacyBytes(bytes: ByteArray, name: String): String? {
        return try {
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM), "Screenshots")
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, name)
            FileOutputStream(file).use { it.write(bytes) }
            MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null)
            file.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        var eventsSink: EventChannel.EventSink? = null

        fun emitMedia(action: String, extra: Map<String, Any?> = emptyMap()) {
            val payload = HashMap<String, Any?>(extra.size + 2)
            payload["type"] = "media"
            payload["action"] = action
            payload.putAll(extra)
            eventsSink?.success(payload)
        }

        private val videoExt = setOf(
            "mp4", "mkv", "webm", "avi", "mov", "m4v", "3gp", "flv", "wmv",
            "mpeg", "mpg", "m2ts", "mts", "vob", "f4v", "ogv"
        )
        private val textExt = setOf(
            "ts", "tsx", "js", "jsx", "mjs", "cjs", "json", "txt", "md", "css",
            "html", "htm", "xml", "svg", "map", "yml", "yaml", "py", "java",
            "kt", "dart", "c", "h", "cpp", "go", "rs", "sh", "log", "csv",
            "toml", "ini", "cfg", "d.ts"
        )

        fun isVideoFile(f: File): Boolean {
            val name = f.name.lowercase()
            if (name.endsWith(".d.ts")) return false
            val ext = f.extension.lowercase()
            if (ext == "ts") return isMpegTs(f)
            if (ext in textExt) return false
            return ext in videoExt
        }

        private fun isMpegTs(f: File): Boolean {
            if (f.length() < 188) return false
            return try {
                f.inputStream().use { it.read() == 0x47 }
            } catch (_: Exception) {
                false
            }
        }
    }
}
