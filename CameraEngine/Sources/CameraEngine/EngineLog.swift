import Foundation
import os

public enum EngineLog {
    private static let maxLines = 300
    private static let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let stampFormat: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    public static func add(_ message: String) {
        let line = "\(Date().formatted(stampFormat)) \(message)"
        lines.withLock {
            $0.append(line)
            if $0.count > maxLines {
                $0.removeFirst($0.count - maxLines)
            }
        }
    }

    public static func dump() -> [String] {
        lines.withLock { $0 }
    }
}
