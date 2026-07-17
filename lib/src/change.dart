import 'hlc.dart';

/// The kind of mutation a [Change] represents.
enum OpType {
  /// Set a map field to a primitive value, or to a container marker
  /// ([ContainerType.map] / [ContainerType.list]) that lazily creates a
  /// nested container the first time it's seen.
  putField,

  /// Tombstone a map field. The value is hidden but the op (and any nested
  /// container reachable through it) is retained for correct merging.
  deleteField,

  /// Insert a new element into an RGA list, immediately after [Change.originId]
  /// (or at the head if null).
  insertItem,

  /// Tombstone a list element.
  deleteItem,
}

/// Marker value used as [Change.value] on a [OpType.putField] op to say
/// "this field holds a nested container", instead of a primitive.
enum ContainerType { map, list }

/// One immutable, causally-ordered mutation in the document's change log.
///
/// [path] addresses *where* the op applies, walking from the document root:
///   * String segments are map keys.
///   * [HLCTimestamp] segments are ids of list elements (needed to address
///     "inside element E of this list", e.g. for a nested map stored as a
///     list item).
///
/// For [OpType.putField]/[OpType.deleteField], the *last* path segment is
/// the field key inside the map located by the preceding segments.
/// For [OpType.insertItem]/[OpType.deleteItem], the path addresses the list
/// itself; [id] is the new element's id and [originId] is its left neighbor.
class Change {
  final HLCTimestamp id;
  final OpType type;
  final List<Object> path;
  final Object? value;
  final HLCTimestamp? originId;

  const Change({
    required this.id,
    required this.type,
    required this.path,
    this.value,
    this.originId,
  });

  Map<String, Object?> toJson() => {
        'id': id.encode(),
        'type': type.name,
        'path': path.map(_encodeSegment).toList(),
        'value': _encodeValue(value),
        'originId': originId?.encode(),
      };

  static Object _encodeSegment(Object seg) =>
      seg is HLCTimestamp ? {'\$id': seg.encode()} : seg;

  static Object? _encodeValue(Object? value) {
    if (value is ContainerType) return {'\$container': value.name};
    return value;
  }

  static Object? _decodeValue(Object? raw) {
    if (raw is Map && raw.containsKey('\$container')) {
      return ContainerType.values.byName(raw['\$container'] as String);
    }
    return raw;
  }

  factory Change.fromJson(Map<String, Object?> json) {
    final rawPath = json['path'] as List;
    final path = rawPath.map<Object>((seg) {
      if (seg is Map && seg.containsKey('\$id')) {
        return HLCTimestamp.fromString(seg['\$id'] as String);
      }
      return seg as Object;
    }).toList();

    final originRaw = json['originId'] as String?;
    return Change(
      id: HLCTimestamp.fromString(json['id'] as String),
      type: OpType.values.byName(json['type'] as String),
      path: path,
      value: _decodeValue(json['value']),
      originId: originRaw == null ? null : HLCTimestamp.fromString(originRaw),
    );
  }

  @override
  String toString() =>
      'Change(${type.name}, id: $id, path: $path, value: $value, originId: $originId)';
}
