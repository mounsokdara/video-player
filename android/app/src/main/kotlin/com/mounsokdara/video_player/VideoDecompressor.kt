package com.mounsokdara.video_player

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import java.io.File
import java.security.MessageDigest

/**
 * Decode oversized / wild videos onto a smaller H.264 surface so 8K and
 * quality spikes cannot allocate a full uncompressed frame in RAM.
 */
object VideoDecompressor {
    fun decompress(context: Context, path: String, lowMem: Boolean): String {
        if (path.isBlank()) return path
        val maxW = if (lowMem) 1920 else 3840
        val maxH = if (lowMem) 1080 else 2160
        val probe = probe(context, path) ?: return path
        val (w, h) = probe
        if (w <= 0 || h <= 0) return path
        val longSide = maxOf(w, h)
        val pixels = w.toLong() * h
        // Phone recordings (1080×2340) are not 8K. Only true 4K+ giants.
        val oversize = longSide >= 3840 || pixels > 3840L * 2160L
        if (!oversize) return path
        val stamp = try {
            if (path.startsWith("content:")) 0L else File(path).lastModified()
        } catch (_: Exception) {
            0L
        }
        val key = hash("$path|$w|$h|$lowMem|$stamp")
        val out = File(context.cacheDir, "decomp_$key.mp4")
        if (out.exists() && out.length() > 8192) {
            // Previous sessions wrote green artifacts. Never reuse them.
            try {
                out.delete()
            } catch (_: Exception) {
            }
        }
        return try {
            if (transcode(context, path, out, maxW, maxH)) out.absolutePath else path
        } catch (_: Throwable) {
            try {
                out.delete()
            } catch (_: Exception) {
            }
            path
        }
    }

    fun wipeCache(context: Context) {
        try {
            context.cacheDir.listFiles()?.forEach { f ->
                if (f.name.startsWith("decomp_") && f.name.endsWith(".mp4")) {
                    try {
                        f.delete()
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun probe(context: Context, path: String): Pair<Int, Int>? {
        val r = MediaMetadataRetriever()
        return try {
            if (path.startsWith("content:")) r.setDataSource(context, Uri.parse(path))
            else r.setDataSource(path)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            if (w > 0 && h > 0) w to h else null
        } catch (_: Exception) {
            null
        } finally {
            try {
                r.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun transcode(context: Context, path: String, dst: File, maxW: Int, maxH: Int): Boolean {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        try {
            if (path.startsWith("content:")) extractor.setDataSource(context, Uri.parse(path), null)
            else extractor.setDataSource(path)
            var videoIx = -1
            var audioIx = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && videoIx < 0) videoIx = i
                else if (mime.startsWith("audio/") && audioIx < 0) audioIx = i
            }
            if (videoIx < 0) return false
            val inFmt = extractor.getTrackFormat(videoIx)
            val inW = inFmt.getInteger(MediaFormat.KEY_WIDTH)
            val inH = inFmt.getInteger(MediaFormat.KEY_HEIGHT)
            val scale = minOf(maxW.toFloat() / inW, maxH.toFloat() / inH, 1f)
            var outW = (inW * scale).toInt() and 1.inv()
            var outH = (inH * scale).toInt() and 1.inv()
            if (outW < 16) outW = 16
            if (outH < 16) outH = 16
            val mime = inFmt.getString(MediaFormat.KEY_MIME) ?: return false

            dst.parentFile?.mkdirs()
            if (dst.exists()) dst.delete()
            muxer = MediaMuxer(dst.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            val encFmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH)
            encFmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            encFmt.setInteger(MediaFormat.KEY_BIT_RATE, (outW * outH * 4).coerceIn(800_000, 6_000_000))
            encFmt.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            encFmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder.configure(encFmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = encoder.createInputSurface()
            encoder.start()

            inFmt.setInteger(MediaFormat.KEY_MAX_WIDTH, outW)
            inFmt.setInteger(MediaFormat.KEY_MAX_HEIGHT, outH)
            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(inFmt, surface, null, 0)
            decoder.start()

            extractor.selectTrack(videoIx)
            val info = MediaCodec.BufferInfo()
            var muxerStarted = false
            var videoTrack = -1
            var audioTrack = -1
            var audioExtractor: MediaExtractor? = null
            if (audioIx >= 0) {
                audioExtractor = MediaExtractor()
                if (path.startsWith("content:")) audioExtractor.setDataSource(context, Uri.parse(path), null)
                else audioExtractor.setDataSource(path)
                audioExtractor.selectTrack(audioIx)
            }
            var inputDone = false
            var outputDone = false
            var loops = 0
            val deadline = System.currentTimeMillis() + 55_000
            while (!outputDone && loops < 12000 && System.currentTimeMillis() < deadline) {
                loops++
                if (!inputDone) {
                    val ix = decoder.dequeueInputBuffer(8_000)
                    if (ix >= 0) {
                        val buf = decoder.getInputBuffer(ix)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(ix, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(ix, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val decOut = decoder.dequeueOutputBuffer(info, 8_000)
                if (decOut >= 0) {
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    decoder.releaseOutputBuffer(decOut, info.size > 0)
                    if (eos) {
                        encoder.signalEndOfInputStream()
                    }
                }
                val encOut = encoder.dequeueOutputBuffer(info, 8_000)
                if (encOut == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    videoTrack = muxer.addTrack(encoder.outputFormat)
                    val aFmt = audioExtractor?.getTrackFormat(audioIx)
                    if (aFmt != null) {
                        try {
                            audioTrack = muxer.addTrack(aFmt)
                        } catch (_: Exception) {
                            audioTrack = -1
                        }
                    }
                    muxer.start()
                    muxerStarted = true
                } else if (encOut >= 0) {
                    val buf = encoder.getOutputBuffer(encOut)
                    if (muxerStarted && buf != null && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        muxer.writeSampleData(videoTrack, buf, info)
                    }
                    encoder.releaseOutputBuffer(encOut, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
            if (muxerStarted && audioTrack >= 0 && audioExtractor != null) {
                val aInfo = MediaCodec.BufferInfo()
                val aBuf = java.nio.ByteBuffer.allocate(256 * 1024)
                var n = 0
                while (n < 20000) {
                    aBuf.clear()
                    val size = audioExtractor.readSampleData(aBuf, 0)
                    if (size < 0) break
                    aInfo.offset = 0
                    aInfo.size = size
                    aInfo.presentationTimeUs = audioExtractor.sampleTime
                    aInfo.flags = audioExtractor.sampleFlags
                    muxer.writeSampleData(audioTrack, aBuf, aInfo)
                    audioExtractor.advance()
                    n++
                }
            }
            try {
                audioExtractor?.release()
            } catch (_: Exception) {
            }
            return muxerStarted && dst.exists() && dst.length() > 8192
        } finally {
            try {
                decoder?.stop()
            } catch (_: Exception) {
            }
            try {
                decoder?.release()
            } catch (_: Exception) {
            }
            try {
                encoder?.stop()
            } catch (_: Exception) {
            }
            try {
                encoder?.release()
            } catch (_: Exception) {
            }
            try {
                muxer?.stop()
            } catch (_: Exception) {
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun hash(s: String): String {
        val d = MessageDigest.getInstance("SHA-1").digest(s.toByteArray())
        return d.joinToString("") { "%02x".format(it) }.take(16)
    }
}
