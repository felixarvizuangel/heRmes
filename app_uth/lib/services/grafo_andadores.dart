import 'package:latlong2/latlong.dart';

import '../models/campus_model.dart';
import '../models/edificio_model.dart';
import 'geometria.dart';

/// Arista del grafo: vecino y largo en metros.
class _Arista {
  const _Arista(this.a, this.b, this.peso);
  final int a;
  final int b;
  final double peso;
}

/// Dónde se "engancha" un punto (usuario o puerta) al grafo.
class _Enganche {
  const _Enganche(this.arista, this.q, this.distancia);
  final _Arista arista;
  final Xy q;
  final double distancia;
}

/// Grafo de andadores del campus y ruta a pie más corta (Dijkstra).
///
/// - Nodos: puntos de los tramos de `/api/andadores/` (banquetas, andadores,
///   cruces, calles internas). Dos tramos se unen donde comparten un punto.
/// - Obstáculos: polígonos (perímetro) de los edificios EDIF-*. Ningún tramo
///   de la BD los cruza y los enlaces que se agregan aquí (usuario → andador,
///   andador → puerta) también se validan: la ruta NUNCA atraviesa un edificio.
/// - Las canchas y plazas (AREA-*) no son obstáculo: se pueden cruzar a pie.
class GrafoAndadores {
  GrafoAndadores(List<Andador> andadores, {List<List<LatLng>> obstaculos = const []})
      : _proy = _proyeccionPara(andadores) {
    _obstaculos = [
      for (final o in obstaculos)
        if (o.length >= 3) [for (final p in o) _proy.deLatLng(p)],
    ];
    for (final t in andadores) {
      int? previo;
      for (final p in t.puntos) {
        final n = _nodo(p);
        if (previo != null && previo != n) _unir(previo, n);
        previo = n;
      }
    }
  }

  /// Grafo con los andadores del campus y los edificios como obstáculos.
  factory GrafoAndadores.desde(CampusDatos campus, List<Edificio> edificios) =>
      GrafoAndadores(campus.andadores, obstaculos: obstaculosDe(edificios));

  /// Polígonos de los edificios EDIF-* (las AREA-* son caminables).
  static List<List<LatLng>> obstaculosDe(List<Edificio> edificios) => [
        for (final e in edificios)
          if (e.codigo.toUpperCase().startsWith('EDIF') && e.poligono.length >= 3)
            e.poligono,
      ];

  /// Distancia máxima (m) para engancharse al grafo; más lejos se considera
  /// que el usuario está fuera del campus.
  static const double maxEnganche = 180;

  final ProyeccionLocal _proy;
  late final List<List<Xy>> _obstaculos;
  final List<Xy> _pos = [];
  final Map<String, int> _ids = {};
  final List<List<_Arista>> _ady = [];
  final List<_Arista> _aristas = [];

  int get nodos => _pos.length;
  int get aristas => _aristas.length;
  bool get vacio => _aristas.isEmpty;

  static ProyeccionLocal _proyeccionPara(List<Andador> andadores) {
    for (final t in andadores) {
      if (t.puntos.isNotEmpty) {
        return ProyeccionLocal(t.puntos.first.latitude, t.puntos.first.longitude);
      }
    }
    return ProyeccionLocal(29.0087, -110.9015);
  }

  int _nodo(LatLng p) {
    // Mismo punto (a 1e-6° ≈ 10 cm) = mismo nodo: así se unen los tramos.
    final clave =
        '${(p.latitude * 1e6).round()}:${(p.longitude * 1e6).round()}';
    return _ids.putIfAbsent(clave, () {
      _pos.add(_proy.deLatLng(p));
      _ady.add([]);
      return _pos.length - 1;
    });
  }

  void _unir(int a, int b) {
    final arista = _Arista(a, b, _pos[a].distanciaA(_pos[b]));
    _aristas.add(arista);
    _ady[a].add(arista);
    _ady[b].add(arista);
  }

  // ───────────────────────── Obstáculos ─────────────────────────

  /// true si el tramo a→b entra a algún edificio.
  bool _bloqueado(Xy a, Xy b, {double tolA = 0.5, double tolB = 0.5}) {
    for (final o in _obstaculos) {
      // Si el extremo está DENTRO del edificio (GPS dentro del salón, o una
      // puerta trazada medio metro adentro) ese edificio no bloquea la salida.
      if (Geometria.puntoEnPoligono(a, o) || Geometria.puntoEnPoligono(b, o)) {
        if (Geometria.cruzaPoligono(a, b, o, tolA: 4, tolB: 4)) return true;
        continue;
      }
      if (Geometria.cruzaPoligono(a, b, o, tolA: tolA, tolB: tolB)) return true;
    }
    return false;
  }

  /// true si la polilínea atraviesa un edificio (sirve para validar rutas
  /// externas como OSRM). Los extremos tienen 3 m de tolerancia (puertas).
  bool cruzaEdificio(List<LatLng> ruta) {
    for (var i = 1; i < ruta.length; i++) {
      final a = _proy.deLatLng(ruta[i - 1]);
      final b = _proy.deLatLng(ruta[i]);
      final tolA = i == 1 ? 3.0 : 0.5;
      final tolB = i == ruta.length - 1 ? 3.0 : 0.5;
      if (_bloqueado(a, b, tolA: tolA, tolB: tolB)) return true;
    }
    return false;
  }

  /// Mejor arista para conectar [p] sin cruzar edificios (o null).
  _Enganche? _enganchar(Xy p, {required double tolExtremo}) {
    final candidatos = <_Enganche>[];
    for (final ar in _aristas) {
      final q = Geometria.proyectar(p, _pos[ar.a], _pos[ar.b]).q;
      final d = p.distanciaA(q);
      if (d <= maxEnganche) candidatos.add(_Enganche(ar, q, d));
    }
    candidatos.sort((x, y) => x.distancia.compareTo(y.distancia));
    for (final c in candidatos.take(40)) {
      if (!_bloqueado(p, c.q, tolA: tolExtremo)) return c;
    }
    return null;
  }

  /// Si [p] cae DENTRO de un edificio (GPS dentro del salón o puerta trazada
  /// medio metro adentro), lo saca a la pared más cercana + 0.5 m. Así el
  /// enlace al andador sale por la pared correcta y no atraviesa el edificio.
  Xy _afuera(Xy p) {
    for (final o in _obstaculos) {
      if (!Geometria.puntoEnPoligono(p, o)) continue;
      final pared = Geometria.puntoMasCercanoContorno(p, o);
      final d = pared.d;
      if (d < 1e-6) return p;
      final k = (d + 0.5) / d;
      return Xy(p.x + (pared.q.x - p.x) * k, p.y + (pared.q.y - p.y) * k);
    }
    return p;
  }

  /// Punto del andador más cercano a [p] (sin cruzar edificios), o null.
  LatLng? puntoMasCercano(LatLng p) {
    if (vacio) return null;
    final e = _enganchar(_proy.deLatLng(p), tolExtremo: 3.0);
    return e == null ? null : _proy.aLatLng(e.q);
  }

  /// Distancia (m) de [p] al andador más cercano, o null si no hay grafo.
  double? distanciaAlGrafo(LatLng p) {
    if (vacio) return null;
    final xy = _proy.deLatLng(p);
    var minima = double.infinity;
    for (final ar in _aristas) {
      final d = xy.distanciaA(Geometria.proyectar(xy, _pos[ar.a], _pos[ar.b]).q);
      if (d < minima) minima = d;
    }
    return minima;
  }

  // ───────────────────────── Ruta ─────────────────────────

  /// Ruta a pie más corta de [desde] (usuario) a [hasta] (puerta del destino)
  /// siguiendo andadores. null si no hay grafo o alguno de los dos puntos
  /// está a más de [maxEnganche] m de un andador.
  List<LatLng>? ruta(LatLng desde, LatLng hasta) {
    if (vacio) return null;
    final s0 = _proy.deLatLng(desde);
    final t0 = _proy.deLatLng(hasta);
    final s = _afuera(s0);
    final t = _afuera(t0);
    final es = _enganchar(s, tolExtremo: 1.0);
    final et = _enganchar(t, tolExtremo: 3.0); // la puerta está en la pared
    if (es == null || et == null) return null;

    // Nodos virtuales: S0→S (usuario y su salida), QS (enganche),
    // QT (enganche), T→T0 (puerta y su salida).
    final n = _pos.length;
    final iS = n, iQs = n + 1, iQt = n + 2, iT = n + 3, iS0 = n + 4, iT0 = n + 5;
    final pos = [..._pos, s, es.q, et.q, t, s0, t0];
    final extra = <int, List<_Arista>>{};
    void virtual(int a, int b) {
      final ar = _Arista(a, b, pos[a].distanciaA(pos[b]));
      (extra[a] ??= []).add(ar);
      (extra[b] ??= []).add(ar);
    }

    virtual(iS0, iS);
    virtual(iT, iT0);
    virtual(iS, iQs);
    virtual(iQs, es.arista.a);
    virtual(iQs, es.arista.b);
    virtual(iQt, et.arista.a);
    virtual(iQt, et.arista.b);
    virtual(iQt, iT);
    if (identical(es.arista, et.arista)) virtual(iQs, iQt);

    // Dijkstra (≈ 400 nodos: basta buscar el mínimo en una lista).
    final total = pos.length;
    final dist = List<double>.filled(total, double.infinity);
    final prev = List<int>.filled(total, -1);
    final hecho = List<bool>.filled(total, false);
    dist[iS0] = 0;
    while (true) {
      var u = -1;
      var mejor = double.infinity;
      for (var i = 0; i < total; i++) {
        if (!hecho[i] && dist[i] < mejor) {
          mejor = dist[i];
          u = i;
        }
      }
      if (u == -1 || u == iT0) break;
      hecho[u] = true;
      final vecinos = [if (u < n) ..._ady[u], ...?extra[u]];
      for (final ar in vecinos) {
        final v = ar.a == u ? ar.b : ar.a;
        final nd = dist[u] + ar.peso;
        if (nd < dist[v]) {
          dist[v] = nd;
          prev[v] = u;
        }
      }
    }
    if (dist[iT0] == double.infinity) return null;

    final camino = <Xy>[];
    for (var v = iT0; v != -1; v = prev[v]) {
      camino.add(pos[v]);
    }
    final puntos = <LatLng>[];
    for (final p in camino.reversed) {
      // Quita puntos repetidos (enganche justo sobre un nodo).
      if (puntos.isEmpty || _proy.deLatLng(puntos.last).distanciaA(p) > 0.3) {
        puntos.add(_proy.aLatLng(p));
      }
    }
    puntos[0] = desde;
    puntos[puntos.length - 1] = hasta;
    return puntos.length < 2 ? null : puntos;
  }
}
