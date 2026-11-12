package com.nosmai.zoom_live

import android.content.Context
import android.opengl.GLES20
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import com.nosmai.effect.api.NosmaiSDK
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import us.zoom.sdk.ZoomVideoSDKVideoCapability
import us.zoom.sdk.ZoomVideoSDKVideoSender
import us.zoom.sdk.ZoomVideoSDKVideoSource

/**
 * Zoom external video source fed by Nosmai's processed camera frames. Nosmai owns the camera;
 * Zoom never opens it.
 *
 * TEXTURE (default when Nosmai joined [SharedGlContext]'s share group): per Nosmai's consumer
 * protocol (waitStreamFrame -> GPU reads -> completeStreamFrame) the processed texture is
 * converted to I420 on the GPU by [I420Converter] on the dedicated GL thread, read back once
 * into a pooled direct buffer and handed to Zoom. Nosmai's render thread never blocks on it.
 *
 * I420 (fallback): Nosmai's frame callback delivers a pooled I420 byte[]; it is copied once into
 * a pooled direct buffer for Zoom.
 *
 * Frames are only produced between Zoom's onStartSend and onStopSend.
 */
internal class NosmaiZoomVideoSource(
    private val appContext: Context,
    private val gl: SharedGlContext?,
    private val control: ExecutorService,
) : ZoomVideoSDKVideoSource {

    enum class Transport { TEXTURE, I420 }

    private class TextureUnavailable(message: String) : Exception(message)

    /** Small ring of direct buffers so Zoom never sees a buffer being refilled. */
    private class BufferRing {
        private val buffers = arrayOfNulls<ByteBuffer>(RING_SIZE)
        private var next = 0
        fun take(bytes: Int): ByteBuffer {
            val index = next
            next = (next + 1) % RING_SIZE
            val existing = buffers[index]
            if (existing != null && existing.capacity() == bytes) return existing
            return ByteBuffer.allocateDirect(bytes).also { buffers[index] = it }
        }
        fun clear() = buffers.fill(null)
    }

    // ---- Configuration (set before joining) ----
    @Volatile private var maxFps = 30
    @Volatile private var maxLongSide = 1280
    @Volatile private var flipVertical = true
    @Volatile private var preferTexture = true
    @Volatile private var adaptToThermalState = true

    // ---- Zoom state ----
    @Volatile private var sender: ZoomVideoSDKVideoSender? = null
    @Volatile private var suggested: String = ""
    @Volatile private var suggestedLongSide = 0
    @Volatile private var suggestedFps = 0
    private val sending = AtomicBoolean(false)

    // ---- Pipeline state ----
    @Volatile private var transport = Transport.I420
    @Volatile private var thermalCapFps = Int.MAX_VALUE
    @Volatile private var lastError = ""
    @Volatile private var lastWidth = 0
    @Volatile private var lastHeight = 0
    private val copyPending = AtomicBoolean(false)
    private var nextDeadlineNs = 0L // Nosmai render thread only.

    // GL thread only.
    private val converter = I420Converter()
    private val textureRing = BufferRing()
    private var textureFailures = 0
    // Nosmai callback thread only.
    private val pixelRing = BufferRing()
    private var rotateScratch = ByteArray(0)

    // ---- Counters (cumulative; rates are derived in [stats]) ----
    private val framesIn = AtomicLong()
    private val sent = AtomicLong()
    private val dropped = AtomicLong()
    private val paced = AtomicLong()
    private val errors = AtomicLong()
    private val convertNsTotal = AtomicLong()
    private val convertNsMax = AtomicLong()
    private val sendNsTotal = AtomicLong()
    private var lastStatsAtMs = 0L
    private var lastStatsSent = 0L
    private var lastStatsIn = 0L
    private var lastStatsConvertNs = 0L
    private var lastStatsSendNs = 0L

    // Nosmai's JNI layer may only keep weak references; hold both callbacks strongly.
    private val textureCallback =
        NosmaiSDK.TextureFrameCallback { texture, width, height, _, _ -> onTexture(texture, width, height) }
    private val frameCallback = NosmaiSDK.FrameCallback { onPixels(it) }
    private val thermalListener: Any? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            PowerManager.OnThermalStatusChangedListener { thermalCapFps = capFor(it) }
        } else null

    val sharedContextAvailable: Boolean
        get() {
            val context = gl ?: return false
            return runCatching { NosmaiSDK.isAgoraShareContext(context.nativeHandle) }.getOrDefault(false)
        }

    fun configure(fps: Int, longSide: Int, transport: String, flip: Boolean, thermal: Boolean) {
        maxFps = fps.coerceIn(1, 60)
        maxLongSide = longSide.coerceIn(320, 1920)
        preferTexture = transport != "i420"
        flipVertical = flip
        adaptToThermalState = thermal
    }

    fun setMaxFps(fps: Int) {
        maxFps = fps.coerceIn(1, 60)
    }

    // ---- ZoomVideoSDKVideoSource (called by Zoom) ----

    override fun onInitialize(
        sender: ZoomVideoSDKVideoSender?,
        supportCapabilityList: MutableList<ZoomVideoSDKVideoCapability>?,
        suggestCapability: ZoomVideoSDKVideoCapability?,
    ) {
        this.sender = sender
        recordCapability(suggestCapability)
        Log.i(TAG, "Zoom video source initialized; suggested $suggested")
    }

    override fun onPropertyChange(
        supportCapabilityList: MutableList<ZoomVideoSDKVideoCapability>?,
        suggestCapability: ZoomVideoSDKVideoCapability?,
    ) {
        recordCapability(suggestCapability)
        Log.i(TAG, "Zoom video capability changed; suggested $suggested")
    }

    /** Told whenever Zoom starts or stops asking for frames. Any thread. */
    @Volatile var onSendingChanged: ((Boolean) -> Unit)? = null

    val isSending: Boolean get() = sending.get()

    override fun onStartSend() {
        if (!sending.compareAndSet(false, true)) return
        control.execute { startOutput() }
        onSendingChanged?.invoke(true)
    }

    override fun onStopSend() {
        if (!sending.compareAndSet(true, false)) return
        control.execute { stopOutput() }
        onSendingChanged?.invoke(false)
    }

    override fun onUninitialized() {
        onStopSend()
        sender = null
    }

    /** Detaches from Nosmai and drains in-flight frames. Safe to call repeatedly; blocks briefly. */
    fun shutdown() {
        val wasSending = sending.getAndSet(false)
        stopOutput()
        sender = null
        if (wasSending) onSendingChanged?.invoke(false)
    }

    // ---- Output lifecycle (control thread) ----

    private fun startOutput() {
        if (!sending.get()) return
        nextDeadlineNs = 0L
        transport = if (preferTexture && sharedContextAvailable) Transport.TEXTURE else Transport.I420
        lastError = when {
            transport == Transport.TEXTURE -> ""
            preferTexture -> "Shared GPU context unavailable; using Nosmai CPU frames"
            else -> ""
        }
        if (adaptToThermalState) registerThermalListener()
        try {
            NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.DUAL_OUTPUT)
            installCallback(transport)
        } catch (t: Throwable) {
            report("Starting Nosmai output failed: ${describe(t)}")
        }
    }

    private fun stopOutput() {
        try {
            NosmaiSDK.setTextureFrameCallback(null)
            NosmaiSDK.setFrameCallback(null)
            NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.PREVIEW_ONLY)
        } catch (t: Throwable) {
            Log.w(TAG, "Removing Nosmai callbacks failed", t)
        }
        // Queued conversions observe sending=false and return their Nosmai slot; then free GPU
        // and CPU buffers so an idle app holds none.
        gl?.runAndWait(DRAIN_TIMEOUT_MS) {
            converter.release()
            textureRing.clear()
        }
        unregisterThermalListener()
    }

    private fun installCallback(selected: Transport) {
        if (selected == Transport.TEXTURE) {
            NosmaiSDK.setFrameCallback(null)
            NosmaiSDK.setTextureFrameCallback(textureCallback)
        } else {
            NosmaiSDK.setTextureFrameCallback(null)
            NosmaiSDK.setFrameCallback(frameCallback)
        }
    }

    // ---- Texture transport ----

    /** Nosmai render thread: never blocks; hands at most one frame to the GL thread. */
    private fun onTexture(texture: Int, width: Int, height: Int) {
        framesIn.incrementAndGet()
        val context = gl
        if (!sending.get() || transport != Transport.TEXTURE || context == null) {
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
            dropped.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        if (!admitFrame()) {
            paced.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        // One conversion in flight: a slow GPU drops frames instead of building latency.
        if (!copyPending.compareAndSet(false, true)) {
            dropped.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        if (!context.post { convertAndSend(texture, width, height) }) {
            copyPending.set(false)
            dropped.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
        }
    }

    /** GL thread. */
    private fun convertAndSend(texture: Int, srcW: Int, srcH: Int) {
        var returned = false
        try {
            if (!sending.get()) return
            val target = sender ?: run { dropped.incrementAndGet(); return }
            // Zoom centre-crops portrait frames to 16:9, so portrait goes out as a rotated
            // landscape frame plus a rotation flag, the way camera sensor frames do.
            val rotate = srcH > srcW
            val (width, height) = if (rotate) {
                I420Converter.alignedSize(srcH, srcW, outputLongSide())
            } else {
                I420Converter.alignedSize(srcW, srcH, outputLongSide())
            }
            val buffer = textureRing.take(I420Converter.frameBytes(width, height))
            if (!NosmaiSDK.waitStreamFrame(texture)) {
                dropped.incrementAndGet()
                return
            }
            val started = SystemClock.elapsedRealtimeNanos()
            try {
                if (!GLES20.glIsTexture(texture)) {
                    throw TextureUnavailable("Nosmai texture is not visible in the shared GL context")
                }
                converter.render(texture, width, height, flipVertical, rotate)
            } finally {
                // Records Nosmai's fence after our draw; Nosmai may reuse the texture after it.
                NosmaiSDK.completeStreamFrame(texture)
                returned = true
            }
            converter.readInto(buffer)
            recordConvert(SystemClock.elapsedRealtimeNanos() - started)
            if (!sending.get()) return
            send(target, buffer, width, height, rotate)
            textureFailures = 0
        } catch (error: TextureUnavailable) {
            dropped.incrementAndGet()
            onTextureFailure(error.message ?: "Texture unavailable")
        } catch (error: Throwable) {
            dropped.incrementAndGet()
            onTextureFailure("Texture frame failed: ${describe(error)}")
        } finally {
            if (!returned) NosmaiSDK.releaseStreamSlot(texture)
            copyPending.set(false)
        }
    }

    private fun onTextureFailure(message: String) {
        report(message)
        if (++textureFailures < TEXTURE_FAILURES_BEFORE_FALLBACK) return
        Log.w(TAG, "$message; switching to Nosmai I420 frames")
        lastError = "$message; switched to CPU frames"
        transport = Transport.I420
        if (sending.get()) control.execute { if (sending.get()) installCallback(Transport.I420) }
    }

    // ---- I420 transport ----

    /** Nosmai callback thread. The byte[] is pooled by Nosmai, so it is copied before returning. */
    private fun onPixels(frame: NosmaiSDK.FrameData?) {
        framesIn.incrementAndGet()
        if (frame == null || !sending.get() || transport != Transport.I420) return
        val data = frame.pixelBuffer
        val width = frame.width
        val height = frame.height
        if (data == null || width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
            dropped.incrementAndGet()
            return
        }
        if (frame.format != NOSMAI_FORMAT_I420) {
            dropped.incrementAndGet()
            report("Unsupported Nosmai frame format ${frame.format}")
            return
        }
        val bytes = width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)
        if (data.size < bytes) {
            dropped.incrementAndGet()
            return
        }
        val rotate = height > width
        if (width % 2 != 0 || height % 2 != 0) {
            dropped.incrementAndGet()
            report("Odd-sized Nosmai frame ${width}x$height is not supported")
            return
        }
        if (!admitFrame()) {
            paced.incrementAndGet()
            return
        }
        val target = sender ?: run { dropped.incrementAndGet(); return }
        try {
            val started = SystemClock.elapsedRealtimeNanos()
            val buffer = pixelRing.take(bytes)
            buffer.clear()
            // Rotate portrait to landscape exactly as the GPU path does (rows are top-down, as
            // in Nosmai's preview).
            val out = rotateScratch.takeIf { it.size >= bytes } ?: ByteArray(bytes).also { rotateScratch = it }
            rotateI420(data, width, height, out, rotate)
            buffer.put(out, 0, bytes)
            buffer.flip()
            recordConvert(SystemClock.elapsedRealtimeNanos() - started)
            if (rotate) send(target, buffer, height, width, true) else send(target, buffer, width, height, false)
        } catch (error: Throwable) {
            dropped.incrementAndGet()
            report("I420 frame failed: ${describe(error)}")
        }
    }

    // ---- Shared helpers ----

    private fun send(target: ZoomVideoSDKVideoSender, buffer: ByteBuffer, width: Int, height: Int, rotated: Boolean) {
        val started = SystemClock.elapsedRealtimeNanos()
        val rotation = if (rotated) PORTRAIT_ROTATION else ZoomVideoSDKVideoSender.ROTATION_ACTION_0
        target.sendVideoFrame(buffer, width, height, buffer.limit(), rotation)
        sendNsTotal.addAndGet(SystemClock.elapsedRealtimeNanos() - started)
        sent.incrementAndGet()
        lastWidth = width
        lastHeight = height
    }

    private fun recordConvert(ns: Long) {
        convertNsTotal.addAndGet(ns)
        while (true) {
            val max = convertNsMax.get()
            if (ns <= max || convertNsMax.compareAndSet(max, ns)) return
        }
    }

    /**
     * Zoom centre-crops any frame that is not the size it asked for (measured: 960x540 in came
     * out as a 1.5x zoom, 640x360 as 2x), so frames are made at Zoom's suggested size once known.
     * The configured size only applies until Zoom suggests one.
     */
    private fun outputLongSide(): Int {
        val suggestedSide = suggestedLongSide
        return if (suggestedSide >= 320) suggestedSide else maxLongSide
    }

    /**
     * Even spacing at the target rate; encoders want a steady cadence. A frame may arrive up to
     * a quarter interval early, so camera jitter at the target rate itself drops nothing.
     */
    private fun admitFrame(): Boolean {
        val now = SystemClock.elapsedRealtimeNanos()
        val interval = 1_000_000_000L / effectiveFps()
        val deadline = nextDeadlineNs
        if (deadline != 0L && now + interval / 4 < deadline) return false
        nextDeadlineNs = if (deadline == 0L || now - deadline > RESYNC_AFTER_NS) now + interval else deadline + interval
        return true
    }

    // Every preview frame goes to Zoom up to the configured rate; Zoom's suggested rate (25) is
    // not a cap here. Measured on a Pixel 5: with 30 fps in, Zoom's encoder still sent at most
    // ~24 fps, so pick fps: 25 in NosmaiLiveVideoConfig to save the extra conversions.
    private fun effectiveFps(): Int = minOf(maxFps, thermalCapFps).coerceAtLeast(1)

    private fun recordCapability(capability: ZoomVideoSDKVideoCapability?) {
        if (capability == null) return
        suggested = "${capability.width}x${capability.height}@${capability.frame} ${capability.dataMode}"
        suggestedLongSide = maxOf(capability.width, capability.height)
        suggestedFps = capability.frame
    }

    /** Called about once per second from the stats poll (main thread). */
    fun stats(): Map<String, Any?> {
        val now = SystemClock.elapsedRealtime()
        val sentNow = sent.get()
        val inNow = framesIn.get()
        val convertNs = convertNsTotal.get()
        val sendNs = sendNsTotal.get()
        val elapsedMs = if (lastStatsAtMs == 0L) 0L else now - lastStatsAtMs
        val sentDelta = sentNow - lastStatsSent
        fun perSecond(delta: Long) = if (elapsedMs > 0) delta * 1000.0 / elapsedMs else 0.0
        fun avgMs(totalDelta: Long) = if (sentDelta > 0) totalDelta / sentDelta / 1_000_000.0 else 0.0
        val result = mapOf(
            "sending" to sending.get(),
            "senderReady" to (sender != null),
            "transport" to transport.name.lowercase(),
            "sharedContext" to sharedContextAvailable,
            "framesIn" to inNow,
            "sent" to sentNow,
            "dropped" to dropped.get(),
            "paced" to paced.get(),
            "errors" to errors.get(),
            "inputFps" to perSecond(inNow - lastStatsIn),
            "txFps" to perSecond(sentDelta),
            "convertMsAvg" to avgMs(convertNs - lastStatsConvertNs),
            "convertMsMax" to convertNsMax.getAndSet(0) / 1_000_000.0,
            "sendMsAvg" to avgMs(sendNs - lastStatsSendNs),
            "width" to lastWidth,
            "height" to lastHeight,
            "targetFps" to effectiveFps(),
            "zoomSuggested" to suggested,
            "lastError" to lastError,
        )
        lastStatsAtMs = now
        lastStatsSent = sentNow
        lastStatsIn = inNow
        lastStatsConvertNs = convertNs
        lastStatsSendNs = sendNs
        return result
    }

    fun resetCounters() {
        for (counter in listOf(framesIn, sent, dropped, paced, errors, convertNsTotal, convertNsMax, sendNsTotal)) {
            counter.set(0)
        }
        lastStatsAtMs = 0L; lastStatsSent = 0L; lastStatsIn = 0L; lastStatsConvertNs = 0L; lastStatsSendNs = 0L
        lastWidth = 0; lastHeight = 0; lastError = ""; suggested = ""; suggestedLongSide = 0; suggestedFps = 0
    }

    private fun registerThermalListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val power = appContext.getSystemService(PowerManager::class.java) ?: return
        try {
            thermalCapFps = capFor(power.currentThermalStatus)
            power.addThermalStatusListener(thermalListener as PowerManager.OnThermalStatusChangedListener)
        } catch (t: Throwable) {
            Log.w(TAG, "Thermal status unavailable", t)
        }
    }

    private fun unregisterThermalListener() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching {
                appContext.getSystemService(PowerManager::class.java)
                    ?.removeThermalStatusListener(thermalListener as PowerManager.OnThermalStatusChangedListener)
            }
        }
        thermalCapFps = Int.MAX_VALUE
    }

    private fun report(message: String) {
        lastError = message
        if (errors.incrementAndGet() <= 5) Log.e(TAG, message)
    }

    companion object {
        private const val TAG = "NosmaiZoomSource"
        private const val RING_SIZE = 3
        private const val MAX_DIMENSION = 4096
        private const val NOSMAI_FORMAT_I420 = 1
        private const val TEXTURE_FAILURES_BEFORE_FALLBACK = 3
        private const val DRAIN_TIMEOUT_MS = 2_000L
        private const val RESYNC_AFTER_NS = 200_000_000L

        private fun capFor(status: Int): Int = when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q -> Int.MAX_VALUE
            status >= PowerManager.THERMAL_STATUS_CRITICAL -> 10
            status >= PowerManager.THERMAL_STATUS_SEVERE -> 15
            else -> Int.MAX_VALUE
        }

        /**
         * Tells Zoom how to turn a landscape frame made by rotating a portrait image 90°
         * counter-clockwise (see [I420Converter.render]) back upright. Verified on devices with
         * an on-screen text effect: viewers see exactly the Nosmai preview, not mirrored.
         */
        private const val PORTRAIT_ROTATION = ZoomVideoSDKVideoSender.ROTATION_ACTION_90

        /**
         * CPU twin of the GPU path for a w x h I420 frame [src]: [dst] gets a copy, or with
         * [rotateCcw] the frame turned 90° counter-clockwise (h wide, w tall). Even sizes only.
         */
        private fun rotateI420(src: ByteArray, w: Int, h: Int, dst: ByteArray, rotateCcw: Boolean) {
            val cw = w / 2
            val ch = h / 2
            transformPlane(src, 0, w, h, dst, 0, rotateCcw)
            transformPlane(src, w * h, cw, ch, dst, w * h, rotateCcw)
            transformPlane(src, w * h + cw * ch, cw, ch, dst, w * h + cw * ch, rotateCcw)
        }

        // Pixel (x, y): unrotated it lands at (x, y);
        // rotated counter-clockwise at (y, w - 1 - x) in an h-wide plane.
        private fun transformPlane(src: ByteArray, srcOff: Int, w: Int, h: Int, dst: ByteArray, dstOff: Int, rotateCcw: Boolean) {
            for (y in 0 until h) {
                val row = srcOff + y * w
                if (!rotateCcw) {
                    System.arraycopy(src, row, dst, dstOff + y * w, w)
                    continue
                }
                for (x in 0 until w) {
                    dst[dstOff + (w - 1 - x) * h + y] = src[row + x]
                }
            }
        }

        private fun describe(error: Throwable) = error.message ?: error.javaClass.simpleName
    }
}
