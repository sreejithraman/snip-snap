import Foundation
import SnipSnapCore
import SwiftData
import Testing
import XCTest

@testable import SnipSnapCloud
@testable import SnipSnapPersistence

private extension SwiftDataSnipLibrary {
  func storedAttachmentReferencePositions(for snipID: UUID) throws -> [UUID: Int] {
    let context = Self.makeContext(container: try XCTUnwrap(container))
    let references = try context.fetch(FetchDescriptor<StoredSnipAttachmentReference>(
      predicate: #Predicate<StoredSnipAttachmentReference> { $0.snipID == snipID }
    ))
    return Dictionary(uniqueKeysWithValues: references.map { ($0.attachmentID, $0.position) })
  }
}

private struct AttachmentClient {
  let root: URL
  let storeURL: URL
  let namespace: CloudSyncNamespace
  let server: FakeCloudServer
  let snipID: UUID
  let library: SwiftDataSnipLibrary
  let store: CloudFullSyncPersistence
  let transport: FakeCloudRecordTransport
  let sync: CloudFullSyncCoordinator
}

private struct LocalAttachmentSeed {
  let root: URL
  let storeURL: URL
  let library: SwiftDataSnipLibrary
  let namespace: CloudSyncNamespace
  let snipID: UUID
}

fileprivate protocol AttachmentTransferTestSupport {}

fileprivate extension AttachmentTransferTestSupport {
  /// One client with one snip whose attachments come from local files, enrolled but not synced.
  func makeAttachmentClient(fileNames: [String]) async throws -> AttachmentClient {
    let seed = try await makeLocalAttachmentSeed(names: fileNames)
    let client = attachmentClient(
      root: seed.root,
      storeURL: seed.storeURL,
      library: seed.library,
      namespace: seed.namespace,
      server: FakeCloudServer(),
      snipID: seed.snipID
    )
    try await client.store.approveEnrollment(references: [
      CloudEntityReference(kind: .list, domainID: SnipList.inbox.id),
      CloudEntityReference(kind: .snip, domainID: seed.snipID),
    ])
    return client
  }

  func attachmentClient(
    root: URL,
    storeURL: URL,
    namespace: CloudSyncNamespace,
    server: FakeCloudServer,
    snipID: UUID
  ) throws -> AttachmentClient {
    attachmentClient(
      root: root,
      storeURL: storeURL,
      library: try SwiftDataSnipLibrary(storeURL: storeURL),
      namespace: namespace,
      server: server,
      snipID: snipID
    )
  }

  func attachmentClient(
    root: URL,
    storeURL: URL,
    library: SwiftDataSnipLibrary,
    namespace: CloudSyncNamespace,
    server: FakeCloudServer,
    snipID: UUID
  ) -> AttachmentClient {
    let dataZone = CloudZoneID(name: "data", ownerName: "owner")
    let store = CloudFullSyncPersistence(
      library: library,
      namespace: namespace,
      dataZone: dataZone,
      payloadZone: CloudZoneID(name: "payload", ownerName: "owner")
    )
    let transport = FakeCloudRecordTransport(
      server: server,
      namespace: namespace,
      automaticallyFetchedZones: [dataZone]
    )
    return AttachmentClient(
      root: root,
      storeURL: storeURL,
      namespace: namespace,
      server: server,
      snipID: snipID,
      library: library,
      store: store,
      transport: transport,
      sync: CloudFullSyncCoordinator(store: store, transport: transport, fetchScope: .zones([dataZone]))
    )
  }

  /// Edits the snip so it keeps only these attachments, in this order, as the editor does.
  func keepAttachments(
    _ attachmentIDs: [UUID],
    ofSnip snipID: UUID,
    in library: SwiftDataSnipLibrary
  ) async throws {
    let local = try await library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == snipID }), "The snip must exist.")
    _ = try await library.perform(
      .editAttachments(
        snipID: snipID,
        content: snip.content,
        edits: attachmentIDs.map { SnipAttachmentEdit.existing(attachmentID: $0) },
        expectedUpdatedAt: snip.updatedAt,
        now: Date(timeIntervalSince1970: 2)
      ),
      sortedBy: .manual
    )
  }

  /// Renames an attachment, defaulting to the first, as a whole-library replace does.
  func renameAttachment(
    ofSnip snipID: UUID,
    attachmentID: UUID? = nil,
    to fileName: String,
    in library: SwiftDataSnipLibrary
  ) async throws {
    var snips = try await library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == snipID }), "The snip must exist.")
    let attachmentIndex: Int
    if let attachmentID {
      attachmentIndex = try XCTUnwrap(snips[index].attachments.firstIndex(where: { $0.id == attachmentID }))
    } else {
      attachmentIndex = 0
    }
    snips[index].attachments[attachmentIndex].fileName = fileName
    _ = try await library.perform(.replaceAll(snips), sortedBy: .manual)
  }

  func makeLocalAttachmentSeed(names: [String]) async throws -> LocalAttachmentSeed {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sources = try names.map { name in
      let url = root.appendingPathComponent("\(name).txt")
      try Data("\(name) payload".utf8).write(to: url)
      return url
    }
    let storeURL = root.appendingPathComponent("store")
    let library = try SwiftDataSnipLibrary(storeURL: storeURL)
    let added = try await library.perform(
      .add(
        content: "attachment fixture",
        origin: .quickEntry,
        source: nil,
        listID: SnipList.inbox.id,
        attachmentURLs: sources,
        requestID: UUID(),
        now: .distantPast
      ),
      sortedBy: .manual
    )
    return LocalAttachmentSeed(
      root: root,
      storeURL: storeURL,
      library: library,
      namespace: namespaceValue(),
      snipID: try XCTUnwrap(added.snapshot.snips.first?.id, "The fixture must save its snip.")
    )
  }

  func namespaceValue() -> CloudSyncNamespace {
    CloudSyncNamespace(
      cloudScope: "private",
      accountLineage: "account",
      generation: UUID(),
      zones: [
        CloudZoneID(name: "data", ownerName: "owner"),
        CloudZoneID(name: "payload", ownerName: "owner"),
      ]
    )
  }

  func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("CloudAttachmentTransferTests-\(UUID().uuidString)", isDirectory: true)
  }
}

private enum AttachmentMatrixMember: UInt8, CaseIterable, Sendable {
  case a = 3, b = 1, c = 2, n = 4, m = 5

  var id: UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, rawValue))
  }

  var fileName: String {
    switch self {
    case .a: "A.txt"
    case .b: "B.txt"
    case .c: "C.txt"
    case .n: "N.txt"
    case .m: "M.txt"
    }
  }

  static let initial: [Self] = [.a, .b, .c]
  static let localOrder: [Self] = [.b, .a, .c]
  static let remoteOrder: [Self] = [.c, .a, .b]
}

private enum AttachmentMatrixRole: String, CaseIterable, Sendable {
  case holder = "H", downloaded = "D"
}

private enum AttachmentMatrixLocal: String, CaseIterable, Sendable {
  case none, rename, reorder
  case addUnrecorded = "add-unrecorded"
  case addRecorded = "add-recorded"
  case removeRecorded = "remove-A-recorded"
  case inFlightReorder = "in-flight-reorder"
}

private enum AttachmentMatrixRemote: String, CaseIterable, Sendable {
  case none, rename, reorder, add
  case remove = "remove-C"
}

private struct AttachmentMatrixCell: Sendable, CustomStringConvertible {
  let role: AttachmentMatrixRole
  let local: AttachmentMatrixLocal
  let remote: AttachmentMatrixRemote

  var description: String { "L=\(role.rawValue) local=\(local.rawValue) remote=\(remote.rawValue)" }

  static let all = AttachmentMatrixRole.allCases.flatMap { role in
    AttachmentMatrixLocal.allCases.flatMap { local in
      AttachmentMatrixRemote.allCases.map { remote in Self(role: role, local: local, remote: remote) }
    }
  }

  static let holderCells = all.filter { $0.role == .holder }
  static let downloadedCells = all.filter { $0.role == .downloaded }

  var expectedNames: [UUID: String] {
    var names = Dictionary(uniqueKeysWithValues: AttachmentMatrixMember.initial.map { ($0.id, $0.fileName) })
    if local == .removeRecorded { names.removeValue(forKey: AttachmentMatrixMember.a.id) }
    if remote == .remove { names.removeValue(forKey: AttachmentMatrixMember.c.id) }
    if local == .addUnrecorded || local == .addRecorded {
      names[AttachmentMatrixMember.n.id] = AttachmentMatrixMember.n.fileName
    }
    if remote == .add { names[AttachmentMatrixMember.m.id] = AttachmentMatrixMember.m.fileName }
    if remote == .rename && local != .inFlightReorder { names[AttachmentMatrixMember.b.id] = "remote-B.txt" }
    if local == .rename { names[AttachmentMatrixMember.b.id] = "local-B.txt" }
    return names
  }

  var expectedSharedOrder: [UUID] {
    let members: [AttachmentMatrixMember]
    if local == .reorder || local == .inFlightReorder {
      members = AttachmentMatrixMember.localOrder
    } else if remote == .reorder {
      members = AttachmentMatrixMember.remoteOrder
    } else {
      members = AttachmentMatrixMember.initial
    }
    return members.map(\.id).filter { expectedNames[$0] != nil }
  }

  // SM33-D5 permits the pending device's whole edit, subject to main's edit-survival floor.
  var allowedNames: [[UUID: String]] {
    guard local == .removeRecorded && remote == .rename else { return [expectedNames] }
    var pendingNames = expectedNames
    pendingNames[AttachmentMatrixMember.b.id] = AttachmentMatrixMember.b.fileName
    return [expectedNames, pendingNames]
  }

  var allowedSharedOrders: [[UUID]] {
    let remoteAddWithLocalReorder = remote == .add && (local == .reorder || local == .inFlightReorder)
    let localMembershipWithRemoteReorder = remote == .reorder && (local == .addRecorded || local == .removeRecorded)
    guard remoteAddWithLocalReorder || localMembershipWithRemoteReorder else {
      return [expectedSharedOrder]
    }
    let pendingOrder = AttachmentMatrixMember.initial.map(\.id).filter { expectedNames[$0] != nil }
    return [expectedSharedOrder, pendingOrder]
  }

  var mainFloorSharedOrder: [UUID]? {
    switch (role, local, remote) {
    case (.holder, .reorder, .add), (.holder, .inFlightReorder, .add):
      AttachmentMatrixMember.localOrder.map(\.id)
    case (.downloaded, .addRecorded, .reorder):
      AttachmentMatrixMember.remoteOrder.map(\.id)
    case (.downloaded, .removeRecorded, .reorder):
      [AttachmentMatrixMember.c.id, AttachmentMatrixMember.b.id]
    default:
      nil
    }
  }

  var mainFloorNames: [UUID: String] {
    if role == .downloaded && local == .removeRecorded && remote == .rename {
      return [AttachmentMatrixMember.b.id: "remote-B.txt"]
    }
    return [:]
  }
}

private struct AttachmentEditClients {
  let holder: AttachmentClient
  let downloaded: AttachmentClient
}

fileprivate extension AttachmentTransferTestSupport {
  func makeAttachmentEditClients(attachmentCount: Int = 3) async throws -> AttachmentEditClients {
    let members = Array(AttachmentMatrixMember.initial.prefix(attachmentCount))
    let holder = try await makeAttachmentClient(fileNames: members.map { String($0.fileName.dropLast(4)) })
    var snips = try await holder.library.checkedSnapshot(sortedBy: .manual).snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == holder.snipID }))
    snips[index].attachments = zip(members, snips[index].attachments).map { member, attachment in
      SnipAttachment(id: member.id, fileName: member.fileName, relativePath: attachment.relativePath,
        contentType: "public.plain-text", byteCount: attachment.byteCount)
    }
    _ = try await holder.library.perform(.replaceAll(snips), sortedBy: .manual)
    try await holder.sync.sync()
    try await holder.sync.sync()
    let downloaded = try attachmentClient(root: holder.root,
      storeURL: holder.root.appendingPathComponent("downloaded.store"),
      namespace: holder.namespace, server: holder.server, snipID: holder.snipID)
    try await downloaded.sync.fetchRemote()
    let downloads = CloudAttachmentTransferCoordinator(library: downloaded.library,
      namespace: holder.namespace, payloadZone: CloudZoneID(name: "payload", ownerName: "owner"),
      transport: downloaded.transport, maximumCacheBytes: 1_024)
    for member in members { _ = try await downloads.download(attachmentID: member.id) }
    return AttachmentEditClients(holder: holder, downloaded: downloaded)
  }

  func appendAttachment(_ member: AttachmentMatrixMember, to client: AttachmentClient) async throws {
    let local = try await client.library.checkedSnapshot(sortedBy: .manual)
    let snip = try XCTUnwrap(local.snips.first(where: { $0.id == client.snipID }))
    let source = client.root.appendingPathComponent(member.fileName)
    try Data("\(member.fileName) payload".utf8).write(to: source)
    let update = try await client.library.perform(.editAttachments(
      snipID: client.snipID, content: snip.content,
      edits: snip.attachments.map { .existing(attachmentID: $0.id) } + [.added(sourceURL: source)],
      expectedUpdatedAt: snip.updatedAt, now: Date(timeIntervalSince1970: 3)
    ), sortedBy: .manual)
    var snips = update.snapshot.snips
    let index = try XCTUnwrap(snips.firstIndex(where: { $0.id == client.snipID }))
    let addedIndex = try XCTUnwrap(snips[index].attachments.firstIndex(where: { $0.fileName == member.fileName }))
    let added = snips[index].attachments[addedIndex]
    snips[index].attachments[addedIndex] = SnipAttachment(id: member.id, fileName: member.fileName,
      relativePath: added.relativePath, contentType: "public.plain-text", byteCount: added.byteCount)
    _ = try await client.library.perform(.replaceAll(snips), sortedBy: .manual)
  }
}

@Suite(.serialized)
private struct AttachmentEditInvariantMatrixTests: AttachmentTransferTestSupport {
  @Test(arguments: AttachmentMatrixCell.holderCells)
  func testAttachmentEditInvariantMatrixWithLocalFiles(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  @Test(arguments: AttachmentMatrixCell.downloadedCells)
  func testAttachmentEditInvariantMatrixWithDownloadsOnly(_ cell: AttachmentMatrixCell) async {
    await run(cell)
  }

  private func run(_ cell: AttachmentMatrixCell) async {
    var log = "result=FAIL server=[] H=[] D=[]"
    defer { print("MATRIX role=\(cell) \(log)") }
    do {
      let clients = try await makeAttachmentEditClients()
      defer { try? FileManager.default.removeItem(at: clients.holder.root) }
      let local = cell.role == .holder ? clients.holder : clients.downloaded
      let remote = cell.role == .holder ? clients.downloaded : clients.holder
      try await applyLocal(cell.local, to: local)
      try await applyRemote(cell.remote, to: remote)
      try await remote.sync.sync()
      try await local.sync.sync()
      try await remote.sync.sync()
      for _ in 0..<2 {
        try await local.sync.sync()
        try await remote.sync.sync()
      }
      log = try await checkInvariants(cell, clients: clients)
    } catch {
      Issue.record("\(cell) threw: \(error)")
      log += " error=\(String(reflecting: String(describing: error)))"
    }
  }

  private func applyLocal(_ change: AttachmentMatrixLocal, to client: AttachmentClient) async throws {
    switch change {
    case .none: break
    case .rename:
      try await renameAttachment(ofSnip: client.snipID, attachmentID: AttachmentMatrixMember.b.id,
        to: "local-B.txt", in: client.library)
    case .reorder, .inFlightReorder:
      try await keepAttachments(AttachmentMatrixMember.localOrder.map(\.id), ofSnip: client.snipID, in: client.library)
      if change == .inFlightReorder {
        _ = try await client.store.pendingChanges()
        for member in [AttachmentMatrixMember.a, .b] {
          await client.transport.failNextSentItem(metadataID(member), failure: .retryable)
        }
        try await client.sync.sendPending()
      }
    case .addUnrecorded, .addRecorded:
      try await appendAttachment(.n, to: client)
      if change == .addRecorded { _ = try await client.store.pendingChanges() }
    case .removeRecorded:
      try await keepAttachments([AttachmentMatrixMember.b.id, AttachmentMatrixMember.c.id],
        ofSnip: client.snipID, in: client.library)
      _ = try await client.store.pendingChanges()
    }
  }

  private func applyRemote(_ change: AttachmentMatrixRemote, to client: AttachmentClient) async throws {
    switch change {
    case .none: break
    case .rename:
      try await renameAttachment(ofSnip: client.snipID, attachmentID: AttachmentMatrixMember.b.id,
        to: "remote-B.txt", in: client.library)
    case .reorder:
      try await keepAttachments(AttachmentMatrixMember.remoteOrder.map(\.id), ofSnip: client.snipID, in: client.library)
    case .add:
      try await appendAttachment(.m, to: client)
    case .remove:
      try await keepAttachments([AttachmentMatrixMember.a.id, AttachmentMatrixMember.b.id],
        ofSnip: client.snipID, in: client.library)
      _ = try await client.store.pendingChanges()
    }
  }

  private func metadataID(_ member: AttachmentMatrixMember) -> CloudRecordID {
    CloudAttachmentRecordCodec.recordID(CloudTextStorageIdentity(zoneName: "data", ownerName: "owner",
      recordName: "a-\(member.id.uuidString.lowercased())"))
  }

  private func checkInvariants(_ cell: AttachmentMatrixCell, clients: AttachmentEditClients) async throws -> String {
    let expectedNames = cell.expectedNames
    let expectedIDs = Set(expectedNames.keys)
    let expectedTypes = expectedNames.mapValues { _ in "public.plain-text" }
    let sharedIDs = Set(AttachmentMatrixMember.initial.map(\.id)).intersection(expectedIDs)
    let types = await clients.holder.server.storedRecordTypes(in: CloudZoneID(name: "data", ownerName: "owner"))
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
      #expect(condition, "\(cell) \(message)")
      if !condition { failures.append(message) }
    }
    check(types.filter { $0 == CloudAttachmentRecordCodec.metadataRecordType }.count == expectedIDs.count,
      "server membership count")
    var serverPositions: [UUID: Int] = [:]
    var serverNames: [UUID: String] = [:]
    var serverTypes: [UUID: String] = [:]
    for member in AttachmentMatrixMember.allCases {
      let record = await clients.holder.server.fullSnapshot(for: metadataID(member))
      if expectedNames[member.id] == nil {
        check(record == nil, "absent server member \(member.fileName)")
        continue
      }
      check(record != nil, "server has member \(member.fileName)")
      guard let present = record else { continue }
      if case .int64(let position)? = present.encryptedFields["position"] {
        serverPositions[member.id] = Int(position)
      } else { check(false, "server has position for \(member.fileName)") }
      if case .string(let name)? = present.encryptedFields["fileName"] { serverNames[member.id] = name }
      if case .string(let type)? = present.encryptedFields["contentType"] { serverTypes[member.id] = type }
    }
    check(cell.allowedNames.contains(serverNames), "server names follow field winners or the pending exception")
    check(serverTypes == expectedTypes, "server types")
    let serverOrder = serverPositions.keys.sorted {
      if serverPositions[$0] != serverPositions[$1] { return serverPositions[$0, default: 0] < serverPositions[$1, default: 0] }
      return $0.uuidString < $1.uuidString
    }
    let serverSharedOrder = serverOrder.filter { sharedIDs.contains($0) }
    check(cell.allowedSharedOrders.contains(serverSharedOrder), "server shared order follows the winner or the pending exception")
    if let mainOrder = cell.mainFloorSharedOrder {
      check(serverSharedOrder == mainOrder, "server keeps the reorder retained by main c42d47d5")
    }
    for (id, name) in cell.mainFloorNames {
      check(serverNames[id] == name, "server keeps the rename retained by main c42d47d5")
    }
    var deviceLogs: [String] = []
    for (role, client) in [("H", clients.holder), ("D", clients.downloaded)] {
      let snapshot = try await client.library.checkedSnapshot(sortedBy: .manual)
      let snip = snapshot.snips.first(where: { $0.id == client.snipID })
      check(snip != nil, "\(role) has snip")
      let attachments = snip?.attachments ?? []
      let order = attachments.map(\.id)
      check(Set(order) == expectedIDs && order.count == expectedIDs.count, "\(role) membership")
      check(order == serverOrder, "\(role) agrees with server order")
      let sharedOrder = order.filter { sharedIDs.contains($0) }
      check(cell.allowedSharedOrders.contains(sharedOrder), "\(role) shared order follows the winner or the pending exception")
      let names = attachments.reduce(into: [UUID: String]()) { $0[$1.id] = $1.fileName }
      let contentTypes = attachments.reduce(into: [UUID: String]()) { $0[$1.id] = $1.contentType ?? "<nil>" }
      check(cell.allowedNames.contains(names), "\(role) names follow the winner or the pending exception")
      check(names == serverNames, "\(role) agrees with server names")
      check(contentTypes == expectedTypes && contentTypes == serverTypes, "\(role) types")
      if let mainOrder = cell.mainFloorSharedOrder {
        check(sharedOrder == mainOrder, "\(role) keeps the reorder retained by main c42d47d5")
      }
      for (id, name) in cell.mainFloorNames {
        check(names[id] == name, "\(role) keeps the rename retained by main c42d47d5")
      }
      let positions = try await client.library.storedAttachmentReferencePositions(for: client.snipID)
      check(Set(positions.keys) == expectedIDs, "\(role) stored membership")
      check(positions.values.sorted() == Array(0..<expectedIDs.count), "\(role) positions are a permutation")
      check(positions == serverPositions, "\(role) stored positions agree with server")
      deviceLogs.append("\(role)=\(format(order: order, positions: positions, names: names, types: contentTypes))")
    }
    for (role, client) in [("H", clients.holder), ("D", clients.downloaded)] {
      let next = try await client.store.pendingChanges()
      check(!next.operations.contains(where: { operation in
        guard case .save(let draft) = operation else { return false }
        return draft.recordType == CloudAttachmentRecordCodec.metadataRecordType
      }), "\(role) quiet after settlement")
    }
    let result = failures.isEmpty ? "PASS" : "FAIL"
    let server = format(order: serverOrder, positions: serverPositions, names: serverNames, types: serverTypes)
    return "result=\(result) server=\(server) \(deviceLogs.joined(separator: " ")) failures=\(String(reflecting: failures.joined(separator: "; ")))"
  }

  private func format(order: [UUID], positions: [UUID: Int], names: [UUID: String], types: [UUID: String]) -> String {
    let extraIDs = Set(positions.keys).union(names.keys).subtracting(order).sorted { $0.uuidString < $1.uuidString }
    let entries = (order + extraIDs).map { id in
      let member = AttachmentMatrixMember.allCases.first { $0.id == id }
      let label = member.map { String($0.fileName.prefix(1)) } ?? id.uuidString
      let position = positions[id].map(String.init) ?? "missing"
      let name = String(reflecting: names[id] ?? "<missing>")
      return "\(label):\(position):\(name):\(types[id] ?? "<missing>")"
    }
    return "[\(entries.joined(separator: ","))]"
  }
}
