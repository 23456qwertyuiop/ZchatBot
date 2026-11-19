import 'package:material_ui/material_ui.dart';

import 'core/store.dart';
import 'ui/home.dart';
import 'ui/scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ZchatApp(store: await AppStore.load()));
}

class ZchatApp extends StatelessWidget {
  const ZchatApp({super.key, required this.store});
  final AppStore store;

  static ThemeData theme(Brightness brightness) {
    final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4), brightness: brightness);
    return ThemeData(
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      listTileTheme: const ListTileThemeData(shape: StadiumBorder()),
      appBarTheme: AppBarTheme(backgroundColor: cs.surface, scrolledUnderElevation: 0),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scope(
        store: store,
        child: MaterialApp(
          title: 'ZchatBot',
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          home: const Home(),
        ),
      );
}
