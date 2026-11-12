package com.nosmai.zoom_live

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowManager
import com.nosmai.effect.api.NosmaiSDK
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import us.zoom.sdk.ZoomVideoSDKVideoView

/**
 * Flutter side of nosmai_zoom_live: MethodChannel `nosmai_zoom_live` (commands), EventChannel
 * `nosmai_zoom_live/events` (session events) and platform view `nosmai_zoom_live/remote_video`.
 *
 * Threads: Zoom calls run on the main thread; Nosmai/GL setup and teardown run on one command
 * thread so they neither block the UI nor reorder.
 */
class NosmaiZoomLivePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var appContext: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var activity: ActivityPluginBinding? = null
    private var pendingPermissions: MethodChannel.Result? = null
    private var screenOn = false
    private val diagnostics = ProcessDiagnostics()
    private val emitter: (Map<String, Any?>) -> Unit = { event -> main.post { onSessionEvent(event) } }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val owner = session(appContext)
        owner.emit = emitter
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "$CHANNEL/events").also { it.setStreamHandler(this) }
        binding.platformViewRegistry.registerViewFactory("$CHANNEL/remote_video", RemoteVideoViewFactory(owner))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        // Hot restart or engine teardown: never leave a session or the camera stream running.
        val owner = session(appContext)
        main.post {
            // A new engine (hot restart) may already own the session; leave it alone then.
            if (owner.emit !== emitter) return@post
            owner.emit = {}
            runCatching { owner.leave(endSession = false) }
        }
        currentSource()?.let { source -> commands.execute { source.shutdown() } }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun onSessionEvent(event: Map<String, Any?>) {
        when (event["type"]) {
            "joined" -> if (session(appContext).request?.keepScreenOn == true) setScreenOn(true)
            "left" -> {
                setScreenOn(false)
                currentSource()?.let { source -> commands.execute { source.shutdown() } }
            }
        }
        sink?.success(event)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = session(appContext)
        when (call.method) {
            "prepare" -> background(result) {
                prepare().also {
                    // Zoom's own init is slow and main-thread only: do it now, while the app is
                    // still setting up, not when the user taps Start. A failure resurfaces at join.
                    main.post {
                        runCatching { owner.ensureInitialized() }
                            .onFailure { Log.w(TAG, "Early Zoom initialize failed; will retry at join", it) }
                    }
                }
            }
            "requestPermissions" -> requestPermissions(call.argument<Boolean>("camera") != false, result)
            "join" -> onMain(result) { join(owner, call) }
            "leave" -> onMain(result) { owner.leave(call.argument<Boolean>("endSession") == true); null }
            "setMicMuted" -> onMain(result) { owner.setMicMuted(call.flag("muted")); null }
            "setVideoMuted" -> onMain(result) { owner.setVideoMuted(call.flag("muted")); null }
            "setSpeakerMuted" -> onMain(result) { owner.setSpeakerMuted(call.flag("muted")); null }
            "setForeground" -> onMain(result) { owner.setForeground(call.flag("foreground")); null }
            "setMaxFps" -> onMain(result) { currentSource()?.setMaxFps(call.argument<Int>("fps") ?: 30); null }
            "stats" -> onMain(result) {
                val host = owner.request?.host == true
                mapOf(
                    "zoom" to owner.stats(),
                    "source" to if (host) currentSource()?.stats() else null,
                    "process" to diagnostics.sample(),
                )
            }
            "version" -> onMain(result) {
                mapOf("zoom" to owner.sdkVersion(), "sharedContext" to (sharedGl != null))
            }
            else -> result.notImplemented()
        }
    }

    private fun join(owner: ZoomSession, call: MethodCall): Map<String, Any?> {
        val host = call.flag("host")
        val request = JoinRequest(
            host = host,
            sessionName = call.text("sessionName"),
            token = call.text("token"),
            userName = call.text("userName"),
            password = call.argument<String>("password").orEmpty(),
            micMuted = call.flag("micMuted"),
            videoMuted = call.flag("videoMuted"),
            speakerMuted = call.flag("speakerMuted"),
            hostUserName = call.argument<String>("hostUserName")?.takeIf { it.isNotBlank() },
            keepScreenOn = call.argument<Boolean>("keepScreenOn") != false,
            fps = (call.argument<Int>("fps") ?: 24).coerceIn(1, 30),
            prioritizeFrameRate = call.argument<Boolean>("prioritizeFrameRate") != false,
        )
        if (!host) {
            owner.join(request, null)
            return mapOf("sharedContext" to false)
        }
        if (!granted(Manifest.permission.CAMERA)) {
            throw BridgeException("permission_denied", "Camera access is required to broadcast.")
        }
        val source = sourceOrCreate()
        source.configure(
            fps = call.argument<Int>("fps") ?: 24,
            longSide = call.argument<Int>("maxLongSide") ?: 960,
            transport = call.argument<String>("transport") ?: "auto",
            flip = call.argument<Boolean>("flipVertical") ?: false,
            thermal = call.argument<Boolean>("adaptToThermalState") ?: true,
        )
        source.resetCounters()
        source.onSendingChanged = { on -> main.post { onSessionEvent(mapOf("type" to "sending", "on" to on)) } }
        owner.join(request, source)
        return mapOf("sharedContext" to source.sharedContextAvailable)
    }

    /**
     * Must run before NosmaiFlutter.initialize: Nosmai only joins a share group that is
     * registered before its render context exists. Without it, frames flow as Nosmai I420.
     */
    private fun prepare(): Map<String, Any?> {
        val alreadyInitialized = runCatching { NosmaiSDK.isInitialized() }.getOrDefault(false)
        synchronized(LOCK) {
            if (sharedGl == null && !alreadyInitialized) {
                try {
                    val context = SharedGlContext.create()
                    runCatching { System.loadLibrary("nosmai") } // NosmaiSDK usually loads it itself.
                    NosmaiSDK.setAgoraShareContext(context.nativeHandle)
                    sharedGl = context
                } catch (t: Throwable) {
                    Log.w(TAG, "Shared GL context unavailable; Nosmai I420 frames will be used", t)
                }
            }
        }
        return mapOf("sharedContext" to (sharedGl != null), "nosmaiAlreadyInitialized" to alreadyInitialized)
    }

    private fun sourceOrCreate(): NosmaiZoomVideoSource = synchronized(LOCK) {
        source ?: NosmaiZoomVideoSource(appContext, sharedGl, commands).also { source = it }
    }

    private fun setScreenOn(on: Boolean) {
        if (screenOn == on) return
        val window = activity?.activity?.window ?: return
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        screenOn = on
    }

    // ---- Permissions ----

    private fun requestPermissions(camera: Boolean, result: MethodChannel.Result) {
        val wanted = buildList {
            if (camera) add(Manifest.permission.CAMERA)
            add(Manifest.permission.RECORD_AUDIO) // Zoom's VoIP audio needs it, even when muted.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        val needed = wanted.filterNot(::granted)
        val host = activity?.activity
        if (needed.isEmpty() || host == null) {
            result.success(permissionState())
            return
        }
        if (pendingPermissions != null) {
            result.error("permission_request_in_progress", "A permission request is already showing.", null)
            return
        }
        pendingPermissions = result
        host.requestPermissions(needed.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        pendingPermissions?.success(permissionState())
        pendingPermissions = null
        return true
    }

    private fun permissionState() = mapOf(
        "camera" to granted(Manifest.permission.CAMERA),
        "microphone" to granted(Manifest.permission.RECORD_AUDIO),
    )

    private fun granted(permission: String) =
        appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
        if (screenOn) {
            screenOn = false
            setScreenOn(true)
        }
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
        pendingPermissions?.success(permissionState())
        pendingPermissions = null
    }

    // ---- Helpers ----

    private fun onMain(result: MethodChannel.Result, block: () -> Any?) {
        main.post { deliver(result, "main", block) }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        commands.execute { deliver(result, "command", block) }
    }

    private fun deliver(result: MethodChannel.Result, thread: String, block: () -> Any?) {
        try {
            val value = block()
            main.post { result.success(value) }
        } catch (error: BridgeException) {
            main.post { result.error(error.code, error.message, null) }
        } catch (error: Throwable) {
            Log.e(TAG, "Call failed on $thread thread", error)
            main.post { result.error("native_error", error.message ?: error.javaClass.simpleName, null) }
        }
    }

    private fun MethodCall.text(key: String): String =
        argument<String>(key)?.takeIf { it.isNotBlank() }
            ?: throw BridgeException("invalid_config", "Missing $key.")

    private fun MethodCall.flag(key: String): Boolean = argument<Boolean>(key) == true

    /** Shows the broadcaster through Zoom's own renderer. */
    private class RemoteVideoViewFactory(
        private val owner: ZoomSession,
    ) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            // Zoom's view calls into Zoom's native libraries (even when its GL context is torn
            // down, e.g. behind a permission dialog). They load in Zoom's initialize, and a viewer
            // may show this view before joining, so initialize first.
            try {
                owner.ensureInitialized()
            } catch (t: Throwable) {
                Log.e(TAG, "Zoom initialize failed; showing an empty view", t)
                val empty = View(context)
                return object : PlatformView {
                    override fun getView(): View = empty
                    override fun dispose() {}
                }
            }
            // `true` = Zoom's TextureView renderer. Flutter composes a TextureView like any other
            // texture; Zoom's default SurfaceView needs hybrid composition, which left stale
            // Flutter overlay pixels (ghost text) on top of the video on a Samsung A52s.
            val view = ZoomVideoSDKVideoView(context, true)
            owner.attachRemoteView(view)
            return object : PlatformView {
                override fun getView(): View = view
                override fun dispose() = owner.detachRemoteView(view)
            }
        }
    }

    companion object {
        private const val TAG = "NosmaiZoomLive"
        private const val CHANNEL = "nosmai_zoom_live"
        private const val PERMISSION_REQUEST_CODE = 0x4E5A // "NZ"

        // Process-wide: Zoom and Nosmai are process singletons, and Nosmai keeps the share group
        // for the life of the process.
        private val LOCK = Any()
        private var sharedGl: SharedGlContext? = null
        private var source: NosmaiZoomVideoSource? = null
        private var zoom: ZoomSession? = null
        private val commands: ExecutorService =
            Executors.newSingleThreadExecutor { Thread(it, "nosmai-zoom-live") }

        private fun currentSource(): NosmaiZoomVideoSource? = synchronized(LOCK) { source }

        private fun session(context: Context): ZoomSession = synchronized(LOCK) {
            zoom ?: ZoomSession(context.applicationContext).also { zoom = it }
        }
    }
}
