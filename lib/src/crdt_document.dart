import 'change.dart';
import 'hlc.dart';

/// Thrown by [CrdtDocument.apply] when a [Change] can't be applied yet
/// because a dependency (its parent container, or its RGA [Change.originId])
/// hasn't been applied. Callers normally don't see this directly — use
/// [ChangeBuffer] (see op_log.dart), which catches it and retries
/// automatically once the dependency arrives.
class UnresolvedDependencyException implements Exception {
  final Change change;
  final String reason;
  UnresolvedDependencyException(this.change, this.reason);
  @override
  String toString() => 'UnresolvedDependencyException: $reason ($change)';
}

/// One field inside a [_MapNode]: last-writer-wins by [id].
class _FieldMeta {
  HLCTimestamp id;
  bool tombstone;
  Object? primitiveValue; // meaningful only when the field is not a container
  ContainerType? containerType; // non-null once ever set to a container

  _FieldMeta({
    required this.id,
    required this.tombstone,
    this.containerType,
  });
}

/// A last-writer-wins map. Field keys map to either a primitive value or a
/// nested container ([_MapNode] / [_ListNode]).
///
/// Design note: once a field is ever set to a container, the child node
/// object is created once and kept alive for the field's lifetime — even if
/// a later write "shadows" it with a primitive, or a delete tombstones it.
/// This keeps op application replay-order-independent: an op targeting a
/// path through that container can arrive before or after the op that
/// (re)wins the LWW race for the field itself, and both converge to the same
/// state either way. The tradeoff (a known, documented simplification vs.
/// e.g. Automerge's full object-identity model) is that concurrently
/// creating *two different container types* at the same key resolves to
/// "first container created locally wins the slot", not a merge of both.
class _MapNode {
  final Map<String, _FieldMeta> _fields = {};
  final Map<String, Object> _children = {}; // String key -> _MapNode|_ListNode

  void applyPutField(Change c, String key) {
    final existing = _fields[key];
    if (existing != null && existing.id >= c.id) return; // already superseded

    final meta = existing ??
        _FieldMeta(id: c.id, tombstone: false); // placeholder, id set below
    meta.id = c.id;
    meta.tombstone = false;

    if (c.value is ContainerType) {
      final type = c.value as ContainerType;
      meta.containerType = type;
      _children.putIfAbsent(key, () => type == ContainerType.map ? _MapNode() : _ListNode());
    } else {
      meta.containerType = null;
      meta.primitiveValue = c.value;
    }
    _fields[key] = meta;
  }

  void applyDeleteField(Change c, String key) {
    final existing = _fields[key];
    if (existing != null && existing.id >= c.id) return;
    final meta = existing ?? _FieldMeta(id: c.id, tombstone: true);
    meta.id = c.id;
    meta.tombstone = true;
    _fields[key] = meta;
  }

  /// Resolves (creating if necessary) the child container at [key], used
  /// when a deeper op in [path] needs to reach through this field.
  /// [expected] documents which container type the caller is about to
  /// address; a lazily-created child defaults to that type if none exists
  /// yet, which lets nested ops arrive before (or without ever needing) an
  /// explicit putField that "officially" marks the field as a container.
  ///
  /// [triggeredBy] is the id of the op causing this resolution. If [key]
  /// has never been written before, we register a field-meta entry for it
  /// right here — otherwise a list/map that's only ever addressed via
  /// insertItem/putField-on-a-child (no top-level putField for the
  /// container itself) would hold real data but be invisible to
  /// [snapshot], since snapshot only walks [_fields].
  Object _resolveChild(String key, ContainerType expected, HLCTimestamp triggeredBy) {
    final existing = _children[key];
    if (existing != null) {
      _fields.putIfAbsent(
        key,
        () => _FieldMeta(id: triggeredBy, tombstone: false, containerType: expected),
      );
      return existing;
    }
    final created = expected == ContainerType.map ? _MapNode() : _ListNode();
    _children[key] = created;
    _fields.putIfAbsent(
      key,
      () => _FieldMeta(id: triggeredBy, tombstone: false, containerType: expected),
    );
    return created;
  }

  /// Snapshot to a plain Dart JSON-ish value (Map/List/primitive), skipping
  /// tombstoned fields.
  Map<String, Object?> snapshot() {
    final out = <String, Object?>{};
    for (final entry in _fields.entries) {
      final meta = entry.value;
      if (meta.tombstone) continue;
      if (meta.containerType != null) {
        final child = _children[entry.key];
        out[entry.key] = child == null
            ? null
            : (child is _MapNode ? child.snapshot() : (child as _ListNode).snapshot());
      } else {
        out[entry.key] = meta.primitiveValue;
      }
    }
    return out;
  }
}

class _RgaElement {
  final HLCTimestamp id;
  final HLCTimestamp? originId;
  bool tombstone;
  Object? primitiveValue;
  ContainerType? containerType;

  _RgaElement({
    required this.id,
    required this.originId,
    required this.tombstone,
  });
}

/// A Replicated Growable Array: a CRDT for ordered, insertable-anywhere
/// lists (the hard part most "simple" sync layers skip, because naive
/// index-based lists corrupt under concurrent inserts/deletes).
///
/// Each element carries its own id and a pointer to the element it was
/// inserted after ([originId]). Concurrent inserts at the same origin are
/// ordered deterministically by comparing ids (higher id sorts closer to the
/// origin), so every replica converges on the same sequence regardless of
/// delivery order — this is the classic Roh et al. RGA algorithm.
class _ListNode {
  final List<_RgaElement> _sequence = [];
  final Map<String, _MapNode> _mapChildren = {}; // keyed by element id.encode()
  final Map<String, _ListNode> _listChildren = {};

  int _indexOf(HLCTimestamp id) => _sequence.indexWhere((e) => e.id == id);

  void applyInsert(Change c) {
    if (_indexOf(c.id) != -1) return; // idempotent: already applied

    final originIdx = c.originId == null ? -1 : _indexOf(c.originId!);
    if (c.originId != null && originIdx == -1) {
      throw UnresolvedDependencyException(
        c,
        'origin element ${c.originId} not yet present in this list',
      );
    }

    var pos = originIdx + 1;
    while (pos < _sequence.length) {
      final candidate = _sequence[pos];
      final candidateOriginIdx =
          candidate.originId == null ? -1 : _indexOf(candidate.originId!);
      // Once we hit an element whose origin is not this same insertion
      // point (i.e. it wasn't also inserted directly after `originId`),
      // it's not competing for this slot — stop scanning.
      if (candidateOriginIdx < originIdx) break;
      if (candidate.id > c.id) {
        pos += 1;
      } else {
        break;
      }
    }

    final el = _RgaElement(id: c.id, originId: c.originId, tombstone: false);
    if (c.value is ContainerType) {
      el.containerType = c.value as ContainerType;
    } else {
      el.primitiveValue = c.value;
    }
    _sequence.insert(pos, el);
  }

  void applyDelete(Change c, HLCTimestamp elementId) {
    final idx = _indexOf(elementId);
    if (idx == -1) {
      throw UnresolvedDependencyException(
        c,
        'target element $elementId not yet present in this list',
      );
    }
    _sequence[idx].tombstone = true;
  }

  /// Resolves (creating if necessary) the nested container living "inside"
  /// list element [elementId]. Callers must have already verified the
  /// element exists (see [_indexOf] checks at call sites).
  ///
  /// If the element was inserted with a primitive value and has never been
  /// addressed as a container before, this promotes it to one — mirroring
  /// [_MapNode]'s equivalent lazy-upgrade behavior, so `snapshot()` picks up
  /// nested data reached only through a later op rather than showing the
  /// stale primitive the element started life as.
  Object _resolveChild(HLCTimestamp elementId, ContainerType expected) {
    final idx = _indexOf(elementId);
    if (idx == -1) {
      throw ArgumentError('_resolveChild called for unknown element $elementId');
    }
    final el = _sequence[idx];
    el.containerType ??= expected;

    final key = elementId.encode();
    if (expected == ContainerType.map) {
      return _mapChildren.putIfAbsent(key, () => _MapNode());
    }
    return _listChildren.putIfAbsent(key, () => _ListNode());
  }

  List<Object?> snapshot() {
    final out = <Object?>[];
    for (final el in _sequence) {
      if (el.tombstone) continue;
      if (el.containerType != null) {
        final key = el.id.encode();
        final child = el.containerType == ContainerType.map
            ? _mapChildren[key]
            : _listChildren[key];
        out.add(child == null
            ? null
            : (child is _MapNode ? child.snapshot() : (child as _ListNode).snapshot()));
      } else {
        out.add(el.primitiveValue);
      }
    }
    return out;
  }
}

/// A single offline-first, mergeable document: the public API surface of
/// synq_core's data model.
///
/// Internally the whole document is a tree of [_MapNode] / [_ListNode]
/// containers, mutated exclusively by applying [Change] ops (never
/// in-place), which is what makes it mergeable: two replicas that have
/// applied the same *set* of ops converge to the same state no matter what
/// order they arrived in (strong eventual consistency).
class CrdtDocument {
  final _MapNode _root = _MapNode();
  final HybridLogicalClock clock;
  final Set<String> _appliedIds = {};

  CrdtDocument(String nodeId) : clock = HybridLogicalClock(nodeId);

  // ---- Local mutation API: each call generates and applies one Change ----

  Change putField(List<Object> mapPath, String key, Object? value) {
    final c = Change(id: clock.next(), type: OpType.putField, path: [...mapPath, key], value: value);
    apply(c);
    return c;
  }

  Change deleteField(List<Object> mapPath, String key) {
    final c = Change(id: clock.next(), type: OpType.deleteField, path: [...mapPath, key]);
    apply(c);
    return c;
  }

  Change insertItem(List<Object> listPath, {HLCTimestamp? after, Object? value}) {
    final c = Change(
      id: clock.next(),
      type: OpType.insertItem,
      path: listPath,
      value: value,
      originId: after,
    );
    apply(c);
    return c;
  }

  Change deleteItem(List<Object> listPath, HLCTimestamp elementId) {
    final c = Change(
      id: clock.next(),
      type: OpType.deleteItem,
      path: [...listPath, elementId],
    );
    apply(c);
    return c;
  }

  // ---- Applying ops (local or remote) ----

  bool get isEmpty => _appliedIds.isEmpty;
  bool hasApplied(HLCTimestamp id) => _appliedIds.contains(id.encode());

  /// Applies [c]. Idempotent — applying the same op twice is a no-op.
  /// Throws [UnresolvedDependencyException] if a container or RGA origin
  /// this op depends on hasn't been applied yet; use [ChangeBuffer] to
  /// handle out-of-order delivery automatically.
  void apply(Change c) {
    if (_appliedIds.contains(c.id.encode())) return;

    // Fold the op's timestamp into our clock so subsequent local ops are
    // guaranteed to causally follow it, per HLC discipline.
    if (c.id.nodeId != clock.nodeId) {
      clock.receive(c.id);
    }

    switch (c.type) {
      case OpType.putField:
      case OpType.deleteField:
        _applyMapOp(c);
        break;
      case OpType.insertItem:
        _applyListInsert(c);
        break;
      case OpType.deleteItem:
        _applyListDelete(c);
        break;
    }
    _appliedIds.add(c.id.encode());
  }

  void _applyMapOp(Change c) {
    if (c.path.isEmpty) {
      throw ArgumentError('putField/deleteField requires a non-empty path');
    }
    final container = _resolveMapContainer(c.path.sublist(0, c.path.length - 1), c);
    final key = c.path.last as String;
    if (c.type == OpType.putField) {
      container.applyPutField(c, key);
    } else {
      container.applyDeleteField(c, key);
    }
  }

  void _applyListInsert(Change c) {
    final container = _resolveListContainer(c.path, c);
    container.applyInsert(c);
  }

  void _applyListDelete(Change c) {
    if (c.path.isEmpty) {
      throw ArgumentError('deleteItem requires path ending in the element id');
    }
    final elementId = c.path.last as HLCTimestamp;
    final container = _resolveListContainer(c.path.sublist(0, c.path.length - 1), c);
    container.applyDelete(c, elementId);
  }

  /// Walks [path] from the root, resolving/creating nested containers as it
  /// goes. Throws [UnresolvedDependencyException] if a segment addresses a
  /// list element that hasn't been inserted yet (can't create a
  /// placeholder — we don't know its ordering).
  _MapNode _resolveMapContainer(List<Object> path, Change forOp) {
    Object current = _root;
    for (var i = 0; i < path.length; i++) {
      final seg = path[i];
      final nextIsMap = i + 1 < path.length ? path[i + 1] is String : true;
      if (seg is String) {
        if (current is! _MapNode) {
          throw UnresolvedDependencyException(forOp, 'expected a map container at segment $i');
        }
        current = current._resolveChild(
          seg,
          nextIsMap ? ContainerType.map : ContainerType.list,
          forOp.id,
        );
      } else if (seg is HLCTimestamp) {
        if (current is! _ListNode) {
          throw UnresolvedDependencyException(forOp, 'expected a list container at segment $i');
        }
        if (current._indexOf(seg) == -1) {
          throw UnresolvedDependencyException(forOp, 'list element $seg not yet present');
        }
        current = current._resolveChild(
          seg,
          nextIsMap ? ContainerType.map : ContainerType.list,
        );
      }
    }
    if (current is! _MapNode) {
      throw UnresolvedDependencyException(forOp, 'path did not resolve to a map container');
    }
    return current;
  }

  _ListNode _resolveListContainer(List<Object> path, Change forOp) {
    if (path.isEmpty) {
      throw ArgumentError('list ops require a non-empty path to the list');
    }
    final parentPath = path.sublist(0, path.length - 1);
    final lastKey = path.last;
    final parent = _resolveMapContainer(parentPath, forOp);
    if (lastKey is! String) {
      throw ArgumentError('the final path segment addressing a list must be a map key');
    }
    final child = parent._resolveChild(lastKey, ContainerType.list, forOp.id);
    if (child is! _ListNode) {
      throw UnresolvedDependencyException(forOp, 'expected a list container at "$lastKey"');
    }
    return child;
  }

  /// Full-document snapshot as plain Dart Maps/Lists/primitives — handy for
  /// rendering in a widget tree or serializing to JSON for display.
  Map<String, Object?> snapshot() => _root.snapshot();
}
