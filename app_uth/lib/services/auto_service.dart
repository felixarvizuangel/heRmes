import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/campus_model.dart';
import 'geometria.dart';
import 'ruta_service.dart';

/// Ruta para quien llega EN CARRO.
class RutaAuto {
  const RutaAuto({
    required this.manejo,
    required this.aPie,
    required this.reportesEnRuta,
    required this.segundosManejo,
    this.estacionamiento,
  });

  /// Tramo en carro: tu posición → entrada de autos → calles internas →
  /// estacionamiento más cercano al edificio.
  final List<LatLng> manejo;

  /// Tramo a pie: estacionamiento → puerta del edificio (banquetas y
  /// andadores).
  final List<LatLng> aPie;

  /// Dónde dejas el carro (null = en la entrada de autos).
  final PuntoAcceso? estacionamiento;

  /// Reportes de la comunidad que quedan sobre la ruta elegida (a ≤ 30 m).
  final List<ReporteVial> reportesEnRuta;

  /// Tiempo estimado de manejo que da OSRM (sin tráfico en vivo).
  final double segundosManejo;

  double get metrosManejo => RutaService.largo(manejo);
  double get metrosAPie => RutaService.largo(aPie);
}

/// Modo carro: ruta por calles con el servidor público y gratuito de
/// OpenStreetMap (OSRM, perfil "car") hasta la ENTRADA DE AUTOS del campus,
/// y de ahí a pie por los andadores hasta el edificio.
///
/// Obstáculos (baches, retenes, calles cerradas): no hay una fuente pública
/// gratuita en tiempo real (Waze/Google son de pago), así que se usan los
/// REPORTES DE LA COMUNIDAD (`/api/reportes/`). Se piden hasta 3 rutas
/// alternativas y se elige la que pasa junto a menos reportes; una calle
/// cerrada pesa mucho más que un bache.
class AutoService {
  AutoService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _base =
      'https://routing.openstreetmap.de/routed-car/route/v1/driving';

  /// Un reporte "está en la ruta" si queda a esta distancia o menos.
  static const double radioReporteM = 30;

  void dispose() => _client.close();

  /// Rutas en carro (la principal y alternativas) con su duración en s.
  Future<List<({List<LatLng> puntos, double segundos})>> rutas(
      LatLng desde, LatLng hasta) async {
    final uri = Uri.parse(
      '$_base/${desde.longitude},${desde.latitude};'
      '${hasta.longitude},${hasta.latitude}'
      '?overview=full&geometries=geojson&alternatives=3',
    );
    try {
      final r = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return const [];
      final json = jsonDecode(r.body) as Map<String, dynamic>;
      if (json['code'] != 'Ok') return const [];
      return [
        for (final ruta in json['routes'] as List)
          (
            puntos: [
              for (final c in ruta['geometry']['coordinates'] as List)
                LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
            ],
            segundos: (ruta['duration'] as num?)?.toDouble() ?? 0,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Reportes a ≤ [radioReporteM] de la polilínea.
  static List<ReporteVial> reportesSobre(
      List<LatLng> ruta, List<ReporteVial> reportes) {
    if (ruta.length < 2 || reportes.isEmpty) return const [];
    final proy = ProyeccionLocal(ruta.first.latitude, ruta.first.longitude);
    final xy = [for (final p in ruta) proy.deLatLng(p)];
    return [
      for (final r in reportes)
        if (_distancia(proy.deLatLng(r.punto), xy) <= radioReporteM) r,
    ];
  }

  static double _distancia(Xy p, List<Xy> linea) {
    var minima = double.infinity;
    for (var i = 1; i < linea.length; i++) {
      final d = p.distanciaA(Geometria.proyectar(p, linea[i - 1], linea[i]).q);
      if (d < minima) minima = d;
    }
    return minima;
  }

  /// Penalización: calle cerrada = 1000, cualquier otro reporte = 1.
  static int _castigo(List<ReporteVial> sobre) =>
      sobre.fold(0, (s, r) => s + (r.bloquea ? 1000 : 1));

  /// Caminata del estacionamiento a la puerta. El estacionamiento es
  /// terreno abierto: si la línea recta no cruza ningún edificio, mide
  /// ≤ 150 m y ahorra mucho frente al grafo (que a veces rodea por las
  /// calles), se cruza el estacionamiento directo. Si no, por andadores.
  static List<LatLng>? caminarDesdeEstacionamiento(
      RutaService pie, LatLng desde, LatLng puerta) {
    final g = pie.grafo;
    final porAndadores = g?.ruta(desde, puerta);
    final recta = [desde, puerta];
    final largoRecta = RutaService.largo(recta);
    final libre = g == null || !g.cruzaEdificio(recta);
    if (libre &&
        largoRecta <= 150 &&
        (porAndadores == null ||
            largoRecta * 1.6 < RutaService.largo(porAndadores))) {
      return recta;
    }
    return porAndadores;
  }

  /// Elige el estacionamiento que deja el recorrido más corto: manejar por
  /// las calles internas desde la entrada + caminar hasta la puerta (la
  /// caminata pesa 4 veces más: conviene dejar el carro lo más cerca).
  static ({PuntoAcceso? lugar, List<LatLng> manejo, List<LatLng> aPie})
      mejorEstacionamiento({
    required LatLng entradaAutos,
    required LatLng puerta,
    required RutaService pie,
    required List<PuntoAcceso> estacionamientos,
  }) {
    final calles = pie.grafoCalles;
    final caminar0 =
        pie.grafo?.ruta(entradaAutos, puerta) ?? [entradaAutos, puerta];
    ({PuntoAcceso? lugar, List<LatLng> manejo, List<LatLng> aPie}) mejor = (
      lugar: null,
      manejo: [entradaAutos],
      aPie: caminar0,
    );
    var mejorCosto = 4 * RutaService.largo(caminar0);
    if (calles == null || calles.vacio) return mejor;
    for (final e in estacionamientos) {
      final manejo = calles.ruta(entradaAutos, e.punto);
      final aPie = caminarDesdeEstacionamiento(pie, e.punto, puerta);
      if (manejo == null || aPie == null) continue;
      final costo = RutaService.largo(manejo) + 4 * RutaService.largo(aPie);
      if (costo < mejorCosto) {
        mejorCosto = costo;
        mejor = (lugar: e, manejo: manejo, aPie: aPie);
      }
    }
    return mejor;
  }

  /// Ruta completa: manejar hasta [entradaAutos], seguir por las calles
  /// internas hasta el estacionamiento más cercano a [puerta] y caminar.
  /// null si OSRM no responde (sin internet).
  Future<RutaAuto?> calcular({
    required LatLng desde,
    required LatLng entradaAutos,
    required LatLng puerta,
    required RutaService pie,
    List<ReporteVial> reportes = const [],
    List<PuntoAcceso> estacionamientos = const [],
  }) async {
    final opciones = await rutas(desde, entradaAutos);
    if (opciones.isEmpty) return null;
    ({List<LatLng> puntos, double segundos})? mejor;
    var mejorCastigo = 1 << 30;
    var mejorSobre = const <ReporteVial>[];
    for (final o in opciones) {
      final sobre = reportesSobre(o.puntos, reportes);
      final castigo = _castigo(sobre);
      // Empate: la más rápida (OSRM ya las da ordenadas por tiempo).
      if (castigo < mejorCastigo) {
        mejor = o;
        mejorCastigo = castigo;
        mejorSobre = sobre;
      }
    }
    final adentro = mejorEstacionamiento(
      entradaAutos: entradaAutos,
      puerta: puerta,
      pie: pie,
      estacionamientos: estacionamientos,
    );
    final manejo = [...mejor!.puntos, ...adentro.manejo];
    // Dentro del campus se maneja despacio (~15 km/h ≈ 4 m/s).
    final extra = RutaService.largo(adentro.manejo) / 4;
    return RutaAuto(
      manejo: manejo,
      aPie: adentro.aPie,
      reportesEnRuta: mejorSobre,
      segundosManejo: mejor.segundos + extra,
      estacionamiento: adentro.lugar,
    );
  }
}
