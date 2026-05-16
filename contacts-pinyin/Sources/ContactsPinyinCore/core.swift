import Foundation

/// Check if string contains any CJK Unified Ideograph (U+4E00–U+9FFF).
func containsCJK(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) {
            return true
        }
    }
    return false
}
