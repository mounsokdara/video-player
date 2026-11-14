package com.mounsokdara.video_player.accessibility.livecaption

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

object ModelStore {
    private const val SHERPA = "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    private const val SHERPA_VERSION = "v1.13.8"
    private const val RUNTIME_ARCHIVE = SHERPA + SHERPA_VERSION + "/sherpa-onnx-" + SHERPA_VERSION + "-android.tar.bz2"
    private const val RUNTIME_ARCHIVE_SIZE = 46_093_321L
    private const val RUNTIME_ARCHIVE_SHA256 = "2ff63469a71cb6009aa2e3ed5f4a670f8abdcbe4bb9ffd23776afc792a6b4f44"
    private const val VAD_URL = SHERPA + "asr-models/silero_vad.onnx"
    private const val HF_WHISPER = "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-"
    const val RUNTIME = "runtime"

    class FileSpec(val rel: String, val url: String, val approx: Long, val entry: String? = null)
    class Item(val id: String, val title: String, val note: String, val files: List<FileSpec>) {
        val totalApprox: Long get() = files.sumOf { it.approx }
    }

    class State(val downloading: Boolean, val progress: Int, val error: String?)

    private class Cancelled : IOException("cancelled")

    private val states = ConcurrentHashMap<String, State>()
    private val cancels = ConcurrentHashMap<String, AtomicBoolean>()
    private val listeners = CopyOnWriteArrayList<Runnable>()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var lastNotify = 0L
    private var nativeLoaded = false

    fun abi(): String {
        val wanted = if (android.os.Process.is64Bit()) listOf("arm64-v8a", "x86_64") else listOf("armeabi-v7a")
        return Build.SUPPORTED_ABIS.firstOrNull { it in wanted } ?: ""
    }

    fun items(): List<Item> = listOf(
        runtime(),
        model("base", "Whisper Base", "Faster, good accuracy", 29_100_000L, 130_700_000L),
        model("small", "Whisper Small", "Slower, most accurate", 112_400_000L, 262_200_000L),
    )

    fun item(id: String): Item = items().first { it.id == id }

    private fun runtime(): Item {
        val abi = abi()
        val files = if (abi.isEmpty()) emptyList() else listOf(
            FileSpec("runtime-$abi/libonnxruntime.so", RUNTIME_ARCHIVE, RUNTIME_ARCHIVE_SIZE, "jniLibs/$abi/libonnxruntime.so"),
            FileSpec("runtime-$abi/libsherpa-onnx-jni.so", RUNTIME_ARCHIVE, 0L, "jniLibs/$abi/libsherpa-onnx-jni.so"),
            FileSpec("silero_vad.onnx", VAD_URL, 640_000L),
        )
        return Item(RUNTIME, "Speech engine (required)", "Runs the AI on your phone", files)
    }

    private fun model(id: String, title: String, note: String, enc: Long, dec: Long) = Item(
        id, title, note,
        listOf(
            FileSpec("models/$id/encoder.int8.onnx", "$HF_WHISPER$id/resolve/main/$id-encoder.int8.onnx", enc),
            FileSpec("models/$id/decoder.int8.onnx", "$HF_WHISPER$id/resolve/main/$id-decoder.int8.onnx", dec),
            FileSpec("models/$id/tokens.txt", "$HF_WHISPER$id/resolve/main/$id-tokens.txt", 800_000L),
        )
    )

    fun root(c: Context) = File(c.filesDir, "livecaption")
    fun file(c: Context, rel: String) = File(root(c), rel)

    fun isReady(c: Context, id: String): Boolean {
        val it = item(id)
        return it.files.isNotEmpty() && it.files.all { f -> file(c, f.rel).exists() }
    }

    fun installedModels(c: Context): List<Item> = items().filter { it.id != RUNTIME && isReady(c, it.id) }

    fun modelDir(c: Context, id: String) = file(c, "models/$id")

    fun state(id: String): State = states[id] ?: State(false, 0, null)

    fun addListener(r: Runnable) { listeners.addIfAbsent(r) }
    fun removeListener(r: Runnable) { listeners.remove(r) }

    private fun publish(id: String, st: State) {
        states[id] = st
        val now = System.currentTimeMillis()
        if (!st.downloading || now - lastNotify > 200) {
            lastNotify = now
            main.post { for (l in listeners) l.run() }
        }
    }

    @Synchronized
    fun loadNative(c: Context) {
        if (nativeLoaded) return
        val abi = abi()
        System.load(file(c, "runtime-$abi/libonnxruntime.so").absolutePath)
        System.load(file(c, "runtime-$abi/libsherpa-onnx-jni.so").absolutePath)
        nativeLoaded = true
    }

    fun download(ctx: Context, id: String) {
        val app = ctx.applicationContext
        if (states[id]?.downloading == true) return
        val cancel = AtomicBoolean(false)
        cancels[id] = cancel
        publish(id, State(true, 0, null))
        Thread {
            try {
                val chain = if (id != RUNTIME && !isReady(app, RUNTIME)) listOf(RUNTIME, id) else listOf(id)
                val total = chain.sumOf { item(it).totalApprox }.coerceAtLeast(1L)
                var base = 0L
                val unpacked = HashSet<String>()
                for (cid in chain) {
                    for (f in item(cid).files) {
                        val onBytes = { got: Long ->
                            val p = ((base + got) * 1000L / total).toInt().coerceIn(0, 999)
                            publish(id, State(true, p, null))
                        }
                        if (f.entry != null) {
                            if (unpacked.add(f.url)) fetchFromArchive(app, item(cid).files.filter { it.url == f.url }, cancel, onBytes)
                        } else {
                            fetch(app, f, cancel, onBytes)
                        }
                        base += f.approx
                    }
                }
                publish(id, State(false, 1000, null))
            } catch (_: Cancelled) {
                publish(id, State(false, 0, null))
            } catch (e: Throwable) {
                publish(id, State(false, 0, e.message ?: "Download failed"))
            }
        }.start()
    }

    fun cancel(id: String) {
        cancels[id]?.set(true)
    }

    fun delete(ctx: Context, id: String) {
        val app = ctx.applicationContext
        cancel(id)
        for (f in item(id).files) {
            file(app, f.rel).delete()
            File(file(app, f.rel).path + ".part").delete()
        }
        if (id == RUNTIME) {
            val a = file(app, "runtime-${abi()}/sherpa-onnx-android.tar.bz2")
            a.delete()
            File(a.path + ".part").delete()
        }
        publish(id, State(false, 0, null))
    }

    private fun fetchFromArchive(c: Context, specs: List<FileSpec>, cancel: AtomicBoolean, onBytes: (Long) -> Unit) {
        val missing = specs.filter { !file(c, it.rel).exists() }
        if (missing.isEmpty()) return
        val archiveSpec = FileSpec("runtime-${abi()}/sherpa-onnx-android.tar.bz2", specs.first().url, RUNTIME_ARCHIVE_SIZE)
        fetch(c, archiveSpec, cancel, onBytes)
        val archive = file(c, archiveSpec.rel)
        if (sha256(archive) != RUNTIME_ARCHIVE_SHA256) {
            archive.delete()
            throw IOException("The downloaded speech engine did not match the official file. Try again.")
        }
        val wanted = HashMap<String, File>()
        for (m in missing) wanted[m.entry!!] = file(c, m.rel)
        val got = try {
            TarBz2.extract(archive, wanted) { cancel.get() }
        } catch (e: IOException) {
            if (cancel.get()) throw Cancelled()
            throw e
        }
        if (got != wanted.size) throw IOException("The speech engine is missing a file for this phone (${abi()}).")
        for (m in missing) if (m.rel.endsWith(".so")) file(c, m.rel).setReadOnly()
        archive.delete()
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { inp ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = inp.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun fetch(c: Context, f: FileSpec, cancel: AtomicBoolean, onBytes: (Long) -> Unit) {
        val dest = file(c, f.rel)
        if (dest.exists()) return
        dest.parentFile?.mkdirs()
        val part = File(dest.path + ".part")
        var existing = if (part.exists()) part.length() else 0L
        val conn = URL(f.url).openConnection() as HttpURLConnection
        conn.connectTimeout = 20_000
        conn.readTimeout = 30_000
        if (existing > 0) conn.setRequestProperty("Range", "bytes=$existing-")
        conn.connect()
        val code = conn.responseCode
        if (code == 416) {
            part.renameTo(dest)
            return
        }
        if (code != 200 && code != 206) throw IOException("Download failed (HTTP $code). Check your internet connection.")
        val append = code == 206
        if (!append) existing = 0
        val remaining = conn.contentLengthLong
        val total = if (remaining > 0) existing + remaining else -1L
        var done = existing
        FileOutputStream(part, append).use { out ->
            conn.inputStream.use { inp ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    if (cancel.get()) throw Cancelled()
                    val n = inp.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    done += n
                    onBytes(done)
                }
            }
        }
        if (total > 0 && part.length() != total) throw IOException("Download interrupted. Tap to resume.")
        if (!part.renameTo(dest)) throw IOException("Could not save file")
        if (dest.name.endsWith(".so")) dest.setReadOnly()
    }
}
