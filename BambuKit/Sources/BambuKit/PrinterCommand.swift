/// Commands the printer accepts on device/{serial}/request.
/// Payload strings are ported verbatim from the legacy app; the firmware
/// accepts these exact shapes, so they are string literals, not Codable.
public enum PrinterCommand: Sendable, Equatable {
    case pause
    case resume
    case stop
    case light(on: Bool)
    case speed(PrintSpeed)

    public enum PrintSpeed: Int, Sendable, CaseIterable, Identifiable {
        case silent = 1, normal = 2, sport = 3, ludicrous = 4
        public var id: Int { rawValue }
        public var displayName: String {
            switch self {
            case .silent: "Silent"
            case .normal: "Normal"
            case .sport: "Sport"
            case .ludicrous: "Ludicrous"
            }
        }
    }

    public var payload: String {
        switch self {
        case .pause:
            #"{"print": { "sequence_id": 1, "command": "pause"}, "user_id":"1234567890"}"#
        case .resume:
            #"{"print": { "sequence_id": 2, "command": "resume"}, "user_id":"1234567890"}"#
        case .stop:
            #"{"print": { "sequence_id": 3, "command": "stop"}, "user_id":"1234567890"}"#
        case .light(let on):
            #"{"system": {"sequence_id": "0", "command": "ledctrl", "led_node": "chamber_light", "led_mode": "\#(on ? "on" : "off")", "led_on_time": 500, "led_off_time": 500, "loop_times": 0, "interval_time": 0}, "user_id":"1234567890"}"#
        case .speed(let s):
            #"{"print": {"sequence_id":"2004","command":"print_speed","param":"\#(s.rawValue)"},"user_id":"1234567890"}"#
        }
    }
}
