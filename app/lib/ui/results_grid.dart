import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/models.dart';
import 'theme.dart';

/// The results area under the editor.
class ResultsPanel extends StatelessWidget {
  const ResultsPanel({super.key, required this.results, required this.error});

  final List<QueryResult> results;
  final String error;

  /// True when at least one statement produced a grid.
  ///
  /// This is what decides whether the Results tab exists at all: an UPDATE has
  /// no rows to show, and an empty grid beside "3 rows affected" invites the
  /// reader to wonder which of the two is the real answer.
  bool get _hasAnyRows =>
      results.any((r) => r.hasRows && r.columns.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    if (error.isNotEmpty) {
      return _ErrorPanel(message: error);
    }
    if (results.isEmpty) {
      return const Center(
        child: Text('Run a statement to see results here.'),
      );
    }

    // Results and Messages are separate, the way SSMS separates them. A write
    // reports only in Messages; a read gets a grid and still leaves its
    // timings and warnings somewhere they do not crowd the data.
    return DefaultTabController(
      length: _hasAnyRows ? 2 : 1,
      child: Column(
        children: [
          TabBar(
            tabs: [
              if (_hasAnyRows) const Tab(height: 38, text: 'Results'),
              Tab(height: 38, text: 'Messages (${results.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                if (_hasAnyRows) _buildResults(context),
                _MessagesPanel(results: results),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final withRows =
        results.where((r) => r.hasRows && r.columns.isNotEmpty).toList();
    if (withRows.length == 1) {
      return _SingleResult(result: withRows.first);
    }
    return _resultTabs(context, withRows);
  }

  Widget _resultTabs(BuildContext context, List<QueryResult> results) {

    // A batch produced several results. Tabs keep them all reachable rather
    // than showing only the last one, which is what hides the fact that
    // statement two failed.
    return DefaultTabController(
      length: results.length,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (var i = 0; i < results.length; i++)
                Tab(
                  child: Row(
                    children: [
                      if (results[i].failed)
                        Icon(Icons.error_outline,
                            size: 14, color: Theme.of(context).colorScheme.error)
                      else
                        const Icon(Icons.check, size: 14),
                      const SizedBox(width: 6),
                      Text('${i + 1}'),
                    ],
                  ),
                ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final result in results) _SingleResult(result: result),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SingleResult extends StatelessWidget {
  const _SingleResult({required this.result});

  final QueryResult result;

  @override
  Widget build(BuildContext context) {
    if (result.failed) {
      return _ErrorPanel(message: result.error, statement: result.statement);
    }
    if (!result.hasRows) {
      return _AffectedPanel(result: result);
    }
    if (result.rows.isEmpty) {
      return Column(
        children: [
          _StatusBar(result: result),
          const Expanded(child: Center(child: Text('No rows.'))),
        ],
      );
    }
    return Column(
      children: [
        _StatusBar(result: result),
        Expanded(child: ResultsGrid(result: result)),
      ],
    );
  }
}

/// A scrollable grid of results.
///
/// Both axes scroll, the header row stays put, and rows are built lazily so
/// that ten thousand rows cost the same to open as ten. Column widths are
/// measured from a sample of the data rather than fixed — a column of dates
/// and a column of long text need very different room, and a uniform width
/// wastes most of a phone screen.
class ResultsGrid extends StatefulWidget {
  const ResultsGrid({super.key, required this.result});

  final QueryResult result;

  @override
  State<ResultsGrid> createState() => _ResultsGridState();
}

class _ResultsGridState extends State<ResultsGrid> {
  final _horizontal = ScrollController();
  late List<double> _widths;

  @override
  void initState() {
    super.initState();
    _widths = _measureColumns(widget.result);
  }

  @override
  void didUpdateWidget(ResultsGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _widths = _measureColumns(widget.result);
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  /// Sizes each column from its header and the first rows on screen.
  ///
  /// Only a sample is measured: scanning every cell of a large result to lay
  /// out a screen that shows twenty rows is work nobody sees.
  static List<double> _measureColumns(QueryResult result) {
    const charWidth = 8.0;
    const padding = 24.0;
    const minWidth = 64.0;
    const maxWidth = 260.0;
    final sampleSize = result.rows.length < 50 ? result.rows.length : 50;

    return [
      for (var col = 0; col < result.columns.length; col++)
        () {
          var longest = result.columns[col].name.length;
          for (var row = 0; row < sampleSize; row++) {
            final cells = result.rows[row];
            if (col >= cells.length) continue;
            final length = cells[col]?.length ?? 4; // "NULL"
            if (length > longest) longest = length;
          }
          return (longest * charWidth + padding).clamp(minWidth, maxWidth);
        }(),
    ];
  }

  double get _totalWidth =>
      _widths.fold(0.0, (sum, width) => sum + width) + 56; // + row number gutter

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final theme = Theme.of(context);

    return Scrollbar(
      controller: _horizontal,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _horizontal,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _totalWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HeaderRow(columns: result.columns, widths: _widths),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: result.rows.length,
                  itemExtent: 34,
                  itemBuilder: (context, index) => _DataRow(
                    index: index,
                    cells: result.rows[index],
                    columns: result.columns,
                    widths: _widths,
                    // Banding makes a wide row easy to follow across the
                    // screen, which matters far more on a phone than a laptop.
                    striped: index.isOdd,
                    onTap: () => _showRow(context, result, index),
                  ),
                ),
              ),
              if (result.truncated)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  color: theme.colorScheme.tertiaryContainer,
                  child: Text(
                    'Showing the first ${result.rows.length} rows — there are more.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens one row full-screen.
  ///
  /// A grid cell on a phone is too small to read a JSON blob or a long note
  /// in. Tapping a row to see every column stacked and selectable is how the
  /// data actually gets read.
  void _showRow(BuildContext context, QueryResult result, int index) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView.separated(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          itemCount: result.columns.length + 1,
          separatorBuilder: (_, __) => const Divider(height: 16),
          itemBuilder: (context, i) {
            if (i == 0) {
              return Text(
                'Row ${index + 1} of ${result.rows.length}',
                style: Theme.of(context).textTheme.titleSmall,
              );
            }
            final col = i - 1;
            final value = col < result.rows[index].length
                ? result.rows[index][col]
                : null;
            return _RowField(column: result.columns[col], value: value);
          },
        ),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.columns, required this.widths});

  final List<ColumnMeta> columns;
  final List<double> widths;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 38,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const SizedBox(width: 56),
          for (var i = 0; i < columns.length; i++)
            SizedBox(
              width: widths[i],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Icon(iconForKind(columns[i].kind),
                        size: 12, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Tooltip(
                        message: columns[i].dbType.isEmpty
                            ? columns[i].name
                            : '${columns[i].name} · ${columns[i].dbType}',
                        child: Text(
                          columns[i].name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DataRow extends StatelessWidget {
  const _DataRow({
    required this.index,
    required this.cells,
    required this.columns,
    required this.widths,
    required this.striped,
    required this.onTap,
  });

  final int index;
  final List<String?> cells;
  final List<ColumnMeta> columns;
  final List<double> widths;
  final bool striped;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: striped
            ? theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5)
            : null,
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.right,
                style: monoFont.copyWith(
                  fontSize: 11,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            for (var i = 0; i < columns.length; i++)
              SizedBox(
                width: widths[i],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Align(
                    alignment: columns[i].kind.isNumeric
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Text(
                      i < cells.length ? (cells[i] ?? 'NULL') : '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: cellStyle(
                        theme,
                        columns[i].kind,
                        isNull: i >= cells.length || cells[i] == null,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RowField extends StatelessWidget {
  const _RowField({required this.column, required this.value});

  final ColumnMeta column;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(iconForKind(column.kind),
                size: 13, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(column.name, style: theme.textTheme.labelMedium),
            const SizedBox(width: 8),
            Text(
              column.dbType.toLowerCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const Spacer(),
            if (value != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
          ],
        ),
        const SizedBox(height: 4),
        SelectableText(
          value ?? 'NULL',
          style: cellStyle(theme, column.kind, isNull: value == null)
              .copyWith(fontSize: 14),
        ),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.result});

  final QueryResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      color: theme.colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: Text(
              result.summary,
              style: theme.textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (result.hasRows && result.rows.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.ios_share, size: 18),
              tooltip: 'Export',
              onSelected: (choice) => _export(context, choice),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'csv', child: Text('Share as CSV')),
                PopupMenuItem(value: 'json', child: Text('Share as JSON')),
                PopupMenuItem(value: 'copy', child: Text('Copy as CSV')),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, String choice) async {
    final messenger = ScaffoldMessenger.of(context);
    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: result.toCsv()));
      messenger.showSnackBar(const SnackBar(
        content: Text('Copied as CSV'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    final isCsv = choice == 'csv';
    final content = isCsv ? result.toCsv() : result.toJsonText();
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');

    // Written into the cache directory rather than anywhere permanent: an
    // export is in transit to another app, and leaving query results sitting
    // in app storage is data nobody asked to keep.
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/query-$stamp.${isCsv ? 'csv' : 'json'}');
    await file.writeAsString(content);

    await Share.shareXFiles([XFile(file.path)], subject: 'Query results');
  }
}

class _AffectedPanel extends StatelessWidget {
  const _AffectedPanel({required this.result});

  final QueryResult result;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 40),
            const SizedBox(height: 12),
            Text(result.summary,
                style: Theme.of(context).textTheme.titleSmall),
            if (result.lastInsertId != null) ...[
              const SizedBox(height: 6),
              Text('New id ${result.lastInsertId}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            SelectableText(
              result.statement,
              textAlign: TextAlign.center,
              style: monoFont.copyWith(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, this.statement});

  final String message;
  final String? statement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(
                message,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
        if (statement != null && statement!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Statement', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              statement!,
              style: monoFont.copyWith(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}


/// The Messages tab: what each statement did, in order.
///
/// This is where a write reports itself. "3 rows affected" is the entire
/// answer to an UPDATE, and it deserves somewhere it is stated plainly rather
/// than a caption under an empty grid.
class _MessagesPanel extends StatelessWidget {
  const _MessagesPanel({required this.results});

  final List<QueryResult> results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 20),
      itemBuilder: (context, i) {
        final r = results[i];
        final failed = r.failed;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  failed ? Icons.error_outline : Icons.check_circle_outline,
                  size: 16,
                  color: failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('${i + 1}', style: theme.textTheme.labelSmall),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    r.summary,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: failed ? theme.colorScheme.error : null,
                    ),
                  ),
                ),
              ],
            ),
            if (r.lastInsertId != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Text('New id ${r.lastInsertId}',
                    style: theme.textTheme.bodySmall),
              ),
            ],
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: SelectableText(
                r.statement.replaceAll(RegExp(r'\s+'), ' '),
                maxLines: 3,
                style: monoFont.copyWith(
                  fontSize: 11.5,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
