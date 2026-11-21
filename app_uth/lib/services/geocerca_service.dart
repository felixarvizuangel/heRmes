import '../models/edificio_model.dart';
import 'geo_math_service.dart';
import 'geometria.dart';

/// Un edificio medido desde la posición del usuario.
class Deteccion {
  const Deteccion(
    this.edificio,
    this.distancia,
    this.punto, {
    this.dentro = false,
    double? lat,
    double? lon,
  })  : lat = lat ?? 0,
        lon = lon ?? 0,
        _tienePunto = lat != null && lon != null;

  final Edificio edificio;

  /// Metros del usuario al edificio: 0 si está DENTRO del polígono; si no,
  /// distancia a la pared (contorno) o al punto GPS más cercano.
  final double distancia;

  /// Punto GPS del edificio (entrada o esquina) más cercano al usuario.
  final CoordenadaGps punto;

  /// true si el usuario está dentro del polígono del edificio.
  final bool dentro;

  /// Punto exacto más cercano (puede caer a media pared).
  final double lat;
  final double lon;
  final bool _tienePunto;

  /// Rumbo (0–360°) del usuario hacia el punto más cercano del edificio.
  double rumboDesde(double uLat, double uLon) => _tienePunto
      ? GeoMathService.initialBearing(uLat, uLon, lat, lon)
      : punto.rumboDesde(uLat, uLon);
}

/// Resultado de una revisión de la geocerca.
class ResultadoGeocerca {
  const ResultadoGeocerca({
    this.masCercano,
    this.nuevo,
    this.cercanos = const [],
    this.nuevos = const [],
  });

  /// Edificio más cercano de todos, aunque esté fuera de su radio
  /// (sirve para el texto de ayuda "Más cercano: … · 42 m").
  final Deteccion? masCercano;

  /// El más cercano de [nuevos] (compatibilidad con el aviso único).
  final Deteccion? nuevo;

  /// TODOS los edificios dentro de su geocerca, del más cercano al más lejano.
  final List<Deteccion> cercanos;

  /// Los de [cercanos] que todavía no se habían avisado.
  final List<Deteccion> nuevos;
}

/// Geocerca del Modo B (navegación libre), sin Flutter ni sensores:
/// recibe una posición y decide qué edificios avisar. Así se puede probar
/// con tests unitarios sin GPS.
///
/// Regla:
///   1. PUNTO EN POLÍGONO: con las esquinas del edificio (PERIMETRO) se arma
///      su polígono; si el usuario cae dentro (ray casting), distancia = 0.
///   2. Si está afuera, la distancia es la mínima entre la pared más cercana
///      (proyección sobre cada lado del polígono) y TODOS sus puntos GPS
///      (entrada principal, secundarias, esquinas), con Haversine.
///   3. ANILLO DE CERCANÍA: el radio_cobertura_m (20 m edificios, 30 m
///      áreas) se mide desde esa pared: dentro del polígono o a ≤ radio de
///      él, el edificio está "cerca". Si hay varios, se reportan TODOS
///      ordenados por distancia.
///   4. Histéresis: un edificio ya avisado no vuelve a avisar hasta que el
///      usuario se aleje más de radio + [histeresisM] metros. Sin esto, el
///      ruido del GPS (±5 m) repetiría el aviso al caminar en el borde.
class GeocercaService {
  GeocercaService({this.histeresisM = 5.0, this.radioPorDefecto = 20});

  /// Margen extra (metros) para volver a "armar" el aviso de un edificio.
  final double histeresisM;

  /// Radio usado si el edificio no trae un radio válido.
  final int radioPorDefecto;

  /// Ids de los edificios ya avisados mientras el usuario sigue cerca.
  final Set<int> _avisados = {};

  /// true si el edificio ya se avisó y el usuario no se ha alejado.
  bool yaAvisado(int edificioId) => _avisados.contains(edificioId);

  /// Olvida todos los avisos (p. ej. al reiniciar la navegación libre).
  void reiniciar() => _avisados.clear();

  /// Radio efectivo del edificio en metros.
  int radioDe(Edificio e) =>
      e.radioCoberturaM > 0 ? e.radioCoberturaM : radioPorDefecto;

  /// Distancia del usuario al edificio (polígono + puntos GPS).
  /// null si el edificio no tiene puntos GPS.
  static Deteccion? medir(Edificio e, double lat, double lon) {
    if (e.coordenadas.isEmpty) return null;

    // Punto GPS más cercano (Haversine), como antes.
    var mejor = e.coordenadas.first;
    var minima = double.infinity;
    for (final c in e.coordenadas) {
      final d = c.distanciaDesde(lat, lon);
      if (d < minima) {
        minima = d;
        mejor = c;
      }
    }

    final poligono = e.poligono;
    if (poligono.length < 3) return Deteccion(e, minima, mejor);

    // Plano local centrado en el usuario (metros).
    final proy = ProyeccionLocal(lat, lon);
    const yo = Xy(0, 0);
    final poli = [for (final p in poligono) proy.deLatLng(p)];
    final pared = Geometria.puntoMasCercanoContorno(yo, poli);
    final q = proy.aLatLng(pared.q);

    if (Geometria.puntoEnPoligono(yo, poli)) {
      return Deteccion(e, 0, mejor,
          dentro: true, lat: q.latitude, lon: q.longitude);
    }
    if (pared.d < minima) {
      return Deteccion(e, pared.d, mejor, lat: q.latitude, lon: q.longitude);
    }
    return Deteccion(e, minima, mejor);
  }

  /// Revisa la posición contra todos los [edificios].
  ///
  /// Si [registrarAviso] es false (por ejemplo, mientras el usuario está
  /// viendo un detalle) se calcula el resultado pero NO se marcan los
  /// edificios como avisados, para que se avisen al volver.
  ResultadoGeocerca evaluar(
    List<Edificio> edificios,
    double lat,
    double lon, {
    bool registrarAviso = true,
  }) {
    Deteccion? cercano;
    final cercanos = <Deteccion>[];

    for (final e in edificios) {
      final m = medir(e, lat, lon);
      if (m == null) continue;
      final radio = radioDe(e);

      // Ya salió del radio + histéresis: el aviso se vuelve a armar.
      if (m.distancia > radio + histeresisM) _avisados.remove(e.id);

      if (cercano == null || m.distancia < cercano.distancia) cercano = m;
      if (m.dentro || m.distancia <= radio) cercanos.add(m);
    }

    cercanos.sort((a, b) => a.distancia.compareTo(b.distancia));
    final nuevos = [
      for (final d in cercanos)
        if (!_avisados.contains(d.edificio.id)) d,
    ];
    if (registrarAviso) {
      for (final d in nuevos) {
        _avisados.add(d.edificio.id);
      }
    }
    return ResultadoGeocerca(
      masCercano: cercano,
      nuevo: nuevos.isEmpty ? null : nuevos.first,
      cercanos: List.unmodifiable(cercanos),
      nuevos: List.unmodifiable(nuevos),
    );
  }
}
