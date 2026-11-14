import 'dart:async';

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';

import 'client.dart';
import 'model.dart';

// This file is the only one that imports `devtools_extensions`, which needs
// the web libraries. The tests run on the Dart VM and never import it.

/// The client over the `serviceManager` of `devtools_extensions`.
///
/// Only code below the `DevToolsExtension` widget can create it, because the
/// `serviceManager` global exists there.
final class ServiceManagerClient implements InspectorClient {
  ServiceManagerClient() {
    final manager = serviceManager;
    _connected.value = manager.connectedState.value.connected;
    manager.connectedState.addListener(_onConnectionChange);
    manager.isolateManager.mainIsolate.addListener(_onMainIsolateChange);
    _onConnectionChange();
  }

  final ValueNotifier<bool> _connected = ValueNotifier<bool>(false);
  final StreamController<RawEvent> _events =
      StreamController<RawEvent>.broadcast();
  final StreamController<void> _restarts = StreamController<void>.broadcast();
  final List<StreamSubscription<Event>> _subscriptions = [];
  VmService? _service;
  IsolateRef? _lastIsolate;

  @override
  ValueListenable<bool> get connected => _connected;

  @override
  Stream<RawEvent> get events => _events.stream;

  @override
  Stream<void> get restarts => _restarts.stream;

  void _onConnectionChange() {
    final manager = serviceManager;
    _connected.value = manager.connectedState.value.connected;
    final service = manager.service;
    if (identical(service, _service)) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _service = service;
    if (service == null) return;
    // The service manager already listens to the `Extension` and `Isolate`
    // streams, so the app only subscribes to the broadcast streams.
    _subscriptions
      ..add(service.onExtensionEvent.listen(_onExtensionEvent))
      ..add(service.onIsolateEvent.listen(_onIsolateEvent));
  }

  void _onMainIsolateChange() {
    final isolate = serviceManager.isolateManager.mainIsolate.value;
    if (isolate == null) return;
    final restarted = _lastIsolate != null && isolate.id != _lastIsolate!.id;
    _lastIsolate = isolate;
    if (restarted) _restarts.add(null);
  }

  void _onExtensionEvent(Event event) {
    final kind = event.extensionKind;
    final data = event.extensionData?.data;
    if (kind == null || data == null) return;
    if (kind != EventKinds.transition &&
        kind != EventKinds.error &&
        kind != EventKinds.slowMutation) {
      return;
    }
    _events.add((kind: kind, data: Map<String, Object?>.from(data)));
  }

  void _onIsolateEvent(Event event) {
    if (event.kind == EventKind.kServiceExtensionAdded &&
        event.extensionRPC == 'ext.fp_di.listen') {
      _restarts.add(null);
    }
  }

  @override
  Future<Map<String, Object?>> query(
    String method, [
    Map<String, String> args = const {},
  ]) async {
    final response = await serviceManager.callServiceExtensionOnMainIsolate(
      method,
      args: args,
    );
    return Map<String, Object?>.from(response.json ?? const {});
  }

  @override
  void dispose() {
    final manager = serviceManager;
    manager.connectedState.removeListener(_onConnectionChange);
    manager.isolateManager.mainIsolate.removeListener(_onMainIsolateChange);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_events.close());
    unawaited(_restarts.close());
    _connected.dispose();
  }
}
