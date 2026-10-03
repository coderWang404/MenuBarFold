import Foundation

/// Unbuffered stderr logging (visible when launched from a shell).
func log(_ message: @autoclosure () -> String) {
    FileHandle.standardError.write("[MenuBarFold] \(message())\n".data(using: .utf8)!)
}
