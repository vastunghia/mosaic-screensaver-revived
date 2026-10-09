/// The albums of the library as Photos shows them in its sidebar: folders,
/// subfolders and albums, with Favorites first.
///
/// A choice is a set of identifiers, folders and albums alike. A chosen folder
/// is kept as the folder, not as the albums it holds today: it stands for
/// whatever albums it holds when the library is indexed, so an album added to
/// it later is in scope without being chosen again.
///
/// Plain values, with no PhotoKit in them, so the rules of a choice can be
/// tested without a library. `PhotoLibraryAccess.albumTree()` reads one.
public struct AlbumTree: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case favorites, folder, album
    }

    public struct Node: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let kind: Kind
        /// For an album, PhotoKit's estimate until `excludingVideos(_:)` takes
        /// them out; for a folder, the sum over its albums, which counts twice
        /// a photograph kept in two of them. Only a guide to how big it is.
        public let count: Int
        /// Nil for an album, so a list draws no disclosure triangle for it.
        public let children: [Node]?

        public static func album(id: String, title: String, count: Int) -> Node {
            Node(id: id, title: title, kind: .album, count: count, children: nil)
        }

        public static func favorites(id: String, title: String, count: Int) -> Node {
            Node(id: id, title: title, kind: .favorites, count: count, children: nil)
        }

        public static func folder(id: String, title: String, children: [Node]) -> Node {
            Node(
                id: id, title: title, kind: .folder,
                count: children.reduce(0) { $0 + $1.count }, children: children
            )
        }
    }

    /// How a row's checkbox looks.
    public enum State: Equatable, Sendable {
        case on, off, mixed
    }

    /// A search result, with the titles of the folders it sits in.
    public struct Match: Equatable, Sendable, Identifiable {
        public let node: Node
        public let path: [String]
        public var id: String { node.id }
    }

    public let roots: [Node]

    private let nodes: [String: Node]
    private let parents: [String: String]
    /// Every identifier, in the order the sidebar lists them.
    private let order: [String]

    public init(roots: [Node]) {
        self.roots = roots
        var nodes: [String: Node] = [:]
        var parents: [String: String] = [:]
        var order: [String] = []
        func visit(_ node: Node, parent: String?) {
            nodes[node.id] = node
            parents[node.id] = parent
            order.append(node.id)
            node.children?.forEach { visit($0, parent: node.id) }
        }
        roots.forEach { visit($0, parent: nil) }
        self.nodes = nodes
        self.parents = parents
        self.order = order
    }

    public var isEmpty: Bool { roots.isEmpty }

    public func node(_ id: String) -> Node? { nodes[id] }

    /// The same tree with each album's videos taken out of its count, and the
    /// folders added up again. `videos` maps album identifiers to how many
    /// videos each holds.
    public func excludingVideos(_ videos: [String: Int]) -> AlbumTree {
        func refined(_ node: Node) -> Node {
            if let children = node.children {
                return .folder(id: node.id, title: node.title, children: children.map(refined))
            }
            let count = max(0, node.count - videos[node.id, default: 0])
            return Node(id: node.id, title: node.title, kind: node.kind, count: count, children: nil)
        }
        return AlbumTree(roots: roots.map(refined))
    }

    /// Every album, Favorites included, in sidebar order.
    public var albums: [Node] {
        order.compactMap { nodes[$0] }.filter { $0.kind != .folder }
    }

    // MARK: Choosing

    /// On when the node or a folder above it is chosen, or when everything
    /// below it is; mixed when only part of what is below it is.
    public func state(of id: String, in chosen: Set<String>) -> State {
        if chosen.contains(id) || ancestors(of: id).contains(where: chosen.contains) { return .on }
        guard let children = nodes[id]?.children, !children.isEmpty else { return .off }
        let states = children.map { state(of: $0.id, in: chosen) }
        if states.allSatisfy({ $0 == .on }) { return .on }
        return states.allSatisfy({ $0 == .off }) ? .off : .mixed
    }

    /// The choice after clicking a node's checkbox.
    ///
    /// Turning a folder on keeps the folder and drops what was chosen inside
    /// it. Turning off something that was on because of a folder above it
    /// replaces that folder with the rest of its contents: what is left stops
    /// being a living folder, as in the Finder.
    public func toggling(_ id: String, in chosen: Set<String>) -> Set<String> {
        var result = chosen
        let descendants = self.descendants(of: id)
        guard state(of: id, in: chosen) == .on else {
            result.subtract(descendants)
            result.insert(id)
            return result
        }
        if let folder = ancestors(of: id).first(where: chosen.contains) {
            // Whatever was chosen below the folder was in it already.
            result.remove(folder)
            result.subtract(self.descendants(of: folder))
            result.formUnion(siblings(from: folder, downTo: id))
            return result
        }
        result.remove(id)
        result.subtract(descendants)
        return result
    }

    /// The choice in sidebar order, without identifiers the library no
    /// longer has: what the preferences keep.
    public func ordered(_ chosen: Set<String>) -> [String] {
        order.filter(chosen.contains)
    }

    /// The titles of what is chosen, in sidebar order.
    public func titles(of chosen: [String]) -> [String] {
        ordered(Set(chosen)).compactMap { nodes[$0]?.title }
    }

    // MARK: Searching

    /// Folders and albums whose title contains the query, in sidebar order.
    public func search(_ query: String) -> [Match] {
        order.compactMap { id in
            guard let node = nodes[id], node.title.localizedStandardContains(query) else { return nil }
            return Match(node: node, path: ancestors(of: id).reversed().compactMap { nodes[$0]?.title })
        }
    }

    // MARK: Structure

    /// From the parent up to the top.
    private func ancestors(of id: String) -> [String] {
        var found: [String] = []
        var current = parents[id]
        while let parent = current {
            found.append(parent)
            current = parents[parent]
        }
        return found
    }

    private func descendants(of id: String) -> Set<String> {
        var found = Set<String>()
        func visit(_ node: Node) {
            for child in node.children ?? [] {
                found.insert(child.id)
                visit(child)
            }
        }
        if let node = nodes[id] { visit(node) }
        return found
    }

    /// Walking from a folder down to a node inside it, every child met on the
    /// way that is not the next step: the folder's contents, minus the node.
    private func siblings(from folder: String, downTo id: String) -> Set<String> {
        var found = Set<String>()
        let steps = ([id] + ancestors(of: id).prefix { $0 != folder }).reversed()
        var current = folder
        for next in steps {
            for child in nodes[current]?.children ?? [] where child.id != next {
                found.insert(child.id)
            }
            current = next
        }
        return found
    }
}
