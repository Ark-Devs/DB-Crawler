import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Raw bindings to the Go core.
///
/// Three symbols, all taking and returning C strings. Keeping the surface this
/// narrow is deliberate: every extra exported function is another struct
/// layout to keep in step between Go and Dart, and a mismatch there is a
/// memory bug rather than a compile error.
typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);
typedef _ShutdownNative = Void Function();
typedef _Shutdown = void Function();

class NativeCore {
  NativeCore._(this._call, this._free, this._shutdown);

  final _CallNative _call;
  final _Free _free;
  final _Shutdown _shutdown;

  static NativeCore? _instance;

  /// Loads the shared library for the current platform.
  ///
  /// On iOS the core is statically linked into the app binary, so the process
  /// itself is the library; on Android it is a real .so shipped in jniLibs.
  static NativeCore load() {
    final existing = _instance;
    if (existing != null) return existing;

    final library = Platform.isIOS || Platform.isMacOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open('libdbcrawler.so');

    final core = NativeCore._(
      library.lookupFunction<_CallNative, _CallNative>('dbcrawler_call'),
      library.lookupFunction<_FreeNative, _Free>('dbcrawler_free'),
      library.lookupFunction<_ShutdownNative, _Shutdown>('dbcrawler_shutdown'),
    );
    _instance = core;
    return core;
  }

  /// Sends one request and returns the decoded response.
  ///
  /// This blocks the calling thread for as long as the database takes to
  /// answer, which is why it is only ever called on a background isolate —
  /// see [CoreClient]. Calling it directly from the UI isolate would freeze
  /// the interface for the duration of every query.
  Map<String, dynamic> callSync(Map<String, dynamic> request) {
    final encoded = jsonEncode(request).toNativeUtf8();
    Pointer<Utf8>? response;
    try {
      response = _call(encoded);
      if (response == nullptr) {
        return {
          'ok': false,
          'error': {'code': 'internal', 'message': 'the core returned nothing'},
        };
      }
      // The bytes have to be copied out before the pointer is freed, which is
      // what toDartString does.
      return jsonDecode(response.toDartString()) as Map<String, dynamic>;
    } finally {
      calloc.free(encoded);
      // Go allocated this with C.CString, so only the Go side can release it.
      // Freeing it here with the Dart allocator would corrupt the heap.
      if (response != null && response != nullptr) {
        _free(response);
      }
    }
  }

  void shutdown() => _shutdown();
}

/// A failure returned by the core, carrying the code the UI branches on.
class CoreException implements Exception {
  CoreException(this.code, this.message);

  final String code;
  final String message;

  /// True when the connection has gone and the app should offer to reopen it
  /// rather than showing a dead end. This is the normal case after the OS has
  /// suspended the app long enough for its sockets to be dropped.
  bool get isSessionLost => code == 'no_session';
  bool get isReadOnly => code == 'read_only';
  bool get isCancelled => code == 'cancelled';

  @override
  String toString() => message;
}

/// Runs core calls on a background isolate.
///
/// A database query on a mobile network can take seconds. Running it on the UI
/// isolate would drop every frame for that whole time — no spinner, no back
/// button, nothing. The isolate keeps the interface responsive and, just as
/// importantly, keeps the cancel button working while a query is in flight.
class CoreClient {
  CoreClient._(this._commands, this._responses, this._exit);

  final SendPort _commands;
  final ReceivePort _responses;
  final ReceivePort _exit;

  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 0;
  bool _closed = false;

  static Future<CoreClient> start() async {
    final responses = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();

    late final CoreClient client;

    responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      client._complete(message as Map<String, dynamic>);
    });

    await Isolate.spawn(
      _isolateMain,
      responses.sendPort,
      onExit: exit.sendPort,
      debugName: 'db-crawler-core',
    );

    final commands = await ready.future;
    client = CoreClient._(commands, responses, exit);

    // If the isolate dies — an unrecoverable core panic, or the OS killing it —
    // every request waiting on it must fail rather than hang forever behind a
    // spinner that will never stop.
    exit.listen((_) => client._failAll('the database core stopped'));

    return client;
  }

  /// Sends a request and returns its `data` payload, throwing [CoreException]
  /// when the core reports a failure.
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    if (_closed) {
      throw CoreException('internal', 'the database core is shut down');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _commands.send({'__id': id, 'request': request});

    final response = await completer.future;
    if (response['ok'] != true) {
      final error = response['error'] as Map<String, dynamic>?;
      throw CoreException(
        error?['code'] as String? ?? 'internal',
        error?['message'] as String? ?? 'the request failed',
      );
    }
    return (response['data'] as Map<String, dynamic>?) ?? const {};
  }

  /// Like [call], for the operations whose payload is a list.
  Future<List<dynamic>> callList(Map<String, dynamic> request, String key) async {
    final data = await call(request);
    return (data[key] as List<dynamic>?) ?? const [];
  }

  void _complete(Map<String, dynamic> message) {
    final id = message['__id'] as int;
    _pending.remove(id)?.complete(message['response'] as Map<String, dynamic>);
  }

  void _failAll(String message) {
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(CoreException('internal', message));
      }
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _commands.send({'__shutdown': true});
    _failAll('the database core is shut down');
    _responses.close();
    _exit.close();
  }

  /// The isolate body: load the library once, then answer requests forever.
  static void _isolateMain(SendPort responses) {
    final commands = ReceivePort();
    responses.send(commands.sendPort);

    final core = NativeCore.load();

    commands.listen((message) {
      final envelope = message as Map<String, dynamic>;
      if (envelope['__shutdown'] == true) {
        core.shutdown();
        commands.close();
        return;
      }
      final id = envelope['__id'] as int;
      final request = envelope['request'] as Map<String, dynamic>;

      Map<String, dynamic> response;
      try {
        response = core.callSync(request);
      } catch (error) {
        // A failure to even reach the core still has to come back as a
        // response, or the caller waits on a future that never completes.
        response = {
          'ok': false,
          'error': {'code': 'internal', 'message': '$error'},
        };
      }
      responses.send({'__id': id, 'response': response});
    });
  }
}
