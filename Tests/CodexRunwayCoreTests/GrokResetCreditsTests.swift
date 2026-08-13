import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok reset credits")
struct GrokResetCreditsTests {
    private let now = Date(timeIntervalSince1970: 1_786_601_000)
    private let start = Date(timeIntervalSince1970: 1_786_560_540)
    private let end = Date(timeIntervalSince1970: 1_789_238_940)

    @Test("decodes an official proto card with expiry")
    func decodesOfficialProtoAvailableCard() throws {
        let data = GrokResetCreditsFixture.proto(
            tokenID: "restok_fixture",
            start: start,
            end: end)

        let snapshot = try GrokResetCreditsSnapshot.decode(from: data, now: now)

        #expect(snapshot.availableCount == 1)
        #expect(snapshot.tokens.count == 1)
        #expect(snapshot.tokens[0].tokenID == "restok_fixture")
        #expect(snapshot.tokens[0].validityStart == start)
        #expect(snapshot.tokens[0].validityEnd == end)
        #expect(snapshot.tokens[0].isAvailable(now: now))
        #expect(snapshot.updatedAt == now)
    }

    @Test("decodes an official gRPC-Web envelope with a trailer")
    func decodesGrpcWebEnvelope() throws {
        let proto = GrokResetCreditsFixture.proto(
            tokenID: "restok_framed",
            start: start,
            end: end)
        let framed = GrokResetCreditsFixture.grpcWeb(proto, status: 0)

        let snapshot = try GrokResetCreditsSnapshot.decode(from: framed, now: now)

        #expect(snapshot.availableCount == 1)
        #expect(snapshot.tokens[0].tokenID == "restok_framed")
        #expect(snapshot.tokens[0].validityEnd == end)
    }

    @Test("empty official proto is zero cards, not an invented count")
    func decodesEmptyOfficialProto() throws {
        let snapshot = try GrokResetCreditsSnapshot.decode(from: Data(), now: now)
        #expect(snapshot.availableCount == 0)
        #expect(snapshot.tokens.isEmpty)

        let framedEmpty = GrokResetCreditsFixture.grpcWeb(Data(), status: 0)
        let framed = try GrokResetCreditsSnapshot.decode(from: framedEmpty, now: now)
        #expect(framed.availableCount == 0)
        #expect(framed.tokens.isEmpty)
    }

    @Test("JSON empty tokens is zero cards")
    func decodesEmptyJSON() throws {
        let data = Data(#"{"tokens":[]}"#.utf8)
        let snapshot = try GrokResetCreditsSnapshot.decode(from: data, now: now)
        #expect(snapshot.availableCount == 0)
        #expect(snapshot.tokens.isEmpty)
    }

    @Test("JSON available card with expiry uses official field names")
    func decodesJSONAvailableCard() throws {
        let data = Data(#"""
        {
          "tokens": [
            {
              "tokenId": "restok_json",
              "validityStart": "2026-08-12T18:49:00Z",
              "validityEnd": "2026-09-12T18:49:00Z"
            }
          ]
        }
        """#.utf8)

        let snapshot = try GrokResetCreditsSnapshot.decode(from: data, now: now)
        #expect(snapshot.availableCount == 1)
        #expect(snapshot.tokens[0].tokenID == "restok_json")
        #expect(snapshot.tokens[0].validityEnd == Date(timeIntervalSince1970: 1_789_238_940))
    }

    @Test("expired cards stay in the list but are not available")
    func expiredCardIsNotAvailable() throws {
        let data = GrokResetCreditsFixture.proto(
            tokenID: "restok_expired",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(-1))

        let snapshot = try GrokResetCreditsSnapshot.decode(from: data, now: now)
        #expect(snapshot.availableCount == 0)
        #expect(snapshot.tokens.count == 1)
        #expect(!snapshot.tokens[0].isAvailable(now: now))
    }

    @Test("maps official tokens onto the shared reset-credits presentation snapshot")
    func mapsToSharedPresentation() throws {
        let grok = GrokResetCreditsSnapshot(
            availableCount: 1,
            tokens: [
                GrokResetToken(tokenID: "restok_map", validityStart: start, validityEnd: end),
            ],
            updatedAt: now)

        let mapped = grok.asResetCreditsSnapshot()
        #expect(mapped.availableCount == 1)
        #expect(mapped.credits[0].id == "restok_map")
        #expect(mapped.credits[0].status == "available")
        #expect(mapped.credits[0].expiresAt == end)
        #expect(mapped.credits[0].remainingSeconds == end.timeIntervalSince(now))
    }

    @Test("rpc failure in the gRPC-Web trailer is not treated as zero cards")
    func rpcFailureDoesNotBecomeZero() {
        let framed = GrokResetCreditsFixture.grpcWeb(Data(), status: 13, message: "internal")
        #expect(throws: GrokResetCreditsDecodingError.rpcFailed("internal")) {
            try GrokResetCreditsSnapshot.decode(from: framed, now: now)
        }
    }
}

enum GrokResetCreditsFixture {
    static func proto(tokenID: String, start: Date, end: Date) -> Data {
        var token = Data()
        token.append(lengthDelimited(field: 10, data: Data(tokenID.utf8)))
        token.append(lengthDelimited(field: 20, data: timestamp(start)))
        token.append(lengthDelimited(field: 30, data: timestamp(end)))
        return lengthDelimited(field: 10, data: token)
    }

    static func grpcWeb(_ message: Data, status: Int, message statusMessage: String? = nil) -> Data {
        var payload = frame(message, flags: 0)
        var trailer = "grpc-status:\(status)\r\n"
        if let statusMessage {
            trailer += "grpc-message:\(statusMessage)\r\n"
        }
        payload.append(frame(Data(trailer.utf8), flags: 0x80))
        return payload
    }

    private static func timestamp(_ date: Date) -> Data {
        varint(field: 1, value: UInt64(date.timeIntervalSince1970.rounded()))
    }

    private static func lengthDelimited(field: Int, data: Data) -> Data {
        var payload = varintValue(UInt64(field << 3 | 2))
        payload.append(varintValue(UInt64(data.count)))
        payload.append(data)
        return payload
    }

    private static func varint(field: Int, value: UInt64) -> Data {
        var payload = varintValue(UInt64(field << 3))
        payload.append(varintValue(value))
        return payload
    }

    private static func frame(_ message: Data, flags: UInt8) -> Data {
        var data = Data([flags, 0, 0, 0, 0])
        let length = UInt32(message.count).bigEndian
        withUnsafeBytes(of: length) { buffer in
            data.replaceSubrange(1..<5, with: buffer)
        }
        data.append(message)
        return data
    }

    private static func varintValue(_ value: UInt64) -> Data {
        var remaining = value
        var data = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
        return data
    }
}
