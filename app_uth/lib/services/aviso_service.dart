import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Avisos de heRmes que SÍ suenan: notificación local con el tono de
/// notificaciones del teléfono + vibración (sin voz; flutter_tts se quitó a
/// pedido del usuario).
///
/// ¿Por qué no basta `SystemSound.play`? En Android solo reproduce el "click"
/// del teclado, que casi no se oye. La notificación va por un CANAL de
/// importancia ALTA: suena, vibra y aparece arriba aun con la app abierta.
///
/// La notificación se hace en código nativo con el MISMO canal
/// "hermes/avisos" en las dos plataformas: MainActivity.kt (Android) y
/// AppDelegate.swift (iOS, UNUserNotificationCenter). No se usa un plugin:
/// el plugin flutter_local_notifications
/// exigía desugaring y SDK 37, y el APK salía sin clases de Kotlin coroutines
/// (la app se cerraba al abrir).
class AvisoService {
  AvisoService._();

  static final AvisoService instancia = AvisoService._();

  /// false en pruebas (`flutter test`): no toca el canal nativo, solo
  /// guarda el aviso en [historial].
  static bool habilitado =
      !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST');

  static const MethodChannel _canal = MethodChannel('hermes/avisos');

  bool _iniciado = false;

  /// Avisos enviados en esta sesión (útil en pruebas y depuración).
  final List<String> historial = [];

  /// Crea el canal de Android y pide el permiso de notificaciones
  /// (Android 13+ / iOS). Se puede llamar varias veces.
  Future<void> iniciar() async {
    if (_iniciado || !habilitado) return;
    try {
      await _canal.invokeMethod<bool>('iniciar');
      _iniciado = true;
    } catch (e) {
      debugPrint('AvisoService: no se pudo iniciar ($e)');
    }
  }

  /// Notificación con sonido + vibración doble.
  Future<void> avisar(String titulo, String cuerpo) async {
    historial.add('$titulo · $cuerpo');
    if (!habilitado) return;
    // Vibración inmediata aunque el usuario haya negado las notificaciones.
    try {
      await HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await HapticFeedback.heavyImpact();
    } catch (_) {}
    var mostrada = false;
    try {
      mostrada = await _canal.invokeMethod<bool>(
              'avisar', {'titulo': titulo, 'cuerpo': cuerpo}) ??
          false;
    } catch (e) {
      debugPrint('AvisoService: no se pudo notificar ($e)');
    }
    // Sin permiso de notificaciones (o en escritorio): sonido del sistema.
    if (!mostrada) SystemSound.play(SystemSoundType.alert);
  }
}
