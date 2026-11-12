// THROWAWAY SPIKE. Not product code.
// A com.apple.wallpaper ExtensionKit extension, written from the interface read out of
// Apple's WallpaperExtensionKit (ObjC protocol + extended type encodings + Swift field
// metadata). It plays a bundled video through a remote CAContext and logs every call.
import AVFoundation
import ExtensionFoundation
import Foundation
import os
import QuartzCore
import IOSurface
import XPC

let logger = Logger(subsystem: "dev.spike.livewallpaper", category: "ext")
let logURL: URL = {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("spike.log")
}()
let logQueue = DispatchQueue(label: "spike.log")
func trace(_ s: String) {
    logger.notice("\(s, privacy: .public)")
    let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(s)\n"
    logQueue.async {
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.data(using: .utf8)!.write(to: logURL) }
    }
}

// MARK: - XPC boxes. Each holds a Swift value encoded as JSON under a key named after its type.

class JSONBox: NSObject, NSSecureCoding {
    class var supportsSecureCoding: Bool { true }
    class var codingKey: String { "" }
    let json: Data
    init(json: Data) { self.json = json; super.init() }
    convenience init(object: Any) { self.init(json: try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) }
    required init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: type(of: self).codingKey) else { return nil }
        json = d as Data
        super.init()
    }
    func encode(with coder: NSCoder) { coder.encode(json as NSData, forKey: type(of: self).codingKey) }
    var text: String { String(data: json, encoding: .utf8) ?? "<\(json.count) bytes>" }
    var object: Any? { try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) }
}
@objc(WallpaperIDXPC) final class WallpaperIDXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperID" } }
@objc(WallpaperUpdateRequestXPC) final class WallpaperUpdateRequestXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperUpdateRequest" } }
@objc(WallpaperRemoteContextXPC) final class WallpaperRemoteContextXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "UInt32" } }
@objc(WallpaperSettingsViewModelsXPC) final class WallpaperSettingsViewModelsXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperSettingsViewModels" } }
@objc(WallpaperContentTypeSetXPC) final class WallpaperContentTypeSetXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "Set<ContentType>" } }
@objc(WallpaperChoiceIDXPC) final class WallpaperChoiceIDXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "ID" } }
@objc(WallpaperChoiceIDsXPC) final class WallpaperChoiceIDsXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "Array<ID>" } }
@objc(WallpaperMigrationVersionXPC) final class WallpaperMigrationVersionXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperMigrationVersion" } }
@objc(WallpaperDebugRequestXPC) final class WallpaperDebugRequestXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperDebugRequest" } }
@objc(WallpaperDebugResponseXPC) final class WallpaperDebugResponseXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperDebugResponse" } }
@objc(WallpaperExtensionChoiceRequestXPC) final class WallpaperExtensionChoiceRequestXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperChoiceRequest" } }
@objc(WallpaperChoiceRequestAdditionResultXPC) final class WallpaperChoiceRequestAdditionResultXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "WallpaperChoiceRequestAdditionResult" } }
@objc(AuditTokenXPC) final class AuditTokenXPC: JSONBox { override class var supportsSecureCoding: Bool { true }; override class var codingKey: String { "audit_token_t" } }

// Carries an IOSurface: only over an NSXPCCoder, under "surface", as IOSurfaceCreateXPCObject.
@objc(WallpaperSnapshotXPC) final class WallpaperSnapshotXPC: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let surface: IOSurfaceRef?
    init(surface: IOSurfaceRef) { self.surface = surface; super.init() }
    required init?(coder: NSCoder) {
        guard let xpc = coder as? NSXPCCoder, let obj = xpc.decodeXPCObject(ofType: XPC_TYPE_DICTIONARY, forKey: "surface") else { return nil }
        surface = IOSurfaceLookupFromXPCObject(obj)
        super.init()
    }
    func encode(with coder: NSCoder) {
        guard let xpc = coder as? NSXPCCoder, let surface else { return }
        xpc.encodeXPCObject(IOSurfaceCreateXPCObject(surface), forKey: "surface")
    }
}

/// A still of the frame now playing, drawn into a BGRA IOSurface of the destination's pixel size.
func makeSnapshot(of surface: Surface) -> IOSurfaceRef? {
    guard let asset = surface.player.currentItem?.asset else { return nil }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    guard let image = try? generator.copyCGImage(at: surface.player.currentTime(), actualTime: nil) else { return nil }
    let w = Int(surface.root.bounds.width * surface.root.contentsScale), h = Int(surface.root.bounds.height * surface.root.contentsScale)
    guard w > 0, h > 0, let io = IOSurfaceCreate([kIOSurfaceWidth: w, kIOSurfaceHeight: h, kIOSurfaceBytesPerElement: 4,
                                                  kIOSurfacePixelFormat: 0x42475241 /* 'BGRA' */] as CFDictionary) else { return nil }
    IOSurfaceLock(io, [], nil)
    defer { IOSurfaceUnlock(io, [], nil) }
    guard let ctx = CGContext(data: IOSurfaceGetBaseAddress(io), width: w, height: h, bitsPerComponent: 8, bytesPerRow: IOSurfaceGetBytesPerRow(io),
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    let scale = max(CGFloat(w) / CGFloat(image.width), CGFloat(h) / CGFloat(image.height)) // aspect fill
    let dw = CGFloat(image.width) * scale, dh = CGFloat(image.height) * scale
    ctx.draw(image, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
    return io
}

@objc(WallpaperCreationRequestXPC) final class WallpaperCreationRequestXPC: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let files: [Any]
    let cacheDirectory: Any?
    let json: Data
    required init?(coder: NSCoder) {
        let wrapper: AnyClass = NSClassFromString("NSSecurityScopedURLWrapper") ?? NSObject.self
        files = coder.decodeArrayOfObjects(ofClasses: [wrapper], forKey: "files") ?? []
        cacheDirectory = coder.decodeObject(of: [wrapper], forKey: "cacheDirectory")
        guard let d = coder.decodeObject(of: NSData.self, forKey: "codable") else { return nil }
        json = d as Data
        super.init()
    }
    func encode(with coder: NSCoder) { coder.encode(json as NSData, forKey: "codable") }
    var text: String { String(data: json, encoding: .utf8) ?? "?" }
}

// MARK: - The protocol WallpaperAgent calls, selector for selector.

@objc protocol SpikeWallpaperXPC {
    @objc(migrateSelectedChoiceFor:reply:) func migrateSelectedChoice(_ id: WallpaperChoiceIDXPC, reply: @escaping (WallpaperChoiceIDXPC?, Error?) -> Void)
    @objc(acquireWithId:request:reply:) func acquire(_ id: WallpaperIDXPC, request: WallpaperCreationRequestXPC, reply: @escaping (WallpaperRemoteContextXPC?, Error?) -> Void)
    @objc(addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:) func addChoiceRequest(_ r: WallpaperExtensionChoiceRequestXPC, onBehalfOf p: AuditTokenXPC, reply: @escaping (WallpaperChoiceRequestAdditionResultXPC?, Error?) -> Void)
    @objc(canSkipShuffledContentWithId:reply:) func canSkipShuffled(_ id: WallpaperIDXPC, reply: @escaping (Bool, Error?) -> Void)
    @objc(cancelDownloadFor:reply:) func cancelDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void)
    @objc(downloadWithChoiceID:reply:) func download(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void) -> Progress
    @objc(handleDebugRequestFor:reply:) func handleDebug(_ r: WallpaperDebugRequestXPC, reply: @escaping (WallpaperDebugResponseXPC?, Error?) -> Void)
    @objc(handleNotificationWithNamed:reply:) func handleNotification(_ name: NSString, reply: @escaping (Error?) -> Void)
    @objc(invalidateWithId:reply:) func invalidate(_ id: WallpaperIDXPC, reply: @escaping (Error?) -> Void)
    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:) func invokeContextMenu(_ item: NSString, group: NSString, reply: @escaping (Error?) -> Void)
    @objc(isChoiceDownloadedWith:reply:) func isChoiceDownloaded(_ id: WallpaperChoiceIDXPC, reply: @escaping (NSNumber?, Error?) -> Void)
    @objc(migrateFrom:to:reply:) func migrate(_ from: WallpaperMigrationVersionXPC, to: WallpaperMigrationVersionXPC, reply: @escaping (Error?) -> Void)
    @objc(pauseDownloadFor:reply:) func pauseDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void)
    @objc(provideSettingsViewModelsWithContentTypes:reply:) func provideSettingsViewModels(_ types: WallpaperContentTypeSetXPC, reply: @escaping (WallpaperSettingsViewModelsXPC?, Error?) -> Void)
    @objc(removeChoiceRequestWithChoiceRequest:reply:) func removeChoiceRequest(_ r: WallpaperExtensionChoiceRequestXPC, reply: @escaping (Error?) -> Void)
    @objc(removeDownloadFor:reply:) func removeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void)
    @objc(resumeDownloadFor:reply:) func resumeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void)
    @objc(selectedChoicesDidChangeFor:reply:) func selectedChoicesDidChange(_ ids: WallpaperChoiceIDsXPC, reply: @escaping (Error?) -> Void)
    @objc(skipShuffledContentWithId:reply:) func skipShuffled(_ id: WallpaperIDXPC, reply: @escaping (Error?) -> Void)
    @objc(snapshotWithId:reply:) func snapshot(_ id: WallpaperIDXPC, reply: @escaping (WallpaperSnapshotXPC?, Error?) -> Void)
    @objc(updateWithId:request:reply:) func update(_ id: WallpaperIDXPC, request: WallpaperUpdateRequestXPC, reply: @escaping (Error?) -> Void)
}

@objc protocol SpikeHostXPC {
    @objc(updateSettingsViewModels:reply:) func updateSettingsViewModels(_ m: WallpaperSettingsViewModelsXPC, reply: @escaping (Error?) -> Void)
    @objc(invalidateSnapshotsWithReply:) func invalidateSnapshots(reply: @escaping (Error?) -> Void)
    @objc(pingWithId:) func ping(_ id: WallpaperIDXPC)
    @objc(requestReadOnlyAccessTo:reply:) func requestReadOnlyAccess(_ url: NSURL, reply: @escaping (NSObject?, Error?) -> Void)
}

// MARK: - Rendering

let providerID = "dev.spike.LiveWallpaperSpike.Wallpaper"

final class Surface {
    let context: NSObject
    let root = CALayer()
    let playerLayer = AVPlayerLayer()
    let player = AVQueuePlayer()
    var looper: AVPlayerLooper?

    init?(destination: [String: Any]) {
        guard let cls = NSClassFromString("CAContext") as? NSObject.Type else { trace("no CAContext class"); return nil }
        let sel = NSSelectorFromString("remoteContextWithOptions:")
        guard cls.responds(to: sel), let ctx = cls.perform(sel, with: [:] as NSDictionary)?.takeUnretainedValue() as? NSObject else {
            trace("remoteContextWithOptions failed"); return nil
        }
        context = ctx
        guard let url = Bundle.main.url(forResource: "spike", withExtension: "mov") else { trace("no video in bundle"); return nil }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        root.backgroundColor = CGColor(red: 0.6, green: 0, blue: 0.6, alpha: 1) // magenta: layer is live but no video frame
        root.addSublayer(playerLayer)
        apply(destination: destination)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        context.setValue(root, forKey: "layer")
        CATransaction.commit()
    }

    var contextID: UInt32 { (context.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0 }

    func apply(destination: [String: Any]) {
        var size = CGSize(width: 1440, height: 900)
        if let s = destination["size"] as? [Double], s.count == 2 { size = CGSize(width: s[0], height: s[1]) }
        let scale = (destination["scaleFactor"] as? Double) ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        playerLayer.frame = root.bounds
        playerLayer.contentsScale = scale
        CATransaction.commit()
    }

    func apply(activity: String?) {
        if activity == "suspended" { player.pause() } else { player.play() }
    }
}

func caseName(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    if let d = v as? [String: Any] { return d.keys.first }
    return nil
}

final class Handler: NSObject, SpikeWallpaperXPC {
    var surfaces: [String: Surface] = [:]
    weak var connection: NSXPCConnection?

    func key(_ id: WallpaperIDXPC) -> String { id.text }

    func acquire(_ id: WallpaperIDXPC, request: WallpaperCreationRequestXPC, reply: @escaping (WallpaperRemoteContextXPC?, Error?) -> Void) {
        trace("acquire id=\(id.text) files=\(request.files.count) request=\(request.text)")
        DispatchQueue.main.async {
            let req = (try? JSONSerialization.jsonObject(with: request.json)) as? [String: Any] ?? [:]
            let dest = req["destination"] as? [String: Any] ?? [:]
            guard let surface = Surface(destination: dest) else {
                reply(nil, NSError(domain: "spike", code: 1)); return
            }
            surface.apply(activity: caseName(req["activityState"]))
            self.surfaces[self.key(id)] = surface
            trace("acquire -> contextId=\(surface.contextID) mode=\(caseName(req["presentationMode"]) ?? "?") activity=\(caseName(req["activityState"]) ?? "?") preview=\(req["isPreview"] ?? "?")")
            reply(WallpaperRemoteContextXPC(object: surface.contextID), nil)
        }
    }

    func update(_ id: WallpaperIDXPC, request: WallpaperUpdateRequestXPC, reply: @escaping (Error?) -> Void) {
        trace("update id=\(id.text) request=\(request.text)")
        DispatchQueue.main.async {
            let req = request.object as? [String: Any] ?? [:]
            if let s = self.surfaces[self.key(id)] {
                if let dest = req["destination"] as? [String: Any] { s.apply(destination: dest) }
                s.apply(activity: caseName(req["activityState"]))
            }
            reply(nil)
        }
    }

    func invalidate(_ id: WallpaperIDXPC, reply: @escaping (Error?) -> Void) {
        trace("invalidate id=\(id.text)")
        DispatchQueue.main.async { self.surfaces[self.key(id)]?.player.pause(); self.surfaces[self.key(id)] = nil; reply(nil) }
    }

    func provideSettingsViewModels(_ types: WallpaperContentTypeSetXPC, reply: @escaping (WallpaperSettingsViewModelsXPC?, Error?) -> Void) {
        trace("provideSettingsViewModels types=\(types.text)")
        let thumb = Bundle.main.url(forResource: "thumb", withExtension: "png")?.absoluteString ?? ""
        let config = Data("{\"video\":\"spike\"}".utf8).base64EncodedString()
        let choice: [String: Any] = [
            "id": ["descriptor": ["provider": providerID, "files": [], "configuration": config]],
            "localizedDescription": "Spike Video", "thumbnail": ["image": ["url": thumb]],
            "isDownloaded": true, "options": [],
        ]
        let item: [String: Any] = [
            "id": ["id": "spike.item.video"], "localizedName": "Spike Video", "thumbnail": ["image": ["url": thumb]],
            "choice": choice, "contentBadge": ["video": [:]], "showInTopLevel": true, "sortOrder": 0, "disposability": ["none": [:]],
        ]
        let group: [String: Any] = [
            "id": ["id": "spike.group"], "localizedName": "Live Wallpaper Spike", "disposability": ["none": [:]],
            "sortID": ["id": "spike"], "shouldHideItemLabels": false, "sortOrder": 0, "items": [item],
        ]
        let model: [String: Any] = ["groups": [group], "refreshPolicy": ["default": [:]], "isModificationDisabled": false]
        reply(WallpaperSettingsViewModelsXPC(object: ["desktop": model, "screenSaver": model]), nil)
    }

    func snapshot(_ id: WallpaperIDXPC, reply: @escaping (WallpaperSnapshotXPC?, Error?) -> Void) {
        DispatchQueue.main.async {
            guard let s = self.surfaces[self.key(id)], let io = makeSnapshot(of: s) else {
                trace("snapshot id=\(id.text) -> failed"); reply(nil, NSError(domain: "spike", code: 2)); return
            }
            trace("snapshot id=\(id.text) -> \(IOSurfaceGetWidth(io))x\(IOSurfaceGetHeight(io)) at \(String(format: "%.2f", s.player.currentTime().seconds))s")
            reply(WallpaperSnapshotXPC(surface: io), nil)
        }
    }
    func isChoiceDownloaded(_ id: WallpaperChoiceIDXPC, reply: @escaping (NSNumber?, Error?) -> Void) { trace("isChoiceDownloaded \(id.text)"); reply(NSNumber(value: true), nil) }
    func selectedChoicesDidChange(_ ids: WallpaperChoiceIDsXPC, reply: @escaping (Error?) -> Void) { trace("selectedChoicesDidChange \(ids.text)"); reply(nil) }
    func handleNotification(_ name: NSString, reply: @escaping (Error?) -> Void) { trace("handleNotification \(name)"); reply(nil) }
    func migrateSelectedChoice(_ id: WallpaperChoiceIDXPC, reply: @escaping (WallpaperChoiceIDXPC?, Error?) -> Void) { trace("migrateSelectedChoice \(id.text)"); reply(id, nil) }
    func migrate(_ from: WallpaperMigrationVersionXPC, to: WallpaperMigrationVersionXPC, reply: @escaping (Error?) -> Void) { trace("migrate \(from.text) -> \(to.text)"); reply(nil) }
    func addChoiceRequest(_ r: WallpaperExtensionChoiceRequestXPC, onBehalfOf p: AuditTokenXPC, reply: @escaping (WallpaperChoiceRequestAdditionResultXPC?, Error?) -> Void) { trace("addChoiceRequest \(r.text)"); reply(nil, NSError(domain: "spike", code: 3)) }
    func removeChoiceRequest(_ r: WallpaperExtensionChoiceRequestXPC, reply: @escaping (Error?) -> Void) { trace("removeChoiceRequest"); reply(nil) }
    func canSkipShuffled(_ id: WallpaperIDXPC, reply: @escaping (Bool, Error?) -> Void) { trace("canSkipShuffled"); reply(false, nil) }
    func skipShuffled(_ id: WallpaperIDXPC, reply: @escaping (Error?) -> Void) { trace("skipShuffled"); reply(nil) }
    func cancelDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void) { reply(nil) }
    func download(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void) -> Progress { trace("download \(id.text)"); reply(nil); return Progress(totalUnitCount: 1) }
    func pauseDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void) { reply(nil) }
    func resumeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeDownload(_ id: WallpaperChoiceIDXPC, reply: @escaping (Error?) -> Void) { reply(nil) }
    func handleDebug(_ r: WallpaperDebugRequestXPC, reply: @escaping (WallpaperDebugResponseXPC?, Error?) -> Void) { trace("handleDebug \(r.text)"); reply(nil, NSError(domain: "spike", code: 4)) }
    func invokeContextMenu(_ item: NSString, group: NSString, reply: @escaping (Error?) -> Void) { trace("contextMenu \(item) \(group)"); reply(nil) }
}

let handler = Handler()

@main
struct SpikeWallpaperExtension: AppExtension {
    init() { trace("extension init pid=\(ProcessInfo.processInfo.processIdentifier)") }
    var configuration: ConnectionHandler {
        ConnectionHandler { connection in
            trace("connection from pid=\(connection.processIdentifier)")
            connection.exportedInterface = NSXPCInterface(with: SpikeWallpaperXPC.self)
            connection.exportedObject = handler
            connection.remoteObjectInterface = NSXPCInterface(with: SpikeHostXPC.self)
            connection.invalidationHandler = { trace("connection invalidated") }
            connection.interruptionHandler = { trace("connection interrupted") }
            handler.connection = connection
            connection.resume()
            return true
        }
    }
}
