package com.ultralytics.yolo_example

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.RectF
import android.os.Bundle
import android.widget.FrameLayout
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Session
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.UnavailableApkTooOldException
import com.google.ar.core.exceptions.UnavailableArcoreNotInstalledException
import com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException
import com.google.ar.core.exceptions.UnavailableSdkTooOldException
import com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val voiceCommandManager: VoiceCommandManager by lazy { VoiceCommandManager(this) }
    private val ttsHelper: TtsHelper by lazy { TtsHelper(this) }
    private val overlayView: DetectionOverlayView by lazy { DetectionOverlayView(this) }
    private val depthProcessor: DepthAnythingProcessor by lazy { DepthAnythingProcessor(this) }

    private var session: Session? = null
    private var sessionResumed = false
    private var installRequested = false
    private var depthSupported = false
    private var lastInstruction: String? = null

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

        EventChannel(messenger, VOICE_EVENTS_CHANNEL)
            .setStreamHandler(voiceCommandManager)
    }

    override fun onResume() {
        super.onResume()
        if (hasCameraPermission()) {
            resumeSessionIfNeeded()
        } else {
            requestCameraPermission()
        }
    }

    override fun onPause() {
        super.onPause()
        overlayView.clear()
        resetDepthCache()
        depthProcessor.clear()
        session?.let {
            try {
                it.pause()
            } catch (_: Exception) {
            }
        }
        sessionResumed = false
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                resumeSessionIfNeeded()
            } else {
                showToast("Se requiere la cámara para la navegación por profundidad.")
            }
        }
        voiceCommandManager.handlePermissionResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        overlayView.clear()
        voiceCommandManager.dispose()
        ttsHelper.shutdown()
        session?.close()
        session = null
        resetDepthCache()
        depthProcessor.clear()
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

        resumeSessionIfNeeded()
        val frame = obtainFrame()
        val depthFromArCore = depthSupported && frame != null
        val depthMap = frame?.let { depthProcessor.estimate(it) }

        val obstacles = detections.map { det ->
            val distanceFromAr = frame?.let { distanceMetersForBox(it, det, viewWidth, viewHeight) }
            val distanceFromModel = if (distanceFromAr == null) {
                depthMap?.metersForBox(det, viewWidth, viewHeight)
            } else {
                null
            }
            val distance = distanceFromAr ?: distanceFromModel
            val approximate = if (distance != null) {
                false
            } else {
                approximateClose(det, viewWidth, viewHeight)
            }
            Obstacle(det.label, sectorOf(det.boxViewPx, viewWidth), distance, approximate)
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
                "usedDepth" to (depthFromArCore || depthMap != null),
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

    private fun obtainFrame(): Frame? {
        if (!depthSupported || !sessionResumed) return null
        val currentSession = session ?: return null
        return try {
            currentSession.update()
        } catch (error: CameraNotAvailableException) {
            showToast("La cámara no está disponible para ARCore.")
            sessionResumed = false
            session = null
            resetDepthCache()
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun resumeSessionIfNeeded() {
        val currentSession = ensureSession() ?: return
        if (sessionResumed) return
        try {
            currentSession.resume()
            sessionResumed = true
        } catch (error: CameraNotAvailableException) {
            showToast("La cámara no está disponible para ARCore.")
            session = null
            sessionResumed = false
        }
    }

    private fun ensureSession(): Session? {
        if (!hasCameraPermission()) return null
        session?.let { return it }

        val activity = this
        try {
            when (ArCoreApk.getInstance().requestInstall(activity, !installRequested)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {
                    installRequested = true
                    return null
                }
                ArCoreApk.InstallStatus.INSTALLED -> installRequested = false
            }
        } catch (error: UnavailableUserDeclinedInstallationException) {
            showToast("Se requiere Google Play Services for AR.")
            return null
        } catch (error: UnavailableArcoreNotInstalledException) {
            showToast("Instala Google Play Services for AR para continuar.")
            return null
        }

        return try {
            val newSession = Session(activity)
            val config = Config(newSession)
            depthSupported = newSession.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
            if (!depthSupported) {
                showToast("Profundidad automática no soportada, usando estimación aproximada.")
            }
            config.depthMode = if (depthSupported) {
                Config.DepthMode.AUTOMATIC
            } else {
                Config.DepthMode.DISABLED
            }
            newSession.configure(config)
            session = newSession
            newSession
        } catch (error: UnavailableDeviceNotCompatibleException) {
            showToast("Este dispositivo no es compatible con ARCore.")
            null
        } catch (error: UnavailableApkTooOldException) {
            showToast("Actualiza Google Play Services for AR.")
            null
        } catch (error: UnavailableSdkTooOldException) {
            showToast("Actualiza la aplicación para usar ARCore.")
            null
        } catch (error: Exception) {
            showToast("No se pudo crear la sesión de AR: ${error.localizedMessage}")
            null
        }
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestCameraPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.CAMERA),
            CAMERA_PERMISSION_CODE,
        )
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

    private fun showToast(message: String) {
        runOnUiThread {
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    companion object {
        private const val DEFAULT_LISTEN_FOR = 8000L
        private const val DEFAULT_PAUSE_FOR = 3000L
        private const val CAMERA_PERMISSION_CODE = 0xAC2
        private const val VOICE_CHANNEL = "voice_commands/methods"
        private const val VOICE_EVENTS_CHANNEL = "voice_commands/events"
        private const val NAVIGATION_CHANNEL = "navigation/depth"
    }
}
