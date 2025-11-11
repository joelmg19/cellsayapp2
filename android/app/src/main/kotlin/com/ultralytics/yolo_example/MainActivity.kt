package com.ultralytics.yolo_example

import android.content.Context
import android.graphics.RectF
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Bundle
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val voiceCommandManager: VoiceCommandManager by lazy { VoiceCommandManager(this) }
    private val ttsHelper: TtsHelper by lazy { TtsHelper(this) }
    private val overlayView: DetectionOverlayView by lazy { DetectionOverlayView(this) }

    private var lastInstruction: String? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        addContentView(
            overlayView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, VOICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> voiceCommandManager.initialize(result)
                "start" -> {
                    val locale = call.argument<String>("locale")
                    val listenFor = call.argument<Int>("listenFor")?.toLong() ?: DEFAULT_LISTEN_FOR
                    val pauseFor = call.argument<Int>("pauseFor")?.toLong() ?: DEFAULT_PAUSE_FOR
                    result.success(voiceCommandManager.startListening(locale, listenFor, pauseFor))
                }
                "stop" -> {
                    voiceCommandManager.stopListening()
                    result.success(null)
                }
                "cancel" -> {
                    voiceCommandManager.cancelListening()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, NAVIGATION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "processDetections" -> handleNavigationCall(call, result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, TTS_ROUTING_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "configureForSpeaker" -> {
                    audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager

                    val attrs = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()

                    focusRequest = AudioFocusRequest.Builder(
                        AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                    )
                        .setAudioAttributes(attrs)
                        .setOnAudioFocusChangeListener { }
                        .build()

                    val manager = audioManager
                    val request = focusRequest
                    if (manager != null && request != null) {
                        manager.mode = AudioManager.MODE_NORMAL
                        manager.isSpeakerphoneOn = true
                        manager.requestAudioFocus(request)
                    }

                    result.success(true)
                }

                "restoreRouting" -> {
                    val manager = audioManager
                    val request = focusRequest
                    if (manager != null && request != null) {
                        try {
                            manager.abandonAudioFocusRequest(request)
                        } catch (_: Throwable) {
                        }
                    }
                    focusRequest = null
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, VOICE_EVENTS_CHANNEL).setStreamHandler(voiceCommandManager)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voiceCommandManager.handlePermissionResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        overlayView.clear()
        voiceCommandManager.dispose()
        ttsHelper.shutdown()
        super.onDestroy()
    }

    private fun handleNavigationCall(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        if (arguments == null) {
            result.error("ARGUMENTS", "Se requieren argumentos en formato mapa", null)
            return
        }

        val viewWidth = (arguments["viewWidth"] as? Number)?.toInt()
        val viewHeight = (arguments["viewHeight"] as? Number)?.toInt()
        if (viewWidth == null || viewHeight == null || viewWidth <= 0 || viewHeight <= 0) {
            result.error("ARGUMENTS", "viewWidth y viewHeight deben ser válidos", null)
            return
        }

        val rawDetections = arguments["detections"] as? List<*> ?: emptyList<Any>()
        val detections = parseDetections(rawDetections, viewWidth, viewHeight)
        if (detections.isEmpty()) {
            overlayView.clear()
        } else {
            overlayView.updateDetections(detections)
        }

        val obstacles = detections.map { det ->
            val approximate = approximateClose(det, viewWidth, viewHeight)
            Obstacle(det.label, sectorOf(det.boxViewPx, viewWidth), null, approximate)
        }

        val instruction = decideInstruction(obstacles)
        if (instruction.isNotBlank() && instruction != lastInstruction) {
            lastInstruction = instruction
            ttsHelper.speak(instruction)
        }

        result.success(
            mapOf(
                "instruction" to instruction,
                "obstacles" to obstacles.map {
                    mapOf(
                        "label" to it.label,
                        "sector" to it.sector.name,
                        "distanceMeters" to it.distanceMeters?.toDouble(),
                        "approximate" to it.isApproximate,
                    )
                },
                "usedDepth" to false,
            ),
        )
    }

    private fun parseDetections(raw: List<*>, viewWidth: Int, viewHeight: Int): List<Det> {
        if (raw.isEmpty()) return emptyList()
        val width = viewWidth.toFloat()
        val height = viewHeight.toFloat()
        return raw.mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            val label = (map["label"] as? String)?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val score = (map["score"] as? Number)?.toFloat() ?: 0f

            val left = (map["left"] as? Number)?.toFloat()
            val top = (map["top"] as? Number)?.toFloat()
            val right = (map["right"] as? Number)?.toFloat()
            val bottom = (map["bottom"] as? Number)?.toFloat()

            val rect = if (left != null && top != null && right != null && bottom != null) {
                RectF(left, top, right, bottom).also { it.sort() }
            } else {
                val normalized = map["normalized"] as? Map<*, *>
                if (normalized != null) {
                    val nLeft = (normalized["left"] as? Number)?.toFloat()
                    val nTop = (normalized["top"] as? Number)?.toFloat()
                    val nRight = (normalized["right"] as? Number)?.toFloat()
                    val nBottom = (normalized["bottom"] as? Number)?.toFloat()
                    if (nLeft != null && nTop != null && nRight != null && nBottom != null) {
                        RectF(
                            nLeft * width,
                            nTop * height,
                            nRight * width,
                            nBottom * height,
                        ).also { it.sort() }
                    } else {
                        null
                    }
                } else {
                    null
                }
            }

            if (rect == null) return@mapNotNull null
            val maxLeft = (width - 1f).coerceAtLeast(0f)
            val maxTop = (height - 1f).coerceAtLeast(0f)
            val leftClamped = rect.left.coerceIn(0f, maxLeft)
            val topClamped = rect.top.coerceIn(0f, maxTop)
            val rightClamped = rect.right.coerceIn(leftClamped + 1f, width)
            val bottomClamped = rect.bottom.coerceIn(topClamped + 1f, height)

            Det(label, RectF(leftClamped, topClamped, rightClamped, bottomClamped), score)
        }
    }

    private fun approximateClose(det: Det, viewWidth: Int, viewHeight: Int): Boolean {
        val area = det.boxViewPx.width() * det.boxViewPx.height()
        val totalArea = viewWidth.toFloat() * viewHeight.toFloat()
        if (totalArea <= 0f) return false
        val ratio = area / totalArea
        if (ratio >= 0.15f) return true
        val bottom = det.boxViewPx.bottom
        return ratio >= 0.08f && bottom > viewHeight * 0.75f
    }

    companion object {
        private const val DEFAULT_LISTEN_FOR = 8000L
        private const val DEFAULT_PAUSE_FOR = 3000L
        private const val VOICE_CHANNEL = "voice_commands/methods"
        private const val VOICE_EVENTS_CHANNEL = "voice_commands/events"
        private const val NAVIGATION_CHANNEL = "navigation/depth"
        private const val TTS_ROUTING_CHANNEL = "tts_audio_routing"
    }
}
