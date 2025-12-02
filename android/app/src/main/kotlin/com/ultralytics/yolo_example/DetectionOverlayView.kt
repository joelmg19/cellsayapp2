package com.ultralytics.yolo_example

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import kotlin.math.max

/** Simple overlay to render post-NMS detections on top of the Flutter UI. */
class DetectionOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(200, 64, 181, 255)
        style = Paint.Style.STROKE
        strokeWidth = resources.displayMetrics.density * 2f
    }

    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 14f * resources.displayMetrics.scaledDensity
    }

    private val labelBackgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(180, 0, 0, 0)
        style = Paint.Style.FILL
    }

    private var detections: List<Det> = emptyList()

    init {
        setBackgroundColor(Color.TRANSPARENT)
        elevation = resources.displayMetrics.density * 8f
    }

    fun updateDetections(items: List<Det>) {
        detections = items
        postInvalidateOnAnimation()
    }

    fun clear() {
        if (detections.isNotEmpty()) {
            detections = emptyList()
            postInvalidateOnAnimation()
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        for (det in detections) {
            val rect = det.boxViewPx
            canvas.drawRect(rect, boxPaint)
            drawLabel(canvas, rect, det.label)
        }
    }

    private fun drawLabel(canvas: Canvas, rect: RectF, label: String) {
        if (label.isEmpty()) return
        val padding = 4f * resources.displayMetrics.density
        val textHeight = labelPaint.textSize
        val textWidth = labelPaint.measureText(label)
        val left = rect.left
        val top = max(0f, rect.top - textHeight - padding * 2)
        val background = RectF(
            left,
            top,
            left + textWidth + padding * 2,
            top + textHeight + padding * 2,
        )
        canvas.drawRoundRect(background, padding, padding, labelBackgroundPaint)
        canvas.drawText(label, background.left + padding, background.bottom - padding, labelPaint)
    }
}
