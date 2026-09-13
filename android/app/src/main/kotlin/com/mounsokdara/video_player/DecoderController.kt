package com.mounsokdara.video_player

import android.content.Context
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy

class DecoderController(
    private val activity: FlutterActivity,
    private val engine: () -> FlutterEngine?,
    private val breadcrumb: (String) -> Unit,
    private val writeCrash: (String) -> Unit
) {
    @Volatile
    var software = false
        private set

    @Volatile
    var hooked = false
        private set

    private val selector: Any by lazy { makeSelector() }

    init {
        hooked = try {
            installSelector()
        } catch (t: Throwable) {
            breadcrumb("decoder init: ${t.message}")
            false
        }
    }

    fun setMode(mode: String): Boolean {
        software = mode.equals("sw", ignoreCase = true)
        if (!hooked) hooked = installSelector()
        breadcrumb("decoder mode=$mode software=$software hooked=$hooked")
        return hooked
    }

    fun apply(): Boolean {
        val found = findWrapper() ?: return false
        val wrapper = found.first
        val old = found.second
        return try {
            val neu = buildPlayer() ?: return false
            val mediaItem = invokeNoArg(old, "getCurrentMediaItem")
            val pos = (invokeNoArg(old, "getCurrentPosition") as? Number)?.toLong() ?: 0L
            val playWhenReady = invokeNoArg(old, "getPlayWhenReady") as? Boolean ?: false
            val listener = fieldValue(wrapper, "exoPlayerEventListener")
            if (listener != null) invokeOne(old, "removeListener", listener)
            invokeNoArg(old, "stop")
            invokeOne(old, "setVideoSurface", null)
            val surface = currentSurface(wrapper)
            if (surface != null) invokeOne(neu, "setVideoSurface", surface)
            if (mediaItem != null) invokeOne(neu, "setMediaItem", mediaItem)
            invokeNoArg(neu, "prepare")
            if (pos > 0) {
                try {
                    neu.javaClass.getMethod("seekTo", Long::class.javaPrimitiveType).invoke(neu, pos)
                } catch (_: Throwable) {
                }
            }
            try {
                neu.javaClass.getMethod("setPlayWhenReady", Boolean::class.javaPrimitiveType)
                    .invoke(neu, playWhenReady)
            } catch (_: Throwable) {
                invokeOne(neu, "setPlayWhenReady", playWhenReady)
            }
            if (listener != null) {
                findField(listener, "exoPlayer")?.set(listener, neu)
                invokeOne(neu, "addListener", listener)
            }
            findField(wrapper, "exoPlayer")?.set(wrapper, neu)
            findField(wrapper, "trackSelector")?.let { f ->
                val ts = invokeNoArg(neu, "getTrackSelector")
                if (ts != null) f.set(wrapper, ts)
            }
            try {
                invokeNoArg(old, "release")
            } catch (_: Throwable) {
            }
            breadcrumb("decoder applied software=$software")
            true
        } catch (t: Throwable) {
            writeCrash("applyDecoder: ${t.message}\n${android.util.Log.getStackTraceString(t)}")
            false
        }
    }

    private fun makeSelector(): Any {
        val selectorClass = Class.forName("androidx.media3.exoplayer.mediacodec.MediaCodecSelector")
        val defaultSel = selectorClass.getField("DEFAULT").get(null)
            ?: throw IllegalStateException("MediaCodecSelector.DEFAULT")
        return Proxy.newProxyInstance(selectorClass.classLoader, arrayOf(selectorClass)) { _, method, args ->
            try {
                if (method.name != "getDecoderInfos") {
                    return@newProxyInstance method.invoke(defaultSel, *(args ?: emptyArray()))
                }
                val infos = method.invoke(defaultSel, *(args ?: emptyArray())) as List<*>
                if (!software) return@newProxyInstance infos
                val mime = args?.firstOrNull() as? String ?: ""
                if (!mime.startsWith("video/")) return@newProxyInstance infos
                val sw = infos.filter { isSoftware(it) }
                if (sw.isEmpty()) return@newProxyInstance infos
                val hw = infos.filter { it != null && !isSoftware(it) }
                ArrayList<Any?>(sw.size + hw.size).apply {
                    addAll(sw)
                    addAll(hw)
                }
            } catch (e: InvocationTargetException) {
                throw e.targetException ?: e
            }
        }
    }

    private fun isSoftware(info: Any?): Boolean {
        if (info == null) return false
        val cls = info.javaClass
        try {
            val f = cls.getField("softwareOnly")
            if (f.getBoolean(info)) return true
        } catch (_: Throwable) {
        }
        try {
            val f = cls.getField("hardwareAccelerated")
            if (!f.getBoolean(info)) return true
        } catch (_: Throwable) {
        }
        val name = try {
            (cls.getField("name").get(info) as? String) ?: info.toString()
        } catch (_: Throwable) {
            info.toString()
        }
        val n = name.lowercase()
        return n.contains("google") ||
            n.contains("c2.android") ||
            n.contains("sw.decoder") ||
            n.contains("ffmpeg") ||
            n.startsWith("omx.google")
    }

    private fun installSelector(): Boolean {
        return try {
            val selectorClass = Class.forName("androidx.media3.exoplayer.mediacodec.MediaCodecSelector")
            val field = selectorClass.getField("DEFAULT")
            if (field.get(null) === selector) return true
            overwriteStatic(field, selector)
        } catch (t: Throwable) {
            breadcrumb("decoder hook failed: ${t.message}")
            false
        }
    }

    private fun overwriteStatic(field: java.lang.reflect.Field, value: Any): Boolean {
        @Suppress("DEPRECATION")
        field.isAccessible = true
        try {
            field.set(null, value)
            if (field.get(null) === value) return true
        } catch (_: Throwable) {
        }
        try {
            val art = java.lang.reflect.Field::class.java
            val flags = try {
                art.getDeclaredField("accessFlags")
            } catch (_: Throwable) {
                art.getDeclaredField("modifiers")
            }
            @Suppress("DEPRECATION")
            flags.isAccessible = true
            flags.setInt(field, field.modifiers and Modifier.FINAL.inv())
            field.set(null, value)
            if (field.get(null) === value) return true
        } catch (_: Throwable) {
        }
        return try {
            val unsafeClass = Class.forName("sun.misc.Unsafe")
            val uf = unsafeClass.getDeclaredField("theUnsafe")
            @Suppress("DEPRECATION")
            uf.isAccessible = true
            val unsafe = uf.get(null)
            val base = unsafeClass.getMethod("staticFieldBase", java.lang.reflect.Field::class.java)
                .invoke(unsafe, field)
            val offset = unsafeClass.getMethod("staticFieldOffset", java.lang.reflect.Field::class.java)
                .invoke(unsafe, field) as Long
            unsafeClass.getMethod("putObject", Any::class.java, Long::class.javaPrimitiveType, Any::class.java)
                .invoke(unsafe, base, offset, value)
            field.get(null) === value
        } catch (_: Throwable) {
            false
        }
    }

    private fun buildPlayer(): Any? {
        val context: Context = activity.applicationContext
        val rfClass = Class.forName("androidx.media3.exoplayer.DefaultRenderersFactory")
        val rf = rfClass.getConstructor(Context::class.java).newInstance(context)
        rfClass.methods.firstOrNull {
            it.name == "setEnableDecoderFallback" && it.parameterCount == 1
        }?.invoke(rf, true)
        rfClass.methods.firstOrNull {
            it.name == "setMediaCodecSelector" && it.parameterCount == 1
        }?.invoke(rf, selector)
        val builderClass = Class.forName("androidx.media3.exoplayer.ExoPlayer\$Builder")
        val renderersClass = Class.forName("androidx.media3.exoplayer.RenderersFactory")
        val builder = try {
            builderClass.getConstructor(Context::class.java, renderersClass).newInstance(context, rf)
        } catch (_: Throwable) {
            val b = builderClass.getConstructor(Context::class.java).newInstance(context)
            builderClass.methods.firstOrNull { it.name == "setRenderersFactory" }?.invoke(b, rf)
            b
        }
        return builderClass.getMethod("build").invoke(builder)
    }

    private fun currentSurface(wrapper: Any): Surface? {
        val producer = fieldValue(wrapper, "surfaceProducer") ?: return null
        return try {
            producer.javaClass.methods.firstOrNull {
                it.name == "getSurface" && it.parameterCount == 0
            }?.invoke(producer) as? Surface
        } catch (_: Throwable) {
            null
        }
    }

    private fun findWrapper(): Pair<Any, Any>? {
        val engine = engine() ?: return null
        return try {
            val plugins = collectPlugins(engine.plugins)
            for (plugin in plugins) {
                if (!plugin.javaClass.name.contains("videoplayer", ignoreCase = true)) continue
                val store = fieldValue(plugin, "videoPlayers") ?: continue
                val wrapper = lastStored(store) ?: continue
                val exo = fieldValue(wrapper, "exoPlayer")
                    ?: fieldValue(wrapper, "player")
                    ?: fieldValue(wrapper, "exo")
                    ?: continue
                return wrapper to exo
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    private fun collectPlugins(registry: Any): List<Any> {
        val out = ArrayList<Any>()
        for (name in arrayOf("flutterPluginMap", "pluginMap", "map", "plugins")) {
            val v = fieldValue(registry, name)
            if (v is Map<*, *>) {
                for (e in v.values) if (e != null) out.add(e)
            }
        }
        if (out.isEmpty()) {
            var c: Class<*>? = registry.javaClass
            while (c != null) {
                for (f in c.declaredFields) {
                    try {
                        @Suppress("DEPRECATION")
                        f.isAccessible = true
                        val v = f.get(registry)
                        if (v is Map<*, *>) {
                            for (e in v.values) if (e != null) out.add(e)
                        }
                    } catch (_: Throwable) {
                    }
                }
                c = c.superclass
            }
        }
        return out
    }

    private fun lastStored(store: Any): Any? {
        if (store is Map<*, *>) {
            return store.values.lastOrNull { it != null }
        }
        return try {
            val size = store.javaClass.getMethod("size").invoke(store) as Int
            if (size <= 0) return null
            store.javaClass.getMethod("valueAt", Int::class.javaPrimitiveType).invoke(store, size - 1)
        } catch (_: Throwable) {
            null
        }
    }

    private fun invokeNoArg(obj: Any, name: String): Any? {
        return try {
            obj.javaClass.methods.firstOrNull { it.name == name && it.parameterCount == 0 }?.invoke(obj)
        } catch (_: Throwable) {
            null
        }
    }

    private fun invokeOne(obj: Any, name: String, arg: Any?): Any? {
        return try {
            val methods = obj.javaClass.methods.filter { it.name == name && it.parameterCount == 1 }
            val m = methods.firstOrNull {
                arg == null || it.parameterTypes[0].isInstance(arg) || !it.parameterTypes[0].isPrimitive
            } ?: methods.firstOrNull()
            m?.invoke(obj, arg)
        } catch (_: Throwable) {
            null
        }
    }

    @Suppress("DiscouragedPrivateApi")
    private fun findField(obj: Any, name: String): java.lang.reflect.Field? {
        var c: Class<*>? = obj.javaClass
        while (c != null) {
            try {
                val f = c.getDeclaredField(name)
                @Suppress("DEPRECATION")
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
}
