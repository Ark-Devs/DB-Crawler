import 'dart:convert';

import 'package:db_crawler/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConnectionProfile', () {
    test('never serialises a password', () {
      const profile = ConnectionProfile(
        id: '1',
        name: 'Production',
        engine: Engine.sqlserver,
        host: 'db.example.com',
        database: 'SQ_Inventory',
        user: 'sa',
      );
      // The whole point of the store's split is that this file cannot leak a
      // credential. If a password field ever appears here, it can.
      final encoded = jsonEncode(profile.toJson());
      expect(encoded.contains('password'), isFalse);
    });

    test('round-trips through JSON', () {
      final original = ConnectionProfile(
        id: '42',
        name: 'Staging',
        engine: Engine.postgres,
        host: 'pg.internal',
        port: 6543,
        database: 'shop',
        user: 'reader',
        tls: TlsMode.verify,
        readOnly: true,
        colorTag: 0xFFFFB224,
        lastUsed: DateTime.utc(2026, 8, 8, 12),
      );
      final restored =
          ConnectionProfile.fromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.engine, Engine.postgres);
      expect(restored.port, 6543);
      expect(restored.tls, TlsMode.verify);
      expect(restored.readOnly, isTrue);
      expect(restored.colorTag, 0xFFFFB224);
      expect(restored.lastUsed, original.lastUsed);
    });

    test('a password is only sent to the core when one is supplied', () {
      const profile = ConnectionProfile(
        id: '1',
        name: 'X',
        engine: Engine.mysql,
        host: 'h',
        user: 'u',
      );
      expect(profile.toCoreConfig().containsKey('password'), isFalse);
      expect(profile.toCoreConfig(password: 'pw')['password'], 'pw');
    });

    test('falls back to the engine default port', () {
      const profile = ConnectionProfile(
        id: '1',
        name: 'X',
        engine: Engine.sqlserver,
        host: 'h',
        user: 'u',
      );
      expect(profile.effectivePort, 1433);
      expect(profile.subtitle, 'h:1433');
    });

    test('an unknown engine in a saved file does not crash the load', () {
      final restored = ConnectionProfile.fromJson({
        'id': '1',
        'name': 'From a newer version',
        'engine': 'oracle',
      });
      expect(restored.engine, Engine.postgres);
    });
  });

  group('QueryResult', () {
    QueryResult build() => QueryResult.fromJson({
          'kind': 'rows',
          'statement': 'SELECT * FROM orders',
          'class': 'select',
          'columns': [
            {'name': 'id', 'kind': 'number', 'dbType': 'INTEGER'},
            {'name': 'notes', 'kind': 'string', 'dbType': 'TEXT'},
            {'name': 'total', 'kind': 'number', 'dbType': 'DECIMAL(19,4)'},
          ],
          'rows': [
            ['1', 'rush order', '1250.7500'],
            ['2', null, '0.0000'],
            ['3', '', '12345678901234.5678'],
          ],
          'truncated': true,
          'elapsedMs': 12,
        });

    test('keeps NULL and the empty string apart', () {
      final result = build();
      expect(result.rows[1][1], isNull);
      expect(result.rows[2][1], '');
    });

    test('CSV distinguishes NULL from an empty string', () {
      final lines = build().toCsv().trim().split('\n');
      expect(lines.first, 'id,notes,total');
      // NULL is an unquoted empty field; an empty string is a quoted one.
      // A spreadsheet has no other way to tell them apart.
      expect(lines[2], '2,,0.0000');
      expect(lines[3], '3,"",12345678901234.5678');
    });

    test('CSV quotes commas, quotes, and newlines', () {
      final result = QueryResult.fromJson({
        'kind': 'rows',
        'columns': [
          {'name': 'note', 'kind': 'string'},
        ],
        'rows': [
          ['a,b'],
          ['say "hi"'],
          ['line1\nline2'],
        ],
      });
      final csv = result.toCsv();
      expect(csv, contains('"a,b"'));
      expect(csv, contains('"say ""hi"""'));
      expect(csv, contains('"line1\nline2"'));
    });

    test('JSON export re-types numbers without losing the wide ones', () {
      final decoded = jsonDecode(build().toJsonText()) as List<dynamic>;
      expect(decoded[0]['id'], 1);
      expect(decoded[1]['notes'], isNull);
      // A value a double can hold exactly becomes a real JSON number, and a
      // difference in stored scale is not a difference in value.
      expect(decoded[0]['total'], 1250.75);
      // A decimal too wide for a double stays a string with every digit
      // intact, rather than being silently rounded on the way out.
      expect(decoded[2]['total'], '12345678901234.5678');
    });

    test('summary says when the result was capped', () {
      expect(build().summary, contains('capped'));
    });

    test('summary reports affected rows for a write', () {
      final result = QueryResult.fromJson({
        'kind': 'affected',
        'statement': 'UPDATE orders SET notes = NULL',
        'rowsAffected': 3,
        'elapsedMs': 8,
      });
      expect(result.hasRows, isFalse);
      expect(result.summary, '3 rows affected in 8ms');
    });

    test('a driver that will not report affected rows does not claim zero', () {
      final result = QueryResult.fromJson({
        'kind': 'affected',
        'statement': 'CREATE TABLE t (id int)',
        'elapsedMs': 4,
      });
      expect(result.rowsAffected, isNull);
      expect(result.summary, 'Done in 4ms');
    });

    test('an error is carried on the result, not thrown away', () {
      final result = QueryResult.fromJson({
        'kind': 'rows',
        'statement': 'SELECT * FROM nope',
        'error': 'no such table: nope',
      });
      expect(result.failed, isTrue);
      expect(result.hasRows, isFalse);
      expect(result.summary, 'no such table: nope');
    });
  });

  group('ValueKind', () {
    test('maps the core’s names', () {
      expect(ValueKind.fromId('number'), ValueKind.number);
      expect(ValueKind.fromId('bool'), ValueKind.boolean);
      expect(ValueKind.fromId('datetime'), ValueKind.datetime);
      expect(ValueKind.fromId('bytes'), ValueKind.bytes);
      // A kind added to the core later must not crash an older app.
      expect(ValueKind.fromId('geography'), ValueKind.unknown);
      expect(ValueKind.fromId(null), ValueKind.unknown);
    });

    test('only numbers are right-aligned', () {
      expect(ValueKind.number.isNumeric, isTrue);
      expect(ValueKind.string.isNumeric, isFalse);
      expect(ValueKind.datetime.isNumeric, isFalse);
    });
  });

  group('TableDetail', () {
    test('parses a full payload', () {
      final detail = TableDetail.fromJson({
        'name': 'orders',
        'schema': 'dbo',
        'columns': [
          {
            'name': 'id',
            'dataType': 'int',
            'nullable': false,
            'isPrimaryKey': true,
            'isAutoIncrement': true,
          },
        ],
        'indexes': [
          {
            'name': 'ix_orders_customer',
            'columns': ['customer_id', 'reference'],
            'unique': false,
          },
        ],
        'foreignKeys': [
          {
            'name': 'fk_orders_customer',
            'columns': ['customer_id'],
            'refTable': 'customers',
            'refColumns': ['id'],
          },
        ],
        'ddl': 'CREATE TABLE [dbo].[orders] (...)',
      });

      expect(detail.columns.single.isPrimaryKey, isTrue);
      // Composite index order decides whether a query can use the index, so
      // it has to survive parsing intact.
      expect(detail.indexes.single.columns, ['customer_id', 'reference']);
      expect(detail.foreignKeys.single.refTable, 'customers');
    });

    test('a payload missing optional sections still parses', () {
      final detail = TableDetail.fromJson({'name': 'orders'});
      expect(detail.columns, isEmpty);
      expect(detail.indexes, isEmpty);
      expect(detail.foreignKeys, isEmpty);
    });
  });
}
