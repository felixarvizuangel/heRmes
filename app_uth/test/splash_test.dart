import 'dart:convert';

import 'package:app_uth/screens/splash_screen.dart';
import 'package:app_uth/services/api_service.dart';
import 'package:app_uth/theme/tema_controller.dart';
import 'package:app_uth/widgets/hermes_cargando.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  HermesCargando.animar = false;
  testWidgets('splash: radar animado → bienvenida con una sola descarga', (t) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    var peticiones = 0;
    final api = ApiService(client: MockClient((_) async {
      peticiones++;
      return http.Response.bytes(utf8.encode(jsonEncode([
        {'id': 1, 'codigo': 'EDIF-K', 'nombre': 'Edificio K', 'categoria': 'ACADEMICO', 'activo': true,
         'coordenadas': [{'id': 1, 'tipo': 'ENTRADA_PRINCIPAL', 'latitud': 29.1, 'longitud': -110.9, 'orden': 0}]},
      ])), 200);
    }));
    await t.pumpWidget(TemaScope(
      controller: TemaController.enMemoria(),
      child: MaterialApp(home: SplashScreen(apiService: api)),
    ));
    expect(find.byType(HermesCargando), findsOneWidget);
    expect(find.text('Trazando los caminos del campus…'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 2300)); // mínimo de la animación
    await t.pumpAndSettle();
    expect(find.text('¿A dónde quieres ir?'), findsOneWidget);
    expect(find.textContaining('1 lugares guardados'), findsOneWidget);
    expect(peticiones, 1, reason: 'la bienvenida reutiliza lo que bajó el splash');
  });
}
