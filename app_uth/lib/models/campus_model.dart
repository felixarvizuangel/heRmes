import 'package:latlong2/latlong.dart';

double _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// Tipos de puerta del campus (espejo de PuntoAcceso.Tipo en Django).
enum TipoAcceso {
  peatonal('PEATONAL', 'Puerta peatonal'),
  vehicular('VEHICULAR', 'Entrada de autos'),
  mixto('MIXTO', 'Peatonal y autos'),
  estacionamiento('ESTACIONAMIENTO', 'Estacionamiento'),
  parada('PARADA', 'Parada de camión');

  const TipoAcceso(this.api, this.etiqueta);

  final String api;
  final String etiqueta;

  static TipoAcceso fromApi(String? v) => TipoAcceso.values
      .firstWhere((t) => t.api == v, orElse: () => TipoAcceso.peatonal);
}

/// Puerta peatonal o entrada de autos del campus (`/api/accesos/`).
class PuntoAcceso {
  const PuntoAcceso({
    required this.id,
    required this.nombre,
    required this.tipo,
    required this.descripcion,
    required this.latitud,
    required this.longitud,
    required this.validado,
  });

  final int id;
  final String nombre;
  final TipoAcceso tipo;
  final String descripcion;
  final double latitud;
  final double longitud;

  /// false = coordenada aproximada, falta confirmarla en sitio.
  final bool validado;

  LatLng get punto => LatLng(latitud, longitud);

  bool get esPeatonal =>
      tipo == TipoAcceso.peatonal || tipo == TipoAcceso.mixto;

  /// Entrada o salida de autos del campus (no estacionamientos).
  bool get esVehicular =>
      tipo == TipoAcceso.vehicular || tipo == TipoAcceso.mixto;

  bool get esEstacionamiento => tipo == TipoAcceso.estacionamiento;

  bool get esParada => tipo == TipoAcceso.parada;

  factory PuntoAcceso.fromJson(Map<String, dynamic> j) => PuntoAcceso(
        id: _int(j['id']),
        nombre: (j['nombre'] as String?) ?? '',
        tipo: TipoAcceso.fromApi(j['tipo'] as String?),
        descripcion: (j['descripcion'] as String?) ?? '',
        latitud: _num(j['latitud']),
        longitud: _num(j['longitud']),
        validado: j['validado'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'nombre': nombre,
        'tipo': tipo.api,
        'descripcion': descripcion,
        'latitud': latitud,
        'longitud': longitud,
        'validado': validado,
      };
}

/// Tramo caminable del grafo de andadores (`/api/andadores/`).
class Andador {
  const Andador({
    required this.id,
    required this.tipo,
    required this.nombre,
    required this.puntos,
  });

  final int id;

  /// ANDADOR, BANQUETA, CRUCE, CALLE, ENLACE o EXTERIOR.
  final String tipo;

  /// Calle o banqueta pública fuera de la barda (De los Seris).
  bool get esExterior => tipo == 'EXTERIOR';
  final String nombre;
  final List<LatLng> puntos;

  factory Andador.fromJson(Map<String, dynamic> j) => Andador(
        id: _int(j['id']),
        tipo: (j['tipo'] as String?) ?? 'ANDADOR',
        nombre: (j['nombre'] as String?) ?? '',
        puntos: [
          for (final p in (j['puntos'] as List? ?? const []))
            if (p is List && p.length >= 2) LatLng(_num(p[0]), _num(p[1])),
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'tipo': tipo,
        'nombre': nombre,
        'puntos': [
          for (final p in puntos) [p.latitude, p.longitude]
        ],
      };
}

/// Todo lo del campus que no es edificio (`/api/campus/`, una sola petición).
class CampusDatos {
  const CampusDatos({
    this.accesos = const [],
    this.andadores = const [],
    this.perimetro = const [],
  });

  static const vacio = CampusDatos();

  final List<PuntoAcceso> accesos;
  final List<Andador> andadores;

  /// Barda del campus (polígono). Vacío = el backend no lo mandó.
  final List<LatLng> perimetro;

  bool get estaVacio => accesos.isEmpty && andadores.isEmpty;

  /// Copia con otro [perimetro] (p. ej. el de la copia incluida en la app
  /// cuando un backend viejo o la caché no lo traen).
  CampusDatos conPerimetro(List<LatLng> p) =>
      CampusDatos(accesos: accesos, andadores: andadores, perimetro: p);

  factory CampusDatos.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Se esperaba {accesos, andadores}.');
    }
    List<Map<String, dynamic>> lista(String k) =>
        (json[k] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
    return CampusDatos(
      accesos: lista('accesos').map(PuntoAcceso.fromJson).toList(growable: false),
      andadores: lista('andadores')
          .map(Andador.fromJson)
          .where((a) => a.puntos.length >= 2)
          .toList(growable: false),
      perimetro: [
        for (final p in (json['perimetro'] as List? ?? const []))
          if (p is List && p.length >= 2) LatLng(_num(p[0]), _num(p[1])),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'accesos': accesos.map((a) => a.toJson()).toList(),
        'andadores': andadores.map((a) => a.toJson()).toList(),
        'perimetro': [
          for (final p in perimetro) [p.latitude, p.longitude]
        ],
      };
}

/// Tipos de reporte vial (espejo de ReporteVial.Tipo en Django).
enum TipoReporte {
  bache('BACHE', 'Bache / socavón'),
  reten('RETEN', 'Retén'),
  cerrada('CERRADA', 'Calle cerrada'),
  obra('OBRA', 'Obra en la calle'),
  otro('OTRO', 'Otro');

  const TipoReporte(this.api, this.etiqueta);

  final String api;
  final String etiqueta;

  static TipoReporte fromApi(String? v) => TipoReporte.values
      .firstWhere((t) => t.api == v, orElse: () => TipoReporte.otro);
}

/// Obstáculo para el modo carro reportado por la comunidad
/// (`/api/reportes/`). Caduca solo en el backend.
class ReporteVial {
  const ReporteVial({
    required this.id,
    required this.tipo,
    required this.descripcion,
    required this.latitud,
    required this.longitud,
    this.creado,
  });

  final int id;
  final TipoReporte tipo;
  final String descripcion;
  final double latitud;
  final double longitud;
  final DateTime? creado;

  LatLng get punto => LatLng(latitud, longitud);

  /// Calle cerrada: la ruta en carro debe evitarla sí o sí.
  bool get bloquea => tipo == TipoReporte.cerrada;

  factory ReporteVial.fromJson(Map<String, dynamic> j) => ReporteVial(
        id: _int(j['id']),
        tipo: TipoReporte.fromApi(j['tipo'] as String?),
        descripcion: (j['descripcion'] as String?) ?? '',
        latitud: _num(j['latitud']),
        longitud: _num(j['longitud']),
        creado: DateTime.tryParse(j['creado']?.toString() ?? '')?.toLocal(),
      );

  static List<ReporteVial> listFromJson(Object? json) {
    final lista = json is Map<String, dynamic> ? json['results'] : json;
    if (lista is! List) return const [];
    return lista
        .whereType<Map<String, dynamic>>()
        .map(ReporteVial.fromJson)
        .toList(growable: false);
  }
}
