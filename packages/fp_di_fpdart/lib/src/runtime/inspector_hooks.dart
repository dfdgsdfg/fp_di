// The test seam of the DevTools inspector. The library file does not export
// this file.
//
// The inspector registers its service extensions and posts its events only
// through [InspectorHooks]. The defaults call `dart:developer`. A test sets a
// recorder before it creates a root, and then calls the recorded handlers.
// The runtime reads [InspectorHooks] only inside an `assert`, so a build
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
abstract final class InspectorHooks {
  /// Registers a service extension. The default calls `registerExtension` of
  /// `dart:developer` and encodes the answer as JSON.
  ///
  /// The default throws an `ArgumentError` when the isolate holds the name
  /// already, for example when the app also loads `fp_di`. The inspector
  /// catches the error and leaves the name to the first owner.
  static ExtensionRegistrar registerExtension = _registerExtension;

  /// Posts an event. The default calls `postEvent` of `dart:developer`.
  static EventPoster postEvent = _postEvent;

  /// Whether the inspector tried to register its service extensions in this
  /// isolate. A name can be registered one time, so the inspector tries once.
  static bool registered = false;

  /// The names that this copy of the inspector registered. A name that
  /// another owner held is not in the list.
  static final List<String> owned = <String>[];

  /// The names that the isolate held already, so this copy skipped them.
  static final List<String> skipped = <String>[];

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
    owned.clear();
    skipped.clear();
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
          'fp_di_fpdart inspector failed: ${error.runtimeType}',
        );
      }
    });
  }

  static void _postEvent(String kind, Map<String, Object?> data) {
    developer.postEvent(kind, data);
  }
}
