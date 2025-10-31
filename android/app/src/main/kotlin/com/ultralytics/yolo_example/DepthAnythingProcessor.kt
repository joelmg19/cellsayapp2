package com.ultralytics.yolo_example

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.util.Log
import com.google.ar.core.Frame
import com.google.ar.core.exceptions.NotYetAvailableException
import io.flutter.FlutterInjector
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import kotlin.math.max
import kotlin.math.min
import org.tensorflow.lite.Interpreter

class DepthAnythingProcessor(private val context: Context) {
    companion object {
        private const val TAG = "DepthAnythingProcessor"
        private const val MODEL_ASSET_PATH = "assets/models/depth_anything.tflite"
    }

    @Volatile
    private var interpreter: Interpreter? = null
    @Volatile
    private var inputShape: IntArray = intArrayOf()
    @Volatile
    private var outputShape: IntArray = intArrayOf()
    @Volatile
    private var cachedTimestamp: Long = -1L
    @Volatile
    private var cachedResult: DepthAnythingResult? = null

    fun estimate(frame: Frame): DepthAnythingResult? {
        val timestamp = frame.timestamp
        val existing = cachedResult
        if (timestamp != 0L && timestamp == cachedTimestamp && existing != null) {
            return existing
        }

        val image = try {
            frame.acquireCameraImage()
        } catch (_: NotYetAvailableException) {
            return existing
        } catch (error: Exception) {
            Log.w(TAG, "Failed to acquire camera image: ${error.localizedMessage}")
            return existing
        }

        val result = try {
            estimate(image)
        } finally {
            image.close()
        }

        if (result != null && timestamp != 0L) {
            cachedTimestamp = timestamp
            cachedResult = result
        }
        return result
    }

    fun clear() {
        cachedTimestamp = -1L
        cachedResult = null
    }

    private fun estimate(image: Image): DepthAnythingResult? {
        val interpreter = ensureInterpreter() ?: return null
        val bitmap = image.toBitmap() ?: return null

        val inputHeight = inputShape.getOrNull(1) ?: return null
        val inputWidth = inputShape.getOrNull(2) ?: return null

        val scaled = Bitmap.createScaledBitmap(bitmap, inputWidth, inputHeight, true)
        val inputBuffer = ByteBuffer.allocateDirect(4 * inputWidth * inputHeight * 3)
            .order(ByteOrder.nativeOrder())
        for (y in 0 until inputHeight) {
            for (x in 0 until inputWidth) {
                val pixel = scaled.getPixel(x, y)
                val r = ((pixel shr 16) and 0xFF) / 255f
                val g = ((pixel shr 8) and 0xFF) / 255f
                val b = (pixel and 0xFF) / 255f
                inputBuffer.putFloat(r)
                inputBuffer.putFloat(g)
                inputBuffer.putFloat(b)
            }
        }
        inputBuffer.rewind()

        val outputHeight = outputShape.getOrNull(1) ?: return null
        val outputWidth = outputShape.getOrNull(2) ?: return null
        val outputBuffer = ByteBuffer.allocateDirect(4 * outputWidth * outputHeight)
            .order(ByteOrder.nativeOrder())
        interpreter.run(inputBuffer, outputBuffer)
        outputBuffer.rewind()
        val depthValues = FloatArray(outputWidth * outputHeight)
        outputBuffer.asFloatBuffer().get(depthValues)

        var minValue = Float.POSITIVE_INFINITY
        var maxValue = Float.NEGATIVE_INFINITY
        for (value in depthValues) {
            if (!value.isFinite()) continue
            if (value < minValue) minValue = value
            if (value > maxValue) maxValue = value
        }
        if (minValue == Float.POSITIVE_INFINITY || maxValue == Float.NEGATIVE_INFINITY) {
            minValue = 0f
            maxValue = 1f
        }

        return DepthAnythingResult(outputWidth, outputHeight, depthValues, minValue, maxValue)
    }

    private fun ensureInterpreter(): Interpreter? {
        var interpreter = this.interpreter
        if (interpreter != null) return interpreter
        synchronized(this) {
            interpreter = this.interpreter
            if (interpreter != null) return interpreter
            return try {
                val loader = FlutterInjector.instance().flutterLoader()
                val assetKey = loader.getLookupKeyForAsset(MODEL_ASSET_PATH)
                val assetManager = context.assets
                assetManager.openFd(assetKey).use { descriptor ->
                    FileInputStream(descriptor.fileDescriptor).use { inputStream ->
                        val startOffset = descriptor.startOffset
                        val declaredLength = descriptor.declaredLength
                        val channel = inputStream.channel
                        val mapped = channel.map(FileChannel.MapMode.READ_ONLY, startOffset, declaredLength)
                        val options = Interpreter.Options().apply { setNumThreads(2) }
                        val newInterpreter = Interpreter(mapped, options)
                        inputShape = newInterpreter.getInputTensor(0).shape()
                        outputShape = newInterpreter.getOutputTensor(0).shape()
                        this.interpreter = newInterpreter
                        newInterpreter
                    }
                }
            } catch (error: Exception) {
                Log.e(TAG, "Failed to load depth model", error)
                null
            }
        }
    }

    private fun Image.toBitmap(): Bitmap? {
        return try {
            if (format != ImageFormat.YUV_420_888) return null
            val yBuffer = planes[0].buffer
            val uBuffer = planes[1].buffer
            val vBuffer = planes[2].buffer
            val ySize = yBuffer.remaining()
            val uSize = uBuffer.remaining()
            val vSize = vBuffer.remaining()
            val nv21 = ByteArray(ySize + uSize + vSize)
            yBuffer.get(nv21, 0, ySize)
            vBuffer.get(nv21, ySize, vSize)
            uBuffer.get(nv21, ySize + vSize, uSize)
            val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
            val out = ByteArrayOutputStream()
            yuvImage.compressToJpeg(Rect(0, 0, width, height), 80, out)
            val bytes = out.toByteArray()
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (error: Exception) {
            Log.w(TAG, "Failed to convert image to bitmap: ${error.localizedMessage}")
            null
        }
    }
}

data class DepthAnythingResult(
    val width: Int,
    val height: Int,
    val values: FloatArray,
    val minValue: Float,
    val maxValue: Float,
) {
    fun metersForBox(det: Det, viewWidth: Int, viewHeight: Int, stride: Int = 4): Float? {
        if (width <= 0 || height <= 0 || viewWidth <= 0 || viewHeight <= 0) return null
        val normalizedLeft = max(0f, det.boxViewPx.left / viewWidth.toFloat())
        val normalizedTop = max(0f, det.boxViewPx.top / viewHeight.toFloat())
        val normalizedRight = min(1f, det.boxViewPx.right / viewWidth.toFloat())
        val normalizedBottom = min(1f, det.boxViewPx.bottom / viewHeight.toFloat())
        if (normalizedLeft >= normalizedRight || normalizedTop >= normalizedBottom) return null

        val samples = mutableListOf<Float>()
        val startX = (normalizedLeft * width).toInt().coerceIn(0, width - 1)
        val endX = (normalizedRight * width).toInt().coerceIn(startX, width - 1)
        val startY = (normalizedTop * height).toInt().coerceIn(0, height - 1)
        val endY = (normalizedBottom * height).toInt().coerceIn(startY, height - 1)
        val step = max(1, stride)
        for (y in startY..endY step step) {
            for (x in startX..endX step step) {
                val value = values[y * width + x]
                if (value.isFinite()) {
                    samples.add(value)
                }
            }
        }
        if (samples.isEmpty()) return null
        samples.sort()
        val median = samples[samples.size / 2]
        return approximateMeters(median)
    }

    private fun approximateMeters(depthValue: Float): Float {
        val clamped = depthValue.coerceIn(minValue, maxValue)
        val normalized = if (maxValue > minValue) {
            (clamped - minValue) / (maxValue - minValue)
        } else {
            0.5f
        }
        val inverted = 1f - normalized.coerceIn(0f, 1f)
        return MIN_DISTANCE + inverted * (MAX_DISTANCE - MIN_DISTANCE)
    }

    companion object {
        private const val MIN_DISTANCE = 0.5f
        private const val MAX_DISTANCE = 5.0f
    }
}
