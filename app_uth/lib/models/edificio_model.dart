import 'package:latlong2/latlong.dart';

import '../services/geo_math_service.dart';

/// Tipos de punto GPS (espejo de EdificioCoordenadasGPS.Tipo en Django).
enum TipoCoordenada {
  entradaPrincipal('ENTRADA_PRINCIPAL', 'Entrada principal'),
  entradaSecundaria('ENTRADA_SECUNDARIA', 'Entrada secundaria'),
  perimetro('PERIMETRO', 'Perímetro');

  const TipoCoordenada(this.api, this.etiqueta);

  final String api;
  final String etiqueta;

  static TipoCoordenada fromApi(String? valor) => TipoCoordenada.values
      .firstWhere((t) => t.api == valor, orElse: () => TipoCoordenada.perimetro);
}

/// Categorías de edificio (espejo de Edificio.Categoria en Django).
enum CategoriaEdificio {
  academico('ACADEMICO', 'Académico'),
  administrativo('ADMINISTRATIVO', 'Administrativo'),
  servicios('SERVICIOS', 'Servicios');

  const CategoriaEdificio(this.api, this.etiqueta);

  final String api;
  final String etiqueta;

  static CategoriaEdificio fromApi(String? valor) =>
      CategoriaEdificio.values.firstWhere((c) => c.api == valor,
          orElse: () => CategoriaEdificio.academico);
}

double _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}

int _toInt(Object? v, [int porDefecto = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? porDefecto;
  return porDefecto;
}

String? _toNullableString(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

List<String> _toStringList(Object? v) =>
    v is List ? v.map((e) => e.toString()).toList(growable: false) : const [];

/// Hora "HH:MM[:SS]" del backend (TimeField) como minutos desde medianoche.
int? _parseMinutos(String? hhmmss) {
  if (hhmmss == null) return null;
  final partes = hhmmss.split(':');
  if (partes.length < 2) return null;
  final h = int.tryParse(partes[0]);
  final m = int.tryParse(partes[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// Punto GPS 1-a-N de un edificio.
class CoordenadaGps {
  const CoordenadaGps({
    required this.id,
    required this.tipo,
    required this.etiqueta,
    required this.latitud,
    required this.longitud,
    required this.orden,
    required this.esTransitable,
  });

  final int id;
  final TipoCoordenada tipo;
  final String etiqueta;
  final double latitud;
  final double longitud;
  final int orden;
  final bool esTransitable;

  factory CoordenadaGps.fromJson(Map<String, dynamic> json) {
    final tipo = TipoCoordenada.fromApi(json['tipo'] as String?);
    return CoordenadaGps(
      id: _toInt(json['id']),
      tipo: tipo,
      etiqueta: (json['etiqueta'] as String?) ?? '',
      latitud: _toDouble(json['latitud']),
      longitud: _toDouble(json['longitud']),
      orden: _toInt(json['orden']),
      esTransitable: json['es_transitable'] is bool
          ? json['es_transitable'] as bool
          : tipo != TipoCoordenada.perimetro,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'tipo': tipo.api,
        'etiqueta': etiqueta,
        'latitud': latitud,
        'longitud': longitud,
        'orden': orden,
        'es_transitable': esTransitable,
      };

  /// Etiqueta legible: la del backend o, si está vacía, la del tipo.
  String get nombreVisible => etiqueta.isNotEmpty ? etiqueta : tipo.etiqueta;

  /// Distancia Haversine en metros desde (lat, lon).
  double distanciaDesde(double lat, double lon) =>
      GeoMathService.haversineDistance(lat, lon, latitud, longitud);

  /// Rumbo inicial en grados [0, 360) desde (lat, lon) hacia este punto.
  double rumboDesde(double lat, double lon) =>
      GeoMathService.initialBearing(lat, lon, latitud, longitud);
}

/// Edificio del campus tal como lo expone `EdificioSerializer`.
class Edificio {
  const Edificio({
    required this.id,
    required this.codigo,
    required this.nombre,
    required this.descripcion,
    required this.categoria,
    required this.categoriaDisplay,
    required this.dependencias,
    required this.palabrasClave,
    required this.horaApertura,
    required this.horaCierre,
    required this.radioCoberturaM,
    required this.fotoFachada,
    required this.urlVideo,
    required this.activo,
    required this.actualizado,
    required this.coordenadas,
  });

  final int id;
  final String codigo;
  final String nombre;
  final String descripcion;
  final CategoriaEdificio categoria;
  final String categoriaDisplay;
  final List<String> dependencias;
  final List<String> palabrasClave;

  /// "HH:MM:SS" o null.
  final String? horaApertura;
  final String? horaCierre;
  final int radioCoberturaM;
  final String? fotoFachada;
  final String? urlVideo;
  final bool activo;
  final DateTime? actualizado;

  /// Puntos ordenados por `orden` (1-a-N).
  final List<CoordenadaGps> coordenadas;

  factory Edificio.fromJson(Map<String, dynamic> json) {
    final coords = (json['coordenadas'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CoordenadaGps.fromJson)
        .toList()
      ..sort((a, b) => a.orden != b.orden
          ? a.orden.compareTo(b.orden)
          : a.id.compareTo(b.id));
    final categoria = CategoriaEdificio.fromApi(json['categoria'] as String?);
    return Edificio(
      id: _toInt(json['id']),
      codigo: (json['codigo'] as String?) ?? '',
      nombre: (json['nombre'] as String?) ?? '',
      descripcion: (json['descripcion'] as String?) ?? '',
      categoria: categoria,
      categoriaDisplay:
          _toNullableString(json['categoria_display']) ?? categoria.etiqueta,
      dependencias: _toStringList(json['dependencias']),
      palabrasClave: _toStringList(json['palabras_clave']),
      horaApertura: _toNullableString(json['hora_apertura']),
      horaCierre: _toNullableString(json['hora_cierre']),
      radioCoberturaM: _toInt(json['radio_cobertura_m'], 20),
      fotoFachada: _toNullableString(json['foto_fachada']),
      urlVideo: _toNullableString(json['url_video']),
      activo: json['activo'] is bool ? json['activo'] as bool : true,
      actualizado: DateTime.tryParse(json['actualizado']?.toString() ?? ''),
      coordenadas: List.unmodifiable(coords),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'codigo': codigo,
        'nombre': nombre,
        'descripcion': descripcion,
        'categoria': categoria.api,
        'categoria_display': categoriaDisplay,
        'dependencias': dependencias,
        'palabras_clave': palabrasClave,
        'hora_apertura': horaApertura,
        'hora_cierre': horaCierre,
        'radio_cobertura_m': radioCoberturaM,
        'foto_fachada': fotoFachada,
        'url_video': urlVideo,
        'activo': activo,
        'actualizado': actualizado?.toIso8601String(),
        'coordenadas': coordenadas.map((c) => c.toJson()).toList(),
      };

  /// Acepta lista plana o respuesta paginada de DRF (`{"results": [...]}`).
  static List<Edificio> listFromJson(Object? json) {
    final lista = json is Map<String, dynamic> ? json['results'] : json;
    if (lista is! List) return const [];
    return lista
        .whereType<Map<String, dynamic>>()
        .map(Edificio.fromJson)
        .toList(growable: false);
  }

  /// La ENTRADA_PRINCIPAL (el backend garantiza exactamente una).
  /// Fallback defensivo: primer punto transitable, luego primer punto.
  CoordenadaGps? get entradaPrincipal {
    for (final c in coordenadas) {
      if (c.tipo == TipoCoordenada.entradaPrincipal) return c;
    }
    for (final c in coordenadas) {
      if (c.esTransitable) return c;
    }
    return coordenadas.isEmpty ? null : coordenadas.first;
  }

  /// Esquinas del edificio (PERIMETRO, en orden) como polígono cerrado.
  /// Vacío si tiene menos de 3 esquinas.
  List<LatLng> get poligono {
    final esquinas = coordenadas
        .where((c) => c.tipo == TipoCoordenada.perimetro)
        .toList()
      ..sort((a, b) => a.orden != b.orden
          ? a.orden.compareTo(b.orden)
          : a.id.compareTo(b.id));
    if (esquinas.length < 3) return const [];
    return List.unmodifiable(
        esquinas.map((c) => LatLng(c.latitud, c.longitud)));
  }

  /// Puertas (principal + secundarias); descarta PERIMETRO.
  List<CoordenadaGps> get puntosTransitables =>
      coordenadas.where((c) => c.esTransitable).toList(growable: false);

  /// Puerta transitable más cercana a (lat, lon); si no hay, la principal.
  CoordenadaGps? puertaMasCercana(double lat, double lon) {
    CoordenadaGps? mejor;
    var mejorDist = double.infinity;
    for (final c in puntosTransitables) {
      final d = c.distanciaDesde(lat, lon);
      if (d < mejorDist) {
        mejorDist = d;
        mejor = c;
      }
    }
    return mejor ?? entradaPrincipal;
  }

  /// Distancia mínima en metros a CUALQUIER punto (incl. perímetro), Modo B.
  double distanciaMinima(double lat, double lon) {
    var minima = double.infinity;
    for (final c in coordenadas) {
      final d = c.distanciaDesde(lat, lon);
      if (d < minima) minima = d;
    }
    return minima;
  }

  bool get tieneVideo => urlVideo != null;

  /// Horario legible "07:00–21:00", o null si no hay horario.
  String? get horarioTexto {
    if (horaApertura == null || horaCierre == null) return null;
    String corta(String h) => h.length >= 5 ? h.substring(0, 5) : h;
    return '${corta(horaApertura!)}–${corta(horaCierre!)}';
  }

  /// true si [ahora] cae dentro del horario; null si no hay horario.
  bool? estaAbierto([DateTime? ahora]) {
    final ap = _parseMinutos(horaApertura);
    final ci = _parseMinutos(horaCierre);
    if (ap == null || ci == null) return null;
    final t = ahora ?? DateTime.now();
    final min = t.hour * 60 + t.minute;
    return min >= ap && min < ci;
  }

  /// Coincidencia para búsqueda predictiva local (nombre, código,
  /// dependencias o palabras clave).
  /// Sin distinguir mayúsculas ni acentos: "cafeteria" encuentra "Cafetería".
  bool coincide(String consulta) {
    final q = _normalizar(consulta.trim());
    if (q.isEmpty) return true;
    return _normalizar(nombre).contains(q) ||
        _normalizar(codigo).contains(q) ||
        dependencias.any((d) => _normalizar(d).contains(q)) ||
        palabrasClave.any((p) => _normalizar(p).contains(q));
  }

  /// Palabras clave para mostrar, sin repetidas por acentos: de
  /// "rectoria" y "rectoría" queda solo "rectoría" (la búsqueda ya ignora
  /// acentos, la versión sin acento solo servía para buscar).
  List<String> get palabrasVisibles {
    final porClave = <String, String>{};
    for (final p in palabrasClave) {
      final k = _normalizar(p);
      final previa = porClave[k];
      // Gana la que tiene acentos (difiere de su forma normalizada).
      if (previa == null || (previa == k && p != k)) porClave[k] = p;
    }
    return porClave.values.toList(growable: false);
  }

  /// Minúsculas y sin acentos (á→a, é→e, í→i, ó→o, ú→u, ü→u).
  static String _normalizar(String s) {
    const con = 'áéíóúüàèìòù';
    const sin = 'aeiouuaeiou';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = con.indexOf(ch);
      b.write(i >= 0 ? sin[i] : ch);
    }
    return b.toString();
  }

  @override
  bool operator ==(Object other) => other is Edificio && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
