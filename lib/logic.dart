import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────
// ENUMS & MODELS
// ─────────────────────────────────────────────

enum StatusType { muted, success, error, warn }
enum BadgeMode { normal, ok, warn }

class BadgeInfo {
  final String label;
  final BadgeMode mode;
  const BadgeInfo(this.label, this.mode);
}

class AttendanceResult {
  final String message;
  final bool ok;
  final String studentName;
  final String studentCode;
  final double? score;
  const AttendanceResult({
    required this.message,
    required this.ok,
    required this.studentName,
    required this.studentCode,
    this.score,
  });
  factory AttendanceResult.fromJson(Map<String, dynamic> j) {
    final student = j['student'] as Map<String, dynamic>?;
    final py = j['pythonResult'] as Map<String, dynamic>?;
    final match = py?['match'] as Map<String, dynamic>?;
    return AttendanceResult(
      message: (j['message'] ?? '—').toString(),
      ok: j['ok'] == true,
      studentName: (student?['studentName'] ?? '—').toString(),
      studentCode: (student?['studentCode'] ?? '—').toString(),
      score: (match?['score'] as num?)?.toDouble(),
    );
  }
}

// Normalized face box (0.0–1.0 của ảnh gốc)
class FaceBox {
  final double left, top, width, height;
  const FaceBox(this.left, this.top, this.width, this.height);
  double get cx => left + width / 2;
  double get cy => top + height / 2;
}

class FaceEval {
  final bool sizeOk, zoneOk, motionOk;
  final double widthRatio;
  bool get allOk => sizeOk && zoneOk && motionOk;
  const FaceEval({required this.sizeOk, required this.zoneOk, required this.motionOk, required this.widthRatio});
}

// ─────────────────────────────────────────────
// GUIDE BOX PAINTER
// Vẽ khung hướng dẫn + góc + bounding box mặt
// ─────────────────────────────────────────────

class GuideBoxPainter extends CustomPainter {
  final List<FaceBox> faces;
  final bool faceOk;
  final bool multipleFaces;

  const GuideBoxPainter({
    required this.faces,
    required this.faceOk,
    required this.multipleFaces,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Guide box: 52% x 62% ở giữa (giống HTML gốc)
    final gw = w * 0.52;
    final gh = h * 0.62;
    final gx = (w - gw) / 2;
    final gy = (h - gh) / 2;

    // Dim vùng ngoài guide
    final dimPaint = Paint()..color = Colors.black.withOpacity(0.32);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, gy), dimPaint);
    canvas.drawRect(Rect.fromLTWH(0, gy + gh, w, h - gy - gh), dimPaint);
    canvas.drawRect(Rect.fromLTWH(0, gy, gx, gh), dimPaint);
    canvas.drawRect(Rect.fromLTWH(gx + gw, gy, w - gx - gw, gh), dimPaint);

    // Viền mờ guide box
    canvas.drawRect(
      Rect.fromLTWH(gx, gy, gw, gh),
      Paint()
        ..color = Colors.white.withOpacity(0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Corner color: xanh = ok, đỏ = nhiều mặt, trắng = chưa ok
    final cornerColor = multipleFaces
        ? const Color(0xFFEF4444)
        : faceOk
            ? const Color(0xFF22C55E)
            : Colors.white;
    final cp = Paint()
      ..color = cornerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    const c = 24.0;
    // Top-left
    _corner(canvas, cp, gx, gy, c, c);
    // Top-right
    _corner(canvas, cp, gx + gw, gy, -c, c);
    // Bottom-left
    _corner(canvas, cp, gx, gy + gh, c, -c);
    // Bottom-right
    _corner(canvas, cp, gx + gw, gy + gh, -c, -c);

    // Face bounding boxes
    for (final face in faces) {
      final fx = face.left * w;
      final fy = face.top * h;
      final fw = face.width * w;
      final fh = face.height * h;
      canvas.drawRect(
        Rect.fromLTWH(fx, fy, fw, fh),
        Paint()
          ..color = multipleFaces
              ? const Color(0xFFEF4444)
              : faceOk
                  ? const Color(0xFF22C55E)
                  : Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  void _corner(Canvas canvas, Paint p, double x, double y, double dx, double dy) {
    canvas.drawPath(
      Path()
        ..moveTo(x, y + dy)
        ..lineTo(x, y)
        ..lineTo(x + dx, y),
      p,
    );
  }

  @override
  bool shouldRepaint(GuideBoxPainter old) =>
      old.faceOk != faceOk ||
      old.multipleFaces != multipleFaces ||
      old.faces.length != faces.length;
}

// ─────────────────────────────────────────────
// APP CONFIG
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
  });
}

// ─────────────────────────────────────────────
// CORE LOGIC
// ─────────────────────────────────────────────

class FaceAttendanceLogic {
  void Function(String, StatusType)? onStatusUpdate;
  void Function(double)? onProgressUpdate;
  void Function(BadgeInfo, BadgeInfo, BadgeInfo, BadgeInfo)? onBadgesUpdate;
  void Function(AttendanceResult)? onResult;
  void Function(String)? onSuccess;
  void Function(bool)? onCameraStateChange;
  void Function(List<FaceBox>, bool faceOk, bool multi)? onFacesUpdate;
  void Function(Uint8List)? onThumbUpdate;

  CameraController? _cam;
  FaceDetector? _detector;
  bool _detecting = false;
  bool _sending = false;
  bool _running = false;
  DateTime? _stableStart;
  DateTime? _cooldownUntil;
  FaceBox? _lastGoodBox;

  CameraController? get cameraController => _cam;

  // ── Start ──
  Future<void> startAll(AppConfig cfg) async {
    _setStatus('Đang khởi tạo camera...', StatusType.muted);
    try {
      await _initCamera();
      _initDetector();
      _running = true;
      onCameraStateChange?.call(true);
      _setStatus('Camera đang chạy — đưa mặt vào khung', StatusType.success);
      _startStream(cfg);
    } catch (e) {
      _setStatus('Lỗi khởi tạo: $e', StatusType.error);
    }
  }

  // ── Stop ──
  void stopAll() {
    _running = false;
    _detecting = false;
    _stableStart = null;
    _lastGoodBox = null;
    try { _cam?.stopImageStream(); } catch (_) {}
    _cam?.dispose();
    _cam = null;
    _detector?.close();
    _detector = null;
    onCameraStateChange?.call(false);
    onProgressUpdate?.call(0);
    onFacesUpdate?.call([], false, false);
    _resetBadges();
    _setStatus('Đã tắt camera', StatusType.muted);
  }

  // ── Manual capture ──
  Future<void> manualCapture(AppConfig cfg) async {
    if (_cam == null || !_running) {
      _setStatus('Hãy mở camera trước', StatusType.error);
      return;
    }
    await _captureAndSend(cfg, manual: true);
  }

  Future<void> _initCamera() async {
    final cams = await availableCameras();
    if (cams.isEmpty) throw Exception('Không tìm thấy camera');
    final cam = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cams.first,
    );
    _cam?.dispose();
    _cam = CameraController(cam, ResolutionPreset.high, enableAudio: false);
    await _cam!.initialize();
  }

  void _initDetector() {
    _detector?.close();
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.10,
      ),
    );
  }

  void _startStream(AppConfig cfg) {
    _cam?.startImageStream((CameraImage img) async {
      if (_detecting || !_running) return;
      _detecting = true;
      try {
        await _processFrame(img, cfg);
      } catch (_) {
      } finally {
        _detecting = false;
      }
    });
  }

  Future<void> _processFrame(CameraImage img, AppConfig cfg) async {
    if (_detector == null || _cam == null) return;
    final input = _buildInput(img);
    if (input == null) return;

    final faces = await _detector!.processImage(input);
    final inCooldown = _cooldownUntil != null && DateTime.now().isBefore(_cooldownUntil!);
    if (inCooldown) _setStatus('Cooldown — chờ lần tiếp theo...', StatusType.muted);

    if (faces.length == 1) {
      final box = _norm(faces.first, img);
      final ev = _eval(box, cfg);
      onFacesUpdate?.call([box], ev.allOk, false);
      onBadgesUpdate?.call(
        const BadgeInfo('1 khuôn mặt', BadgeMode.ok),
        BadgeInfo(
          ev.sizeOk
              ? 'Khoảng cách OK (${(ev.widthRatio * 100).toStringAsFixed(0)}%)'
              : 'Khoảng cách chưa đạt (${(ev.widthRatio * 100).toStringAsFixed(0)}%)',
          ev.sizeOk ? BadgeMode.ok : BadgeMode.warn,
        ),
        BadgeInfo(ev.zoneOk ? 'Đúng vị trí' : 'Chưa vào khung', ev.zoneOk ? BadgeMode.ok : BadgeMode.warn),
        BadgeInfo(ev.motionOk ? 'Ổn định' : 'Đang rung', ev.motionOk ? BadgeMode.ok : BadgeMode.warn),
      );
      if (ev.allOk) {
        _lastGoodBox = box;
        if (!inCooldown) _setStatus('Giữ yên thêm chút...', StatusType.success);
        final ready = _updateProgress(true, cfg.holdMs);
        if (ready && !inCooldown && !_sending) await _captureAndSend(cfg);
      } else {
        _lastGoodBox = null;
        _updateProgress(false, cfg.holdMs);
        if (!inCooldown) _setStatus('Đưa mặt vào đúng vị trí', StatusType.muted);
      }
    } else if (faces.length > 1) {
      _lastGoodBox = null;
      _updateProgress(false, cfg.holdMs);
      onFacesUpdate?.call(faces.map((f) => _norm(f, img)).toList(), false, true);
      onBadgesUpdate?.call(
        BadgeInfo('${faces.length} khuôn mặt', BadgeMode.warn),
        const BadgeInfo('—', BadgeMode.normal),
        const BadgeInfo('Nhiều mặt — không chụp', BadgeMode.warn),
        const BadgeInfo('—', BadgeMode.normal),
      );
      _setStatus('Chỉ chấp nhận 1 người trong khung', StatusType.error);
    } else {
      _lastGoodBox = null;
      _updateProgress(false, cfg.holdMs);
      onFacesUpdate?.call([], false, false);
      _resetBadges();
      if (!inCooldown) _setStatus('Đưa mặt vào khung giữa', StatusType.muted);
    }
  }

  InputImage? _buildInput(CameraImage img) {
    try {
      final rot = InputImageRotationValue.fromRawValue(_cam!.description.sensorOrientation);
      final fmt = InputImageFormatValue.fromRawValue(img.format.raw);
      if (rot == null || fmt == null) return null;
      return InputImage.fromBytes(
        bytes: img.planes.first.bytes,
        metadata: InputImageMetadata(
          size: Size(img.width.toDouble(), img.height.toDouble()),
          rotation: rot,
          format: fmt,
          bytesPerRow: img.planes.first.bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  FaceBox _norm(Face f, CameraImage img) => FaceBox(
        f.boundingBox.left / img.width,
        f.boundingBox.top / img.height,
        f.boundingBox.width / img.width,
        f.boundingBox.height / img.height,
      );

  FaceEval _eval(FaceBox box, AppConfig cfg) {
    final sizeOk = box.width >= cfg.minFaceWidthRatio && box.width <= cfg.maxFaceWidthRatio;
    final zoneOk = (box.cx - 0.5).abs() <= cfg.centerToleranceX &&
        (box.cy - 0.5).abs() <= cfg.centerToleranceY;
    bool motionOk = true;
    if (_lastGoodBox != null) {
      final dist = sqrt(pow(box.cx - _lastGoodBox!.cx, 2) + pow(box.cy - _lastGoodBox!.cy, 2)) * 400;
      motionOk = dist <= cfg.maxMovePx;
    }
    return FaceEval(sizeOk: sizeOk, zoneOk: zoneOk, motionOk: motionOk, widthRatio: box.width);
  }

  bool _updateProgress(bool good, int holdMs) {
    if (good) {
      _stableStart ??= DateTime.now();
      final ms = DateTime.now().difference(_stableStart!).inMilliseconds;
      onProgressUpdate?.call((ms / holdMs).clamp(0.0, 1.0));
      return ms >= holdMs;
    }
    _stableStart = null;
    onProgressUpdate?.call(0);
    return false;
  }

  Future<void> _captureAndSend(AppConfig cfg, {bool manual = false}) async {
    if (_sending || _cam == null) return;
    _sending = true;
    try {
      _setStatus(manual ? 'Đang chụp thủ công...' : 'Đủ điều kiện, đang tự chụp...', StatusType.warn);
      final xf = await _cam!.takePicture();
      final bytes = await xf.readAsBytes();
      onThumbUpdate?.call(bytes);

      _setStatus('Đang gửi ảnh lên server...', StatusType.muted);

      final uri = Uri.parse(cfg.apiUrl);
      final req = http.MultipartRequest('POST', uri)
        ..fields['ModuleSessionId'] = cfg.moduleSessionId.toString()
        ..fields['Thresh'] = cfg.thresh.toString()
        ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'autocapture.jpg'));

      final streamed = await req.send().timeout(const Duration(seconds: 15));
      final resp = await http.Response.fromStream(streamed);

      Map<String, dynamic> json;
      try {
        json = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        throw Exception('Response không hợp lệ: ${resp.body}');
      }

      final result = AttendanceResult.fromJson(json);
      onResult?.call(result);

      if (resp.statusCode < 200 || resp.statusCode >= 300 || !result.ok) {
        _setStatus(result.message.isNotEmpty ? result.message : 'Điểm danh thất bại', StatusType.error);
      } else {
        final name = (result.studentName != '—' && result.studentName.isNotEmpty)
            ? result.studentName
            : result.message;
        onSuccess?.call(name);
        _setStatus('Điểm danh thành công', StatusType.success);
      }

      _cooldownUntil = DateTime.now().add(Duration(milliseconds: cfg.cooldownMs));
      _stableStart = null;
      onProgressUpdate?.call(0);
    } catch (e) {
      _setStatus('Lỗi: $e', StatusType.error);
    } finally {
      _sending = false;
    }
  }

  void _setStatus(String t, StatusType s) => onStatusUpdate?.call(t, s);
  void _resetBadges() => onBadgesUpdate?.call(
        const BadgeInfo('Chưa phát hiện mặt', BadgeMode.normal),
        const BadgeInfo('Khoảng cách: —', BadgeMode.normal),
        const BadgeInfo('Vị trí: —', BadgeMode.normal),
        const BadgeInfo('Ổn định: —', BadgeMode.normal),
      );
}
