import 'package:material_ui/material_ui.dart';

import '../core/store.dart';

/// Exposes the [AppStore]; widgets that call [Scope.of] rebuild on change.
class Scope extends InheritedNotifier<AppStore> {
  const Scope({super.key, required AppStore store, required super.child})
      : super(notifier: store);

  static AppStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Scope>()!.notifier!;

  /// Read without subscribing (for callbacks).
  static AppStore read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<Scope>()!.notifier!;
}
