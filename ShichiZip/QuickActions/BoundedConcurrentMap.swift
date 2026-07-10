import Foundation

@MainActor
private final class ShichiZipBoundedConcurrentMapCoordinator<Element, Output: Sendable> {
    private let elements: [Element]
    private let transform: @MainActor (Element) async throws -> Output

    init(elements: [Element],
         transform: @escaping @MainActor (Element) async throws -> Output)
    {
        self.elements = elements
        self.transform = transform
    }

    func transformElement(at index: Int) async throws -> Output {
        try await transform(elements[index])
    }
}

private enum ShichiZipBoundedConcurrentMapSlot<Value> {
    case pending
    case value(Value)
}

@MainActor
func shichiZipBoundedConcurrentMap<Element, Output: Sendable>(
    _ elements: [Element],
    maxConcurrentTasks: Int,
    transform: @escaping @MainActor (Element) async throws -> Output,
) async throws -> [Output] {
    precondition(maxConcurrentTasks > 0)
    guard !elements.isEmpty else { return [] }

    let coordinator = ShichiZipBoundedConcurrentMapCoordinator(elements: elements,
                                                               transform: transform)
    let elementCount = elements.count

    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var nextIndex = 0
        var results = [ShichiZipBoundedConcurrentMapSlot<Output>](repeating: .pending,
                                                                  count: elementCount)

        while nextIndex < min(maxConcurrentTasks, elementCount) {
            let index = nextIndex
            nextIndex += 1
            group.addTask {
                try await (index, coordinator.transformElement(at: index))
            }
        }

        while let (index, output) = try await group.next() {
            results[index] = .value(output)

            if nextIndex < elementCount {
                let pendingIndex = nextIndex
                nextIndex += 1
                group.addTask {
                    try await (pendingIndex, coordinator.transformElement(at: pendingIndex))
                }
            }
        }

        return results.map { slot in
            switch slot {
            case .pending:
                preconditionFailure("Bounded concurrent map finished without producing every result.")
            case let .value(output):
                output
            }
        }
    }
}
