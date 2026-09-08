import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../services/voice_service.dart';
import '../services/screen_automation_service.dart';
import '../services/app_launcher_service.dart';
import '../services/shizuku_service.dart';
import '../services/task_executor.dart';

enum CallState { connecting, listening, thinking, speaking, working, ended }

/// Full-screen "phone call with Lara" experience. The user talks, Lara
/// listens (Bangla by default), figures out what to do, controls the phone
/// through the existing TaskExecutor pipeline, and speaks the result back —
/// then automatically listens again, like a real conversation, until the
/// user ends the call.
class CallScreen extends StatefulWidget {
  final AiService aiService;
  const CallScreen({super.key, required this.aiService});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with TickerProviderStateMixin {
  final VoiceService _voice = VoiceService();
  late final ScreenAutomationService _screenService;
  late final AppLauncherService _appLauncher;
  late final ShizukuService _shizukuService;
  TaskExecutor? _executor;

  CallState _state = CallState.connecting;
  String _liveCaption = '';
  String _laraLine = "Hi, I'm Lara.";
  bool _muted = false;
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;
  int _consecutiveTimeouts = 0;

  late final AnimationController _pulseController;
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _screenService = ScreenAutomationService();
    _appLauncher = AppLauncherService();
    _shizukuService = ShizukuService();

    _startCall();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _pulseController.dispose();
    _spinController.dispose();
    _voice.dispose();
    _executor?.cancel();
    super.dispose();
  }

  Future<void> _startCall() async {
    await widget.aiService.init();
    await _voice.init();

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _callDuration += const Duration(seconds: 1));
    });

    final greeting = _voice.isBangla
        ? 'হ্যালো, আমি লারা। বলুন, কী করতে হবে?'
        : "Hi, I'm Lara. What would you like me to do?";
    await _speakThenListen(greeting);
  }

  Future<void> _speakThenListen(String line) async {
    if (!mounted || _state == CallState.ended) return;
    setState(() {
      _state = CallState.speaking;
      _laraLine = line;
    });
    await _voice.speak(line);
    if (!mounted || _state == CallState.ended) return;
    _listenOnce();
  }

  Future<void> _listenOnce() async {
    if (!mounted || _state == CallState.ended) return;
    if (_muted) {
      // Don't auto-listen while muted; wait for the user to unmute.
      setState(() {
        _state = CallState.listening;
        _liveCaption = '';
      });
      return;
    }

    setState(() {
      _state = CallState.listening;
      _liveCaption = '';
    });

    await _voice.listenForCall(
      onPartial: (text) {
        if (mounted) setState(() => _liveCaption = text);
      },
      onFinal: (text) async {
        _consecutiveTimeouts = 0;
        if (mounted) setState(() => _liveCaption = text);
        await _handleCommand(text);
      },
      onTimeout: () async {
        _consecutiveTimeouts++;
        if (!mounted || _state == CallState.ended) return;
        // Keep the call open quietly — don't nag the user every few seconds.
        if (_consecutiveTimeouts >= 4) {
          _consecutiveTimeouts = 0;
          final nudge = _voice.isBangla
              ? "আমি শুনছি, বলুন কী করতে হবে।"
              : "I'm still here — go ahead whenever you're ready.";
          await _speakThenListen(nudge);
        } else {
          _listenOnce();
        }
      },
    );
  }

  Future<void> _handleCommand(String text) async {
    if (text.trim().isEmpty) {
      _listenOnce();
      return;
    }

    // Simple voice commands to end the call, in Bangla or English.
    final lower = text.toLowerCase();
    if (lower.contains('bye') ||
        lower.contains('end call') ||
        lower.contains('hang up') ||
        text.contains('বন্ধ কর') ||
        text.contains('রাখো') ||
        text.contains('বিদায়')) {
      await _endCall();
      return;
    }

    setState(() => _state = CallState.working);

    try {
      _executor = TaskExecutor(
        aiService: widget.aiService,
        screenService: _screenService,
        appLauncher: _appLauncher,
        shizukuService: _shizukuService,
        onProgress: (msg) {
          if (mounted) setState(() => _laraLine = msg);
        },
      );

      final result = await _executor!.executeTask(text);
      if (!mounted || _state == CallState.ended) return;
      await _speakThenListen(result);
    } catch (e) {
      if (!mounted || _state == CallState.ended) return;
      final failMsg = _voice.isBangla
          ? 'দুঃখিত, এটা করতে সমস্যা হয়েছে। আবার বলুন।'
          : "Sorry, I ran into a problem with that. Try again?";
      await _speakThenListen(failMsg);
    }
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    if (_muted) {
      await _voice.stopListening();
    } else if (_state == CallState.listening) {
      _listenOnce();
    }
  }

  Future<void> _toggleLanguage() async {
    final newLang = _voice.isBangla ? 'en-US' : 'bn-BD';
    await _voice.setLanguage(newLang);
    if (mounted) setState(() {});
    final line = _voice.isBangla ? 'বাংলায় চলছি।' : 'Switched to English.';
    await _speakThenListen(line);
  }

  Future<void> _endCall() async {
    _durationTimer?.cancel();
    await _voice.stopListening();
    await _voice.stopSpeaking();
    _executor?.cancel();
    if (mounted) {
      setState(() => _state = CallState.ended);
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) Navigator.of(context).pop();
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _statusLabel() {
    switch (_state) {
      case CallState.connecting:
        return _voice.isBangla ? 'সংযোগ হচ্ছে...' : 'Connecting...';
      case CallState.listening:
        return _voice.isBangla ? 'শুনছি...' : 'Listening...';
      case CallState.thinking:
        return _voice.isBangla ? 'ভাবছি...' : 'Thinking...';
      case CallState.working:
        return _voice.isBangla ? 'কাজ করছি...' : 'Working on it...';
      case CallState.speaking:
        return _voice.isBangla ? 'বলছি...' : 'Speaking...';
      case CallState.ended:
        return _voice.isBangla ? 'কল শেষ' : 'Call ended';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endCall();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0F),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                'Lara AI',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formatDuration(_callDuration),
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              ),
              const Spacer(),
              _buildAvatar(),
              const SizedBox(height: 28),
              Text(
                _statusLabel(),
                style: const TextStyle(
                  color: Color(0xFF22D3EE),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _state == CallState.listening && _liveCaption.isNotEmpty
                      ? _liveCaption
                      : _laraLine,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 16,
                    height: 1.4,
                  ),
                ),
              ),
              const Spacer(),
              _buildControls(),
              const SizedBox(height: 36),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    final isActive = _state == CallState.listening || _state == CallState.speaking;
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _spinController]),
      builder: (context, child) {
        final pulse = isActive ? _pulseController.value : 0.0;
        return SizedBox(
          width: 220,
          height: 220,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer glow rings, only animate while actively listening/speaking
              for (int i = 0; i < 3; i++)
                Transform.scale(
                  scale: 1.0 + (pulse * 0.35) + (i * 0.18),
                  child: Opacity(
                    opacity: isActive ? (0.18 - i * 0.05).clamp(0.0, 1.0) : 0.06,
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFF8B5CF6).withOpacity(0.6),
                            const Color(0xFF22D3EE).withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Rotating "processing" ring while thinking/working
              if (_state == CallState.thinking || _state == CallState.working)
                Transform.rotate(
                  angle: _spinController.value * 2 * math.pi,
                  child: SizedBox(
                    width: 176,
                    height: 176,
                    child: CustomPaint(painter: _ArcPainter()),
                  ),
                ),
              // Core avatar circle with the robot face
              Container(
                width: 148,
                height: 148,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF8B5CF6), Color(0xFF22D3EE)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF8B5CF6).withOpacity(0.5),
                      blurRadius: 30,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/app-logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.smart_toy_rounded,
                      color: Colors.white,
                      size: 64,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _circleButton(
          icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          background: _muted ? Colors.white24 : Colors.white12,
          onTap: _toggleMute,
        ),
        const SizedBox(width: 24),
        _circleButton(
          icon: Icons.call_end_rounded,
          background: const Color(0xFFEF4444),
          size: 68,
          iconSize: 30,
          onTap: _endCall,
        ),
        const SizedBox(width: 24),
        _circleButton(
          icon: Icons.translate_rounded,
          background: Colors.white12,
          label: _voice.isBangla ? 'বাং' : 'EN',
          onTap: _toggleLanguage,
        ),
      ],
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color background,
    required VoidCallback onTap,
    double size = 56,
    double iconSize = 24,
    String? label,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: background),
        child: label != null
            ? Center(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              )
            : Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = const SweepGradient(
        colors: [Colors.transparent, Color(0xFF22D3EE)],
      ).createShader(Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromLTWH(0, 0, size.width, size.height),
      0,
      math.pi * 1.5,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
