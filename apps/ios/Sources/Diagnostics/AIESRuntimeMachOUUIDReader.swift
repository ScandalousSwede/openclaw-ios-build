import Foundation

enum AIESRuntimeMachOUUIDReader {
    static let source = "runtime_main_executable_lc_uuid"

    struct Slice: Codable, Equatable, Sendable {
        let uuid: String
        let architecture: String
    }

    enum Status: String, Codable, Equatable, Sendable {
        case observed
        case executableUnavailable = "main_executable_unavailable"
        case readFailed = "main_executable_read_failed"
        case uuidMissing = "lc_uuid_missing"
        case malformed = "malformed_main_executable"
    }

    struct Observation: Equatable, Sendable {
        let source: String
        let status: Status
        let slices: [Slice]
    }

    enum ParseError: Error, Equatable {
        case malformed
        case uuidMissing
    }

    static func readMainExecutable(bundle: Bundle = .main) -> Observation {
        guard let executableURL = bundle.executableURL else {
            return Observation(source: self.source, status: .executableUnavailable, slices: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        } catch {
            return Observation(source: self.source, status: .readFailed, slices: [])
        }

        return self.observe(data)
    }

    static func observe(_ data: Data) -> Observation {
        do {
            return Observation(source: self.source, status: .observed, slices: try self.parse(data))
        } catch ParseError.uuidMissing {
            return Observation(source: self.source, status: .uuidMissing, slices: [])
        } catch {
            return Observation(source: self.source, status: .malformed, slices: [])
        }
    }

    static func parse(_ data: Data) throws -> [Slice] {
        try data.withUnsafeBytes { bytes in
            guard bytes.count >= 4 else { throw ParseError.malformed }
            switch self.magic(in: bytes, at: 0) {
            case let .some(.thin(byteOrder, is64Bit)):
                return [try self.parseThin(
                    bytes,
                    offset: 0,
                    size: bytes.count,
                    byteOrder: byteOrder,
                    is64Bit: is64Bit).slice]
            case let .some(.fat(byteOrder, is64Bit)):
                return try self.parseFat(bytes, byteOrder: byteOrder, is64Bit: is64Bit)
            case nil:
                throw ParseError.malformed
            }
        }
    }

    private enum ByteOrder {
        case big
        case little
    }

    private enum Magic {
        case thin(ByteOrder, is64Bit: Bool)
        case fat(ByteOrder, is64Bit: Bool)
    }

    private struct ParsedSlice {
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let slice: Slice
    }

    private static let loadCommandUUID: UInt32 = 0x1B

    private static func parseFat(
        _ bytes: UnsafeRawBufferPointer,
        byteOrder: ByteOrder,
        is64Bit: Bool) throws -> [Slice]
    {
        let count = Int(try self.readUInt32(bytes, at: 4, byteOrder: byteOrder, limit: bytes.count))
        let entrySize = is64Bit ? 32 : 20
        guard count > 0,
              count <= (bytes.count - 8) / entrySize
        else { throw ParseError.malformed }

        var slices: [Slice] = []
        var occupiedRanges: [Range<Int>] = []
        var representedCPUs: Set<String> = []
        let tableEnd = 8 + count * entrySize
        for index in 0..<count {
            let entryOffset = 8 + index * entrySize
            let cpuType = try self.readUInt32(bytes, at: entryOffset, byteOrder: byteOrder, limit: bytes.count)
            let cpuSubtype = try self.readUInt32(
                bytes,
                at: entryOffset + 4,
                byteOrder: byteOrder,
                limit: bytes.count)
            let sliceOffset: UInt64
            let sliceSize: UInt64
            if is64Bit {
                sliceOffset = try self.readUInt64(
                    bytes,
                    at: entryOffset + 8,
                    byteOrder: byteOrder,
                    limit: bytes.count)
                sliceSize = try self.readUInt64(
                    bytes,
                    at: entryOffset + 16,
                    byteOrder: byteOrder,
                    limit: bytes.count)
            } else {
                sliceOffset = UInt64(try self.readUInt32(
                    bytes,
                    at: entryOffset + 8,
                    byteOrder: byteOrder,
                    limit: bytes.count))
                sliceSize = UInt64(try self.readUInt32(
                    bytes,
                    at: entryOffset + 12,
                    byteOrder: byteOrder,
                    limit: bytes.count))
            }
            let alignmentOffset = entryOffset + (is64Bit ? 24 : 16)
            let alignment = try self.readUInt32(
                bytes,
                at: alignmentOffset,
                byteOrder: byteOrder,
                limit: bytes.count)
            if is64Bit {
                let reserved = try self.readUInt32(
                    bytes,
                    at: entryOffset + 28,
                    byteOrder: byteOrder,
                    limit: bytes.count)
                guard reserved == 0 else { throw ParseError.malformed }
            }
            guard sliceOffset <= UInt64(Int.max),
                  sliceSize <= UInt64(Int.max),
                  alignment <= 31
            else { throw ParseError.malformed }
            let offset = Int(sliceOffset)
            let size = Int(sliceSize)
            guard size >= 4,
                  offset >= tableEnd,
                  offset.isMultiple(of: 1 << Int(alignment)),
                  offset <= bytes.count,
                  size <= bytes.count - offset,
                  case let .some(.thin(sliceByteOrder, sliceIs64Bit)) = self.magic(in: bytes, at: offset)
            else { throw ParseError.malformed }
            let occupiedRange = offset..<(offset + size)
            guard !occupiedRanges.contains(where: { $0.overlaps(occupiedRange) })
            else { throw ParseError.malformed }
            let parsed = try self.parseThin(
                bytes,
                offset: offset,
                size: size,
                byteOrder: sliceByteOrder,
                is64Bit: sliceIs64Bit)
            let fatSubtype = cpuSubtype & 0x00FF_FFFF
            let thinSubtype = parsed.cpuSubtype & 0x00FF_FFFF
            let cpuKey = "\(cpuType):\(cpuSubtype)"
            guard parsed.cpuType == cpuType,
                  thinSubtype == fatSubtype,
                  representedCPUs.insert(cpuKey).inserted
            else { throw ParseError.malformed }
            occupiedRanges.append(occupiedRange)
            slices.append(parsed.slice)
        }
        return slices.sorted {
            if $0.architecture != $1.architecture {
                return $0.architecture < $1.architecture
            }
            return $0.uuid < $1.uuid
        }
    }

    private static func parseThin(
        _ bytes: UnsafeRawBufferPointer,
        offset: Int,
        size: Int,
        byteOrder: ByteOrder,
        is64Bit: Bool) throws -> ParsedSlice
    {
        let headerSize = is64Bit ? 32 : 28
        guard size >= headerSize else { throw ParseError.malformed }
        let limit = offset + size
        let cpuType = try self.readUInt32(bytes, at: offset + 4, byteOrder: byteOrder, limit: limit)
        let cpuSubtype = try self.readUInt32(bytes, at: offset + 8, byteOrder: byteOrder, limit: limit)
        let fileType = try self.readUInt32(bytes, at: offset + 12, byteOrder: byteOrder, limit: limit)
        let commandCount = Int(try self.readUInt32(bytes, at: offset + 16, byteOrder: byteOrder, limit: limit))
        let commandBytes = Int(try self.readUInt32(bytes, at: offset + 20, byteOrder: byteOrder, limit: limit))
        guard fileType == 2,
              commandCount > 0,
              commandBytes >= commandCount * 8,
              commandBytes <= size - headerSize
        else { throw ParseError.malformed }

        var commandOffset = offset + headerSize
        let commandsEnd = commandOffset + commandBytes
        var uuid: String?
        for _ in 0..<commandCount {
            let command = try self.readUInt32(bytes, at: commandOffset, byteOrder: byteOrder, limit: commandsEnd)
            let commandSize = Int(try self.readUInt32(
                bytes,
                at: commandOffset + 4,
                byteOrder: byteOrder,
                limit: commandsEnd))
            guard commandSize >= 8,
                  commandSize.isMultiple(of: is64Bit ? 8 : 4),
                  commandSize <= commandsEnd - commandOffset
            else { throw ParseError.malformed }
            if command == self.loadCommandUUID {
                guard commandSize == 24, uuid == nil else { throw ParseError.malformed }
                uuid = try self.readUUID(bytes, at: commandOffset + 8, limit: commandsEnd)
            }
            commandOffset += commandSize
        }
        guard commandOffset == commandsEnd else { throw ParseError.malformed }
        guard let uuid else { throw ParseError.uuidMissing }
        return ParsedSlice(
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            slice: Slice(
                uuid: uuid,
                architecture: self.architecture(cpuType: cpuType, cpuSubtype: cpuSubtype)))
    }

    private static func magic(in bytes: UnsafeRawBufferPointer, at offset: Int) -> Magic? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        switch (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) {
        case (0xFE, 0xED, 0xFA, 0xCE): .thin(.big, is64Bit: false)
        case (0xCE, 0xFA, 0xED, 0xFE): .thin(.little, is64Bit: false)
        case (0xFE, 0xED, 0xFA, 0xCF): .thin(.big, is64Bit: true)
        case (0xCF, 0xFA, 0xED, 0xFE): .thin(.little, is64Bit: true)
        case (0xCA, 0xFE, 0xBA, 0xBE): .fat(.big, is64Bit: false)
        case (0xBE, 0xBA, 0xFE, 0xCA): .fat(.little, is64Bit: false)
        case (0xCA, 0xFE, 0xBA, 0xBF): .fat(.big, is64Bit: true)
        case (0xBF, 0xBA, 0xFE, 0xCA): .fat(.little, is64Bit: true)
        default: nil
        }
    }

    private static func readUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        byteOrder: ByteOrder,
        limit: Int) throws -> UInt32
    {
        guard offset >= 0,
              limit <= bytes.count,
              offset <= limit - 4
        else { throw ParseError.malformed }
        let values = (0..<4).map { UInt32(bytes[offset + $0]) }
        switch byteOrder {
        case .big:
            return values[0] << 24 | values[1] << 16 | values[2] << 8 | values[3]
        case .little:
            return values[3] << 24 | values[2] << 16 | values[1] << 8 | values[0]
        }
    }

    private static func readUInt64(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        byteOrder: ByteOrder,
        limit: Int) throws -> UInt64
    {
        guard offset >= 0,
              limit <= bytes.count,
              offset <= limit - 8
        else { throw ParseError.malformed }
        let values = (0..<8).map { UInt64(bytes[offset + $0]) }
        switch byteOrder {
        case .big:
            return values.reduce(0) { $0 << 8 | $1 }
        case .little:
            return values.reversed().reduce(0) { $0 << 8 | $1 }
        }
    }

    private static func readUUID(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        limit: Int) throws -> String
    {
        guard offset >= 0,
              limit <= bytes.count,
              offset <= limit - 16
        else { throw ParseError.malformed }
        let value: uuid_t = (
            bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
            bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
            bytes[offset + 8], bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
            bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15])
        return UUID(uuid: value).uuidString.lowercased()
    }

    private static func architecture(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        let subtype = cpuSubtype & 0x00FF_FFFF
        switch (cpuType, subtype) {
        case (0x0100_000C, 2): "arm64e"
        case (0x0100_000C, _): "arm64"
        case (0x0200_000C, _): "arm64_32"
        case (0x0000_000C, _): "arm"
        case (0x0100_0007, 8): "x86_64h"
        case (0x0100_0007, _): "x86_64"
        case (0x0000_0007, _): "i386"
        default: "cpu-\(String(cpuType, radix: 16))-subtype-\(String(subtype, radix: 16))"
        }
    }
}
