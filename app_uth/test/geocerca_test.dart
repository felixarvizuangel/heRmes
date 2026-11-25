import 'dart:convert';

import 'package:app_uth/models/edificio_model.dart';
import 'package:app_uth/services/api_service.dart';
import 'package:app_uth/services/geo_math_service.dart';
import 'package:app_uth/services/geocerca_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.0001° de latitud ≈ 11.1 m.
const double _m11 = 0.0001;

Edificio _edificio(int id, String nombre, double lat, double lon,
    {int radio = 20, List<List<double>> extra = const []}) {
  return Edificio.fromJson({
    'id': id,
    'codigo': 'EDIF-$id',
    'nombre': nombre,
    'categoria': 'ACADEMICO',
    'radio_cobertura_m': radio,
    'activo': true,
    'coordenadas': [
      {'id': id * 10, 'tipo': 'ENTRADA_PRINCIPAL', 'latitud': lat, 'longitud': lon, 'orden': 0},
      for (var i = 0; i < extra.length; i++)
        {'id': id * 10 + i + 1, 'tipo': 'PERIMETRO', 'latitud': extra[i][0], 'longitud': extra[i][1], 'orden': i + 1},
    ],
  });
}

void main() {
  group('GeoMathService', () {
    test('Haversine: 0.0001° de latitud ≈ 11.1 m', () {
      final d = GeoMathService.haversineDistance(29.1, -110.9, 29.1 + _m11, -110.9);
      expect(d, closeTo(11.12, 0.05));
    });

    test('rumbo con atan2: N=0, E=90, S=180, O=270', () {
      expect(GeoMathService.initialBearing(0, 0, 1, 0), closeTo(0, 1e-9));
      expect(GeoMathService.initialBearing(0, 0, 0, 1), closeTo(90, 1e-9));
      expect(GeoMathService.initialBearing(0, 0, -1, 0), closeTo(180, 1e-9));
      expect(GeoMathService.initialBearing(0, 0, 0, -1), closeTo(270, 1e-9));
    });

    test('aguja mod 360: destino 10°, teléfono 350° → 20°', () {
      expect(GeoMathService.needleRotation(10, 350), closeTo(20, 1e-9));
      expect(GeoMathService.quadrantText(10, 350), 'Al frente');
      expect(GeoMathService.quadrantText(0, 90), 'A tu izquierda');
    });
  });

  group('GeocercaService (Modo B)', () {
    final k = _edificio(1, 'Edificio K', 29.1, -110.9);
    final c = _edificio(2, 'Cafetería', 29.2, -110.9);

    test('fuera del radio no avisa, pero reporta el más cercano', () {
      final g = GeocercaService();
      final r = g.evaluar([k, c], 29.1 + 3 * _m11, -110.9); // ~33 m
      expect(r.nuevo, isNull);
      expect(r.masCercano!.edificio.nombre, 'Edificio K');
      expect(r.masCercano!.distancia, closeTo(33.4, 0.5));
    });

    test('al entrar al radio avisa UNA sola vez', () {
      final g = GeocercaService();
      final r1 = g.evaluar([k, c], 29.1 + _m11, -110.9); // ~11 m
      expect(r1.nuevo!.edificio.nombre, 'Edificio K');
      final r2 = g.evaluar([k, c], 29.1 + 0.5 * _m11, -110.9); // sigue dentro
      expect(r2.nuevo, isNull);
    });

    test('histéresis: entre radio y radio+5 m no se re-arma', () {
      final g = GeocercaService();
      g.evaluar([k], 29.1 + _m11, -110.9); // avisa a ~11 m
      g.evaluar([k], 29.1 + 0.0002, -110.9); // ~22 m: fuera de 20 pero < 25
      final r = g.evaluar([k], 29.1 + _m11, -110.9); // vuelve a entrar
      expect(r.nuevo, isNull, reason: 'el ruido del GPS no repite el aviso');
    });

    test('al salir más de radio+5 m se re-arma y vuelve a avisar', () {
      final g = GeocercaService();
      g.evaluar([k], 29.1 + _m11, -110.9);
      g.evaluar([k], 29.1 + 0.0003, -110.9); // ~33 m > 25 m
      final r = g.evaluar([k], 29.1 + _m11, -110.9);
      expect(r.nuevo!.edificio.nombre, 'Edificio K');
    });

    test('usa TODOS los puntos: el perímetro también cuenta', () {
      final grande = _edificio(3, 'Gimnasio', 29.1, -110.9,
          extra: [[29.1010, -110.9]]); // costado a ~111 m de la entrada
      final g = GeocercaService();
      final r = g.evaluar([grande], 29.1010 + _m11, -110.9); // junto al costado
      expect(r.nuevo!.edificio.nombre, 'Gimnasio');
      expect(r.nuevo!.punto.tipo, TipoCoordenada.perimetro);
    });

    test('respeta radio_cobertura_m de cada edificio', () {
      final chico = _edificio(4, 'Caseta', 29.1, -110.9, radio: 10);
      final g = GeocercaService();
      expect(g.evaluar([chico], 29.1 + _m11, -110.9).nuevo, isNull); // 11 > 10
    });

    test('con el detalle abierto no se gasta el aviso', () {
      final g = GeocercaService();
      final r1 = g.evaluar([k], 29.1 + _m11, -110.9, registrarAviso: false);
      expect(r1.nuevo, isNotNull);
      final r2 = g.evaluar([k], 29.1 + _m11, -110.9);
      expect(r2.nuevo, isNotNull, reason: 'se avisa al volver del detalle');
    });
  });

  test('búsqueda sin acentos: "cafeteria" encuentra "Cafetería"', () {
    final e = Edificio.fromJson({
      'id': 9, 'codigo': 'EDIF-M', 'nombre': 'Comedor',
      'palabras_clave': ['cafetería'], 'coordenadas': [],
    });
    expect(e.coincide('cafeteria'), isTrue);
    expect(e.coincide('CAFETERÍA'), isTrue);
    expect(e.coincide('biblioteca'), isFalse);
  });

  test('ApiService: una sola petición por sesión, luego datos locales', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    var peticiones = 0;
    final api = ApiService(
      client: MockClient((_) async {
        peticiones++;
        return http.Response.bytes(
            utf8.encode(jsonEncode([_edificio(1, 'K', 29.1, -110.9).toJson()])), 200);
      }),
    );
    await api.obtenerEdificios();
    await api.obtenerEdificios(); // radar
    await api.obtenerEdificios(); // mapa
    expect(peticiones, 1);
    await api.obtenerEdificios(forzarRed: true); // botón Sincronizar
    expect(peticiones, 2);
  });
}
