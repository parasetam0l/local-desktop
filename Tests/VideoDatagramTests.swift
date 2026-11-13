import XCTest
import CryptoKit

final class VideoDatagramTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private lazy var packetizer = RDVideoPacketizer(key: key)

    private func payload(_ size: Int, seed: UInt8 = 0) -> Data {
        Data((0..<size).map { UInt8((Int(seed) + $0) % 251) })
    }

    private func datagrams(_ frame: UInt32, _ data: Data, keyframe: Bool = false, max: Int = 300) -> [Data] {
        packetizer.datagrams(frame: frame, payload: data, isKeyframe: keyframe, maxDatagramSize: max)!
    }

    func testPiecesFitAndReassembleOutOfOrder() {
        let data = payload(5000)
        let pieces = datagrams(1, data, keyframe: true, max: 1200)
        XCTAssertEqual(pieces.count, 5)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 1200 })
        var assembler = RDVideoReassembler(key: key)
        var delivered: [Data] = []
        for piece in pieces.shuffled() {
            let out = assembler.receive(piece)
            delivered += out.frames
            if !out.frames.isEmpty { XCTAssertEqual(out.acked, 1) }
        }
        XCTAssertEqual(delivered, [data])
    }

    func testDuplicatesAndReplaysAreIgnored() {
        let pieces = datagrams(1, payload(700), keyframe: true)
        var assembler = RDVideoReassembler(key: key)
        _ = assembler.receive(pieces[0])
        XCTAssertTrue(assembler.receive(pieces[0]).frames.isEmpty)  // duplicate piece
        var delivered = 0
        for piece in pieces.dropFirst() { delivered += assembler.receive(piece).frames.count }
        XCTAssertEqual(delivered, 1)
        // Replaying the whole frame after delivery yields nothing.
        for piece in pieces {
            let out = assembler.receive(piece)
            XCTAssertTrue(out.frames.isEmpty)
            XCTAssertNil(out.acked)
        }
    }

    func testTamperedOrForeignDatagramsAreRejected() {
        var piece = datagrams(1, payload(100), keyframe: true)[0]
        var assembler = RDVideoReassembler(key: key)
        piece[piece.count - 20] ^= 0x01
        XCTAssertTrue(assembler.receive(piece).frames.isEmpty)
        var header = datagrams(1, payload(100), keyframe: true)[0]
        header[3] = 2  // frame number changed: header is authenticated
        XCTAssertTrue(assembler.receive(header).frames.isEmpty)
        let foreign = RDVideoPacketizer(key: SymmetricKey(size: .bits256))
            .datagrams(frame: 1, payload: payload(100), isKeyframe: true, maxDatagramSize: 300)![0]
        XCTAssertTrue(assembler.receive(foreign).frames.isEmpty)
        XCTAssertTrue(assembler.receive(Data([1, 2, 3])).frames.isEmpty)
    }

    func testLossDropsTheIncompleteFrameAndResyncsOnKeyframe() {
        var assembler = RDVideoReassembler(key: key, lastFrame: 4)  // 4 frames came on the stream
        XCTAssertEqual(datagrams(5, payload(400)).flatMap { assembler.receive($0).frames }.count, 1)

        let incomplete = datagrams(6, payload(900))
        _ = assembler.receive(incomplete[0])                       // frame 6 never completes
        let pFrame = datagrams(7, payload(200, seed: 7)).map { assembler.receive($0) }
        XCTAssertTrue(pFrame.allSatisfy { $0.frames.isEmpty })     // discarded: its reference is gone
        XCTAssertEqual(pFrame.reduce(0) { $0 + $1.dropped }, 2)    // 6 lost + 7 discarded
        XCTAssertTrue(pFrame.contains { $0.needsKeyframe })
        XCTAssertEqual(pFrame.compactMap(\.acked).last, 7)         // still confirmed to the host
        XCTAssertTrue(assembler.receive(incomplete[1]).frames.isEmpty)  // late piece of 6: too old

        let key8 = payload(600, seed: 8)
        let resumed = datagrams(8, key8, keyframe: true).flatMap { assembler.receive($0).frames }
        XCTAssertEqual(resumed, [key8])
        XCTAssertFalse(assembler.awaitingKeyframe)
        XCTAssertEqual(datagrams(9, payload(10)).flatMap { assembler.receive($0).frames }.count, 1)
    }

    func testStreamFrameOlderThanDatagramsBreaksTheChain() {
        var assembler = RDVideoReassembler(key: key, lastFrame: 2)
        XCTAssertEqual(datagrams(4, payload(50), keyframe: true).flatMap { assembler.receive($0).frames }.count, 1)
        XCTAssertFalse(assembler.noteStreamFrame(3))
        XCTAssertTrue(assembler.awaitingKeyframe)
        XCTAssertTrue(datagrams(5, payload(50)).flatMap { assembler.receive($0).frames }.isEmpty)
    }

    func testOversizedFrameIsRefused() {
        let tooBig = payload((RDVideoDatagram.maxPieces + 1) * RDVideoDatagram.minPieceBody)
        XCTAssertNil(packetizer.datagrams(frame: 1, payload: tooBig, isKeyframe: true, maxDatagramSize: 0))
    }

    func testFECParityRecoversSingleLossInGroup() {
        let fecPacketizer = RDVideoPacketizer(key: key, fecEnabled: true)
        let data = payload(3200, seed: 11)
        // 5 pieces + 1 parity packet (6 total); lose data piece index 2.
        let all = fecPacketizer.datagrams(frame: 1, payload: data, isKeyframe: true, maxDatagramSize: 700)!
        let parityFlag = RDVideoDatagram.fecParityFlag
        let dataPieces = all.filter { ($0[8] & parityFlag) == 0 }
        let parityPieces = all.filter { ($0[8] & parityFlag) != 0 }
        XCTAssertEqual(dataPieces.count, 5)
        XCTAssertEqual(parityPieces.count, 1)

        var assembler = RDVideoReassembler(key: key)
        var delivered: [Data] = []
        var acked: UInt32?
        for datagram in (dataPieces.enumerated().compactMap { $0.offset == 2 ? nil : $0.element } + parityPieces).reversed() {
            let out = assembler.receive(datagram)
            delivered += out.frames
            if let a = out.acked { acked = a }
            XCTAssertEqual(out.dropped, 0)
            XCTAssertFalse(out.needsKeyframe)
        }
        XCTAssertEqual(delivered, [data])
        XCTAssertEqual(acked, 1)
    }

    func testFECSlicesSixPiecesIntoThreePlusThreeGroups() {
        let fecPacketizer = RDVideoPacketizer(key: key, fecEnabled: true)
        // With maxDatagramSize=310, body is 280 B -> 1650 B yields 6 data pieces (3+3 groups).
        let data = payload(1650, seed: 3)
        let all = fecPacketizer.datagrams(frame: 1, payload: data, isKeyframe: true, maxDatagramSize: 310)!
        let parityFlag = RDVideoDatagram.fecParityFlag
        let dataPieces = all.filter { ($0[8] & parityFlag) == 0 }
        let parityPieces = all.filter { ($0[8] & parityFlag) != 0 }
        XCTAssertEqual(dataPieces.count, 6)
        XCTAssertEqual(parityPieces.count, 2)

        // Drop piece 1 (group 0) and piece 4 (group 1) simultaneously.
        let surviving = dataPieces.enumerated().compactMap { ($0.offset == 1 || $0.offset == 4) ? nil : $0.element } + parityPieces
        var assembler = RDVideoReassembler(key: key)
        let delivered = surviving.flatMap { assembler.receive($0).frames }
        XCTAssertEqual(delivered, [data])
    }

    func testFECCannotRecoverTwoLossesInSameGroup() {
        let fecPacketizer = RDVideoPacketizer(key: key, fecEnabled: true)
        let all = fecPacketizer.datagrams(frame: 1, payload: payload(2500), isKeyframe: true, maxDatagramSize: 600)!
        let parityFlag = RDVideoDatagram.fecParityFlag
        let dataPieces = all.filter { ($0[8] & parityFlag) == 0 }
        let parityPieces = all.filter { ($0[8] & parityFlag) != 0 }
        let incomplete = Array(dataPieces.dropFirst(2)) + parityPieces

        var assembler = RDVideoReassembler(key: key)
        for datagram in incomplete {
            XCTAssertTrue(assembler.receive(datagram).frames.isEmpty)
        }
        let next = fecPacketizer.datagrams(frame: 2, payload: payload(100), isKeyframe: false, maxDatagramSize: 600)!
        let out = next.map { assembler.receive($0) }
        XCTAssertTrue(out.allSatisfy { $0.frames.isEmpty })
        XCTAssertTrue(out.contains { $0.needsKeyframe })
        XCTAssertGreaterThanOrEqual(out.reduce(0) { $0 + $1.dropped }, 1)
    }

    func testUnsealedTLSBoundDatagramsSupportFECAndOutOfOrder() {
        let unsealedPacketizer = RDVideoPacketizer(key: nil, fecEnabled: true)
        let data = payload(3200, seed: 29)
        let all = unsealedPacketizer.datagrams(frame: 1, payload: data, isKeyframe: true, maxDatagramSize: 700)!
        let parityFlag = RDVideoDatagram.fecParityFlag
        let dataPieces = all.filter { ($0[8] & parityFlag) == 0 }
        let parityPieces = all.filter { ($0[8] & parityFlag) != 0 }
        let withSingleLoss = (Array(dataPieces.dropFirst()) + parityPieces).shuffled()

        var assembler = RDVideoReassembler(key: nil)
        let delivered = withSingleLoss.flatMap { assembler.receive($0).frames }
        XCTAssertEqual(delivered, [data])
    }

    func testInterleavedFECRecoversConsecutiveBurstLoss() {
        let fecPacketizer = RDVideoPacketizer(key: key, fecEnabled: true)
        // 1650 B at maxDatagramSize=310 splits into 6 data pieces (groups [0..<3] and [3..<6]) + 2 parities.
        let data = payload(1650, seed: 19)
        let all = fecPacketizer.datagrams(frame: 1, payload: data, isKeyframe: true, maxDatagramSize: 310)!
        XCTAssertEqual(all.count, 8)

        // Drop two adjacent wire packets [0, 1] at the front of the burst; interleaving puts them
        // in different XOR groups so both recover without requesting a keyframe.
        let afterBurstDrop = Array(all.dropFirst(2))
        var assembler = RDVideoReassembler(key: key)
        var delivered: [Data] = []
        for datagram in afterBurstDrop {
            let out = assembler.receive(datagram)
            delivered += out.frames
            XCTAssertFalse(out.needsKeyframe)
            XCTAssertEqual(out.dropped, 0)
        }
        XCTAssertEqual(delivered, [data])
    }

    func testFECProtectsSmallMultiPiecePFrame() {
        let fecPacketizer = RDVideoPacketizer(key: key, fecEnabled: true)
        let pFrame = payload(800, seed: 7)
        // At maxDatagramSize=500, splits into 2 data pieces + 1 parity packet even when not a keyframe.
        let all = fecPacketizer.datagrams(frame: 2, payload: pFrame, isKeyframe: false, maxDatagramSize: 500)!
        let parityFlag = RDVideoDatagram.fecParityFlag
        let dataPieces = all.filter { ($0[8] & parityFlag) == 0 }
        let parityPieces = all.filter { ($0[8] & parityFlag) != 0 }
        XCTAssertEqual(dataPieces.count, 2)
        XCTAssertEqual(parityPieces.count, 1)

        var assembler = RDVideoReassembler(key: key, lastFrame: 1)
        let recovered = (Array(dataPieces.dropFirst()) + parityPieces).flatMap { assembler.receive($0).frames }
        XCTAssertEqual(recovered, [pFrame])
    }
}
