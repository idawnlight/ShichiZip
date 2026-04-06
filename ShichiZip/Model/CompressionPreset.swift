import Foundation

/// Predefined compression presets
struct CompressionPreset {
    let name: String
    let format: SZArchiveFormat
    let level: SZCompressionLevel
    let method: SZCompressionMethod

    var settings: SZCompressionSettings {
        let s = SZCompressionSettings()
        s.format = format
        s.level = level
        s.method = method
        return s
    }

    static let presets: [CompressionPreset] = [
        CompressionPreset(name: "7z - Ultra", format: .format7z, level: .ultra, method: .LZMA2),
        CompressionPreset(name: "7z - Normal", format: .format7z, level: .normal, method: .LZMA2),
        CompressionPreset(name: "7z - Fast", format: .format7z, level: .fast, method: .LZMA2),
        CompressionPreset(name: "ZIP - Normal", format: .formatZip, level: .normal, method: .deflate),
        CompressionPreset(name: "ZIP - Fast", format: .formatZip, level: .fast, method: .deflate),
        CompressionPreset(name: "tar.gz", format: .formatGZip, level: .normal, method: .deflate),
        CompressionPreset(name: "tar.bz2", format: .formatBZip2, level: .normal, method: .bZip2),
        CompressionPreset(name: "tar.xz", format: .formatXz, level: .normal, method: .LZMA2),
    ]
}
