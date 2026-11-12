// THROWAWAY: waits for the screen to lock, captures the Lock Screen twice, exits after unlock.
import CoreGraphics
import Foundation
func locked() -> Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
func shot(_ name: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", CommandLine.arguments[1] + "/" + name]; try? p.run(); p.waitUntilExit() }
func stamp(_ s: String) { print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(s)"); fflush(stdout) }
let deadline = Date().addingTimeInterval(15 * 60)
stamp("waiting for lock")
while !locked() { if Date() > deadline { stamp("timeout"); exit(1) }; usleep(300_000) }
stamp("locked"); sleep(4); shot("lock-a.png"); stamp("shot a"); sleep(2); shot("lock-b.png"); stamp("shot b"); sleep(4); shot("lock-c.png"); stamp("shot c")
while locked() { usleep(300_000) }
stamp("unlocked")
