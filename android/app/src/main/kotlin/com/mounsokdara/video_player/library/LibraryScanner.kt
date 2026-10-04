package com.mounsokdara.video_player

import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

object LibraryScanner {
    // A cached pool (not a single fixed thread) so a probe that hangs on one
    // pathological file occupies only its own thread; the next file's probe
    // still gets scheduled immediately instead of queueing behind it.
    private val probeExecutor: ExecutorService = Executors.newCachedThreadPool()

    /**
     * Runs [block] with a hard wall-clock budget. If it doesn't finish in time,
     * returns [default] immediately and abandons the underlying call rather than
     * blocking the caller - native MediaExtractor/MediaMetadataRetriever calls
     * can't always be interrupted cleanly, so we don't wait for them to die,
     * we just stop waiting on them.
     */
    private fun <T> withTimeout(timeoutMs: Long, default: T, block: () -> T): T {
        val future: Future<T> = probeExecutor.submit(Callable<T> { block() })
        return try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            future.cancel(true)
            default
        } catch (_: Exception) {
            default
        }
    }

    fun scan(
        root: File,
        depth: Int,
        includeHidden: Boolean,
        budget: Int,
        hiddenOnly: Boolean,
        skipNomedia: Boolean = true
    ): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        walk(root, depth, includeHidden, hiddenOnly, skipNomedia, isHiddenPath(root.absolutePath), out, intArrayOf(budget))
        return out
    }

    /**
     * Inspects the video track's format for HDR / 10-bit signals (HLG or PQ
     * transfer function, BT.2020 color, or an HEVC Main10 profile) without
     * decoding any frames. Used so playback can proactively avoid the
     * hardware-decoder + GPU color paths that commonly glitch or black-screen
     * on this class of content on many Android chipsets.
     */
    fun colorInfo(path: String): Map<String, Any?> {
        return withTimeout<Map<String, Any?>>(800L, mapOf("isHdr" to false)) { colorInfoBody(path) }
    }

    private fun colorInfoBody(path: String): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["isHdr"] = false
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                out["mime"] = mime
                var isHdr = false
                if (Build.VERSION.SDK_INT >= 24) {
                    val transfer = if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER))
                        format.getInteger(MediaFormat.KEY_COLOR_TRANSFER) else -1
                    val standard = if (format.containsKey(MediaFormat.KEY_COLOR_STANDARD))
                        format.getInteger(MediaFormat.KEY_COLOR_STANDARD) else -1
                    out["transfer"] = transfer
                    out["standard"] = standard
                    // COLOR_TRANSFER_ST2084 (PQ) = 6, COLOR_TRANSFER_HLG = 7,
                    // COLOR_STANDARD_BT2020 = 6
                    if (transfer == 6 || transfer == 7 || standard == 6) isHdr = true
                }
                if (format.containsKey(MediaFormat.KEY_PROFILE)) {
                    val profile = format.getInteger(MediaFormat.KEY_PROFILE)
                    out["profile"] = profile
                    // HEVCProfileMain10 = 2, HEVCProfileMain10HDR10 = 4096,
                    // HEVCProfileMain10HDR10Plus = 8192
                    if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC &&
                        (profile == 2 || profile == 4096 || profile == 8192)
                    ) {
                        isHdr = true
                    }
                }
                out["isHdr"] = isHdr
                break
            }
        } catch (_: Exception) {
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
        return out
    }

    fun thumbnailJpeg(path: String, size: Int): ByteArray? {
        return withTimeout<ByteArray?>(3000L, null) { thumbnailJpegBody(path, size) }
    }

    private fun thumbnailJpegBody(path: String, size: Int): ByteArray? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val atUs = when {
                durationMs > 4000L -> 1_000_000L
                durationMs > 0L -> (durationMs * 1000L) / 4L
                else -> 0L
            }
            val edge = size.coerceIn(64, 512)
            val bmp: Bitmap? = if (Build.VERSION.SDK_INT >= 27) {
                retriever.getScaledFrameAtTime(atUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, edge, edge)
                    ?: retriever.getScaledFrameAtTime(atUs, MediaMetadataRetriever.OPTION_CLOSEST, edge, edge)
                    ?: retriever.frameAtTime
            } else {
                retriever.getFrameAtTime(atUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: retriever.frameAtTime
            }
            if (bmp == null) return null
            val scaled = if (bmp.width > edge || bmp.height > edge) {
                val ratio = edge.toFloat() / maxOf(bmp.width, bmp.height).toFloat()
                val w = (bmp.width * ratio).toInt().coerceAtLeast(1)
                val h = (bmp.height * ratio).toInt().coerceAtLeast(1)
                val next = Bitmap.createScaledBitmap(bmp, w, h, true)
                if (next !== bmp) bmp.recycle()
                next
            } else {
                bmp
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 70, out)
            if (scaled !== bmp) scaled.recycle() else bmp.recycle()
            return out.toByteArray()
        } catch (_: Exception) {
            return null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    fun isHiddenPath(path: String): Boolean {
        return path.split('/', '\\').any { it.isNotEmpty() && it.startsWith('.') }
    }

    private fun walk(
        dir: File,
        depth: Int,
        includeHidden: Boolean,
        hiddenOnly: Boolean,
        skipNomedia: Boolean,
        insideHidden: Boolean,
        out: ArrayList<Map<String, Any?>>,
        budget: IntArray
    ) {
        if (budget[0] <= 0 || depth < 0 || !dir.exists() || !dir.canRead()) return
        if (skipNomedia && File(dir, ".nomedia").exists()) return
        val files = dir.listFiles() ?: return
        for (f in files) {
            if (budget[0] <= 0) return
            if (f.isDirectory) {
                if (shouldSkipDir(f, includeHidden)) continue
                if (skipNomedia && File(f, ".nomedia").exists()) continue
                val childHidden = insideHidden || f.name.startsWith(".")
                if (!includeHidden && childHidden) continue
                walk(f, depth - 1, includeHidden, hiddenOnly, skipNomedia, childHidden, out, budget)
            } else {
                val fileHidden = insideHidden || f.name.startsWith(".") || isHiddenPath(f.absolutePath)
                if (!includeHidden && fileHidden) continue
                if (hiddenOnly && !fileHidden) continue
                if (!MainActivity.isVideoFile(f)) continue
                budget[0] = budget[0] - 1
                // Bounded: one slow/corrupt file (common with large HDR/10-bit
                // clips) can no longer stall the entire library scan.
                val meta = withTimeout<Map<String, Any?>>(1500L, emptyMap()) { probeMeta(f.absolutePath) }
                out.add(
                    mapOf(
                        "path" to f.absolutePath,
                        "name" to f.name,
                        "size" to f.length(),
                        "modified" to f.lastModified(),
                        "folder" to (f.parent ?: ""),
                        "durationMs" to (meta["durationMs"] ?: 0L),
                        "width" to (meta["width"] ?: 0),
                        "height" to (meta["height"] ?: 0),
                        "mime" to meta["mime"]
                    )
                )
            }
        }
    }

    private fun shouldSkipDir(f: File, includeHidden: Boolean): Boolean {
        val n = f.name
        if (!includeHidden && n.startsWith(".")) return true
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

    fun probeMeta(path: String): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["durationMs"] = 0L
        out["width"] = 0
        out["height"] = 0
        out["mime"] = null
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                out["mime"] = mime
                if (format.containsKey(MediaFormat.KEY_WIDTH)) {
                    out["width"] = format.getInteger(MediaFormat.KEY_WIDTH)
                }
                if (format.containsKey(MediaFormat.KEY_HEIGHT)) {
                    out["height"] = format.getInteger(MediaFormat.KEY_HEIGHT)
                }
                if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    out["durationMs"] = format.getLong(MediaFormat.KEY_DURATION) / 1000L
                }
                break
            }
        } catch (_: Exception) {
        } finally {
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
        val dur = out["durationMs"] as? Long ?: 0L
        val w = out["width"] as? Int ?: 0
        if (dur > 0L && w > 0) return out
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            if (w <= 0) {
                out["width"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            }
            if ((out["height"] as? Int ?: 0) <= 0) {
                out["height"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            }
            if (dur <= 0L) {
                out["durationMs"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            }
            if (out["mime"] == null) {
                out["mime"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            }
        } catch (_: Exception) {
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
        return out
    }
}
