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

    fun installHook(context: Context, emit: (Map<String, Any?>) -> Unit) {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, e ->
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
            prev?.uncaughtException(Thread.currentThread(), e)
        }
    }
}
