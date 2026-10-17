import Foundation

public enum SNError: Error, CustomStringConvertible {
    case notSupernote
    case unsupportedFormat(String)
    case outOfBounds(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .notSupernote: return "Not a Supernote file"
        case .unsupportedFormat(let s): return "Unsupported Supernote format: \(s)"
        case .outOfBounds(let s): return "File is truncated or corrupt: \(s)"
        case .malformed(let s): return "Malformed Supernote file: \(s)"
        }
    }
}

public enum SNFileType: String {
    case note
    case mark
}

/// An ordered list of `<KEY:VALUE>` pairs as stored in Supernote metadata blocks.
public struct SNMetadata {
    public let pairs: [(key: String, value: String)]

    init(_ bytes: Data) {
        // Values never contain '>' (LAYERINFO JSON uses '#' for ':', other blobs are base64).
        let text = String(decoding: bytes, as: UTF8.self)
        var pairs: [(String, String)] = []
        var i = text.startIndex
        while let open = text[i...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { break }
            let tag = text[text.index(after: open)..<close]
            if let colon = tag.firstIndex(of: ":") {
                pairs.append((String(tag[..<colon]), String(tag[tag.index(after: colon)...])))
            }
            i = text.index(after: close)
        }
        self.pairs = pairs
    }

    public subscript(key: String) -> String? {
        pairs.first { $0.key == key }?.value
    }

    /// Value as a block address; nil when absent or zero.
    func address(_ key: String) -> Int? {
        guard let v = self[key], let n = Int(v), n > 0 else { return nil }
        return n
    }
}

public struct SNLayer {
    /// Page metadata key the layer was found under (MAINLAYER, LAYER1…3, BGLAYER).
    public let key: String
    /// LAYERNAME from the layer block; used for LAYERSEQ ordering.
    public let name: String
    public let layerProtocol: String
    public let layerType: String
    public let bitmapAddress: Int?
}

public struct SNPage {
    /// 1-based page number from the footer's PAGEn key.
    public let number: Int
    public let metadata: SNMetadata
    public let layers: [SNLayer]
    public let width: Int
    public let height: Int

    public var style: String { metadata["PAGESTYLE"] ?? "none" }

    public var isLandscape: Bool {
        let o = metadata["ORIENTATION"]
        return o == "1090" || o == "1270"
    }

    /// Layers in drawing order (bottom first), honoring LAYERSEQ when present.
    public var layersBottomUp: [SNLayer] {
        guard let seq = metadata["LAYERSEQ"], seq != "none" else {
            let order = ["BGLAYER", "MAINLAYER", "LAYER1", "LAYER2", "LAYER3"]
            return layers.sorted { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
        }
        let topFirst = seq.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return topFirst.reversed().compactMap { name in layers.first { $0.name == name } }
    }
}


public struct SNTitle {
    public let pageNumber: Int
    public let metadata: SNMetadata
    public let bitmapAddress: Int?
    public let width: Int?
    public let height: Int?
}

public final class SNFile {
    public let data: Data
    public let fileType: SNFileType
    public let signature: String
    public let header: SNMetadata
    public let footer: SNMetadata
    public let pages: [SNPage]
    public let titles: [SNTitle]

    /// Device canvas size in portrait orientation.
    public let deviceWidth: Int
    public let deviceHeight: Int

    public static let dpi: Double = 300

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        // Normalize indices to start at 0 regardless of how the Data was sliced.
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data

        guard data.count >= 28,
              let type = SNFileType(rawValue: String(decoding: data[0..<4], as: UTF8.self))
        else { throw SNError.notSupernote }
        fileType = type

        let sig = String(decoding: data[4..<24], as: UTF8.self)
        guard sig.hasPrefix("SN_FILE_VER_"), Int(sig.dropFirst(12)) != nil else {
            if sig.hasPrefix("SN_FILE_ASA_") { throw SNError.unsupportedFormat("original Supernote (\(sig))") }
            throw SNError.notSupernote
        }
        signature = sig

        let footerAddress = Int(try Self.readUInt32(data, at: data.count - 4))
        footer = SNMetadata(try Self.block(data, at: footerAddress))

        guard let headerAddress = footer.address("FILE_FEATURE") else {
            throw SNError.malformed("footer has no FILE_FEATURE")
        }
        header = SNMetadata(try Self.block(data, at: headerAddress))

        if header["APPLY_EQUIPMENT"] == "N5" {
            (deviceWidth, deviceHeight) = (1920, 2560)  // Manta
        } else {
            (deviceWidth, deviceHeight) = (1404, 1872)  // A5X, A6X, Nomad
        }

        var pageRefs: [(number: Int, address: Int)] = []
        for (key, value) in footer.pairs where key.hasPrefix("PAGE") {
            guard let n = Int(key.dropFirst(4)), let addr = Int(value), addr > 0 else { continue }
            pageRefs.append((n, addr))
        }
        pageRefs.sort { $0.number < $1.number }

        // A page or layer whose block is unreadable is kept blank (or left out), so the rest of a
        // damaged file still renders.
        let (w, h) = (deviceWidth, deviceHeight)
        pages = pageRefs.map { ref in
            let meta = SNMetadata((try? Self.block(data, at: ref.address)) ?? Data())
            var layers: [SNLayer] = []
            for key in ["MAINLAYER", "LAYER1", "LAYER2", "LAYER3", "BGLAYER"] {
                guard let addr = meta.address(key), let block = try? Self.block(data, at: addr) else { continue }
                let lm = SNMetadata(block)
                var name = lm["LAYERNAME"] ?? key
                // Some firmware labels the background layer MAINLAYER as well.
                if name == "MAINLAYER", layers.contains(where: { $0.name == "MAINLAYER" }) { name = "BGLAYER" }
                let bitmap = lm.address("LAYERBITMAP")
                layers.append(SNLayer(
                    key: key, name: name,
                    layerProtocol: Self.layerProtocol(declared: lm["LAYERPROTOCOL"], bitmapAt: bitmap, in: data),
                    layerType: lm["LAYERTYPE"] ?? "",
                    bitmapAddress: bitmap))
            }
            if layers.isEmpty, let addr = meta.address("DATA") {
                // Pre-layer X-series pages store a single bitmap directly.
                layers.append(SNLayer(key: "MAINLAYER", name: "MAINLAYER",
                                      layerProtocol: Self.layerProtocol(declared: meta["PROTOCOL"], bitmapAt: addr, in: data),
                                      layerType: type == .mark ? "MARK" : "NOTE", bitmapAddress: addr))
            }
            let o = meta["ORIENTATION"]
            let landscape = o == "1090" || o == "1270"
            return SNPage(number: ref.number, metadata: meta, layers: layers,
                          width: landscape ? h : w, height: landscape ? w : h)
        }
        
        var titleRefs: [(pageNumber: Int, address: Int)] = []
        for (key, value) in footer.pairs where key.hasPrefix("TITLE_") {
            guard let pageNumber = Int(key.dropFirst(6).prefix(4)),
                    let addr = Int(value), addr > 0 else { continue }
            titleRefs.append((pageNumber, addr))
        }
        
        titles = titleRefs.map { ref in
            let meta = SNMetadata((try? Self.block(data, at: ref.address)) ?? Data())
            var w: Int?
            var h: Int?
            if let rect = meta["TITLERECT"] {
                let splits = rect.split(separator: ",").map { Int($0) }
                if splits.count == 4 {
                    w = splits[2]
                    h = splits[3]
                }
            }

            return SNTitle(
                pageNumber: ref.pageNumber,
                metadata: meta,
                bitmapAddress: meta.address("TITLEBITMAP"),
                width: w,
                height: h
            )
        }
        
        pageRefs.sort { $0.number < $1.number }
    }

    /// Numeric file format version, e.g. 20260016.
    public var formatVersion: Int { Int(signature.dropFirst(12)) ?? 0 }

    /// Files from firmware Chauvet 3.14.27 on use the X2 color codes.
    public var usesX2Colors: Bool { formatVersion >= 20230015 }

    public func block(at address: Int) throws -> Data {
        try Self.block(data, at: address)
    }

    /// Path of the PDF a `.mark` file annotates: `X.pdf.mark` → `X.pdf`.
    public static func companionPDFURL(forMark url: URL) -> URL {
        url.deletingPathExtension()
    }

    static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw SNError.outOfBounds("length field at \(offset)")
        }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    /// PNG if the bitmap is a PNG, otherwise the declared protocol (RATTA_RLE if none).
    /// Custom user templates are PNGs, but depending on firmware their layer declares no
    /// protocol or even RATTA_RLE.
    static func layerProtocol(declared: String?, bitmapAt address: Int?, in data: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        if let address, let length = try? readUInt32(data, at: address), length >= 8,
           address + 4 + 8 <= data.count, data[(address + 4)..<(address + 12)].elementsEqual(pngSignature) {
            return "PNG"
        }
        return declared ?? "RATTA_RLE"
    }

    static func block(_ data: Data, at address: Int) throws -> Data {
        let length = Int(try readUInt32(data, at: address))
        let start = address + 4
        guard start + length <= data.count else {
            throw SNError.outOfBounds("block at \(address) with length \(length)")
        }
        return data.subdata(in: start..<start + length)
    }
}

// MARK: - Layer visibility

public struct SNLayerInfo: Decodable {
    public let layerId: Int
    public let isBackgroundLayer: Bool?
    public let isVisible: Bool?
    public let isDeleted: Bool?

    /// LAYERINFO is JSON with '#' in place of ':' on some firmware, base64-encoded JSON on others.
    static func parse(_ raw: String?) -> [SNLayerInfo]? {
        guard let raw, raw != "none", !raw.isEmpty else { return nil }
        let decoder = JSONDecoder()
        if let d = raw.replacingOccurrences(of: "#", with: ":").data(using: .utf8),
           let infos = try? decoder.decode([SNLayerInfo].self, from: d) {
            return infos
        }
        if let d = Data(base64Encoded: raw),
           let infos = try? decoder.decode([SNLayerInfo].self, from: d) {
            return infos
        }
        return nil
    }

    var layerName: String {
        if isBackgroundLayer == true { return "BGLAYER" }
        return layerId == 0 ? "MAINLAYER" : "LAYER\(layerId)"
    }
}

extension SNPage {
    public var layerInfo: [SNLayerInfo]? { SNLayerInfo.parse(metadata["LAYERINFO"]) }

    /// Layers that should be drawn, bottom first.
    public func visibleLayers(fileType: SNFileType) -> [SNLayer] {
        let infos = layerInfo
        return layersBottomUp.filter { layer in
            guard layer.bitmapAddress != nil else { return false }
            if let infos {
                guard let info = infos.first(where: { $0.layerName == layer.name }) else {
                    return layer.name == "MAINLAYER"
                }
                return info.isVisible != false && info.isDeleted != true
            }
            return fileType == .mark ? layer.layerType == "MARK" : true
        }
    }
}
