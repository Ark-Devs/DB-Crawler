import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/native_core.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Everything known about one table: columns, indexes, keys, and its DDL.
class TableDetailScreen extends StatefulWidget {
  const TableDetailScreen({
    super.key,
    required this.table,
    required this.onOpenInEditor,
  });

  final TableInfo table;
  final void Function(String sql, {bool inNewTab}) onOpenInEditor;

  @override
  State<TableDetailScreen> createState() => _TableDetailScreenState();
}

class _TableDetailScreenState extends State<TableDetailScreen> {
  TableDetail? _detail;
  String? _routineSource;
  String _error = '';
  String? _exactCount;
  bool _counting = false;

  bool get _isRoutine => widget.table.isRoutine;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    try {
      // A routine is code, not storage: it has a definition to read rather
      // than columns to browse, and asking for columns would simply fail.
      if (_isRoutine) {
        final source = await state.routineDefinition(widget.table);
        if (mounted) setState(() => _routineSource = source);
        return;
      }
      final detail = await state.tableDetail(widget.table);
      if (mounted) setState(() => _detail = detail);
    } on CoreException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  /// Opens the routine's source in a new editor tab, ready to be altered.
  ///
  /// Editing happens in the SQL editor rather than in a bespoke form. That
  /// gets it the read-only guard, the cancel button, the history, and the
  /// Messages pane for free — and, more to the point, what is being changed
  /// stays visible as SQL rather than hidden behind a widget that decides
  /// what to run on your behalf.
  void _editRoutine() {
    final source = _routineSource;
    if (source == null) return;
    final engine = context.read<AppState>().active?.engine;
    widget.onOpenInEditor(_asAlter(source, engine), inNewTab: true);
    Navigator.of(context).pop();
  }

  /// Turns a stored definition into a statement that replaces it.
  ///
  /// SQL Server hands back the original CREATE, which fails against an object
  /// that already exists; ALTER is the same text with one word changed.
  /// PostgreSQL already returns CREATE OR REPLACE. MySQL returns only the
  /// body, so it is left alone with a note — a correct rewrite there needs
  /// DROP and CREATE, which is not something to generate silently.
  static String _asAlter(String source, Engine? engine) {
    final trimmed = source.trimLeft();
    if (engine == Engine.mysql) {
      return '-- MySQL returns only the routine body, not a runnable\n'
          '-- definition. Changing it needs DROP then CREATE, written by hand.\n'
          '$source';
    }
    final match = RegExp(r'^CREATE\s', caseSensitive: false).firstMatch(trimmed);
    if (match == null) return source;
    if (RegExp(r'^CREATE\s+OR\s+REPLACE\s', caseSensitive: false)
        .hasMatch(trimmed)) {
      return source;
    }
    return trimmed.replaceFirst(
        RegExp(r'^CREATE\s', caseSensitive: false), 'ALTER ');
  }

  /// Counts the rows exactly, only when asked.
  ///
  /// COUNT(*) on a large table is a full scan. Running it just to fill in a
  /// label would make opening a table slow in exactly the case where the user
  /// most needs it to be fast, so the estimate is shown by default and this is
  /// opt-in.
  Future<void> _countExactly() async {
    setState(() => _counting = true);
    final state = context.read<AppState>();
    try {
      final sql = await state.previewSql(widget.table);
      await state.run(statement: sql.count);
      final results = state.results;
      if (results.isNotEmpty && results.first.rows.isNotEmpty) {
        setState(() => _exactCount = results.first.rows.first.first);
      }
    } on CoreException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    }
    if (mounted) setState(() => _counting = false);
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.table.name, style: monoFont.copyWith(fontSize: 16)),
        actions: [
          if (_isRoutine)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _routineSource == null ? null : _editRoutine,
            ),
          if (_isRoutine)
            IconButton(
              tooltip: 'Copy definition',
              icon: const Icon(Icons.copy),
              onPressed: _routineSource == null
                  ? null
                  : () {
                      Clipboard.setData(
                          ClipboardData(text: _routineSource!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
            )
          else
          IconButton(
            tooltip: 'Query this table',
            icon: const Icon(Icons.play_arrow),
            onPressed: () async {
              final sql =
                  await context.read<AppState>().previewSql(widget.table);
              if (!context.mounted) return;
              widget.onOpenInEditor(sql.preview);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: switch ((detail, _error)) {
        (_, final error) when error.isNotEmpty => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(error, textAlign: TextAlign.center),
            ),
          ),
        _ when _isRoutine && _routineSource != null =>
          _RoutineSource(source: _routineSource!, kind: widget.table.type),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final d?, _) => _Body(
            detail: d,
            table: widget.table,
            exactCount: _exactCount,
            counting: _counting,
            onCount: _countExactly,
            onOpenInEditor: (sql) {
              widget.onOpenInEditor(sql);
              Navigator.of(context).pop();
            },
          ),
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.detail,
    required this.table,
    required this.exactCount,
    required this.counting,
    required this.onCount,
    required this.onOpenInEditor,
  });

  final TableDetail detail;
  final TableInfo table;
  final String? exactCount;
  final bool counting;
  final VoidCallback onCount;
  final void Function(String sql) onOpenInEditor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text(
                exactCount != null
                    ? '$exactCount rows'
                    : table.rowEstimate != null
                        ? '~${table.rowEstimate} rows (estimate)'
                        : 'Row count unknown',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              if (exactCount == null)
                TextButton(
                  onPressed: counting ? null : onCount,
                  child: Text(counting ? 'Counting…' : 'Count exactly'),
                ),
            ],
          ),
        ),
        _Section(
          title: 'Columns',
          count: detail.columns.length,
          children: [
            for (final column in detail.columns)
              _ColumnTile(column: column, table: table, onOpenInEditor: onOpenInEditor),
          ],
        ),
        if (detail.indexes.isNotEmpty)
          _Section(
            title: 'Indexes',
            count: detail.indexes.length,
            children: [
              for (final index in detail.indexes)
                ListTile(
                  dense: true,
                  leading: Icon(
                    index.primary ? Icons.key : Icons.bolt_outlined,
                    size: 18,
                  ),
                  title: Text(index.name, style: monoFont.copyWith(fontSize: 13)),
                  subtitle: Text(
                    index.columns.join(', '),
                    style: monoFont.copyWith(fontSize: 11),
                  ),
                  trailing: index.unique
                      ? Text('unique', style: theme.textTheme.labelSmall)
                      : null,
                ),
            ],
          ),
        if (detail.foreignKeys.isNotEmpty)
          _Section(
            title: 'Foreign keys',
            count: detail.foreignKeys.length,
            children: [
              for (final fk in detail.foreignKeys)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link, size: 18),
                  title: Text(
                    '${fk.columns.join(', ')} → '
                    '${fk.refSchema.isEmpty ? '' : '${fk.refSchema}.'}'
                    '${fk.refTable}(${fk.refColumns.join(', ')})',
                    style: monoFont.copyWith(fontSize: 12),
                  ),
                  subtitle: Text(fk.name, style: theme.textTheme.labelSmall),
                ),
            ],
          ),
        if (detail.ddl.isNotEmpty)
          _Section(
            title: 'Definition',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Reconstructed from the catalog — readable, but not a '
                  'faithful script. Storage options, computed columns, and '
                  'check constraints are not shown.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  detail.ddl,
                  style: monoFont.copyWith(fontSize: 11.5),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: detail.ddl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _ColumnTile extends StatelessWidget {
  const _ColumnTile({
    required this.column,
    required this.table,
    required this.onOpenInEditor,
  });

  final ColumnDetail column;
  final TableInfo table;
  final void Function(String sql) onOpenInEditor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: column.isPrimaryKey
          ? const Icon(Icons.key, size: 18)
          : const SizedBox(width: 18),
      title: Row(
        children: [
          Flexible(
            child: Text(column.name, style: monoFont.copyWith(fontSize: 13)),
          ),
          const SizedBox(width: 8),
          Text(
            column.dataType,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ],
      ),
      subtitle: Text(
        [
          if (!column.nullable) 'not null',
          if (column.isAutoIncrement) 'auto',
          if (column.defaultValue != null) 'default ${column.defaultValue}',
          if (column.comment.isNotEmpty) column.comment,
        ].join(' · '),
        style: theme.textTheme.labelSmall,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        iconSize: 18,
        tooltip: 'Filter by this column',
        icon: const Icon(Icons.filter_alt_outlined),
        onPressed: () {
          // Hands over a statement with the WHERE already scaffolded, so the
          // user types a value rather than a query.
          final ref = table.schema.isEmpty
              ? table.name
              : '${table.schema}.${table.name}';
          onOpenInEditor('SELECT * FROM $ref\nWHERE ${column.name} = ');
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.count});

  final String title;
  final int? count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Row(
            children: [
              Text(title.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    color: theme.colorScheme.outline,
                  )),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text('$count',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}


/// The stored source of a function or procedure.
///
/// Unlike the CREATE TABLE the table screen reconstructs from catalog
/// metadata, this is the real text the server holds, so it can be trusted and
/// copied.
class _RoutineSource extends StatelessWidget {
  const _RoutineSource({required this.source, required this.kind});

  final String source;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          kind.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            source,
            style: monoFont.copyWith(fontSize: 12),
          ),
        ),
      ],
    );
  }
}
