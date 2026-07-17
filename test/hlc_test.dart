import 'package:synq_core/synq_core.dart';
import 'package:test/test.dart';

void main() {
  group('HLCTimestamp', () {
    test('encodes and decodes round-trip', () {
      const t = HLCTimestamp(1000, 3, 'nodeA');
      expect(HLCTimestamp.fromString(t.encode()), t);
    });

    test('orders by millis, then counter, then nodeId', () {
      final a = HLCTimestamp(100, 0, 'a');
      final b = HLCTimestamp(100, 1, 'a');
      final c = HLCTimestamp(100, 1, 'b');
      final d = HLCTimestamp(101, 0, 'a');
      expect(a < b, isTrue);
      expect(b < c, isTrue);
      expect(c < d, isTrue);
    });
  });

  group('HybridLogicalClock', () {
    test('next() is monotonically increasing even with a frozen wall clock', () {
      final clock = HybridLogicalClock('nodeA');
      final t1 = clock.next(wallClockMillis: 1000);
      final t2 = clock.next(wallClockMillis: 1000);
      final t3 = clock.next(wallClockMillis: 1000);
      expect(t1 < t2, isTrue);
      expect(t2 < t3, isTrue);
    });

    test('receive() folds a remote timestamp forward without going backwards', () {
      final clock = HybridLogicalClock('nodeA');
      clock.next(wallClockMillis: 1000);
      final remote = HLCTimestamp(5000, 2, 'nodeB');
      final folded = clock.receive(remote, wallClockMillis: 1000);
      expect(folded > remote, isTrue);

      // A subsequent local op must still sort after the folded-in remote op,
      // even though the local wall clock hasn't caught up to 5000ms yet.
      final next = clock.next(wallClockMillis: 1000);
      expect(next > folded, isTrue);
    });

    test('receive() with a remote timestamp behind local time just advances counter', () {
      final clock = HybridLogicalClock('nodeA');
      clock.next(wallClockMillis: 5000);
      final remote = HLCTimestamp(1000, 9, 'nodeB');
      final folded = clock.receive(remote, wallClockMillis: 5000);
      expect(folded.millis, 5000);
    });
  });
}
