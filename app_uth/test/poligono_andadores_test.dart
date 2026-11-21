import 'dart:convert';

import 'package:app_uth/models/campus_model.dart';
import 'package:app_uth/models/edificio_model.dart';
import 'package:app_uth/services/api_service.dart';
import 'package:app_uth/services/aviso_service.dart';
import 'package:app_uth/services/geocerca_service.dart';
import 'package:app_uth/services/geometria.dart';
import 'package:app_uth/services/grafo_andadores.dart';
import 'package:app_uth/services/ruta_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.0001° de latitud ≈ 11.1 m; de longitud (a 29°) ≈ 9.7 m.
const double _lat0 = 29.0;
const double _lon0 = -110.9;

/// Edificio rectangular: esquinas (lat1,lon1)-(lat2,lon2), puerta en [puerta].
Edificio _rect(int id, String codigo, double la1, double lo1, double la2,
    double lo2, List<double> puerta,
    {int radio = 20}) {
  return Edificio.fromJson({
    'id': id,
    'codigo': codigo,
    'nombre': 'Lugar $codigo',
    'categoria': 'ACADEMICO',
    'radio_cobertura_m': radio,
    'activo': true,
    'coordenadas': [
      {'id': id * 10, 'tipo': 'ENTRADA_PRINCIPAL', 'latitud': puerta[0], 'longitud': puerta[1], 'orden': 0},
      {'id': id * 10 + 1, 'tipo': 'PERIMETRO', 'latitud': la1, 'longitud': lo1, 'orden': 1},
      {'id': id * 10 + 2, 'tipo': 'PERIMETRO', 'latitud': la1, 'longitud': lo2, 'orden': 2},
      {'id': id * 10 + 3, 'tipo': 'PERIMETRO', 'latitud': la2, 'longitud': lo2, 'orden': 3},
      {'id': id * 10 + 4, 'tipo': 'PERIMETRO', 'latitud': la2, 'longitud': lo1, 'orden': 4},
    ],
  });
}

void main() {
  group('Geometría', () {
    final cuadro = [const Xy(0, 0), const Xy(10, 0), const Xy(10, 10), const Xy(0, 10)];

    test('punto en polígono (ray casting)', () {
      expect(Geometria.puntoEnPoligono(const Xy(5, 5), cuadro), isTrue);
      expect(Geometria.puntoEnPoligono(const Xy(15, 5), cuadro), isFalse);
      expect(Geometria.puntoEnPoligono(const Xy(-1, -1), cuadro), isFalse);
    });

    test('segmento que atraviesa vs. que solo llega a la pared', () {
      expect(Geometria.cruzaPoligono(const Xy(-5, 5), const Xy(15, 5), cuadro), isTrue);
      expect(Geometria.cruzaPoligono(const Xy(-5, 5), const Xy(0, 5), cuadro), isFalse);
      expect(Geometria.cruzaPoligono(const Xy(-5, -5), const Xy(-5, 15), cuadro), isFalse);
    });
  });

  group('Geocerca por polígono', () {
    // Edificio grande de ~111 m × ~97 m: con solo puntos la orilla quedaba
    // lejos de todo punto; con el polígono se detecta.
    final grande = _rect(1, 'EDIF-G', _lat0, _lon0, _lat0 + 0.001, _lon0 + 0.001,
        [_lat0, _lon0 + 0.0005]);

    test('dentro del polígono: distancia 0 y "dentro"', () {
      final r = GeocercaService()
          .evaluar([grande], _lat0 + 0.0005, _lon0 + 0.0005); // centro
      expect(r.nuevo, isNotNull);
      expect(r.nuevo!.dentro, isTrue);
      expect(r.nuevo!.distancia, 0);
    });

    test('afuera: mide a la PARED, no solo a las esquinas', () {
      // A 11 m al oeste de la mitad de la pared oeste (esquinas a ~56 m).
      final m = GeocercaService.medir(grande, _lat0 + 0.0005, _lon0 - 0.000115);
      expect(m!.dentro, isFalse);
      expect(m.distancia, closeTo(11.2, 0.6));
    });

    test('anillo de cercanía: fuera del radio no avisa', () {
      final r = GeocercaService().evaluar([grande], _lat0 + 0.0005, _lon0 - 0.0003); // ~29 m
      expect(r.nuevo, isNull);
      expect(r.cercanos, isEmpty);
      expect(r.masCercano!.distancia, closeTo(29.2, 1));
    });

    test('dos o más edificios cerca: TODOS, ordenados por distancia', () {
      // Dos edificios separados por un pasillo de ~22 m; usuario en medio,
      // un poco más cerca del de abajo.
      final abajo = _rect(2, 'EDIF-A', _lat0, _lon0, _lat0 + 0.0003, _lon0 + 0.0003,
          [_lat0 + 0.0003, _lon0 + 0.00015]);
      final arriba = _rect(3, 'EDIF-B', _lat0 + 0.0005, _lon0, _lat0 + 0.0008,
          _lon0 + 0.0003, [_lat0 + 0.0005, _lon0 + 0.00015]);
      final lejos = _rect(4, 'EDIF-C', _lat0 + 0.003, _lon0, _lat0 + 0.0033,
          _lon0 + 0.0003, [_lat0 + 0.003, _lon0 + 0.00015]);
      final g = GeocercaService();
      final r = g.evaluar([arriba, lejos, abajo], _lat0 + 0.00039, _lon0 + 0.00015);
      expect(r.cercanos.map((d) => d.edificio.codigo), ['EDIF-A', 'EDIF-B']);
      expect(r.nuevos.length, 2);
      expect(r.cercanos.first.distancia, lessThan(r.cercanos.last.distancia));
      // Siguen cerca pero ya avisados: lista llena, sin avisos nuevos.
      final r2 = g.evaluar([arriba, lejos, abajo], _lat0 + 0.0004, _lon0 + 0.00015);
      expect(r2.cercanos.length, 2);
      expect(r2.nuevos, isEmpty);
    });
  });

  group('Grafo de andadores', () {
    // Andador en forma de U alrededor de un edificio; la línea recta
    // usuario→puerta atravesaría el edificio.
    //   (0,0)───────(0,60m)
    //     │  [EDIF]   │
    //   (U)          (puerta lado este)
    final edificio = _rect(9, 'EDIF-X', _lat0 + 0.0001, _lon0 + 0.0001,
        _lat0 + 0.0004, _lon0 + 0.0004, [_lat0 + 0.00025, _lon0 + 0.0004]);
    final campus = CampusDatos.fromJson({
      'accesos': [],
      'andadores': [
        {
          'id': 1,
          'tipo': 'ANDADOR',
          'puntos': [
            [_lat0 + 0.00025, _lon0],
            [_lat0 + 0.0005, _lon0],
            [_lat0 + 0.0005, _lon0 + 0.0005],
            [_lat0 + 0.00025, _lon0 + 0.0005],
          ],
        },
      ],
    });
    final grafo = GrafoAndadores.desde(campus, [edificio]);
    const usuario = LatLng(_lat0 + 0.00025, _lon0 - 0.00002);
    final puerta = LatLng(edificio.entradaPrincipal!.latitud, edificio.entradaPrincipal!.longitud);

    test('la línea recta cruza el edificio; la ruta por andadores no', () {
      expect(grafo.cruzaEdificio([usuario, puerta]), isTrue);
      final ruta = grafo.ruta(usuario, puerta)!;
      expect(ruta.first, usuario);
      expect(ruta.last, puerta);
      expect(grafo.cruzaEdificio(ruta), isFalse);
      // Rodea por arriba: ~28 m + ~48 m + ~28 m + ~10 m.
      expect(RutaService.largo(ruta), greaterThan(90));
    });

    test('RutaService.calcular usa el grafo (sin internet)', () async {
      final s = RutaService(client: MockClient((_) async => http.Response('', 500)));
      s.grafo = grafo;
      final r = await s.calcular(usuario, puerta);
      expect(r!.origen, OrigenRuta.andadores);
      s.dispose();
    });

    test('lejos de todo andador no inventa ruta', () {
      expect(grafo.ruta(const LatLng(29.1, -110.9), puerta), isNull);
    });
  });

  test('ApiService.obtenerCampus: una petición y caché local', () async {
    SharedPreferences.setMockInitialValues({});
    var peticiones = 0;
    final api = ApiService(client: MockClient((req) async {
      peticiones++;
      expect(req.url.path, endsWith('/campus/'));
      return http.Response.bytes(utf8.encode(jsonEncode({
        'accesos': [
          {'id': 1, 'nombre': 'Entrada de autos norte', 'tipo': 'VEHICULAR',
           'latitud': '29.011300', 'longitud': '-110.904100', 'validado': false},
          {'id': 2, 'nombre': 'Puerta peatonal', 'tipo': 'PEATONAL',
           'latitud': 29.0084, 'longitud': -110.903, 'validado': true},
        ],
        'andadores': [
          {'id': 1, 'tipo': 'BANQUETA', 'puntos': [[29.0, -110.9], [29.001, -110.9]]},
        ],
      })), 200);
    }));
    final c = await api.obtenerCampus();
    await api.obtenerCampus();
    expect(peticiones, 1);
    expect(c.accesos.first.tipo, TipoAcceso.vehicular);
    expect(c.accesos.first.latitud, closeTo(29.0113, 1e-9));
    expect(c.accesos.last.esPeatonal, isTrue);
    expect(c.andadores.single.puntos.length, 2);

    // Sin red: lo guardado.
    final offline = ApiService(client: MockClient((_) async => throw http.ClientException('x')));
    expect((await offline.obtenerCampus()).accesos.length, 2);
  });

  test('palabras clave sin repetidas por acentos', () {
    final e = Edificio.fromJson({
      'id': 1, 'codigo': 'EDIF-A', 'nombre': 'Rectoría', 'coordenadas': [],
      'palabras_clave': ['rectoria', 'rectoría', 'servicios escolares'],
    });
    expect(e.palabrasVisibles, ['rectoría', 'servicios escolares']);
    expect(e.coincide('rectoria'), isTrue);
  });

  test('AvisoService en pruebas: registra el aviso sin tocar el plugin', () async {
    expect(AvisoService.habilitado, isFalse);
    await AvisoService.instancia.avisar('🏁 Llegaste a EDIF-K', 'Edificio K');
    expect(AvisoService.instancia.historial.last, contains('EDIF-K'));
  });
}
