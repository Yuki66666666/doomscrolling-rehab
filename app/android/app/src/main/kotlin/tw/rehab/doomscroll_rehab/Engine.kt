package tw.rehab.doomscroll_rehab

import java.util.concurrent.ConcurrentHashMap
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Session clock, taper plan and the shared token bucket.
 * Same rules as server.js in the repo root, so the laptop demo and the app behave alike.
 */
object Engine {
    const val MAX_KBPS = 3000.0
    const val PLAN_DAYS = 14
    const val MAX_DELAY_MS = 3000
    const val MAX_GRANTS = 3
    const val MAX_GRANT_MIN = 10
    private const val ACTIVE_WINDOW_MS = 8000L
    private const val IDLE_RESET_MS = 600_000.0

    // The taper plan. The coach rewrites these four per person.
    @Volatile var startGraceMin = 10.0
    @Volatile var dailyFactor = 0.93
    @Volatile var rampMin = 15.0
    @Volatile var floorKbps = 40.0

    @Volatile var sessionMs = 0.0
    @Volatile var lastActive = 0L
    @Volatile var boostUntil = 0L
    @Volatile var timeScale = 1.0
    @Volatile var day = 0
    @Volatile var grantsToday = 0

    class HostStat(@Volatile var bytes: Long, @Volatile var last: Long)
    val hosts = ConcurrentHashMap<String, HostStat>()

    private val lock = Any()
    private var tokens = 0.0
    private var lastRefill = System.currentTimeMillis()
    @Volatile private var ticker: Thread? = null

    fun graceFor(d: Int): Double = max(1.0, startGraceMin * dailyFactor.pow(d))
    fun boosted(): Boolean = System.currentTimeMillis() < boostUntil
    fun inGrace(): Boolean = sessionMs / 60000.0 < graceFor(day)
    fun isActive(): Boolean = System.currentTimeMillis() - lastActive < ACTIVE_WINDOW_MS

    /** 0 during the full-speed window, then 0..1 along the ramp. */
    fun progress(): Double {
        val m = sessionMs / 60000.0
        val g = graceFor(day)
        return if (m < g) 0.0 else min(1.0, (m - g) / rampMin)
    }

    fun currentKbps(): Double =
        if (boosted() || inGrace()) Double.POSITIVE_INFINITY
        else exp(ln(MAX_KBPS) + (ln(floorKbps) - ln(MAX_KBPS)) * progress())

    /** Bytes per second, or infinity. */
    fun currentRate(): Double {
        val k = currentKbps()
        return if (k.isInfinite()) k else k * 1000.0 / 8.0
    }

    fun connectDelayMs(): Long =
        if (boosted() || inGrace()) 0L else (progress() * MAX_DELAY_MS).toLong()

    private fun idleResetMs(): Double = max(20000.0, IDLE_RESET_MS / timeScale)

    fun note(host: String, n: Int) {
        val now = System.currentTimeMillis()
        val s = hosts.getOrPut(host) { HostStat(0, now) }
        s.bytes += n
        s.last = now
        lastActive = now
        if (hosts.size > 300) {
            hosts.entries.minByOrNull { it.value.last }?.let { hosts.remove(it.key) }
        }
    }

    /** Blocks until n bytes may be sent. One bucket for every connection. */
    fun take(n: Int) {
        synchronized(lock) {
            while (true) {
                val rate = currentRate()
                val now = System.currentTimeMillis()
                if (rate.isInfinite()) {
                    tokens = 0.0
                    lastRefill = now
                    return
                }
                val cap = max(rate, n.toDouble())
                tokens = min(cap, tokens + (now - lastRefill) / 1000.0 * rate)
                lastRefill = now
                if (tokens >= n) {
                    tokens -= n
                    return
                }
                val wait = ((n - tokens) / rate * 1000.0).toLong().coerceIn(10L, 250L)
                try {
                    Thread.sleep(wait)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }
            }
        }
    }

    fun grant(minutes: Int): Int {
        if (grantsToday >= MAX_GRANTS) return 0
        val m = minutes.coerceIn(0, MAX_GRANT_MIN)
        if (m == 0) return 0
        grantsToday += 1
        boostUntil = System.currentTimeMillis() + max(20000.0, m * 60000.0 / timeScale).toLong()
        return m
    }

    fun reset() {
        sessionMs = 0.0
        boostUntil = 0L
        grantsToday = 0
    }

    fun startTicker() {
        if (ticker != null) return
        val t = Thread {
            var last = System.currentTimeMillis()
            while (!Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(250)
                } catch (e: InterruptedException) {
                    break
                }
                val now = System.currentTimeMillis()
                val dt = now - last
                last = now
                if (isActive()) {
                    if (!boosted()) sessionMs += dt * timeScale
                } else if (sessionMs > 0 && now - lastActive > idleResetMs()) {
                    sessionMs = 0.0
                }
            }
        }
        t.isDaemon = true
        t.name = "rehab-ticker"
        ticker = t
        t.start()
    }

    fun stopTicker() {
        ticker?.interrupt()
        ticker = null
    }

    fun stage(running: Boolean): String = when {
        !running -> "off"
        boosted() -> "boost"
        sessionMs == 0.0 && !isActive() -> "idle"
        inGrace() -> "full"
        progress() >= 1.0 -> "floor"
        else -> "slowing"
    }

    fun snapshot(running: Boolean, port: Int): Map<String, Any?> {
        val now = System.currentTimeMillis()
        val k = currentKbps()
        val top = hosts.entries
            .filter { now - it.value.last < 120_000 }
            .sortedByDescending { it.value.bytes }
            .take(8)
            .map { mapOf("host" to it.key, "kb" to (it.value.bytes / 1024).toInt()) }
        return mapOf(
            "running" to running,
            "stage" to stage(running),
            "sessionMin" to sessionMs / 60000.0,
            "graceMin" to graceFor(day),
            "rampMin" to rampMin,
            "kbps" to if (k.isInfinite()) null else k,
            "minKbps" to floorKbps,
            "maxKbps" to MAX_KBPS,
            "connectDelayMs" to connectDelayMs().toInt(),
            "boostLeftSec" to if (boosted()) ((boostUntil - now) / 1000).toInt() + 1 else 0,
            "timeScale" to timeScale,
            "day" to day,
            "plan" to (0 until PLAN_DAYS).map { graceFor(it) },
            "grantsToday" to grantsToday,
            "maxGrants" to MAX_GRANTS,
            "hosts" to top,
            "port" to port,
        )
    }
}
