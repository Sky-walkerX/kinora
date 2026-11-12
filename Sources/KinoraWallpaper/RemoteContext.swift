// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import QuartzCore

/// A layer tree another process can host. WallpaperAgent receives the context's ID from
/// acquire and shows the layer as the wallpaper. It uses QuartzCore's private `CAContext`,
/// resolved at runtime so a macOS without it fails cleanly instead of crashing.
@MainActor final class RemoteContext {
    private let context: NSObject

    init?() {
        let create = NSSelectorFromString("remoteContextWithOptions:")
        guard let cls = NSClassFromString("CAContext") as? NSObject.Type, cls.responds(to: create),
              let context = cls.perform(create, with: NSDictionary())?.takeUnretainedValue() as? NSObject,
              context.responds(to: NSSelectorFromString("contextId"))
        else { return nil }
        self.context = context
    }

    var contextID: UInt32 { (context.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0 }

    func host(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.setValue(layer, forKey: "layer")
        CATransaction.commit()
    }

    func invalidate() {
        let selector = NSSelectorFromString("invalidate")
        if context.responds(to: selector) { context.perform(selector) }
    }
}
