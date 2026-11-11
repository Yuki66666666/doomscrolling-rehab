package tw.rehab.doomscroll_rehab

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val vpnRequest = 4201
    private var pending: MethodChannel.Result? = null
    private var pendingApps: ArrayList<String> = arrayListOf()

    // Feed apps the VPN can be applied to. Each also needs a <queries> entry in the manifest.
    private val knownApps = listOf(
        "com.instagram.android" to "Instagram",
        "com.instagram.barcelona" to "Threads",
        "com.ss.android.ugc.trill" to "TikTok",
        "com.zhiliaoapp.musically" to "TikTok",
        "com.phoenix.read" to "Hongguo",
        "com.ss.android.ugc.aweme" to "Douyin",
        "com.google.android.youtube" to "YouTube",
        "com.facebook.katana" to "Facebook",
        "com.android.chrome" to "Chrome (for testing)",
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rehab").setMethodCallHandler { call, result ->
            when (call.method) {
                "apps" -> result.success(knownApps.map { (pkg, label) ->
                    val installed = isInstalled(pkg)
                    mapOf(
                        "pkg" to pkg,
                        "label" to label,
                        "installed" to installed,
                        "icon" to if (installed) iconPng(pkg) else null,
                    )
                })

                "start" -> {
                    pendingApps = ArrayList(call.argument<List<String>>("apps") ?: emptyList())
                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        pending = result
                        startActivityForResult(intent, vpnRequest)
                    } else {
                        startVpn()
                        result.success(true)
                    }
                }

                "stop" -> {
                    startService(Intent(this, RehabVpnService::class.java).setAction(RehabVpnService.ACTION_STOP))
                    result.success(true)
                }

                "state" -> {
                    val snap = HashMap(Engine.snapshot(RehabVpnService.running, RehabVpnService.port))
                    snap["error"] = RehabVpnService.lastError
                    snap["appliedTo"] = RehabVpnService.appliedTo
                    result.success(snap)
                }

                "grant" -> result.success(
                    Engine.grant(call.argument<Int>("minutes") ?: 0, call.argument<String>("words") ?: ""),
                )

                "demo" -> {
                    if (call.argument<Boolean>("reset") == true) Engine.reset()
                    call.argument<Double>("timeScale")?.let { Engine.timeScale = it.coerceIn(1.0, 120.0) }
                    call.argument<Double>("addMinutes")?.let {
                        Engine.sessionMs = maxOf(0.0, Engine.sessionMs + it * 60000.0)
                        Engine.lastActive = System.currentTimeMillis()
                    }
                    call.argument<Int>("day")?.let { Engine.day = it.coerceIn(0, Engine.PLAN_DAYS - 1) }
                    result.success(true)
                }

                "plan" -> {
                    call.argument<Double>("startGraceMin")?.let { Engine.startGraceMin = it.coerceIn(2.0, 30.0) }
                    call.argument<Double>("dailyFactor")?.let { Engine.dailyFactor = it.coerceIn(0.85, 0.98) }
                    call.argument<Double>("rampMin")?.let { Engine.rampMin = it.coerceIn(5.0, 30.0) }
                    call.argument<Double>("floorKbps")?.let { Engine.floorKbps = it.coerceIn(20.0, 300.0) }
                    result.success(true)
                }

                // The profile the onboarding conversation produced, kept across launches.
                "prefGet" -> result.success(
                    getSharedPreferences("rehab", MODE_PRIVATE).getString(call.argument<String>("key") ?: "", null),
                )

                "prefSet" -> {
                    val editor = getSharedPreferences("rehab", MODE_PRIVATE).edit()
                    val value = call.argument<String>("value")
                    val key = call.argument<String>("key") ?: ""
                    if (value == null) editor.remove(key) else editor.putString(key, value)
                    editor.apply()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    // Demo hook for driving the session clock from a laptop during a recording:
    //   adb shell am start -n tw.rehab.doomscroll_rehab/.MainActivity --ef addMinutes 30
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra("reset", false)) Engine.reset()
        if (intent.hasExtra("timeScale")) {
            Engine.timeScale = intent.getFloatExtra("timeScale", 1f).toDouble().coerceIn(1.0, 120.0)
        }
        if (intent.hasExtra("addMinutes")) {
            Engine.sessionMs = maxOf(0.0, Engine.sessionMs + intent.getFloatExtra("addMinutes", 0f) * 60000.0)
            Engine.lastActive = System.currentTimeMillis()
        }
        if (intent.hasExtra("grant")) {
            Engine.grant(intent.getIntExtra("grant", 0), intent.getStringExtra("words") ?: "")
        }
    }

    /** The app's own launcher icon as PNG bytes, so people can pick by picture. */
    private fun iconPng(pkg: String): ByteArray? = try {
        val drawable = packageManager.getApplicationIcon(pkg)
        val size = 144
        val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val out = java.io.ByteArrayOutputStream()
        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
        out.toByteArray()
    } catch (e: Exception) {
        null
    }

    private fun isInstalled(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun startVpn() {
        startService(
            Intent(this, RehabVpnService::class.java)
                .putStringArrayListExtra(RehabVpnService.EXTRA_APPS, pendingApps)
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != vpnRequest) return
        val ok = resultCode == Activity.RESULT_OK
        if (ok) startVpn()
        pending?.success(ok)
        pending = null
    }
}
