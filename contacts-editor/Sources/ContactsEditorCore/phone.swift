import Foundation

// MARK: - Phone Normalization

/// Normalize a Chinese mobile phone number by prepending +86.
/// Returns the new number string, or nil if no change needed.
public func normalizeChinesePhone(_ number: String) -> String? {
    let stripped = number.replacingOccurrences(
        of: #"[\s\-\(\)]"#,
        with: "",
        options: .regularExpression
    )
    guard !stripped.hasPrefix("+") else { return nil }
    guard stripped.count == 11, stripped.hasPrefix("1") else { return nil }
    guard stripped.allSatisfy({ $0.isNumber }) else { return nil }
    return "+86 \(stripped)"
}
