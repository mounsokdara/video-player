package com.mounsokdara.video_player

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
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
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = NativeConstants.CHANNEL
    private val eventName = NativeConstants.EVENTS
    private var wantPip = false
    private var isPlaying = false
    private var keepScreenOn = false
    private var pendingOpen: String? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io = java.util.concurrent.Executors.newSingleThreadExecutor()
    private var previewRetriever: MediaMetadataRetriever? = null
    private var previewBoundPath: String? = null
    private var pickResult: MethodChannel.Result? = null
    private val pickVideoCode = NativeConstants.PICK_VIDEO_CODE
    private lateinit var systemBars: SystemBarController
    private lateinit var audioFocus: AudioFocusController
    private lateinit var equalizer: EqualizerController
    private lateinit var appNative: AppNative

    override fun onCreate(savedInstanceState: Bundle?) {
        systemBars = SystemBarController(this)
        equalizer = EqualizerController(
            this,
            { flutterEngine },
            mainHandler,
            { NativeCrashLog.breadcrumb(this, it) },
            { NativeCrashLog.write(this, it) }
        )
        audioFocus = AudioFocusController(
            this,
            mainHandler,
            { MainActivity.emitMedia(it) },
            { NativeCrashLog.breadcrumb(this, it) },
            isPlaying
        ) { isPlaying = it }
        appNative = AppNative(this, systemBars, audioFocus, equalizer)
        super.onCreate(savedInstanceState)
        systemBars.enableEdgeToEdge()
        NativeCrashLog.installHook(this) { emit(it) }
        handleIncoming(intent)
    }

    override fun onDestroy() {
        try {
            File(filesDir, NativeConstants.FILE_DIRTY).delete()
            File(filesDir, NativeConstants.FILE_ACTION).writeText("idle")
        } catch (_: Exception) {
        }
        equalizer.release()
        bindPreview(null)
        audioFocus.release()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) systemBars.reapply()
    }

    override fun onResume() {
        super.onResume()
        if (::systemBars.isInitialized) systemBars.reapply()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (::systemBars.isInitialized) systemBars.reapply()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncoming(intent)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickVideoCode) return
        val reply = pickResult
        pickResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            reply?.success(null)
            return
        }
        val uri = data.data!!
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) {
        }
        reply?.success(uri.toString())
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
                    if (appNative.handleLocal(call.method, call, result)) return@setMethodCallHandler
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
                            audioFocus.setPlaying(isPlaying)
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
                        "initEqualizer" -> result.success(equalizer.initAndDescribe())
                        "setEqBand" -> {
                            equalizer.setBand(call.argument<Int>("band") ?: 0, call.argument<Int>("level") ?: 0)
                            result.success(true)
                        }
                        "setEqBands" -> {
                            equalizer.setBands(call.argument<List<Int>>("levels") ?: emptyList())
                            result.success(true)
                        }
                        "setEqPreset" -> result.success(true)
                        "setEqEnabled" -> {
                            equalizer.setEnabled(call.argument<Boolean>("on") ?: false)
                            result.success(true)
                        }
                        "setBassBoost" -> {
                            equalizer.setBass(
                                call.argument<Boolean>("on") ?: false,
                                call.argument<Int>("strength") ?: 0
                            )
                            result.success(true)
                        }
                        "setVirtualizer" -> {
                            equalizer.setVirtualizer(
                                call.argument<Boolean>("on") ?: false,
                                call.argument<Int>("strength") ?: 0
                            )
                            result.success(true)
                        }
                        "preparePreview" -> {
                            val path = call.argument<String>("path")
                            io.execute { bindPreview(path) }
                            result.success(true)
                        }
                        "setPlaybackParams" -> {
                            val speed = (call.argument<Double>("speed") ?: 1.0).toFloat()
                            val pitchShift = call.argument<Boolean>("pitchShift") ?: false
                            equalizer.applyPlaybackParams(speed, pitchShift)
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
                                NativeCrashLog.write(this, "startBackground: ${t.message}\n${Log.getStackTraceString(t)}")
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
                        "lastCrash" -> result.success(NativeCrashLog.readLast(this))
                        "breadcrumb" -> {
                            NativeCrashLog.breadcrumb(this, call.argument<String>("action") ?: "")
                            result.success(true)
                        }
                        "pickVideo" -> {
                            if (pickResult != null) {
                                result.success(null)
                            } else {
                                pickResult = result
                                launchPickVideo()
                            }
                        }
                        "applyPlaybackGuard" -> {
                            val anti = call.argument<Boolean>("antiCrash") ?: true
                            val low = call.argument<Boolean>("lowMem") ?: true
                            val path = call.argument<String>("path") ?: ""
                            io.execute {
                                val out = try {
                                    if (anti) VideoDecompressor.decompress(this, path, low) else path
                                } catch (_: Throwable) {
                                    path
                                }
                                mainHandler.post { result.success(out) }
                            }
                        }
                        "decompressVideo" -> {
                            val path = call.argument<String>("path") ?: ""
                            val low = call.argument<Boolean>("lowMem") ?: true
                            io.execute {
                                val out = try {
                                    VideoDecompressor.decompress(this, path, low)
                                } catch (_: Throwable) {
                                    path
                                }
                                mainHandler.post { result.success(out) }
                            }
                        }
                        "extractCaptions" -> {
                            val path = call.argument<String>("path") ?: ""
                            io.execute {
                                val cues = extractCaptions(path)
                                mainHandler.post { result.success(cues) }
                            }
                        }
                        "transcribeVideo" -> {
                            val path = call.argument<String>("path") ?: ""
                            transcribeVideo(path, result)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    NativeCrashLog.write(this, "channel ${call.method}: ${e.message}\n${Log.getStackTraceString(e)}")
                    result.error("ERR", e.message, null)
                }
            }
    }

    private fun bindPreview(path: String?) {
        if (path.isNullOrEmpty()) {
            try { previewRetriever?.release() } catch (_: Exception) {}
            previewRetriever = null
            previewBoundPath = null
            return
        }
        if (path == previewBoundPath && previewRetriever != null) return
        try { previewRetriever?.release() } catch (_: Exception) {}
        previewRetriever = null
        previewBoundPath = null
        val r = MediaMetadataRetriever()
        try {
            val file = File(path)
            if (file.exists()) r.setDataSource(path) else r.setDataSource(this, Uri.parse(path))
            previewRetriever = r
            previewBoundPath = path
        } catch (_: Exception) {
            try { r.release() } catch (_: Exception) {}
        }
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
        scanVideosInto(dir, depth, hidden, out, intArrayOf(NativeConstants.SCAN_BUDGET))
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
                while (c.moveToNext() && out.size < NativeConstants.INDEXED_CAP) {
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
        if (previewBoundPath != path || previewRetriever == null) bindPreview(path)
        val retriever = previewRetriever
        if (retriever != null) {
            try {
                return frameToJpeg(retriever, positionMs)
            } catch (_: Exception) {
                bindPreview(path)
                previewRetriever?.let {
                    return try {
                        frameToJpeg(it, positionMs)
                    } catch (_: Exception) {
                        null
                    }
                }
            }
        }
        return null
    }

    private fun frameToJpeg(retriever: MediaMetadataRetriever, positionMs: Long): ByteArray? {
        val us = positionMs * 1000
        val option = MediaMetadataRetriever.OPTION_PREVIOUS_SYNC
        val bmp: Bitmap? = if (Build.VERSION.SDK_INT >= 27) {
            retriever.getScaledFrameAtTime(us, option, 180, 102)
                ?: retriever.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST, 180, 102)
        } else {
            val full = retriever.getFrameAtTime(us, option) ?: retriever.frameAtTime
            if (full == null) {
                null
            } else if (full.width > 180) {
                val h = (full.height * 180f / full.width).toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(full, 180, h, true)
                if (scaled !== full) full.recycle()
                scaled
            } else {
                full
            }
        }
        if (bmp == null) return null
        val out = java.io.ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 40, out)
        bmp.recycle()
        return out.toByteArray()
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

    @Suppress("DEPRECATION")
    private fun launchPickVideo() {
        val candidates = ArrayList<Intent>()
        if (Build.VERSION.SDK_INT >= 33) {
            candidates.add(Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "video/*" })
        }
        candidates.add(
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "video/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
        )
        for (intent in candidates) {
            try {
                startActivityForResult(intent, pickVideoCode)
                return
            } catch (_: Exception) {
            }
        }
        pickResult?.success(null)
        pickResult = null
    }

    private fun extractCaptions(path: String): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        if (path.isEmpty()) return out
        val extractor = MediaExtractor()
        try {
            if (path.startsWith("content:")) extractor.setDataSource(this, Uri.parse(path), null)
            else extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = (format.getString(MediaFormat.KEY_MIME) ?: "").lowercase()
                val isText = mime.startsWith("text/") || mime.contains("cea") || mime.contains("vtt") ||
                    mime.contains("tx3g") || mime.contains("subrip") || mime.contains("wvtt")
                if (!isText) continue
                extractor.selectTrack(i)
                val buf = java.nio.ByteBuffer.allocate(64 * 1024)
                var n = 0
                while (n < 400) {
                    buf.clear()
                    val size = extractor.readSampleData(buf, 0)
                    if (size < 0) break
                    val time = (extractor.sampleTime / 1000).coerceAtLeast(0)
                    val bytes = ByteArray(size)
                    buf.position(0)
                    buf.get(bytes)
                    val text = decodeCue(bytes)
                    if (text.isNotBlank()) {
                        out.add(mapOf("startMs" to time, "endMs" to time + 2500, "text" to text))
                    }
                    extractor.advance()
                    n++
                }
                extractor.unselectTrack(i)
            }
        } catch (_: Throwable) {
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
        return out
    }

    private fun decodeCue(bytes: ByteArray): String {
        if (bytes.isEmpty()) return ""
        var start = 0
        if (bytes.size >= 2) {
            val len = ((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)
            if (len in 1 until bytes.size) start = 2
        }
        val raw = try {
            String(bytes, start, bytes.size - start, Charsets.UTF_8)
        } catch (_: Exception) {
            String(bytes, start, bytes.size - start, Charsets.ISO_8859_1)
        }
        return raw.replace(Regex("<[^>]+>"), " ").replace(Regex("\\s+"), " ").trim()
    }

    private fun transcribeVideo(path: String, result: MethodChannel.Result) {
        io.execute {
            val wav = extractPcmWav(path)
            if (wav == null) {
                mainHandler.post { result.success(emptyList<Map<String, Any?>>()) }
                return@execute
            }
            mainHandler.post { startFileStt(wav, result) }
        }
    }

    private fun startFileStt(wav: File, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || !SpeechRecognizer.isRecognitionAvailable(this)) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        val replied = java.util.concurrent.atomic.AtomicBoolean(false)
        fun finish(cues: List<Map<String, Any?>>) {
            if (replied.compareAndSet(false, true)) result.success(cues)
        }
        val pfd: ParcelFileDescriptor
        try {
            pfd = ParcelFileDescriptor.open(wav, ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (_: Exception) {
            finish(emptyList())
            return
        }
        val rec = SpeechRecognizer.createSpeechRecognizer(this)
        val timeout = Runnable {
            try {
                rec.cancel()
            } catch (_: Exception) {
            }
            try {
                rec.destroy()
            } catch (_: Exception) {
            }
            try {
                pfd.close()
            } catch (_: Exception) {
            }
            finish(emptyList())
        }
        mainHandler.postDelayed(timeout, 12000)
        rec.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                mainHandler.removeCallbacks(timeout)
                val texts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: arrayListOf()
                val cues = ArrayList<Map<String, Any?>>()
                if (texts.isNotEmpty()) {
                    cues.add(mapOf("startMs" to 0, "endMs" to 25000, "text" to texts.first()))
                }
                try {
                    rec.destroy()
                } catch (_: Exception) {
                }
                try {
                    pfd.close()
                } catch (_: Exception) {
                }
                finish(cues)
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val texts = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                if (!texts.isNullOrEmpty() && !replied.get()) {
                    // Some OEMs only deliver file STT here.
                }
            }

            override fun onError(error: Int) {
                mainHandler.removeCallbacks(timeout)
                try {
                    rec.destroy()
                } catch (_: Exception) {
                }
                try {
                    pfd.close()
                } catch (_: Exception) {
                }
                finish(emptyList())
            }

            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        try {
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            intent.putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pfd)
            intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
            rec.startListening(intent)
        } catch (_: Exception) {
            mainHandler.removeCallbacks(timeout)
            try {
                rec.destroy()
            } catch (_: Exception) {
            }
            try {
                pfd.close()
            } catch (_: Exception) {
            }
            finish(emptyList())
        }
    }

    private fun extractPcmWav(path: String): File? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        return try {
            if (path.startsWith("content:")) extractor.setDataSource(this, Uri.parse(path), null)
            else extractor.setDataSource(path)
            var audio = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audio = i
                    format = f
                    break
                }
            }
            if (audio < 0 || format == null) return null
            extractor.selectTrack(audio)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            val pcm = java.io.ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var inSample = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
            if (inSample <= 0) inSample = 44100
            val channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1
            val maxBytes = 16000 * 2 * 25 * maxOf(1, channels) * maxOf(1, inSample / 16000)
            var loops = 0
            while (!outputDone && pcm.size() < maxBytes && loops < 8000) {
                loops++
                if (!inputDone) {
                    val inIx = codec.dequeueInputBuffer(8_000)
                    if (inIx >= 0) {
                        val buf = codec.getInputBuffer(inIx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIx = codec.dequeueOutputBuffer(info, 8_000)
                if (outIx >= 0) {
                    val out = codec.getOutputBuffer(outIx)
                    if (out != null && info.size > 0) {
                        val chunk = ByteArray(info.size)
                        out.position(info.offset)
                        out.get(chunk)
                        pcm.write(chunk)
                    }
                    codec.releaseOutputBuffer(outIx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
            val mono = resampleTo16kMono(pcm.toByteArray(), inSample, channels)
            val wav = File(cacheDir, "stt.wav")
            writeWav(wav, mono, 16000)
            wav
        } catch (_: Throwable) {
            null
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun resampleTo16kMono(pcm: ByteArray, sampleRate: Int, channels: Int): ByteArray {
        if (pcm.size < 4) return pcm
        val ch = channels.coerceAtLeast(1)
        val inFrames = pcm.size / (2 * ch)
        if (inFrames <= 0) return ByteArray(0)
        val outRate = 16000
        val outFrames = maxOf(1, (inFrames.toLong() * outRate / sampleRate).toInt())
        val out = ByteArray(outFrames * 2)
        var i = 0
        while (i < outFrames) {
            val src = ((i.toLong() * inFrames) / outFrames).toInt().coerceIn(0, inFrames - 1)
            var acc = 0
            var c = 0
            while (c < ch) {
                val ix = (src * ch + c) * 2
                if (ix + 1 < pcm.size) {
                    val lo = pcm[ix].toInt() and 0xFF
                    val hi = pcm[ix + 1].toInt()
                    acc += (hi shl 8) or lo
                }
                c++
            }
            val sample = (acc / ch).toShort()
            out[i * 2] = (sample.toInt() and 0xFF).toByte()
            out[i * 2 + 1] = ((sample.toInt() shr 8) and 0xFF).toByte()
            i++
        }
        return out
    }

    private fun writeWav(file: File, pcm: ByteArray, sampleRate: Int) {
        val dataSize = pcm.size
        val bos = java.io.DataOutputStream(java.io.FileOutputStream(file))
        bos.writeBytes("RIFF")
        writeLeInt(bos, 36 + dataSize)
        bos.writeBytes("WAVE")
        bos.writeBytes("fmt ")
        writeLeInt(bos, 16)
        writeLeShort(bos, 1)
        writeLeShort(bos, 1)
        writeLeInt(bos, sampleRate)
        writeLeInt(bos, sampleRate * 2)
        writeLeShort(bos, 2)
        writeLeShort(bos, 16)
        bos.writeBytes("data")
        writeLeInt(bos, dataSize)
        bos.write(pcm)
        bos.close()
    }

    private fun writeLeInt(out: java.io.DataOutputStream, v: Int) {
        out.write(v and 0xFF)
        out.write((v shr 8) and 0xFF)
        out.write((v shr 16) and 0xFF)
        out.write((v shr 24) and 0xFF)
    }

    private fun writeLeShort(out: java.io.DataOutputStream, v: Int) {
        out.write(v and 0xFF)
        out.write((v shr 8) and 0xFF)
    }

    companion object {
        var eventsSink: EventChannel.EventSink? = null
        private val emitHandler = Handler(Looper.getMainLooper())

        fun emitMedia(action: String, extra: Map<String, Any?> = emptyMap()) {
            val payload = HashMap<String, Any?>(extra.size + 2)
            payload["type"] = "media"
            payload["action"] = action
            payload.putAll(extra)
            val send = Runnable { eventsSink?.success(payload) }
            if (Looper.myLooper() == Looper.getMainLooper()) send.run() else emitHandler.post(send)
        }

        fun isVideoFile(f: File): Boolean {
            val name = f.name.lowercase()
            if (name.endsWith(".d.ts")) return false
            val ext = f.extension.lowercase()
            if (ext == "ts") return isMpegTs(f)
            if (ext in NativeConstants.TEXT_EXT) return false
            return ext in NativeConstants.VIDEO_EXT
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
