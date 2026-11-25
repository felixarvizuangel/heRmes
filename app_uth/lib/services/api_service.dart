import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../models/campus_model.dart';
import '../models/edificio_model.dart';
import 'almacen_lugares.dart';

/// Origen de los datos entregados por [ApiService].
enum OrigenDatos { red, cache }

/// Resultado de la carga del catálogo con metadatos de sincronización.
class ResultadoEdificios {
  const ResultadoEdificios({
    required this.edificios,
    required this.origen,
    required this.sincronizadoEn,
    this.error,
  });

  final List<Edificio> edificios;
  final OrigenDatos origen;

  /// Momento de la última descarga exitosa (para el banner "Offline · dd/mm").
  final DateTime? sincronizadoEn;

  /// Motivo por el que se usó caché (null si vino de red).
  final String? error;

  bool get esOffline => origen == OrigenDatos.cache;
}

class ApiException implements Exception {
  const ApiException(this.mensaje);
  final String mensaje;

  @override
  String toString() => mensaje;
}

/// Cliente REST de `/api/edificios/` con caché offline (red primero,
/// caché como fallback).
class ApiService {
  ApiService({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.timeout = const Duration(seconds: 8),
    AlmacenLugares? almacen,
  })  : _client = client ?? http.Client(),
        almacen = almacen ?? AlmacenLugares();

  /// 10.0.2.2 = localhost de la máquina anfitriona desde el emulador Android.
  /// Para teléfono real: flutter run --dart-define=API_URL=http://TU_IP:8000/api
  static const String defaultBaseUrl =
      String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8000/api');

  final http.Client _client;

  /// Almacenamiento local cifrado (flutter_secure_storage) de los lugares.
  final AlmacenLugares almacen;
  final String baseUrl;
  final Duration timeout;

  Uri get _edificiosUri => Uri.parse('$baseUrl/edificios/');

  /// Último catálogo cargado en esta sesión (lista local en memoria).
  ResultadoEdificios? _sesion;

  /// Catálogo de edificios con la regla del profe: UNA petición al abrir la
  /// app y, después, todas las consultas contra los datos locales.
  ///
  /// - Primera llamada de la sesión: descarga de la red y la guarda en el
  ///   dispositivo ([AlmacenLugares], flutter_secure_storage). Si no hay
  ///   red, usa lo guardado.
  /// - Llamadas siguientes (radar, mapa, directorio…): devuelven la lista
  ///   local sin tocar la red.
  /// - [forzarRed] = true (botón "Sincronizar"): vuelve a descargar.
  ///
  /// Lanza [ApiException] solo si no hay red NI datos guardados.
  Future<ResultadoEdificios> obtenerEdificios({bool forzarRed = false}) async {
    final local = _sesion;
    if (local != null && !forzarRed) return local;
    final r = await _descargarOUsarCache(forzarRed: forzarRed);
    _sesion = r;
    return r;
  }

  Future<ResultadoEdificios> _descargarOUsarCache({
    required bool forzarRed,
  }) async {
    try {
      final edificios = await _descargarTodo();
      final ahora = DateTime.now();
      await _guardarCache(edificios, ahora);
      return ResultadoEdificios(
        edificios: _soloActivos(edificios),
        origen: OrigenDatos.red,
        sincronizadoEn: ahora,
      );
    } catch (e) {
      final motivo = _describirError(e);
      if (forzarRed) {
        // Aun forzando, preferimos caché a dejar la app vacía.
        final cache = await obtenerDesdeCache(motivo: motivo);
        if (cache != null) return cache;
        throw ApiException(motivo);
      }
      final cache = await obtenerDesdeCache(motivo: motivo);
      if (cache != null) return cache;
      // Primera vez sin backend (p. ej. la versión web en GitHub Pages):
      // copia del catálogo incluida en la app.
      final incluida = await _desdeRespaldoIncluido(motivo);
      if (incluida != null) return incluida;
      throw ApiException('$motivo Sin datos guardados en el dispositivo.');
    }
  }

  /// Lee la caché local; null si no existe o está corrupta.
  Future<ResultadoEdificios?> obtenerDesdeCache({String? motivo}) async {
    final edificios = await almacen.leerEdificios();
    if (edificios == null) return null;
    return ResultadoEdificios(
      edificios: _soloActivos(edificios),
      origen: OrigenDatos.cache,
      sincronizadoEn: await almacen.leerFechaSincronizacion(),
      error: motivo,
    );
  }

  /// Copia de `/api/edificios/` incluida en la app (regenerarla si cambian
  /// los edificios en el backend). Permite usar heRmes sin servidor.
  static const String kEdificiosRespaldo = 'assets/campus/edificios_uth.json';

  /// Lee [kEdificiosRespaldo]; null si no existe o está dañado.
  Future<ResultadoEdificios?> _desdeRespaldoIncluido(String motivo) async {
    try {
      final raw = await rootBundle.loadString(kEdificiosRespaldo);
      return ResultadoEdificios(
        edificios: _soloActivos(Edificio.listFromJson(jsonDecode(raw))),
        origen: OrigenDatos.cache,
        sincronizadoEn: null,
        error: motivo,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> limpiarCache() async {
    _sesion = null;
    await almacen.borrarEdificios();
  }

  // ───────────── Campus: puertas/entradas + andadores ─────────────

  CampusDatos? _campusSesion;

  /// Copia de `/api/campus/` incluida en la app (regenerarla si cambian las
  /// puertas o los andadores en el backend).
  static const String kCampusRespaldo = 'assets/campus/campus_uth.json';

  /// Puertas peatonales, entradas de autos y andadores (`/api/campus/`).
  /// Misma regla que los edificios: UNA petición por sesión, se guarda en el
  /// dispositivo y después todo es local. Nunca lanza: sin red usa lo
  /// guardado; sin nada guardado, la copia de [kCampusRespaldo].
  Future<CampusDatos> obtenerCampus({bool forzarRed = false}) async {
    final local = _campusSesion;
    if (local != null && !forzarRed) return local;
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/campus/'),
              headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final datos = await _conBarda(
          CampusDatos.fromJson(jsonDecode(utf8.decode(resp.bodyBytes))));
      await almacen.guardarCampus(datos);
      return _campusSesion = datos;
    } catch (_) {
      final guardado = await almacen.leerCampus();
      if (guardado != null) return _campusSesion = await _conBarda(guardado);
      // Primera vez sin backend: copia incluida en la app (assets/campus).
      try {
        final raw = await rootBundle.loadString(kCampusRespaldo);
        return _campusSesion = CampusDatos.fromJson(jsonDecode(raw));
      } catch (_) {
        return CampusDatos.vacio;
      }
    }
  }

  /// Si [d] no trae la barda (backend o caché de antes), usa la de la copia
  /// incluida en la app: sin barda no se sabe si estás dentro del campus.
  Future<CampusDatos> _conBarda(CampusDatos d) async {
    if (d.perimetro.length >= 3) return d;
    try {
      final raw = await rootBundle.loadString(kCampusRespaldo);
      final barda = CampusDatos.fromJson(jsonDecode(raw)).perimetro;
      return barda.length >= 3 ? d.conPerimetro(barda) : d;
    } catch (_) {
      return d;
    }
  }

  // ───────────── Reportes viales (modo carro) ─────────────

  /// Reportes vigentes de la comunidad (siempre de la red: cambian seguido).
  /// Sin red devuelve lista vacía; nunca lanza.
  Future<List<ReporteVial>> obtenerReportes() async {
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/reportes/'),
              headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (resp.statusCode != 200) return const [];
      return ReporteVial.listFromJson(jsonDecode(utf8.decode(resp.bodyBytes)));
    } catch (_) {
      return const [];
    }
  }

  /// Publica un reporte en la posición dada. Devuelve null si se guardó, o
  /// el motivo del error para mostrarlo.
  Future<String?> crearReporte(TipoReporte tipo, double lat, double lon,
      {String descripcion = ''}) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/reportes/'),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'tipo': tipo.api,
              'latitud': lat.toStringAsFixed(6),
              'longitud': lon.toStringAsFixed(6),
              'descripcion': descripcion,
            }),
          )
          .timeout(timeout);
      if (resp.statusCode == 201) return null;
      if (resp.statusCode == 429) return 'Demasiados reportes, espera un rato.';
      return 'No se pudo guardar (HTTP ${resp.statusCode}).';
    } catch (e) {
      return _describirError(e);
    }
  }

  void dispose() => _client.close();

  /// Recorre la paginación de DRF si está activa; si no, una sola petición.
  Future<List<Edificio>> _descargarTodo() async {
    final resultado = <Edificio>[];
    Uri? siguiente = _edificiosUri;
    var paginas = 0;
    while (siguiente != null && paginas < 50) {
      final resp = await _client
          .get(siguiente, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: siguiente);
      }
      final body = jsonDecode(utf8.decode(resp.bodyBytes));
      resultado.addAll(Edificio.listFromJson(body));
      final next = body is Map<String, dynamic> ? body['next'] : null;
      siguiente = next is String && next.isNotEmpty ? Uri.parse(next) : null;
      paginas++;
    }
    return resultado;
  }

  Future<void> _guardarCache(List<Edificio> edificios, DateTime fecha) =>
      almacen.guardarEdificios(edificios, fecha);

  List<Edificio> _soloActivos(List<Edificio> lista) => lista
      .where((e) => e.activo && e.coordenadas.isNotEmpty)
      .toList(growable: false);

  String _describirError(Object e) {
    if (e is TimeoutException) return 'El servidor no respondió a tiempo.';
    if (e is SocketException) return 'Sin conexión con el servidor.';
    if (e is http.ClientException) return 'Error de red: ${e.message}.';
    if (e is HttpException) return 'Respuesta inválida (${e.message}).';
    if (e is FormatException) return 'Respuesta JSON inválida.';
    return 'Error inesperado: $e.';
  }
}
