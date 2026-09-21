import MosaicCore

/// One photograph, as the solver sees it: an identifier it never looks inside,
/// and the colours it will be judged by.
public struct PoolEntry: Equatable, Sendable {
    public let id: PhotoID
    public let signature: TileSignature

    public init(id: PhotoID, signature: TileSignature) {
        self.id = id
        self.signature = signature
    }
}
