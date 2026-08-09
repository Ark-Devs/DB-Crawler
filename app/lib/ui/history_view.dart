import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Every statement run on this device, newest first.
///
/// This is the feature that makes the app usable on a phone. Retyping a join
/// on a touchscreen is miserable, and the query someone needs at 11pm is
/// almost always one they have run before.
class HistoryView extends StatefulWidget {
  const HistoryView({super.key, required this.onUse});

  final void Function(String sql) onUse;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final needle = _filter.trim().toLowerCase();
    final entries = needle.isEmpty
        ? state.history.entries
        : state.history.entries
            .where((e) => e.sql.toLowerCase().contains(needle))
            .toList();

    if (state.history.entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Statements you run show up here, so you can run them again '
            'without retyping.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search history',
                  ),
                  onChanged: (value) => setState(() => _filter = value),
                ),
              ),
              IconButton(
                tooltip: 'Clear history',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Clear history?'),
                      content: const Text(
                        'Every saved statement is removed from this device.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true || !context.mounted) return;
                  final appState = context.read<AppState>();
                  await appState.history.clear();
                  appState.refresh();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) =>
                _HistoryTile(entry: entries[index], onUse: widget.onUse),
          ),
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry, required this.onUse});

  final HistoryEntry entry;
  final void Function(String sql) onUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        entry.succeeded ? Icons.check_circle_outline : Icons.error_outline,
        size: 18,
        color: entry.succeeded ? theme.colorScheme.outline : theme.colorScheme.error,
      ),
      title: Text(
        entry.sql.replaceAll(RegExp(r'\s+'), ' '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: monoFont.copyWith(fontSize: 12.5),
      ),
      subtitle: Text(
        '${entry.connectionName} · ${_relative(entry.ranAt)}'
        '${entry.rowCount != null ? ' · ${entry.rowCount} rows' : ''}',
        style: theme.textTheme.labelSmall,
      ),
      trailing: IconButton(
        iconSize: 18,
        tooltip: 'Copy',
        icon: const Icon(Icons.copy),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: entry.sql));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copied'),
              duration: Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
            ),
          );
        },
      ),
      onTap: () => onUse(entry.sql),
    );
  }

  static String _relative(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')}';
  }
}
