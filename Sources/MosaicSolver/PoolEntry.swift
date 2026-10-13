import MosaicCore

/// One photograph, as the solver sees it: an identifier it never looks inside,
/// and the colours it will be judged by.
public struct PoolEntry: Equatable, Sendable {
    public let id: PhotoID
    public let signature: TileSignature

    /// Whether it has the pixels for the anchor's ring, where tiles come on
    /// screen several atlas slices wide (`SolverOptions.sharpRing`).
    public let isSharp: Bool

    public init(id: PhotoID, signature: TileSignature, isSharp: Bool = true) {
        self.id = id
        self.signature = signature
        self.isSharp = isSharp
    }
}
