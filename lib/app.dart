import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
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
        scaffoldBackgroundColor: const Color(0xFFF9F9F8),
        colorScheme: const ColorScheme.light(surface: Colors.white),
      ),
      home: const FaceAttendanceScreen(),
    );
  }
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
    with SingleTickerProviderStateMixin {

  final _logic = FaceAttendanceLogic();
  final _cfg = AppConfig();
  bool _configOpen = false;

  // Config controllers
  late final TextEditingController _cApiUrl;
  late final TextEditingController _cSession;
  late final TextEditingController _cThresh;
  late final TextEditingController _cHold;
  late final TextEditingController _cCooldown;
  late final TextEditingController _cMinFace;
  late final TextEditingController _cMaxFace;
  late final TextEditingController _cTolX;
  late final TextEditingController _cTolY;
  late final TextEditingController _cMove;

  // UI state
  String _statusText = 'Sẵn sàng';
  StatusType _statusType = StatusType.muted;
  double _progress = 0;
  bool _cameraOn = false;

  BadgeInfo _bFace = const BadgeInfo('Chưa phát hiện mặt', BadgeMode.normal);
  BadgeInfo _bSize = const BadgeInfo('Khoảng cách: —', BadgeMode.normal);
  BadgeInfo _bZone = const BadgeInfo('Vị trí: —', BadgeMode.normal);
  BadgeInfo _bStable = const BadgeInfo('Ổn định: —', BadgeMode.normal);

  List<FaceBox> _faces = [];
  bool _faceOk = false;
  bool _multiFace = false;

  AttendanceResult? _result;
  Uint8List? _thumb;

  // Success overlay
  bool _showSuccess = false;
  String _successName = '';
  late final AnimationController _successCtrl;
  late final Animation<double> _successFade;
  late final Animation<double> _successScale;

  @override
  void initState() {
    super.initState();

    _cApiUrl = TextEditingController(text: _cfg.apiUrl);
    _cSession = TextEditingController(text: _cfg.moduleSessionId.toString());
    _cThresh = TextEditingController(text: _cfg.thresh.toString());
    _cHold = TextEditingController(text: _cfg.holdMs.toString());
    _cCooldown = TextEditingController(text: _cfg.cooldownMs.toString());
    _cMinFace = TextEditingController(text: _cfg.minFaceWidthRatio.toString());
    _cMaxFace = TextEditingController(text: _cfg.maxFaceWidthRatio.toString());
    _cTolX = TextEditingController(text: _cfg.centerToleranceX.toString());
    _cTolY = TextEditingController(text: _cfg.centerToleranceY.toString());
    _cMove = TextEditingController(text: _cfg.maxMovePx.toString());

    _successCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
    _successFade = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 10),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_successCtrl);
    _successScale = CurvedAnimation(
      parent: _successCtrl,
      curve: const Interval(0, 0.18, curve: Curves.elasticOut),
    ).drive(Tween(begin: 0.75, end: 1.0));

    // Wire callbacks
    _logic.onStatusUpdate = (t, s) { if (mounted) setState(() { _statusText = t; _statusType = s; }); };
    _logic.onProgressUpdate = (p) { if (mounted) setState(() => _progress = p); };
    _logic.onBadgesUpdate = (f, s, z, st) { if (mounted) setState(() { _bFace = f; _bSize = s; _bZone = z; _bStable = st; }); };
    _logic.onResult = (r) { if (mounted) setState(() => _result = r); };
    _logic.onSuccess = (n) { if (mounted) _triggerSuccess(n); };
    _logic.onCameraStateChange = (on) { if (mounted) setState(() => _cameraOn = on); };
    _logic.onFacesUpdate = (faces, ok, multi) {
      if (mounted) setState(() { _faces = faces; _faceOk = ok; _multiFace = multi; });
    };
    _logic.onThumbUpdate = (b) { if (mounted) setState(() => _thumb = b); };
  }

  void _syncConfig() {
    _cfg.apiUrl = _cApiUrl.text.trim();
    _cfg.moduleSessionId = int.tryParse(_cSession.text) ?? 1;
    _cfg.thresh = double.tryParse(_cThresh.text) ?? 0.36;
    _cfg.holdMs = int.tryParse(_cHold.text) ?? 1200;
    _cfg.cooldownMs = int.tryParse(_cCooldown.text) ?? 4000;
    _cfg.minFaceWidthRatio = double.tryParse(_cMinFace.text) ?? 0.20;
    _cfg.maxFaceWidthRatio = double.tryParse(_cMaxFace.text) ?? 0.72;
    _cfg.centerToleranceX = double.tryParse(_cTolX.text) ?? 0.18;
    _cfg.centerToleranceY = double.tryParse(_cTolY.text) ?? 0.22;
    _cfg.maxMovePx = double.tryParse(_cMove.text) ?? 18;
  }

  void _triggerSuccess(String name) {
    setState(() { _showSuccess = true; _successName = name; });
    _successCtrl.forward(from: 0);
    Future.delayed(const Duration(milliseconds: 2700), () {
      if (mounted) setState(() => _showSuccess = false);
    });
  }

  @override
  void dispose() {
    _logic.stopAll();
    _successCtrl.dispose();
    for (final c in [_cApiUrl, _cSession, _cThresh, _cHold, _cCooldown,
                     _cMinFace, _cMaxFace, _cTolX, _cTolY, _cMove]) {
      c.dispose();
    }
    super.dispose();
  }

  // ─────────────── BUILD ───────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _header(),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _configSection(),
                        _cameraSection(),
                        _resultSection(),   // Luôn hiện, ẩn nội dung khi chưa có data
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_showSuccess) _successOverlay(),
        ],
      ),
    );
  }

  // ── HEADER ──

  Widget _header() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFE2E2DF))),
        ),
        child: Row(children: [
          Container(width: 8, height: 8,
              decoration: const BoxDecoration(color: Color(0xFF111110), shape: BoxShape.circle)),
          const SizedBox(width: 10),
          const Text('ĐIỂM DANH KHUÔN MẶT',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  letterSpacing: 1.0, color: Color(0xFF111110))),
        ]),
      );

  // ── CONFIG ──

  Widget _configSection() => Container(
        color: Colors.white,
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFE2E2DF)))),
        child: Column(children: [
          GestureDetector(
            onTap: () => setState(() => _configOpen = !_configOpen),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('CẤU HÌNH',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          letterSpacing: 1.2, color: Color(0xFF888885))),
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
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(children: [
                _field('API URL', _cApiUrl, type: TextInputType.url),
                const SizedBox(height: 12),
                _fieldRow('Session ID', _cSession, 'Thresh', _cThresh),
                const SizedBox(height: 12),
                _fieldRow('Hold (ms)', _cHold, 'Cooldown (ms)', _cCooldown),
                const SizedBox(height: 12),
                _fieldRow('Min Face Ratio', _cMinFace, 'Max Face Ratio', _cMaxFace),
                const SizedBox(height: 12),
                _fieldRow('Center Tol X', _cTolX, 'Center Tol Y', _cTolY),
                const SizedBox(height: 12),
                _field('Max Move (px)', _cMove, type: TextInputType.number),
              ]),
            ),
          ),
        ]),
      );

  Widget _fieldRow(String l1, TextEditingController c1, String l2, TextEditingController c2) =>
      Row(children: [
        Expanded(child: _field(l1, c1)),
        const SizedBox(width: 12),
        Expanded(child: _field(l2, c2)),
      ]);

  Widget _field(String label, TextEditingController ctrl,
      {TextInputType type = TextInputType.number}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                letterSpacing: 0.8, color: Color(0xFF888885))),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          keyboardType: type,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFFE2E2DF))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFFE2E2DF))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF111110))),
            filled: true,
            fillColor: const Color(0xFFF9F9F8),
          ),
        ),
      ]);

  // ── CAMERA SECTION ──

  Widget _cameraSection() => Container(
        color: Colors.white,
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFE2E2DF)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Camera + overlay
          _cameraPreview(),
          // Progress bar
          const SizedBox(height: 8),
          ClipRRect(
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 2,
              backgroundColor: const Color(0xFFE2E2DF),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF111110)),
            ),
          ),
          // Badges
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6,
              children: [_badge(_bFace), _badge(_bSize), _badge(_bZone), _badge(_bStable)]),
          // Status
          const SizedBox(height: 12),
          Row(children: [
            _dot(),
            const SizedBox(width: 8),
            Flexible(child: Text(_statusText,
                style: TextStyle(fontSize: 13, color: _statusColor()))),
          ]),
          // Buttons
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () { _syncConfig(); _logic.startAll(_cfg); },
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
          Row(children: [
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
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () { _syncConfig(); _logic.manualCapture(_cfg); },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF111110),
                  side: const BorderSide(color: Color(0xFFE2E2DF)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                child: const Text('CHỤP & GỬI',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          const Text('Yêu cầu: camera permission được cấp',
              style: TextStyle(fontSize: 11, color: Color(0xFF888885))),
          // Thumb
          if (_thumb != null) ...[
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE2E2DF)),
                  borderRadius: BorderRadius.circular(4)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(_thumb!, fit: BoxFit.cover),
              ),
            ),
          ],
        ]),
      );

  // Camera preview với CustomPaint overlay
  Widget _cameraPreview() {
    final camCtrl = _logic.cameraController;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 280, maxHeight: 420),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFE2E2DF)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: camCtrl != null && camCtrl.value.isInitialized
            ? Stack(
                fit: StackFit.expand,
                children: [
                  // Camera feed
                  CameraPreview(camCtrl),
                  // Guide box + face box overlay
                  CustomPaint(
                    painter: GuideBoxPainter(
                      faces: _faces,
                      faceOk: _faceOk,
                      multipleFaces: _multiFace,
                    ),
                  ),
                ],
              )
            : const Center(
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

  // ── RESULT SECTION ──

  Widget _resultSection() => Container(
        color: Colors.white,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('KẾT QUẢ',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 1.2, color: Color(0xFF888885))),
          const SizedBox(height: 12),
          _result == null
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFE2E2DF)),
                    borderRadius: BorderRadius.circular(4),
                    color: const Color(0xFFF9F9F8),
                  ),
                  child: const Center(
                    child: Text('Chưa có kết quả điểm danh',
                        style: TextStyle(fontSize: 13, color: Color(0xFF888885))),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFE2E2DF)),
                      borderRadius: BorderRadius.circular(4)),
                  child: Column(children: [
                    _rRow('Thông báo', _result!.message),
                    _rRow('Học viên', _result!.studentName),
                    _rRow('Mã học viên', _result!.studentCode),
                    _rRow('Điểm match',
                        _result!.score != null ? _result!.score!.toStringAsFixed(4) : '—'),
                    _rRowStatus('Trạng thái', _result!.ok ? 'Thành công' : 'Thất bại', _result!.ok),
                  ]),
                ),
        ]),
      );

  Widget _rRow(String key, String val) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFE2E2DF)))),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(key.toUpperCase(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 0.6, color: Color(0xFF888885), fontFamily: 'monospace')),
          Flexible(
            child: Text(val,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: Color(0xFF111110))),
          ),
        ]),
      );

  Widget _rRowStatus(String key, String val, bool ok) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(key.toUpperCase(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 0.6, color: Color(0xFF888885), fontFamily: 'monospace')),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: ok ? const Color(0xFFF0FAF4) : const Color(0xFFFFF5F5),
              border: Border.all(color: ok ? const Color(0xFF1A6640) : const Color(0xFFB91C1C)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(val,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace',
                    color: ok ? const Color(0xFF1A6640) : const Color(0xFFB91C1C))),
          ),
        ]),
      );

  // ── SUCCESS OVERLAY ──

  Widget _successOverlay() => AnimatedBuilder(
        animation: _successCtrl,
        builder: (_, __) => Opacity(
          opacity: _successFade.value,
          child: Container(
            color: Colors.black.withOpacity(0.3),
            child: Center(
              child: Transform.scale(
                scale: _successScale.value,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.97),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF16A34A), width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.15),
                          blurRadius: 40, offset: const Offset(0, 16)),
                    ],
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 72, height: 72,
                      decoration: const BoxDecoration(
                          color: Color(0xFFDCFCE7), shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded, color: Color(0xFF16A34A), size: 42),
                    ),
                    const SizedBox(height: 14),
                    const Text('Điểm danh thành công!',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600,
                            color: Color(0xFF15803D))),
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
                          style: const TextStyle(fontSize: 14,
                              fontFamily: 'monospace', color: Color(0xFF374151))),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );

  // ── HELPERS ──

  Widget _badge(BadgeInfo b) {
    Color bg, border, text;
    switch (b.mode) {
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
      decoration: BoxDecoration(color: bg, border: Border.all(color: border),
          borderRadius: BorderRadius.circular(4)),
      child: Text(b.label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
              fontFamily: 'monospace', color: text)),
    );
  }

  Widget _dot() {
    final color = {
      StatusType.success: const Color(0xFF1A6640),
      StatusType.error: const Color(0xFFB91C1C),
      StatusType.warn: const Color(0xFFD97706),
      StatusType.muted: const Color(0xFF888885),
    }[_statusType]!;
    return Container(width: 6, height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }

  Color _statusColor() => {
        StatusType.success: const Color(0xFF1A6640),
        StatusType.error: const Color(0xFFB91C1C),
        StatusType.warn: const Color(0xFF92400E),
        StatusType.muted: const Color(0xFF888885),
      }[_statusType]!;
}
