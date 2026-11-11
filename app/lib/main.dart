import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('rehab');

// Set at build time with --dart-define-from-file=../.env
const _llmBase = String.fromEnvironment('LLM_BASE_URL');
const _llmKey = String.fromEnvironment('LLM_API_KEY');
const _llmModel = String.fromEnvironment('LLM_MODEL');
bool get _aiConfigured => _llmBase.isNotEmpty && _llmKey.isNotEmpty && _llmModel.isNotEmpty;

const _ease = Cubic(0.22, 1, 0.36, 1);

void main() => runApp(const RehabApp());

class Tokens {
  const Tokens({
    required this.bg,
    required this.surface,
    required this.text,
    required this.muted,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.bubble,
  });

  final Color bg, surface, text, muted, line, accent, onAccent, ok, warn, bad, bubble;

  static const light = Tokens(
    bg: Color(0xFFF6F7F8),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF15181C),
    muted: Color(0xFF5D6670),
    line: Color(0x3315181C),
    accent: Color(0xFF1F5FD6),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF1C7A4A),
    warn: Color(0xFFA35A00),
    bad: Color(0xFFB3261E),
    bubble: Color(0xFFEEF0F2),
  );

  static const dark = Tokens(
    bg: Color(0xFF101214),
    surface: Color(0xFF181B1F),
    text: Color(0xFFECEEF0),
    muted: Color(0xFF9AA3AD),
    line: Color(0x3DECEEF0),
    accent: Color(0xFF7FA8FF),
    onAccent: Color(0xFF0C1220),
    ok: Color(0xFF6FD3A0),
    warn: Color(0xFFF0B060),
    bad: Color(0xFFFF8A80),
    bubble: Color(0xFF22262B),
  );

  static Tokens of(BuildContext context) =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark ? dark : light;
}

class RehabApp extends StatelessWidget {
  const RehabApp({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final dark = identical(t, Tokens.dark);
    return MaterialApp(
      title: 'Doomscroll Rehab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: t.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: t.accent,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(primary: t.accent, onPrimary: t.onAccent, surface: t.surface),
        textTheme: const TextTheme().apply(bodyColor: t.text, displayColor: t.text),
        splashFactory: NoSplash.splashFactory,
      ),
      home: const HomePage(),
    );
  }
}

class ChatLine {
  ChatLine(this.kind, this.text);
  final String kind; // user, bot, note
  final String text;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, dynamic> s = {};
  List<Map<String, dynamic>> apps = [];
  final Set<String> chosen = {};
  final List<ChatLine> chat = [];
  final List<Map<String, String>> history = [];
  final input = TextEditingController();
  final scroll = ScrollController();
  Timer? timer;
  bool sending = false;
  bool starting = false;
  bool zh = false;

  /// Picks the English or Traditional Chinese string.
  String tr(String en, String zhText) => zh ? zhText : en;

  @override
  void initState() {
    super.initState();
    zh = WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    _loadApps();
    _poll();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    timer?.cancel();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('apps') ?? [];
    final list = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    setState(() {
      apps = list.where((a) => a['installed'] == true).toList();
      for (final a in apps) {
        if (a['pkg'] != 'com.android.chrome') chosen.add(a['pkg'] as String);
      }
    });
  }

  Future<void> _poll() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('state');
      if (raw != null && mounted) setState(() => s = Map<String, dynamic>.from(raw));
    } catch (_) {
      // channel not ready yet
    }
  }

  bool get running => s['running'] == true;

  Future<void> _toggle() async {
    setState(() => starting = true);
    if (running) {
      await _channel.invokeMethod('stop');
    } else {
      await _channel.invokeMethod('start', {'apps': chosen.toList()});
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _poll();
    if (mounted) setState(() => starting = false);
  }

  Future<void> _demo(Map<String, dynamic> args) async {
    await _channel.invokeMethod('demo', args);
    await _poll();
  }

  // ---------- negotiator ----------

  String _systemPrompt() {
    final kbps = s['kbps'];
    return [
      'You are the negotiator inside Doomscroll Rehab, an app that slows short-video feeds the longer someone scrolls.',
      'The user has been slowed down and is asking you for full speed back.',
      '',
      'Right now:',
      '- Scrolling this session: ${((s['sessionMin'] ?? 0) as num).round()} minutes',
      '- Current feed speed: ${kbps == null ? 'full speed' : '${(kbps as num).round()} kbps'}',
      '- Speed boosts already granted today: ${s['grantsToday'] ?? 0} of ${s['maxGrants'] ?? 3}',
      '- Day ${((s['day'] ?? 0) as num) + 1} of a 14-day taper',
      '',
      'How to talk (motivational interviewing):',
      '- Never lecture, never shame, never quote statistics.',
      '- Ask one short open question at a time so the user says in their own words what they want from the next few minutes.',
      '- Reflect their answer back in a few words.',
      '- If they give a specific reason and a specific stopping point, grant a boost. Grant less than they ask for when they are vague.',
      '- If they just say "because I want to", ask what they were hoping to feel, once. If they are still vague, grant nothing and offer one small alternative they could do in two minutes.',
      '- If all boosts for today are used, say so plainly and grant nothing.',
      zh
          ? '- Keep every reply under 60 Chinese characters. Reply in Traditional Chinese as used in Taiwan, unless the user writes in another language.'
          : '- Keep every reply under 45 words. Reply in the language the user writes in.',
      '',
      'Answer with JSON only, no other text: {"reply": "<what you say>", "grant_minutes": <integer 0 to 10>}',
    ].join('\n');
  }

  Future<(String, int)> _askModel() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final base = _llmBase.replaceAll(RegExp(r'/+$'), '');
      final req = await client.postUrl(Uri.parse('$base/chat/completions'));
      req.headers.set('content-type', 'application/json; charset=utf-8');
      req.headers.set('authorization', 'Bearer $_llmKey');
      req.add(utf8.encode(jsonEncode({
        'model': _llmModel,
        'messages': [
          {'role': 'system', 'content': _systemPrompt()},
          ...history,
        ],
        'temperature': 0.5,
        'max_tokens': 400,
      })));
      final res = await req.close().timeout(const Duration(seconds: 25));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      var text = (jsonDecode(body)['choices'][0]['message']['content'] ?? '').toString();
      text = text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
      final a = text.indexOf('{');
      final b = text.lastIndexOf('}');
      if (a != -1 && b > a) {
        final j = jsonDecode(text.substring(a, b + 1)) as Map<String, dynamic>;
        return ((j['reply'] ?? '').toString(), ((j['grant_minutes'] ?? 0) as num).round());
      }
      return (text, 0);
    } finally {
      client.close(force: true);
    }
  }

  (String, int) _scripted() {
    final used = (s['grantsToday'] ?? 0) as num;
    final max = (s['maxGrants'] ?? 3) as num;
    if (used >= max) {
      return (
        tr('You have used all $max boosts for today. The feed stays slow until tomorrow.',
            '今天的 $max 次全速都用完了，明天之前會維持慢速。'),
        0
      );
    }
    final turns = history.where((m) => m['role'] == 'user').length;
    if (turns <= 1) {
      return (tr('What do you want from the next few minutes on the feed?', '接下來這幾分鐘，你想從動態裡得到什麼？'), 0);
    }
    return (tr('Okay. Five minutes at full speed, then it slows again.', '好，給你五分鐘全速，之後會再慢下來。'), 5);
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    input.clear();
    setState(() {
      sending = true;
      chat.add(ChatLine('user', text));
      history.add({'role': 'user', 'content': text});
    });
    _scrollDown();

    var reply = '';
    var grant = 0;
    String? note;
    if (_aiConfigured) {
      try {
        (reply, grant) = await _askModel();
        if (reply.isEmpty) throw Exception('empty reply');
      } catch (e) {
        (reply, grant) = _scripted();
        note = tr('Model call failed, scripted reply shown. $e', '模型沒有回應，以下是預設回覆。$e');
      }
    } else {
      (reply, grant) = _scripted();
    }

    final granted = grant > 0 ? (await _channel.invokeMethod<int>('grant', {'minutes': grant}) ?? 0) : 0;
    await _poll();
    if (!mounted) return;
    setState(() {
      history.add({'role': 'assistant', 'content': reply});
      chat.add(ChatLine('bot', reply));
      if (note != null) chat.add(ChatLine('note', note));
      if (granted > 0) chat.add(ChatLine('note', tr('Full speed for $granted minutes', '全速 $granted 分鐘')));
      sending = false;
    });
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: _ease);
      }
    });
  }

  // ---------- view ----------

  String _fmtTime(num minutes) {
    final total = (minutes * 60).floor();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final stage = (s['stage'] ?? 'off') as String;
    final kbps = s['kbps'] as num?;
    final sessionMin = (s['sessionMin'] ?? 0) as num;
    final graceMin = (s['graceMin'] ?? 10) as num;
    final rampMin = (s['rampMin'] ?? 15) as num;
    final minKbps = (s['minKbps'] ?? 40) as num;
    final delayMs = (s['connectDelayMs'] ?? 0) as num;
    final timeScale = (s['timeScale'] ?? 1) as num;
    final hosts = ((s['hosts'] ?? []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final error = s['error'] as String?;

    final stageText = {
      'off': tr('Off', '未開啟'),
      'idle': tr('On, waiting for a feed', '已開啟，等你打開動態'),
      'full': tr('Full speed', '全速'),
      'slowing': tr('Slowing down', '正在變慢'),
      'floor': tr('At the floor', '已降到最慢'),
      'boost': tr('Boost active', '全速時段'),
    };
    final stageColor = switch (stage) {
      'full' || 'boost' => t.ok,
      'slowing' => t.warn,
      'floor' => t.bad,
      _ => t.muted,
    };
    final speedText = !running
        ? tr('Off', '未開啟')
        : kbps == null
            ? tr('Full', '全速')
            : kbps >= 1000
                ? '${(kbps / 1000).toStringAsFixed(1)} Mbps'
                : '${kbps.round()} kbps';

    final small = TextStyle(fontSize: 14, height: 1.5, color: t.muted, fontWeight: FontWeight.w400);
    final body = TextStyle(fontSize: 16, height: 1.7, color: t.text, fontWeight: FontWeight.w400);
    final h2 = TextStyle(fontSize: 16, height: 1.5, color: t.text, fontWeight: FontWeight.w500);
    final stat = TextStyle(
      fontSize: 36,
      height: 1.2,
      color: t.text,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget card(List<Widget> children) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.line, width: 0.5),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        );

    Widget plain(String label, VoidCallback? onTap, {bool on = false}) => OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: t.text,
            side: BorderSide(color: on ? t.text : t.line, width: on ? 1 : 0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.w500 : FontWeight.w400),
          ),
          child: Text(label),
        );

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text('Doomscroll Rehab',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: t.text)),
                ),
                Text(
                  stage == 'boost'
                      ? tr('Boost, ${s['boostLeftSec']} s left', '全速時段，剩 ${s['boostLeftSec']} 秒')
                      : (stageText[stage] ?? stage),
                  style: TextStyle(fontSize: 14, color: stageColor),
                ),
                const SizedBox(width: 12),
                plain(zh ? 'EN' : '中文', () => setState(() => zh = !zh)),
              ],
            ),
            const SizedBox(height: 16),
            card([
              Text(tr('Feed speed', '動態網速'), style: small),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                curve: _ease,
                style: stat,
                child: Text(speedText),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Scrolling this session', '這次已滑'), style: small),
                    Text(_fmtTime(sessionMin), style: stat.copyWith(fontSize: 28)),
                  ]),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Wait per new video', '每支新影片多等'), style: small),
                    Text('${(delayMs / 1000).toStringAsFixed(1)} ${tr('s', '秒')}', style: stat.copyWith(fontSize: 28)),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                height: 120,
                width: double.infinity,
                child: CustomPaint(
                  painter: CurvePainter(
                    sessionMin: sessionMin.toDouble(),
                    graceMin: graceMin.toDouble(),
                    rampMin: rampMin.toDouble(),
                    line: t.text,
                    faint: t.line,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Full speed for the first ${graceMin.toStringAsFixed(1)} minutes, then slower every minute down to ${minKbps.round()} kbps.',
                  '前 ${graceMin.toStringAsFixed(1)} 分鐘全速，之後每分鐘更慢，最低降到 ${minKbps.round()} kbps。',
                ),
                style: small,
              ),
            ]),
            card([
              Text(running ? tr('Slowing these apps', '正在放慢這些 App') : tr('Apps to slow', '要放慢的 App'), style: h2),
              const SizedBox(height: 8),
              if (apps.isEmpty)
                Text(tr('No supported feed app is installed on this phone.', '這支手機沒有安裝支援的短影音 App。'), style: small),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in apps)
                    plain(
                      a['pkg'] == 'com.android.chrome' ? tr('Chrome (for testing)', 'Chrome（測試用）') : a['label'] as String,
                      running
                          ? null
                          : () => setState(() {
                                final pkg = a['pkg'] as String;
                                chosen.contains(pkg) ? chosen.remove(pkg) : chosen.add(pkg);
                              }),
                      on: chosen.contains(a['pkg']),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: starting || (!running && chosen.isEmpty) ? null : _toggle,
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: t.onAccent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  child: Text(running ? tr('Turn off', '關閉') : tr('Turn on', '開啟')),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error, style: small.copyWith(color: t.bad)),
              ],
              const SizedBox(height: 8),
              Text(
                tr(
                  'Uses a local VPN that stays on this phone. It sees which servers the chosen apps talk to, never what they send.',
                  '使用只在這支手機上運作的本機 VPN。它只看得到這些 App 連到哪些伺服器，看不到傳送的內容。',
                ),
                style: small,
              ),
            ]),
            card([
              Text(tr('Ask for full speed', '想要回全速'), style: h2),
              Text(
                _aiConfigured
                    ? tr('Negotiator model: $_llmModel', '談判模型：$_llmModel')
                    : tr('No model configured in this build. Replies are scripted.', '這個版本沒有接上模型，以下是預設回覆。'),
                style: small,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView(
                  controller: scroll,
                  shrinkWrap: true,
                  children: [
                    for (final m in chat)
                      Align(
                        alignment: m.kind == 'user'
                            ? Alignment.centerRight
                            : m.kind == 'note'
                                ? Alignment.center
                                : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: m.kind == 'note'
                              ? EdgeInsets.zero
                              : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          constraints: const BoxConstraints(maxWidth: 280),
                          decoration: m.kind == 'note'
                              ? null
                              : BoxDecoration(
                                  color: m.kind == 'bot' ? t.bubble : null,
                                  border: m.kind == 'user' ? Border.all(color: t.line, width: 0.5) : null,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                          child: Text(m.text, style: m.kind == 'note' ? small : body.copyWith(height: 1.5)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    onSubmitted: (_) => _send(),
                    style: body.copyWith(height: 1.3),
                    decoration: InputDecoration(
                      hintText: tr('Why do you want it back?', '為什麼想要回全速？'),
                      hintStyle: body.copyWith(color: t.muted, height: 1.3),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.line, width: 0.5),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: t.accent, width: 2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                plain(sending ? tr('Thinking', '思考中') : tr('Send', '送出'), sending ? null : _send, on: true),
              ]),
              const SizedBox(height: 8),
              Text(
                tr('${s['grantsToday'] ?? 0} of ${s['maxGrants'] ?? 3} boosts used today',
                    '今天已用 ${s['grantsToday'] ?? 0} 次全速，共 ${s['maxGrants'] ?? 3} 次'),
                style: small,
              ),
            ]),
            card([
              Text(tr('What the feed apps are loading', '這些 App 正在連的伺服器'), style: h2),
              Text(tr('Server names only.', '只有伺服器名稱。'), style: small),
              const SizedBox(height: 8),
              if (hosts.isEmpty) Text(tr('Nothing yet. Turn it on and open a feed.', '還沒有資料。開啟後打開任一個動態。'), style: small),
              for (final h in hosts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text(h['host'] as String, style: small.copyWith(color: t.text))),
                    Text(
                      (h['kb'] as num) >= 1024
                          ? '${((h['kb'] as num) / 1024).toStringAsFixed(1)} MB'
                          : '${h['kb']} KB',
                      style: small,
                    ),
                  ]),
                ),
            ]),
            card([
              Text(tr('Demo controls', '展示控制'), style: h2),
              Text(tr('Clock speed, so a twenty-minute session fits in a short demo.', '調快時鐘，讓二十分鐘的過程能在短時間內展示完。'),
                  style: small),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final x in const [1, 10, 30, 60])
                  plain(x == 1 ? tr('Real time', '正常速度') : '${x}x', () => _demo({'timeScale': x.toDouble()}),
                      on: timeScale.round() == x),
                plain(tr('Skip ahead 5 min', '快轉 5 分鐘'), () => _demo({'addMinutes': 5.0})),
                plain(tr('Reset session', '重設'), () {
                  setState(() {
                    chat.clear();
                    history.clear();
                  });
                  _demo({'reset': true});
                }),
              ]),
            ]),
          ],
        ),
      ),
    );
  }
}

class CurvePainter extends CustomPainter {
  CurvePainter({
    required this.sessionMin,
    required this.graceMin,
    required this.rampMin,
    required this.line,
    required this.faint,
  });

  final double sessionMin, graceMin, rampMin;
  final Color line, faint;

  @override
  void paint(Canvas canvas, Size size) {
    final span = graceMin + rampMin + 5;
    double x(double m) => size.width * (m / span).clamp(0.0, 1.0);
    const top = 8.0;
    final bottom = size.height - 12;

    final axis = Paint()
      ..color = faint
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 1), Offset(size.width, size.height - 1), axis);
    canvas.drawLine(Offset(x(graceMin), top), Offset(x(graceMin), size.height - 1), axis);

    final path = Path()
      ..moveTo(0, top)
      ..lineTo(x(graceMin), top)
      ..lineTo(x(graceMin + rampMin), bottom)
      ..lineTo(size.width, bottom);
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    final m = sessionMin.clamp(0.0, span);
    var y = top;
    if (m > graceMin) {
      final t = ((m - graceMin) / rampMin).clamp(0.0, 1.0);
      y = top + (bottom - top) * t;
    }
    canvas.drawCircle(Offset(x(m), y), 6, Paint()..color = line);
  }

  @override
  bool shouldRepaint(CurvePainter old) =>
      old.sessionMin != sessionMin || old.graceMin != graceMin || old.rampMin != rampMin;
}
