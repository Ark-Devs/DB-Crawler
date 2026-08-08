import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'connection_editor.dart';
import 'theme.dart';
import 'workspace_screen.dart';

/// The app opens here: the list of saved connections.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final profiles = List.of(state.connections.profiles)
      ..sort((a, b) {
        // Most recently used first — on a phone the list you want is almost
        // always the one you used last.
        final aTime = a.lastUsed;
        final bTime = b.lastUsed;
        if (aTime == null && bTime == null) return a.name.compareTo(b.name);
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('DB Crawler'),
        actions: [
          IconButton(
            tooltip: 'New connection',
            icon: const Icon(Icons.add),
            onPressed: () => _openEditor(context, null),
          ),
        ],
      ),
      body: profiles.isEmpty
          ? _EmptyState(onAdd: () => _openEditor(context, null))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: profiles.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) => _ConnectionTile(
                profile: profiles[index],
                onEdit: () => _openEditor(context, profiles[index]),
              ),
            ),
    );
  }

  Future<void> _openEditor(BuildContext context, ConnectionProfile? profile) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ConnectionEditor(existing: profile)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.storage_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('No connections yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add a database and it stays on this device. '
              'Passwords go into the phone’s keystore, not into a file.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add a connection'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({required this.profile, required this.onEdit});

  final ConnectionProfile profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tag = profile.colorTag;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: tag != null
              ? Color(tag).withValues(alpha: 0.18)
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: tag != null
              ? Border.all(color: Color(tag).withValues(alpha: 0.6))
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          _engineInitials(profile.engine),
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: tag != null ? Color(tag) : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(child: Text(profile.name, overflow: TextOverflow.ellipsis)),
          if (profile.readOnly) ...[
            const SizedBox(width: 8),
            const _Badge(label: 'read-only', icon: Icons.lock_outline),
          ],
        ],
      ),
      subtitle: Text(profile.subtitle, style: monoFont.copyWith(fontSize: 12)),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        onPressed: () => _showActions(context),
      ),
      onTap: () => _connect(context),
    );
  }

  static String _engineInitials(Engine engine) => switch (engine) {
        Engine.sqlserver => 'MS',
        Engine.postgres => 'PG',
        Engine.mysql => 'My',
        Engine.sqlite => 'Lt',
      };

  Future<void> _connect(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    String? passwordOverride;
    bool remember = false;

    // Only prompt when there is nothing stored. Asking every time would train
    // the user to type their production password into any dialog that appears.
    final needsPassword = profile.engine != Engine.sqlite &&
        profile.rawDsn.isEmpty &&
        !await state.connections.hasPassword(profile.id);

    if (needsPassword) {
      if (!context.mounted) return;
      final entered = await _promptForPassword(context, profile);
      if (entered == null) return;
      passwordOverride = entered.password;
      remember = entered.remember;
    }

    final ok = await state.connect(
      profile,
      passwordOverride: passwordOverride,
      remember: remember,
    );

    if (!ok) {
      messenger.showSnackBar(SnackBar(
        content: Text(state.connectionError),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    navigator.push(
      MaterialPageRoute(builder: (_) => const WorkspaceScreen()),
    );
  }

  Future<({String password, bool remember})?> _promptForPassword(
    BuildContext context,
    ConnectionProfile profile,
  ) {
    final controller = TextEditingController();
    var remember = true;
    var obscure = true;

    return showDialog<({String password, bool remember})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(profile.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'Password for ${profile.user}',
                  suffixIcon: IconButton(
                    icon: Icon(obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => obscure = !obscure),
                  ),
                ),
                onSubmitted: (value) => Navigator.of(context)
                    .pop((password: value, remember: remember)),
              ),
              CheckboxListTile(
                value: remember,
                onChanged: (value) => setState(() => remember = value ?? false),
                title: const Text('Save to keystore'),
                subtitle: const Text('Stored by the phone, not in a file.'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context)
                  .pop((password: controller.text, remember: remember)),
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onEdit();
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Duplicate'),
              onTap: () async {
                final state = context.read<AppState>();
                Navigator.of(sheetContext).pop();
                await state.connections.save(
                  ConnectionProfile(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    name: '${profile.name} copy',
                    engine: profile.engine,
                    host: profile.host,
                    port: profile.port,
                    database: profile.database,
                    user: profile.user,
                    file: profile.file,
                    tls: profile.tls,
                    readOnly: profile.readOnly,
                    connectTimeoutSeconds: profile.connectTimeoutSeconds,
                    params: profile.params,
                    rawDsn: profile.rawDsn,
                    colorTag: profile.colorTag,
                  ),
                );
                // The duplicate deliberately carries no password: copying a
                // credential to a new profile the user did not type it into
                // is not a favour.
                state.refresh();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              textColor: Theme.of(context).colorScheme.error,
              iconColor: Theme.of(context).colorScheme.error,
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Delete ${profile.name}?'),
                    content: const Text(
                      'The saved password is removed from the keystore too. '
                      'The database itself is not touched.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                final state = context.read<AppState>();
                await state.connections.delete(profile.id);
                state.refresh();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
