import Foundation
import StatusSignals

let help = """
Notchlight local signals
  notchlight signal --source NAME --state working|success|failure|attention --message TEXT [--ttl SECONDS]
  notchlight clear --source NAME
  notchlight list
  notchlight codex-hook             Read a Codex lifecycle event from stdin.

Enable custom signals in Notchlight Settings first. Signals expire after 300 seconds
by default (1–86400 allowed). A source replaces only its own signal. No app is launched.
"""

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "--help"
    let store = SignalStore()
    if command == "--help" || command == "help" { print(help) }
    else if command == "codex-hook" {
        // Hook inputs can contain sensitive tool arguments: decode only the
        // correlation fields and never print or persist the input.
        var input = Data()
        while input.count <= 1_048_576 {
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(16_384, 1_048_577 - input.count)), !chunk.isEmpty else { break }
            input.append(chunk)
        }
        guard input.count <= 1_048_576 else { throw SignalError.invalidHook }
        try JSONDecoder().decode(CodexAttentionHook.self, from: input).apply(to: store)
        print("{}") // Valid no-op output for Stop as well as every other hook.
    } else if command == "list", arguments.count == 1 {
        for signal in try store.snapshot() { print("\(signal.source)\t\(signal.state.rawValue)\t\(signal.message)") }
    } else {
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard ["--source", "--state", "--message", "--ttl"].contains(key), index + 1 < arguments.count,
                  options[key] == nil else { throw SignalError.invalidSignal }
            options[key] = arguments[index + 1]
            index += 2
        }
        guard let source = options["--source"], !source.lowercased().hasPrefix("codex-") else { throw SignalError.invalidSignal }
        switch command {
        case "clear":
            guard options.count == 1 else { throw SignalError.invalidSignal }
            try store.clear(source: source)
        case "signal":
            guard let state = StatusSignal.State(rawValue: options["--state"] ?? ""), let message = options["--message"],
                  let lifetime = Double(options["--ttl"] ?? "300") else { throw SignalError.invalidSignal }
            try store.write(StatusSignal(source: source, state: state, message: message, lifetime: lifetime))
        default: throw SignalError.invalidSignal
        }
    }
} catch {
    if CommandLine.arguments.dropFirst().first == "codex-hook" {
        // A status-light failure must never block, approve, or deny Codex work.
        print("{}")
    } else {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n" + help + "\n").utf8))
        exit(1)
    }
}
