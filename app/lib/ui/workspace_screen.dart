import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'editor_view.dart';
import 'history_view.dart';
import 'table_detail_screen.dart';
import 'theme.dart';

/// Which of the three panes is in front.
class _Pane {
  static const explorer = 0;
  static const editor = 1;
  static const history = 2;
}

/// The workspace: explorer, editor, and history, once a connection is open.
///
/// There is no app bar and no tab bar. Both were permanent, and on a phone in
/// landscape they cost about a quarter of the screen before the keyboard took
/// its half — which left the editor roughly one line to type into. Navigation
/// lives in a drawer, where it costs nothing until it is asked for, and the
/// only thing kept on screen is the name of the database a statement will run
/// against.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final _scaffold = GlobalKey<ScaffoldState>();
  int _pane = _Pane.editor;

  /// Moves to the editor with a statement loaded, which is how the explorer
  /// hands a table over to be queried.
  ///
  /// [inNewTab] is for work the user will keep — a routine they are about to
  /// alter — so it does not overwrite whatever they were already writing.
  void _openInEditor(String sql, {bool inNewTab = false}) {
    final state = context.read<AppState>();
    if (inNewTab) {
      // The editor notices the tab changed and loads its text itself.
      state.openTab(sql: sql);
    } else {
      state.setSql(sql);
      EditorView.loadSql(sql);
    }
    setState(() => _pane = _Pane.editor);
  }

  void _show(int pane) {
    // The panes stay mounted, so the editor could otherwise keep focus — and
    // its header, folded away for typing, would never come back.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(); // the drawer
    if (pane != _pane) setState(() => _pane = pane);
  }

  Future<void> _disconnect() async {
    final navigator = Navigator.of(context);
    navigator.pop(); // the drawer
    await context.read<AppState>().disconnect();
    navigator.pop(); // the workspace
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connection = state.active;

    // Switching database reconnects, so there is a moment with no session.
    // Showing "disconnected" for that moment would look like a failure.
    if (connection == null) {
      return state.connecting ? const _Switching() : const _Disconnected();
    }

    return Scaffold(
      key: _scaffold,
      drawer: _NavDrawer(
        connection: connection,
        pane: _pane,
        onShow: _show,
        onDisconnect: _disconnect,
      ),
      // Landscape puts the notch and the gesture bar down the sides, where
      // they would otherwise clip the first column of a results grid.
      body: SafeArea(
        left: true,
        right: true,
        top: true,
        bottom: false,
        child: Column(
          children: [
            // Folded away while the editor has focus. Every pixel of the
            // remaining height belongs to the text you are typing.
            ValueListenableBuilder<bool>(
              valueListenable: EditorView.typing,
              builder: (context, typing, header) =>
                  typing ? const SizedBox.shrink() : header!,
              child: _Header(
                connection: connection,
                pane: _pane,
                onMenu: () => _scaffold.currentState?.openDrawer(),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _pane,
                children: [
                  _ExplorerView(onOpenInEditor: _openInEditor),
                  const EditorView(),
                  HistoryView(onUse: _openInEditor),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one strip of chrome the workspace keeps: a way into the drawer, the
/// database in use, and whatever single action the visible pane needs.
class _Header extends StatelessWidget {
  const _Header({
    required this.connection,
    required this.pane,
    required this.onMenu,
  });

  final ActiveConnection connection;
  final int pane;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Menu',
              icon: const Icon(Icons.menu, size: 22),
              onPressed: onMenu,
            ),
            Expanded(child: _DatabaseButton(connection: connection)),
            if (pane == _Pane.editor)
              IconButton(
                tooltip: 'New query tab',
                icon: const Icon(Icons.add, size: 22),
                onPressed: () => context.read<AppState>().openTab(),
              ),
            if (pane == _Pane.explorer)
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh, size: 22),
                onPressed: () => context.read<AppState>().refreshTables(),
              ),
          ],
        ),
      ),
    );
  }
}

/// The database in use, and — when the login can see more than one — the way
/// to move to another.
///
/// This is the header's whole job. Which server, which login, and which
/// profile are all questions the drawer answers; the one thing that has to be
/// visible without asking is where the next statement lands.
class _DatabaseButton extends StatelessWidget {
  const _DatabaseButton({required this.connection});

  final ActiveConnection connection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tag = connection.profile.colorTag;
    final current = _currentName(connection);
    final names = connection.databases;

    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tag != null) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: Color(tag), shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            current,
            overflow: TextOverflow.ellipsis,
            style: monoFont.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (connection.profile.readOnly) ...[
          const SizedBox(width: 6),
          const Icon(Icons.lock_outline, size: 13),
        ],
        if (names.length > 1)
          Icon(Icons.arrow_drop_down,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
      ],
    );

    if (names.length <= 1) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(padding: const EdgeInsets.only(right: 8), child: label),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<String>(
        tooltip: 'Switch database',
        position: PopupMenuPosition.under,
        padding: EdgeInsets.zero,
        itemBuilder: (context) => [
          for (final name in names)
            PopupMenuItem<String>(
              value: name,
              height: 42,
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: name == current
                        ? const Icon(Icons.check, size: 16)
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: monoFont.copyWith(fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
        onSelected: (value) async {
          final messenger = ScaffoldMessenger.of(context);
          final state = context.read<AppState>();
          // Switching reconnects, so it can fail the way any connect can —
          // most often because the login has no access to what was picked.
          if (!await state.switchDatabase(value)) {
            messenger.showSnackBar(SnackBar(
              content: Text(state.connectionError),
              behavior: SnackBarBehavior.floating,
            ));
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: label,
        ),
      ),
    );
  }

  /// What to call the database we are in.
  ///
  /// The server's own answer first; the profile only as a fallback for the
  /// moment before the first round trip comes back.
  static String _currentName(ActiveConnection connection) {
    if (connection.currentDatabase.isNotEmpty) return connection.currentDatabase;
    if (connection.profile.database.isNotEmpty) {
      return connection.profile.database;
    }
    return connection.profile.name;
  }
}

class _NavDrawer extends StatelessWidget {
  const _NavDrawer({
    required this.connection,
    required this.pane,
    required this.onShow,
    required this.onDisconnect,
  });

  final ActiveConnection connection;
  final int pane;
  final void Function(int pane) onShow;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tag = connection.profile.colorTag;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (tag != null) ...[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                              color: Color(tag), shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          connection.profile.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    connection.profile.subtitle,
                    style: monoFont.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (connection.profile.readOnly) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.lock_outline, size: 14),
                        const SizedBox(width: 6),
                        Text('Read-only',
                            style: theme.textTheme.labelMedium),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            _NavTile(
              icon: Icons.account_tree_outlined,
              label: 'Explorer',
              selected: pane == _Pane.explorer,
              onTap: () => onShow(_Pane.explorer),
            ),
            _NavTile(
              icon: Icons.terminal,
              label: 'Editor',
              selected: pane == _Pane.editor,
              onTap: () => onShow(_Pane.editor),
            ),
            _NavTile(
              icon: Icons.history,
              label: 'History',
              selected: pane == _Pane.history,
              onTap: () => onShow(_Pane.history),
            ),
            const Spacer(),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.power_settings_new),
              title: const Text('Disconnect'),
              onTap: onDisconnect,
            ),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      selectedColor: theme.colorScheme.onSecondaryContainer,
      leading: Icon(icon),
      title: Text(label),
      onTap: onTap,
    );
  }
}

class _Switching extends StatelessWidget {
  const _Switching();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(height: 14),
            Text('Reconnecting…'),
          ],
        ),
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

  final void Function(String sql, {bool inNewTab}) onOpenInEditor;

  @override
  State<_ExplorerView> createState() => _ExplorerViewState();
}

class _ExplorerViewState extends State<_ExplorerView> {
  String _filter = '';

  /// Empty means every kind. SSMS separates these into folders; on a phone a
  /// row of chips does the same job without a tree to expand.
  String _kind = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connection = state.active;
    if (connection == null) return const SizedBox.shrink();

    final needle = _filter.trim().toLowerCase();
    final tables = connection.tables.where((t) {
      if (_kind.isNotEmpty && t.type != _kind) return false;
      return needle.isEmpty || t.name.toLowerCase().contains(needle);
    }).toList();

    // Only offer a chip for a kind that is actually present. A Procedures
    // filter on SQLite, which has none, is a dead control.
    final counts = <String, int>{};
    for (final t in connection.tables) {
      counts[t.type] = (counts[t.type] ?? 0) + 1;
    }

    return Column(
      children: [
        // The database picker lives in the header now — it is the one piece of
        // context that matters on every pane, not just this one.
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
        if (counts.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _KindChip(
                  label: 'All',
                  count: connection.tables.length,
                  selected: _kind.isEmpty,
                  onTap: () => setState(() => _kind = ''),
                ),
                for (final kind in _kindOrder)
                  if (counts[kind] != null)
                    _KindChip(
                      label: _kindLabel(kind, counts[kind]!),
                      count: counts[kind]!,
                      selected: _kind == kind,
                      onTap: () => setState(
                          () => _kind = _kind == kind ? '' : kind),
                    ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Filter ${tables.length} of ${connection.tables.length}',
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
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: tables.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final table = tables[index];
        return ListTile(
          leading: IconButton(
            tooltip: 'Structure',
            icon: Icon(iconForTable(table), size: 20),
            onPressed: () => _openDetail(table),
          ),
          title: Text(table.name, style: monoFont.copyWith(fontSize: 14)),
          subtitle: _subtitleFor(table),
          trailing: table.isRoutine
              ? null
              : IconButton(
                  tooltip: 'Query this table',
                  icon: const Icon(Icons.play_arrow_outlined),
                  onPressed: () async {
                    final sql =
                        await context.read<AppState>().previewSql(table);
                    widget.onOpenInEditor(sql.preview);
                  },
                ),
          // Tapping a table shows its rows, which is what anyone opening a
          // database client wants first. Structure is one more tap away, on
          // the row's own icon.
          onTap: () async {
            if (table.isRoutine) {
              _openDetail(table);
              return;
            }
            final sql = await context
                .read<AppState>()
                .previewSql(table, limit: 200);
            widget.onOpenInEditor(sql.preview);
          },
          onLongPress: () => _openDetail(table),
        );
      },
    );
  }

  void _openDetail(TableInfo table) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TableDetailScreen(
          table: table,
          onOpenInEditor: widget.onOpenInEditor,
        ),
      ),
    );
  }

  Widget? _subtitleFor(TableInfo table) {
    final parts = <String>[
      if (table.isRoutine) table.type,
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


const _kindOrder = [
  ObjectKind.table,
  ObjectKind.view,
  ObjectKind.materializedView,
  ObjectKind.function,
  ObjectKind.procedure,
];

String _kindLabel(String kind, int count) {
  final plural = count == 1;
  switch (kind) {
    case ObjectKind.table:
      return plural ? 'Table' : 'Tables';
    case ObjectKind.view:
      return plural ? 'View' : 'Views';
    case ObjectKind.materializedView:
      return 'Mat. views';
    case ObjectKind.function:
      return plural ? 'Function' : 'Functions';
    case ObjectKind.procedure:
      return plural ? 'Procedure' : 'Procedures';
  }
  return kind;
}

class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        label: Text('$label  $count'),
      ),
    );
  }
}
