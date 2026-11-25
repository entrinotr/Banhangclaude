# Phần mềm Bán Hàng — Máy tính, Android và iPhone

Một giao diện dùng chung cho cả 3 nơi:

| Thư mục | Dùng cho |
|---|---|
| `web/index.html` | **Bản gốc giao diện.** Mở trực tiếp bằng Chrome/Edge trên máy tính. |
| `android/` | Mã nguồn app Android (.apk) |
| `ios/` | Mã nguồn app iPhone (.ipa) |
| `.github/workflows/` | Cấu hình để GitHub tự build ra APK và IPA |

Muốn sửa giao diện → chỉ sửa `web/index.html`, GitHub sẽ tự đưa vào cả 2 app khi build.

---

## Bước 1 — Cho GitHub build app (miễn phí, không cần cài gì)

1. Tạo tài khoản tại https://github.com và đăng nhập.
2. Bấm **New repository** → tên `BanHang` → chọn **Private** → **Create repository**.
3. Bấm **uploading an existing file**, kéo **toàn bộ nội dung bên trong thư mục `BanHangApp`** vào → **Commit changes**.
   - Thư mục `.github` là thư mục ẩn. Trên Windows bật *View → Show → Hidden items*; trên Mac bấm `Cmd + Shift + .` để thấy và kéo cả nó vào.
4. Mở tab **Actions**. Sẽ có 2 dòng chạy: **Build Android APK** và **Build iPhone IPA** (mỗi cái 5–10 phút).
5. Khi có dấu ✅, bấm vào từng dòng → mục **Artifacts** ở cuối trang → tải:
   - **BanHang-Android-APK** → bên trong có `BanHang.apk`
   - **BanHang-iPhone-IPA** → bên trong có `BanHang.ipa`

Nếu có dấu ❌ đỏ: bấm vào, chụp màn hình phần báo lỗi màu đỏ và gửi lại để sửa.

---

## Bước 2a — Cài lên Android

1. Gửi `BanHang.apk` sang điện thoại (Zalo, cáp USB, Drive…) và mở nó.
2. Cho phép "Cài ứng dụng không rõ nguồn gốc".
3. Lần đầu mở app cần có mạng khoảng 1 phút (để tải bộ quét mã của Google). Sau đó chạy offline.
4. Máy in: ghép đôi trong **Cài đặt điện thoại → Bluetooth** trước (PIN thường là `0000` hoặc `1234`), rồi vào app **⚙️ Cài đặt → Tìm máy in**.

## Bước 2b — Cài lên iPhone (bằng Apple ID của bạn, không qua App Store)

Cần một máy tính Windows hoặc Mac và cáp cắm iPhone.

1. Trên máy tính, cài **Sideloadly**: https://sideloadly.io
   - Windows: cài thêm **iTunes** và **iCloud** bản tải từ trang Apple (không dùng bản Microsoft Store).
2. Cắm iPhone vào máy tính, mở khóa iPhone và bấm **Tin cậy** nếu được hỏi.
3. Mở Sideloadly → kéo file `BanHang.ipa` vào → nhập **Apple ID** của bạn → bấm **Start** → nhập mật khẩu Apple ID khi được hỏi
   (Sideloadly gửi thẳng tới Apple để ký app; nên dùng mật khẩu riêng cho ứng dụng nếu có bật xác thực 2 lớp theo hướng dẫn của Sideloadly).
4. Trên iPhone:
   - **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển** → bật → khởi động lại máy (iOS 16 trở lên).
   - **Cài đặt → Cài đặt chung → Quản lý VPN & Thiết bị** → chọn Apple ID của bạn → **Tin cậy**.
5. Mở app **Bán Hàng**. Cho phép **Camera** và **Bluetooth** khi được hỏi.
6. Máy in: **không cần ghép đôi trong Cài đặt iPhone**. Bật máy in, để gần điện thoại → vào app **⚙️ Cài đặt → Tìm máy in** → chọn máy in → **In thử hóa đơn**.

### Lưu ý quan trọng khi dùng Apple ID miễn phí
- App **hết hạn sau 7 ngày**. Khi đó cắm máy và bấm **Start** lại trong Sideloadly với cùng file `.ipa` và cùng Apple ID → app được gia hạn, **dữ liệu vẫn giữ nguyên**.
  Sideloadly có chế độ **tự gia hạn qua Wi-Fi** nếu máy tính để cùng mạng với iPhone.
- **Đừng xóa app** khi hết hạn — xóa app là mất dữ liệu. Hãy **Sao lưu ra file** thường xuyên (Cài đặt → Sao lưu).
  File sao lưu nằm trong ứng dụng **Tệp → Trên iPhone → Bán Hàng**, và có thể gửi qua Zalo/AirDrop.
- Khi dùng ổn định, có thể đăng ký Apple Developer (99 USD/năm) để app dùng được 1 năm và cài qua TestFlight.

---

## Máy in Bluetooth

- Hỗ trợ máy in nhiệt ESC/POS khổ **58mm** (máy cầm tay) và **80mm**. Chọn khổ giấy trong Cài đặt.
- Hóa đơn được in dạng hình ảnh nên **đủ dấu tiếng Việt**.
- iPhone chỉ kết nối được máy in có **Bluetooth LE (BLE)**. Nếu bấm Tìm máy in mà không thấy, hãy kiểm tra máy in có hỗ trợ BLE / iOS không.
- In được cả **tem mã vạch** (Kho hàng → tích chọn hàng → In tem mã vạch).

## Dữ liệu

- Mỗi thiết bị lưu dữ liệu riêng, offline hoàn toàn.
- File sao lưu (.json) dùng chung được giữa máy tính, Android và iPhone: sao lưu ở máy này → **Khôi phục** ở máy kia.
