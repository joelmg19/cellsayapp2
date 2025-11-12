package com.ultralytics.yolo_example

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale

/** Simple Text-to-Speech helper with a 1200ms rate limit. */
class TtsHelper(context: Context) : TextToSpeech.OnInitListener {
    private val handler = Handler(Looper.getMainLooper())
    private val tts = TextToSpeech(context.applicationContext, this)
    private var ready = false
    private var lastSpeakTimestamp = 0L
    private var pendingUtterance: PendingUtterance? = null

    private val delayedSpeak = Runnable {
        val utterance = pendingUtterance ?: return@Runnable
        pendingUtterance = null
        speakInternal(utterance.text, utterance.flushQueue)
    }

    private val progressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String) {
            Log.d(TAG, "TTS onStart id=$utteranceId")
        }

        override fun onDone(utteranceId: String) {
            Log.d(TAG, "TTS onDone id=$utteranceId")
        }

        override fun onError(utteranceId: String) {
            Log.e(TAG, "TTS onError id=$utteranceId")
        }

        override fun onError(utteranceId: String, errorCode: Int) {
            Log.e(TAG, "TTS onError id=$utteranceId code=$errorCode")
        }
    }

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            val locale = tts.voice?.locale ?: Locale.getDefault()
            tts.language = locale
            tts.setSpeechRate(1.0f)
            tts.setOnUtteranceProgressListener(progressListener)
            val pending = pendingUtterance
            if (pending != null && pending.text.isNotBlank()) {
                pendingUtterance = null
                speakInternal(pending.text, pending.flushQueue)
            }
        }
    }

    fun speak(text: String, flushQueue: Boolean = false) {
        if (text.isBlank()) return
        handler.post {
            if (!ready) {
                pendingUtterance = PendingUtterance(text, flushQueue)
                return@post
            }
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - lastSpeakTimestamp
            if (elapsed < RATE_LIMIT_MS) {
                pendingUtterance = PendingUtterance(text, flushQueue)
                handler.removeCallbacks(delayedSpeak)
                handler.postDelayed(delayedSpeak, RATE_LIMIT_MS - elapsed)
                return@post
            }
            speakInternal(text, flushQueue)
        }
    }

    private fun speakInternal(text: String, flushQueue: Boolean = false) {
        if (!ready) {
            pendingUtterance = PendingUtterance(text, flushQueue)
            return
        }
        lastSpeakTimestamp = SystemClock.elapsedRealtime()
        val queueMode = when {
            flushQueue && !tts.isSpeaking -> TextToSpeech.QUEUE_FLUSH
            tts.isSpeaking -> TextToSpeech.QUEUE_ADD
            else -> TextToSpeech.QUEUE_FLUSH
        }
        Log.d(TAG, "TTS speakInternal queueMode=$queueMode len=${text.length}")
        tts.speak(text, queueMode, null, text.hashCode().toString())
    }

    fun shutdown() {
        handler.removeCallbacksAndMessages(null)
        pendingUtterance = null
        tts.stop()
        tts.shutdown()
    }

    companion object {
        private const val RATE_LIMIT_MS = 1200L
        private const val TAG = "CellsayTTS"
    }

    private data class PendingUtterance(val text: String, val flushQueue: Boolean)
}
