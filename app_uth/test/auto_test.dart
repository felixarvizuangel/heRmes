import 'dart:convert';
import 'dart:io';

import 'package:app_uth/models/campus_model.dart';
import 'package:app_uth/models/edificio_model.dart';
import 'package:app_uth/services/api_service.dart';
import 'package:app_uth/services/auto_service.dart';
import 'package:app_uth/services/ruta_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

/// Respuesta OSRM con dos rutas: la 1ª (más rápida) pasa por el poniente,
/// la 2ª da la vuelta por el oriente.
String _osrm(LatLng a, LatLng b) {
  List<List<double>> linea(double dLon) => [
        [a.longitude, a.latitude],
        [a.longitude + dLon, (a.latitude + b.latitude) / 2],
        [b.longitude, b.latitude],
      ];
  return jsonEncode({
    'code': 'Ok',
    'routes': [
      {'duration': 300, 'geometry': {'coordinates': linea(-0.003)}},
      {'duration': 420, 'geometry': {'coordinates': linea(0.003)}},
    ],
  });
}

void main() {
  final campus = CampusDatos.fromJson(
      jsonDecode(File('assets/campus/campus_uth.json').readAsStringSync()));
  final edificios = Edificio.listFromJson(
      jsonDecode(File('test/fixtures/edificios_uth.json').readAsStringSync()));
  final entrada = campus.accesos
      .firstWhere((a) => a.nombre.toLowerCase().contains('entrada'))
      .punto;
  final e = edificios.firstWhere((x) => x.codigo == 'EDIF-B').entradaPrincipal!;
  final puerta = LatLng(e.latitud, e.longitud);
  const casa = LatLng(29.0300, -110.9200);
  final medio = LatLng((casa.latitude + entrada.latitude) / 2,
      (casa.longitude + entrada.longitude) / 2);

  RutaService pie() => RutaService(client: MockClient((_) async => http.Response('', 503)))
    ..configurar(campus, edificios);

  AutoService auto() =>
      AutoService(client: MockClient((_) async => http.Response(_osrm(casa, entrada), 200)));

  ReporteVial rep(TipoReporte t, LatLng p) => ReporteVial(
      id: 1, tipo: t, descripcion: '', latitud: p.latitude, longitud: p.longitude);

  test('sin reportes: la más rápida, y el tramo a pie entra por andadores', () async {
    final r = (await auto().calcular(
        desde: casa, entradaAutos: entrada, puerta: puerta, pie: pie()))!;
    expect(r.segundosManejo, 300);
    expect(r.manejo.last, entrada);
    expect(r.aPie.first, entrada);
    expect(r.aPie.last, puerta);
    expect(pie().grafo!.cruzaEdificio(r.aPie), isFalse);
  });

  test('calle cerrada en la ruta rápida: elige la alternativa y la avisa vacía', () async {
    final cerrada = rep(TipoReporte.cerrada,
        LatLng(medio.latitude, casa.longitude - 0.003)); // vértice de la ruta 1
    final r = (await auto().calcular(
        desde: casa,
        entradaAutos: entrada,
        puerta: puerta,
        pie: pie(),
        reportes: [cerrada]))!;
    expect(r.segundosManejo, 420, reason: 'evita la calle cerrada');
    expect(r.reportesEnRuta, isEmpty);
  });

  test('bache en las dos rutas: se queda con la rápida y lo reporta', () async {
    final bache = rep(TipoReporte.bache, entrada);
    final r = (await auto().calcular(
        desde: casa,
        entradaAutos: entrada,
        puerta: puerta,
        pie: pie(),
        reportes: [bache]))!;
    expect(r.segundosManejo, 300);
    expect(r.reportesEnRuta.single.tipo, TipoReporte.bache);
  });

  test('estaciona en el estacionamiento más cercano al edificio, no en la entrada', () async {
    final parkings = [for (final a in campus.accesos) if (a.esEstacionamiento) a];
    expect(parkings, isNotEmpty);
    final ruta = pie();
    for (final codigo in ['EDIF-L', 'EDIF-A', 'EDIF-K']) {
      final p = edificios.firstWhere((x) => x.codigo == codigo).entradaPrincipal!;
      final destino = LatLng(p.latitud, p.longitud);
      final r = (await auto().calcular(
          desde: casa,
          entradaAutos: entrada,
          puerta: destino,
          pie: ruta,
          estacionamientos: parkings))!;
      expect(r.estacionamiento, isNotNull, reason: codigo);
      final soloEntrada = ruta.grafo!.ruta(entrada, destino)!;
      expect(r.metrosAPie, lessThan(RutaService.largo(soloEntrada)),
          reason: '$codigo: camina menos que desde la entrada de autos');
      expect(ruta.grafo!.cruzaEdificio(r.aPie), isFalse);
      expect(r.aPie.last, destino);
    }
  });

  test('sin internet: null (el mapa muestra la línea recta)', () async {
    final sinRed = AutoService(client: MockClient((_) async => throw http.ClientException('x')));
    expect(
        await sinRed.calcular(
            desde: casa, entradaAutos: entrada, puerta: puerta, pie: pie()),
        isNull);
  });

  test('ApiService: lee y crea reportes', () async {
    String? enviado;
    final api = ApiService(client: MockClient((req) async {
      if (req.method == 'POST') {
        enviado = req.body;
        return http.Response('{}', 201);
      }
      return http.Response.bytes(utf8.encode(jsonEncode([
        {'id': 3, 'tipo': 'RETEN', 'descripcion': 'Tránsito', 'latitud': '29.020000',
         'longitud': '-110.910000', 'creado': '2026-11-21T10:00:00Z'},
      ])), 200);
    }));
    final lista = await api.obtenerReportes();
    expect(lista.single.tipo, TipoReporte.reten);
    expect(lista.single.latitud, closeTo(29.02, 1e-9));
    expect(await api.crearReporte(TipoReporte.bache, 29.01, -110.9), isNull);
    expect(jsonDecode(enviado!)['tipo'], 'BACHE');
  });
}
