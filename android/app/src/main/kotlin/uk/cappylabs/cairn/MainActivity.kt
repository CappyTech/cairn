package uk.cappylabs.cairn

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "uk.cappylabs.cairn/activity"
        const val REQUEST_ACTIVITY = 4201
    }

    // The Dart side waiting on an activity-recognition permission prompt.
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // The plugin is built for Android 8+ (API 26); see the manifest.
                    "available" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    "status" -> result.success(activityGranted())
                    "request" -> requestActivity(result)
                    else -> result.notImplemented()
                }
            }
    }

    // Activity recognition is a runtime permission from Android 10 (API 29);
    // before that it's granted at install.
    private fun activityGranted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestActivity(result: MethodChannel.Result) {
        if (activityGranted()) {
            result.success(true)
            return
        }
        pending?.success(false) // a prompt already open: superseded
        pending = result
        requestPermissions(arrayOf(Manifest.permission.ACTIVITY_RECOGNITION), REQUEST_ACTIVITY)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_ACTIVITY) return
        pending?.success(activityGranted())
        pending = null
    }
}
