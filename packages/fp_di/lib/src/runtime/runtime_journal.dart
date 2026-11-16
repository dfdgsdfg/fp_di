part of 'scope.dart';

// The release journal of an activation and of a node. It holds an effect, a
// dispose function, so it stays in `runtime/` and not in `core/`.

/// The dispose functions of the acquisitions of one activation, in
/// acquisition order.
///
/// An activation records an entry for each `acquire` call. A commit gives the
/// node a copy of the journal, so a late `acquire` of the closed activation
/// never reaches the journal of the node. A release runs the entries last
/// first (`_Runtime.runCleanups`).
///
/// The type is an extension type of the list of entries, so a journal costs
/// no object beyond that list.
extension type _RuntimeJournal._(List<DisposeFunction> _entries) {
  /// An empty journal.
  _RuntimeJournal() : this._(<DisposeFunction>[]);

  /// A journal with the entries of [other], in the same order.
  _RuntimeJournal.copyOf(_RuntimeJournal other)
    : this._(List<DisposeFunction>.of(other._entries));

  /// Adds the release of one acquisition.
  void record(DisposeFunction release) => _entries.add(release);

  /// The entries in release order: the last acquisition first.
  Iterable<DisposeFunction> get lastFirst => _entries.reversed;

  /// Removes every entry, after the release of the node ended.
  void clear() => _entries.clear();
}
