/// A Hybrid Logical Clock timestamp: wall-clock time + logical counter +
/// node id, giving every op a globally unique, totally-ordered, causally
/// consistent identifier.
///
/// This is the foundation everything else in synq_core is built on. Plain
/// wall-clock timestamps are not safe for CRDT ordering (clock skew between
/// devices causes silent, undetectable data loss on merge); pure logical
/// clocks (Lamport) lose the "close to real time" property that makes
/// last-writer-wins merges match user intuition. HLC gives both.
class HLCTimestamp implements Comparable<HLCTimestamp> {
  final int millis;
  final int counter;
  final String nodeId;

  const HLCTimestamp(this.millis, this.counter, this.nodeId);

  factory HLCTimestamp.fromString(String encoded) {
    final parts = encoded.split(':');
    if (parts.length != 3) {
      throw FormatException('Invalid HLCTimestamp encoding: "$encoded"');
    }
    return HLCTimestamp(
      int.parse(parts[0]),
      int.parse(parts[1]),
      parts[2],
    );
  }

  String encode() => '$millis:$counter:$nodeId';

  @override
  int compareTo(HLCTimestamp other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  bool operator >(HLCTimestamp other) => compareTo(other) > 0;
  bool operator <(HLCTimestamp other) => compareTo(other) < 0;
  bool operator >=(HLCTimestamp other) => compareTo(other) >= 0;
  bool operator <=(HLCTimestamp other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HLCTimestamp &&
          millis == other.millis &&
          counter == other.counter &&
          nodeId == other.nodeId);

  @override
  int get hashCode => Object.hash(millis, counter, nodeId);

  @override
  String toString() => encode();
}

/// Generates causally-consistent [HLCTimestamp]s for one node ("device",
/// "peer", "replica" — pick your vocabulary).
///
/// Rules (Kulkarni et al., "Logical Physical Clocks"):
///  * [next] is called for every local mutation.
///  * [receive] is called whenever a timestamp arrives from a remote peer,
///    so the local clock is folded forward and never emits a timestamp that
///    could be mistaken as happening-before something it actually
///    causally follows.
class HybridLogicalClock {
  final String nodeId;
  int _lastMillis = 0;
  int _counter = 0;

  HybridLogicalClock(this.nodeId);

  HLCTimestamp next({int? wallClockMillis}) {
    final now = wallClockMillis ?? DateTime.now().millisecondsSinceEpoch;
    if (now > _lastMillis) {
      _lastMillis = now;
      _counter = 0;
    } else {
      _counter += 1;
    }
    return HLCTimestamp(_lastMillis, _counter, nodeId);
  }

  /// Folds a remote timestamp into this clock. Returns a fresh local
  /// timestamp that is guaranteed to sort after [remote].
  HLCTimestamp receive(HLCTimestamp remote, {int? wallClockMillis}) {
    final now = wallClockMillis ?? DateTime.now().millisecondsSinceEpoch;
    final newMillis = <int>[now, _lastMillis, remote.millis]
        .reduce((a, b) => a > b ? a : b);

    final int newCounter;
    if (newMillis == _lastMillis && newMillis == remote.millis) {
      newCounter = (_counter > remote.counter ? _counter : remote.counter) + 1;
    } else if (newMillis == _lastMillis) {
      newCounter = _counter + 1;
    } else if (newMillis == remote.millis) {
      newCounter = remote.counter + 1;
    } else {
      newCounter = 0;
    }

    _lastMillis = newMillis;
    _counter = newCounter;
    return HLCTimestamp(_lastMillis, _counter, nodeId);
  }
}
