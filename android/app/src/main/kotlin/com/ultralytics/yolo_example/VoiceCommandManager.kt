
package com.ultralytics.yolo_example

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class VoiceCommandManager(private val activity: Activity) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var speechRecognizer: SpeechRecognizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var listening = false
    private var stopRunnable: Runnable? = null
    private var pendingInitializeResult: MethodChannel.Result? = null

    fun initialize(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.success(
                mapOf(
                    "available" to false,
                    "error" to "El reconocimiento de voz no está disponible en este dispositivo.",
                ),
            )
            return
        }

        if (!hasAudioPermission()) {
            pendingInitializeResult = result
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                PERMISSION_REQUEST_CODE,
            )
            return
        }

        result.success(createInitializationPayload())
    }

    fun handlePermissionResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != PERMISSION_REQUEST_CODE) {
            return
        }

        val result = pendingInitializeResult
        pendingInitializeResult = null
        if (result == null) {
            return
        }

        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            result.success(
                mapOf(
                    "available" to false,
                    "error" to "Permiso de micrófono denegado.",
                ),
            )
            return
        }

        result.success(createInitializationPayload())
    }

    fun startListening(localeTag: String?, listenForMillis: Long, pauseForMillis: Long): Boolean {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            sendError("El reconocimiento de voz no está disponible en este dispositivo.")
            return false
        }

        if (!hasAudioPermission()) {
            sendError("Se requiere el permiso de micrófono para escuchar comandos.")
            return false
        }

        if (speechRecognizer == null) {
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(activity).apply {
                setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        sendStatus(true)
                    }

                    override fun onBeginningOfSpeech() {
                        sendStatus(true)
                    }

                    override fun onRmsChanged(rmsdB: Float) {}

                    override fun onBufferReceived(buffer: ByteArray?) {}

                    override fun onEndOfSpeech() {}

                    override fun onError(error: Int) {
                        cancelStopTimer()
                        listening = false
                        sendStatus(false)
                        sendError(mapError(error))
                    }

                    override fun onResults(results: Bundle) {
                        cancelStopTimer()
                        listening = false
                        val matches = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        val text = matches?.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
                        if (text.isEmpty()) {
                            sendError("No se escuchó ningún comando.")
                        } else {
                            sendResult(text)
                        }
                        sendStatus(false)
                    }

                    override fun onPartialResults(partialResults: Bundle) {}

                    override fun onEvent(eventType: Int, params: Bundle?) {}
                })
            }
        }

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            localeTag?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, listenForMillis)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, pauseForMillis)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, pauseForMillis)
        }

        cancelStopTimer()
        listening = true
        sendStatus(true)
        mainHandler.post {
            speechRecognizer?.startListening(intent)
        }
        scheduleStopTimer(listenForMillis)
        return true
    }

    fun stopListening() {
        cancelStopTimer()
        listening = false
        mainHandler.post {
            speechRecognizer?.stopListening()
        }
        sendStatus(false)
    }

    fun cancelListening() {
        cancelStopTimer()
        listening = false
        mainHandler.post {
            speechRecognizer?.cancel()
        }
        sendStatus(false)
    }

    fun dispose() {
        cancelStopTimer()
        speechRecognizer?.destroy()
        speechRecognizer = null
        eventSink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun createInitializationPayload(): Map<String, Any?> {
        val locales = getAvailableLocales().map { locale ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                locale.toLanguageTag()
            } else {
                locale.toString()
            }
        }
        val systemLocale = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            Locale.getDefault().toLanguageTag()
        } else {
            Locale.getDefault().toString()
        }
        return mapOf(
            "available" to true,
            "systemLocale" to systemLocale,
            "locales" to locales,
        )
    }

    private fun scheduleStopTimer(durationMillis: Long) {
        if (durationMillis <= 0L) {
            return
        }

        stopRunnable = Runnable {
            if (listening) {
                sendEvent(mapOf("type" to "timeout"))
            }
            speechRecognizer?.stopListening()
        }.also { runnable ->
            mainHandler.postDelayed(runnable, durationMillis)
        }
    }

    private fun cancelStopTimer() {
        stopRunnable?.let { mainHandler.removeCallbacks(it) }
        stopRunnable = null
    }

    private fun hasAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun getAvailableLocales(): Set<Locale> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                val method = SpeechRecognizer::class.java.getMethod("getAvailableLanguages")
                val languages = method.invoke(null) as? Set<*>
                if (languages != null) {
                    val locales = mutableSetOf<Locale>()
                    for (entry in languages) {
                        val locale = when (entry) {
                            is Locale -> entry
                            is String -> try {
                                Locale.forLanguageTag(entry)
                            } catch (_: Throwable) {
                                null
                            }
                            else -> null
                        }
                        if (locale != null) {
                            locales.add(locale)
                        }
                    }
                    if (locales.isNotEmpty()) {
                        return locales
                    }
                }
            } catch (_: Throwable) {
                // If reflection fails we will fall back to the default locale below.
            }
        }
        return setOf(Locale.getDefault())
    }

    private fun mapError(errorCode: Int): String {
        return when (errorCode) {
            SpeechRecognizer.ERROR_AUDIO -> "Error de audio durante la captura."
            SpeechRecognizer.ERROR_CLIENT -> "Error del cliente de reconocimiento."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Permisos insuficientes para acceder al micrófono."
            SpeechRecognizer.ERROR_NETWORK -> "Error de red al procesar el comando."
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Tiempo de espera excedido en la red."
            SpeechRecognizer.ERROR_NO_MATCH -> "No se encontró coincidencia para el comando."
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "El reconocedor está ocupado."
            SpeechRecognizer.ERROR_SERVER -> "Error del servicio de reconocimiento."
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No se detectó voz."
            else -> "Error desconocido en el reconocimiento de voz."
        }
    }

    private fun sendStatus(isListening: Boolean) {
        if (!listening && isListening) {
            listening = true
        } else if (!isListening) {
            listening = false
        }
        sendEvent(
            mapOf(
                "type" to "status",
                "listening" to isListening,
            ),
        )
    }

    private fun sendResult(text: String) {
        sendEvent(
            mapOf(
                "type" to "result",
                "text" to text,
            ),
        )
    }

    private fun sendError(message: String) {
        sendEvent(
            mapOf(
                "type" to "error",
                "message" to message,
            ),
        )
    }

    private fun sendEvent(event: Map<String, Any?>) {
        val sink = eventSink ?: return
        mainHandler.post {
            sink.success(event)
        }
    }

    companion object {
        private const val PERMISSION_REQUEST_CODE = 0x5643
    }
}
