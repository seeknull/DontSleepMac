import Cocoa
import WebKit

let svgPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let W = Double(CommandLine.arguments[3]) ?? 1024
let H = Double(CommandLine.arguments[4]) ?? 1024

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let svg = try! String(contentsOfFile: svgPath, encoding: .utf8)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: W, height: H))
webView.loadHTMLString("<html><body style='margin:0;padding:0'>\(svg)</body></html>", baseURL: nil)

class Nav: NSObject, WKNavigationDelegate {
    let out: String; let w: Double; let h: Double
    init(_ o: String, _ w: Double, _ h: Double){ out=o; self.w=w; self.h=h }
    func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x:0,y:0,width:w,height:h)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3){
            wv.takeSnapshot(with: cfg){ img, err in
                guard let img = img, let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("fail"); exit(1) }
                try! png.write(to: URL(fileURLWithPath: self.out)); print("wrote \(self.out)"); exit(0)
            }
        }
    }
}
let nav = Nav(outPath, W, H)
webView.navigationDelegate = nav
withExtendedLifetime(nav){ app.run() }
