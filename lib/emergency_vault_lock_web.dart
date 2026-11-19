import 'dart:js_interop';

@JS('navigator.locks')
external JSObject? get _locks;

extension type _Locks(JSObject object) implements JSObject {
  external JSPromise<JSAny?> request(JSString name, JSFunction callback);
}

/// Do not silently use an unsafe multi-tab read/modify/write fallback.
Future<T> withEmergencyVaultLock<T>(
  String name,
  Future<T> Function() action,
) async {
  final manager = _locks;
  if (manager == null) {
    throw UnsupportedError('Web Locks required for emergency storage');
  }
  T? result;
  Object? failure;
  StackTrace? trace;
  var ran = false;
  JSPromise<JSAny?> callback(JSAny? lock) => (() async {
    try {
      result = await action();
    } catch (e, st) {
      failure = e;
      trace = st;
    }
    ran = true;
    return null;
  })().toJS;
  await _Locks(manager).request(name.toJS, callback.toJS).toDart;
  if (!ran) throw StateError('Emergency storage lock was not acquired');
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result as T;
}
