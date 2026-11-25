import 'dart:convert';
import 'dart:io';
import 'dart:math' show sqrt;

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
    expect(r.origen.vieneDeAfuera, isFalse);
    expect(RutaService.largo(r.puntos), lessThan(200));
  });

  group('barda del campus (punto en polígono)', () {
    test('la copia local trae el perímetro y todo edificio cae adentro', () {
      expect(campus.perimetro.length, greaterThanOrEqualTo(3));
      final s = servicio();
      expect(s.tieneBarda, isTrue);
      for (final e in edificios) {
        for (final c in e.coordenadas) {
          expect(s.dentroDelCampus(LatLng(c.latitud, c.longitud)), isTrue,
              reason: '${e.codigo} ${c.tipo}');
        }
      }
      expect(s.dentroDelCampus(principal), isTrue, reason: 'puerta peatonal');
      expect(s.estaFuera(const LatLng(29.00878, -110.90345)), isTrue,
          reason: 'banqueta de De los Seris');
      expect(s.estaFuera(const LatLng(29.0700, -110.9600)), isTrue);
    });

    test('ninguna ruta interior se sale de la barda', () {
      final s = servicio();
      for (final a in edificios) {
        for (final b in edificios) {
          if (a == b) continue;
          final r = s.grafo!.ruta(puerta(a.codigo), puerta(b.codigo))!;
          for (final p in r) {
            expect(distanciaAfuera(campus.perimetro, p), lessThan(8.5),
                reason: '${a.codigo} → ${b.codigo} sale en $p');
          }
        }
      }
    });

    test('adentro rumbo al Edificio P: solo andadores, sin OSRM ni puerta', () async {
      var peticiones = 0;
      final s = RutaService(client: MockClient((_) async {
        peticiones++;
        return http.Response('', 503);
      }))
        ..configurar(campus, edificios);
      final destino = puerta('EDIF-P');
      // Rejilla de ~30 m sobre todo el campus: cada punto que cae dentro de
      // la barda (y fuera de un edificio) debe ir directo por andadores.
      var probados = 0;
      for (var lat = 29.0060; lat <= 29.0112; lat += 0.00027) {
        for (var lon = -110.9036; lon <= -110.8990; lon += 0.00031) {
          final u = LatLng(lat, lon);
          if (!s.dentroDelCampus(u) || distanciaAfuera(campus.perimetro, u) > -6) {
            continue; // fuera, o pegado a la barda (ruido del GPS)
          }
          if (edificios.any((e) => dentroDe(e.poligono, u))) continue;
          final r = await s.calcular(u, destino);
          if (r == null) continue;
          probados++;
          expect(r.origen, OrigenRuta.andadores, reason: '$u');
          for (final p in r.puntos) {
            expect(distanciaAfuera(campus.perimetro, p), lessThan(8.5),
                reason: 'desde $u la ruta sale del campus en $p');
          }
        }
      }
      expect(probados, greaterThan(100));
      expect(peticiones, 0, reason: 'adentro nunca se consulta OSRM');
    });

    test('desde afuera se marca que viene de afuera', () async {
      final s = servicio();
      final r = (await s.calcular(const LatLng(29.00878, -110.90345), puerta('EDIF-P')))!;
      expect(r.origen.vieneDeAfuera, isTrue);
      expect(aLaPuerta(r.puntos), lessThan(3));
    });

    test('sin barda (backend viejo) se usa la regla de respaldo', () {
      final s = RutaService(client: MockClient((_) async => http.Response('', 503)))
        ..configurar(
            CampusDatos(accesos: campus.accesos, andadores: campus.andadores),
            edificios);
      expect(s.tieneBarda, isFalse);
      expect(s.estaFuera(puerta('EDIF-M')), isFalse);
      expect(s.estaFuera(const LatLng(29.0700, -110.9600)), isTrue);
    });
  });
}

/// Ray casting en grados (solo para las pruebas).
bool dentroDe(List<LatLng> poli, LatLng p) {
  var dentro = false;
  for (var i = 0, j = poli.length - 1; i < poli.length; j = i++) {
    final a = poli[i], b = poli[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude)) {
      final x = a.longitude +
          (p.latitude - a.latitude) *
              (b.longitude - a.longitude) /
              (b.latitude - a.latitude);
      if (p.longitude < x) dentro = !dentro;
    }
  }
  return dentro;
}

/// Metros que [p] queda FUERA de la barda (negativo = adentro).
double distanciaAfuera(List<LatLng> barda, LatLng p) {
  const mLat = 111320.0;
  final mLon = mLat * 0.8746; // cos(29.01°)
  var minima = double.infinity;
  for (var i = 0, j = barda.length - 1; i < barda.length; j = i++) {
    final ax = (barda[j].longitude - p.longitude) * mLon;
    final ay = (barda[j].latitude - p.latitude) * mLat;
    final bx = (barda[i].longitude - p.longitude) * mLon;
    final by = (barda[i].latitude - p.latitude) * mLat;
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    final t = l2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / l2).clamp(0.0, 1.0);
    final x = ax + t * dx, y = ay + t * dy;
    final d = (x * x + y * y);
    if (d < minima) minima = d;
  }
  final d = minima == double.infinity ? 0.0 : sqrt(minima);
  return dentroDe(barda, p) ? -d : d;
}
