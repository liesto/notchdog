import Foundation

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]   // lowercased keys
    public let body: Data

    public enum ParseError: Error { case malformed }

    /// Parse a single HTTP/1.1 request from the front of `data`.
    /// Returns nil if more bytes are needed; throws on a malformed request line.
    public static func parse(_ data: Data) throws -> (request: HTTPRequest, consumed: Int)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: sep) else { return nil } // headers incomplete

        let headerData = data[data.startIndex..<sepRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformed
        }
        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ParseError.malformed }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw ParseError.malformed }
        let method = String(parts[0])
        let path = String(parts[1])
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sepRange.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        if available < contentLength { return nil } // body incomplete

        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = Data(data[bodyStart..<bodyEnd])
        let consumed = data.distance(from: data.startIndex, to: bodyEnd)
        return (HTTPRequest(method: method, path: path, headers: headers, body: body), consumed)
    }
}
