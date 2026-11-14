// The test seam of the DevTools inspector (specs/tooling/devtools,
// "Registration"). Not exported from any public library.
//
// The inspector registers its service extensions and posts its events only
// through [RuntimeInspectorHooks]. The defaults call `dart:developer`. A test
// sets a recorder before it creates a root, and then calls the recorded
// handlers.
// The runtime reads [RuntimeInspectorHooks] only inside an `assert`, so a build
// without assertions never reaches it.

import 'dart:convert';
import 'dart:developer' as developer;

/// The handler of one service extension. It answers a JSON object.
typedef InspectorHandler =
    Future<Map<String, Object?>> Function(
      String method,
      Map<String, String> parameters,
    );

/// Registers [handler] under the service extension name [method].
typedef ExtensionRegistrar =
    void Function(String method, InspectorHandler handler);

/// Posts the event [kind] with the JSON object [data].
typedef EventPoster = void Function(String kind, Map<String, Object?> data);

/// The switches that the inspector reads, and the state that belongs to one
/// isolate.
abstract final class RuntimeInspectorHooks {
  /// Registers a service extension. The default calls `registerExtension` of
  /// `dart:developer` and encodes the answer as JSON.
  static ExtensionRegistrar registerExtension = _registerExtension;

  /// Posts an event. The default calls `postEvent` of `dart:developer`.
  static EventPoster postEvent = _postEvent;

  /// Whether the service extensions are registered in this isolate. A name
  /// can be registered one time, so the inspector registers when this is
  /// false.
  static bool registered = false;

  /// The inspector of this isolate, or null before the first root. The
  /// runtime library owns the value and its type.
  static Object? state;

  /// Sets every hook to its default and forgets the inspector, so a test
  /// starts again. Tests only; with the real `registerExtension` a second
  /// registration of a name fails.
  static void reset() {
    registerExtension = _registerExtension;
    postEvent = _postEvent;
    registered = false;
    state = null;
  }

  static void _registerExtension(String method, InspectorHandler handler) {
    developer.registerExtension(method, (name, parameters) async {
      try {
        return developer.ServiceExtensionResponse.result(
          jsonEncode(await handler(name, parameters)),
        );
      } on Object catch (error) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'fp_di inspector failed: ${error.runtimeType}',
        );
      }
    });
  }

  static void _postEvent(String kind, Map<String, Object?> data) {
    developer.postEvent(kind, data);
  }
}
