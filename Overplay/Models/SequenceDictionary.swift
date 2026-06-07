import Foundation

extension Sequence {
    func firstValueDictionary<Key: Hashable, Value>(
        keyedBy key: (Element) throws -> Key,
        value: (Element) throws -> Value
    ) rethrows -> [Key: Value] {
        try reduce(into: [Key: Value]()) { result, element in
            let key = try key(element)
            guard result[key] == nil else { return }
            result[key] = try value(element)
        }
    }

    func firstValueDictionary<Key: Hashable>(
        keyedBy key: (Element) throws -> Key
    ) rethrows -> [Key: Element] {
        try firstValueDictionary(keyedBy: key) { $0 }
    }
}
