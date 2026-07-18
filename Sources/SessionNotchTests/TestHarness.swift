import Foundation

struct ExpectationError: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #file, line: UInt = #line) throws {
    if !condition { throw ExpectationError(description: "\(message()) [\(file):\(line)]") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
            file: StaticString = #file, line: UInt = #line) throws {
    if actual != expected {
        throw ExpectationError(description: "expected \(expected), got \(actual) [\(file):\(line)]")
    }
}

func expectThrows(_ body: () throws -> Void, _ message: String = "expected an error to be thrown",
                  file: StaticString = #file, line: UInt = #line) throws {
    var threw = false
    do { try body() } catch { threw = true }
    if !threw { throw ExpectationError(description: "\(message) [\(file):\(line)]") }
}

final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private let filter: String?
    init(filter: String?) { self.filter = filter }

    func test(_ name: String, _ body: () throws -> Void) {
        guard filter.map({ name.contains($0) }) ?? true else { return }
        do { try body(); passed += 1; print("ok - \(name)") }
        catch { failed += 1; print("FAIL - \(name): \(error)") }
    }

    func test(_ name: String, _ body: () async throws -> Void) async {
        guard filter.map({ name.contains($0) }) ?? true else { return }
        do { try await body(); passed += 1; print("ok - \(name)") }
        catch { failed += 1; print("FAIL - \(name): \(error)") }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
