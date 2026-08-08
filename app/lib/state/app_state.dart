import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/native_core.dart';
import '../data/connection_store.dart';

/// A connection that is currently open, and everything the explorer has
/// learned about it so far.
class ActiveConnection {
  ActiveConnection({
    required this.sessionId,
    required this.profile,
  });

  final String sessionId;
  final ConnectionProfile profile;

  List<String> schemas = const [];
  String? selectedSchema;
  List<TableInfo> tables = const [];
  bool tablesLoading = false;
  String tablesError = '';

  Engine get engine => profile.engine;
}

/// The single source of truth the whole app reads from.
///
/// It owns the core client, the saved connections, the open session, and the
/// state of the editor. Keeping it in one place is what lets the explorer, the
/// editor, and the results grid stay in step — they are three views of the
/// same query, not three independent screens.
class AppState extends ChangeNotifier {
  AppState({
    required CoreClient client,
    required ConnectionStore connections,
    required QueryHistoryStore history,
  })  : _client = client,
        _connections = connections,
        _history = history;

  final CoreClient _client;
  final ConnectionStore _connections;
  final QueryHistoryStore _history;

  ConnectionStore get connections => _connections;
  QueryHistoryStore get history => _history;

  /// Rebuilds everything watching this state.
  ///
  /// The stores are plain objects rather than notifiers of their own, so a
  /// screen that saves or deletes a connection calls this to say the list has
  /// changed. It exists because `notifyListeners` is protected and reaching
  /// into it from a widget is the kind of thing that works until someone
  /// refactors it.
  void refresh() => notifyListeners();

  ActiveConnection? _active;
  ActiveConnection? get active => _active;
  bool get isConnected => _active != null;

  bool _connecting = false;
  bool get connecting => _connecting;

  String _connectionError = '';
  String get connectionError => _connectionError;

  // --- editor -------------------------------------------------------------

  String _sql = '';
  String get sql => _sql;

  List<QueryResult> _results = const [];
  List<QueryResult> get results => _results;

  bool _running = false;
  bool get running => _running;

  String? _runningOpId;

  String _runError = '';
  String get runError => _runError;

  int _rowLimit = 500;
  int get rowLimit => _rowLimit;
  set rowLimit(int value) {
    _rowLimit = value;
    notifyListeners();
  }

  void setSql(String value) {
    _sql = value;
    // Deliberately silent: the editor's own controller already holds the text,
    // and rebuilding the whole tree on every keystroke would make typing lag.
  }

  // --- lifecycle ----------------------------------------------------------

  Future<void> init() async {
    await Future.wait([_connections.load(), _history.load()]);
    notifyListeners();
  }

  /// Opens a saved connection.
  ///
  /// [passwordOverride] is used when the user has just typed a password into
  /// the connect prompt for a profile that has none stored.
  Future<bool> connect(
    ConnectionProfile profile, {
    String? passwordOverride,
    bool remember = false,
  }) async {
    _connecting = true;
    _connectionError = '';
    notifyListeners();

    try {
      // Only one connection is open at a time. A phone has neither the screen
      // nor the memory to make several worth the confusion of picking between
      // them mid-query.
      await disconnect();

      final password =
          passwordOverride ?? await _connections.password(profile.id);
      final data = await _client.call({
        'op': 'openConnection',
        'config': profile.toCoreConfig(password: password),
      });

      _active = ActiveConnection(
        sessionId: data['sessionId'] as String,
        profile: profile,
      );

      if (remember && passwordOverride != null && passwordOverride.isNotEmpty) {
        await _connections.save(profile, password: passwordOverride);
      }
      await _connections.touch(profile.id);

      _connecting = false;
      notifyListeners();

      await refreshSchemas();
      return true;
    } on CoreException catch (error) {
      _connectionError = error.message;
      _connecting = false;
      notifyListeners();
      return false;
    }
  }

  /// Lists the databases on a server the app is not connected to.
  ///
  /// This is what lets the connection editor offer a list instead of asking
  /// someone to recall a database name and type it exactly right on a phone
  /// keyboard — which is how you end up staring at "login failed" because of
  /// a capital letter.
  Future<({bool ok, List<String> databases, String message})> fetchDatabases(
    ConnectionProfile profile,
    String password,
  ) async {
    try {
      final data = await _client.call({
        'op': 'databasesFor',
        'config': profile.toCoreConfig(password: password),
      });
      final names = ((data['databases'] as List<dynamic>?) ?? const [])
          .map((d) => '$d')
          .toList();
      return (ok: true, databases: names, message: '');
    } on CoreException catch (error) {
      return (ok: false, databases: <String>[], message: error.message);
    }
  }

  /// Checks a connection without keeping it open, for the editor's Test button.
  Future<({bool ok, String message})> testConnection(
    ConnectionProfile profile,
    String password,
  ) async {
    try {
      final data = await _client.call({
        'op': 'testConnection',
        'config': profile.toCoreConfig(password: password),
      });
      final version = data['serverVersion'] as String? ?? '';
      return (
        ok: true,
        message: version.isEmpty ? 'Connected.' : 'Connected to $version',
      );
    } on CoreException catch (error) {
      return (ok: false, message: error.message);
    }
  }

  Future<void> disconnect() async {
    final current = _active;
    if (current == null) return;
    _active = null;
    _results = const [];
    _runError = '';
    notifyListeners();
    try {
      await _client.call({
        'op': 'closeConnection',
        'sessionId': current.sessionId,
      });
    } on CoreException {
      // The session may already be gone, which is exactly what disconnecting
      // was meant to achieve.
    }
  }

  // --- explorer -----------------------------------------------------------

  Future<void> refreshSchemas() async {
    final connection = _active;
    if (connection == null) return;
    try {
      final data = await _client.call({
        'op': 'schemas',
        'sessionId': connection.sessionId,
      });
      final schemas = ((data['schemas'] as List<dynamic>?) ?? const [])
          .map((s) => '$s')
          .toList();
      connection.schemas = schemas;
      connection.selectedSchema = _defaultSchema(connection.engine, schemas);
      notifyListeners();
      await refreshTables();
    } on CoreException catch (error) {
      connection.tablesError = error.message;
      notifyListeners();
    }
  }

  /// Picks the schema a user most likely wants to see first, so the explorer
  /// opens on something useful rather than on an alphabetical accident.
  static String? _defaultSchema(Engine engine, List<String> schemas) {
    if (schemas.isEmpty) return null;
    final preferred = switch (engine) {
      Engine.sqlserver => 'dbo',
      Engine.postgres => 'public',
      _ => null,
    };
    if (preferred != null && schemas.contains(preferred)) return preferred;
    return schemas.first;
  }

  Future<void> selectSchema(String? schema) async {
    final connection = _active;
    if (connection == null) return;
    connection.selectedSchema = schema;
    notifyListeners();
    await refreshTables();
  }

  Future<void> refreshTables() async {
    final connection = _active;
    if (connection == null) return;
    connection.tablesLoading = true;
    connection.tablesError = '';
    notifyListeners();

    try {
      final data = await _client.call({
        'op': 'tables',
        'sessionId': connection.sessionId,
        'schema': connection.selectedSchema ?? '',
      });
      connection.tables = ((data['tables'] as List<dynamic>?) ?? const [])
          .map((t) => TableInfo.fromJson(t as Map<String, dynamic>))
          .toList();
    } on CoreException catch (error) {
      connection.tablesError = error.message;
      connection.tables = const [];
    }
    connection.tablesLoading = false;
    notifyListeners();
  }

  Future<TableDetail> tableDetail(TableInfo table) async {
    final connection = _active;
    if (connection == null) {
      throw CoreException('no_session', 'Not connected.');
    }
    final data = await _client.call({
      'op': 'table',
      'sessionId': connection.sessionId,
      'schema': table.schema,
      'table': table.name,
    });
    return TableDetail.fromJson(data);
  }

  /// Asks the core for the SELECT it would run for this table, so the SQL the
  /// user sees is exactly the SQL that runs — quoting rules included.
  Future<({String preview, String count})> previewSql(TableInfo table) async {
    final connection = _active;
    if (connection == null) {
      throw CoreException('no_session', 'Not connected.');
    }
    final data = await _client.call({
      'op': 'previewSql',
      'sessionId': connection.sessionId,
      'schema': table.schema,
      'table': table.name,
      'limit': _rowLimit,
    });
    return (
      preview: data['preview'] as String? ?? '',
      count: data['count'] as String? ?? '',
    );
  }

  // --- running SQL --------------------------------------------------------

  /// Runs [statement], or the editor's contents when it is null.
  Future<void> run({String? statement}) async {
    final connection = _active;
    if (connection == null) {
      _runError = 'Not connected.';
      notifyListeners();
      return;
    }
    final text = (statement ?? _sql).trim();
    if (text.isEmpty) return;

    final opId = 'op-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(9999)}';
    _running = true;
    _runningOpId = opId;
    _runError = '';
    _results = const [];
    notifyListeners();

    final started = DateTime.now();
    try {
      final data = await _client.call({
        'op': 'execute',
        'sessionId': connection.sessionId,
        'sql': text,
        'opId': opId,
        'maxRows': _rowLimit,
        'stopOnError': true,
      });
      _results = ((data['results'] as List<dynamic>?) ?? const [])
          .map((r) => QueryResult.fromJson(r as Map<String, dynamic>))
          .toList();

      final failed = _results.any((r) => r.failed);
      await _history.add(HistoryEntry(
        sql: text,
        connectionName: connection.profile.name,
        ranAt: started,
        succeeded: !failed,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
        rowCount: _results.isEmpty ? null : _results.last.rows.length,
      ));
    } on CoreException catch (error) {
      _runError = error.message;
      if (error.isSessionLost) {
        // The socket died while the app was backgrounded. Dropping the stale
        // session here is what lets the UI offer "reconnect" instead of
        // failing every subsequent query with the same confusing message.
        _active = null;
      }
      await _history.add(HistoryEntry(
        sql: text,
        connectionName: connection.profile.name,
        ranAt: started,
        succeeded: false,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
      ));
    }

    _running = false;
    _runningOpId = null;
    notifyListeners();
  }

  Future<void> cancel() async {
    final connection = _active;
    final opId = _runningOpId;
    if (connection == null || opId == null) return;
    try {
      await _client.call({
        'op': 'cancel',
        'sessionId': connection.sessionId,
        'opId': opId,
      });
    } on CoreException {
      // Cancelling something that just finished is a race the user should
      // never see the losing side of.
    }
  }

  /// Splits the editor buffer so the UI can offer "run the statement under the
  /// cursor" and warn before a write.
  Future<List<({String text, int start, int end, String kind, bool readOnly})>>
      analyse(String text) async {
    if (text.trim().isEmpty) return const [];
    try {
      final data = await _client.call({
        'op': 'splitStatements',
        'engine': (_active?.engine ?? Engine.postgres).id,
        'sql': text,
      });
      final statements = (data['statements'] as List<dynamic>?) ?? const [];
      final kinds = (data['kinds'] as List<dynamic>?) ?? const [];
      final readOnly = (data['readOnly'] as List<dynamic>?) ?? const [];
      return [
        for (var i = 0; i < statements.length; i++)
          (
            text: statements[i]['text'] as String? ?? '',
            start: statements[i]['start'] as int? ?? 0,
            end: statements[i]['end'] as int? ?? 0,
            kind: i < kinds.length ? '${kinds[i]}' : 'other',
            readOnly: i < readOnly.length && readOnly[i] == true,
          ),
      ];
    } on CoreException {
      return const [];
    }
  }

  @override
  void dispose() {
    unawaited(_client.dispose());
    super.dispose();
  }
}
