package com.mounsokdara.video_player

import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File

object LibraryScanner {
    fun scan(
        root: File,
        depth: Int,
        includeHidden: Boolean,
        budget: Int,
        hiddenOnly: Boolean
    ): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        walk(root, depth, includeHidden, hiddenOnly, isHiddenPath(root.absolutePath), out, intArrayOf(budget))
        return out
    }

    fun thumbnailJpeg(path: String, size: Int): ByteArray? {
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
        insideHidden: Boolean,
        out: ArrayList<Map<String, Any?>>,
        budget: IntArray
    ) {
        if (budget[0] <= 0 || depth < 0 || !dir.exists() || !dir.canRead()) return
        val files = dir.listFiles() ?: return
        for (f in files) {
            if (budget[0] <= 0) return
            if (f.isDirectory) {
                if (shouldSkipDir(f, includeHidden)) continue
                val childHidden = insideHidden || f.name.startsWith(".")
                if (!includeHidden && childHidden) continue
                walk(f, depth - 1, includeHidden, hiddenOnly, childHidden, out, budget)
            } else {
                val fileHidden = insideHidden || f.name.startsWith(".") || isHiddenPath(f.absolutePath)
                if (!includeHidden && fileHidden) continue
                if (hiddenOnly && !fileHidden) continue
                if (!MainActivity.isVideoFile(f)) continue
                budget[0] = budget[0] - 1
                val meta = probeMeta(f.absolutePath)
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
