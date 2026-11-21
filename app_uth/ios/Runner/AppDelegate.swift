import AudioToolbox
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Canal propio de heRmes (equivalente iOS de MainActivity.kt).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HermesAvisos") {
      HermesAvisos.registrar(con: registrar)
    }
  }
}

/// Avisos de heRmes en iOS: notificación local NATIVA con sonido + vibración,
/// sin plugins (igual que MainActivity.kt en Android).
///
/// Canal Flutter "hermes/avisos" (mismo nombre y métodos que usa
/// lib/services/aviso_service.dart):
///  - iniciar: pide permiso de notificaciones (alerta + sonido). Devuelve
///    true si el usuario lo concedió.
///  - avisar(titulo, cuerpo): muestra la notificación al instante y vibra
///    dos veces. Devuelve false si no hay permiso (Dart entonces usa el
///    sonido del sistema).
///
/// También es el "delegate" del centro de notificaciones para que el aviso
/// se vea y suene AUNQUE la app esté abierta (iOS lo oculta por defecto).
final class HermesAvisos: NSObject, UNUserNotificationCenterDelegate {

  private static let canalFlutter = "hermes/avisos"
  /// Se guarda una referencia fuerte: el delegate de iOS es "weak".
  private static var instancia: HermesAvisos?

  private let centro = UNUserNotificationCenter.current()

  static func registrar(con registrar: FlutterPluginRegistrar) {
    let avisos = HermesAvisos()
    instancia = avisos
    avisos.centro.delegate = avisos

    let canal = FlutterMethodChannel(
      name: canalFlutter, binaryMessenger: registrar.messenger())
    canal.setMethodCallHandler { llamada, resultado in
      switch llamada.method {
      case "iniciar":
        avisos.pedirPermiso { concedido in resultado(concedido) }
      case "avisar":
        let args = llamada.arguments as? [String: Any]
        let titulo = args?["titulo"] as? String ?? "heRmes"
        let cuerpo = args?["cuerpo"] as? String ?? ""
        avisos.avisar(titulo: titulo, cuerpo: cuerpo) { mostrada in resultado(mostrada) }
      default:
        resultado(FlutterMethodNotImplemented)
      }
    }
  }

  /// Pide permiso de alerta + sonido. Si ya se respondió antes, iOS no vuelve
  /// a preguntar y solo devuelve la decisión guardada.
  private func pedirPermiso(_ listo: @escaping (Bool) -> Void) {
    centro.requestAuthorization(options: [.alert, .sound]) { concedido, _ in
      DispatchQueue.main.async { listo(concedido) }
    }
  }

  private func avisar(titulo: String, cuerpo: String, _ listo: @escaping (Bool) -> Void) {
    vibrarDoble()
    centro.getNotificationSettings { ajustes in
      let permitido = ajustes.authorizationStatus == .authorized
        || ajustes.authorizationStatus == .provisional
      guard permitido else {
        DispatchQueue.main.async { listo(false) }
        return
      }
      let contenido = UNMutableNotificationContent()
      contenido.title = titulo
      contenido.body = cuerpo
      contenido.sound = .default  // tono de notificaciones del iPhone
      // trigger nil = se muestra de inmediato.
      let solicitud = UNNotificationRequest(
        identifier: UUID().uuidString, content: contenido, trigger: nil)
      self.centro.add(solicitud) { error in
        DispatchQueue.main.async { listo(error == nil) }
      }
    }
  }

  /// Vibración doble, como el patrón [0, 350, 200, 350] de Android. iOS no
  /// deja fijar la duración; se lanzan dos vibraciones del sistema seguidas.
  private func vibrarDoble() {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
      AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
  }

  // Con la app en primer plano iOS no muestra el aviso salvo que se lo pidamos.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])  // banner arriba + centro de avisos + tono
  }
}
