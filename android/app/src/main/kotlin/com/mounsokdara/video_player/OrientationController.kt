package com.mounsokdara.video_player

import android.app.Activity
import android.content.pm.ActivityInfo

/** Maps player rotation strings onto ActivityInfo constants. */
object OrientationController {
    fun apply(activity: Activity, mode: String) {
        activity.requestedOrientation = when (mode) {
            NativeConstants.Orient.LANDSCAPE -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            NativeConstants.Orient.PORTRAIT -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            NativeConstants.Orient.LANDSCAPE_NORMAL -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            NativeConstants.Orient.LANDSCAPE_REVERSE -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
            NativeConstants.Orient.PORTRAIT_NORMAL -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            NativeConstants.Orient.PORTRAIT_REVERSE -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
            NativeConstants.Orient.LOCKED -> ActivityInfo.SCREEN_ORIENTATION_LOCKED
            NativeConstants.Orient.USER -> ActivityInfo.SCREEN_ORIENTATION_USER
            NativeConstants.Orient.SENSOR, NativeConstants.Orient.AUTO -> ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
            NativeConstants.Orient.NONE, NativeConstants.Orient.UNSPECIFIED -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }
}
