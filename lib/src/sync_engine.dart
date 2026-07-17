import 'change.dart';
import 'crdt_document.dart';
import 'op_log.dart';
import 'storage.dart';

/// One replica: a document, its durable op log, and the buffer that
/// resolves out-of-order deliveries. This is the unit you sync between
/// peers.
class SynqPeer {
  final String nodeId;
  final CrdtDocument document;
  final SynqStorage storage;
  late final ChangeBuffer _buffer;

  SynqPeer({required this.nodeId, required this.storage})
      : document = CrdtDocument(nodeId) {
    _buffer = ChangeBuffer(document);
  }

  /// Call once at startup to replay this peer's own persisted history back
  /// into the (fresh, in-memory) document.
  Future<void> hydrate() async {
    final all = await storage.allChanges();
    _buffer.ingest(all);
  }

  /// Applies a locally-generated [change] (already applied to [document] by
  /// the CrdtDocument mutation methods) and persists it.
  Future<void> recordLocal(Change change) => storage.appendChange(change);
}

/// Computes and applies deltas between two [SynqPeer]s.
///
/// This models a direct (e.g. LAN, Bluetooth, or through-a-relay) sync
/// round. For client/server sync, run this same logic with the server's
/// storage standing in as "peer B" — the algorithm is symmetric.
class SyncEngine {
  /// Ops peer B has that peer A doesn't, and vice versa. Pure computation,
  /// no mutation — useful for e.g. showing "3 changes to send, 5 to
  /// receive" in a UI before committing to a transfer over a metered
  /// connection.
  static Future<SyncDelta> computeDelta(SynqPeer a, SynqPeer b) async {
    final aIds = await a.storage.allChangeIds();
    final bIds = await b.storage.allChangeIds();
    final aChanges = await a.storage.allChanges();
    final bChanges = await b.storage.allChanges();

    final toSendToB = aChanges.where((c) => !bIds.contains(c.id.encode())).toList();
    final toSendToA = bChanges.where((c) => !aIds.contains(c.id.encode())).toList();
    return SyncDelta(toA: toSendToA, toB: toSendToB);
  }

  /// Full bidirectional sync: computes the delta, applies missing ops to
  /// each peer's document (via [ChangeBuffer], so delivery order doesn't
  /// matter), and persists them to each peer's storage.
  static Future<SyncDelta> sync(SynqPeer a, SynqPeer b) async {
    final delta = await computeDelta(a, b);

    if (delta.toA.isNotEmpty) {
      a._buffer.ingest(delta.toA);
      await a.storage.appendChanges(delta.toA);
    }
    if (delta.toB.isNotEmpty) {
      b._buffer.ingest(delta.toB);
      await b.storage.appendChanges(delta.toB);
    }
    return delta;
  }
}

class SyncDelta {
  final List<Change> toA;
  final List<Change> toB;
  const SyncDelta({required this.toA, required this.toB});

  int get totalOps => toA.length + toB.length;
}
