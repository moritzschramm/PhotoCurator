extension Array {
    /// Splits into batches so callers can wrap each batch in one DB write transaction
    /// instead of either one giant transaction or one transaction per row (spec §7.1,
    /// §7.3: "batch writes").
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
