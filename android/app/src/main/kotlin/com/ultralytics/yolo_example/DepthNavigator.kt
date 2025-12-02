package com.ultralytics.yolo_example

import android.graphics.RectF
import java.util.Locale

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
