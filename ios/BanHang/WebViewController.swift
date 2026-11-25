import UIKit
import WebKit
import AVFoundation

/// Phục vụ file giao diện (thư mục "web" trong app) qua địa chỉ banhang://app/...
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let base = Bundle.main.resourceURL?.appendingPathComponent("web") else {
            task.didFailWithError(NSError(domain: "BanHang", code: 400)); return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = base.appendingPathComponent(String(path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: "BanHang", code: 404)); return
        }
        let ext = file.pathExtension.lowercased()
        let mime = ext == "html" ? "text/html" : ext == "js" ? "text/javascript" : ext == "css" ? "text/css" : "application/octet-stream"
        let headers = ["Content-Type": mime + "; charset=utf-8", "Content-Length": String(data.count)]
        if let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(resp)
        }
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Tránh giữ vòng tham chiếu giữa WKUserContentController và màn hình.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

/// Màn hình chính: hiển thị giao diện bán hàng và xử lý các yêu cầu từ JavaScript
/// (lưu dữ liệu, quét mã, in Bluetooth, xuất file).
final class WebViewController: UIViewController, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {

    private var web: WKWebView!
    private let printer = BLEPrinter()

    private lazy var dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BanHangData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 17 / 255, green: 94 / 255, blue: 89 / 255, alpha: 1)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: "banhang")
        config.userContentController.add(WeakMessageHandler(self), name: "pos")
        config.websiteDataStore = .default()

        web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.backgroundColor = UIColor(red: 241 / 255, green: 245 / 255, blue: 244 / 255, alpha: 1)
        if #available(iOS 16.4, *) { web.isInspectable = true }

        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if let url = URL(string: "banhang://app/index.html") {
            web.load(URLRequest(url: url))
        }
    }

    // MARK: - Trả kết quả về JavaScript

    private func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }

    private func reply(_ id: String, _ ok: Bool, _ value: String) {
        let js = "nativeCb(\(jsString(id)),\(ok ? "true" : "false"),\(jsString(value)))"
        DispatchQueue.main.async { self.web.evaluateJavaScript(js, completionHandler: nil) }
    }

    private var topController: UIViewController {
        var top: UIViewController = self
        while let p = top.presentedViewController { top = p }
        return top
    }

    // MARK: - Nhận yêu cầu từ JavaScript

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let fn = body["fn"] as? String,
              let id = body["id"] as? String else { return }
        let args = body["args"] as? [Any] ?? []
        func arg(_ i: Int) -> String {
            guard i < args.count else { return "" }
            if let s = args[i] as? String { return s }
            return "\(args[i])"
        }

        switch fn {
        case "kvGet":
            let url = dataDir.appendingPathComponent(safeKey(arg(0)) + ".json")
            if let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .utf8) {
                reply(id, true, s)
            } else {
                reply(id, true, "")
            }

        case "kvSet":
            let url = dataDir.appendingPathComponent(safeKey(arg(0)) + ".json")
            do {
                try Data(arg(1).utf8).write(to: url, options: .atomic)
                reply(id, true, "")
            } catch {
                reply(id, false, "Lỗi lưu dữ liệu: \(error.localizedDescription)")
            }

        case "scan":
            openScanner(id)

        case "listPrinters":
            printer.scan(seconds: 4) { list, err in
                var obj: [String: Any] = ["ok": err == nil]
                if let err = err { obj["error"] = err } else { obj["list"] = list ?? [] }
                let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":false,\"error\":\"Lỗi\"}".utf8)
                self.reply(id, true, String(data: d, encoding: .utf8) ?? "")
            }

        case "print":
            guard let data = Data(base64Encoded: arg(1), options: .ignoreUnknownCharacters) else {
                reply(id, false, "Dữ liệu in không hợp lệ"); return
            }
            printer.printData(identifier: arg(0), data: data) { err in
                self.reply(id, err == nil, err ?? "")
            }

        case "save":
            saveAndShare(name: arg(0), base64: arg(1), id: id)

        default:
            reply(id, false, "Chức năng chưa hỗ trợ: \(fn)")
        }
    }

    private func safeKey(_ k: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let s = String(k.unicodeScalars.filter { allowed.contains($0) })
        return s.isEmpty ? "data" : s
    }

    // MARK: - Quét mã vạch

    private func openScanner(_ id: String) {
        guard AVCaptureDevice.default(for: .video) != nil else {
            reply(id, false, "Thiết bị không có camera"); return
        }
        let showScanner = {
            let vc = ScannerViewController()
            vc.modalPresentationStyle = .fullScreen
            vc.onResult = { code in
                if let code = code { self.reply(id, true, code) } else { self.reply(id, false, "cancel") }
            }
            self.topController.present(vc, animated: true)
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { showScanner() } else { self.reply(id, false, "Chưa cho phép dùng camera") }
                }
            }
        default:
            reply(id, false, "Chưa cho phép dùng camera — vào Cài đặt iPhone › Bán Hàng › bật Camera")
        }
    }

    // MARK: - Xuất file (sao lưu, báo cáo)

    private func saveAndShare(name: String, base64: String, id: String) {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            reply(id, false, "Dữ liệu file không hợp lệ"); return
        }
        let fileName = name.replacingOccurrences(of: "/", with: "-")
        // Lưu một bản vào thư mục của app (xem trong ứng dụng Tệp › Trên iPhone › Bán Hàng)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let saved = docs.appendingPathComponent(fileName)
        do {
            try data.write(to: saved, options: .atomic)
        } catch {
            reply(id, false, "Lỗi lưu file: \(error.localizedDescription)"); return
        }
        let share = UIActivityViewController(activityItems: [saved], applicationActivities: nil)
        if let pop = share.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        share.completionWithItemsHandler = { _, _, _, _ in
            self.reply(id, true, "Đã lưu \(fileName) vào ứng dụng Tệp › Bán Hàng")
        }
        topController.present(share, animated: true)
    }

    // MARK: - Hộp thoại alert / confirm / prompt của JavaScript

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        topController.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "Đồng ý", style: .default) { _ in completionHandler(true) })
        topController.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        topController.present(a, animated: true)
    }
}
