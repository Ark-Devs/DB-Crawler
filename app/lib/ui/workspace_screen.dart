import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'editor_view.dart';
import 'history_view.dart';
import 'table_detail_screen.dart';
import 'theme.dart';

/// The workspace: explorer, editor, and history, once a connection is open.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Moves to the editor with a statement loaded, which is how the explorer
  /// hands a table over to be queried.
  void _openInEditor(String sql) {
    context.read<AppState>().setSql(sql);
    EditorView.loadSql(sql);
    _tabs.animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connection = state.active;

    // The session can be dropped from under us — the OS suspended the app long
    // enough for the socket to die. Showing the workspace over a dead
    // connection would fail every tap, so the screen steps back instead.
    if (connection == null) {
      return const _Disconnected();
    }

    final tag = connection.profile.colorTag;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (tag != null) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: Color(tag), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    connection.profile.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                if (connection.profile.readOnly) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.lock_outline, size: 14),
                ],
              ],
            ),
            Text(
              connection.profile.subtitle,
              style: monoFont.copyWith(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.power_settings_new),
            onPressed: () async {
              final navigator = Navigator.of(context);
              await context.read<AppState>().disconnect();
              navigator.pop();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.account_tree_outlined), text: 'Explorer'),
            Tab(icon: Icon(Icons.terminal), text: 'Editor'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ExplorerView(onOpenInEditor: _openInEditor),
          EditorView(onRequestTab: () => _tabs.animateTo(1)),
          HistoryView(onUse: _openInEditor),
        ],
      ),
    );
  }
}

class _Disconnected extends StatelessWidget {
  const _Disconnected();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Disconnected')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off, size: 48),
              const SizedBox(height: 16),
              const Text(
                'The connection closed.\n'
                'Phones drop idle sockets when an app is in the background.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to connections'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The schema tree: schema picker, then a searchable list of tables.
class _ExplorerView extends StatefulWidget {
  const _ExplorerView({required this.onOpenInEditor});

  final void Function(String sql) onOpenInEditor;

  @override
  State<_ExplorerView> createState() => _ExplorerViewState();
}

class _ExplorerViewState extends State<_ExplorerView> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connection = state.active;
    if (connection == null) return const SizedBox.shrink();

    final needle = _filter.trim().toLowerCase();
    final tables = needle.isEmpty
        ? connection.tables
        : connection.tables
            .where((t) => t.name.toLowerCase().contains(needle))
            .toList();

    return Column(
      children: [
        if (connection.engine.usesSchemas && connection.schemas.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: DropdownButtonFormField<String>(
              initialValue: connection.selectedSchema,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Schema'),
              items: [
                for (final schema in connection.schemas)
                  DropdownMenuItem(value: schema, child: Text(schema)),
              ],
              onChanged: (value) => context.read<AppState>().selectSchema(value),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Filter ${connection.tables.length} tables',
              suffixIcon: _filter.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _filter = ''),
                    ),
            ),
            onChanged: (value) => setState(() => _filter = value),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => context.read<AppState>().refreshTables(),
            child: _buildBody(connection, tables),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(ActiveConnection connection, List<TableInfo> tables) {
    if (connection.tablesLoading && connection.tables.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (connection.tablesError.isNotEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 12),
                SelectableText(
                  connection.tablesError,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => context.read<AppState>().refreshTables(),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (tables.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Nothing here.')),
          ),
        ],
      );
    }

    return ListView.separated(
      itemCount: tables.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final table = tables[index];
        return ListTile(
          leading: Icon(iconForTable(table), size: 20),
          title: Text(table.name, style: monoFont.copyWith(fontSize: 14)),
          subtitle: _subtitleFor(table),
          trailing: IconButton(
            tooltip: 'Query this table',
            icon: const Icon(Icons.play_arrow_outlined),
            onPressed: () async {
              final sql = await context.read<AppState>().previewSql(table);
              widget.onOpenInEditor(sql.preview);
            },
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TableDetailScreen(
                table: table,
                onOpenInEditor: widget.onOpenInEditor,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget? _subtitleFor(TableInfo table) {
    final parts = <String>[
      if (table.isView) 'view',
      // The estimate is the planner's, not a COUNT(*), so it is labelled as
      // approximate rather than presented as fact.
      if (table.rowEstimate != null) '~${_compact(table.rowEstimate!)} rows',
      if (table.comment.isNotEmpty) table.comment,
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
