import 'dart:convert';
import 'dart:io';

import 'package:app_uth/models/campus_model.dart';
import 'package:app_uth/models/edificio_model.dart';
import 'package:app_uth/services/geo_math_service.dart';
import 'package:app_uth/services/ruta_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

/// Pruebas con los datos REALES del campus: andadores y puertas
/// (assets/campus/campus_uth.json) y los 23 edificios de la BD
/// (test/fixtures/edificios_uth.json).
void main() {
  final campus = CampusDatos.fromJson(
      jsonDecode(File('assets/campus/campus_uth.json').readAsStringSync()));
  final edificios = Edificio.listFromJson(
      jsonDecode(File('test/fixtures/edificios_uth.json').readAsStringSync()));
  Edificio ed(String codigo) => edificios.firstWhere((e) => e.codigo == codigo);
  LatLng puerta(String codigo) {
    final c = ed(codigo).entradaPrincipal!;
    return LatLng(c.latitud, c.longitud);
  }

  final principal = campus.accesos
      .firstWhere((a) => a.tipo == TipoAcceso.peatonal)
      .punto;

  RutaService servicio() {
    // Sin internet: OSRM siempre falla (la prueba no depende de la red).
    final s = RutaService(client: MockClient((_) async => http.Response('', 503)));
    s.configurar(campus, edificios);
    return s;
  }

  double aLaPuerta(List<LatLng> ruta) => ruta
      .map((p) => GeoMathService.haversineDistance(
          p.latitude, p.longitude, principal.latitude, principal.longitude))
      .reduce((a, b) => a < b ? a : b);

  test('dentro del campus: todas las puertas conectadas, ninguna ruta cruza', () {
    final s = servicio();
    var total = 0;
    for (final a in edificios) {
      for (final b in edificios) {
        if (a == b) continue;
        final r = s.grafo!.ruta(puerta(a.codigo), puerta(b.codigo));
        expect(r, isNotNull, reason: '${a.codigo} → ${b.codigo}');
        expect(s.grafo!.cruzaEdificio(r!), isFalse,
            reason: '${a.codigo} → ${b.codigo}');
        total++;
      }
    }
    expect(total, edificios.length * (edificios.length - 1));
  });

  test('en la banqueta de De los Seris junto a los autos: entra por la PUERTA PEATONAL', () async {
    final s = servicio();
    const enLaCalle = LatLng(29.00878, -110.90345); // frente a la caseta de autos
    expect(s.estaFuera(enLaCalle), isTrue);
    final r = (await s.calcular(enLaCalle, puerta('EDIF-B')))!;
    expect(aLaPuerta(r.puntos), lessThan(3), reason: 'pasa por la puerta principal');
    expect(s.grafo!.cruzaEdificio(r.puntos), isFalse);
  });

  test('desde lejos (sin internet): recto a la puerta peatonal y luego andadores', () async {
    final s = servicio();
    const casa = LatLng(29.0700, -110.9600);
    expect(s.estaFuera(casa), isTrue);
    final r = (await s.calcular(casa, puerta('EDIF-E')))!;
    expect(r.puntos.first, casa);
    expect(r.puntos[1], principal, reason: 'el primer tramo termina en la puerta');
    expect(r.puntos.last, puerta('EDIF-E'));
  });

  test('desde lejos con OSRM que entra por la rampa de autos: se recorta', () async {
    // OSRM simulado: baja por De los Seris y se mete por la entrada de autos
    // (Del Ingeniero) hasta adentro del campus.
    final s = RutaService(client: MockClient((_) async => http.Response(jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'geometry': {
                'coordinates': [
                  [-110.9600, 29.0700],
                  [-110.9046, 29.0113],
                  [-110.9036, 29.0094],
                  [-110.90345, 29.00878], // frente a la caseta
                  [-110.9025, 29.00875], // ya dentro (rampa de autos)
                  [-110.9016, 29.00876],
                ],
              },
            },
          ],
        }), 200)))
      ..configurar(campus, edificios);
    final r = (await s.calcular(const LatLng(29.0700, -110.9600), puerta('EDIF-E')))!;
    final entrada = campus.accesos
        .firstWhere((a) => a.nombre.toLowerCase().contains('entrada'))
        .punto;
    for (final p in r.puntos) {
      expect(
          GeoMathService.haversineDistance(
              p.latitude, p.longitude, entrada.latitude, entrada.longitude),
          greaterThan(15),
          reason: 'a pie nunca pasa por la entrada de autos');
    }
    expect(aLaPuerta(r.puntos), lessThan(3), reason: 'entra por la peatonal');
    expect(s.grafo!.cruzaEdificio(r.puntos), isFalse);
  });

  test('parada de camión: está en el mapa y no cuenta como puerta', () {
    final parada = campus.accesos.where((a) => a.esParada).toList();
    expect(parada.map((p) => p.nombre),
        containsAll(['Parada Línea 4 Periférico', 'Parada Línea 4 Centro']));
    expect(parada.every((p) => !p.esPeatonal && !p.esVehicular && p.validado), isTrue);
  });

  test('ya adentro: no sale a la calle ni da la vuelta por la puerta', () async {
    final s = servicio();
    final cerca = puerta('EDIF-M');
    expect(s.estaFuera(cerca), isFalse);
    final r = (await s.calcular(cerca, puerta('EDIF-C')))!;
    expect(r.origen, OrigenRuta.andadores);
    expect(RutaService.largo(r.puntos), lessThan(200));
  });
}
