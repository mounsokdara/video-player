package com.mounsokdara.video_player

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager

/**
 * Owns status + navigation bar appearance. Honor / Huawei 3-button nav
 * ignores deprecated systemUiVisibility on API 30+, so hide() must call
 * WindowInsetsController.hide(Type.systemBars()) AND keep the old flags.
 * Flutter AnnotatedRegion can re-show bars a frame later, so hide is
 * posted once more after layout.
 */
class SystemBarController(private val activity: Activity) {
    private var lastLightIcons = true
    private var lastContrast = true
    private var lastHide = false
    private var uiListenerAttached = false

    fun enableEdgeToEdge() {
        val window = activity.window
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                window.setDecorFitsSystemWindows(false)
            }
            if (Build.VERSION.SDK_INT >= 28) {
                window.attributes.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
            if (Build.VERSION.SDK_INT >= 29) {
                window.isNavigationBarContrastEnforced = true
                window.isStatusBarContrastEnforced = false
            }
            attachUiListener(window)
        } catch (_: Exception) {
        }
    }

    fun apply(lightIcons: Boolean, contrast: Boolean, hide: Boolean) {
        lastLightIcons = lightIcons
        lastContrast = contrast
        lastHide = hide
        activity.runOnUiThread {
            try {
                val window = activity.window
                attachUiListener(window)
                if (hide) {
                    hideBars(window)
                    window.decorView.post { if (lastHide) hideBars(window) }
                    window.decorView.postDelayed({ if (lastHide) hideBars(window) }, NativeConstants.HIDE_RETRY_MS)
                    window.decorView.postDelayed({ if (lastHide) hideBars(window) }, 400)
                    window.decorView.postDelayed({ if (lastHide) hideBars(window) }, 800)
                } else {
                    showBars(window, lightIcons, contrast)
                }
            } catch (_: Exception) {
            }
        }
    }

    fun reapply() {
        apply(lastLightIcons, lastContrast, lastHide)
    }

    @Suppress("DEPRECATION")
    private fun attachUiListener(window: Window) {
        if (uiListenerAttached) return
        uiListenerAttached = true
        window.decorView.setOnSystemUiVisibilityChangeListener { vis ->
            if (lastHide && vis and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION == 0) {
                window.decorView.post { if (lastHide) hideBars(window) }
            }
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.decorView.setOnApplyWindowInsetsListener { v, insets ->
                val bars = WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars()
                if (lastHide && insets.isVisible(bars)) {
                    v.post { if (lastHide) hideBars(window) }
                }
                v.onApplyWindowInsets(insets)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun hideBars(window: Window) {
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        if (Build.VERSION.SDK_INT >= 29) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            val controller = window.insetsController ?: window.decorView.windowInsetsController
            controller?.let {
                it.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars() or WindowInsets.Type.systemBars())
                it.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_FULLSCREEN
            )
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
    }

    @Suppress("DEPRECATION")
    private fun showBars(window: Window, lightIcons: Boolean, contrast: Boolean) {
        window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            val controller = window.insetsController ?: window.decorView.windowInsetsController
            controller?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars() or WindowInsets.Type.systemBars())
            val light = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            controller?.setSystemBarsAppearance(if (lightIcons) 0 else light, light)
        }
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            )
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= 29) {
            window.isNavigationBarContrastEnforced = contrast
            window.isStatusBarContrastEnforced = false
        }
    }
}
