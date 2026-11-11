package tw.rehab.doomscroll_rehab

import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/**
 * A small HTTP proxy that lives inside the app, on 127.0.0.1.
 * The VPN tells the chosen feed apps to use it, so everything that arrives here is feed traffic.
 * HTTPS goes through CONNECT tunnels: we see the hostname and the byte count, never the content.
 */
class ThrottleProxy(private val protect: (Socket) -> Unit) {
    private var server: ServerSocket? = null
    private var pool: ExecutorService? = null
    @Volatile private var running = false

    val port: Int get() = server?.localPort ?: 0

    fun start() {
        val s = ServerSocket(0, 100, InetAddress.getByName("127.0.0.1"))
        server = s
        val p = Executors.newCachedThreadPool { r -> Thread(r, "rehab-proxy").apply { isDaemon = true } }
        pool = p
        running = true
        p.execute {
            while (running) {
                try {
                    val client = s.accept()
                    p.execute { handle(client) }
                } catch (e: Exception) {
                    if (running) continue else break
                }
            }
        }
    }

    fun stop() {
        running = false
        try { server?.close() } catch (e: Exception) {}
        pool?.shutdownNow()
        server = null
        pool = null
    }

    private fun readHead(inp: InputStream): String? {
        val sb = StringBuilder()
        var matched = 0
        while (sb.length < 16384) {
            val b = inp.read()
            if (b < 0) return null
            sb.append(b.toChar())
            matched = when {
                b == '\r'.code && (matched == 0 || matched == 2) -> matched + 1
                b == '\n'.code && (matched == 1 || matched == 3) -> matched + 1
                else -> 0
            }
            if (matched == 4) return sb.toString()
        }
        return null
    }

    private fun handle(client: Socket) {
        var upstream: Socket? = null
        try {
            client.tcpNoDelay = true
            val cin = client.getInputStream()
            val cout = client.getOutputStream()
            val head = readHead(cin) ?: return
            val firstLine = head.substringBefore("\r\n")
            val parts = firstLine.split(' ')
            if (parts.size < 3) return
            val method = parts[0]
            val host: String
            val port: Int
            var forward: ByteArray? = null

            if (method.equals("CONNECT", ignoreCase = true)) {
                val hp = parts[1]
                host = hp.substringBeforeLast(':').trim('[', ']').lowercase()
                port = hp.substringAfterLast(':').toIntOrNull() ?: 443
            } else {
                val uri = URI(parts[1])
                host = (uri.host ?: return).lowercase()
                port = if (uri.port > 0) uri.port else 80
                val path = (uri.rawPath?.ifEmpty { "/" } ?: "/") + (uri.rawQuery?.let { "?$it" } ?: "")
                val rest = head.substringAfter("\r\n")
                    .split("\r\n")
                    .filterNot { it.startsWith("Proxy-Connection", ignoreCase = true) }
                    .joinToString("\r\n")
                forward = ("$method $path ${parts[2]}\r\n$rest").toByteArray(Charsets.ISO_8859_1)
            }

            Engine.lastActive = System.currentTimeMillis()
            val delay = Engine.connectDelayMs()
            if (delay > 0) Thread.sleep(delay)

            val up = Socket()
            upstream = up
            protect(up)
            up.tcpNoDelay = true
            up.connect(InetSocketAddress(host, port), 10000)
            val uin = up.getInputStream()
            val uout = up.getOutputStream()

            if (forward == null) {
                cout.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                cout.flush()
            } else {
                uout.write(forward)
                uout.flush()
            }

            val upPump = Thread({
                try { pumpPlain(cin, uout) } catch (e: Exception) {}
                closeQuietly(up)
                closeQuietly(client)
            }, "rehab-up")
            upPump.isDaemon = true
            upPump.start()

            pumpThrottled(uin, cout, host)
        } catch (e: Exception) {
            // connection ended; nothing to report
        } finally {
            closeQuietly(upstream)
            closeQuietly(client)
        }
    }

    private fun pumpPlain(inp: InputStream, out: OutputStream) {
        val buf = ByteArray(16384)
        while (true) {
            val n = inp.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            out.flush()
        }
    }

    private fun pumpThrottled(inp: InputStream, out: OutputStream, host: String) {
        val buf = ByteArray(16384)
        while (true) {
            val n = inp.read(buf)
            if (n < 0) break
            var off = 0
            while (off < n) {
                val rate = Engine.currentRate()
                val piece = if (rate.isInfinite()) n - off else min(n - off, max(256, (rate / 8).toInt()))
                Engine.take(piece)
                out.write(buf, off, piece)
                out.flush()
                Engine.note(host, piece)
                off += piece
            }
        }
    }

    private fun closeQuietly(s: Socket?) {
        try { s?.close() } catch (e: Exception) {}
    }
}
