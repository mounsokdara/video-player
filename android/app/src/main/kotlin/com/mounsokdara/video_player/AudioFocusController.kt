package com.mounsokdara.video_player

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler

/**
 * Single AUDIOFOCUS_GAIN owner. Duck (never pause) on CAN_DUCK.
 * Transient loss still pauses so a phone call wins.
 */
class AudioFocusController(
    context: Context,
    private val mainHandler: Handler,
    private val emit: (String) -> Unit,
    private val breadcrumb: (String) -> Unit,
    private var playing: Boolean,
    private val onPlaying: (Boolean) -> Unit
) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false
    private var resumeOnFocusGain = false
    private var ducked = false

    fun setPlaying(on: Boolean) {
        playing = on
    }

    fun release() {
        abandon()
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        mainHandler.post {
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS -> {
                    hasAudioFocus = false
                    resumeOnFocusGain = false
                    if (ducked) {
                        ducked = false
                        emit("unduck")
                    }
                    playing = false
                    onPlaying(false)
                    emit("pause")
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    resumeOnFocusGain = playing
                    hasAudioFocus = false
                    if (ducked) {
                        ducked = false
                        emit("unduck")
                    }
                    playing = false
                    onPlaying(false)
                    emit("pause")
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    if (!ducked) {
                        ducked = true
                        emit("duck")
                    }
                }
                AudioManager.AUDIOFOCUS_GAIN -> {
                    hasAudioFocus = true
                    if (ducked) {
                        ducked = false
                        emit("unduck")
                    }
                    if (resumeOnFocusGain) {
                        resumeOnFocusGain = false
                        playing = true
                        onPlaying(true)
                        emit("play")
                    }
                }
            }
        }
    }

    fun request() {
        if (hasAudioFocus) return
        try {
            val granted = if (Build.VERSION.SDK_INT >= 26) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build()
                    )
                    .setOnAudioFocusChangeListener(focusListener, mainHandler)
                    .setAcceptsDelayedFocusGain(false)
                    .setWillPauseWhenDucked(false)
                    .build()
                focusRequest = req
                audioManager.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    focusListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
            hasAudioFocus = granted
            if (granted) {
                playing = true
                onPlaying(true)
            }
            breadcrumb("audio focus granted=$granted")
        } catch (t: Throwable) {
            breadcrumb("audio focus: ${t.message}")
        }
    }

    fun abandon() {
        hasAudioFocus = false
        resumeOnFocusGain = false
        ducked = false
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusListener)
            }
        } catch (_: Throwable) {
        }
        focusRequest = null
    }
}
