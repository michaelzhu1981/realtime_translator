import Foundation
import os

enum AppLogger {
    static let subsystem = "local.realtime-translator"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let asr = Logger(subsystem: subsystem, category: "asr")
    static let translation = Logger(subsystem: subsystem, category: "translation")
}
