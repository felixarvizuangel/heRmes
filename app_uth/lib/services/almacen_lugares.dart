import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/campus_model.dart';
import '../models/edificio_model.dart';

/// Almacenamiento local de lugares de heRmes (misma idea que la clase de la
/// práctica iCamp, pero para edificios y sus ubicaciones GPS).
///
/// Guarda en el dispositivo, con `flutter_secure_storage`, lo que se
/// descarga UNA sola vez al abrir la app:
///   - el catálogo de los 23 lugares (edificios y áreas) con todos sus
///     puntos GPS (entrada principal, secundarias y esquinas),
///   - la fecha de la última sincronización,
///   - los datos del campus (puertas, andadores y barda).
///
/// ¿Cómo se guarda? `flutter_secure_storage` solo guarda pares
/// clave → texto. Por eso cada lista se convierte a JSON (`jsonEncode`) al
/// guardar y se vuelve a convertir a objetos Dart (`fromJson`) al leer.
/// En Android el texto queda cifrado con una llave del Android Keystore; en
/// iOS, en el Keychain. Ninguna otra app puede leerlo.
///
/// Estructura de lo guardado (clave → valor):
///   hermes_edificios_v1        → '[{"id":1,"codigo":"EDIF-A","nombre":…,
///                                  "radio_cobertura_m":20,
///                                  "coordenadas":[{"tipo":"ENTRADA_PRINCIPAL",
///                                  "latitud":29.0091,"longitud":-110.9035,
///                                  "es_transitable":true,…}]}, …]'
///   hermes_edificios_fecha_v1  → '1795645148398'  (milisegundos desde 1970)
///   hermes_campus_v1           → '{"accesos":[…],"andadores":[…],"perimetro":[…]}'
///
/// Nunca lanza excepciones hacia la pantalla: si el almacenamiento falla o
/// el texto está dañado, se comporta como si no hubiera nada guardado y la
/// app usa la copia incluida en `assets/campus/`.
class AlmacenLugares {
  AlmacenLugares({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  // Claves. El sufijo _v1 permite cambiar el formato en el futuro sin leer
  // datos viejos con la estructura equivocada.
  static const String kEdificios = 'hermes_edificios_v1';
  static const String kFecha = 'hermes_edificios_fecha_v1';
  static const String kCampus = 'hermes_campus_v1';

  final FlutterSecureStorage _storage;

  // ───────────────────────── Edificios ─────────────────────────

  /// Guarda el catálogo completo y la fecha de descarga.
  Future<void> guardarEdificios(List<Edificio> edificios, DateTime fecha) async {
    final json = jsonEncode([for (final e in edificios) e.toJson()]);
    await _escribir(kEdificios, json);
    await _escribir(kFecha, fecha.millisecondsSinceEpoch.toString());
  }

  /// Lee el catálogo guardado; null si no hay nada o está dañado.
  Future<List<Edificio>?> leerEdificios() async {
    final raw = await _leer(kEdificios);
    if (raw == null) return null;
    try {
      return Edificio.listFromJson(jsonDecode(raw));
    } on FormatException {
      await _borrar(kEdificios); // texto dañado: se descarta
      return null;
    }
  }

  /// Fecha de la última descarga exitosa (para el aviso "Offline · dd/mm").
  Future<DateTime?> leerFechaSincronizacion() async {
    final ms = int.tryParse(await _leer(kFecha) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// true si ya hay un catálogo guardado en el dispositivo.
  Future<bool> hayCatalogo() async => (await _leer(kEdificios)) != null;

  /// Busca un lugar guardado por su código (p. ej. "EDIF-B" o "AREA-5").
  Future<Edificio?> buscarPorCodigo(String codigo) async {
    final lista = await leerEdificios();
    if (lista == null) return null;
    for (final e in lista) {
      if (e.codigo.toUpperCase() == codigo.toUpperCase()) return e;
    }
    return null;
  }

  /// Todos los puntos GPS guardados de un lugar (entradas y esquinas).
  Future<List<CoordenadaGps>> coordenadasDe(String codigo) async =>
      (await buscarPorCodigo(codigo))?.coordenadas ?? const [];

  // ───────────────────────── Campus ─────────────────────────

  /// Guarda puertas, entradas de autos, andadores y barda del campus.
  Future<void> guardarCampus(CampusDatos datos) =>
      _escribir(kCampus, jsonEncode(datos.toJson()));

  /// Lee los datos del campus; null si no hay o están dañados.
  Future<CampusDatos?> leerCampus() async {
    final raw = await _leer(kCampus);
    if (raw == null) return null;
    try {
      return CampusDatos.fromJson(jsonDecode(raw));
    } on FormatException {
      await _borrar(kCampus);
      return null;
    }
  }

  // ───────────────────────── Limpieza ─────────────────────────

  /// Borra el catálogo y su fecha (botón "Sincronizar" lo vuelve a bajar).
  Future<void> borrarEdificios() async {
    await _borrar(kEdificios);
    await _borrar(kFecha);
  }

  /// Borra todo lo que heRmes guardó en el dispositivo.
  Future<void> borrarTodo() async {
    await borrarEdificios();
    await _borrar(kCampus);
  }

  // ─────────── Acceso a flutter_secure_storage (sin excepciones) ───────────

  Future<String?> _leer(String clave) async {
    try {
      return await _storage.read(key: clave);
    } catch (_) {
      return null; // sin almacenamiento disponible = nada guardado
    }
  }

  Future<void> _escribir(String clave, String valor) async {
    try {
      await _storage.write(key: clave, value: valor);
    } catch (_) {
      // Si no se pudo guardar, la app sigue con los datos en memoria.
    }
  }

  Future<void> _borrar(String clave) async {
    try {
      await _storage.delete(key: clave);
    } catch (_) {}
  }
}
