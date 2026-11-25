package vn.banhang.app;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothSocket;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Base64;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.webkit.WebViewAssetLoader;

import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanner;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.util.Set;
import java.util.UUID;

/**
 * App bán hàng: giao diện là trang web trong thư mục assets (index.html),
 * phần Java này lo những việc trang web không tự làm được trên điện thoại:
 *  - Quét mã vạch bằng camera (Google ML Kit)
 *  - In ra máy in nhiệt Bluetooth (kết nối SPP, gửi lệnh ESC/POS)
 *  - Lưu file sao lưu / báo cáo vào thư mục Download
 *  - Chọn file Excel/CSV để nhập hàng
 */
public class MainActivity extends Activity {

    private static final int REQ_FILE = 1001;
    private static final int REQ_BT = 1002;
    private static final UUID SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");

    private WebView web;
    private ValueCallback<Uri[]> fileCallback;

    private final Object printLock = new Object();
    private BluetoothSocket socket;
    private String socketAddress;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setStatusBarColor(0xFF115E59);

        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        s.setTextZoom(100);

        final WebViewAssetLoader loader = new WebViewAssetLoader.Builder()
                .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                .build();

        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return loader.shouldInterceptRequest(request.getUrl());
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                Intent i = new Intent(Intent.ACTION_GET_CONTENT);
                i.addCategory(Intent.CATEGORY_OPENABLE);
                i.setType("*/*");
                try {
                    startActivityForResult(Intent.createChooser(i, "Chọn file"), REQ_FILE);
                } catch (Exception e) {
                    fileCallback = null;
                    return false;
                }
                return true;
            }
        });

        web.addJavascriptInterface(new Bridge(), "Android");
        web.loadUrl("https://appassets.androidplatform.net/assets/index.html");

        if (Build.VERSION.SDK_INT >= 31 && !hasBtPermission()) {
            requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT}, REQ_BT);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_FILE && fileCallback != null) {
            Uri[] result = null;
            if (resultCode == RESULT_OK && data != null && data.getData() != null) {
                result = new Uri[]{data.getData()};
            }
            fileCallback.onReceiveValue(result);
            fileCallback = null;
        }
    }

    @Override
    public void onBackPressed() {
        web.evaluateJavascript("window.handleBack ? handleBack() : false", value -> {
            if (!"true".equals(value)) finish();
        });
    }

    @Override
    protected void onDestroy() {
        closeSocket();
        super.onDestroy();
    }

    // ------------------------------------------------------------------ tiện ích

    private boolean hasBtPermission() {
        return Build.VERSION.SDK_INT < 31
                || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
    }

    private void callback(String id, boolean ok, String value) {
        final String code = "nativeCb(" + JSONObject.quote(id) + "," + ok + "," + JSONObject.quote(value == null ? "" : value) + ")";
        runOnUiThread(() -> web.evaluateJavascript(code, null));
    }

    private void closeSocket() {
        try {
            if (socket != null) socket.close();
        } catch (IOException ignored) {
        }
        socket = null;
        socketAddress = null;
    }

    @SuppressWarnings("MissingPermission")
    private OutputStream openPrinter(String address) throws Exception {
        if (socket != null && socket.isConnected() && address.equals(socketAddress)) {
            return socket.getOutputStream();
        }
        closeSocket();
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null) throw new Exception("Điện thoại không có Bluetooth");
        if (!adapter.isEnabled()) throw new Exception("Bluetooth đang tắt");
        adapter.cancelDiscovery();
        BluetoothDevice device = adapter.getRemoteDevice(address);
        BluetoothSocket s;
        try {
            s = device.createRfcommSocketToServiceRecord(SPP_UUID);
            s.connect();
        } catch (IOException first) {
            // Một số máy in giá rẻ cần kết nối thẳng vào kênh 1
            Method m = device.getClass().getMethod("createRfcommSocket", int.class);
            s = (BluetoothSocket) m.invoke(device, 1);
            s.connect();
        }
        socket = s;
        socketAddress = address;
        return s.getOutputStream();
    }

    // ------------------------------------------------------------------ cầu nối JavaScript

    private class Bridge {

        @JavascriptInterface
        public boolean isNative() {
            return true;
        }

        /** Mở camera quét mã vạch. Kết quả trả về qua nativeCb(id, ok, mã). */
        @JavascriptInterface
        public void scan(final String id) {
            runOnUiThread(() -> {
                GmsBarcodeScannerOptions options = new GmsBarcodeScannerOptions.Builder()
                        .setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS)
                        .build();
                GmsBarcodeScanner scanner = GmsBarcodeScanning.getClient(MainActivity.this, options);
                scanner.startScan()
                        .addOnSuccessListener(barcode -> {
                            String v = barcode.getRawValue();
                            callback(id, v != null, v != null ? v : "Không đọc được mã");
                        })
                        .addOnCanceledListener(() -> callback(id, false, "cancel"))
                        .addOnFailureListener(e -> callback(id, false, String.valueOf(e.getMessage())));
            });
        }

        /** Danh sách thiết bị Bluetooth đã ghép đôi. */
        @JavascriptInterface
        @SuppressWarnings("MissingPermission")
        public String printers() {
            try {
                JSONObject r = new JSONObject();
                if (!hasBtPermission()) {
                    runOnUiThread(() -> requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT}, REQ_BT));
                    return r.put("ok", false).put("error", "Hãy cho phép quyền Bluetooth (Thiết bị ở gần) rồi bấm lại").toString();
                }
                BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
                if (adapter == null) return r.put("ok", false).put("error", "Điện thoại không có Bluetooth").toString();
                if (!adapter.isEnabled()) return r.put("ok", false).put("error", "Bluetooth đang tắt — hãy bật Bluetooth").toString();
                JSONArray list = new JSONArray();
                Set<BluetoothDevice> devices = adapter.getBondedDevices();
                if (devices != null) {
                    for (BluetoothDevice d : devices) {
                        list.put(new JSONObject().put("name", d.getName() == null ? "" : d.getName()).put("address", d.getAddress()));
                    }
                }
                return r.put("ok", true).put("list", list).toString();
            } catch (Exception e) {
                return "{\"ok\":false,\"error\":" + JSONObject.quote("Lỗi Bluetooth: " + e.getMessage()) + "}";
            }
        }

        /** Bản bất đồng bộ của printers() (dùng chung giao diện với iPhone). */
        @JavascriptInterface
        public void listPrinters(final String id) {
            callback(id, true, printers());
        }

        /** Bản bất đồng bộ của saveFile() (dùng chung giao diện với iPhone). */
        @JavascriptInterface
        public void save(final String name, final String base64, final String mime, final String id) {
            String msg = saveFile(name, base64, mime);
            callback(id, !msg.startsWith("Lỗi"), msg);
        }

        /** Gửi dữ liệu ESC/POS (base64) tới máy in. */
        @JavascriptInterface
        public void print(final String address, final String base64, final String id) {
            new Thread(() -> {
                String error = null;
                synchronized (printLock) {
                    byte[] data = Base64.decode(base64, Base64.DEFAULT);
                    for (int attempt = 0; attempt < 2; attempt++) {
                        try {
                            if (!hasBtPermission()) throw new Exception("Chưa cấp quyền Bluetooth");
                            OutputStream os = openPrinter(address);
                            for (int i = 0; i < data.length; i += 512) {
                                os.write(data, i, Math.min(512, data.length - i));
                                os.flush();
                                Thread.sleep(20);
                            }
                            error = null;
                            break;
                        } catch (Exception e) {
                            closeSocket();
                            error = e.getMessage() == null ? e.toString() : e.getMessage();
                        }
                    }
                }
                callback(id, error == null, error);
            }).start();
        }

        /** Lưu file (sao lưu, báo cáo) vào thư mục Download/BanHang. */
        @JavascriptInterface
        public String saveFile(String name, String base64, String mime) {
            try {
                byte[] data = Base64.decode(base64, Base64.DEFAULT);
                if (Build.VERSION.SDK_INT >= 29) {
                    ContentValues v = new ContentValues();
                    v.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
                    v.put(MediaStore.MediaColumns.MIME_TYPE, mime);
                    v.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/BanHang");
                    Uri uri = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
                    if (uri == null) throw new IOException("không tạo được file");
                    try (OutputStream os = getContentResolver().openOutputStream(uri)) {
                        if (os == null) throw new IOException("không mở được file");
                        os.write(data);
                    }
                    return "Đã lưu vào Download/BanHang/" + name;
                } else {
                    File dir = new File(getExternalFilesDir(null), "BanHang");
                    if (!dir.exists() && !dir.mkdirs()) throw new IOException("không tạo được thư mục");
                    File f = new File(dir, name);
                    try (FileOutputStream os = new FileOutputStream(f)) {
                        os.write(data);
                    }
                    return "Đã lưu: " + f.getAbsolutePath();
                }
            } catch (Exception e) {
                return "Lỗi lưu file: " + e.getMessage();
            }
        }
    }
}
