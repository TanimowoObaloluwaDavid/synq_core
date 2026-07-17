import 'change.dart';

/// Pluggable persistence for a node's op log. synq_core ships an in-memory
/// implementation for tests and prototyping; back this with sqflite, Hive,
/// Drift, or a flat file for real persistence — the interface only needs
/// append + full-scan, deliberately, so any KV or SQL store works.
abstract class SynqStorage {
  Future<void> appendChange(Change change);
  Future<void> appendChanges(Iterable<Change> changes) async {
    for (final c in changes) {
      await appendChange(c);
    }
  }

  /// All changes ever recorded for this node, in the order they were
  /// appended (not necessarily causal order — that's [ChangeBuffer]'s job
  /// on the receiving side).
  Future<List<Change>> allChanges();

  /// Ids of all changes recorded, for cheap diffing during sync without
  /// deserializing full payloads.
  Future<Set<String>> allChangeIds() async {
    final all = await allChanges();
    return all.map((c) => c.id.encode()).toSet();
  }
}

class InMemorySynqStorage implements SynqStorage {
  final List<Change> _log = [];

  @override
  Future<void> appendChange(Change change) async {
    _log.add(change);
  }

  @override
  Future<void> appendChanges(Iterable<Change> changes) async {
    _log.addAll(changes);
  }

  @override
  Future<List<Change>> allChanges() async => List.unmodifiable(_log);

  @override
  Future<Set<String>> allChangeIds() async =>
      _log.map((c) => c.id.encode()).toSet();
}
