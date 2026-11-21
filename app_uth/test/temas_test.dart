import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_uth/theme/uth_themes.dart';
import 'package:app_uth/theme/tema_controller.dart';

void main() {
  test('20 temas, ids únicos, contraste AA', () {
    expect(UthTemas.todos.length, 20);
    expect(UthTemas.todos.map((t) => t.id).toSet().length, 20);
    final c = UthTema.contraste;
    for (final t in UthTemas.todos) {
      final s = t.data.colorScheme;
      final u = t.colores;
      final ab = t.data.appBarTheme;
      final checks = {
        'onSurface': c(s.onSurface, s.surface) >= 7,
        'onSurfaceVariant': c(s.onSurfaceVariant, s.surfaceContainerHighest) >= 4.5,
        'primary': c(s.primary, s.surface) >= 4.5,
        'onPrimary': c(s.onPrimary, s.primary) >= 4.5,
        'tertiary': c(s.tertiary, s.surface) >= 4.5,
        'onTertiaryContainer': c(s.onTertiaryContainer, s.tertiaryContainer) >= 4.5,
        'onSecondaryContainer': c(s.onSecondaryContainer, s.secondaryContainer) >= 4.5,
        'onPrimaryContainer': c(s.onPrimaryContainer, s.primaryContainer) >= 4.5,
        'error': c(s.error, s.surface) >= 4.5,
        'outline': c(s.outline, s.surface) >= 3,
        'appbar': c(ab.foregroundColor!, ab.backgroundColor!) >= 4.5,
        'aguja': c(u.aguja, s.surface) >= 3,
        'llegada': c(u.sobreLlegada, u.llegada) >= 4.5,
      };
      final fallos = checks.entries.where((e) => !e.value).map((e) => e.key);
      expect(fallos, isEmpty, reason: t.nombre);
    }
  });

  testWidgets('selector cambia tema en caliente', (tester) async {
    final temas = TemaController.enMemoria();
    await tester.pumpWidget(TemaScope(
      controller: temas,
      child: ListenableBuilder(
        listenable: temas,
        builder: (_, __) => MaterialApp(
          theme: temas.actual.data,
          home: Scaffold(appBar: AppBar(actions: const [BotonTemas()])),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.palette_outlined));
    await tester.pumpAndSettle();
    expect(find.text('1. Navy Lima'), findsOneWidget);
    await tester.tap(find.byTooltip('Siguiente'));
    await tester.pumpAndSettle();
    expect(temas.actual.id, 'navy_lima_noche');
    await tester.tap(find.text('5. Cosmic Lima'));
    await tester.pumpAndSettle();
    expect(temas.actual.id, 'cosmic_lima');
    await tester.longPress(find.byIcon(Icons.palette_outlined).first, warnIfMissed: false);
  });
}
