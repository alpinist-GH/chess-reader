package com.alpinist.chessbook_reader

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.chessnutech.chessnutevo.ChessnutServiceChessBoardCallback
import com.chessnutech.chessnutevo.ChessnutServiceInterface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge to the Chessnut Evo's on-device board service (AIDL). It reads the
 * piece positions and sets per-square RGB LEDs without Bluetooth, so the app
 * works on the Evo's own Android screen. Only the board part of the interface
 * is used; the camera "Vision" detection is not needed.
 */
class EvoBoardService(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var service: ChessnutServiceInterface? = null
    private var binding = false
    private var pendingConnect: MethodChannel.Result? = null
    private var connectTimeout: Runnable? = null
    private var sink: EventChannel.EventSink? = null

    private val boardCallback = object : ChessnutServiceChessBoardCallback.Stub() {
        override fun onFenChanged(fen: String?) {
            main.post { sink?.success(mapOf("event" to "fen", "fen" to (fen ?: ""))) }
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val bound = ChessnutServiceInterface.Stub.asInterface(binder)
            service = bound
            try {
                bound.registerChessBoardCallback(boardCallback)
                finishConnect(null)
            } catch (e: Exception) {
                service = null
                finishConnect(e.message ?: "Could not register with the Evo service.")
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            main.post { sink?.success(mapOf("event" to "disconnected")) }
        }

        override fun onBindingDied(name: ComponentName?) = onServiceDisconnected(name)
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "chess_reader/evo_board")
            .setMethodCallHandler { call, result -> handle(call, result) }
        EventChannel(messenger, "chess_reader/evo_board/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isInstalled())
            "connect" -> connect(result)
            "disconnect" -> {
                disconnect()
                result.success(null)
            }
            "getFen" -> {
                val bound = service
                if (bound == null) {
                    result.error("not_connected", "Evo service is not connected.", null)
                    return
                }
                try {
                    result.success(bound.fen)
                } catch (e: Exception) {
                    result.error("remote", e.message, null)
                }
            }
            "setLed" -> setLed(call, result)
            else -> result.notImplemented()
        }
    }

    private fun isInstalled(): Boolean = try {
        context.packageManager.getPackageInfo(SERVICE_PACKAGE, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun connect(result: MethodChannel.Result) {
        if (service != null) {
            result.success(null)
            return
        }
        if (pendingConnect != null) {
            result.error("busy", "Already connecting to the Evo service.", null)
            return
        }
        val intent = Intent().setComponent(ComponentName(SERVICE_PACKAGE, SERVICE_CLASS))
        val started = try {
            context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            false
        }
        if (!started) {
            result.error("bind_failed", "The Chessnut Evo service is not available.", null)
            return
        }
        binding = true
        pendingConnect = result
        connectTimeout = Runnable { finishConnect("The Evo service did not answer.") }
        main.postDelayed(connectTimeout!!, CONNECT_TIMEOUT_MS)
    }

    private fun finishConnect(error: String?) {
        val result = pendingConnect ?: return
        pendingConnect = null
        connectTimeout?.let { main.removeCallbacks(it) }
        connectTimeout = null
        if (error == null) {
            result.success(null)
        } else {
            unbind()
            result.error("connect_failed", error, null)
        }
    }

    fun disconnect() {
        pendingConnect?.error("cancelled", "Disconnected.", null)
        pendingConnect = null
        connectTimeout?.let { main.removeCallbacks(it) }
        connectTimeout = null
        try {
            service?.unregisterChessBoardCallback(boardCallback)
        } catch (_: Exception) {
        }
        unbind()
    }

    private fun unbind() {
        service = null
        if (binding) {
            binding = false
            try {
                context.unbindService(connection)
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    private fun setLed(call: MethodCall, result: MethodChannel.Result) {
        val bound = service
        val on = call.argument<ByteArray>("on")
        val rgb = call.argument<ByteArray>("rgb")
        if (bound == null) {
            result.error("not_connected", "Evo service is not connected.", null)
            return
        }
        if (on == null || on.size != 64 || rgb == null || rgb.size != 192) {
            result.error("bad_args", "Expected 64 switches and 192 colour bytes.", null)
            return
        }
        val switches = BooleanArray(64) { on[it].toInt() != 0 }
        val r = ByteArray(64) { rgb[it * 3] }
        val g = ByteArray(64) { rgb[it * 3 + 1] }
        val b = ByteArray(64) { rgb[it * 3 + 2] }
        try {
            bound.setLed(switches, r, g, b)
            result.success(null)
        } catch (e: Exception) {
            result.error("remote", e.message, null)
        }
    }

    private companion object {
        const val SERVICE_PACKAGE = "com.chessnutech.chessnutevo.launcher"
        const val SERVICE_CLASS = "com.chessnutech.chessnutevo.chessnutservice.ChessnutService"
        const val CONNECT_TIMEOUT_MS = 8000L
    }
}
