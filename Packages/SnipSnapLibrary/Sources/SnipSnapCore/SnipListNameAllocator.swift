import Foundation

package enum SnipListNameAllocator {
  private static let locale = Locale(identifier: "en_US_POSIX")

  package static func cleaned(_ name: String) -> String {
    name.split(whereSeparator: { $0.isWhitespace }).map(String.init).joined(separator: " ")
  }

  package static func normalized(_ name: String) -> String {
    cleaned(name)
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: locale
      )
      .lowercased(with: locale)
  }

  package static func resolving<S: Sequence>(_ input: S) -> [SnipList]
  where S.Element == SnipList {
    var lists = Array(input).map { list in
      SnipList(
        id: list.id,
        desiredName: cleaned(list.desiredName),
        resolvedName: cleaned(list.desiredName),
        systemImage: list.systemImage,
        sortKey: list.sortKey
      )
    }
    let grouped = Dictionary(grouping: lists.indices) { normalized(lists[$0].desiredName) }
    let winners = grouped.values.compactMap { indices in
      indices.min { lists[$0].id.uuidString < lists[$1].id.uuidString }
    }
    var used = Set(winners.map { normalized(lists[$0].desiredName) })
    let winnerSet = Set(winners)
    let losers = lists.indices.filter { !winnerSet.contains($0) }.sorted {
      lists[$0].id.uuidString < lists[$1].id.uuidString
    }
    for index in losers {
      let group = grouped[normalized(lists[index].desiredName)] ?? []
      guard let winner = group.min(by: {
        lists[$0].id.uuidString < lists[$1].id.uuidString
      }) else { continue }
      let base = lists[winner].desiredName
      var suffix = 2
      while true {
        let candidate = "\(base) (\(suffix))"
        if used.insert(normalized(candidate)).inserted {
          lists[index].resolvedName = candidate
          break
        }
        suffix += 1
      }
    }
    return lists
  }
}
