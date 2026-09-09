package com.mounsokdara.video_player

import android.app.PictureInPictureParams
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.Virtualizer
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
import android.util.Rational
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
    private var equalizer: Equalizer? = null
    private var bassBoost: BassBoost? = null
    private var virtualizer: Virtualizer? = null
    private var wantPip = false
    private var isPlaying = false
    private var keepScreenOn = false
    private var pendingOpen: String? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val tenBandHz = intArrayOf(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
    private var tenBandLevels = IntArray(10)
    private var eqWanted = false
    private var bassWanted = false
    private var surroundWanted = false
    private var bassStrength = 0
    private var surroundStrength = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncoming(intent)
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
                            result.success(scanVideos(File(root), 4))
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
                            var session = call.argument<Int>("sessionId") ?: 0
                            if (session == 0) session = currentAudioSession()
                            result.success(initAudioFx(session))
                        }
                        "setEqBand" -> {
                            val band = call.argument<Int>("band") ?: 0
                            val level = call.argument<Int>("level") ?: 0
                            if (band in 0..9) tenBandLevels[band] = level
                            applyTenBands()
                            result.success(true)
                        }
                        "setEqBands" -> {
                            val levels = call.argument<List<Int>>("levels") ?: emptyList()
                            for (i in 0 until minOf(10, levels.size)) tenBandLevels[i] = levels[i]
                            applyTenBands()
                            result.success(true)
                        }
                        "setEqPreset" -> {
                            val preset = call.argument<Int>("preset") ?: 0
                            equalizer?.usePreset(preset.toShort())
                            result.success(true)
                        }
                        "setEqEnabled" -> {
                            eqWanted = call.argument<Boolean>("on") ?: true
                            applyFxEnabled()
                            result.success(true)
                        }
                        "setBassBoost" -> {
                            bassWanted = call.argument<Boolean>("on") ?: false
                            bassStrength = (call.argument<Int>("strength") ?: 0).coerceIn(0, 1000)
                            bassBoost?.setStrength(bassStrength.toShort())
                            applyFxEnabled()
                            result.success(true)
                        }
                        "setVirtualizer" -> {
                            surroundWanted = call.argument<Boolean>("on") ?: false
                            surroundStrength = (call.argument<Int>("strength") ?: 0).coerceIn(0, 1000)
                            virtualizer?.setStrength(surroundStrength.toShort())
                            applyFxEnabled()
                            result.success(true)
                        }
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
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
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
                            result.success(captureFrame(path, positionMs.toLong(), title))
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
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("ERR", e.message, null)
                }
            }
    }

    private fun applyFxEnabled() {
        try {
            equalizer?.enabled = eqWanted
        } catch (_: Throwable) {
        }
        try {
            bassBoost?.enabled = eqWanted && bassWanted
        } catch (_: Throwable) {
        }
        try {
            virtualizer?.enabled = eqWanted && surroundWanted
        } catch (_: Throwable) {
        }
    }

    private fun initAudioFx(session: Int): Map<String, Any> {
        try {
            equalizer?.release()
        } catch (_: Exception) {
        }
        try {
            bassBoost?.release()
        } catch (_: Exception) {
        }
        try {
            virtualizer?.release()
        } catch (_: Exception) {
        }
        equalizer = null
        bassBoost = null
        virtualizer = null
        if (session == 0) return emptyFx(0)
        try {
            equalizer = Equalizer(0, session).apply { enabled = eqWanted }
        } catch (_: Throwable) {
            equalizer = null
        }
        try {
            bassBoost = BassBoost(0, session).apply {
                setStrength(bassStrength.toShort())
                enabled = eqWanted && bassWanted
            }
        } catch (_: Throwable) {
            bassBoost = null
        }
        try {
            virtualizer = Virtualizer(0, session).apply {
                setStrength(surroundStrength.toShort())
                enabled = eqWanted && surroundWanted
            }
        } catch (_: Throwable) {
            virtualizer = null
        }
        try {
            applyTenBands()
            applyFxEnabled()
        } catch (_: Throwable) {
        }
        val eq = equalizer ?: return emptyFx(session)
        return try {
            val bands = eq.numberOfBands.toInt()
            val map = HashMap<String, Any>()
            map["bands"] = 10
            map["deviceBands"] = bands
            map["min"] = eq.bandLevelRange[0].toInt()
            map["max"] = eq.bandLevelRange[1].toInt()
            map["freqs"] = tenBandHz.toList()
            map["levels"] = tenBandLevels.toList()
            map["sessionId"] = session
            val presets = ArrayList<String>()
            for (i in 0 until eq.numberOfPresets) {
                presets.add(eq.getPresetName(i.toShort()))
            }
            map["presets"] = presets
            map
        } catch (_: Throwable) {
            emptyFx(session)
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

    private fun applyTenBands() {
        val eq = equalizer ?: return
        try {
            val n = eq.numberOfBands.toInt()
            val min = eq.bandLevelRange[0].toInt()
            val max = eq.bandLevelRange[1].toInt()
            for (i in 0 until n) {
                val freqHz = eq.getCenterFreq(i.toShort()) / 1000
                val idx = nearestBand(freqHz)
                val level = tenBandLevels[idx].coerceIn(min, max)
                eq.setBandLevel(i.toShort(), level.toShort())
            }
        } catch (_: Throwable) {
        }
    }

    private fun nearestBand(freqHz: Int): Int {
        var best = 0
        var bestDiff = Int.MAX_VALUE
        for (i in tenBandHz.indices) {
            val d = kotlin.math.abs(tenBandHz[i] - freqHz)
            if (d < bestDiff) {
                bestDiff = d
                best = i
            }
        }
        return best
    }

    private fun currentAudioSession(): Int {
        for (exo in collectExoPlayers()) {
            try {
                val method = exo.javaClass.methods.firstOrNull { it.name == "getAudioSessionId" } ?: continue
                val id = method.invoke(exo) as? Int ?: continue
                if (id != 0) return id
            } catch (_: Exception) {
            }
        }
        return 0
    }

    private fun collectExoPlayers(): List<Any> {
        val out = ArrayList<Any>()
        val engine = flutterEngine ?: return out
        try {
            val pluginClass = Class.forName("io.flutter.plugins.videoplayer.VideoPlayerPlugin")
            val plugin = engine.plugins.get(pluginClass as Class<out FlutterPlugin>) ?: return out
            walkForExo(plugin, out, 0, HashSet())
        } catch (_: Exception) {
        }
        return out
    }

    private fun walkForExo(root: Any, out: MutableList<Any>, depth: Int, seen: MutableSet<Int>) {
        if (depth > 8) return
        val id = System.identityHashCode(root)
        if (!seen.add(id)) return
        val name = root.javaClass.name
        if (name.contains("ExoPlayer") && !name.contains("Plugin") && !name.contains("Factory")) {
            out.add(root)
            return
        }
        if (name.startsWith("android.") || name.startsWith("java.") || name.startsWith("kotlin.") ||
            name.startsWith("dalvik.") || name.startsWith("androidx.media3.exoplayer.source")
        ) {
            return
        }
        when (root) {
            is Map<*, *> -> {
                for (v in root.values) if (v != null) walkForExo(v, out, depth + 1, seen)
                return
            }
            is Iterable<*> -> {
                for (v in root) if (v != null) walkForExo(v, out, depth + 1, seen)
                return
            }
        }
        if (name.contains("SparseArray")) {
            try {
                val size = (root.javaClass.methods.firstOrNull { it.name == "size" }?.invoke(root) as? Int) ?: 0
                val valueAt = root.javaClass.methods.firstOrNull { it.name == "valueAt" }
                for (i in 0 until size) {
                    val item = valueAt?.invoke(root, i) ?: continue
                    walkForExo(item, out, depth + 1, seen)
                }
            } catch (_: Exception) {
            }
            return
        }
        var cls: Class<*>? = root.javaClass
        while (cls != null && cls != Any::class.java) {
            for (field in cls.declaredFields) {
                try {
                    field.isAccessible = true
                    val v = field.get(root) ?: continue
                    val vn = v.javaClass.name
                    if (vn.startsWith("android.") && !vn.contains("SparseArray")) continue
                    if (vn.startsWith("java.") || vn.startsWith("kotlin.")) continue
                    walkForExo(v, out, depth + 1, seen)
                } catch (_: Exception) {
                }
            }
            cls = cls.superclass
        }
    }

    private fun applyPlaybackParams(speed: Float, pitchShift: Boolean) {
        val pitch = if (pitchShift) speed else 1f
        val paramsClass = try {
            Class.forName("androidx.media3.common.PlaybackParameters")
        } catch (_: Exception) {
            try {
                Class.forName("com.google.android.exoplayer2.PlaybackParameters")
            } catch (_: Exception) {
                return
            }
        }
        try {
            val ctor = paramsClass.getConstructor(Float::class.javaPrimitiveType, Float::class.javaPrimitiveType)
            val params = ctor.newInstance(speed, pitch)
            for (exo in collectExoPlayers()) {
                val method = exo.javaClass.methods.firstOrNull { it.name == "setPlaybackParameters" } ?: continue
                method.invoke(exo, params)
            }
        } catch (_: Exception) {
        }
    }

    private fun captureFrame(path: String, positionMs: Long, title: String): String? {
        val retriever = MediaMetadataRetriever()
        return try {
            val file = File(path)
            if (file.exists()) retriever.setDataSource(path) else retriever.setDataSource(this, Uri.parse(path))
            val bitmap = retriever.getFrameAtTime(positionMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
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

    private fun scanVideos(dir: File, depth: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        if (depth < 0 || !dir.exists() || !dir.canRead()) return out
        val files = dir.listFiles() ?: return out
        for (f in files) {
            if (f.isDirectory) {
                if (!f.name.startsWith(".")) out.addAll(scanVideos(f, depth - 1))
            } else if (isVideoFile(f)) {
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
        return out
    }

    companion object {
        var eventsSink: EventChannel.EventSink? = null

        fun emitMedia(action: String) {
            eventsSink?.success(mapOf("type" to "media", "action" to action))
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
