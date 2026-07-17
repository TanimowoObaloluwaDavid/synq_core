# synq_core

[![pub package](https://img.shields.io/pub/v/synq_core.svg)](https://pub.dev/packages/synq_core)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![pub points](https://img.shields.io/pub/points/synq_core)](https://pub.dev/packages/synq_core/score)

An offline-first **CRDT sync engine** for Flutter and Dart. Merges data at
the field and list-element level — not the whole-record level — so
concurrent edits from multiple devices converge correctly without a server
picking a winner and silently discarding the other one.

Pure Dart, zero third-party dependencies. Works identically in a Flutter
app, a Dart CLI tool, or a server.

> **Note:** this package documents its limitations honestly below —
> please read the [Known Limitations](#known-limitations) section before
> depending on it for anything important.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Features](#features)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Core concepts](#core-concepts)
- [Using it in a Flutter widget](#using-it-in-a-flutter-widget)
- [Nested documents and lists](#nested-documents-and-lists)
- [Wiring persistence and a transport](#wiring-persistence-and-a-transport)
- [API overview](#api-overview)
- [Testing](#testing)
- [Known limitations](#known-limitations)
- [When to reach for something else](#when-to-reach-for-something-else)
- [Contributing](#contributing)
- [License](#license)

---

## Why this exists

Most "offline sync" packages merge at the **record** level: two devices
edit the same object, and one write wins while the other is silently
discarded. That's fine right up until two people edit **different fields
of the same record** while offline — the common case in any collaborative
app, not the edge case — and one edit clobbers the other anyway, because
the merge granularity is too coarse to tell the edits apart.

`synq_core` merges at the **field and list-element** level instead:

- Concurrent edits to different fields of the same document never conflict.
- Concurrent inserts into the same list (two people adding todo items
  offline, say) both survive, landing in a deterministic order every
  device agrees on — no central sequence counter, no server round-trip.
- Only genuinely concurrent writes to the *same* field fall back to
  last-writer-wins, and that resolution is deterministic and commutative:
  every replica converges on the same value no matter what order the ops
  arrive in.

## Features

- 🕰️ **Hybrid Logical Clocks** — causally-ordered, clock-skew-safe timestamps for every operation
- 🗂️ **Nested LWW-maps** — arbitrarily deep JSON-like documents with per-field conflict resolution
- 📋 **RGA lists** — a real Replicated Growable Array, so concurrent inserts/deletes in shared lists converge correctly
- 🧩 **Causal op buffering** — ops delivered out of order are held and auto-retried, not dropped
- 💾 **Storage-agnostic** — bring your own persistence (sqflite, Hive, Drift, a flat file)
- 🔌 **Transport-agnostic** — bring your own network layer (REST, WebSocket, Bluetooth, sneakernet)
- 📦 **Zero dependencies** — pure Dart, nothing to conflict with your existing deps

## Installation

```bash
dart pub add synq_core
```

or, in a Flutter project:

```bash
flutter pub add synq_core
```

This adds a line like the following to your `pubspec.yaml` (pub does this
for you automatically):

```yaml
dependencies:
  synq_core: ^0.1.0
```

Then:

```bash
dart pub get
```

## Quick start

```dart
import 'package:synq_core/synq_core.dart';

void main() async {
  final peerA = SynqPeer(nodeId: 'deviceA', storage: InMemorySynqStorage());
  final peerB = SynqPeer(nodeId: 'deviceB', storage: InMemorySynqStorage());

  // Both edit offline, no coordination, no network.
  final createList = peerA.document.putField([], 'todos', ContainerType.list);
  await peerA.recordLocal(createList);
  final item = peerA.document.insertItem(['todos'], value: 'buy milk');
  await peerA.recordLocal(item);

  final title = peerB.document.putField([], 'title', 'Groceries');
  await peerB.recordLocal(title);

  // Later, when they're back online:
  await SyncEngine.sync(peerA, peerB);

  print(peerA.document.snapshot());
  // {title: Groceries, todos: [buy milk]}
  print(peerB.document.snapshot());
  // identical — both peers converged
}
```

## Core concepts

| Concept | What it does |
|---|---|
| `HLCTimestamp` / `HybridLogicalClock` | Every op gets a timestamp that's both causally ordered and close to wall-clock time — safer than raw timestamps (clock skew can't reorder causality) and more intuitive than pure Lamport clocks. |
| `Change` | One immutable, replayable mutation (`putField`, `deleteField`, `insertItem`, `deleteItem`). This is the unit of sync. |
| `CrdtDocument` | The mergeable data structure: a tree of LWW-maps and RGA-lists. Mutate it locally, or feed it remote `Change`s — same code path either way. |
| `ChangeBuffer` | Holds ops that arrived before their dependency (a parent container, or an RGA insert's left-neighbor) and retries them automatically. Real transports don't guarantee causal delivery order; this is what makes that safe. |
| `SynqStorage` | Your persistence adapter — an append-only op log. Bring your own. |
| `SyncEngine` / `SynqPeer` | Computes the op-id-set difference between two peers and applies it bidirectionally. |

## Using it in a Flutter widget

```dart
class TodosView extends StatefulWidget {
  final SynqPeer peer;
  const TodosView({required this.peer, super.key});

  @override
  State<TodosView> createState() => _TodosViewState();
}

class _TodosViewState extends State<TodosView> {
  Future<void> _addTodo(String text) async {
    final change = widget.peer.document.insertItem(['todos'], value: text);
    await widget.peer.recordLocal(change);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final todos = (widget.peer.document.snapshot()['todos'] as List?) ?? [];
    return ListView(
      children: [for (final t in todos) ListTile(title: Text('$t'))],
    );
  }
}
```

For real apps, wrap `CrdtDocument.snapshot()` in a `ValueNotifier`, a
`ChangeNotifier`, or your state-management tool of choice, and
notify listeners after every mutation. `synq_core` deliberately doesn't
impose a state-management opinion.

## Nested documents and lists

Documents can nest maps and lists arbitrarily deep:

```dart
final doc = CrdtDocument('deviceA');

doc.putField([], 'profile', ContainerType.map);
doc.putField(['profile'], 'name', 'Ada');
doc.putField(['profile'], 'age', 30);

doc.putField([], 'todos', ContainerType.list);
final first = doc.insertItem(['todos'], value: 'buy milk');
doc.insertItem(['todos'], after: first.id, value: 'walk dog');

print(doc.snapshot());
// {profile: {name: Ada, age: 30}, todos: [buy milk, walk dog]}
```

Deleting a field or list item just tombstones it — the op history is
retained so merges stay correct:

```dart
doc.deleteField([], 'profile');
doc.deleteItem(['todos'], first.id);
```

## Wiring persistence and a transport

```dart
class SqfliteSynqStorage implements SynqStorage {
  final Database db;
  SqfliteSynqStorage(this.db);

  @override
  Future<void> appendChange(Change change) async {
    await db.insert('ops', {
      'id': change.id.encode(),
      'json': jsonEncode(change.toJson()),
    });
  }

  @override
  Future<void> appendChanges(Iterable<Change> changes) async {
    final batch = db.batch();
    for (final c in changes) {
      batch.insert('ops', {'id': c.id.encode(), 'json': jsonEncode(c.toJson())});
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<Change>> allChanges() async {
    final rows = await db.query('ops', orderBy: 'rowid');
    return rows.map((r) => Change.fromJson(jsonDecode(r['json'] as String))).toList();
  }
}
```

For the network side, `SyncEngine.computeDelta` gives you the exact set of
`Change`s to send/receive — serialize each with `Change.toJson()`, ship
them over whatever transport you like, and feed the received ones into a
`ChangeBuffer` on the other end via `document.apply()` or `SynqPeer`.

## API overview

```
synq_core
├── HLCTimestamp, HybridLogicalClock   // causal timestamps
├── Change, OpType, ContainerType      // the unit of mutation/sync
├── CrdtDocument                       // put/delete fields, insert/delete list items, snapshot()
├── UnresolvedDependencyException      // thrown by apply() when a dependency is missing
├── ChangeBuffer                       // auto-retries out-of-order ops
├── SynqStorage, InMemorySynqStorage   // pluggable persistence
├── SynqPeer                           // document + storage + buffer, bundled
└── SyncEngine, SyncDelta              // computeDelta() / sync() between two peers
```

Full API docs are generated automatically on the
[pub.dev documentation tab](https://pub.dev/documentation/synq_core/latest/)
once published.

## Testing

```bash
dart pub get
dart analyze
dart test
```

The `test/` directory covers HLC ordering, LWW field conflicts, RGA
ordering (including concurrent-insert tie-breaking), out-of-order delivery
via `ChangeBuffer`, and full bidirectional `SyncEngine` convergence.

## Known limitations

Being direct about these, because a list of caveats is more useful to you
than a confident claim:

1. **No performance testing at scale.** `_ListNode` uses linear scans for
   RGA operations — fine for hundreds of items, likely too slow for tens
   of thousands without an id→index cache. Op history isn't compacted;
   a real deployment needs a garbage-collection strategy once ops are
   acknowledged by every peer.
2. **Concurrent container-type races are simplified.** If two peers
   concurrently set the same field to a map on one side and a list on the
   other, whichever container is created first locally wins the slot —
   it's not a true merge of both.
3. **No encryption, auth, or transport included.** This is a merge
   engine, not a sync service — you provide the network layer and any
   security around it.
4. **No conflict-notification hook yet.** LWW resolution happens
   silently; surfacing "field X was changed on two devices, B's edit won"
   to a user currently means diffing snapshots yourself.
5. **Single-document scope.** Each `CrdtDocument` is one mergeable tree.
   For multiple logical documents (a todo list *and* a user profile), use
   one `CrdtDocument`/`SynqPeer` per document rather than one shared tree.

## When to reach for something else

If your data model is "independent records that different devices rarely
edit concurrently" (each user only edits their own rows, say), a simpler
vector-clock + whole-record-LWW package is less to reason about and may be
all you need. Reach for `synq_core` specifically when concurrent,
fine-grained edits to shared documents or lists are a real scenario in
your app.

## Contributing

Issues and PRs welcome once the repository is public. Please include a
failing test alongside any bug report — the CRDT logic is subtle enough
that a reproducible test case is far more useful than a description.

## License

MIT — see [LICENSE](LICENSE).
