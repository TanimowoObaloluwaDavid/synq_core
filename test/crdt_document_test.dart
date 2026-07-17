import 'package:synq_core/synq_core.dart';
import 'package:test/test.dart';

void main() {
  group('LWW map fields', () {
    test('concurrent writes converge to the higher-id write regardless of application order', () {
      final idA = HLCTimestamp(1000, 0, 'A');
      final idB = HLCTimestamp(1000, 0, 'B'); // same millis/counter, 'B' > 'A' as tiebreak
      final cA = Change(id: idA, type: OpType.putField, path: const ['status'], value: 'from A');
      final cB = Change(id: idB, type: OpType.putField, path: const ['status'], value: 'from B');

      final doc1 = CrdtDocument('replica1')
        ..apply(cA)
        ..apply(cB);
      final doc2 = CrdtDocument('replica2')
        ..apply(cB)
        ..apply(cA);

      expect(doc1.snapshot()['status'], 'from B');
      expect(doc2.snapshot()['status'], 'from B');
    });

    test('delete beats an earlier write, write beats an earlier delete', () {
      final doc = CrdtDocument('A');
      final put = doc.putField(const [], 'name', 'Alice');
      expect(doc.snapshot()['name'], 'Alice');

      doc.deleteField(const [], 'name');
      expect(doc.snapshot().containsKey('name'), isFalse);

      // A write with a lower id than the delete must NOT resurrect the field.
      final staleWrite = Change(
        id: HLCTimestamp(put.id.millis, put.id.counter, put.id.nodeId), // same as original put
        type: OpType.putField,
        path: const ['name'],
        value: 'Stale',
      );
      doc.apply(staleWrite);
      expect(doc.snapshot().containsKey('name'), isFalse);
    });
  });

  group('nested maps', () {
    test('putField with ContainerType.map creates an addressable nested map', () {
      final doc = CrdtDocument('A');
      doc.putField(const [], 'profile', ContainerType.map);
      doc.putField(const ['profile'], 'age', 30);
      doc.putField(const ['profile'], 'name', 'Ada');

      expect(doc.snapshot(), {
        'profile': {'age': 30, 'name': 'Ada'},
      });
    });

    test('nested containers work without an explicit parent putField (lazy creation)', () {
      // Regression test: a container reached only through a nested op must
      // still show up in snapshot(), not just exist invisibly in memory.
      final doc = CrdtDocument('A');
      doc.putField(const [], 'todos', ContainerType.list);
      final item = doc.insertItem(const ['todos'], value: 'first');
      doc.putField(['todos', item.id], 'label', 'urgent');

      expect(doc.snapshot()['todos'], [
        {'label': 'urgent'}
      ]);
    });
  });

  group('RGA lists', () {
    test('sequential inserts preserve order', () {
      final doc = CrdtDocument('A');
      doc.putField(const [], 'todos', ContainerType.list);
      final a = doc.insertItem(const ['todos'], value: 'a');
      final b = doc.insertItem(const ['todos'], after: a.id, value: 'nope'); // will delete this one
      doc.deleteItem(const ['todos'], b.id);
      doc.insertItem(const ['todos'], after: b.id, value: 'c');

      expect(doc.snapshot()['todos'], ['a', 'c']);
    });

    test('concurrent inserts at the same origin order deterministically by id (RGA tie-break)', () {
      final doc = CrdtDocument('A');
      doc.putField(const [], 'todos', ContainerType.list);
      final a = doc.insertItem(const ['todos'], value: 'a');
      doc.insertItem(const ['todos'], after: a.id, value: 'b');
      doc.insertItem(const ['todos'], after: a.id, value: 'c'); // later id, same origin as b

      // 'c' has a higher id than 'b' and both were inserted directly after
      // 'a', so 'c' sorts closer to the origin: a, c, b.
      expect(doc.snapshot()['todos'], ['a', 'c', 'b']);
    });

    test('two independent head-inserts converge to the same order on both replicas', () {
      final left = HLCTimestamp(1000, 0, 'left');
      final right = HLCTimestamp(1000, 0, 'right'); // right > left, tie-broken by nodeId

      final createList = Change(
        id: HLCTimestamp(500, 0, 'left'),
        type: OpType.putField,
        path: const ['todos'],
        value: ContainerType.list,
      );
      final insertLeft = Change(id: left, type: OpType.insertItem, path: const ['todos'], value: 'L');
      final insertRight = Change(id: right, type: OpType.insertItem, path: const ['todos'], value: 'R');

      final docA = CrdtDocument('replicaA')
        ..apply(createList)
        ..apply(insertLeft)
        ..apply(insertRight);
      final docB = CrdtDocument('replicaB')
        ..apply(createList)
        ..apply(insertRight)
        ..apply(insertLeft);

      expect(docA.snapshot()['todos'], docB.snapshot()['todos']);
      expect(docA.snapshot()['todos'], ['R', 'L']); // higher id ('right') wins the head position
    });

    test('deleteItem tombstones without disturbing surrounding order', () {
      final doc = CrdtDocument('A');
      doc.putField(const [], 'todos', ContainerType.list);
      final a = doc.insertItem(const ['todos'], value: 'a');
      doc.insertItem(const ['todos'], after: a.id, value: 'b');
      doc.deleteItem(const ['todos'], a.id);

      expect(doc.snapshot()['todos'], ['b']);
    });
  });

  group('out-of-order delivery', () {
    test('apply() throws UnresolvedDependencyException for a missing RGA origin', () {
      final doc = CrdtDocument('B');
      final c = Change(
        id: HLCTimestamp(2000, 0, 'A'),
        type: OpType.insertItem,
        path: const ['todos'],
        value: 'x',
        originId: HLCTimestamp(1000, 0, 'A'), // never applied
      );
      expect(() => doc.apply(c), throwsA(isA<UnresolvedDependencyException>()));
    });

    test('ChangeBuffer resolves ops delivered out of causal order', () {
      final source = CrdtDocument('A');
      final a = source.insertItem(const ['todos'], value: 'a');
      final b = source.insertItem(const ['todos'], after: a.id, value: 'b');

      final target = CrdtDocument('B');
      final buffer = ChangeBuffer(target);
      buffer.ingest([b, a]); // dependency (a) arrives after its dependent (b)

      expect(buffer.pendingCount, 0);
      expect(target.snapshot()['todos'], ['a', 'b']);
    });

    test('apply() is idempotent under duplicate delivery', () {
      final doc = CrdtDocument('A');
      final a = doc.insertItem(const ['todos'], value: 'a');
      doc.apply(a); // re-apply the same op
      doc.apply(a);
      expect(doc.snapshot()['todos'], ['a']);
    });
  });
}
