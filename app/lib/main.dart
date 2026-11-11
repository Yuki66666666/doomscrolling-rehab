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
const _chromePkg = 'com.android.chrome';

class Option {
  const Option(this.key, this.en, this.zh);
  final String key, en, zh;
}

class Question {
  const Question(this.key, this.en, this.zh, this.options, {this.multi = true});
  final String key, en, zh;
  final List<Option> options;
  final bool multi; // several answers can be ticked
}

// Setup is one question per screen, answered with a tap. No typing.
const _questions = [
  Question('length', 'How long do you usually scroll at a time?', '你一次通常滑多久？', [
    Option('15', 'About 15 minutes', '大約 15 分鐘'),
    Option('30', 'About half an hour', '大約半小時'),
    Option('60', 'About an hour', '大約一小時'),
    Option('120', 'Two hours or more', '兩小時以上'),
  ], multi: false),
  Question('when', 'When is it hardest to stop?', '什麼時候最難停下來？', [
    Option('morning', 'Right after waking up', '早上剛起床'),
    Option('day', 'During work or class', '上班或上課的時候'),
    Option('evening', 'After work', '下班回家後'),
    Option('bed', 'In bed before sleep', '睡前躺在床上'),
  ]),
  Question('tried', 'Have you tried to cut back before?', '以前試過少滑一點嗎？', [
    Option('never', 'Not really', '沒有特別試過'),
    Option('limit', 'Set a time limit, then ignored it', '設過時間限制，但都直接略過'),
    Option('blocker', 'Used a blocker app, then removed it', '裝過鎖 App 的工具，後來刪了'),
    Option('deleted', 'Deleted the app, then came back', '把 App 刪掉過，後來又裝回來'),
  ]),
  Question('instead', 'What would you rather do with that time?', '那段時間你比較想拿來做什麼？', [
    Option('sleep', 'Sleep earlier', '早點睡'),
    Option('people', 'Be with family or friends', '陪家人或朋友'),
    Option('move', 'Exercise or go outside', '運動或出門走走'),
    Option('focus', 'Read, study or finish my work', '看書、學東西或把事情做完'),
  ]),
];

/// The ghost who does the talking.
Widget _ghost(double size) => ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.asset('assets/ghost.png', width: size, height: size),
    );

/// Shows its child once, growing from 80 percent with a small overshoot. Untappable until it starts.
class PopIn extends StatefulWidget {
  const PopIn({super.key, required this.child, this.delayMs = 0, this.alignment = Alignment.centerLeft});
  final Widget child;
  final int delayMs;
  final Alignment alignment;

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer(Duration(milliseconds: widget.delayMs), () {
      if (mounted) c.forward();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: c,
        child: widget.child,
        builder: (context, child) => IgnorePointer(
          ignoring: c.value == 0,
          child: Opacity(
            opacity: Curves.easeOut.transform(c.value),
            child: Transform.scale(
              scale: 0.8 + 0.2 * Curves.easeOutBack.transform(c.value),
              alignment: widget.alignment,
              child: child,
            ),
          ),
        ),
      );
}

/// Three dots that take turns lifting, the way a chat shows someone typing.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, required this.color});
  final Color color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: c,
        builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: Transform.translate(
                // each dot rises during its own third of the loop
                offset: Offset(0, -5 * _lift((c.value - i * 0.18) % 1.0)),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
                ),
              ),
            ),
        ]),
      );

  double _lift(double t) => t < 0.4 ? Curves.easeInOut.transform(t < 0.2 ? t / 0.2 : (0.4 - t) / 0.2) : 0;
}

/// One thing the ghost says: the ghost appears, types for a moment, then the bubble pops in.
class GhostLine extends StatefulWidget {
  const GhostLine({
    super.key,
    required this.child,
    required this.bubbleColor,
    required this.dotColor,
    this.delayMs = 250,
    this.typingMs = 650,
    this.avatar = 40,
  });
  final Widget child;
  final Color bubbleColor, dotColor;
  final int delayMs, typingMs;
  final double avatar;

  @override
  State<GhostLine> createState() => _GhostLineState();
}

class _GhostLineState extends State<GhostLine> {
  int phase = 0; // 0 not yet, 1 typing, 2 said
  final timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    timers.add(Timer(Duration(milliseconds: widget.delayMs), () {
      if (mounted) setState(() => phase = 1);
    }));
    timers.add(Timer(Duration(milliseconds: widget.delayMs + widget.typingMs), () {
      if (mounted) setState(() => phase = 2);
    }));
  }

  @override
  void dispose() {
    for (final t in timers) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (phase == 0) return const SizedBox.shrink();
    Widget bubble(Widget inner) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: widget.bubbleColor, borderRadius: BorderRadius.circular(16)),
          child: inner,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, right: 32),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PopIn(key: const ValueKey('avatar'), alignment: Alignment.bottomCenter, child: _ghost(widget.avatar)),
        const SizedBox(width: 8),
        Flexible(
          child: phase == 1
              ? bubble(TypingDots(color: widget.dotColor))
              : PopIn(key: const ValueKey('said'), alignment: Alignment.topLeft, child: bubble(widget.child)),
        ),
      ]),
    );
  }
}

/// The one filled button. Pressing it shrinks and darkens it; letting go springs it back past
/// full size before it settles, with a tick you can feel and hear.
class PressButton extends StatefulWidget {
  const PressButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.color,
    required this.onColor,
    required this.pressedColor,
    required this.offColor,
    required this.onOffColor,
  });
  final String label;
  final VoidCallback? onTap;
  final Color color, onColor, pressedColor, offColor, onOffColor;

  @override
  State<PressButton> createState() => _PressButtonState();
}

class _PressButtonState extends State<PressButton> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 380),
  );
  // easeInBack run backwards dips below zero at the end, which is the overshoot
  late final Animation<double> press = CurvedAnimation(parent: c, curve: _ease, reverseCurve: Curves.easeInBack);

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Future<void> _release() async {
    // a quick tap still shows the whole press before it springs back
    try {
      await c.forward();
      if (mounted) await c.reverse();
    } on TickerCanceled {
      // the button left the screen mid-press
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled
            ? (_) {
                HapticFeedback.lightImpact();
                c.forward();
              }
            : null,
        onTapCancel: enabled ? () => c.reverse() : null,
        onTap: enabled
            ? () {
                SystemSound.play(SystemSoundType.click);
                _release();
                widget.onTap!();
              }
            : null,
        child: AnimatedBuilder(
          animation: press,
          builder: (context, _) => Transform.scale(
            scale: 1 - 0.05 * press.value,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: _ease,
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: enabled
                    ? Color.lerp(widget.color, widget.pressedColor, press.value.clamp(0.0, 1.0))
                    : widget.offColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 18,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  color: enabled ? widget.onColor : widget.onOffColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() => runApp(const RehabApp());

/// Colours from the app icon: lavender white and deep plum, the spinner's violet as the
/// second colour, and its magenta kept for the one main button on each screen.
class Tokens {
  const Tokens({
    required this.bg,
    required this.surface,
    required this.text,
    required this.muted,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.accentPressed,
    required this.second,
    required this.onSecond,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.bubble,
  });

  final Color bg, surface, text, muted, line, accent, onAccent, accentPressed, second, onSecond, ok, warn, bad, bubble;

  static const light = Tokens(
    bg: Color(0xFFFAF5FF),
    surface: Color(0xFFFEFCFF),
    text: Color(0xFF2E1A47),
    muted: Color(0xFF5F4E7A),
    line: Color(0x332E1A47),
    accent: Color(0xFFFF2DD0),
    onAccent: Color(0xFF2E1A47),
    accentPressed: Color(0xFFE01FB6),
    second: Color(0xFF6D4BC3),
    onSecond: Color(0xFFFAF5FF),
    ok: Color(0xFF1C7A4A),
    warn: Color(0xFF9A5200),
    bad: Color(0xFFB3261E),
    bubble: Color(0xFFEDE9FE),
  );

  static const dark = Tokens(
    bg: Color(0xFF0A0B18),
    surface: Color(0xFF14152A),
    text: Color(0xFFF3EEFF),
    muted: Color(0xFFA9A2C4),
    line: Color(0x3DF3EEFF),
    accent: Color(0xFFFF4FD8),
    onAccent: Color(0xFF1A0B2E),
    accentPressed: Color(0xFFE03BBD),
    second: Color(0xFF6D4BC3),
    onSecond: Color(0xFFF3EEFF),
    ok: Color(0xFF6FD3A0),
    warn: Color(0xFFF0B060),
    bad: Color(0xFFFF8A80),
    bubble: Color(0xFF22224A),
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
        ).copyWith(
          primary: t.second,
          onPrimary: t.onSecond,
          secondary: t.second,
          onSecondary: t.onSecond,
          surface: t.surface,
          onSurface: t.text,
        ),
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
  Timer? timer;
  bool zh = false;
  bool loaded = false;
  bool starting = false;
  bool showDetails = false;

  // Setup: step 0 picks the apps, steps 1..n are the questions, the last step shows the plan
  bool onboarded = false;
  int step = 0;
  final Map<String, String> answers = {};
  bool planning = false;
  bool planFromModel = false;
  String planNote = '';
  String instead = '';
  Map<String, double> planNums = {};

  // Negotiator
  final List<ChatLine> chat = [];
  final List<Map<String, String>> history = [];
  final input = TextEditingController();
  final scroll = ScrollController();
  bool sending = false;
  int wordsFrom = 0; // history index where the current negotiation started

  // Report
  bool reportBusy = false;
  String reportText = '';

  /// Picks the English or Traditional Chinese string.
  String tr(String en, String zhText) => zh ? zhText : en;

  String get _languageRule =>
      zh ? 'Write in Traditional Chinese as used in Taiwan.' : 'Write in English.';

  @override
  void initState() {
    super.initState();
    zh = WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    _init();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    timer?.cancel();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('apps') ?? [];
      apps = raw.map((e) => Map<String, dynamic>.from(e as Map)).where((a) => a['installed'] == true).toList();
    } catch (_) {
      apps = [];
    }
    try {
      final saved = await _channel.invokeMethod<String>('prefGet', {'key': 'profile'});
      if (saved != null) {
        final p = jsonDecode(saved) as Map<String, dynamic>;
        zh = p['zh'] == true;
        planNote = (p['planNote'] ?? '').toString();
        instead = (p['instead'] ?? '').toString();
        planNums = ((p['plan'] ?? {}) as Map).map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
        final installed = apps.map((a) => a['pkg']).toSet();
        chosen
          ..clear()
          ..addAll(((p['apps'] ?? []) as List).map((e) => e.toString()).where(installed.contains));
        if (planNums.isNotEmpty) await _channel.invokeMethod('plan', planNums);
        onboarded = true;
      }
    } catch (_) {
      // no saved profile, or it could not be read: start the setup conversation
    }
    await _poll();
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _saveProfile() async {
    await _channel.invokeMethod('prefSet', {
      'key': 'profile',
      'value': jsonEncode({
        'zh': zh,
        'apps': chosen.toList(),
        'plan': planNums,
        'planNote': planNote,
        'instead': instead,
      }),
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

  void _switchLanguage() {
    setState(() => zh = !zh);
    if (onboarded) _saveProfile();
  }

  // ---------- model ----------

  /// One chat completion against the configured OpenAI-compatible endpoint.
  Future<String> _chat(String system, List<Map<String, String>> messages, {int seconds = 30}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final base = _llmBase.replaceAll(RegExp(r'/+$'), '');
      final req = await client.postUrl(Uri.parse('$base/chat/completions'));
      req.headers.set('content-type', 'application/json; charset=utf-8');
      req.headers.set('authorization', 'Bearer $_llmKey');
      req.add(utf8.encode(jsonEncode({
        'model': _llmModel,
        'messages': [
          {'role': 'system', 'content': system},
          ...messages,
        ],
        'temperature': 0.5,
        'max_tokens': 600,
      })));
      final res = await req.close().timeout(Duration(seconds: seconds));
      final body = await res.transform(utf8.decoder).join().timeout(Duration(seconds: seconds));
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final text = (jsonDecode(body)['choices'][0]['message']['content'] ?? '').toString();
      return text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic>? _jsonIn(String text) {
    final a = text.indexOf('{');
    final b = text.lastIndexOf('}');
    if (a == -1 || b <= a) return null;
    try {
      return jsonDecode(text.substring(a, b + 1)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ---------- setup: taps in, a plan out ----------

  /// The option keys ticked for a question. Several answers are stored comma-separated.
  Set<String> _picked(String key) => (answers[key] ?? '').split(',').where((s) => s.isNotEmpty).toSet();

  String _answerText(String key, {bool english = false}) {
    final q = _questions.firstWhere((x) => x.key == key);
    final picked = _picked(key);
    final useEnglish = english || !zh;
    return q.options
        .where((o) => picked.contains(o.key))
        .map((o) => useEnglish ? o.en : o.zh)
        .join(useEnglish ? '; ' : '、');
  }

  /// The plan that follows from the answers by plain rules. Used as is when no model answers.
  Map<String, double> _rulePlan() {
    final length = double.tryParse(answers['length'] ?? '') ?? 30;
    final tried = _picked('tried');
    final quitBefore = tried.contains('blocker') || tried.contains('deleted');
    return {
      // a little under how long they scroll now, so day one barely feels different
      'startGraceMin': (length * 0.6).clamp(5, 30).toDouble(),
      // gentler for people who quit before and came back
      'dailyFactor': quitBefore ? 0.96 : (tried.contains('limit') ? 0.94 : 0.92),
      // shorter slope at bedtime, when people lose track of time
      'rampMin': _picked('when').contains('bed') ? 8 : 15,
      // blurry but watchable for people who removed a blocker, so they do not remove this too
      'floorKbps': tried.contains('blocker') ? 200 : 40,
    };
  }

  // One line only. The picture under it explains what happens.
  String _ruleNote(Map<String, double> p) => tr('All set. Here is what happens when you scroll.', '設定好了。你滑的時候會像這樣。');

  Future<void> _makePlan() async {
    setState(() {
      planning = true;
      planFromModel = false;
    });
    var plan = _rulePlan();
    var note = _ruleNote(plan);
    instead = _answerText('instead');

    if (_aiConfigured) {
      final names = apps.where((a) => chosen.contains(a['pkg'])).map((a) => a['label']).toSet().join(', ');
      final system = [
        'You are the coach inside Doomscroll Rehab. The app does not block short-video feeds. It makes them slower the longer one session runs, and tightens a little every day for 14 days.',
        'From the answers a new user tapped, set four numbers:',
        '- start_grace_min (2 to 30): minutes of full speed at the start of a session on day 1. A little under how long their sessions run now, so day 1 barely feels different.',
        '- daily_factor (0.85 to 0.98): the full-speed window is multiplied by this each day. Closer to 1 is gentler. Use gentler values for people who quit before and came back.',
        '- ramp_min (5 to 30): minutes to fall from full speed to the slowest. Shorter for people who lose track of time, such as in bed.',
        '- floor_kbps (20 to 300): the slowest speed. 40 stalls video entirely. 150 to 300 leaves it blurry but watchable, for people who removed a blocker before.',
        'Then write note for the user: ONE short sentence, at most 14 English words or 22 Chinese characters, that a person reads at a glance. Do not explain how the app works and do not mention minutes or speeds; a picture next to it already shows that. Only say, warmly, how the plan fits one thing they told you. No words like kbps, VPN, taper, parameter. $_languageRule',
        'Answer with JSON only: {"start_grace_min": n, "daily_factor": n, "ramp_min": n, "floor_kbps": n, "note": "..."}',
      ].join('\n');
      final user = [
        'Apps they picked: $names',
        'How long they scroll at a time: ${_answerText('length', english: true)}',
        'Hardest time to stop: ${_answerText('when', english: true)}',
        'Tried before: ${_answerText('tried', english: true)}',
        'Would rather be doing: ${_answerText('instead', english: true)}',
      ].join('\n');
      try {
        final j = _jsonIn(await _chat(system, [
          {'role': 'user', 'content': user},
        ], seconds: 45));
        if (j == null || (j['note'] ?? '').toString().isEmpty) throw Exception('empty reply');
        double pick(String key, String mine, double lo, double hi) =>
            j[key] is num ? (j[key] as num).toDouble().clamp(lo, hi).toDouble() : plan[mine]!;
        plan = {
          'startGraceMin': pick('start_grace_min', 'startGraceMin', 2, 30),
          'dailyFactor': pick('daily_factor', 'dailyFactor', 0.85, 0.98),
          'rampMin': pick('ramp_min', 'rampMin', 5, 30),
          'floorKbps': pick('floor_kbps', 'floorKbps', 20, 300),
        };
        note = j['note'].toString();
        planFromModel = true;
        debugPrint('Rehab coach: plan written by $_llmModel $plan');
      } catch (e) {
        // keep the rule-based plan; the screen says which one this is
        debugPrint('Rehab coach: model did not answer ($e), rule-based plan used');
      }
    } else {
      debugPrint('Rehab coach: no model in this build, rule-based plan used');
    }

    planNums = plan;
    planNote = note;
    await _channel.invokeMethod('plan', planNums);
    await _saveProfile();
    await _poll();
    if (mounted) setState(() => planning = false);
  }

  void _nextStep() {
    setState(() => step += 1);
    if (step == _questions.length + 1) _makePlan();
  }

  /// One-answer questions move on by themselves; several-answer questions tick and wait for "Next".
  void _answer(Question q, String option) {
    if (q.multi) {
      final picked = _picked(q.key);
      picked.contains(option) ? picked.remove(option) : picked.add(option);
      // keep the order the options are listed in
      setState(() => answers[q.key] = q.options.map((o) => o.key).where(picked.contains).join(','));
      return;
    }
    setState(() => answers[q.key] = option);
    // Let the tap show as selected before the next question comes in.
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted) _nextStep();
    });
  }

  Future<void> _finishSetup({bool turnOn = true}) async {
    if (chosen.isEmpty) {
      chosen.addAll(apps.where((a) => a['pkg'] != _chromePkg).map((a) => a['pkg'] as String));
    }
    if (turnOn && !running) await _toggle();
    await _saveProfile();
    if (mounted) setState(() => onboarded = true);
  }

  void _restartSetup() {
    setState(() {
      onboarded = false;
      planning = false;
      step = 0;
      answers.clear();
    });
  }

  // ---------- negotiator ----------

  String _negotiatorPrompt() {
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
      if (instead.isNotEmpty) '- When they set the app up, they said they would rather be doing this: $instead',
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

  (String, int) _negotiatorScripted() {
    final used = (s['grantsToday'] ?? 0) as num;
    final max = (s['maxGrants'] ?? 3) as num;
    if (used >= max) {
      return (
        tr('You have used all $max boosts for today. The feed stays slow until tomorrow.',
            '今天的 $max 次全速都用完了，明天之前會維持慢速。'),
        0
      );
    }
    final turns = history.skip(wordsFrom).where((m) => m['role'] == 'user').length;
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
    _scrollDown(scroll);

    var reply = '';
    var grant = 0;
    String? note;
    if (_aiConfigured) {
      try {
        final raw = await _chat(_negotiatorPrompt(), history);
        final j = _jsonIn(raw);
        reply = (j?['reply'] ?? raw).toString();
        grant = ((j?['grant_minutes'] ?? 0) as num).round();
        if (reply.isEmpty) throw Exception('empty reply');
      } catch (e) {
        (reply, grant) = _negotiatorScripted();
        note = tr('Model call failed, scripted reply shown. $e', '模型沒有回應，以下是預設回覆。$e');
      }
    } else {
      (reply, grant) = _negotiatorScripted();
    }

    // What the user said in this negotiation is stored with the boost, so it can be held against what they do next.
    final words = history.skip(wordsFrom).where((m) => m['role'] == 'user').map((m) => m['content']).join(' / ');
    final granted =
        grant > 0 ? (await _channel.invokeMethod<int>('grant', {'minutes': grant, 'words': words}) ?? 0) : 0;
    if (granted > 0) wordsFrom = history.length + 1;
    await _poll();
    if (!mounted) return;
    setState(() {
      history.add({'role': 'assistant', 'content': reply});
      chat.add(ChatLine('bot', reply));
      if (note != null) chat.add(ChatLine('note', note));
      if (granted > 0) chat.add(ChatLine('note', tr('Full speed for $granted minutes', '全速 $granted 分鐘')));
      sending = false;
    });
    _scrollDown(scroll);
  }

  // ---------- report: what you said versus what you did ----------

  Future<void> _report() async {
    if (reportBusy) return;
    final promises = (s['promises'] ?? []) as List;
    if (promises.isEmpty) {
      setState(() => reportText = tr('Nothing to report yet. Ask for full speed once first.', '還沒有資料。先要一次全速。'));
      return;
    }
    if (!_aiConfigured) {
      setState(() => reportText = tr('No model configured in this build.', '這個版本沒有接上模型。'));
      return;
    }
    setState(() {
      reportBusy = true;
      reportText = tr('Reading your log. This takes about 20 seconds.', '正在讀你的紀錄，大約需要 20 秒。');
    });
    final system = [
      'You write the usage report inside Doomscroll Rehab, an app that slows short-video feeds the longer someone scrolls.',
      'You get JSON with: promises (what the user said to get full speed back, the minutes granted, and the outcome: kept means they stopped when it ran out, broken means they kept scrolling, pending means still being checked), finished sessions, the current session, and what they said they would rather be doing.',
      'Write summary: at most 70 words, addressed to the person as "you". Where a promise was broken, quote a few of their own words back exactly, in quotation marks. Say plainly how many promises were kept out of how many decided. End with ONE concrete change they could make, in everyday words, and nothing after it.',
      'No lecturing, no shaming, no statistics from outside this data, no field names. $_languageRule',
      'Answer with JSON only: {"summary": "..."}',
    ].join('\n');
    try {
      final text = await _chat(system, [
        {
          'role': 'user',
          'content': jsonEncode({
            'promises': promises,
            'finishedSessions': s['sessions'] ?? [],
            'currentSessionMinutes': s['sessionMin'],
            'currentSessionMinutesAfterSlowingBegan': s['slowedMin'],
            'wouldRatherBeDoing': instead,
          }),
        },
      ], seconds: 75);
      final j = _jsonIn(text);
      if (!mounted) return;
      setState(() => reportText = (j?['summary'] ?? text).toString());
    } catch (e) {
      if (mounted) setState(() => reportText = tr('Could not reach the model. $e', '模型沒有回應。$e'));
    } finally {
      if (mounted) setState(() => reportBusy = false);
    }
  }

  void _scrollDown(ScrollController c) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.hasClients) {
        c.animateTo(c.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: _ease);
      }
    });
  }

  String _fmtTime(num minutes) {
    final total = (minutes * 60).floor();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  // ---------- view ----------

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final small = TextStyle(fontSize: 15, height: 1.5, color: t.muted, fontWeight: FontWeight.w400);
    final body = TextStyle(fontSize: 16, height: 1.7, color: t.text, fontWeight: FontWeight.w400);
    final h2 = TextStyle(fontSize: 16, height: 1.5, color: t.text, fontWeight: FontWeight.w500);
    final stat = TextStyle(
      fontSize: 32,
      height: 1.25,
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
            disabledForegroundColor: t.muted,
            backgroundColor: on ? t.bubble : null,
            side: BorderSide(color: on ? t.second : t.line, width: on ? 1.5 : 0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: TextStyle(fontSize: 15, fontWeight: on ? FontWeight.w500 : FontWeight.w400),
          ),
          child: Text(label),
        );

    Widget primary(String label, VoidCallback? onTap) => PressButton(
          label: label,
          onTap: onTap,
          color: t.accent,
          onColor: t.onAccent,
          pressedColor: t.accentPressed,
          offColor: t.bubble,
          onOffColor: t.muted,
        );

    InputDecoration field(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: body.copyWith(color: t.muted, height: 1.3),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: t.line, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: t.second, width: 2),
          ),
        );

    Widget bubble(ChatLine m) {
      if (m.kind == 'note') {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(child: Text(m.text, style: small)),
        );
      }
      final isGhost = m.kind == 'bot';
      final box = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isGhost ? t.bubble : t.second,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(m.text, style: body.copyWith(height: 1.5, color: isGhost ? t.text : t.onSecond)),
      );
      return Padding(
        padding: EdgeInsets.only(top: 4, bottom: 4, left: isGhost ? 0 : 48, right: isGhost ? 24 : 0),
        child: isGhost
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _ghost(32),
                const SizedBox(width: 8),
                Flexible(child: box),
              ])
            : Align(alignment: Alignment.centerRight, child: box),
      );
    }

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text('Doomscroll Rehab', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: t.text)),
        ),
        plain(zh ? 'EN' : '中文', _switchLanguage),
      ],
    );

    if (!loaded) {
      return Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: header)));
    }

    // ----- first run: the ghost asks in speech bubbles, you answer by tapping -----
    if (!onboarded) {
      final n = _questions.length;
      final big = TextStyle(fontSize: 18, height: 1.45, color: t.text, fontWeight: FontWeight.w400);

      // The ghost shows up, types for a moment, then the bubble pops in. Keys keep old lines from replaying.
      Widget ghostSays(String id, Widget child, {int delayMs = 300, int typingMs = 650}) => GhostLine(
            key: ValueKey('ghost-$id'),
            delayMs: delayMs,
            typingMs: typingMs,
            bubbleColor: t.bubble,
            dotColor: t.muted,
            child: child,
          );

      Widget youSaid(String id, String text) => PopIn(
            key: ValueKey('you-$id'),
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12, left: 56),
              child: Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: t.second, borderRadius: BorderRadius.circular(16)),
                  child: Text(text, style: big.copyWith(color: t.onSecond)),
                ),
              ),
            ),
          );

      Widget option(String label, bool on, VoidCallback onTap, {Widget? leading, Widget? trailing}) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: on ? t.bubble : t.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: on ? t.second : t.line, width: on ? 2 : 0.5),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    if (leading != null) ...[leading, const SizedBox(width: 12)],
                    Expanded(child: Text(label, style: big)),
                    if (trailing != null) trailing,
                  ]),
                ),
              ),
            ),
          );

      Widget tick(bool on) => AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: _ease,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? t.second : t.surface,
              border: Border.all(color: on ? t.second : t.line, width: 1.5),
            ),
            child: AnimatedScale(
              scale: on ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              curve: _ease,
              child: Icon(Icons.check_rounded, size: 18, color: t.onSecond),
            ),
          );

      // What happens next, as three little phone screens: clear, fading, stuck.
      Widget planPicture() {
        final grace = (planNums['startGraceMin'] ?? 10).round();
        final slowest = grace + (planNums['rampMin'] ?? 15).round();
        Widget screen(double strength, {bool stuck = false}) => Container(
              width: 56,
              height: 84,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.second, width: 1.5),
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: t.second.withValues(alpha: strength),
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: stuck
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: t.second),
                      )
                    : Icon(Icons.play_arrow_rounded, size: 24, color: t.surface),
              ),
            );
        Widget stage(Widget picture, String label, String when) => Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                picture,
                const SizedBox(height: 8),
                Text(label, style: body.copyWith(height: 1.3, fontWeight: FontWeight.w500), textAlign: TextAlign.center),
                Text(when, style: small, textAlign: TextAlign.center),
              ]),
            );
        return SizedBox(
          width: 264,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            stage(screen(1), tr('Normal', '正常'), tr('first $grace min', '前 $grace 分鐘')),
            stage(screen(0.4), tr('Slower', '越來越慢'), tr('after that', '之後')),
            // a gentle plan never stalls video completely, so it is only called blurry
            stage(
              screen(0.08, stuck: true),
              (planNums['floorKbps'] ?? 40) <= 100 ? tr('Stuck', '卡住') : tr('Very blurry', '很糊'),
              tr('at $slowest min', '第 $slowest 分鐘'),
            ),
          ]),
        );
      }

      final pickedNames = apps
          .where((a) => chosen.contains(a['pkg']))
          .map((a) => a['label'] as String)
          .toSet()
          .join(tr(', ', '、'));

      // Everything said so far, oldest first.
      final transcript = <Widget>[
        ghostSays(
          'hi',
          Text(
            tr('Hi. I will help you scroll a little less. Nothing gets locked. A few quick questions first.',
                '嗨，我會陪你少滑一點，不會鎖住任何東西。先問你幾個問題。'),
            style: big,
          ),
        ),
        ghostSays('q0', Text(tr('Which apps do you get stuck in?', '你會在哪些 App 滑到停不下來？'), style: big),
            delayMs: 1500),
        if (step > 0) youSaid('a0', pickedNames),
        for (var i = 1; i <= n && i <= step; i++) ...[
          ghostSays(
            'q$i',
            Text(
              (zh ? _questions[i - 1].zh : _questions[i - 1].en) +
                  (_questions[i - 1].multi ? tr(' You can pick more than one.', '可以選好幾個。') : ''),
              style: big,
            ),
            delayMs: 350,
          ),
          if (step > i) youSaid('a$i', _answerText(_questions[i - 1].key)),
        ],
        if (step > n)
          planning
              ? ghostSays(
                  'planning',
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(tr('Got it. Working out a plan for you. About ten seconds.', '了解。我來幫你訂計畫，大約十秒。'),
                        style: big),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 160,
                      child: LinearProgressIndicator(minHeight: 4, color: t.second, backgroundColor: t.line),
                    ),
                  ]),
                  delayMs: 350,
                  typingMs: 500,
                )
              : ghostSays(
                  'plan',
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(planNote, style: big),
                    const SizedBox(height: 12),
                    planPicture(),
                  ]),
                  delayMs: 0,
                  typingMs: 600,
                ),
      ];

      // What you can tap right now.
      final choices = <Widget>[];
      Widget? footer;
      if (step == 0) {
        final pickable = apps.where((a) => a['pkg'] != _chromePkg).toList();
        if (pickable.isEmpty) {
          choices.add(Text(tr('No supported feed app is installed on this phone.', '這支手機沒有安裝支援的短影音 App。'), style: big));
        }
        for (final a in pickable) {
          final on = chosen.contains(a['pkg']);
          choices.add(option(
            a['label'] as String,
            on,
            () => setState(() {
              final pkg = a['pkg'] as String;
              chosen.contains(pkg) ? chosen.remove(pkg) : chosen.add(pkg);
            }),
            leading: a['icon'] == null
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(a['icon'] as Uint8List, width: 36, height: 36, gaplessPlayback: true),
                  ),
            trailing: tick(on),
          ));
        }
        footer = primary(tr('These ones', '就這些'), chosen.isEmpty ? null : () => setState(() => step = 1));
      } else if (step <= n) {
        final q = _questions[step - 1];
        final picked = _picked(q.key);
        for (final o in q.options) {
          final on = picked.contains(o.key);
          choices.add(option(zh ? o.zh : o.en, on, () => _answer(q, o.key), trailing: q.multi ? tick(on) : null));
        }
        if (q.multi) footer = primary(tr('Next', '下一步'), picked.isEmpty ? null : _nextStep);
      } else if (!planning) {
        footer = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          primary(tr('Start', '開始'), starting ? null : () => _finishSetup()),
          const SizedBox(height: 8),
          Text(
            tr('Your phone will ask to allow a VPN. Tap OK. It stays on this phone.', '手機會問你要不要允許 VPN，按「確定」就好。它只在這支手機上運作。'),
            style: small,
          ),
          if (_aiConfigured && !planFromModel)
            Text(tr('The coach did not answer, so this is the standard plan for your answers.', '教練沒有回應，這是依照你的回答套用的標準計畫。'),
                style: small),
        ]);
      }

      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 12),
                // Newest at the bottom, and it stays at the bottom as the conversation grows.
                Expanded(child: ListView(reverse: true, children: transcript.reversed.toList())),
                // The answers appear once the ghost has finished asking.
                if (choices.isNotEmpty)
                  PopIn(
                    key: ValueKey('choices-$step'),
                    delayMs: step == 0 ? 2300 : 1100,
                    alignment: Alignment.bottomCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.42),
                      child: SingleChildScrollView(child: Column(children: choices)),
                    ),
                  ),
                if (footer != null) ...[
                  const SizedBox(height: 4),
                  PopIn(
                    key: ValueKey('footer-$step-$planning'),
                    delayMs: step == 0 ? 2300 : 900,
                    alignment: Alignment.bottomCenter,
                    child: footer,
                  ),
                ],
                const SizedBox(height: 8),
                Row(children: [
                  if (step > 0 && !planning) plain(tr('Back', '上一步'), () => setState(() => step -= 1)),
                  const Spacer(),
                  if (step <= n) plain(tr('Skip the questions', '跳過問題'), () => _finishSetup(turnOn: false)),
                ]),
              ],
            ),
          ),
        ),
      );
    }

    // ----- home: one sentence about now, and the way to ask for more -----
    final stage = (s['stage'] ?? 'off') as String;
    final kbps = s['kbps'] as num?;
    final sessionMin = (s['sessionMin'] ?? 0) as num;
    final graceMin = (s['graceMin'] ?? 10) as num;
    final rampMin = (s['rampMin'] ?? 15) as num;
    final minKbps = (s['minKbps'] ?? 40) as num;
    final delayMs = (s['connectDelayMs'] ?? 0) as num;
    final timeScale = (s['timeScale'] ?? 1) as num;
    final day = ((s['day'] ?? 0) as num).toInt();
    final hosts = ((s['hosts'] ?? []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final error = s['error'] as String?;
    final promises = ((s['promises'] ?? []) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final keptCount = promises.where((p) => p['outcome'] == 'kept').length;
    final decidedCount = promises.where((p) => p['outcome'] != 'pending').length;
    final speedText = kbps == null
        ? tr('full speed', '全速')
        : kbps >= 1000
            ? '${(kbps / 1000).toStringAsFixed(1)} Mbps'
            : '${kbps.round()} kbps';
    final appNames = apps.where((a) => chosen.contains(a['pkg'])).map((a) => a['label']).toSet().join(tr(', ', '、'));

    final stageColor = switch (stage) {
      'full' || 'boost' => t.ok,
      'slowing' => t.warn,
      'floor' => t.bad,
      _ => t.muted,
    };
    final heroTitle = switch (stage) {
      'off' => tr('Off', '未開啟'),
      'idle' => tr('Ready when you are', '準備好了'),
      'full' => tr('Full speed', '全速'),
      'slowing' => tr('Getting slower', '正在變慢'),
      'floor' => tr('As slow as it gets', '已經最慢'),
      'boost' => tr('Full speed, on a timer', '限時全速'),
      _ => stage,
    };
    final left = graceMin - sessionMin;
    final heroLine = switch (stage) {
      'off' => tr('Turn it on and $appNames will get slower the longer you scroll.', '開啟後，$appNames 會越滑越慢。'),
      'idle' => tr(
          'Open $appNames whenever you like. The first ${graceMin.toStringAsFixed(0)} minutes are at full speed.',
          '想滑的時候就打開 $appNames。前 ${graceMin.toStringAsFixed(0)} 分鐘是全速。',
        ),
      'full' => tr(
          'Another ${_fmtTime(left)} at full speed. After that it gets slower every minute.',
          '還有 ${_fmtTime(left)} 的全速，之後每分鐘都會更慢。',
        ),
      'slowing' => tr(
          'You have been scrolling for ${sessionMin.round()} minutes. The feed is at $speedText and still dropping.',
          '你已經滑了 ${sessionMin.round()} 分鐘。現在是 $speedText，還會繼續變慢。',
        ),
      'floor' => instead.isNotEmpty
          ? tr('This is the slowest it goes. You said you would rather: $instead', '這是最慢的速度了。你說過你比較想：$instead')
          : tr('This is the slowest it goes. Ten minutes away resets it.', '這是最慢的速度了。離開十分鐘就會重設。'),
      'boost' => tr('${s['boostLeftSec']} seconds left, then it slows down again.', '還剩 ${s['boostLeftSec']} 秒，之後會再慢下來。'),
      _ => '',
    };

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            header,
            const SizedBox(height: 16),
            card([
              // The ghost tells you where things stand, in a speech bubble.
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _ghost(56),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(color: t.bubble, borderRadius: BorderRadius.circular(16)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 300),
                        curve: _ease,
                        style: stat.copyWith(
                          fontSize: 24,
                          color: stage == 'off' || stage == 'idle' ? t.text : stageColor,
                        ),
                        child: Text(heroTitle),
                      ),
                      const SizedBox(height: 4),
                      Text(heroLine, style: body.copyWith(height: 1.5)),
                    ]),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                height: 96,
                width: double.infinity,
                child: CustomPaint(
                  painter: CurvePainter(
                    sessionMin: sessionMin.toDouble(),
                    graceMin: graceMin.toDouble(),
                    rampMin: rampMin.toDouble(),
                    line: t.second,
                    faint: t.line,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('${_fmtTime(sessionMin)} scrolled this session', '這次已滑 ${_fmtTime(sessionMin)}'),
                style: small,
              ),
              if (!running) ...[
                const SizedBox(height: 16),
                primary(tr('Turn on', '開啟'), starting || chosen.isEmpty ? null : _toggle),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error, style: small.copyWith(color: t.bad)),
              ],
            ]),
            if (running)
              card([
                Text(tr('Want full speed back?', '想要回全速？'), style: h2),
                Text(
                  tr('Tell it why. It decides, and it remembers what you said.', '跟它說為什麼。由它決定，而且它會記得你說的話。'),
                  style: small,
                ),
                const SizedBox(height: 8),
                if (chat.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView(
                      controller: scroll,
                      shrinkWrap: true,
                      children: [
                        // Each line pops in once; the key stops earlier lines from replaying.
                        for (var i = 0; i < chat.length; i++)
                          PopIn(
                            key: ValueKey('chat-$i'),
                            alignment: chat[i].kind == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                            child: bubble(chat[i]),
                          ),
                        // While the model is thinking, the ghost is typing.
                        if (sending)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(children: [
                              _ghost(32),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(color: t.bubble, borderRadius: BorderRadius.circular(16)),
                                child: TypingDots(color: t.muted),
                              ),
                            ]),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                // Answers people can tap instead of typing. What they tap is still recorded as what they said.
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final quick in [
                    tr('One more video, then I stop', '再看一支就停'),
                    tr('I need to reply to someone', '我要回一則訊息'),
                    tr('Five more minutes', '再五分鐘'),
                  ])
                    plain(
                        quick,
                        sending
                            ? null
                            : () {
                                input.text = quick;
                                _send();
                              }),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      onSubmitted: (_) => _send(),
                      style: body.copyWith(height: 1.3),
                      decoration: field(tr('Why do you want it back?', '為什麼想要回全速？')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  plain(sending ? tr('Thinking', '思考中') : tr('Send', '送出'), sending ? null : _send, on: true),
                ]),
                const SizedBox(height: 8),
                Text(
                  tr('${s['grantsToday'] ?? 0} of ${s['maxGrants'] ?? 3} used today',
                      '今天已用 ${s['grantsToday'] ?? 0} 次，共 ${s['maxGrants'] ?? 3} 次'),
                  style: small,
                ),
                if (!_aiConfigured) Text(tr('No model in this build. Replies are scripted.', '這個版本沒有接上模型，以下是預設回覆。'), style: small),
              ]),
            if (promises.isNotEmpty)
              card([
                Text(tr('Said versus did', '說的 vs 做的'), style: h2),
                const SizedBox(height: 4),
                Text('$keptCount / $decidedCount', style: stat),
                Text(tr('promises kept, of those already decided', '守住的承諾（已有結果的）'), style: small),
                const SizedBox(height: 8),
                for (final p in promises.reversed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Text(tr('"${p['words']}"', '「${p['words']}」'), style: small.copyWith(color: t.text)),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${p['minutes']} ${tr('min', '分')}  ${switch (p['outcome']) {
                          'kept' => tr('kept', '守住'),
                          'broken' => tr('broken', '沒守住'),
                          _ => tr('checking', '確認中'),
                        }}',
                        style: small.copyWith(
                          color: switch (p['outcome']) { 'kept' => t.ok, 'broken' => t.bad, _ => t.muted },
                        ),
                      ),
                    ]),
                  ),
                const SizedBox(height: 8),
                plain(reportBusy ? tr('Thinking', '思考中') : tr('What does this say about me?', '這代表什麼？'),
                    reportBusy ? null : _report,
                    on: true),
                if (reportText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(reportText, style: body.copyWith(height: 1.5)),
                ],
              ]),
            card([
              Text(tr('Your plan', '你的計畫'), style: h2),
              const SizedBox(height: 4),
              Text(
                planNote.isNotEmpty
                    ? planNote
                    : tr('The default plan. Talk to the coach and it will fit one to you.', '目前是預設計畫。跟教練聊聊，它會幫你調整。'),
                style: body.copyWith(height: 1.5),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Day ${day + 1} of 14. Full speed for the first ${graceMin.toStringAsFixed(1)} minutes, slowest ${minKbps.round()} kbps.',
                  '14 天中的第 ${day + 1} 天。前 ${graceMin.toStringAsFixed(1)} 分鐘全速，最慢 ${minKbps.round()} kbps。',
                ),
                style: small,
              ),
              const SizedBox(height: 8),
              plain(tr('Talk to the coach again', '再跟教練聊一次'), _restartSetup),
            ]),
            Align(
              alignment: Alignment.centerLeft,
              child: plain(showDetails ? tr('Hide details', '收起詳細資料') : tr('Details', '詳細資料'),
                  () => setState(() => showDetails = !showDetails)),
            ),
            if (showDetails) ...[
              const SizedBox(height: 16),
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
                        a['pkg'] == _chromePkg ? tr('Chrome (for testing)', 'Chrome（測試用）') : a['label'] as String,
                        running
                            ? null
                            : () {
                                setState(() {
                                  final pkg = a['pkg'] as String;
                                  chosen.contains(pkg) ? chosen.remove(pkg) : chosen.add(pkg);
                                });
                                _saveProfile();
                              },
                        on: chosen.contains(a['pkg']),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  tr('Uses a local VPN that stays on this phone. It sees which servers the chosen apps talk to, never what they send.',
                      '使用只在這支手機上運作的本機 VPN。它只看得到這些 App 連到哪些伺服器，看不到傳送的內容。'),
                  style: small,
                ),
                if (running) ...[
                  const SizedBox(height: 8),
                  plain(tr('Turn off', '關閉'), starting ? null : _toggle),
                ],
              ]),
              card([
                Text(tr('Right now', '目前數值'), style: h2),
                const SizedBox(height: 4),
                Text(
                  tr(
                    'Speed limit: $speedText. Wait before each new video: ${(delayMs / 1000).toStringAsFixed(1)} s.',
                    '速度上限：$speedText。每支新影片多等 ${(delayMs / 1000).toStringAsFixed(1)} 秒。',
                  ),
                  style: small,
                ),
                const SizedBox(height: 8),
                Text(tr('Servers the feed apps are loading', '這些 App 正在連的伺服器'), style: small.copyWith(color: t.text)),
                if (hosts.isEmpty) Text(tr('Nothing yet.', '還沒有資料。'), style: small),
                for (final h in hosts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Expanded(child: Text(h['host'] as String, style: small)),
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
                      wordsFrom = 0;
                      reportText = '';
                    });
                    _demo({'reset': true});
                  }),
                  plain(tr('Forget me and start over', '清除設定重新開始'), () async {
                    await _channel.invokeMethod('prefSet', {'key': 'profile', 'value': null});
                    planNote = '';
                    instead = '';
                    _restartSetup();
                  }),
                ]),
              ]),
            ],
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
