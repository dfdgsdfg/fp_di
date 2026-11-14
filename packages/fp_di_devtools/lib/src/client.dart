import 'dart:async';

import 'package:flutter/foundation.dart';

import 'model.dart';

/// A raw event of the inspector: the `extensionKind` and the JSON data.
typedef RawEvent = ({String kind, Map<String, Object?> data});

/// The connection between the extension app and the inspector of the app.
abstract interface class InspectorClient {
  /// Whether a debugged app is connected.
  ValueListenable<bool> get connected;

  /// The events of the inspector, for the kinds of [EventKinds] only.
  Stream<RawEvent> get events;

  /// Fires when the inspector can have started again: the app restarted, or
  /// the isolate registered the service extensions. The listener calls
  /// `listen` again and reloads.
  Stream<void> get restarts;

  /// Calls the service extension [method], such as `ext.fp_di.state`, with
  /// [args], and returns the JSON answer.
  Future<Map<String, Object?>> query(
    String method, [
    Map<String, String> args = const {},
  ]);

  /// Releases the subscriptions.
  void dispose();
}
