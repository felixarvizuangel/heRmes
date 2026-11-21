import 'package:app_uth/models/edificio_model.dart';
import 'package:app_uth/widgets/foto_fachada.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Edificio _e(String codigo) => Edificio.fromJson({
      'id': 1, 'codigo': codigo, 'nombre': codigo, 'coordenadas': [],
    });

void main() {
  testWidgets('con fachada: Fachada + Desde arriba para deslizar', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: GaleriaEdificio(edificio: _e('EDIF-A')))));
    expect(find.text('Fachada · desliza'), findsOneWidget);
    expect(find.text(FotoFachada.creditoFachada), findsOneWidget);
    await t.drag(find.byType(PageView), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(find.text('Desde arriba · desliza'), findsOneWidget);
    expect(find.text(FotoFachada.creditoAerea), findsOneWidget);
  });

  testWidgets('sin fachada (Biblioteca): solo la vista aérea', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: GaleriaEdificio(edificio: _e('EDIF-C')))));
    expect(find.text('Desde arriba'), findsOneWidget);
    expect(find.text(FotoFachada.creditoAerea), findsOneWidget);
    expect(FotoFachada.tieneFoto(_e('EDIF-C')), isFalse);
  });
}
