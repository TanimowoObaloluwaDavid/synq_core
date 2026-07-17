import 'package:synq_core/synq_core.dart';
import 'package:test/test.dart';

void main() {
  group('SyncEngine', () {
    test('two peers editing different parts offline converge after sync', () async {
      final peerA = SynqPeer(nodeId: 'deviceA', storage: InMemorySynqStorage());
      final peerB = SynqPeer(nodeId: 'deviceB', storage: InMemorySynqStorage());

      final createListA = peerA.document.putField(const [], 'todos', ContainerType.list);
      await peerA.recordLocal(createListA);
      final itemA = peerA.document.insertItem(const ['todos'], value: 'buy milk');
      await peerA.recordLocal(itemA);

      final createListB = peerB.document.putField(const [], 'todos', ContainerType.list);
      await peerB.recordLocal(createListB);
      final itemB = peerB.document.insertItem(const ['todos'], value: 'walk dog');
      await peerB.recordLocal(itemB);

      final delta = await SyncEngine.sync(peerA, peerB);
      expect(delta.totalOps, greaterThan(0));

      expect(peerA.document.snapshot(), peerB.document.snapshot());
      final todos = Set<Object?>.from(peerA.document.snapshot()['todos'] as List);
      expect(todos, {'buy milk', 'walk dog'});
    });

    test('conflicting field edits converge to the same winner on both peers', () async {
      final peerA = SynqPeer(nodeId: 'deviceA', storage: InMemorySynqStorage());
      final peerB = SynqPeer(nodeId: 'deviceB', storage: InMemorySynqStorage());

      final putA = peerA.document.putField(const [], 'title', 'Draft from A');
      await peerA.recordLocal(putA);
      final putB = peerB.document.putField(const [], 'title', 'Draft from B');
      await peerB.recordLocal(putB);

      await SyncEngine.sync(peerA, peerB);

      expect(peerA.document.snapshot()['title'], peerB.document.snapshot()['title']);
    });

    test('computeDelta does not mutate either peer', () async {
      final peerA = SynqPeer(nodeId: 'deviceA', storage: InMemorySynqStorage());
      final peerB = SynqPeer(nodeId: 'deviceB', storage: InMemorySynqStorage());

      final put = peerA.document.putField(const [], 'x', 1);
      await peerA.recordLocal(put);

      final delta = await SyncEngine.computeDelta(peerA, peerB);
      expect(delta.toB, hasLength(1));
      expect(delta.toA, isEmpty);
      // peer B's document is untouched until an actual sync applies the delta.
      expect(peerB.document.snapshot().containsKey('x'), isFalse);
    });

    test('a third peer syncing later picks up already-merged history from either side', () async {
      final peerA = SynqPeer(nodeId: 'deviceA', storage: InMemorySynqStorage());
      final peerB = SynqPeer(nodeId: 'deviceB', storage: InMemorySynqStorage());
      final peerC = SynqPeer(nodeId: 'deviceC', storage: InMemorySynqStorage());

      final put = peerA.document.putField(const [], 'x', 42);
      await peerA.recordLocal(put);
      await SyncEngine.sync(peerA, peerB);

      // C syncs with B only, never touches A directly.
      await SyncEngine.sync(peerB, peerC);

      expect(peerC.document.snapshot()['x'], 42);
    });

    test("hydrate() replays a peer's own persisted history into a fresh document", () async {
      final storage = InMemorySynqStorage();
      final peer = SynqPeer(nodeId: 'deviceA', storage: storage);
      final put = peer.document.putField(const [], 'name', 'Ada');
      await peer.recordLocal(put);

      // Simulate a cold start: fresh in-memory document, same durable storage.
      final rehydrated = SynqPeer(nodeId: 'deviceA', storage: storage);
      await rehydrated.hydrate();

      expect(rehydrated.document.snapshot()['name'], 'Ada');
    });
  });
}
