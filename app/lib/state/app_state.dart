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

  List<String> databases = const [];
  List<String> schemas = const [];
  String? selectedSchema;
  List<TableInfo> tables = const [];
  bool tablesLoading = false;
  String tablesError = '';

  Engine get engine => profile.engine;
}

/// One editor tab: its text, and the results it produced.
///
/// Results belong to the tab that ran them rather than to the app, so a slow
/// query in one tab cannot overwrite what another tab is showing.
class EditorTab {
  EditorTab({required this.id, required this.title});

  final String id;
  String title;
  String sql = '';
  List<QueryResult> results = const [];
  bool running = false;
  String? runningOpId;
  String runError = '';
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

  final List<EditorTab> _tabs = [EditorTab(id: 'tab-1', title: 'Query 1')];
  int _activeTab = 0;
  int _tabSeq = 1;

  List<EditorTab> get tabs => List.unmodifiable(_tabs);
  int get activeTabIndex => _activeTab;

  /// The tab the user is looking at. Never null — closing the last tab opens
  /// a fresh one rather than leaving the editor with nothing to type into.
  EditorTab get tab => _tabs[_activeTab];

  String get sql => tab.sql;
  List<QueryResult> get results => tab.results;
  bool get running => tab.running;
  String get runError => tab.runError;

  /// How many rows a query brings back.
  ///
  /// No longer a control in the toolbar — it was a knob nobody wanted to
  /// think about before running a query. It is still a cap, because a phone
  /// cannot hold a million rows and an unbounded SELECT over mobile data is
  /// how you lose a data plan by accident. When it bites, the grid says so
  /// rather than quietly showing part of the answer.
  static const int _rowLimit = 1000;
  int get rowLimit => _rowLimit;

  void setSql(String value) {
    tab.sql = value;
    // Deliberately silent: the editor's own controller already holds the text,
    // and rebuilding the whole tree on every keystroke would make typing lag.
  }

  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _activeTab) return;
    _activeTab = index;
    notifyListeners();
  }

  /// Opens a tab, optionally pre-filled. Returns its index.
  int openTab({String? sql, String? title}) {
    _tabSeq++;
    final created = EditorTab(
      id: 'tab-$_tabSeq',
      title: title ?? 'Query $_tabSeq',
    );
    if (sql != null) created.sql = sql;
    _tabs.add(created);
    _activeTab = _tabs.length - 1;
    notifyListeners();
    return _activeTab;
  }

  void closeTab(String id) {
    final index = _tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    _tabs.removeAt(index);
    if (_tabs.isEmpty) {
      // An editor with no tabs has nowhere to type; replace rather than empty.
      _tabSeq++;
      _tabs.add(EditorTab(id: 'tab-$_tabSeq', title: 'Query $_tabSeq'));
    }
    _activeTab = _activeTab.clamp(0, _tabs.length - 1);
    notifyListeners();
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

      await refreshDatabases();
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
    // Clear results everywhere, not just the visible tab: they describe a
    // connection that no longer exists. The SQL is left alone — that is the
    // user's work, and switching database should not cost them their query.
    for (final t in _tabs) {
      t.results = const [];
      t.runError = '';
      t.running = false;
      t.runningOpId = null;
    }
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

  /// Moves the open connection to another database.
  ///
  /// Done by reconnecting rather than by issuing USE, because PostgreSQL
  /// cannot change database on a live connection at all and doing it one way
  /// on some engines and another way elsewhere is how the catalog cache ends
  /// up describing a database you are no longer in.
  ///
  /// The change is not written back to the saved connection: looking at
  /// another database is not a decision to change where this profile points.
  Future<bool> switchDatabase(String name) async {
    final connection = _active;
    if (connection == null) return false;
    if (connection.profile.database == name) return true;
    return connect(connection.profile.copyWith(database: name));
  }

  Future<void> refreshDatabases() async {
    final connection = _active;
    if (connection == null) return;
    try {
      final data = await _client.call({
        'op': 'databases',
        'sessionId': connection.sessionId,
      });
      connection.databases = ((data['databases'] as List<dynamic>?) ?? const [])
          .map((d) => '$d')
          .toList();
      notifyListeners();
    } on CoreException {
      // A login that cannot enumerate databases can still use the one it is
      // in; the picker simply does not appear.
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
  Future<({String preview, String count})> previewSql(
    TableInfo table, {
    int? limit,
  }) async {
    final connection = _active;
    if (connection == null) {
      throw CoreException('no_session', 'Not connected.');
    }
    final data = await _client.call({
      'op': 'previewSql',
      'sessionId': connection.sessionId,
      'schema': table.schema,
      'table': table.name,
      // Tapping a table opens a deliberately small window on it — 200 rows,
      // the way SSMS does — rather than the editor's row cap, which the user
      // set for queries they wrote themselves.
      'limit': limit ?? _rowLimit,
    });
    return (
      preview: data['preview'] as String? ?? '',
      count: data['count'] as String? ?? '',
    );
  }

  /// Asks the core what could follow the cursor.
  ///
  /// The logic lives in Go so it can be tested without a phone; this just
  /// carries the request. Failures are swallowed — an editor that stops
  /// accepting keystrokes because a hint could not be computed is worse than
  /// one with no hints.
  Future<({String prefix, List<Suggestion> suggestions})> complete(
    String sql,
    int cursor,
  ) async {
    final connection = _active;
    if (connection == null || sql.trim().isEmpty) {
      return (prefix: '', suggestions: const <Suggestion>[]);
    }
    try {
      final data = await _client.call({
        'op': 'complete',
        'sessionId': connection.sessionId,
        'sql': sql,
        'cursor': cursor,
      });
      return (
        prefix: data['prefix'] as String? ?? '',
        suggestions: ((data['suggestions'] as List<dynamic>?) ?? const [])
            .map((s) => Suggestion.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
    } on CoreException {
      return (prefix: '', suggestions: const <Suggestion>[]);
    }
  }

  /// The source of a stored function or procedure.
  Future<String> routineDefinition(TableInfo object) async {
    final connection = _active;
    if (connection == null) {
      throw CoreException('no_session', 'Not connected.');
    }
    final data = await _client.call({
      'op': 'routineDefinition',
      'sessionId': connection.sessionId,
      'schema': object.schema,
      'table': object.name,
      'kind': object.type,
    });
    return data['definition'] as String? ?? '';
  }

  // --- running SQL --------------------------------------------------------

  /// Runs [statement], or the active tab's contents when it is null.
  Future<void> run({String? statement}) async {
    final connection = _active;
    final target = tab;
    if (connection == null) {
      target.runError = 'Not connected.';
      notifyListeners();
      return;
    }
    final text = (statement ?? target.sql).trim();
    if (text.isEmpty) return;

    final opId =
        'op-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(9999)}';
    // The tab is captured rather than read again later: switching tabs while
    // a query is in flight must not land the results on whichever tab happens
    // to be in front when the answer arrives.
    target.running = true;
    target.runningOpId = opId;
    target.runError = '';
    target.results = const [];
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
      target.results = ((data['results'] as List<dynamic>?) ?? const [])
          .map((r) => QueryResult.fromJson(r as Map<String, dynamic>))
          .toList();

      final failed = target.results.any((r) => r.failed);
      await _history.add(HistoryEntry(
        sql: text,
        connectionName: connection.profile.name,
        ranAt: started,
        succeeded: !failed,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
        rowCount:
            target.results.isEmpty ? null : target.results.last.rows.length,
      ));
    } on CoreException catch (error) {
      target.runError = error.message;
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

    target.running = false;
    target.runningOpId = null;
    notifyListeners();
  }

  Future<void> cancel() async {
    final connection = _active;
    final opId = tab.runningOpId;
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
