import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'app.dart';

// ─────────────────────────────────────────────
// ENUMS & DATA MODELS
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

  factory AttendanceResult.fromJson(Map<String, dynamic> json) {
    final student = json['student'] as Map<String, dynamic>?;
    final pythonResult = json['pythonResult'] as Map<String, dynamic>?;
    final match = pythonResult?['match'] as Map<String, dynamic>?;
    return AttendanceResult(
      message: json['message']?.toString() ?? '—',
      ok: json['ok'] == true,
      studentName: student?['studentName']?.toString() ?? '—',
      studentCode: student?['studentCode']?.toString() ?? '—',
      score: (match?['score'] as num?)?.toDouble(),
    );
  }
}

class _FaceBox {
  final double left, top, width, height;
  const _FaceBox(this.left, this.top, this.width, this.height);
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;
}

// ─────────────────────────────────────────────
// CORE LOGIC
// ─────────────────────────────────────────────

class FaceAttendanceLogic {
  // Callbacks to UI
  void Function(String text, StatusType type)? onStatusUpdate;
  void Function(double progress)? onProgressUpdate;
  void Function(BadgeInfo face, BadgeInfo size, BadgeInfo zone, BadgeInfo stable)? onBadgesUpdate;
  void Function(AttendanceResult result)? onResult;
  void Function(String name)? onSuccess;
  void Function(bool running)? onCameraStateChange;

  // Camera & detection
  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  bool _isDetecting = false;
  bool _isSending = false;
  bool _isCameraRunning = false;

  // Timing state
  DateTime? _stableStartAt;
  DateTime? _cooldownUntil;
  _FaceBox? _lastGoodBox;
  Uint8List? _lastCapturedBytes;

  // Audio
  final AudioPlayer _audioPlayer = AudioPlayer();

  Uint8List? get lastCapturedImageBytes => _lastCapturedBytes;

  // ─── Start everything ───
  Future<void> startAll(AppConfig config) async {
    try {
      _setStatus('Đang khởi tạo camera...', StatusType.muted);
      await _initCamera();
      await _initFaceDetector();
      _isCameraRunning = true;
      onCameraStateChange?.call(true);
      _setStatus('Camera đang chạy — đưa mặt vào khung', StatusType.success);
      _startDetectionLoop(config);
    } catch (e) {
      _setStatus('Không khởi động được: $e', StatusType.error);
    }
  }

  // ─── Stop everything ───
  void stopAll() {
    _isCameraRunning = false;
    _isDetecting = false;
    _stableStartAt = null;
    _lastGoodBox = null;
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _cameraController = null;
    _faceDetector?.close();
    _faceDetector = null;
    onCameraStateChange?.call(false);
    onProgressUpdate?.call(0);
    _resetBadges();
    _setStatus('Đã tắt camera', StatusType.muted);
  }

  // ─── Manual capture ───
  Future<void> manualCapture(AppConfig config) async {
    if (_cameraController == null || !_isCameraRunning) {
      _setStatus('Hãy mở camera trước', StatusType.error);
      return;
    }
    await _captureAndSend(config, reason: 'manual');
  }

  // ─── Camera preview widget ───
  Widget? cameraPreviewWidget(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return null;
    return CameraPreview(_cameraController!);
  }

  // ─── Init camera ───
  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw Exception('Không tìm thấy camera');

    // Prefer front camera
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController?.dispose();
    _cameraController = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await _cameraController!.initialize();
  }

  // ─── Init face detector ───
  Future<void> _initFaceDetector() async {
    _faceDetector?.close();
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: false,
        enableLandmarks: false,
        enableContours: false,
        enableTracking: false,
        minFaceSize: 0.15,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
  }

  // ─── Detection loop ───
  void _startDetectionLoop(AppConfig config) {
    _cameraController?.startImageStream((CameraImage image) async {
      if (_isDetecting || !_isCameraRunning) return;
      _isDetecting = true;
      try {
        await _processFrame(image, config);
      } catch (_) {} finally {
        _isDetecting = false;
      }
    });
  }

  Future<void> _processFrame(CameraImage image, AppConfig config) async {
    if (_faceDetector == null || _cameraController == null) return;

    final inputImage = _buildInputImage(image);
    if (inputImage == null) return;

    final faces = await _faceDetector!.processImage(inputImage);

    final inCooldown = _cooldownUntil != null && DateTime.now().isBefore(_cooldownUntil!);

    if (inCooldown) {
      _setStatus('Cooldown — chờ lần tiếp theo...', StatusType.muted);
    }

    if (faces.length == 1) {
      final face = faces.first;
      final box = _faceBox(face, image);
      final check = _evaluateFace(box, image, config);

      onBadgesUpdate?.call(
        const BadgeInfo('1 khuôn mặt', BadgeMode.ok),
        BadgeInfo(
          check.sizeOk ? 'Khoảng cách OK (${(check.widthRatio * 100).toStringAsFixed(0)}%)' : 'Khoảng cách chưa đạt (${(check.widthRatio * 100).toStringAsFixed(0)}%)',
          check.sizeOk ? BadgeMode.ok : BadgeMode.warn,
        ),
        BadgeInfo(check.zoneOk ? 'Đúng vị trí' : 'Chưa vào khung', check.zoneOk ? BadgeMode.ok : BadgeMode.warn),
        BadgeInfo(check.motionOk ? 'Ổn định' : 'Đang rung', check.motionOk ? BadgeMode.ok : BadgeMode.warn),
      );

      if (check.allOk) {
        _lastGoodBox = box;
        if (!inCooldown) _setStatus('Giữ yên thêm chút...', StatusType.success);
        final ready = _updateHoldProgress(true, config.holdMs);
        if (ready && !inCooldown && !_isSending) {
          await _captureAndSend(config);
        }
      } else {
        _lastGoodBox = null;
        _updateHoldProgress(false, config.holdMs);
        if (!inCooldown) _setStatus('Đưa mặt vào đúng vị trí', StatusType.muted);
      }
    } else if (faces.length > 1) {
      _lastGoodBox = null;
      _updateHoldProgress(false, config.holdMs);
      onBadgesUpdate?.call(
        BadgeInfo('${faces.length} khuôn mặt', BadgeMode.warn),
        const BadgeInfo('—', BadgeMode.normal),
        const BadgeInfo('Nhiều mặt — không chụp', BadgeMode.warn),
        const BadgeInfo('—', BadgeMode.normal),
      );
      _setStatus('Chỉ chấp nhận 1 người trong khung', StatusType.error);
    } else {
      _lastGoodBox = null;
      _updateHoldProgress(false, config.holdMs);
      _resetBadges();
      if (!inCooldown) _setStatus('Đưa mặt vào khung giữa', StatusType.muted);
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    try {
      final camera = _cameraController!.description;
      final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
      if (rotation == null) return null;

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;

      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  _FaceBox _faceBox(Face face, CameraImage image) {
    final r = face.boundingBox;
    return _FaceBox(
      r.left / image.width,
      r.top / image.height,
      r.width / image.width,
      r.height / image.height,
    );
  }

  ({bool sizeOk, bool zoneOk, bool motionOk, bool allOk, double widthRatio}) _evaluateFace(
    _FaceBox box, CameraImage image, AppConfig config) {
    final sizeOk = box.width >= config.minFaceWidthRatio && box.width <= config.maxFaceWidthRatio;
    final zoneOk = (box.centerX - 0.5).abs() <= config.centerToleranceX &&
        (box.centerY - 0.5).abs() <= config.centerToleranceY;
    bool motionOk = true;
    if (_lastGoodBox != null) {
      final dx = (box.centerX - _lastGoodBox!.centerX) * image.width;
      final dy = (box.centerY - _lastGoodBox!.centerY) * image.height;
      motionOk = sqrt(dx * dx + dy * dy) <= config.maxMovePx;
    }
    return (
      sizeOk: sizeOk,
      zoneOk: zoneOk,
      motionOk: motionOk,
      allOk: sizeOk && zoneOk && motionOk,
      widthRatio: box.width,
    );
  }

  bool _updateHoldProgress(bool isGood, int holdMs) {
    if (isGood) {
      _stableStartAt ??= DateTime.now();
      final elapsed = DateTime.now().difference(_stableStartAt!).inMilliseconds;
      final pct = (elapsed / holdMs).clamp(0.0, 1.0);
      onProgressUpdate?.call(pct);
      return elapsed >= holdMs;
    } else {
      _stableStartAt = null;
      onProgressUpdate?.call(0);
      return false;
    }
  }

  // ─── Capture & send ───
  Future<void> _captureAndSend(AppConfig config, {String reason = 'auto'}) async {
    if (_isSending) return;
    _isSending = true;
    try {
      _setStatus(reason == 'manual' ? 'Đang chụp thủ công...' : 'Đủ điều kiện, đang tự chụp...', StatusType.warn);

      // Capture frame
      final xFile = await _cameraController!.takePicture();
      final bytes = await xFile.readAsBytes();
      _lastCapturedBytes = bytes;

      _setStatus('Đang gửi ảnh lên server...', StatusType.muted);
      await _sendToApi(bytes, config);

      _cooldownUntil = DateTime.now().add(Duration(milliseconds: config.cooldownMs));
      _stableStartAt = null;
      onProgressUpdate?.call(0);
    } catch (e) {
      _setStatus('Lỗi khi gửi ảnh: $e', StatusType.error);
    } finally {
      _isSending = false;
    }
  }

  Future<void> _sendToApi(Uint8List imageBytes, AppConfig config) async {
    final uri = Uri.parse(config.apiUrl);
    final request = http.MultipartRequest('POST', uri)
      ..fields['ModuleSessionId'] = config.moduleSessionId.toString()
      ..fields['Thresh'] = config.thresh.toString()
      ..files.add(http.MultipartFile.fromBytes(
        'file', imageBytes,
        filename: 'autocapture.jpg',
      ));

    final streamedResponse = await request.send().timeout(const Duration(seconds: 15));
    final response = await http.Response.fromStream(streamedResponse);
    final body = response.body;

    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Response không hợp lệ: $body');
    }

    final result = AttendanceResult.fromJson(json);
    onResult?.call(result);

    if (!response.ok || result.ok == false) {
      _setStatus(result.message.isNotEmpty ? result.message : 'Điểm danh thất bại', StatusType.error);
    } else {
      final name = result.studentName.isNotEmpty && result.studentName != '—'
          ? result.studentName
          : result.message;
      await _playSuccessSound(config.audioPath);
      onSuccess?.call(name);
      _setStatus('Điểm danh thành công', StatusType.success);
    }
  }

  // ─── Audio ───
  Future<void> _playSuccessSound(String path) async {
    try {
      if (path.trim().isNotEmpty) {
        await _audioPlayer.play(AssetSource(path.trim()));
      } else {
        // Default: system short sound or silent
        await _audioPlayer.play(AssetSource('sounds/ting.mp3'));
      }
    } catch (_) {
      // Silently fail — audio is optional
    }
  }

  // ─── Helpers ───
  void _setStatus(String text, StatusType type) {
    onStatusUpdate?.call(text, type);
  }

  void _resetBadges() {
    onBadgesUpdate?.call(
      const BadgeInfo('Chưa phát hiện mặt', BadgeMode.normal),
      const BadgeInfo('Khoảng cách: —', BadgeMode.normal),
      const BadgeInfo('Vị trí: —', BadgeMode.normal),
      const BadgeInfo('Ổn định: —', BadgeMode.normal),
    );
  }
}

extension on http.Response {
  bool get ok => statusCode >= 200 && statusCode < 300;
}
