// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors
//
// SPIKE PROBE, not shipped. Answers, inside a sandbox signed like Kinora's wallpaper plug-in,
// the parts of the WebKit-in-plug-in question that don't need WallpaperAgent:
//
//   1. Does a WKWebView load a local page from Kinora's library folder with only the plug-in's
//      entitlements (no network)?
//   2. Does the page keep animating (requestAnimationFrame, CSS, timers) when its window is
//      hidden, as it would be in a plug-in that never shows a window of its own?
//   3. Can the page's pixels be re-hosted through a remote CAContext, the way the plug-in hands
//      WallpaperAgent its layers? A visible window of this process hosts the remote context with
//      a CALayerHost, standing in for WallpaperAgent, and is captured to see what arrives.
//
// Every private interface (CAContext, CALayerHost, a WKWebView switch, CGWindowListCreateImage
// through dlsym) is looked up at runtime and reported when missing. Output: one JSON object per
// line on stdout, prefixed "WEBPROBE ". See run.sh.

import AppKit
import Darwin
import QuartzCore
import WebKit

@MainActor func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    print("WEBPROBE " + String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

@MainActor func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Waits for a callback-style result, giving up after `seconds`.
@MainActor final class Pending<Value> {
    var value: Value?
    var done = false
    func set(_ value: Value?) { self.value = value; done = true }
    func wait(_ seconds: Double) async -> Value? {
        let deadline = Date().addingTimeInterval(seconds)
        while !done, Date() < deadline { await pause(0.05) }
        return value
    }
}

@MainActor final class NavigationWatcher: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: String?
    var webContentTerminated = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = "\(error)" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = "\(error)" }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webContentTerminated = true }
}

/// QuartzCore's private remote context: the plug-in's way of handing WallpaperAgent a layer tree.
@MainActor final class RemoteContext {
    let object: NSObject
    init?() {
        let create = NSSelectorFromString("remoteContextWithOptions:")
        guard let cls = NSClassFromString("CAContext") as? NSObject.Type, cls.responds(to: create),
              let context = cls.perform(create, with: NSDictionary())?.takeUnretainedValue() as? NSObject
        else { return nil }
        object = context
    }
    var contextID: UInt32 { (object.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0 }
    func host(_ layer: CALayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        object.setValue(layer, forKey: "layer")
        CATransaction.commit()
    }
    func invalidate() {
        let selector = NSSelectorFromString("invalidate")
        if object.responds(to: selector) { object.perform(selector) }
    }
}

/// A layer that shows another context's layers, as WallpaperAgent shows the plug-in's.
@MainActor func layerHost(for contextID: UInt32) -> CALayer? {
    guard let cls = NSClassFromString("CALayerHost") as? CALayer.Type else { return nil }
    let host = cls.init()
    host.setValue(NSNumber(value: contextID), forKey: "contextId")
    return host
}

/// Describes a layer tree: class names, and the context IDs of any layer hosts in it.
@MainActor func describe(_ layer: CALayer?, depth: Int = 0, into lines: inout [String], hosts: inout [UInt32]) {
    guard let layer, depth < 8, lines.count < 60 else { return }
    let name = String(describing: type(of: layer))
    var line = String(repeating: " ", count: depth) + name
    if name.contains("LayerHost"), let id = (layer.value(forKey: "contextId") as? NSNumber)?.uint32Value {
        line += " contextId=\(id)"
        hosts.append(id)
    }
    if layer.contents != nil { line += " contents=\(String(describing: type(of: layer.contents!)))" }
    lines.append(line)
    for sub in layer.sublayers ?? [] { describe(sub, depth: depth + 1, into: &lines, hosts: &hosts) }
}

/// Captures one of this process's own windows. CGWindowListCreateImage is unavailable to new
/// builds in Swift, so it is looked up at runtime; capturing your own window needs no permission.
@MainActor func capture(_ window: NSWindow) -> CGImage? {
    typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let create = unsafeBitCast(symbol, to: Create.self)
    // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution
    return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 4))?.takeRetainedValue()
}

/// A small summary of an image: whether it is one flat colour, and a coarse fingerprint to
/// compare two captures with.
func summary(_ image: CGImage?) -> (flat: Bool, mean: Double, print: [UInt8])? {
    guard let image else { return nil }
    let w = 32, h = 20
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var lo = 255, hi = 0, total = 0
    var fingerprint: [UInt8] = []
    for i in 0..<(w * h) {
        let luma = (Int(pixels[i * 4]) * 3 + Int(pixels[i * 4 + 1]) * 6 + Int(pixels[i * 4 + 2])) / 10
        lo = min(lo, luma); hi = max(hi, luma); total += luma
        fingerprint.append(UInt8(luma))
    }
    return (hi - lo < 8, Double(total) / Double(w * h), fingerprint)
}

func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
}

@MainActor final class Probe {
    let page: URL
    let seconds = 3.0
    let size = NSSize(width: 480, height: 300)

    init(page: URL) { self.page = page }

    func run() async {
        let env = ProcessInfo.processInfo.environment
        emit([
            "event": "start",
            "sandboxed": env["APP_SANDBOX_CONTAINER_ID"] != nil,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "pageReadable": FileManager.default.isReadableFile(atPath: page.path),
            "screens": NSScreen.screens.count,
            "caContext": NSClassFromString("CAContext") != nil,
            "caLayerHost": NSClassFromString("CALayerHost") != nil,
        ])
        for scenario in ["visible", "hidden", "hiddenNoOcclusion", "offscreen", "hostedHidden", "hostedOffscreen"] {
            await run(scenario)
        }
        emit(["event": "end"])
    }

    func run(_ scenario: String) async {
        var result: [String: Any] = ["event": "scenario", "name": scenario]
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        let watcher = NavigationWatcher()
        webView.navigationDelegate = watcher

        switch scenario {
        case "visible":
            window.setFrameOrigin(NSPoint(x: 40, y: 40))
            window.orderFrontRegardless()
        case "hiddenNoOcclusion":
            // A WebKit switch for views in windows that are never shown. Private: reported when missing.
            let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            result["occlusionSwitch"] = webView.responds(to: selector)
            if let method = class_getInstanceMethod(type(of: webView), selector) {
                typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(method), to: SetBool.self)(webView, selector, false)
            }
        case "offscreen", "hostedOffscreen":
            // Shown, but far outside every display.
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
        default:
            break // "hidden", "hostedHidden": never ordered front, as in a plug-in
        }

        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        let deadline = Date().addingTimeInterval(15)
        while !watcher.finished, watcher.failure == nil, Date() < deadline { await pause(0.05) }
        result["loaded"] = watcher.finished
        if let failure = watcher.failure { result["loadError"] = failure }
        result["windowVisible"] = window.isVisible
        result["occlusionVisible"] = window.occlusionState.contains(.visible)

        var hostWindow: NSWindow?
        var remote: RemoteContext?
        if scenario.hasPrefix("hosted"), watcher.finished {
            // Stand in for WallpaperAgent: a visible window of ours hosts a remote context, and the
            // remote context's tree is where the plug-in would put the page.
            await pause(0.5)
            var lines: [String] = [], hosts: [UInt32] = []
            describe(webView.layer, into: &lines, hosts: &hosts)
            result["webViewLayers"] = lines
            result["webKitHostContexts"] = hosts.map(Int.init)
            if let context = RemoteContext() {
                remote = context
                let root = CALayer()
                root.frame = CGRect(origin: .zero, size: size)
                root.backgroundColor = CGColor(red: 1, green: 0, blue: 1, alpha: 1) // magenta: nothing arrived
                if let webKitContext = hosts.first, let inner = layerHost(for: webKitContext) {
                    // WebKit already draws through a context of its own: host it again.
                    inner.frame = root.bounds
                    root.addSublayer(inner)
                    result["method"] = "nestedLayerHost"
                } else if let layer = webView.layer {
                    // Move the web view's own layer tree into the remote context.
                    layer.removeFromSuperlayer()
                    layer.frame = root.bounds
                    root.addSublayer(layer)
                    result["method"] = "reparentedLayer"
                }
                context.host(root)
                result["remoteContextID"] = Int(context.contextID)
                let window = NSWindow(contentRect: NSRect(x: 60 + size.width, y: 40, width: size.width, height: size.height),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let view = NSView(frame: NSRect(origin: .zero, size: size))
                view.wantsLayer = true
                if let host = layerHost(for: context.contextID) {
                    host.frame = CGRect(origin: .zero, size: size)
                    view.layer?.addSublayer(host)
                }
                window.contentView = view
                window.orderFrontRegardless()
                hostWindow = window
            } else {
                result["method"] = "noRemoteContext"
            }
        }

        // Animation over `seconds`: frames, CSS time and timer ticks the page counted.
        let before = await probe(webView)
        let snapshotBefore = await snapshot(webView)
        let captureBefore = hostWindow.flatMap(capture).flatMap(summary)
        await pause(seconds)
        let after = await probe(webView)
        let snapshotAfter = await snapshot(webView)
        let captureAfter = hostWindow.flatMap(capture).flatMap(summary)

        if let before, let after {
            let elapsed = max(0.001, ((after["now"] as? Double ?? 0) - (before["now"] as? Double ?? 0)) / 1000)
            result["visibilityState"] = after["visibility"]
            result["rafPerSecond"] = round(((after["frames"] as? Double ?? 0) - (before["frames"] as? Double ?? 0)) / elapsed * 10) / 10
            result["timerPerSecond"] = round(((after["ticks"] as? Double ?? 0) - (before["ticks"] as? Double ?? 0)) / elapsed * 10) / 10
            result["cssMsPerSecond"] = round(((after["css"] as? Double ?? 0) - (before["css"] as? Double ?? 0)) / elapsed)
            result["pageClockSeconds"] = round(elapsed * 100) / 100
        } else {
            result["javascript"] = "no answer"
        }
        if let a = summary(snapshotBefore), let b = summary(snapshotAfter) {
            result["snapshotFlat"] = a.flat && b.flat
            result["snapshotChange"] = round(difference(a.print, b.print) * 10) / 10
        } else {
            result["snapshot"] = snapshotBefore == nil ? "none" : "one"
        }
        if hostWindow != nil {
            if let a = captureBefore, let b = captureAfter {
                result["hostedFlat"] = a.flat && b.flat
                result["hostedMeanLuma"] = round(b.mean)
                result["hostedChange"] = round(difference(a.print, b.print) * 10) / 10
            } else {
                result["hostedCapture"] = "unavailable"
            }
        }
        result["webContentTerminated"] = watcher.webContentTerminated
        emit(result)

        hostWindow?.orderOut(nil)
        remote?.invalidate()
        window.orderOut(nil)
        webView.navigationDelegate = nil
    }

    func probe(_ webView: WKWebView) async -> [String: Any]? {
        let pending = Pending<String>()
        webView.evaluateJavaScript("probe()") { value, _ in
            MainActor.assumeIsolated { pending.set(value as? String) }
        }
        guard let json = await pending.wait(5), let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func snapshot(_ webView: WKWebView) async -> CGImage? {
        let pending = Pending<CGImage>()
        webView.takeSnapshot(with: nil) { image, _ in
            MainActor.assumeIsolated { pending.set(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)) }
        }
        return await pending.wait(5)
    }
}

@main
struct WebProbeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count > 1 else {
            print("usage: WebProbe <page.html>")
            exit(64)
        }
        let probe = Probe(page: URL(fileURLWithPath: CommandLine.arguments[1]))
        DispatchQueue.main.async {
            Task { @MainActor in
                await probe.run()
                exit(0)
            }
        }
        // A hard stop, in case WebKit never answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            print("WEBPROBE {\"event\":\"timeout\"}")
            exit(2)
        }
        app.run()
    }
}
