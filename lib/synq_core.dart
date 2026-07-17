/// synq_core: an offline-first CRDT sync engine for Flutter/Dart.
///
/// Start with [CrdtDocument] for local mutation, [SynqStorage] to persist
/// an op log, and [SyncEngine] to reconcile two peers. See the package
/// README for a worked example and the known limitations section before
/// you rely on this for anything important.
library synq_core;

export 'src/hlc.dart';
export 'src/change.dart';
export 'src/crdt_document.dart' show CrdtDocument, UnresolvedDependencyException;
export 'src/op_log.dart';
export 'src/storage.dart';
export 'src/sync_engine.dart';
