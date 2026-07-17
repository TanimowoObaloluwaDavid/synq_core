import 'change.dart';
import 'crdt_document.dart';

/// Applies a stream of [Change]s to a [CrdtDocument], transparently handling
/// ops that arrive before their dependencies (a parent container's creation
/// op, or an RGA element's [Change.originId]) — which is the normal case in
/// real sync, since transports don't guarantee causal delivery order.
///
/// Ops that can't yet be applied are held in a pending pool and retried
/// every time a new op is successfully applied, until they succeed or the
/// buffer is told to give up on them (see [pendingCount] /
/// [unresolvedAfter]).
class ChangeBuffer {
  final CrdtDocument document;
  final List<Change> _pending = [];

  ChangeBuffer(this.document);

  int get pendingCount => _pending.length;

  /// Feeds [changes] in, applying whatever is ready and buffering the rest.
  /// Safe to call repeatedly (e.g. once per network batch); previously
  /// buffered ops are retried on every call.
  void ingest(Iterable<Change> changes) {
    _pending.addAll(changes);
    _drain();
  }

  void _drain() {
    var progressed = true;
    while (progressed && _pending.isNotEmpty) {
      progressed = false;
      for (var i = 0; i < _pending.length; i++) {
        final c = _pending[i];
        try {
          document.apply(c);
          _pending.removeAt(i);
          progressed = true;
          break; // restart the scan; indices shifted
        } on UnresolvedDependencyException {
          continue;
        }
      }
    }
  }

  /// Ops still stuck after a full drain pass — normally empty; a non-empty
  /// result after your final sync round usually means a dependency op was
  /// dropped somewhere upstream (e.g. never persisted, or filtered out).
  List<Change> get stuck => List.unmodifiable(_pending);
}
