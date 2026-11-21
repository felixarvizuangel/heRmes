import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../widgets/hermes_cargando.dart';
import '../widgets/nombre_hermes.dart';
import 'welcome_screen.dart';

/// Pantalla de arranque animada de heRmes.
///
/// Mientras se muestra el radar girando, se hace la ÚNICA descarga del
/// catálogo (o se lee lo guardado si no hay red). Cuando termina, y tras un
/// mínimo de [_minimo] para que la animación se aprecie, pasa a la bienvenida
/// con el mismo [ApiService], que ya tiene la lista en memoria: la bienvenida
/// no vuelve a pedir nada a la red.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.apiService});

  final ApiService? apiService;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  static const Duration _minimo = Duration(milliseconds: 2200);
  static const Color _fondo = Color(0xFF141D44); // azul del ícono

  late final ApiService _api = widget.apiService ?? ApiService();

  @override
  void initState() {
    super.initState();
    _arrancar();
  }

  Future<void> _arrancar() async {
    await Future.wait([
      // Si falla (sin red y sin caché), la bienvenida muestra el error
      // y el botón Reintentar; aquí no se detiene el arranque.
      _api.obtenerEdificios().then<void>((_) {}, onError: (_) {}),
      Future<void>.delayed(_minimo),
    ]);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (_, __, ___) => WelcomeScreen(apiService: _api),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: _fondo,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HermesCargando(tamano: 240),
            SizedBox(height: 28),
            NombreHermes(
              tamano: 48,
              color: Colors.white,
              colorR: Color(0xFFC6F432),
            ),
            SizedBox(height: 8),
            Text(
              'Trazando los caminos del campus…',
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}
