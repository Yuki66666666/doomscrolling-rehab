package tw.rehab.doomscroll_rehab

import android.content.Intent
import android.content.pm.PackageManager
import android.net.ProxyInfo
import android.net.VpnService
import android.os.ParcelFileDescriptor

/**
 * A local VPN that carries no traffic of its own. It exists to do two things Android only
 * lets a VPN do: apply to chosen apps only, and tell those apps to use our in-app proxy.
 * Nothing leaves the phone through us; the proxy connects straight to the real servers.
 */
class RehabVpnService : VpnService() {
    companion object {
        const val ACTION_STOP = "tw.rehab.STOP"
        const val EXTRA_APPS = "apps"
        @Volatile var running = false
        @Volatile var port = 0
        @Volatile var lastError: String? = null
        @Volatile var appliedTo: List<String> = emptyList()
    }

    private var tun: ParcelFileDescriptor? = null
    private var proxy: ThrottleProxy? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutdown()
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_STICKY
        lastError = null
        try {
            val p = ThrottleProxy { socket -> protect(socket) }
            p.start()
            proxy = p
            port = p.port

            val builder = Builder()
                .setSession("Doomscroll Rehab")
                .addAddress("10.111.0.2", 32)
                // One unused address, so no real traffic is routed into the tunnel.
                .addRoute("10.111.0.1", 32)
                .setHttpProxy(ProxyInfo.buildDirectProxy("127.0.0.1", p.port))

            val applied = ArrayList<String>()
            for (pkg in intent?.getStringArrayListExtra(EXTRA_APPS) ?: arrayListOf()) {
                try {
                    builder.addAllowedApplication(pkg)
                    applied.add(pkg)
                } catch (e: PackageManager.NameNotFoundException) {
                    // not installed
                }
            }
            if (applied.isEmpty()) {
                // With no allowed app the VPN would apply to the whole phone. Refuse instead.
                throw IllegalStateException("None of the chosen apps is installed")
            }
            appliedTo = applied

            tun = builder.establish() ?: throw IllegalStateException("VPN permission was not granted")
            Engine.startTicker()
            running = true
        } catch (e: Exception) {
            lastError = e.message ?: e.toString()
            shutdown()
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun shutdown() {
        running = false
        try { tun?.close() } catch (e: Exception) {}
        tun = null
        proxy?.stop()
        proxy = null
        port = 0
        appliedTo = emptyList()
        Engine.stopTicker()
    }

    override fun onRevoke() {
        shutdown()
        super.onRevoke()
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }
}
