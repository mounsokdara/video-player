package com.mounsokdara.video_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.media.app.NotificationCompat.MediaStyle

class PlaybackService : Service() {
    private var session: MediaSessionCompat? = null
    private var title: String = "Playing"
    private var artist: String = "Video Player"
    private var playing: Boolean = true
    private var positionMs: Int = 0
    private var durationMs: Int = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW)
            )
        }
        session = MediaSessionCompat(this, "video_player").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    MainActivity.emitMedia("play")
                    playing = true
                    notifyNow()
                }

                override fun onPause() {
                    MainActivity.emitMedia("pause")
                    playing = false
                    notifyNow()
                }

                override fun onSkipToNext() {
                    MainActivity.emitMedia("next")
                }

                override fun onSkipToPrevious() {
                    MainActivity.emitMedia("prev")
                }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> {
                MainActivity.emitMedia("play")
                playing = true
            }
            ACTION_PAUSE -> {
                MainActivity.emitMedia("pause")
                playing = false
            }
            ACTION_NEXT -> MainActivity.emitMedia("next")
            ACTION_PREV -> MainActivity.emitMedia("prev")
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                intent?.getStringExtra("title")?.let { title = it }
                intent?.getStringExtra("artist")?.let { artist = it }
                playing = intent?.getBooleanExtra("playing", playing) ?: playing
                positionMs = intent?.getIntExtra("positionMs", positionMs) ?: positionMs
                durationMs = intent?.getIntExtra("durationMs", durationMs) ?: durationMs
            }
        }
        notifyNow()
        return START_STICKY
    }

    private fun notifyNow() {
        session?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackStateCompat.ACTION_STOP
                )
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    positionMs.toLong(),
                    1f
                )
                .build()
        )
        val launch = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        fun action(id: Int, icon: Int, label: String, action: String): NotificationCompat.Action {
            val pi = PendingIntent.getService(
                this, id, Intent(this, PlaybackService::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            return NotificationCompat.Action(icon, label, pi)
        }
        val playPause = if (playing)
            action(1, android.R.drawable.ic_media_pause, "Pause", ACTION_PAUSE)
        else
            action(1, android.R.drawable.ic_media_play, "Play", ACTION_PLAY)
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle(title)
            .setContentText(if (playing) artist else "Paused")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(launch)
            .setOngoing(playing)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(action(2, android.R.drawable.ic_media_previous, "Previous", ACTION_PREV))
            .addAction(playPause)
            .addAction(action(3, android.R.drawable.ic_media_next, "Next", ACTION_NEXT))
            .setStyle(
                MediaStyle()
                    .setMediaSession(session?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .build()
        ServiceCompat.startForeground(
            this,
            42,
            notification,
            if (Build.VERSION.SDK_INT >= 29)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            else 0
        )
    }

    override fun onDestroy() {
        session?.release()
        session = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "playback"
        const val ACTION_START = "app.videoplayer.START"
        const val ACTION_UPDATE = "app.videoplayer.UPDATE"
        const val ACTION_PLAY = "app.videoplayer.PLAY"
        const val ACTION_PAUSE = "app.videoplayer.PAUSE"
        const val ACTION_NEXT = "app.videoplayer.NEXT"
        const val ACTION_PREV = "app.videoplayer.PREV"
        const val ACTION_STOP = "app.videoplayer.STOP"
    }
}
