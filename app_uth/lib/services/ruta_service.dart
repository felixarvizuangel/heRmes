import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/campus_model.dart';
import '../models/edificio_model.dart';
import 'geo_math_service.dart';
import 'geometria.dart';
import 'grafo_andadores.dart';

/// De dónde salió la ruta que se dibuja.
enum OrigenRuta {
  /// Ya estás DENTRO de la barda: solo grafo de andadores (Dijkstra local).
  andadores('Dentro del campus · por andadores', vieneDeAfuera: false),

  /// Vienes de AFUERA, cerca: banqueta exterior → puerta peatonal → andadores.
  puerta('Vienes de afuera · entra por la puerta peatonal'),

  /// Vienes de AFUERA, lejos: OSRM (perfil foot) → puerta peatonal → andadores.
  calles('Vienes de afuera · por calles y puerta peatonal');

  const OrigenRuta(this.texto, {this.vieneDeAfuera = true});
  final String texto;

  /// true si la ruta empieza fuera de la barda (entra por la puerta peatonal).
  final bool vieneDeAfuera;
}

/// Ruta a pie hacia la puerta del destino.
///
/// 0. ¿DENTRO o FUERA? Punto en polígono (ray casting, la misma función que
///    usa la geocerca) contra la BARDA del campus (`perimetro` de
///    `/api/campus/`, OSM way 265741798).
/// 1. DENTRO del campus usa SOLO el GRAFO DE ANDADORES (Dijkstra local, sin
///    internet): nunca OSRM, nunca sale por la puerta peatonal ni por la
///    entrada de autos.
/// 2. FUERA: llega a la PUERTA PEATONAL (banqueta exterior si estás cerca,
///    OSRM perfil "foot" si vienes de lejos) y de ahí por los andadores.
/// 3. Si nada de eso funciona devuelve null y el mapa usa la línea recta
///    (Extra 2 de la rúbrica), así la app nunca se queda sin guía.
///
/// ¿Por qué no solo OSRM? Su perfil foot conoce las calles pero no todos los
/// andadores internos de la UTH, y "corta" de la calle a la puerta en línea
/// recta, atravesando edificios.
class RutaService {
  RutaService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _base = 'https://routing.openstreetmap.de/routed-foot/route/v1/foot';

  /// Puntos de la ruta (incluye origen y destino) o null si no se pudo.
  Future<List<LatLng>?> caminar(LatLng desde, LatLng hasta) async {
    final uri = Uri.parse(
      '$_base/${desde.longitude},${desde.latitude};'
      '${hasta.longitude},${hasta.latitude}'
      '?overview=full&geometries=geojson',
    );
    try {
      final r = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final json = jsonDecode(r.body) as Map<String, dynamic>;
      if (json['code'] != 'Ok') return null;
      final coords = (json['routes'] as List).first['geometry']['coordinates'] as List;
      // GeoJSON viene como [longitud, latitud].
      final puntos = [
        for (final c in coords)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];
      return puntos.length < 2 ? null : [...puntos, hasta];
    } catch (_) {
      return null;
    }
  }

  /// Grafo de andadores DENTRO de la barda (null = todavía no se carga).
  GrafoAndadores? grafo;

  /// Calles y banquetas de afuera (De los Seris): solo para llegar a la
  /// puerta peatonal.
  GrafoAndadores? grafoExterior;

  /// Puertas por donde entran los estudiantes (peatonales o mixtas).
  List<LatLng> puertasPeatonales = const [];

  /// Calles internas del campus (solo autos): entrada de autos →
  /// estacionamiento en el modo carro.
  GrafoAndadores? grafoCalles;

  /// Sin barda: más lejos que esto de todo andador interior = estás fuera.
  static const double margenCampusM = 35;

  /// Un tramo "interior" que se sale de la barda más que esto (enlaces a la
  /// calle, salida norte de autos) no entra al grafo a pie de adentro.
  static const double toleranciaBardaM = 8;

  /// Barda del campus en metros (plano local) para el punto en polígono.
  List<Xy> _barda = const [];
  ProyeccionLocal? _proyBarda;

  /// true si ya se cargó el perímetro del campus.
  bool get tieneBarda => _barda.length >= 3;

  /// Arma los grafos con lo que bajó de `/api/campus/`.
  void configurar(CampusDatos campus, List<Edificio> edificios) {
    final obstaculos = GrafoAndadores.obstaculosDe(edificios);
    if (campus.perimetro.length >= 3) {
      final o = campus.perimetro.first;
      final proy = ProyeccionLocal(o.latitude, o.longitude);
      _proyBarda = proy;
      _barda = [for (final p in campus.perimetro) proy.deLatLng(p)];
    } else {
      _proyBarda = null;
      _barda = const [];
    }
    grafo = GrafoAndadores(
      [
        for (final a in campus.andadores)
          if (!a.esExterior && _dentroDeLaBarda(a)) a,
      ],
      obstaculos: obstaculos,
    );
    grafoExterior = GrafoAndadores(
      [for (final a in campus.andadores) if (a.esExterior) a],
      obstaculos: obstaculos,
    );
    puertasPeatonales = [
      for (final p in campus.accesos) if (p.esPeatonal) p.punto,
    ];
    grafoCalles = GrafoAndadores(
      [for (final a in campus.andadores) if (a.tipo == 'CALLE') a],
      obstaculos: obstaculos,
    );
  }

  /// true si [p] está DENTRO del polígono del campus (sin barda cargada se
  /// usa la regla de respaldo de [estaFuera]).
  bool dentroDelCampus(LatLng p) => !estaFuera(p);

  /// true si todo el tramo cae dentro de la barda (± [toleranciaBardaM]).
  bool _dentroDeLaBarda(Andador a) {
    final proy = _proyBarda;
    if (proy == null) return true;
    for (final p in a.puntos) {
      final xy = proy.deLatLng(p);
      if (Geometria.puntoEnPoligono(xy, _barda)) continue;
      if (Geometria.puntoMasCercanoContorno(xy, _barda).d > toleranciaBardaM) {
        return false;
      }
    }
    return true;
  }

  /// true si [p] está FUERA del campus.
  ///
  /// Con barda: punto en polígono (ray casting). Sin barda (datos viejos):
  /// lejos de los andadores interiores o más cerca de la calle de afuera.
  bool estaFuera(LatLng p) {
    final proy = _proyBarda;
    if (proy != null && tieneBarda) {
      return !Geometria.puntoEnPoligono(proy.deLatLng(p), _barda);
    }
    final g = grafo;
    if (g == null || g.vacio) return true;
    final dIn = g.distanciaAlGrafo(p) ?? double.infinity;
    if (dIn > margenCampusM) return true;
    final ext = grafoExterior;
    final dEx = (ext == null || ext.vacio) ? null : ext.distanciaAlGrafo(p);
    return dEx != null && dEx + 3 < dIn;
  }

  /// Ruta completa con su origen, o null (el mapa dibuja la línea recta).
  ///
  /// - Dentro del campus: SOLO andadores interiores (Dijkstra local). Sin
  ///   OSRM y sin pasar por la puerta peatonal ni la entrada de autos; si el
  ///   grafo no alcanza, null (línea recta), nunca una vuelta por la calle.
  /// - Fuera del campus: hasta la PUERTA PEATONAL (por la calle de afuera
  ///   si estás cerca, o por OSRM si vienes de lejos) y de ahí por los
  ///   andadores interiores. Nunca entra por la entrada de autos.
  Future<({List<LatLng> puntos, OrigenRuta origen})?> calcular(
      LatLng desde, LatLng hasta) async {
    final g = grafo;
    if (g != null && !g.vacio) {
      if (dentroDelCampus(desde)) {
        final local = g.ruta(desde, hasta);
        return local == null
            ? null
            : (puntos: local, origen: OrigenRuta.andadores);
      }
      if (puertasPeatonales.isNotEmpty) {
        final porPuerta = await _porPuerta(g, desde, hasta);
        if (porPuerta != null) return porPuerta;
      }
    }
    final calles = await caminar(desde, hasta);
    if (calles == null) return null;
    if (g != null && !g.vacio && g.cruzaEdificio(calles)) return null;
    return (puntos: calles, origen: OrigenRuta.calles);
  }

  /// Recorta [ruta] en el primer punto que ya está DENTRO del campus (la
  /// ruta de afuera nunca debe meterse por la entrada de autos).
  List<LatLng> soloAfuera(List<LatLng> ruta) {
    final fuera = <LatLng>[];
    for (final p in ruta) {
      if (!estaFuera(p)) break;
      fuera.add(p);
    }
    return fuera.isEmpty ? [ruta.first] : fuera;
  }

  /// Afuera → puerta peatonal → andadores → puerta del edificio.
  Future<({List<LatLng> puntos, OrigenRuta origen})?> _porPuerta(
      GrafoAndadores g, LatLng desde, LatLng hasta) async {
    // Puerta con el recorrido total más corto (afuera en línea recta como
    // estimación + adentro por andadores).
    List<LatLng>? mejorAdentro;
    LatLng? mejorPuerta;
    var mejor = double.infinity;
    for (final p in puertasPeatonales) {
      final adentro = g.ruta(p, hasta);
      if (adentro == null) continue;
      final total = GeoMathService.haversineDistance(
              desde.latitude, desde.longitude, p.latitude, p.longitude) +
          largo(adentro);
      if (total < mejor) {
        mejor = total;
        mejorAdentro = adentro;
        mejorPuerta = p;
      }
    }
    if (mejorAdentro == null || mejorPuerta == null) return null;

    // Tramo de afuera: banqueta exterior (cerca) u OSRM (lejos).
    var origen = OrigenRuta.puerta;
    final ext = grafoExterior;
    List<LatLng>? afuera = ext?.ruta(desde, mejorPuerta);
    if (afuera == null) {
      // OSRM no conoce la barda: si le pides la puerta, la "engancha" a la
      // calle interna y entra por la rampa de AUTOS. Por eso se le pide el
      // punto de la calle de afuera (De los Seris) frente a la puerta
      // peatonal, se corta todo lo que entre al campus y de ahí se sigue
      // por la banqueta exterior hasta la puerta.
      final frente = ext?.puntoMasCercano(mejorPuerta) ?? mejorPuerta;
      final osrm = await caminar(desde, frente);
      if (osrm != null) {
        final fuera = soloAfuera(osrm);
        final cierre = ext?.ruta(fuera.last, mejorPuerta) ??
            [fuera.last, mejorPuerta];
        final completo = [...fuera, ...cierre.skip(1)];
        if (!g.cruzaEdificio(completo)) {
          afuera = completo;
          origen = OrigenRuta.calles;
        }
      }
    }
    afuera ??= [desde, mejorPuerta]; // sin datos: recto hasta la puerta
    return (puntos: [...afuera, ...mejorAdentro.skip(1)], origen: origen);
  }

  void dispose() => _client.close();

  /// Recorta la ruta a lo que FALTA por caminar: busca el punto de la ruta
  /// más cercano al usuario y descarta todo lo anterior.
  /// Devuelve también la distancia del usuario a la ruta (para recalcular si
  /// se desvía mucho).
  static ({List<LatLng> restante, double desvio}) recortar(
    List<LatLng> ruta,
    LatLng usuario,
  ) {
    var mejor = 0;
    var minima = double.infinity;
    for (var i = 0; i < ruta.length; i++) {
      final d = GeoMathService.haversineDistance(
          usuario.latitude, usuario.longitude, ruta[i].latitude, ruta[i].longitude);
      if (d < minima) {
        minima = d;
        mejor = i;
      }
    }
    return (restante: [usuario, ...ruta.sublist(mejor + 1)], desvio: minima);
  }

  /// Largo total de una polilínea en metros (suma de tramos Haversine).
  static double largo(List<LatLng> puntos) {
    var total = 0.0;
    for (var i = 1; i < puntos.length; i++) {
      total += GeoMathService.haversineDistance(puntos[i - 1].latitude,
          puntos[i - 1].longitude, puntos[i].latitude, puntos[i].longitude);
    }
    return total;
  }
}
