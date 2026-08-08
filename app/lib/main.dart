import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/native_core.dart';
import 'data/connection_store.dart';
import 'state/app_state.dart';
import 'ui/connections_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final client = await CoreClient.start();
  final state = AppState(
    client: client,
    connections: ConnectionStore(),
    history: QueryHistoryStore(),
  );
  await state.init();

  runApp(DbCrawlerApp(state: state));
}

class DbCrawlerApp extends StatelessWidget {
  const DbCrawlerApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        title: 'DB Crawler',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const _Root(),
      ),
    );
  }
}

/// Closes the database connection when the app is backgrounded for real.
///
/// A phone suspends an app aggressively, and a TCP connection that survives
/// being suspended for ten minutes is the exception, not the rule. Holding a
/// dead socket open means the next query fails with a confusing driver error;
/// closing it means the app knows it is disconnected and can say so.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `paused` fires for a lock screen too, which is far too eager — being
    // disconnected every time the screen times out would make the app
    // unusable. `detached` is the app actually going away.
    if (state == AppLifecycleState.detached) {
      context.read<AppState>().disconnect();
    }
  }

  @override
  Widget build(BuildContext context) => const ConnectionsScreen();
}
