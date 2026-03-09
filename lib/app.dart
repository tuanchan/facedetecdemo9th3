import 'package:flutter/material.dart';
import 'logic.dart';

class FaceAttendanceApp extends StatelessWidget {
  const FaceAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Điểm danh khuôn mặt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'IBMPlexSans',
        colorScheme: const ColorScheme.light(
          surface: Color(0xFFFFFFFF),
          onSurface: Color(0xFF111110),
        ),
        scaffoldBackgroundColor: const Color(0xFFF9F9F8),
      ),
      home: const FaceAttendanceScreen(),
    );
  }
}

// ─────────────────────────────────────────────
// CONFIG MODEL
// ─────────────────────────────────────────────
class AppConfig {
  String apiUrl;
  int moduleSessionId;
  double thresh;
  int holdMs;
  int cooldownMs;
  double minFaceWidthRatio;
  double maxFaceWidthRatio;
  double centerToleranceX;
  double centerToleranceY;
  double maxMovePx;
  String audioPath;

  AppConfig({
    this.apiUrl = 'https://your-api.example.com/api/FaceAttendance/checkin-image',
    this.moduleSessionId = 1,
    this.thresh = 0.36,
    this.holdMs = 1200,
    this.cooldownMs = 4000,
    this.minFaceWidthRatio = 0.20,
    this.maxFaceWidthRatio = 0.72,
    this.centerToleranceX = 0.18,
    this.centerToleranceY = 0.22,
    this.maxMovePx = 18,
    this.audioPath = '',
  });
}

// ─────────────────────────────────────────────
// MAIN SCREEN
// ─────────────────────────────────────────────
class FaceAttendanceScreen extends StatefulWidget {
  const FaceAttendanceScreen({super.key});

  @override
  State<FaceAttendanceScreen> createState() => _FaceAttendanceScreenState();
}

class _FaceAttendanceScreenState extends State<FaceAttendanceScreen>
    with TickerProviderStateMixin {
  final AppConfig _config = AppConfig();
  final FaceAttendanceLogic _logic = FaceAttendanceLogic();
  bool _configOpen = false;

  // Controllers for config fields
  late TextEditingController _apiUrlCtrl;
  late TextEditingController _sessionIdCtrl;
  late TextEditingController _threshCtrl;
  late TextEditingController _holdMsCtrl;
  late TextEditingController _cooldownMsCtrl;
  late TextEditingController _minFaceRatioCtrl;
  late TextEditingController _maxFaceRatioCtrl;
  late TextEditingController _tolXCtrl;
  late TextEditingController _tolYCtrl;
  late TextEditingController _maxMoveCtrl;

  // UI state
  String _statusText = 'Sẵn sàng';
  StatusType _statusType = StatusType.muted;
  double _progress = 0.0;
  bool _isCameraRunning = false;

  // Badge state
  BadgeInfo _badgeFace = BadgeInfo('Chưa phát hiện mặt', BadgeMode.normal);
  BadgeInfo _badgeSize = BadgeInfo('Khoảng cách: —', BadgeMode.normal);
  BadgeInfo _badgeZone = BadgeInfo('Vị trí: —', BadgeMode.normal);
  BadgeInfo _badgeStable = BadgeInfo('Ổn định: —', BadgeMode.normal);

  // Result
  AttendanceResult? _result;

  // Success overlay
  bool _showSuccess = false;
  String _successName = '';
  late AnimationController _successAnimCtrl;
  late Animation<double> _successFadeAnim;
  late Animation<double> _successScaleAnim;

  @override
  void initState() {
    super.initState();
    _initControllers();

    _successAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _successFadeAnim = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 10),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_successAnimCtrl);
    _successScaleAnim = CurvedAnimation(
      parent: _successAnimCtrl,
      curve: const Interval(0, 0.15, curve: Curves.elasticOut),
    ).drive(Tween(begin: 0.8, end: 1.0));

    _logic.onStatusUpdate = (text, type) {
      if (mounted) setState(() { _statusText = text; _statusType = type; });
    };
    _logic.onProgressUpdate = (pct) {
      if (mounted) setState(() { _progress = pct; });
    };
    _logic.onBadgesUpdate = (face, size, zone, stable) {
      if (mounted) setState(() {
        _badgeFace = face; _badgeSize = size; _badgeZone = zone; _badgeStable = stable;
      });
    };
    _logic.onResult = (result) {
      if (mounted) setState(() { _result = result; });
    };
    _logic.onSuccess = (name) {
      if (mounted) _triggerSuccessOverlay(name);
    };
    _logic.onCameraStateChange = (running) {
      if (mounted) setState(() { _isCameraRunning = running; });
    };
  }

  void _initControllers() {
    _apiUrlCtrl = TextEditingController(text: _config.apiUrl);
    _sessionIdCtrl = TextEditingController(text: _config.moduleSessionId.toString());
    _threshCtrl = TextEditingController(text: _config.thresh.toString());
    _holdMsCtrl = TextEditingController(text: _config.holdMs.toString());
    _cooldownMsCtrl = TextEditingController(text: _config.cooldownMs.toString());
    _minFaceRatioCtrl = TextEditingController(text: _config.minFaceWidthRatio.toString());
    _maxFaceRatioCtrl = TextEditingController(text: _config.maxFaceWidthRatio.toString());
    _tolXCtrl = TextEditingController(text: _config.centerToleranceX.toString());
    _tolYCtrl = TextEditingController(text: _config.centerToleranceY.toString());
    _maxMoveCtrl = TextEditingController(text: _config.maxMovePx.toString());
  }

  void _syncConfigFromControllers() {
    _config.apiUrl = _apiUrlCtrl.text.trim();
    _config.moduleSessionId = int.tryParse(_sessionIdCtrl.text) ?? 1;
    _config.thresh = double.tryParse(_threshCtrl.text) ?? 0.36;
    _config.holdMs = int.tryParse(_holdMsCtrl.text) ?? 1200;
    _config.cooldownMs = int.tryParse(_cooldownMsCtrl.text) ?? 4000;
    _config.minFaceWidthRatio = double.tryParse(_minFaceRatioCtrl.text) ?? 0.20;
    _config.maxFaceWidthRatio = double.tryParse(_maxFaceRatioCtrl.text) ?? 0.72;
    _config.centerToleranceX = double.tryParse(_tolXCtrl.text) ?? 0.18;
    _config.centerToleranceY = double.tryParse(_tolYCtrl.text) ?? 0.22;
    _config.maxMovePx = double.tryParse(_maxMoveCtrl.text) ?? 18;
  }

  void _triggerSuccessOverlay(String name) {
    setState(() { _showSuccess = true; _successName = name; });
    _successAnimCtrl.forward(from: 0);
    Future.delayed(const Duration(milliseconds: 2700), () {
      if (mounted) setState(() { _showSuccess = false; });
    });
  }

  @override
  void dispose() {
    _logic.stopAll();
    _successAnimCtrl.dispose();
    _apiUrlCtrl.dispose(); _sessionIdCtrl.dispose(); _threshCtrl.dispose();
    _holdMsCtrl.dispose(); _cooldownMsCtrl.dispose(); _minFaceRatioCtrl.dispose();
    _maxFaceRatioCtrl.dispose(); _tolXCtrl.dispose(); _tolYCtrl.dispose(); _maxMoveCtrl.dispose();
    super.dispose();
  }

  // ─────────────── BUILD ───────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9F8),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _buildConfig(),
                        _buildCameraSection(),
                        if (_result != null) _buildResultSection(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_showSuccess) _buildSuccessOverlay(),
        ],
      ),
    );
  }

  // ─────────── HEADER ───────────
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E2DF))),
      ),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF111110), shape: BoxShape.circle)),
          const SizedBox(width: 10),
          const Text('ĐIỂM DANH KHUÔN MẶT',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.0, color: Color(0xFF111110))),
        ],
      ),
    );
  }

  // ─────────── CONFIG ───────────
  Widget _buildConfig() {
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE2E2DF)))),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => setState(() => _configOpen = !_configOpen),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              color: Colors.white,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('CẤU HÌNH', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: Color(0xFF888885))),
                  AnimatedRotation(
                    turns: _configOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.keyboard_arrow_down, size: 18, color: Color(0xFF888885)),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _configOpen ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                children: [
                  _configField('API URL', _apiUrlCtrl, keyboardType: TextInputType.url),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _configField('Session ID', _sessionIdCtrl, keyboardType: TextInputType.number)),
                    const SizedBox(width: 12),
                    Expanded(child: _configField('Thresh', _threshCtrl, keyboardType: TextInputType.number)),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _configField('Hold (ms)', _holdMsCtrl, keyboardType: TextInputType.number)),
                    const SizedBox(width: 12),
                    Expanded(child: _configField('Cooldown (ms)', _cooldownMsCtrl, keyboardType: TextInputType.number)),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _configField('Min Face Ratio', _minFaceRatioCtrl, keyboardType: TextInputType.number)),
                    const SizedBox(width: 12),
                    Expanded(child: _configField('Max Face Ratio', _maxFaceRatioCtrl, keyboardType: TextInputType.number)),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _configField('Center Tol X', _tolXCtrl, keyboardType: TextInputType.number)),
                    const SizedBox(width: 12),
                    Expanded(child: _configField('Center Tol Y', _tolYCtrl, keyboardType: TextInputType.number)),
                  ]),
                  const SizedBox(height: 12),
                  _configField('Max Move (px)', _maxMoveCtrl, keyboardType: TextInputType.number),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _configField(String label, TextEditingController ctrl, {TextInputType? keyboardType}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: Color(0xFF888885))),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          keyboardType: keyboardType,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: Color(0xFF111110)),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFFE2E2DF))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFFE2E2DF))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF111110))),
            filled: true,
            fillColor: const Color(0xFFF9F9F8),
          ),
        ),
      ],
    );
  }

  // ─────────── CAMERA SECTION ───────────
  Widget _buildCameraSection() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Camera preview
          _buildCameraPreview(),
          // Progress bar
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 2,
              backgroundColor: const Color(0xFFE2E2DF),
              color: const Color(0xFF111110),
            ),
          ),
          // Badges
          const SizedBox(height: 10),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: [_buildBadge(_badgeFace), _buildBadge(_badgeSize), _buildBadge(_badgeZone), _buildBadge(_badgeStable)],
          ),
          // Status
          const SizedBox(height: 12),
          Row(
            children: [
              _buildStatusDot(),
              const SizedBox(width: 8),
              Text(_statusText, style: TextStyle(fontSize: 13, color: _statusColor())),
            ],
          ),
          // Buttons
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                _syncConfigFromControllers();
                _logic.startAll(_config);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF111110),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                elevation: 0,
              ),
              child: const Text('MỞ CAMERA + AUTO DETECT',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.8)),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _logic.stopAll,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB91C1C),
                    side: const BorderSide(color: Color(0xFFFECACA)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text('TẮT CAMERA',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    _syncConfigFromControllers();
                    _logic.manualCapture(_config);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF111110),
                    side: const BorderSide(color: Color(0xFFE2E2DF)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text('CHỤP & GỬI',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Yêu cầu: camera permission được cấp',
              style: TextStyle(fontSize: 11, color: Color(0xFF888885), fontFamily: 'monospace')),
          // Thumb preview
          if (_logic.lastCapturedImageBytes != null) ...[
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE2E2DF)), borderRadius: BorderRadius.circular(4)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(_logic.lastCapturedImageBytes!, fit: BoxFit.cover),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 280, maxHeight: 400),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFE2E2DF)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: _logic.cameraPreviewWidget(context) ??
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt_outlined, color: Colors.white30, size: 48),
                  SizedBox(height: 12),
                  Text('Nhấn "Mở camera" để bắt đầu',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            ),
      ),
    );
  }

  Widget _buildBadge(BadgeInfo badge) {
    Color bg, border, text;
    switch (badge.mode) {
      case BadgeMode.ok:
        bg = const Color(0xFFF0FAF4); border = const Color(0xFF1A6640); text = const Color(0xFF1A6640);
        break;
      case BadgeMode.warn:
        bg = const Color(0xFFFFFBEB); border = const Color(0xFF92400E); text = const Color(0xFF92400E);
        break;
      default:
        bg = const Color(0xFFF9F9F8); border = const Color(0xFFE2E2DF); text = const Color(0xFF888885);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, border: Border.all(color: border), borderRadius: BorderRadius.circular(4)),
      child: Text(badge.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: text, fontFamily: 'monospace')),
    );
  }

  Widget _buildStatusDot() {
    Color color;
    switch (_statusType) {
      case StatusType.success: color = const Color(0xFF1A6640); break;
      case StatusType.error: color = const Color(0xFFB91C1C); break;
      case StatusType.warn: color = const Color(0xFFD97706); break;
      default: color = const Color(0xFF888885);
    }
    return Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }

  Color _statusColor() {
    switch (_statusType) {
      case StatusType.success: return const Color(0xFF1A6640);
      case StatusType.error: return const Color(0xFFB91C1C);
      case StatusType.warn: return const Color(0xFF92400E);
      default: return const Color(0xFF888885);
    }
  }

  // ─────────── RESULT ───────────
  Widget _buildResultSection() {
    final r = _result!;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('KẾT QUẢ',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: Color(0xFF888885))),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE2E2DF)), borderRadius: BorderRadius.circular(4)),
            child: Column(
              children: [
                _resultRow('Thông báo', r.message),
                _resultRow('Học viên', r.studentName),
                _resultRow('Mã học viên', r.studentCode),
                _resultRow('Điểm match', r.score != null ? r.score!.toStringAsFixed(4) : '—'),
                _resultRow('Trạng thái', r.ok ? 'Thành công' : 'Thất bại', isStatus: true, ok: r.ok),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultRow(String key, String value, {bool isStatus = false, bool ok = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE2E2DF)))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(key.toUpperCase(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: Color(0xFF888885), fontFamily: 'monospace')),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13, fontFamily: 'monospace',
                  color: isStatus ? (ok ? const Color(0xFF1A6640) : const Color(0xFFB91C1C)) : const Color(0xFF111110),
                  fontWeight: isStatus ? FontWeight.w600 : FontWeight.normal,
                )),
          ),
        ],
      ),
    );
  }

  // ─────────── SUCCESS OVERLAY ───────────
  Widget _buildSuccessOverlay() {
    return AnimatedBuilder(
      animation: _successAnimCtrl,
      builder: (context, child) {
        return Opacity(
          opacity: _successFadeAnim.value,
          child: Container(
            color: Colors.black26,
            child: Center(
              child: Transform.scale(
                scale: _successScaleAnim.value,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.97),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF16A34A), width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 60, offset: const Offset(0, 20)),
                      BoxShadow(color: const Color(0xFF16A34A).withOpacity(0.10), blurRadius: 0, spreadRadius: 6),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72, height: 72,
                        decoration: const BoxDecoration(color: Color(0xFFDCFCE7), shape: BoxShape.circle),
                        child: const Icon(Icons.check, color: Color(0xFF16A34A), size: 40),
                      ),
                      const SizedBox(height: 14),
                      const Text('Điểm danh thành công!',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Color(0xFF15803D))),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDF4),
                          border: Border.all(color: const Color(0xFFBBF7D0)),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(_successName,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14, fontFamily: 'monospace', color: Color(0xFF374151))),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
