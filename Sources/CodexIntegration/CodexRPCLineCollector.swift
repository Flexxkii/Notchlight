import Foundation

final class CodexRPCLineCollector: @unchecked Sendable {
    private let output: Pipe
    private let error: Pipe
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [[String: Any]] = []
    private var counter = 0
    private var failure = false
    private var receivedByteCount = 0

    init(output: Pipe, error: Pipe) { self.output = output; self.error = error }

    func start() {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                self?.lock.withLock { self?.failure = true }
                return
            }
            self?.append(data)
        }
        error.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
    }

    func nextID() -> Int { lock.withLock { counter += 1; return counter } }

    var failed: Bool { lock.withLock { failure } }

    var receivedBytes: Int { lock.withLock { receivedByteCount } }

    func take(id: Int) -> [String: Any]? {
        lock.withLock {
            guard let index = responses.firstIndex(where: { ($0["id"] as? Int) == id }) else { return nil }
            return responses.remove(at: index)
        }
    }

    private func append(_ data: Data) {
        lock.withLock {
            receivedByteCount += data.count
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard line.count <= 1_048_576,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let dictionary = object as? [String: Any] else {
                    failure = true
                    continue
                }
                guard responses.count < 64 else { failure = true; continue }
                if dictionary["id"] != nil { responses.append(dictionary) }
            }
            if buffer.count > 1_048_576 { failure = true; buffer.removeAll(keepingCapacity: false) }
        }
    }
}
