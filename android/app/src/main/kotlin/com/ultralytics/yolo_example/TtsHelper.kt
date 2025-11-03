package com.ultralytics.yolo_example

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import java.util.Locale

/** Simple Text-to-Speech helper with a 1200ms rate limit. */
class TtsHelper(context: Context) : TextToSpeech.OnInitListener {
    private val handler = Handler(Looper.getMainLooper())
    private val tts = TextToSpeech(context.applicationContext, this)
    private var ready = false
    private var lastSpeakTimestamp = 0L
    private var pendingUtterance: String? = null

    private val delayedSpeak = Runnable {
        val utterance = pendingUtterance ?: return@Runnable
        pendingUtterance = null
        speakInternal(utterance)
    }

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            val locale = tts.voice?.locale ?: Locale.getDefault()
            tts.language = locale
            tts.setSpeechRate(1.0f)
            val pending = pendingUtterance
            if (!pending.isNullOrBlank()) {
                pendingUtterance = null
                speakInternal(pending)
            }
        }
    }

    fun speak(text: String) {
        if (text.isBlank()) return
        handler.post {
            if (!ready) {
                pendingUtterance = text
                return@post
            }
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - lastSpeakTimestamp
            if (elapsed < RATE_LIMIT_MS) {
                pendingUtterance = text
                handler.removeCallbacks(delayedSpeak)
                handler.postDelayed(delayedSpeak, RATE_LIMIT_MS - elapsed)
                return@post
            }
            speakInternal(text)
        }
    }

    private fun speakInternal(text: String) {
        if (!ready) {
            pendingUtterance = text
            return
        }
        lastSpeakTimestamp = SystemClock.elapsedRealtime()
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, text.hashCode().toString())
    }

    fun shutdown() {
        handler.removeCallbacksAndMessages(null)
        pendingUtterance = null
        tts.stop()
        tts.shutdown()
    }

    companion object {
        private const val RATE_LIMIT_MS = 1200L
    }
}
