import 'package:app_uth/widgets/hermes_cargando.dart';
import 'dart:convert';
import 'package:app_uth/models/edificio_model.dart';
import 'package:app_uth/screens/welcome_screen.dart';
import 'package:app_uth/services/api_service.dart';
import 'package:app_uth/theme/tema_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  HermesCargando.animar = false;
  final json = [
    {'id':1,'codigo':'EDIF-K','nombre':'Edificio K','categoria':'ACADEMICO','dependencias':['Biblioteca'],'palabras_clave':['libros'],'radio_cobertura_m':20,'activo':true,
     'coordenadas':[{'id':1,'tipo':'ENTRADA_PRINCIPAL','latitud':29.1,'longitud':-110.9,'orden':0}]},
    {'id':2,'codigo':'EDIF-C','nombre':'Cafetería','categoria':'SERVICIOS','dependencias':[],'palabras_clave':['comida'],'radio_cobertura_m':20,'activo':true,
     'coordenadas':[{'id':2,'tipo':'ENTRADA_PRINCIPAL','latitud':29.2,'longitud':-110.9,'orden':0}]},
  ];
  testWidgets('bienvenida → directorio → detalle', (t) async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiService(client: MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(json)), 200)));
    await t.pumpWidget(TemaScope(controller: TemaController.enMemoria(), child: MaterialApp(home: WelcomeScreen(apiService: api))));
    await t.pumpAndSettle();
    expect(find.textContaining('2 lugares guardados'), findsOneWidget);
    expect(find.text('¿A dónde quieres ir?'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Buscar un lugar'), 200); // la pantalla de prueba (800x600) es más baja que un teléfono
    await t.tap(find.text('Buscar un lugar'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'comida');
    await t.pumpAndSettle();
    expect(find.text('Cafetería'), findsOneWidget);
    expect(find.text('Edificio K'), findsNothing);
    await t.tap(find.text('Cafetería'));
    await t.pumpAndSettle();
    expect(find.text('Navegar aquí'), findsOneWidget);
    await t.pageBack(); await t.pumpAndSettle();
    await t.pageBack(); await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Ver\nedificios'), 200);
    await t.tap(find.text('Ver\nedificios'));
    await t.pumpAndSettle();
    await t.tap(find.text('Académico'));
    await t.pumpAndSettle();
    expect(find.text('Edificio K'), findsOneWidget);
    expect(find.text('Cafetería'), findsNothing);
  });
  test('distanciaMinima detecta a <20 m', () {
    final e = Edificio.listFromJson(json).first;
    expect(e.distanciaMinima(29.1001, -110.9) <= 20, isTrue); // ~11 m
    expect(e.distanciaMinima(29.1003, -110.9) <= 20, isFalse); // ~33 m
  });
}
