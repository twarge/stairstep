import Compression
import Foundation

/// Minimal read-only ZIP reader, enough for the container formats this app opens
/// (FreeCAD `.FCStd` today). Entries are located through the central directory and
/// inflated on demand, so opening an archive costs only the directory scan.
///
/// Deliberately small: store (method 0) and deflate (method 8) are the only
/// compression methods FreeCAD emits, and ZIP64 archives are rejected rather than
/// half-supported. Anything outside that surface throws.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable {
        public let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public enum Error: Swift.Error, LocalizedError {
        case notAnArchive
        case unsupportedZip64
        case unsupportedCompression(UInt16)
        case malformedEntry(String)
        case decompressionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAnArchive:
                "The file is not a zip archive."
            case .unsupportedZip64:
                "ZIP64 archives are not supported."
            case let .unsupportedCompression(method):
                "Unsupported zip compression method \(method)."
            case let .malformedEntry(name):
                "The zip entry '\(name)' is malformed."
            case let .decompressionFailed(name):
                "The zip entry '\(name)' could not be decompressed."
            }
        }
    }

    private let data: Data
    public let entries: [Entry]

    public init(data: Data) throws {
        // Every offset below is relative to the archive start, so rebase slices —
        // a `Data` handed in from a larger buffer carries a non-zero startIndex.
        let normalized = data.startIndex == 0 ? data : Data(data)
        self.data = normalized
        self.entries = try Self.readCentralDirectory(in: normalized)
    }

    public var entryNames: [String] { entries.map(\.name) }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    public func contains(_ name: String) -> Bool {
        entry(named: name) != nil
    }

    /// Inflates `entry` and returns its bytes.
    public func contents(of entry: Entry) throws -> Data {
        // The central directory records where the local header sits, but the local
        // header's own name/extra lengths are what the payload actually follows —
        // they can differ from the central copy, so re-read them here.
        guard let signature: UInt32 = data.readLE(at: entry.localHeaderOffset), signature == 0x0403_4b50 else {
            throw Error.malformedEntry(entry.name)
        }
        guard let nameLength: UInt16 = data.readLE(at: entry.localHeaderOffset + 26),
              let extraLength: UInt16 = data.readLE(at: entry.localHeaderOffset + 28) else {
            throw Error.malformedEntry(entry.name)
        }

        let start = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count, start <= end else {
            throw Error.malformedEntry(entry.name)
        }

        let payload = data.subdata(in: start..<end)

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expecting: entry.uncompressedSize, name: entry.name)
        default:
            throw Error.unsupportedCompression(entry.compressionMethod)
        }
    }

    public func contents(ofEntryNamed name: String) throws -> Data? {
        guard let entry = entry(named: name) else {
            return nil
        }
        return try contents(of: entry)
    }

    /// Raw deflate — a zip entry carries no zlib header, which is exactly what
    /// `COMPRESSION_ZLIB` expects here.
    private func inflate(_ payload: Data, expecting size: Int, name: String) throws -> Data {
        guard size > 0 else {
            return Data()
        }

        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    size,
                    sourceBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written == size else {
            throw Error.decompressionFailed(name)
        }
        return output
    }

    // MARK: - Central directory

    private static func readCentralDirectory(in data: Data) throws -> [Entry] {
        guard data.count > 22 else {
            throw Error.notAnArchive
        }

        // The end-of-central-directory record sits at the tail, after a comment of
        // up to 64 KB, so scan backwards for its signature.
        let maximumCommentLength = 65_535
        let lowerBound = max(0, data.count - 22 - maximumCommentLength)
        var endOffset: Int?
        var cursor = data.count - 22
        while cursor >= lowerBound {
            if let signature: UInt32 = data.readLE(at: cursor), signature == 0x0605_4b50 {
                endOffset = cursor
                break
            }
            cursor -= 1
        }

        guard let endOffset else {
            throw Error.notAnArchive
        }

        guard let entryCount: UInt16 = data.readLE(at: endOffset + 10),
              let directorySize: UInt32 = data.readLE(at: endOffset + 12),
              let directoryOffset: UInt32 = data.readLE(at: endOffset + 16) else {
            throw Error.notAnArchive
        }

        // 0xFFFF/0xFFFFFFFF sentinels mean the real values live in a ZIP64 record.
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF {
            throw Error.unsupportedZip64
        }

        var entries = [Entry]()
        entries.reserveCapacity(Int(entryCount))
        var offset = Int(directoryOffset)

        for _ in 0..<Int(entryCount) {
            guard let signature: UInt32 = data.readLE(at: offset), signature == 0x0201_4b50 else {
                throw Error.notAnArchive
            }
            guard let method: UInt16 = data.readLE(at: offset + 10),
                  let compressedSize: UInt32 = data.readLE(at: offset + 20),
                  let uncompressedSize: UInt32 = data.readLE(at: offset + 24),
                  let nameLength: UInt16 = data.readLE(at: offset + 28),
                  let extraLength: UInt16 = data.readLE(at: offset + 30),
                  let commentLength: UInt16 = data.readLE(at: offset + 32),
                  let localHeaderOffset: UInt32 = data.readLE(at: offset + 42) else {
                throw Error.notAnArchive
            }

            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else {
                throw Error.notAnArchive
            }
            let name = String(decoding: data.subdata(in: nameStart..<nameEnd), as: UTF8.self)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                throw Error.unsupportedZip64
            }

            entries.append(
                Entry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    localHeaderOffset: Int(localHeaderOffset)
                )
            )

            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }

        return entries
    }
}

private extension Data {
    /// Reads a little-endian fixed-width integer at `offset`, or nil if the range
    /// runs past the end. Assembled byte by byte: the offsets in a zip directory
    /// have no alignment guarantees.
    func readLE<T: FixedWidthInteger>(at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else {
            return nil
        }
        var value: T = 0
        for byteIndex in stride(from: size - 1, through: 0, by: -1) {
            let byte = self[startIndex + offset + byteIndex]
            value = (value << 8) | T(byte)
        }
        return value
    }
}
