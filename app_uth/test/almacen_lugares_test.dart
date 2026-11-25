import 'dart:convert';
import 'dart:io';

import 'package:app_uth/services/almacen_lugares.dart';
import 'package:app_uth/models/edificio_model.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pruebas de [AlmacenLugares] con el almacenamiento seguro simulado.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Edificio> catalogo;

  setUpAll(() {
    final raw = File('test/fixtures/edificios_uth.json').readAsStringSync();
    catalogo = Edificio.listFromJson(jsonDecode(raw));
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('sin nada guardado devuelve null', () async {
    final almacen = AlmacenLugares();
    expect(await almacen.hayCatalogo(), isFalse);
    expect(await almacen.leerEdificios(), isNull);
    expect(await almacen.leerFechaSincronizacion(), isNull);
    expect(await almacen.leerCampus(), isNull);
  });

  test('guarda y lee el catálogo con sus puntos GPS', () async {
    final almacen = AlmacenLugares();
    final fecha = DateTime(2026, 11, 25, 16, 30);
    await almacen.guardarEdificios(catalogo, fecha);

    final leidos = await almacen.leerEdificios();
    expect(leidos, isNotNull);
    expect(leidos!.length, catalogo.length);
    expect(leidos.first.codigo, catalogo.first.codigo);
    expect(leidos.first.coordenadas.length, catalogo.first.coordenadas.length);
    expect(leidos.first.coordenadas.first.latitud,
        catalogo.first.coordenadas.first.latitud);
    expect(await almacen.leerFechaSincronizacion(), fecha);
    expect(await almacen.hayCatalogo(), isTrue);
  });

  test('busca por código y devuelve sus coordenadas', () async {
    final almacen = AlmacenLugares();
    await almacen.guardarEdificios(catalogo, DateTime.now());
    final codigo = catalogo.first.codigo.toLowerCase();
    expect((await almacen.buscarPorCodigo(codigo))?.nombre,
        catalogo.first.nombre);
    expect(await almacen.coordenadasDe(codigo), isNotEmpty);
    expect(await almacen.buscarPorCodigo('NO-EXISTE'), isNull);
  });

  test('texto dañado se descarta y se lee como vacío', () async {
    FlutterSecureStorage.setMockInitialValues(
        {AlmacenLugares.kEdificios: '{no es json'});
    final almacen = AlmacenLugares();
    expect(await almacen.leerEdificios(), isNull);
    expect(await almacen.hayCatalogo(), isFalse);
  });

  test('borrarTodo deja el dispositivo limpio', () async {
    final almacen = AlmacenLugares();
    await almacen.guardarEdificios(catalogo, DateTime.now());
    await almacen.borrarTodo();
    expect(await almacen.hayCatalogo(), isFalse);
    expect(await almacen.leerFechaSincronizacion(), isNull);
  });
}
