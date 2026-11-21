import 'package:app_uth/theme/uth_themes.dart';
import 'package:app_uth/widgets/nombre_hermes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// En TODOS los temas, el nombre se debe leer en la barra y en el cuerpo.
void main() {
  for (final t in UthTemas.todos) {
    for (final enBarra in [true, false]) {
      testWidgets('${t.id} · ${enBarra ? 'barra' : 'cuerpo'}', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: t.data,
          home: Scaffold(
            appBar: AppBar(title: enBarra ? const NombreHermes(enBarra: true) : null),
            body: enBarra ? null : const NombreHermes(),
          ),
        ));
        final tema = Theme.of(tester.element(find.byType(NombreHermes)));
        final fondo = enBarra
            ? (tema.appBarTheme.backgroundColor ?? tema.colorScheme.surface)
            : tema.scaffoldBackgroundColor;
        final rich = tester.widget<RichText>(find.descendant(
            of: find.byType(NombreHermes), matching: find.byType(RichText)));
        final envoltura = rich.text as TextSpan; // Text.rich envuelve el span
        final raiz = envoltura.children!.first as TextSpan;
        final r = (raiz.children![1] as TextSpan).style!.color!;
        expect(NombreHermes.contraste(raiz.style!.color!, fondo), greaterThanOrEqualTo(4.5),
            reason: 'he/mes');
        expect(NombreHermes.contraste(r, fondo), greaterThanOrEqualTo(3.0), reason: 'R');
      });
    }
  }
}
