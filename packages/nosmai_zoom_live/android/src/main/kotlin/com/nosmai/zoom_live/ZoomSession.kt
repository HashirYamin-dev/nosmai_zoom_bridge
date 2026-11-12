package com.nosmai.zoom_live

import android.content.Context
import android.util.Log
import java.lang.reflect.Proxy
import us.zoom.sdk.ZoomVideoSDK
import us.zoom.sdk.ZoomVideoSDKAudioOption
import us.zoom.sdk.ZoomVideoSDKDelegate
import us.zoom.sdk.ZoomVideoSDKErrors
import us.zoom.sdk.ZoomVideoSDKInitParams
import us.zoom.sdk.ZoomVideoSDKPasswordHandler
import us.zoom.sdk.ZoomVideoSDKRawDataMemoryMode
import us.zoom.sdk.ZoomVideoSDKSessionContext
import us.zoom.sdk.ZoomVideoSDKSessionLeaveReason
import us.zoom.sdk.ZoomVideoSDKUser
import us.zoom.sdk.ZoomVideoSDKVideoAspect
import us.zoom.sdk.ZoomVideoSDKVideoOption
import us.zoom.sdk.ZoomVideoSDKVideoPreferenceMode
import us.zoom.sdk.ZoomVideoSDKVideoPreferenceSetting
import us.zoom.sdk.ZoomVideoSDKVideoResolution
import us.zoom.sdk.ZoomVideoSDKVideoView

/** What Dart asked for when joining. */
internal class JoinRequest(
    val host: Boolean,
    val sessionName: String,
    val token: String,
    val userName: String,
    val password: String,
    val micMuted: Boolean,
    val videoMuted: Boolean,
    val speakerMuted: Boolean,
    val hostUserName: String?,
    val keepScreenOn: Boolean,
    val fps: Int = 24,
    val prioritizeFrameRate: Boolean = true,
)

/**
 * The process-wide Zoom Video SDK session: one broadcaster (publishes [NosmaiZoomVideoSource])
 * or one viewer (renders the broadcaster into [ZoomVideoSDKVideoView]s).
 *
 * Main thread only: Zoom's Android SDK expects its calls and delivers its callbacks there.
 * Outcomes reach Dart as events through [emit]:
 * `joined`, `left {reason}`, `reconnecting`, `error {code, message, fatal}`,
 * `warning {message}`, `remoteVideo {userName, on}` and (from the plugin) `sending {on}`.
 */
internal class ZoomSession(private val appContext: Context) {
    var emit: (Map<String, Any?>) -> Unit = {}

    private val sdk: ZoomVideoSDK get() = ZoomVideoSDK.getInstance()
    private var initialized = false

    var request: JoinRequest? = null
        private set
    private var source: NosmaiZoomVideoSource? = null
    private var joined = false
    private var joinedAtMs = 0L
    private var foreground = true
    private var micMuted = false
    private var videoMuted = false
    private var speakerMuted = false
    private var localVideoOn = false

    private val remoteViews = LinkedHashSet<ZoomVideoSDKVideoView>()
    private val subscribed = HashMap<ZoomVideoSDKVideoView, ZoomVideoSDKUser>()
    private var reportedRemote: Pair<String?, Boolean>? = null

    // Zoom's delegate interface has ~90 methods; a proxy handles the handful we need.
    private val delegate: ZoomVideoSDKDelegate = Proxy.newProxyInstance(
        ZoomVideoSDKDelegate::class.java.classLoader,
        arrayOf(ZoomVideoSDKDelegate::class.java),
    ) { proxy, method, args ->
        when (method.name) {
            "hashCode" -> System.identityHashCode(proxy)
            "equals" -> proxy === args?.getOrNull(0)
            "toString" -> "NosmaiZoomLiveDelegate"
            else -> {
                try {
                    onDelegate(method.name, args ?: emptyArray())
                } catch (t: Throwable) {
                    Log.e(TAG, "Delegate ${method.name} failed", t)
                }
                null
            }
        }
    } as ZoomVideoSDKDelegate

    val active: Boolean get() = request != null

    private val inSession: Boolean get() = initialized && sdk.isInSession

    fun sdkVersion(): String = runCatching { sdk.sdkVersion }.getOrDefault("")

    /** Zoom's initialize takes about 1.5 s on the main thread; run it before the user presses Start. */
    fun ensureInitialized() {
        if (initialized) return
        val params = ZoomVideoSDKInitParams().apply {
            domain = "zoom.us"
            enableLog = false
            videoRawDataMemoryMode = ZoomVideoSDKRawDataMemoryMode.ZoomVideoSDKRawDataMemoryModeHeap
            audioRawDataMemoryMode = ZoomVideoSDKRawDataMemoryMode.ZoomVideoSDKRawDataMemoryModeHeap
            shareRawDataMemoryMode = ZoomVideoSDKRawDataMemoryMode.ZoomVideoSDKRawDataMemoryModeHeap
        }
        val code = sdk.initialize(appContext, params)
        if (code != ZoomVideoSDKErrors.Errors_Success) {
            throw BridgeException("start_failed", "Zoom Video SDK initialize failed: ${errorName(code)} ($code)")
        }
        sdk.addListener(delegate)
        initialized = true
    }

    /**
     * Joins asynchronously; success arrives as the `joined` event. A broadcaster passes
     * [videoSource] so Zoom publishes Nosmai's frames instead of opening a camera.
     */
    fun join(join: JoinRequest, videoSource: NosmaiZoomVideoSource?) {
        ensureInitialized()
        if (request != null || sdk.isInSession) {
            throw BridgeException(
                "already_active",
                "Another Zoom session is active in this app. Stop it before starting a new one.",
            )
        }
        request = join
        source = if (join.host) videoSource else null
        joined = false
        joinedAtMs = 0L
        foreground = true
        micMuted = join.micMuted
        videoMuted = join.videoMuted
        speakerMuted = join.speakerMuted
        localVideoOn = join.host && !join.videoMuted
        reportedRemote = null
        val context = ZoomVideoSDKSessionContext().apply {
            sessionName = join.sessionName
            token = join.token
            userName = join.userName
            sessionPassword = join.password
            videoOption = ZoomVideoSDKVideoOption().apply { localVideoOn = this@ZoomSession.localVideoOn }
            audioOption = ZoomVideoSDKAudioOption().apply {
                connect = join.host || !join.speakerMuted
                mute = !join.host || join.micMuted
                autoAdjustSpeakerVolume = true
            }
            if (join.host) externalVideoSource = videoSource
        }
        if (sdk.joinSession(context) == null) {
            reset()
            throw BridgeException(
                "start_failed",
                "Zoom rejected the join request. Check the session name and that the token was issued for it.",
            )
        }
    }

    /** Leaves (and, for a broadcaster with [endSession], ends) the session. `left` follows. */
    fun leave(endSession: Boolean) {
        val current = request ?: return
        unsubscribeAll()
        val code = if (initialized) sdk.leaveSession(endSession && current.host) else ZoomVideoSDKErrors.Errors_Wrong_Usage
        if (code != ZoomVideoSDKErrors.Errors_Success && !inSession) {
            // Nothing to leave (the join never got through), so Zoom will not call back.
            Log.i(TAG, "leaveSession: ${errorName(code)}; not in a session")
            reset()
            emit(mapOf("type" to "left", "reason" to "BySelf"))
        }
    }

    fun setMicMuted(muted: Boolean) {
        micMuted = muted
        applyMedia()
    }

    fun setVideoMuted(muted: Boolean) {
        videoMuted = muted
        applyMedia()
    }

    fun setSpeakerMuted(muted: Boolean) {
        speakerMuted = muted
        applyMedia()
    }

    /** Backgrounded: stop sending (broadcaster) or receiving (viewer) until foregrounded. */
    fun setForeground(value: Boolean) {
        if (foreground == value) return
        foreground = value
        applyMedia()
    }

    private fun applyMedia() {
        val current = request ?: return
        if (!joined || !inSession) return
        val me = sdk.session?.mySelf ?: return
        val audio = sdk.audioHelper
        if (current.host) {
            val wantVideo = !videoMuted && foreground
            if (wantVideo != localVideoOn) {
                val code = if (wantVideo) sdk.videoHelper.startVideo() else sdk.videoHelper.stopVideo()
                if (code == ZoomVideoSDKErrors.Errors_Success) {
                    localVideoOn = wantVideo
                } else {
                    warn("${if (wantVideo) "Starting" else "Stopping"} video failed: ${errorName(code)}")
                }
            }
            val wantMuted = micMuted || !foreground
            val isMuted = me.audioStatus?.isMuted ?: true
            if (wantMuted != isMuted) {
                if (!audioConnected(me)) audio.startAudio()
                val code = if (wantMuted) audio.muteAudio(me) else audio.unMuteAudio(me)
                if (code != ZoomVideoSDKErrors.Errors_Success) {
                    warn("${if (wantMuted) "Muting" else "Unmuting"} the microphone failed: ${errorName(code)}")
                }
            }
        } else {
            val wantAudio = !speakerMuted && foreground
            val connected = audioConnected(me)
            if (wantAudio && !connected) {
                val code = audio.startAudio()
                if (code == ZoomVideoSDKErrors.Errors_Success) {
                    audio.muteAudio(me) // Viewers listen; they never send audio.
                } else {
                    warn("Starting audio failed: ${errorName(code)}")
                }
            } else if (!wantAudio && connected) {
                audio.stopAudio()
            }
            refreshSubscriptions()
        }
    }

    /**
     * Zoom's default (Balance) trades frame rate for sharpness: with 30 fps in, it sent ~24 or
     * less. Pinning min = max = the configured rate makes Zoom lower resolution instead.
     */
    private fun applyVideoPreference(join: JoinRequest) {
        val setting = ZoomVideoSDKVideoPreferenceSetting().apply {
            if (join.prioritizeFrameRate) {
                mode = ZoomVideoSDKVideoPreferenceMode.ZoomVideoSDKVideoPreferenceMode_Custom
                minimumFrameRate = join.fps
                maximumFrameRate = join.fps
            } else {
                mode = ZoomVideoSDKVideoPreferenceMode.ZoomVideoSDKVideoPreferenceMode_Balance
            }
        }
        val code = runCatching { sdk.videoHelper.setVideoQualityPreference(setting) }
            .getOrDefault(ZoomVideoSDKErrors.Errors_Wrong_Usage)
        Log.i(TAG, "Video preference ${setting.mode} ${join.fps} fps: ${errorName(code)}")
        if (code != ZoomVideoSDKErrors.Errors_Success) {
            warn("Zoom did not accept the frame-rate preference: ${errorName(code)}")
        }
    }

    private fun audioConnected(me: ZoomVideoSDKUser): Boolean =
        me.audioStatus?.audioType?.name?.contains("None", ignoreCase = true) == false

    // ---- Remote video (viewer) ----

    fun attachRemoteView(view: ZoomVideoSDKVideoView) {
        remoteViews.add(view)
        refreshSubscriptions()
    }

    fun detachRemoteView(view: ZoomVideoSDKVideoView) {
        remoteViews.remove(view)
        subscribed.remove(view)?.let { user -> runCatching { user.videoCanvas?.unSubscribe(view) } }
        reportRemote()
    }

    /** Shows the broadcaster in every attached view, and reports what is shown. */
    private fun refreshSubscriptions() {
        val current = request
        if (current == null || current.host || !joined || !inSession) return
        val target = if (foreground) publisher(current.hostUserName) else null
        for (view in remoteViews) {
            val existing = subscribed[view]
            if (existing != null && target != null && existing.userID == target.userID) continue
            existing?.let { runCatching { it.videoCanvas?.unSubscribe(view) } }
            subscribed.remove(view)
            if (target == null) continue
            val code = target.videoCanvas?.subscribe(
                view,
                ZoomVideoSDKVideoAspect.ZoomVideoSDKVideoAspect_LetterBox,
                ZoomVideoSDKVideoResolution.VideoResolution_720P,
            ) ?: ZoomVideoSDKErrors.Errors_Wrong_Usage
            if (code == ZoomVideoSDKErrors.Errors_Success) {
                subscribed[view] = target
            } else {
                warn("Showing the broadcaster's video failed: ${errorName(code)}")
            }
        }
        reportRemote()
    }

    private fun reportRemote() {
        val current = request ?: return
        if (current.host) return
        val shown = subscribed.values.firstOrNull()
        val target = shown ?: if (joined && inSession && foreground) publisher(current.hostUserName) else null
        val on = shown != null && shown.videoCanvas?.videoStatus?.isOn == true
        val next = Pair(target?.userName, on)
        if (next == reportedRemote) return
        reportedRemote = next
        emit(mapOf("type" to "remoteVideo", "userName" to next.first, "on" to on))
    }

    private fun unsubscribeAll() {
        for ((view, user) in subscribed) runCatching { user.videoCanvas?.unSubscribe(view) }
        subscribed.clear()
    }

    /** The user to watch: [wanted] by name if given, else the sending host, else any sender. */
    private fun publisher(wanted: String?): ZoomVideoSDKUser? {
        val session = sdk.session ?: return null
        val me = session.mySelf
        var remote = session.remoteUsers.orEmpty().filter { it.userID != me?.userID }
        if (!wanted.isNullOrEmpty()) remote = remote.filter { it.userName == wanted }
        val withVideo = remote.filter { it.videoCanvas?.videoStatus?.isOn == true }
        return withVideo.firstOrNull { it.isHost } ?: withVideo.firstOrNull()
            ?: remote.firstOrNull { it.isHost } ?: remote.firstOrNull()
    }

    // ---- Stats ----

    fun stats(): Map<String, Any?> {
        val current = request
        val session = if (current != null && joined && inSession) sdk.session else null
        val stats = HashMap<String, Any?>()
        stats["inSession"] = session != null
        if (session == null || current == null) return stats
        stats["participants"] = session.remoteUsers?.size ?: 0
        stats["secondsLive"] = if (joinedAtMs > 0) (System.currentTimeMillis() - joinedAtMs) / 1000 else 0
        session.mySelf?.let { me ->
            stats["micMuted"] = me.audioStatus?.isMuted ?: true
            stats["network"] = networkName(me.overallNetworkLevel?.name)
        }
        session.sessionVideoStatisticInfo?.let { video ->
            if (current.host) {
                stats["fps"] = video.sendFps
                stats["width"] = video.sendFrameWidth
                stats["height"] = video.sendFrameHeight
                stats["latencyMs"] = video.sendLatency
                stats["lossPercent"] = video.sendPacketLossAvg.toDouble()
            } else {
                stats["fps"] = video.recvFps
                stats["width"] = video.recvFrameWidth
                stats["height"] = video.recvFrameHeight
                stats["latencyMs"] = video.recvLatency
                stats["lossPercent"] = video.recvPacketLossAvg.toDouble()
            }
        }
        if (!current.host) {
            subscribed.values.firstOrNull()?.videoStatisticInfo?.let { info ->
                // Per-user figures describe exactly the stream on screen; prefer them.
                if (info.fps > 0) stats["fps"] = info.fps
                if (info.width > 0) stats["width"] = info.width
                if (info.height > 0) stats["height"] = info.height
                stats["bitrateKbps"] = info.bps / 1000
                stats["rttMs"] = info.rtt
                stats["network"] = networkName(info.videoNetworkStatus?.name)
            }
        }
        return stats
    }

    private fun networkName(raw: String?): String = raw?.substringAfterLast('_') ?: ""

    // ---- Delegate ----

    private fun onDelegate(name: String, args: Array<out Any?>) {
        if (request == null && name != "onSessionLeave") return
        when (name) {
            "onSessionJoin" -> {
                val firstJoin = !joined
                joined = true
                if (firstJoin) {
                    joinedAtMs = System.currentTimeMillis()
                    runCatching { sdk.audioHelper.disableTelephoneMonitor(true) }
                    request?.takeIf { it.host }?.let(::applyVideoPreference)
                }
                emit(mapOf("type" to "joined"))
                applyMedia()
                refreshSubscriptions()
            }
            "onSessionLeave" -> {
                val reason = (args.getOrNull(0) as? ZoomVideoSDKSessionLeaveReason)?.name
                    ?.removePrefix("ZoomVideoSDKSessionLeaveReason_") ?: "Unknown"
                val wasActive = request != null
                unsubscribeAll()
                reset()
                if (wasActive) emit(mapOf("type" to "left", "reason" to reason))
            }
            "onError" -> {
                val code = args.getOrNull(0) as? Int ?: -1
                if (code == ZoomVideoSDKErrors.Errors_Session_Reconncting) {
                    emit(mapOf("type" to "reconnecting"))
                } else {
                    emit(mapOf(
                        "type" to "error",
                        "code" to code,
                        "message" to describeError(code),
                        "fatal" to (!joined || code in FATAL_ERRORS),
                    ))
                }
            }
            "onUserJoin", "onUserLeave", "onUserVideoStatusChanged", "onUserHostChanged" -> refreshSubscriptions()
            "onSessionNeedPassword", "onSessionPasswordWrong" -> {
                (args.getOrNull(0) as? ZoomVideoSDKPasswordHandler)?.leaveSessionIgnorePassword()
                emit(mapOf(
                    "type" to "error",
                    "code" to if (name == "onSessionNeedPassword") 2010 else 2011,
                    "message" to if (name == "onSessionNeedPassword") {
                        "This Zoom session needs a password."
                    } else {
                        "The Zoom session password is wrong."
                    },
                    "fatal" to true,
                ))
            }
            "onVideoCanvasSubscribeFail" -> warn("Showing the broadcaster's video failed: ${args.getOrNull(0)}")
        }
    }

    private fun warn(message: String) {
        Log.w(TAG, message)
        emit(mapOf("type" to "warning", "message" to message))
    }

    private fun reset() {
        request = null
        source = null
        joined = false
        joinedAtMs = 0L
        localVideoOn = false
        reportedRemote = null
        subscribed.clear()
    }

    companion object {
        private const val TAG = "NosmaiZoomLive"

        private val FATAL_ERRORS = setOf(
            ZoomVideoSDKErrors.Errors_Session_Disconnect,
            ZoomVideoSDKErrors.Errors_Session_Join_Failed,
            ZoomVideoSDKErrors.Errors_Session_No_Rights,
            ZoomVideoSDKErrors.Errors_Session_Need_Password,
            ZoomVideoSDKErrors.Errors_Session_Password_Wrong,
            ZoomVideoSDKErrors.Errors_Session_Client_Incompatible,
            ZoomVideoSDKErrors.Errors_Session_Account_FreeMinutesExceeded,
            ZoomVideoSDKErrors.Errors_Session_Account_FreeCreditExceeded,
        )

        private val errorNames: Map<Int, String> by lazy {
            ZoomVideoSDKErrors::class.java.fields
                .filter { it.type == Int::class.javaPrimitiveType }
                .mapNotNull { field -> runCatching { field.getInt(null) to field.name }.getOrNull() }
                .toMap()
        }

        fun errorName(code: Int): String = errorNames[code]?.removePrefix("Errors_") ?: "Error $code"

        private fun describeError(code: Int): String = when (code) {
            ZoomVideoSDKErrors.Errors_Session_Disconnect -> "Disconnected from Zoom."
            ZoomVideoSDKErrors.Errors_JoinSession_Invalid_SessionToken ->
                "Zoom rejected the token. Check that it is signed with this app's SDK key and has not expired."
            ZoomVideoSDKErrors.Errors_JoinSession_Token_MismatchedSessionName ->
                "The token was issued for a different session name."
            else -> "Zoom error ${errorName(code)} ($code)."
        }
    }
}

internal class BridgeException(val code: String, message: String) : Exception(message)
