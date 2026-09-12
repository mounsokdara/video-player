package com.mounsokdara.video_player

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

class AboutActivity : Activity() {
    private var taps = 0
    private var lastTap = 0L
    private lateinit var developerBox: LinearLayout
    private lateinit var console: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val night = (resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
            android.content.res.Configuration.UI_MODE_NIGHT_YES
        val bg = Color.parseColor(if (night) "#121212" else "#F7F7F4")
        val fg = Color.parseColor(if (night) "#F2F2F2" else "#1A1C1E")
        val muted = Color.parseColor(if (night) "#B0B0B0" else "#5C5F64")

        val info = try {
            if (Build.VERSION.SDK_INT >= 33)
                packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
            else
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
        } catch (_: Exception) {
            null
        }
        val versionName = info?.versionName ?: "1.0.0"
        val versionCode = if (Build.VERSION.SDK_INT >= 28) info?.longVersionCode ?: 1 else {
            @Suppress("DEPRECATION")
            info?.versionCode?.toLong() ?: 1
        }
        val versionLabel = "$versionName ($versionCode) · 1.0.0_BETA"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(bg)
            setPadding(dp(20), dp(28), dp(20), dp(20))
        }

        val icon = ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            layoutParams = LinearLayout.LayoutParams(dp(72), dp(72)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(12)
            }
        }
        val title = label("Video Player", fg, 22f, true)
        val blurb = label("Local-only Android player. Material 3.", muted, 14f, false)
        val created = row("Created by", "Moun Sokdara", fg, muted)
        val version = row("Build version", versionLabel, fg, muted).apply {
            isClickable = true
            setOnClickListener { onVersionTap() }
        }
        val licensesTitle = label("Open source licenses", fg, 16f, true).apply {
            setPadding(0, dp(18), 0, dp(6))
        }
        val licenses = label(LICENSES, muted, 13f, false).apply {
            setTextIsSelectable(true)
        }

        developerBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = if (DeveloperLog.developerEnabled(this@AboutActivity)) View.VISIBLE else View.GONE
            setPadding(0, dp(16), 0, 0)
        }
        val devHead = label("Developer options", fg, 16f, true)
        val debugRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        val debugLabel = label("Log debug", fg, 15f, false).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val debugSwitch = Switch(this).apply {
            isChecked = DeveloperLog.debugEnabled(this@AboutActivity)
            setOnCheckedChangeListener { _, on ->
                DeveloperLog.setDebugEnabled(this@AboutActivity, on)
                DeveloperLog.append(this@AboutActivity, "debugLog=$on")
                refreshConsole()
            }
        }
        debugRow.addView(debugLabel)
        debugRow.addView(debugSwitch)
        val consoleHead = label("Console", fg, 15f, true).apply {
            setPadding(0, dp(8), 0, dp(6))
        }
        console = TextView(this).apply {
            setTextColor(muted)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        val copy = Button(this).apply {
            text = "Copy"
            setOnClickListener {
                val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("console", console.text))
                Toast.makeText(this@AboutActivity, "Copied", Toast.LENGTH_SHORT).show()
            }
        }
        val clear = Button(this).apply {
            text = "Clear"
            setOnClickListener {
                DeveloperLog.append(this@AboutActivity, "__clear__")
                refreshConsole()
            }
        }
        actions.addView(copy)
        actions.addView(clear)
        developerBox.addView(devHead)
        developerBox.addView(debugRow)
        developerBox.addView(consoleHead)
        developerBox.addView(console)
        developerBox.addView(actions)

        val close = Button(this).apply {
            text = "Close"
            setOnClickListener { finish() }
        }

        root.addView(icon)
        root.addView(title)
        root.addView(blurb)
        root.addView(created)
        root.addView(version)
        root.addView(licensesTitle)
        root.addView(licenses)
        root.addView(developerBox)
        root.addView(close)

        val scroll = ScrollView(this).apply {
            setBackgroundColor(bg)
            addView(root)
        }
        setContentView(scroll)
        refreshConsole()
    }

    private fun onVersionTap() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastTap > 2000) taps = 0
        lastTap = now
        taps += 1
        if (DeveloperLog.developerEnabled(this)) {
            Toast.makeText(this, "Developer options are on", Toast.LENGTH_SHORT).show()
            return
        }
        val left = 10 - taps
        if (left in 1..3) {
            Toast.makeText(this, "$left tap${if (left == 1) "" else "s"} away from developer options", Toast.LENGTH_SHORT).show()
        }
        if (taps >= 10) {
            taps = 0
            DeveloperLog.setDeveloperEnabled(this, true)
            developerBox.visibility = View.VISIBLE
            refreshConsole()
            Toast.makeText(this, "Developer options enabled", Toast.LENGTH_SHORT).show()
        }
    }

    private fun refreshConsole() {
        val buf = StringBuilder()
        buf.append("=== debug ===\n")
        val debug = DeveloperLog.read(this)
        buf.append(if (debug.isBlank()) "No debug lines yet.\n" else debug)
        buf.append("\n=== crash ===\n")
        buf.append(NativeCrashLog.peek(this))
        console.text = buf.toString()
    }

    private fun label(text: String, color: Int, sp: Float, bold: Boolean) = TextView(this).apply {
        this.text = text
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(0, dp(4), 0, dp(4))
    }

    private fun row(k: String, v: String, fg: Int, muted: Int): LinearLayout {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(10), 0, dp(10))
        }
        box.addView(label(k, fg, 15f, true))
        box.addView(label(v, muted, 14f, false))
        return box
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val LICENSES = "" +
            "Flutter engine - BSD 3-Clause - Google LLC\n" +
            "Dart - BSD 3-Clause - Google LLC\n" +
            "video_player - BSD 3-Clause\n" +
            "Media3 / ExoPlayer - Apache 2.0 - Google LLC\n" +
            "AndroidX - Apache 2.0 - Google LLC\n" +
            "Kotlin - Apache 2.0 - JetBrains\n" +
            "Material Components - Apache 2.0\n" +
            "battery_plus, permission_handler, shared_preferences, wakelock_plus, package_info_plus - BSD / Apache / MIT as published by each project."
    }
}
