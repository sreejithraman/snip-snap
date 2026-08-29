import Foundation

package enum SnipLegacyOrderBackfill {
  package static func applying(snips: [Snip], lists: [SnipList]) -> (snips: [Snip], lists: [SnipList]) {
    var snips = snips
    var lists = lists

    if lists.contains(where: { $0.sortKey.requiresLegacyBackfill }) {
      let ordered = lists.indices.sorted {
        if lists[$0].position != lists[$1].position {
          return lists[$0].position < lists[$1].position
        }
        return lists[$0].id.uuidString < lists[$1].id.uuidString
      }
      let keys = try! SnipOrderKey.rebalanced(count: ordered.count)
      for (rank, index) in ordered.enumerated() { lists[index].sortKey = keys[rank] }
    }

    let indicesByList = Dictionary(grouping: snips.indices, by: { snips[$0].listID })
    for indices in indicesByList.values
    where indices.contains(where: { snips[$0].manualSortKey.requiresLegacyBackfill }) {
      let ordered = indices.sorted {
        if snips[$0].manualPosition != snips[$1].manualPosition {
          return snips[$0].manualPosition < snips[$1].manualPosition
        }
        return snips[$0].id.uuidString < snips[$1].id.uuidString
      }
      let keys = try! SnipOrderKey.rebalanced(count: ordered.count)
      for (rank, index) in ordered.enumerated() { snips[index].manualSortKey = keys[rank] }
    }

    return (snips, lists)
  }
}
