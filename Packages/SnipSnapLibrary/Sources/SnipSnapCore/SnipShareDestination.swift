import Foundation

public enum SnipShareDestination {
  public static func resolve(rememberedListID: UUID?, in lists: [SnipList]) -> UUID {
    guard let rememberedListID,
      lists.contains(where: { $0.id == rememberedListID })
    else { return SnipList.inboxID }
    return rememberedListID
  }
}
