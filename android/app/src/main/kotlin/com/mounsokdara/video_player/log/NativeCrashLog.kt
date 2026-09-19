package com.mounsokdara.video_player

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object NativeCrashLog {
    fun peek(context: Context): String {
        val crash = File(context.filesDir, NativeConstants.FILE_CRASH)
        val actionFile = File(context.filesDir, NativeConstants.FILE_ACTION)
        val buf = StringBuilder()
        try {
            if (actionFile.exists()) {
                val action = actionFile.readText()
                if (action.isNotBlank()) buf.append("Last action: ").append(action).append('\n')
            }
        } catch (_: Exception) {
        }
        try {
            if (crash.exists()) buf.append(crash.readText()).append('\n')
        } catch (_: Exception) {
        }
        val out = buf.toString().trim()
        return if (out.isEmpty()) "No crash captured." else out
    }

    fun clear(context: Context) {
        try {
            File(context.filesDir, NativeConstants.FILE_CRASH).delete()
        } catch (_: Exception) {
        }
        try {
            File(context.filesDir, NativeConstants.FILE_ACTION).writeText("")
        } catch (_: Exception) {
        }
        try {
            File(context.filesDir, NativeConstants.FILE_DIRTY).delete()
        } catch (_: Exception) {
        }
        try {
            File(context.filesDir, NativeConstants.FILE_DEBUG).writeText("")
        } catch (_: Exception) {
        }
    }

    fun write(context: Context, text: String) {
        try {
            File(context.filesDir, NativeConstants.FILE_CRASH).writeText(
                "===== NATIVE ${SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())} =====\n$text"
            )
        } catch (_: Exception) {
        }
    }

    fun breadcrumb(context: Context, action: String) {
        try {
            File(context.filesDir, NativeConstants.FILE_ACTION).writeText(action)
        } catch (_: Exception) {
        }
    }

    fun readLast(context: Context): String? {
        val crash = File(context.filesDir, NativeConstants.FILE_CRASH)
        val dirty = File(context.filesDir, NativeConstants.FILE_DIRTY)
        val actionFile = File(context.filesDir, NativeConstants.FILE_ACTION)
        val hasCrash = crash.exists()
        val action = try {
            if (actionFile.exists()) actionFile.readText() else ""
        } catch (_: Exception) {
            ""
        }
        val buf = StringBuilder()
        if (action.isNotBlank()) buf.append("Last action: ").append(action).append('\n')
        if (hasCrash) {
            val body = try {
                crash.readText()
            } catch (_: Exception) {
                ""
            }
            crash.delete()
            if (body.isNotBlank() && !isDetachedFlutterJniMessage(body)) {
                buf.append(body)
            }
        }
        try {
            dirty.delete()
            dirty.writeText("running")
        } catch (_: Exception) {
        }
        val out = buf.toString().trim()
        if (out.isEmpty() || !out.contains("=====")) return null
        return out
    }

    fun installHook(context: Context, emit: (Map<String, Any?>) -> Unit) {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            if (isDetachedFlutterJni(e)) {
                Log.w("VideoPlayer", "ignored FlutterJNI detach", e)
                return@setDefaultUncaughtExceptionHandler
            }
            write(context, "${e.javaClass.name}: ${e.message}\n${Log.getStackTraceString(e)}")
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
            prev?.uncaughtException(t, e)
        }
    }

    private fun isDetachedFlutterJni(e: Throwable): Boolean {
        var cur: Throwable? = e
        var hops = 0
        while (cur != null && hops < 8) {
            if (isDetachedFlutterJniMessage("${cur.javaClass.name} ${cur.message}")) return true
            cur = cur.cause
            hops++
        }
        return false
    }

    private fun isDetachedFlutterJniMessage(text: String): Boolean {
        val low = text.lowercase()
        return low.contains("flutterjni is not attached to native") ||
            low.contains("cannot execute operation because flutterjni")
    }
}
