import 'dart:math' as math;

/// Cuadrante relativo del destino respecto al cuerpo del usuario.
enum Cuadrante { alFrente, aTuDerecha, aTusEspaldas, aTuIzquierda }

extension CuadranteTexto on Cuadrante {
  /// Etiqueta textual definida en la rúbrica (Reto Mayor, punto 3).
  String get texto {
    switch (this) {
      case Cuadrante.alFrente:
        return 'Al frente';
      case Cuadrante.aTuDerecha:
        return 'A tu derecha';
      case Cuadrante.aTusEspaldas:
        return 'A tus espaldas';
      case Cuadrante.aTuIzquierda:
        return 'A tu izquierda';
    }
  }
}

/// Lógica geodésica y angular pura (sin dependencias de Flutter ni UI).
class GeoMathService {
  GeoMathService._();

  /// Radio medio de la Tierra en metros (NOTA 3).
  static const double earthRadiusMeters = 6371000.0;

  /// Umbral de llegada al destino en metros (NOTA 6).
  static const double arrivalThresholdMeters = 15.0;

  /// Convierte grados a radianes.
  static double toRadians(double degrees) => degrees * math.pi / 180.0;

  /// Convierte radianes a grados.
  static double toDegrees(double radians) => radians * 180.0 / math.pi;

  /// Normaliza cualquier ángulo (positivo, negativo o > 360) a [0, 360).
  static double normalize360(double degrees) {
    final r =
        degrees % 360.0; // En Dart, % con divisor positivo nunca es negativo.
    return r >= 360.0 ? 0.0 : r;
  }

  /// Diferencia angular más corta de [from] a [to], en (-180, 180].
  /// Positivo = giro horario. Resuelve la discontinuidad 359° -> 0°.
  static double shortestAngleDelta(double from, double to) {
    var d = normalize360(to - from);
    if (d > 180.0) d -= 360.0;
    return d;
  }

  /// Fórmula de Haversine: distancia sobre la superficie esférica, en metros,
  /// entre (lat1, lon1) y (lat2, lon2) dados en grados decimales.
  ///
  /// ¿Por qué no Pitágoras? La Tierra es (casi) una esfera: los grados de
  /// longitud miden menos metros conforme te alejas del ecuador. Haversine
  /// calcula el arco del círculo máximo que une los dos puntos.
  ///
  /// Paso a paso:
  ///   φ = latitud en radianes, λ = longitud en radianes, R = 6 371 000 m
  ///   a = sin²(Δφ/2) + cos φ1 · cos φ2 · sin²(Δλ/2)
  ///       → "haversine" del ángulo central entre los puntos (valor 0..1)
  ///   c = 2 · atan2(√a, √(1−a))
  ///       → ángulo central en radianes (atan2 es estable numéricamente
  ///         incluso cuando los puntos están muy cerca, como en el campus)
  ///   d = R · c
  ///       → longitud del arco = radio × ángulo (en metros)
  ///
  /// Ejemplo: 0.0001° de latitud ≈ 11 m, que es la escala de la geocerca.
  static double haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final phi1 = toRadians(lat1);
    final phi2 = toRadians(lat2);
    final dPhi = toRadians(lat2 - lat1);
    final dLambda = toRadians(lon2 - lon1);

    final a =
        math.pow(math.sin(dPhi / 2), 2) +
        math.cos(phi1) * math.cos(phi2) * math.pow(math.sin(dLambda / 2), 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  /// Rumbo inicial (azimut geodésico) desde el punto 1 hacia el punto 2,
  /// calculado con atan2. Devuelve grados en [0, 360) respecto al Norte.
  ///
  /// Es el ángulo "absoluto" hacia el destino: 0° = Norte, 90° = Este,
  /// 180° = Sur, 270° = Oeste, sin importar hacia dónde mire el teléfono.
  ///
  ///   y = sin Δλ · cos φ2                         (componente Este)
  ///   x = cos φ1 · sin φ2 − sin φ1 · cos φ2 · cos Δλ   (componente Norte)
  ///   θ = atan2(y, x)
  ///
  /// ¿Por qué atan2 y no atan(y/x)? atan solo devuelve −90°..90° y no sabe
  /// en qué cuadrante está el destino (y/x da lo mismo para Noreste que
  /// para Suroeste) y falla si x = 0. atan2 mira los signos de y y de x por
  /// separado y devuelve el ángulo completo −180°..180°.
  ///
  /// Como atan2 puede dar negativos (p. ej. −90° = Oeste), se normaliza con
  /// mod 360 para quedar en [0, 360): −90° → 270°.
  static double initialBearing(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final phi1 = toRadians(lat1);
    final phi2 = toRadians(lat2);
    final dLambda = toRadians(lon2 - lon1);

    final y = math.sin(dLambda) * math.cos(phi2);
    final x =
        math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
    return normalize360(toDegrees(math.atan2(y, x)));
  }

  /// Rotación visual de la aguja (NOTA 5): (bearing - heading) mod 360,
  /// normalizada a [0, 360). 0° = el destino está justo al frente.
  ///
  /// - bearing: hacia dónde está el destino respecto al Norte (atan2).
  /// - heading: hacia dónde apunta el teléfono respecto al Norte (brújula).
  /// - bearing − heading: cuánto debe girar la aguja respecto a la parte de
  ///   arriba del teléfono.
  ///
  /// ¿Por qué mod 360? La resta puede salir negativa o "dar la vuelta".
  /// Ejemplo: destino a 10°, teléfono mirando a 350° → 10 − 350 = −340°.
  /// −340 mod 360 = 20°: la aguja gira solo 20° a la derecha, que es lo
  /// correcto, en vez de casi una vuelta completa a la izquierda.
  static double needleRotation(double bearing, double heading) =>
      normalize360(bearing - heading);

  /// Rotación de la aguja en radianes, lista para Transform.rotate.
  static double needleRotationRadians(double bearing, double heading) =>
      toRadians(needleRotation(bearing, heading));

  /// Cuadrante relativo a partir de la diferencia angular (bearing - heading):
  /// [315, 45) Al frente, [45, 135) Derecha, [135, 225) Espaldas, [225, 315) Izquierda.
  static Cuadrante quadrant(double bearing, double heading) {
    final rel = needleRotation(bearing, heading);
    if (rel >= 315.0 || rel < 45.0) return Cuadrante.alFrente;
    if (rel < 135.0) return Cuadrante.aTuDerecha;
    if (rel < 225.0) return Cuadrante.aTusEspaldas;
    return Cuadrante.aTuIzquierda;
  }

  /// Texto del cuadrante relativo ("Al frente", "A tu derecha", etc.).
  static String quadrantText(double bearing, double heading) =>
      quadrant(bearing, heading).texto;

  /// Indica si la distancia ya está dentro del umbral de llegada.
  static bool hasArrived(
    double distanceMeters, {
    double threshold = arrivalThresholdMeters,
  }) => distanceMeters <= threshold;
}

/// Filtro pasa-bajas de primer orden para el heading del magnetómetro
/// (Módulo Extra 1). Interpola por la diferencia angular más corta, de modo
/// que el paso por el Norte (359° -> 0°) no provoca un giro de 360°.
class CompassLowPassFilter {
  /// Ponderación del filtro (rúbrica: 0.10 a 0.20).
  final double alpha;

  double? _value;

  CompassLowPassFilter({this.alpha = 0.15})
    : assert(alpha > 0 && alpha <= 1, 'alpha debe estar en (0, 1]');

  /// Último heading filtrado en [0, 360), o null si aún no hay lecturas.
  double? get value => _value;

  /// Aplica: filtrado = previo + alpha * deltaMasCorto(previo, lectura).
  /// La primera lectura se adopta sin suavizar.
  double filter(double rawHeading) {
    final raw = GeoMathService.normalize360(rawHeading);
    final prev = _value;
    if (prev == null) {
      _value = raw;
    } else {
      final delta = GeoMathService.shortestAngleDelta(prev, raw);
      _value = GeoMathService.normalize360(prev + alpha * delta);
    }
    return _value!;
  }

  /// Reinicia el estado (p. ej. al cambiar de destino o reanudar sensores).
  void reset() => _value = null;
}
