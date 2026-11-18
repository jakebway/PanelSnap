// Stand-ins for the app pieces the detector touches, so it can run as a command-line check.
import Foundation
enum Console { static func log(_ s: String) { print(s) } }
enum Paths { static var caches: URL { return FileManager.default.temporaryDirectory } }
