// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import ObjectiveC

/// Loads Apple's private WallpaperExtensionKit in the test process and asks its own message
/// classes to decode our JSON, the way WallpaperAgent and System Settings will.
enum AppleWallpaperDecoder {
    static let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/Versions/A/WallpaperExtensionKit"

    static let isAvailable: Bool = {
        dlopen(frameworkPath, RTLD_NOW) != nil && NSClassFromString("WallpaperSettingsViewModelsXPC") != nil
    }()

    /// True when Apple's class at `className` decodes `json` stored under `key`.
    static func accepts(_ json: Data, className: String, key: String) -> Bool {
        guard isAvailable, let cls = NSClassFromString(className) as? NSObject.Type else { return false }
        let coder = BoxCoder(key: key, data: json)
        let selector = NSSelectorFromString("initWithCoder:")
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: selector) else { return false }
        let result = allocated.perform(selector, with: coder)?.takeUnretainedValue()
        return result != nil && coder.failure == nil
    }
}

/// A keyed coder holding one value, the way NSXPC hands a message object its single field.
private final class BoxCoder: NSCoder {
    let key: String
    let data: NSData
    private(set) var failure: Error?

    init(key: String, data: Data) {
        self.key = key
        self.data = data as NSData
        super.init()
        Self.installClassCheckedDecoder
    }

    /// Swift marks `decodeObjectOfClass:forKey:` unavailable for overriding, so add it at runtime.
    private static let installClassCheckedDecoder: Void = {
        let block: @convention(block) (BoxCoder, AnyClass, NSString) -> Any? = { coder, _, key in
            (key as String) == coder.key ? coder.data : nil
        }
        class_replaceMethod(BoxCoder.self, NSSelectorFromString("decodeObjectOfClass:forKey:"),
                            imp_implementationWithBlock(block), "@@:#@")
    }()

    override var allowsKeyedCoding: Bool { true }
    override var requiresSecureCoding: Bool { true }
    override var decodingFailurePolicy: NSCoder.DecodingFailurePolicy { .setErrorAndReturn }
    override var error: Error? { failure }
    override func failWithError(_ error: Error) { failure = error }
    override func containsValue(forKey key: String) -> Bool { key == self.key }
    override func decodeObject(forKey key: String) -> Any? { key == self.key ? data : nil }
    // Swift hides the class-checked decoders behind generic wrappers, so answer their selectors.
    override func __decodeObject(ofClasses classes: Set<AnyHashable>?, forKey key: String) -> Any? { key == self.key ? data : nil }
}
