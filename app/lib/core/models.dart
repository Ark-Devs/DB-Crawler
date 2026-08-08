import 'dart:convert';

/// The database products the core can talk to.
enum Engine {
  sqlserver('sqlserver', 'SQL Server / Azure SQL', 1433, usesSchemas: true),
  postgres('postgres', 'PostgreSQL', 5432, usesSchemas: true),
  mysql('mysql', 'MySQL / MariaDB', 3306),
  sqlite('sqlite', 'SQLite', 0, usesFile: true);

  const Engine(
    this.id,
    this.label,
    this.defaultPort, {
    this.usesFile = false,
    this.usesSchemas = false,
  });

  final String id;
  final String label;
  final int defaultPort;
  final bool usesFile;
  final bool usesSchemas;

  static Engine fromId(String id) =>
      Engine.values.firstWhere((e) => e.id == id, orElse: () => Engine.postgres);
}

/// How a connection negotiates TLS.
enum TlsMode {
  disable('disable', 'Off', 'No encryption. Only for a database on this device.'),
  prefer('prefer', 'Prefer', 'Encrypt when the server offers it.'),
  require('require', 'Require', 'Always encrypt. Do not check the certificate.'),
  verify('verify', 'Verify', 'Always encrypt and verify the certificate.');

  const TlsMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static TlsMode fromId(String? id) =>
      TlsMode.values.firstWhere((m) => m.id == id, orElse: () => TlsMode.require);
}

/// How SQL Server verifies who you are.
///
/// Made explicit because the driver otherwise infers it from the shape of the
/// username, and an inferred choice is invisible: someone who cannot log in
/// has no way to tell which method was even attempted.
enum AuthMethod {
  sql(
    'sql',
    'SQL Server',
    'A login the database server itself holds. This is what you want unless '
        'your organisation says otherwise.',
  ),
  windows(
    'windows',
    'Windows',
    'A domain account over NTLM. The username must include the domain, as '
        'DOMAIN\\username.',
  );

  const AuthMethod(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static AuthMethod fromId(String? id) =>
      AuthMethod.values.firstWhere((a) => a.id == id,
          orElse: () => AuthMethod.sql);
}

/// A saved connection.
///
/// The password is deliberately absent. It lives in the platform keystore
/// keyed by [id] and is only ever fetched at the moment of connecting, so the
/// file this class serialises into can never leak one — not through a backup,
/// not through a bug report, not through a shared screenshot of app data.
class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.engine,
    this.host = '',
    this.port,
    this.database = '',
    this.user = '',
    this.file = '',
    this.auth = AuthMethod.sql,
    this.tls = TlsMode.require,
    this.readOnly = false,
    this.connectTimeoutSeconds = 15,
    this.params = const {},
    this.rawDsn = '',
    this.colorTag,
    this.lastUsed,
  });

  final String id;
  final String name;
  final Engine engine;
  final String host;
  final int? port;
  final String database;
  final String user;
  final String file;

  /// SQL Server only; the other engines have a single scheme.
  final AuthMethod auth;

  final TlsMode tls;

  /// Blocks anything that is not a read. Worth turning on for production, and
  /// the app suggests it whenever a profile is named like one.
  final bool readOnly;

  final int connectTimeoutSeconds;
  final Map<String, String> params;
  final String rawDsn;

  /// A colour the user assigns so production does not look like staging at a
  /// glance. Mixing those up is the mistake this app makes easiest.
  final int? colorTag;

  final DateTime? lastUsed;

  int get effectivePort => port ?? engine.defaultPort;

  /// A one-line summary for the connection list.
  String get subtitle {
    if (engine == Engine.sqlite) {
      final name = file.split('/').last;
      return name.isEmpty ? 'No file chosen' : name;
    }
    final target = '$host:$effectivePort';
    return database.isEmpty ? target : '$target/$database';
  }

  ConnectionProfile copyWith({
    String? name,
    Engine? engine,
    String? host,
    int? port,
    bool clearPort = false,
    String? database,
    String? user,
    String? file,
    AuthMethod? auth,
    TlsMode? tls,
    bool? readOnly,
    int? connectTimeoutSeconds,
    Map<String, String>? params,
    String? rawDsn,
    int? colorTag,
    bool clearColorTag = false,
    DateTime? lastUsed,
  }) {
    return ConnectionProfile(
      id: id,
      name: name ?? this.name,
      engine: engine ?? this.engine,
      host: host ?? this.host,
      port: clearPort ? null : (port ?? this.port),
      database: database ?? this.database,
      user: user ?? this.user,
      file: file ?? this.file,
      auth: auth ?? this.auth,
      tls: tls ?? this.tls,
      readOnly: readOnly ?? this.readOnly,
      connectTimeoutSeconds: connectTimeoutSeconds ?? this.connectTimeoutSeconds,
      params: params ?? this.params,
      rawDsn: rawDsn ?? this.rawDsn,
      colorTag: clearColorTag ? null : (colorTag ?? this.colorTag),
      lastUsed: lastUsed ?? this.lastUsed,
    );
  }

  /// The shape the Go core expects. [password] is passed in rather than held
  /// on the object so it exists in memory only for the duration of a connect.
  Map<String, dynamic> toCoreConfig({String password = ''}) => {
        'engine': engine.id,
        if (host.isNotEmpty) 'host': host,
        if (port != null) 'port': port,
        if (database.isNotEmpty) 'database': database,
        if (user.isNotEmpty) 'user': user,
        if (password.isNotEmpty) 'password': password,
        if (file.isNotEmpty) 'file': file,
        if (engine == Engine.sqlserver) 'auth': auth.id,
        'tls': tls.id,
        'connectTimeoutSeconds': connectTimeoutSeconds,
        'readOnly': readOnly,
        if (params.isNotEmpty) 'params': params,
        if (rawDsn.isNotEmpty) 'rawDsn': rawDsn,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'engine': engine.id,
        'host': host,
        if (port != null) 'port': port,
        'database': database,
        'user': user,
        'file': file,
        'auth': auth.id,
        'tls': tls.id,
        'readOnly': readOnly,
        'connectTimeoutSeconds': connectTimeoutSeconds,
        'params': params,
        'rawDsn': rawDsn,
        if (colorTag != null) 'colorTag': colorTag,
        if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ConnectionProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled',
      engine: Engine.fromId(json['engine'] as String? ?? 'postgres'),
      host: json['host'] as String? ?? '',
      port: json['port'] as int?,
      database: json['database'] as String? ?? '',
      user: json['user'] as String? ?? '',
      file: json['file'] as String? ?? '',
      auth: AuthMethod.fromId(json['auth'] as String?),
      tls: TlsMode.fromId(json['tls'] as String?),
      readOnly: json['readOnly'] as bool? ?? false,
      connectTimeoutSeconds: json['connectTimeoutSeconds'] as int? ?? 15,
      params: (json['params'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, '$v')) ??
          const {},
      rawDsn: json['rawDsn'] as String? ?? '',
      colorTag: json['colorTag'] as int?,
      lastUsed: json['lastUsed'] == null
          ? null
          : DateTime.tryParse(json['lastUsed'] as String),
    );
  }
}

/// How a column should be rendered and aligned.
enum ValueKind {
  string,
  number,
  boolean,
  datetime,
  date,
  time,
  bytes,
  json,
  uuid,
  unknown;

  static ValueKind fromId(String? id) {
    switch (id) {
      case 'number':
        return ValueKind.number;
      case 'bool':
        return ValueKind.boolean;
      case 'datetime':
        return ValueKind.datetime;
      case 'date':
        return ValueKind.date;
      case 'time':
        return ValueKind.time;
      case 'bytes':
        return ValueKind.bytes;
      case 'json':
        return ValueKind.json;
      case 'uuid':
        return ValueKind.uuid;
      case 'string':
        return ValueKind.string;
      default:
        return ValueKind.unknown;
    }
  }

  /// Numbers read far more easily right-aligned in a grid, because the digits
  /// line up by place value.
  bool get isNumeric => this == ValueKind.number;
}

class ColumnMeta {
  const ColumnMeta({
    required this.name,
    required this.kind,
    this.dbType = '',
    this.nullable,
  });

  final String name;
  final ValueKind kind;
  final String dbType;
  final bool? nullable;

  factory ColumnMeta.fromJson(Map<String, dynamic> json) => ColumnMeta(
        name: json['name'] as String? ?? '',
        kind: ValueKind.fromId(json['kind'] as String?),
        dbType: json['dbType'] as String? ?? '',
        nullable: json['nullable'] as bool?,
      );
}

/// What one statement produced.
class QueryResult {
  const QueryResult({
    required this.kind,
    required this.statement,
    required this.statementClass,
    this.columns = const [],
    this.rows = const [],
    this.truncated = false,
    this.rowsAffected,
    this.lastInsertId,
    this.elapsedMs = 0,
    this.error = '',
  });

  final String kind;
  final String statement;
  final String statementClass;
  final List<ColumnMeta> columns;

  /// A null entry is SQL NULL; an empty string is an empty string. Keeping
  /// those distinct all the way to the screen is the whole reason values
  /// arrive as nullable strings rather than as a rendered display value.
  final List<List<String?>> rows;

  final bool truncated;
  final int? rowsAffected;
  final int? lastInsertId;
  final int elapsedMs;
  final String error;

  bool get failed => error.isNotEmpty;
  bool get hasRows => kind == 'rows' && !failed;

  factory QueryResult.fromJson(Map<String, dynamic> json) => QueryResult(
        kind: json['kind'] as String? ?? 'rows',
        statement: json['statement'] as String? ?? '',
        statementClass: json['class'] as String? ?? 'other',
        columns: ((json['columns'] as List<dynamic>?) ?? const [])
            .map((c) => ColumnMeta.fromJson(c as Map<String, dynamic>))
            .toList(growable: false),
        rows: ((json['rows'] as List<dynamic>?) ?? const [])
            .map((row) => (row as List<dynamic>)
                .map((cell) => cell as String?)
                .toList(growable: false))
            .toList(growable: false),
        truncated: json['truncated'] as bool? ?? false,
        rowsAffected: json['rowsAffected'] as int?,
        lastInsertId: json['lastInsertId'] as int?,
        elapsedMs: json['elapsedMs'] as int? ?? 0,
        error: json['error'] as String? ?? '',
      );

  /// A one-line summary for the status bar under the editor.
  String get summary {
    if (failed) return error;
    if (kind == 'affected') {
      final n = rowsAffected;
      if (n == null) return 'Done in ${elapsedMs}ms';
      return '$n ${n == 1 ? 'row' : 'rows'} affected in ${elapsedMs}ms';
    }
    final count = rows.length;
    final suffix = truncated ? ' (capped)' : '';
    return '$count ${count == 1 ? 'row' : 'rows'}$suffix in ${elapsedMs}ms';
  }

  /// Renders the result as CSV, quoting per RFC 4180.
  ///
  /// NULL is written as an unquoted empty field and an empty string as a
  /// quoted one, which is the only way a spreadsheet can tell them apart.
  String toCsv() {
    final buffer = StringBuffer();
    buffer.writeln(columns.map((c) => _csvField(c.name)).join(','));
    for (final row in rows) {
      buffer.writeln(row.map((v) => v == null ? '' : _csvField(v)).join(','));
    }
    return buffer.toString();
  }

  static String _csvField(String value) {
    final needsQuotes = value.contains(RegExp(r'[",\r\n]'));
    final escaped = value.replaceAll('"', '""');
    return needsQuotes || value.isEmpty ? '"$escaped"' : escaped;
  }

  /// Renders the result as JSON, re-typing from the column kinds so numbers
  /// come out as numbers rather than as quoted strings.
  String toJsonText() {
    final out = rows.map((row) {
      final map = <String, dynamic>{};
      for (var i = 0; i < columns.length && i < row.length; i++) {
        final raw = row[i];
        map[columns[i].name] = switch (columns[i].kind) {
          _ when raw == null => null,
          ValueKind.number => _asNumber(raw),
          ValueKind.boolean => raw == 'true',
          _ => raw,
        };
      }
      return map;
    }).toList();
    return const JsonEncoder.withIndent('  ').convert(out);
  }

  /// Converts a numeric cell to a JSON number, but only when that is lossless.
  ///
  /// A DECIMAL(19,4) does not fit in an IEEE 754 double. Parsing one into a
  /// Dart `num` to make the export "properly typed" would round it, which is
  /// the exact silent corruption that made the core send values as strings in
  /// the first place — reintroduced one layer higher, where it is harder to
  /// notice.
  ///
  /// So a value is only emitted as a number when the double round-trips back
  /// to the same digits. Anything wider stays a quoted string: an exact total
  /// a consumer has to parse beats a convenient one that is wrong.
  static Object _asNumber(String raw) {
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;

    final asDouble = double.tryParse(raw);
    if (asDouble != null &&
        _normaliseDecimal(asDouble.toString()) == _normaliseDecimal(raw)) {
      return asDouble;
    }
    return raw;
  }

  /// Strips trailing fractional zeros so that 250.5000 and 250.5 compare
  /// equal — a difference in stored scale is not a difference in value.
  static String _normaliseDecimal(String value) {
    if (!value.contains('.')) return value;
    var out = value.replaceFirst(RegExp(r'0+$'), '');
    if (out.endsWith('.')) out = out.substring(0, out.length - 1);
    return out;
  }
}

class TableInfo {
  const TableInfo({
    required this.name,
    required this.type,
    this.schema = '',
    this.rowEstimate,
    this.comment = '',
  });

  final String name;
  final String type;
  final String schema;
  final int? rowEstimate;
  final String comment;

  bool get isView => type.contains('view');
  String get qualified => schema.isEmpty ? name : '$schema.$name';

  factory TableInfo.fromJson(Map<String, dynamic> json) => TableInfo(
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? 'table',
        schema: json['schema'] as String? ?? '',
        rowEstimate: json['rowEstimate'] as int?,
        comment: json['comment'] as String? ?? '',
      );
}

class ColumnDetail {
  const ColumnDetail({
    required this.name,
    required this.dataType,
    required this.nullable,
    this.isPrimaryKey = false,
    this.isAutoIncrement = false,
    this.defaultValue,
    this.comment = '',
  });

  final String name;
  final String dataType;
  final bool nullable;
  final bool isPrimaryKey;
  final bool isAutoIncrement;
  final String? defaultValue;
  final String comment;

  factory ColumnDetail.fromJson(Map<String, dynamic> json) => ColumnDetail(
        name: json['name'] as String? ?? '',
        dataType: json['dataType'] as String? ?? '',
        nullable: json['nullable'] as bool? ?? true,
        isPrimaryKey: json['isPrimaryKey'] as bool? ?? false,
        isAutoIncrement: json['isAutoIncrement'] as bool? ?? false,
        defaultValue: json['default'] as String?,
        comment: json['comment'] as String? ?? '',
      );
}

class IndexDetail {
  const IndexDetail({
    required this.name,
    required this.columns,
    this.unique = false,
    this.primary = false,
  });

  final String name;
  final List<String> columns;
  final bool unique;
  final bool primary;

  factory IndexDetail.fromJson(Map<String, dynamic> json) => IndexDetail(
        name: json['name'] as String? ?? '',
        columns: ((json['columns'] as List<dynamic>?) ?? const [])
            .map((c) => '$c')
            .toList(growable: false),
        unique: json['unique'] as bool? ?? false,
        primary: json['primary'] as bool? ?? false,
      );
}

class ForeignKeyDetail {
  const ForeignKeyDetail({
    required this.name,
    required this.columns,
    required this.refTable,
    required this.refColumns,
    this.refSchema = '',
  });

  final String name;
  final List<String> columns;
  final String refTable;
  final List<String> refColumns;
  final String refSchema;

  factory ForeignKeyDetail.fromJson(Map<String, dynamic> json) => ForeignKeyDetail(
        name: json['name'] as String? ?? '',
        columns: ((json['columns'] as List<dynamic>?) ?? const [])
            .map((c) => '$c')
            .toList(growable: false),
        refTable: json['refTable'] as String? ?? '',
        refColumns: ((json['refColumns'] as List<dynamic>?) ?? const [])
            .map((c) => '$c')
            .toList(growable: false),
        refSchema: json['refSchema'] as String? ?? '',
      );
}

class TableDetail {
  const TableDetail({
    required this.name,
    this.schema = '',
    this.columns = const [],
    this.indexes = const [],
    this.foreignKeys = const [],
    this.ddl = '',
  });

  final String name;
  final String schema;
  final List<ColumnDetail> columns;
  final List<IndexDetail> indexes;
  final List<ForeignKeyDetail> foreignKeys;
  final String ddl;

  factory TableDetail.fromJson(Map<String, dynamic> json) => TableDetail(
        name: json['name'] as String? ?? '',
        schema: json['schema'] as String? ?? '',
        columns: ((json['columns'] as List<dynamic>?) ?? const [])
            .map((c) => ColumnDetail.fromJson(c as Map<String, dynamic>))
            .toList(growable: false),
        indexes: ((json['indexes'] as List<dynamic>?) ?? const [])
            .map((i) => IndexDetail.fromJson(i as Map<String, dynamic>))
            .toList(growable: false),
        foreignKeys: ((json['foreignKeys'] as List<dynamic>?) ?? const [])
            .map((f) => ForeignKeyDetail.fromJson(f as Map<String, dynamic>))
            .toList(growable: false),
        ddl: json['ddl'] as String? ?? '',
      );
}

/// One entry in the query history.
class HistoryEntry {
  const HistoryEntry({
    required this.sql,
    required this.connectionName,
    required this.ranAt,
    this.succeeded = true,
    this.elapsedMs = 0,
    this.rowCount,
  });

  final String sql;
  final String connectionName;
  final DateTime ranAt;
  final bool succeeded;
  final int elapsedMs;
  final int? rowCount;

  Map<String, dynamic> toJson() => {
        'sql': sql,
        'connectionName': connectionName,
        'ranAt': ranAt.toIso8601String(),
        'succeeded': succeeded,
        'elapsedMs': elapsedMs,
        if (rowCount != null) 'rowCount': rowCount,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        sql: json['sql'] as String? ?? '',
        connectionName: json['connectionName'] as String? ?? '',
        ranAt: DateTime.tryParse(json['ranAt'] as String? ?? '') ?? DateTime.now(),
        succeeded: json['succeeded'] as bool? ?? true,
        elapsedMs: json['elapsedMs'] as int? ?? 0,
        rowCount: json['rowCount'] as int?,
      );
}
