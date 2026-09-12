package com.mounsokdara.video_player

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

class CrashReportActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val report = intent.getStringExtra(EXTRA_REPORT)
            ?: NativeCrashLog.readLast(this)
            ?: getString(R.string.crash_empty)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(getColor(R.color.crash_bg))
            setPadding(dp(20), dp(28), dp(20), dp(20))
        }
        val title = TextView(this).apply {
            text = getString(R.string.crash_title)
            setTextColor(getColor(R.color.crash_title))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        }
        val body = TextView(this).apply {
            text = report
            setTextColor(getColor(R.color.crash_body))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        val scroll = ScrollView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f
            )
            addView(body)
        }
        val copy = Button(this).apply {
            text = getString(R.string.crash_copy)
            setOnClickListener {
                val cm = getSystemService(ClipboardManager::class.java) ?: return@setOnClickListener
                cm.setPrimaryClip(
                    ClipData.newPlainText(getString(R.string.crash_clip_label), report)
                )
                if (Build.VERSION.SDK_INT < 33) {
                    Toast.makeText(
                        this@CrashReportActivity,
                        getString(R.string.crash_copied),
                        Toast.LENGTH_SHORT
                    ).show()
                }
            }
        }
        val close = Button(this).apply {
            text = getString(R.string.crash_close)
            setOnClickListener { finish() }
        }
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            addView(copy)
            addView(close)
        }
        root.addView(title)
        root.addView(scroll)
        root.addView(actions)
        setContentView(root)
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_REPORT = "report"
    }
}
