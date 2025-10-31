package com.ultralytics.yolo_example

import android.graphics.RectF
import com.google.ar.core.Frame
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.NotYetAvailableException
import java.nio.ByteOrder
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Representation of a detection after non-maximum suppression. */
data class Det(
    val label: String,
    val boxViewPx: RectF,
    val score: Float,
)

/** Navigation sectors in the camera frustum. */
enum class Sector { L, C, R }

/** Obstacle enriched with spatial context. */
data class Obstacle(
    val label: String,
    val sector: Sector,
    val distanceMeters: Float?,
    val isApproximate: Boolean = false,
) {
    fun isBlocking(safeDistance: Float): Boolean {
        val distance = distanceMeters
        return if (distance != null) {
            distance <= safeDistance
        } else {
            isApproximate
        }
    }
}

/** Determine the sector for a bounding box projected in view pixels. */
fun sectorOf(box: RectF, viewW: Int): Sector {
    if (viewW <= 0) return Sector.C
    val width = viewW.toFloat()
    val centerX = (box.left + box.right) / 2f
    val third = width / 3f
    return when {
        centerX < third -> Sector.L
        centerX > 2f * third -> Sector.R
        else -> Sector.C
    }
}

/**
 * Estimate the distance in meters for a detection by sampling the ARCore depth map.
 */
fun distanceMetersForBox(
    frame: Frame,
    det: Det,
    viewW: Int,
    viewH: Int,
    stride: Int = 4,
): Float? {
    if (viewW <= 0 || viewH <= 0) return null
    if (frame.camera.trackingState != TrackingState.TRACKING) return null

    val depthPlane = DepthImageCache.ensure(frame) ?: return null

    val rect = RectF(
        max(0f, det.boxViewPx.left),
        max(0f, det.boxViewPx.top),
        min(viewW.toFloat(), det.boxViewPx.right),
        min(viewH.toFloat(), det.boxViewPx.bottom),
    )
    if (rect.isEmpty) return null

    val samplingStride = if (stride <= 0) 1 else stride
    val samples = mutableListOf<Float>()

    val depthWidth = depthPlane.width
    val depthHeight = depthPlane.height
    val data = depthPlane.data

    var y = rect.top
    while (y <= rect.bottom) {
        var x = rect.left
        while (x <= rect.right) {
            val normalizedX = x / viewW.toFloat()
            val normalizedY = y / viewH.toFloat()
            val depthX = (normalizedX * depthWidth).roundToInt()
            val depthY = (normalizedY * depthHeight).roundToInt()
            if (depthX in 0 until depthWidth && depthY in 0 until depthHeight) {
                val index = depthY * depthWidth + depthX
                val depthMillimeters = data[index].toInt() and 0xFFFF
                if (depthMillimeters > 0) {
                    samples.add(depthMillimeters / 1000f)
                }
            }
            x += samplingStride.toFloat()
        }
        y += samplingStride.toFloat()
    }

    if (samples.isEmpty()) return null
    samples.sort()
    val middle = samples.size / 2
    return if (samples.size % 2 == 1) {
        samples[middle]
    } else {
        (samples[middle - 1] + samples[middle]) / 2f
    }
}

/** Decide the spoken instruction given the current obstacle map. */
fun decideInstruction(obsts: List<Obstacle>, safeM: Float = 1.2f): String {
    if (obsts.isEmpty()) return "Sigue derecho"

    val crosswalk = obsts.firstOrNull { it.label.equals("crosswalk", ignoreCase = true) }
    if (crosswalk != null) {
        return "Hay un paso de cebra al frente. Avanza para cruzar"
    }

    val center = obsts.filter { it.sector == Sector.C }
    val left = obsts.filter { it.sector == Sector.L }
    val right = obsts.filter { it.sector == Sector.R }

    val centerBlocked = center.any { it.isBlocking(safeM) }
    val leftBlocked = left.any { it.isBlocking(safeM) }
    val rightBlocked = right.any { it.isBlocking(safeM) }

    if (centerBlocked) {
        return when {
            !rightBlocked -> "Sigue por la derecha"
            !leftBlocked -> "Sigue por la izquierda"
            else -> "Alto, hay obstáculos alrededor"
        }
    }

    val caution = center.minByOrNull { it.distanceMeters ?: Float.MAX_VALUE }
    if (caution != null) {
        val distance = caution.distanceMeters
        return when {
            distance != null -> {
                val meters = String.format(Locale.getDefault(), "%.1f", distance)
                "Cuidado ${caution.label} al frente a $meters metros"
            }
            caution.isApproximate -> "Cuidado ${caution.label} al frente, muy cerca"
            else -> "Cuidado ${caution.label} al frente"
        }
    }

    return "Sigue derecho"
}

/** Clear cached depth data when pausing the AR session. */
fun resetDepthCache() {
    DepthImageCache.clear()
}

private data class DepthPlane(
    val width: Int,
    val height: Int,
    val data: ShortArray,
)

private object DepthImageCache {
    @Volatile
    private var timestamp: Long = -1L
    @Volatile
    private var width: Int = 0
    @Volatile
    private var height: Int = 0
    @Volatile
    private var data: ShortArray? = null

    @Synchronized
    fun ensure(frame: Frame): DepthPlane? {
        val currentTimestamp = frame.timestamp
        if (currentTimestamp == 0L) return null
        if (timestamp != currentTimestamp || data == null) {
            try {
                frame.acquireDepthImage16Bits().use { image ->
                    val plane = image.planes.firstOrNull() ?: return null
                    val buffer = plane.buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                    buffer.rewind()
                    val depthWidth = image.width
                    val depthHeight = image.height
                    val rowStride = plane.rowStride
                    val pixelStride = plane.pixelStride
                    val depthData = ShortArray(depthWidth * depthHeight)
                    for (y in 0 until depthHeight) {
                        for (x in 0 until depthWidth) {
                            val bufferIndex = y * rowStride + x * pixelStride
                            val depthMillimeters = buffer.getShort(bufferIndex).toInt() and 0xFFFF
                            depthData[y * depthWidth + x] = depthMillimeters.toShort()
                        }
                    }
                    timestamp = currentTimestamp
                    width = depthWidth
                    height = depthHeight
                    data = depthData
                }
            } catch (_: NotYetAvailableException) {
                return null
            } catch (_: IllegalStateException) {
                return null
            }
        }
        val depthData = data ?: return null
        return DepthPlane(width, height, depthData)
    }

    @Synchronized
    fun clear() {
        timestamp = -1L
        width = 0
        height = 0
        data = null
    }
}
