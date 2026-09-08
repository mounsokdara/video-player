package com.mounsokdara.video_player

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.ActivityInfo
import android.media.audiofx.Equalizer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "app.videoplayer/android"
    private var equalizer: Equalizer? = null
    private var wantPip = false
    private var isPlaying = false
    private var keepScreenOn = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        "listStorageVolumes" -> {
                            result.success(listVolumes())
                        }
                        "listVideoFiles" -> {
                            val root = call.argument<String>("path") ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            result.success(scanVideos(File(root), 4))
                        }
                        "deletePath" -> {
                            val path = call.argument<String>("path") ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            val file = File(path)
                            result.success(file.exists() && file.delete())
                        }
                        "renamePath" -> {
                            val path = call.argument<String>("path") ?: return@setMethodCallHandler result.error("ARG", "path", null)
                            val name = call.argument<String>("name") ?: return@setMethodCallHandler result.error("ARG", "name", null)
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
                        "openWriteSettings" -> {
                            if (Build.VERSION.SDK_INT >= 23 && !Settings.System.canWrite(this)) {
                                startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                                    data = Uri.parse("package:$packageName")
                                })
                            }
                            result.success(true)
                        }
                        "initEqualizer" -> {
                            val session = call.argument<Int>("sessionId") ?: 0
                            try {
                                equalizer?.release()
                                equalizer = Equalizer(0, session).apply { enabled = true }
                                val bands = equalizer!!.numberOfBands.toInt()
                                val map = HashMap<String, Any>()
                                map["bands"] = bands
                                map["min"] = equalizer!!.bandLevelRange[0].toInt()
                                map["max"] = equalizer!!.bandLevelRange[1].toInt()
                                val freqs = ArrayList<Int>()
                                val levels = ArrayList<Int>()
                                for (i in 0 until bands) {
                                    freqs.add(equalizer!!.getCenterFreq(i.toShort()) / 1000)
                                    levels.add(equalizer!!.getBandLevel(i.toShort()).toInt())
                                }
                                map["freqs"] = freqs
                                map["levels"] = levels
                                val presets = ArrayList<String>()
                                for (i in 0 until equalizer!!.numberOfPresets) {
                                    presets.add(equalizer!!.getPresetName(i.toShort()))
                                }
                                map["presets"] = presets
                                result.success(map)
                            } catch (e: Exception) {
                                result.error("EQ", e.message, null)
                            }
                        }
                        "setEqBand" -> {
                            val band = call.argument<Int>("band") ?: 0
                            val level = call.argument<Int>("level") ?: 0
                            equalizer?.setBandLevel(band.toShort(), level.toShort())
                            result.success(true)
                        }
                        "setEqPreset" -> {
                            val preset = call.argument<Int>("preset") ?: 0
                            equalizer?.usePreset(preset.toShort())
                            result.success(true)
                        }
                        "setEqEnabled" -> {
                            equalizer?.enabled = call.argument<Boolean>("on") ?: true
                            result.success(true)
                        }
                        "toast" -> {
                            Toast.makeText(this, call.argument<String>("msg") ?: "", Toast.LENGTH_SHORT).show()
                            result.success(true)
                        }
                        "startBackground" -> {
                            val title = call.argument<String>("title") ?: "Video Player"
                            val intent = Intent(this, PlaybackService::class.java)
                            intent.putExtra("title", title)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                            result.success(true)
                        }
                        "stopBackground" -> {
                            stopService(Intent(this, PlaybackService::class.java))
                            result.success(true)
                        }
                        "openNotificationSettings" -> {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            intent.putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            startActivity(intent)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("ERR", e.message, null)
                }
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
