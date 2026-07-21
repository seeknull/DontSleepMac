import Cocoa
import WebKit

let svgPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let size = 1024.0

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let svg = try! String(contentsOfFile: svgPath, encoding: .utf8)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
webView.loadHTMLString("<html><body style='margin:0'>\(svg)</body></html>", baseURL: nil)

class Nav: NSObject, WKNavigationDelegate {
    let out: String; let size: Double
    init(_ o: String, _ s: Double){ out=o; size=s }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x:0,y:0,width:size,height:size)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3){
            w.takeSnapshot(with: cfg){ img, err in
                guard let img = img, let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("snapshot failed"); exit(1)
                }
                try! png.write(to: URL(fileURLWithPath: self.out))
                print("wrote \(self.out)"); exit(0)
            }
        }
    }
}
let nav = Nav(outPath, size)
webView.navigationDelegate = nav
// keep a strong ref
withExtendedLifetime(nav){ app.run() }
