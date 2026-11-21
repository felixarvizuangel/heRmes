import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Punto en metros sobre un plano local (x = este, y = norte).
class Xy {
  const Xy(this.x, this.y);

  final double x;
  final double y;

  double distanciaA(Xy o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));

  @override
  String toString() => 'Xy(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// Proyección equirectangular local: convierte lat/lon a metros alrededor de
/// un origen. En distancias de un campus (< 2 km) el error es de centímetros,
/// y permite usar geometría plana (polígonos, segmentos, proyecciones).
class ProyeccionLocal {
  ProyeccionLocal(this.lat0, this.lon0)
      : _mLon = 111320.0 * math.cos(lat0 * math.pi / 180.0);

  final double lat0;
  final double lon0;
  static const double _mLat = 111320.0;
  final double _mLon;

  Xy xy(double lat, double lon) => Xy((lon - lon0) * _mLon, (lat - lat0) * _mLat);

  Xy deLatLng(LatLng p) => xy(p.latitude, p.longitude);

  LatLng aLatLng(Xy p) => LatLng(lat0 + p.y / _mLat, lon0 + p.x / _mLon);
}

/// Geometría plana para la geocerca por polígono y el ruteo por andadores.
class Geometria {
  Geometria._();

  /// Punto en polígono (ray casting): cuenta cuántas veces un rayo hacia el
  /// este cruza los lados; impar = dentro.
  static bool puntoEnPoligono(Xy p, List<Xy> poli) {
    var dentro = false;
    for (var i = 0, j = poli.length - 1; i < poli.length; j = i++) {
      final a = poli[i];
      final b = poli[j];
      if ((a.y > p.y) != (b.y > p.y) &&
          p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
        dentro = !dentro;
      }
    }
    return dentro;
  }

  /// Proyección de [p] sobre el segmento ab: t ∈ [0, 1] y el punto.
  static ({double t, Xy q}) proyectar(Xy p, Xy a, Xy b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final l2 = dx * dx + dy * dy;
    final t = l2 == 0
        ? 0.0
        : (((p.x - a.x) * dx + (p.y - a.y) * dy) / l2).clamp(0.0, 1.0);
    return (t: t, q: Xy(a.x + t * dx, a.y + t * dy));
  }

  /// Punto del CONTORNO del polígono más cercano a [p] y su distancia.
  static ({Xy q, double d}) puntoMasCercanoContorno(Xy p, List<Xy> poli) {
    var mejor = poli.first;
    var minima = double.infinity;
    for (var i = 0; i < poli.length; i++) {
      final q = proyectar(p, poli[i], poli[(i + 1) % poli.length]).q;
      final d = p.distanciaA(q);
      if (d < minima) {
        minima = d;
        mejor = q;
      }
    }
    return (q: mejor, d: minima);
  }

  /// Cruce de los segmentos p1p2 y q1q2 (null si no se tocan).
  static Xy? interseccion(Xy p1, Xy p2, Xy q1, Xy q2) {
    final rx = p2.x - p1.x, ry = p2.y - p1.y;
    final sx = q2.x - q1.x, sy = q2.y - q1.y;
    final den = rx * sy - ry * sx;
    if (den.abs() < 1e-12) return null;
    final qpx = q1.x - p1.x, qpy = q1.y - p1.y;
    final t = (qpx * sy - qpy * sx) / den;
    final u = (qpx * ry - qpy * rx) / den;
    if (t < 0 || t > 1 || u < 0 || u > 1) return null;
    return Xy(p1.x + t * rx, p1.y + t * ry);
  }

  /// true si el segmento ab ENTRA al polígono.
  ///
  /// Se ignoran los toques a menos de [tolA] metros de `a` y [tolB] de `b`:
  /// así una puerta que está justo sobre la pared (o un GPS que cae medio
  /// metro adentro) puede conectarse con el andador de enfrente, pero una
  /// línea que atraviesa el edificio de lado a lado sí se detecta.
  static bool cruzaPoligono(Xy a, Xy b, List<Xy> poli,
      {double tolA = 0.5, double tolB = 0.5}) {
    if (poli.length < 3) return false;
    final largo = a.distanciaA(b);
    if (largo < 1e-6) return false;
    // Puntos interiores del segmento (detecta un tramo completo adentro).
    const muestras = 8;
    for (var k = 1; k < muestras; k++) {
      final t = k / muestras;
      final m = Xy(a.x + t * (b.x - a.x), a.y + t * (b.y - a.y));
      if (t * largo <= tolA || (1 - t) * largo <= tolB) continue;
      if (puntoEnPoligono(m, poli)) return true;
    }
    for (var i = 0; i < poli.length; i++) {
      final c = interseccion(a, b, poli[i], poli[(i + 1) % poli.length]);
      if (c != null && c.distanciaA(a) > tolA && c.distanciaA(b) > tolB) {
        return true;
      }
    }
    return false;
  }
}
