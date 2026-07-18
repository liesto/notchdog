import Foundation
@testable import SessionNotchCore

func registerHTTPRequestTests(_ runner: TestRunner) async {
    runner.test("HTTPRequest.parsePostWithBody") {
        let raw = "POST /event HTTP/1.1\r\nHost: x\r\nX-SessionNotch-Secret: k\r\nContent-Length: 5\r\n\r\nhello"
        let result = try HTTPRequest.parse(Data(raw.utf8))
        try expect(result != nil)
        let req = result!.request
        try expectEqual(req.method, "POST")
        try expectEqual(req.path, "/event")
        try expectEqual(req.headers["x-sessionnotch-secret"], "k")
        try expectEqual(String(data: req.body, encoding: .utf8), "hello")
    }

    runner.test("HTTPRequest.incompleteBodyReturnsNil") {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort"
        try expect(try HTTPRequest.parse(Data(raw.utf8)) == nil)
    }

    runner.test("HTTPRequest.incompleteHeadersReturnsNil") {
        try expect(try HTTPRequest.parse(Data("GET /health HTTP/1.1\r\nHost: x".utf8)) == nil)
    }

    runner.test("HTTPRequest.getNoBody") {
        let raw = "GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
        let result = try HTTPRequest.parse(Data(raw.utf8))
        try expect(result != nil)
        let req = result!.request
        try expectEqual(req.method, "GET")
        try expectEqual(req.path, "/health")
        try expect(req.body.isEmpty)
    }

    runner.test("HTTPRequest.malformedRequestLineThrows") {
        try expectThrows {
            _ = try HTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8))
        }
    }

    runner.test("HTTPRequest.negativeContentLengthThrows") {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: -1\r\n\r\nhello"
        try expectThrows { _ = try HTTPRequest.parse(Data(raw.utf8)) }
    }

    runner.test("HTTPRequest.nonNumericContentLengthThrows") {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: abc\r\n\r\n"
        try expectThrows { _ = try HTTPRequest.parse(Data(raw.utf8)) }
    }
}
