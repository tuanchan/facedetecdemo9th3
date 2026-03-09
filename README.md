# 📱 Điểm Danh Khuôn Mặt — Flutter iOS App

Ứng dụng điểm danh bằng nhận diện khuôn mặt. Build unsigned IPA qua GitHub Actions, cài bằng **ESign** — không cần Apple Developer Account, không cần certificate.

---

## 🗂️ Cấu trúc (3 file chính)

```
lib/
├── main.dart      # Entry point, orientation lock
├── app.dart       # UI, config model, screen, overlays
└── logic.dart     # Camera, ML Kit face detection, API call, audio
```

---

## ⚙️ Cấu hình có thể chỉnh trong app

| Trường | Mặc định | Mô tả |
|---|---|---|
| API URL | `https://your-api.example.com/...` | Endpoint điểm danh |
| Session ID | `1` | Module session ID |
| Thresh | `0.36` | Ngưỡng nhận diện khuôn mặt |
| Hold (ms) | `1200` | Thời gian giữ mặt ổn định trước khi chụp |
| Cooldown (ms) | `4000` | Thời gian chờ giữa các lần điểm danh |
| Min Face Ratio | `0.20` | Tỷ lệ mặt/màn hình tối thiểu |
| Max Face Ratio | `0.72` | Tỷ lệ mặt/màn hình tối đa |
| Center Tol X/Y | `0.18/0.22` | Độ lệch tâm cho phép |
| Max Move (px) | `18` | Pixel tối đa được phép di chuyển |

---

## 🚀 Build IPA qua GitHub Actions

### Tự động (mỗi push lên main)
```
git push origin main
```
→ Actions chạy → tải IPA ở tab **Actions → Artifacts**

### Thủ công với API URL custom
- Vào **Actions → Build Unsigned IPA → Run workflow**
- Điền API URL vào field `api_url` (tuỳ chọn)

### Release (gán tag)
```bash
git tag v1.0.0
git push origin v1.0.0
```
→ IPA xuất hiện trong **Releases**

---

## 📲 Cài lên iPhone qua ESign

1. Tải `face-attendance-unsigned.ipa` từ Actions artifacts
2. Gửi vào iPhone qua **AirDrop**, Files app, hoặc web server local
3. Mở **ESign** → chọn IPA → **Sign** (dùng cert free tự tạo trong ESign)
4. Sau khi sign → Install
5. Vào **Settings → General → VPN & Device Management** → Trust developer
6. Mở app ✅

> 📥 ESign app: https://esign.yyyue.xyz  
> (Hoặc tìm "ESign IPA" trên AltStore / TrollStore nếu có)

---

## 🛠️ Phát triển local

```bash
# Cài dependencies
flutter pub get

# Chạy trên simulator (iOS)
flutter run -d <device_id>

# Build debug
flutter build ios --debug --no-codesign

# Build release unsigned
flutter build ios --release --no-codesign
```

---

## 📦 Dependencies

| Package | Công dụng |
|---|---|
| `camera` | Camera preview + capture |
| `google_mlkit_face_detection` | Nhận diện khuôn mặt on-device |
| `http` | Gửi ảnh lên API |
| `audioplayers` | Phát âm thanh thành công |
| `permission_handler` | Xin quyền camera |

---

## 🔊 Âm thanh

- Đặt file `ting.mp3` vào `assets/sounds/`
- Hoặc để trống → app im lặng khi thành công
- Có thể thay đường dẫn trong config `audioPath`
