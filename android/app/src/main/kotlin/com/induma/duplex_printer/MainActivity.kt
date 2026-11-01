package com.induma.duplex_printer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Accepts PDFs from other apps ("Open with" / "Share") and hands them to
 * Flutter as a cached file path over the `flipprint/files` channel, and runs
 * [PrintService] over `flipprint/print` so prints survive leaving the app.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pending = fileFrom(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flipprint/files").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "getInitialFile") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flipprint/print")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        askForNotifications()
                        try {
                            startForegroundService(serviceIntent(call.arguments()))
                        } catch (e: Exception) {
                            return@setMethodCallHandler result.error("service", e.message, null)
                        }
                    }
                    "update" -> PrintService.update(this, serviceIntent(call.arguments()))
                    "stop" -> startService(
                        serviceIntent(call.arguments()).setAction(PrintService.ACTION_STOP),
                    )
                    "alert" -> PrintService.alert(
                        this, call.argument<String>("title") ?: "", call.argument<String>("text") ?: "",
                    )
                    "clearAlert" -> PrintService.clearAlert(this)
                    else -> return@setMethodCallHandler result.notImplemented()
                }
                result.success(null)
            }
    }

    /** Back on the last screen hides FlipPrint instead of closing it, so a
     *  print in progress (or waiting for the flip) is still there later. */
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    private fun serviceIntent(args: Map<String, Any?>?) =
        Intent(this, PrintService::class.java).apply {
            args?.forEach { (k, v) ->
                when (v) {
                    is String -> putExtra(k, v)
                    is Int -> putExtra(k, v)
                }
            }
        }

    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        fileFrom(intent)?.let { channel?.invokeMethod("openFile", it) }
    }

    private fun fileFrom(intent: Intent?): Map<String, String>? {
        val uri: Uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            else -> null
        } ?: return null

        return try {
            val name = displayName(uri) ?: "Document.pdf"
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            dir.listFiles()?.forEach { it.delete() }
            val out = File(dir, name.replace(Regex("[^\\w.\\- ]"), "_"))
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { input.copyTo(it) }
            } ?: return null
            mapOf("name" to name, "path" to out.absolutePath)
        } catch (e: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
}
