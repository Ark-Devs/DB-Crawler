import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'results_grid.dart';
import 'theme.dart';

/// The SQL editor and its results.
class EditorView extends StatefulWidget {
  const EditorView({super.key, this.onRequestTab});

  final VoidCallback? onRequestTab;

  /// Loads SQL into the editor from elsewhere in the app.
  ///
  /// A static hook rather than a key or a controller passed down: the explorer
  /// and the history list both need to push text into an editor that lives
  /// inside a TabBarView and may not be built yet, and threading a controller
  /// through both would be more plumbing than the one live editor justifies.
  static void Function(String sql)? _loader;
  static void loadSql(String sql) => _loader?.call(sql);

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    EditorView._loader = (sql) {
      _controller.text = sql;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
      context.read<AppState>().setSql(sql);
      if (mounted) setState(() {});
    };
    final existing = context.read<AppState>().sql;
    if (existing.isNotEmpty) _controller.text = existing;
  }

  @override
  void dispose() {
    EditorView._loader = null;
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Column(
      children: [
        _EditorField(
          controller: _controller,
          focus: _focus,
          onChanged: (value) {
            state.setSql(value);
            setState(() {}); // keeps the run button's enabled state honest
          },
        ),
        _Toolbar(
          canRun: _controller.text.trim().isNotEmpty && !state.running,
          running: state.running,
          rowLimit: state.rowLimit,
          onRun: () {
            _focus.unfocus();
            state.run();
          },
          onCancel: state.cancel,
          onRowLimitChanged: (value) => state.rowLimit = value,
          onFormat: () {
            final formatted = _tidy(_controller.text);
            _controller.text = formatted;
            state.setSql(formatted);
            setState(() {});
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: state.running
              ? const _RunningIndicator()
              : ResultsPanel(
                  results: state.results,
                  error: state.runError,
                ),
        ),
      ],
    );
  }

  /// A light tidy-up, not a formatter.
  ///
  /// It puts the major clauses on their own lines and collapses runs of
  /// whitespace, which is most of the readability win on a narrow screen.
  /// Anything more ambitious needs a real parser, and getting that subtly
  /// wrong would rewrite the user's query into something else.
  static String _tidy(String sql) {
    const clauses = [
      'SELECT', 'FROM', 'WHERE', 'GROUP BY', 'HAVING', 'ORDER BY',
      'LIMIT', 'INNER JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'FULL JOIN',
      'CROSS JOIN', 'JOIN', 'UNION ALL', 'UNION', 'VALUES', 'SET',
    ];
    var out = sql.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    for (final clause in clauses) {
      out = out.replaceAllMapped(
        RegExp('(?<![\\w])$clause(?![\\w])', caseSensitive: false),
        (match) => '\n${match.group(0)!.toUpperCase()}',
      );
    }
    return out
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }
}

class _EditorField extends StatelessWidget {
  const _EditorField({
    required this.controller,
    required this.focus,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 120, maxHeight: 260),
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: TextField(
          controller: controller,
          focusNode: focus,
          maxLines: null,
          expands: false,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          // Every one of these would otherwise fight the user: autocorrect
          // rewrites table names, capitalisation breaks case-sensitive
          // identifiers, and smart quotes turn a valid literal into a syntax
          // error that is invisible on a small screen.
          autocorrect: false,
          enableSuggestions: false,
          smartQuotesType: SmartQuotesType.disabled,
          smartDashesType: SmartDashesType.disabled,
          textCapitalization: TextCapitalization.none,
          style: monoFont.copyWith(fontSize: 14, height: 1.4),
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(12),
            hintText: 'SELECT * FROM …',
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.canRun,
    required this.running,
    required this.rowLimit,
    required this.onRun,
    required this.onCancel,
    required this.onRowLimitChanged,
    required this.onFormat,
  });

  final bool canRun;
  final bool running;
  final int rowLimit;
  final VoidCallback onRun;
  final VoidCallback onCancel;
  final ValueChanged<int> onRowLimitChanged;
  final VoidCallback onFormat;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tag = state.active?.profile.colorTag;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          if (running)
            OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop'),
            )
          else
            FilledButton.icon(
              onPressed: canRun ? onRun : null,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Run'),
              style: tag == null
                  ? null
                  // Tinting the run button with the connection's colour is the
                  // last thing a user sees before a statement executes, which
                  // makes it the right place to say "this is production".
                  : FilledButton.styleFrom(backgroundColor: Color(tag)),
            ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Tidy up',
            icon: const Icon(Icons.format_align_left, size: 20),
            onPressed: onFormat,
          ),
          const Spacer(),
          Text('Limit', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(width: 6),
          DropdownButton<int>(
            value: rowLimit,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: const [
              DropdownMenuItem(value: 100, child: Text('100')),
              DropdownMenuItem(value: 500, child: Text('500')),
              DropdownMenuItem(value: 2000, child: Text('2000')),
              DropdownMenuItem(value: 10000, child: Text('10000')),
            ],
            onChanged: (value) {
              if (value != null) onRowLimitChanged(value);
            },
          ),
        ],
      ),
    );
  }
}

class _RunningIndicator extends StatelessWidget {
  const _RunningIndicator();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 14),
          Text('Running…'),
          SizedBox(height: 4),
          Text(
            'Stop is above if it takes too long.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
