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

  static final _themes = <(Brightness, Color), ThemeData>{};

  /// Cached: the app rebuilds on every store change while a reply streams.
  static ThemeData theme(Brightness brightness, {Color seed = const Color(0xFF6750A4)}) =>
      _themes.putIfAbsent((brightness, seed), () => _build(brightness, seed));

  static ThemeData _build(Brightness brightness, Color seed) {
    final cs = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
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
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final s = store.settings;
            final seed = Color(s.seedColor);
            return MaterialApp(
              title: 'ZchatBot',
              debugShowCheckedModeBanner: false,
              theme: theme(Brightness.light, seed: seed),
              darkTheme: theme(Brightness.dark, seed: seed),
              themeMode: switch (s.themeMode) {
                'light' => ThemeMode.light,
                'dark' => ThemeMode.dark,
                _ => ThemeMode.system,
              },
              builder: (context, child) {
                final mq = MediaQuery.of(context);
                return MediaQuery(
                  data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * s.textScale)),
                  child: child!,
                );
              },
              home: const Home(),
            );
          },
        ),
      );
}
