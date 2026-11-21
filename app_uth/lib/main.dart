import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/splash_screen.dart';
import 'services/aviso_service.dart';
import 'theme/tema_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final temas = await TemaController.cargar();
  // Canal de notificaciones con sonido + permiso (Android 13+), sin bloquear
  // el arranque.
  AvisoService.instancia.iniciar();
  runApp(UthRadarApp(temas: temas));
}

class UthRadarApp extends StatelessWidget {
  const UthRadarApp({super.key, required this.temas});

  final TemaController temas;

  @override
  Widget build(BuildContext context) {
    return TemaScope(
      controller: temas,
      child: ListenableBuilder(
        listenable: temas,
        builder: (context, _) => MaterialApp(
          title: 'heRmes',
          debugShowCheckedModeBanner: false,
          // Cada tema fija su propio brillo (claro u oscuro).
          theme: temas.actual.data,
          // Arranca con el radar animado (descarga edificios) y luego la bienvenida.
          home: const SplashScreen(),
        ),
      ),
    );
  }
}
