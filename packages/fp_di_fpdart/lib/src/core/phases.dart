// Internal types. The library file does not export this file.

/// The phase of a node, as the runtime derives it from the fields of the
/// node record.
enum NodePhase {
  /// The node has a value and publishes its keys.
  active,

  /// An activation of the node runs, or a failed activation of a scope that
  /// still initializes waits for the rollback.
  activating,

  /// The release of the node runs.
  deactivating,

  /// A required key of the node does not resolve.
  waiting,

  /// The node is not active, and no narrower phase applies.
  inactive,

  /// The last automatic activation of the node failed.
  activationFailed,

  /// A dispose function of the node failed in a release that is not final.
  disposeFailed,

  /// The runtime removed the node.
  disposed,
}

/// The phase of a scope, as the runtime derives it from the fields of the
/// scope record and of its ancestors.
///
/// A scope moves from `declared` through `initializing` to `initialized`. An
/// initialization that fails returns the scope to `declared`. An accepted
/// disposal of the scope or of an ancestor moves the scope to
/// `disposeRequested`, and then through `disposing` to `disposed`. A scope
/// never leaves `disposeRequested` for an earlier phase.
enum ScopePhase {
  /// The scope exists, and no initialization started.
  declared,

  /// The initialization creates and activates the nodes.
  initializing,

  /// The initialization succeeded.
  initialized,

  /// The scope or an ancestor accepted a disposal, and the disposal waits.
  disposeRequested,

  /// The disposal releases the nodes.
  disposing,

  /// The disposal finished.
  disposed,
}
