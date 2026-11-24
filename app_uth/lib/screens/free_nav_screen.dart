import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../models/edificio_model.dart';
import '../services/api_service.dart';
import '../services/aviso_service.dart';
import '../services/geo_math_service.dart';
import '../services/geocerca_service.dart';
import '../widgets/foto_fachada.dart';
import '../widgets/hermes_cargando.dart';
import 'detalle_screen.dart';

/// Navegación libre · Modo B (nivel 8).
///
/// Mientras no hay ningún edificio cerca se muestra el radar con el texto
/// "Buscando edificios cercanos…". Cada [_intervalo] (5 s) se compara la
/// última posición GPS contra los edificios guardados en el dispositivo:
///
///   1. Punto en polígono: si el usuario está DENTRO de las esquinas del
///      edificio → distancia 0 ("Estás aquí").
///   2. Si no, distancia a la pared más cercana (o a su puerta), Haversine.
///   3. Anillo de cercanía: a ≤ radio_cobertura_m (20 m / 30 m áreas).
///
/// La regla vive en [GeocercaService] (lógica pura, con tests unitarios).
///
/// Si hay DOS O MÁS edificios cerca se muestran TODOS en una lista ordenada
/// por distancia ("A tu izquierda · Edificio X · 12 m"). Al aparecer uno
/// nuevo: notificación con sonido + vibración ([AvisoService]).
/// Un edificio no vuelve a avisar hasta que el usuario sale de su radio
/// + 5 m (histéresis, evita avisos repetidos por el ruido del GPS).
class FreeNavScreen extends StatefulWidget {
  const FreeNavScreen({super.key, required this.edificios, this.apiService});

  /// Lista LOCAL (descargada en la bienvenida). No se hacen peticiones aquí.
  final List<Edificio> edificios;
  final ApiService? apiService;

  @override
  State<FreeNavScreen> createState() => _FreeNavScreenState();
}

class _FreeNavScreenState extends State<FreeNavScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  /// Cada cuánto se revisa la posición contra los edificios (profe: 5–10 s).
  static const Duration _intervalo = Duration(seconds: 5);

  final GeocercaService _geocerca = GeocercaService(histeresisM: 5.0);
  final CompassLowPassFilter _filtro = CompassLowPassFilter(alpha: 0.15);
  late final AnimationController _giro = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  StreamSubscription<Position>? _subPosicion;
  StreamSubscription<CompassEvent>? _subBrujula;
  Timer? _timer;

  Position? _posicion;
  double? _heading;
  String? _errorUbicacion;

  /// Edificios cerca ahora mismo, del más cercano al más lejano.
  List<Deteccion> _cercanos = const [];

  /// Ids que el usuario cerró con la X (vuelven al alejarse y regresar).
  final Set<int> _ocultos = {};

  /// Edificio más cercano aunque esté fuera de radio (texto de ayuda).
  Deteccion? _masCercano;

  /// true mientras el detalle está abierto (no se avisa nada nuevo).
  bool _viendoDetalle = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _iniciar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detener();
    _giro.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ahorra batería: apaga sensores en segundo plano.
    if (state == AppLifecycleState.paused) {
      _detener();
    } else if (state == AppLifecycleState.resumed) {
      _filtro.reset();
      _iniciar();
    }
  }

  // ───────────────────────── Sensores ─────────────────────────

  Future<void> _iniciar() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) setState(() => _errorUbicacion = 'El GPS está apagado.');
      return;
    }
    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }
    if (!mounted) return;
    if (permiso == LocationPermission.denied ||
        permiso == LocationPermission.deniedForever) {
      setState(() => _errorUbicacion = 'Se necesita permiso de ubicación.');
      return;
    }
    setState(() => _errorUbicacion = null);

    // 1) GPS: el stream solo guarda la última posición; la comparación
    //    contra los edificios la hace el Timer cada 5 s.
    await _subPosicion?.cancel();
    _subPosicion = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
      ),
    ).listen((pos) {
      final primera = _posicion == null;
      _posicion = pos;
      if (primera) _evaluar(); // primera lectura: evalúa sin esperar 5 s
    });

    // 2) Brújula: para decir "a tu izquierda / derecha…".
    await _subBrujula?.cancel();
    _subBrujula = FlutterCompass.events?.listen((ev) {
      final raw = ev.heading;
      if (raw == null || !mounted) return;
      setState(() => _heading = _filtro.filter(raw));
    }, onError: (Object _) {
      // Sin brújula (p. ej. la versión web en Safari): se sigue sin rumbo.
    });

    // 3) Revisión periódica contra los edificios guardados.
    _timer?.cancel();
    _timer = Timer.periodic(_intervalo, (_) => _evaluar());
  }

  void _detener() {
    _subPosicion?.cancel();
    _subPosicion = null;
    _subBrujula?.cancel();
    _subBrujula = null;
    _timer?.cancel();
    _timer = null;
  }

  // ───────────────────────── Geocerca ─────────────────────────

  void _evaluar() {
    final pos = _posicion;
    if (pos == null || !mounted) return;

    final r = _geocerca.evaluar(
      widget.edificios,
      pos.latitude,
      pos.longitude,
      // Con el detalle abierto no se "gastan" los avisos: se dan al volver.
      registrarAviso: !_viendoDetalle,
    );

    setState(() {
      _masCercano = r.masCercano;
      _cercanos = r.cercanos;
      // Un edificio cerrado con la X reaparece cuando el usuario se aleja
      // (radio + 5 m) y vuelve a entrar.
      _ocultos.removeWhere((id) => !_geocerca.yaAvisado(id));
    });

    if (r.nuevos.isNotEmpty && !_viendoDetalle) _avisar(r.nuevos);
  }

  /// Notificación con sonido + vibración por los edificios que acaban de
  /// entrar a la geocerca (uno o varios a la vez).
  void _avisar(List<Deteccion> nuevos) {
    final primero = nuevos.first;
    final titulo = nuevos.length == 1
        ? (primero.dentro
            ? 'Estás en ${primero.edificio.nombre}'
            : 'Cerca: ${primero.edificio.nombre}')
        : '${nuevos.length} lugares cerca';
    final cuerpo = nuevos.length == 1
        ? '${_direccion(primero)} · ${_distanciaTexto(primero)}'
        : nuevos
            .map((d) => '${d.edificio.codigo} ${_distanciaTexto(d)}')
            .join(' · ');
    AvisoService.instancia.avisar(titulo, cuerpo);
  }

  /// "A tu izquierda", "Al frente"… según el rumbo a la pared más cercana y
  /// el heading del teléfono: (rumbo − heading) mod 360 → cuadrante.
  String _direccion(Deteccion d) {
    if (d.dentro) return 'Estás aquí';
    final pos = _posicion;
    final h = _heading;
    if (pos == null || h == null) return 'Cerca de ti';
    final rumbo = d.rumboDesde(pos.latitude, pos.longitude);
    return GeoMathService.quadrantText(rumbo, h);
  }

  static String _distanciaTexto(Deteccion d) =>
      d.dentro ? 'dentro' : '${d.distancia.round()} m';

  Future<void> _abrirDetalle(Edificio e) async {
    _viendoDetalle = true;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetalleScreen(
        edificio: e,
        apiService: widget.apiService,
        mostrarNavegar: false,
      ),
    ));
    if (!mounted) return;
    _viendoDetalle = false;
    _evaluar();
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Navegación libre')),
      body: SafeArea(
        child: _errorUbicacion != null ? _errorGps(context) : _cuerpo(context),
      ),
    );
  }

  Widget _cuerpo(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;
    final visibles = [
      for (final d in _cercanos)
        if (!_ocultos.contains(d.edificio.id)) d,
    ];
    final cercano = _masCercano;
    final hayLista = visibles.isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Radar de heRmes barriendo (más chico si hay lista).
                  HermesCargando(
                    tamano: hayLista ? 150 : 260,
                    mostrarIcono: false,
                    color: esquema.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _posicion == null
                        ? 'Obteniendo tu ubicación…'
                        : hayLista
                            ? (visibles.length == 1
                                ? '1 lugar cerca de ti'
                                : '${visibles.length} lugares cerca de ti')
                            : 'Buscando edificios cercanos…',
                    style: tema.textTheme.titleLarge
                        ?.copyWith(color: esquema.primary),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  if (cercano != null && !hayLista)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'Más cercano: ${cercano.edificio.nombre} · ${cercano.distancia.round()} m',
                        style: tema.textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (_posicion != null)
                    Text(
                      'Precisión GPS ±${_posicion!.accuracy.toStringAsFixed(0)} m · revisión cada ${_intervalo.inSeconds} s',
                      style: tema.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ),
        // Lista de edificios cerca (uno o varios), del más cercano al más lejano.
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          alignment: Alignment.topCenter,
          child: !hayLista
              ? const SizedBox(width: double.infinity)
              : ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.48,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: visibles.length,
                    itemBuilder: (_, i) =>
                        _tarjeta(context, visibles[i], principal: i == 0),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _tarjeta(BuildContext context, Deteccion d, {required bool principal}) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;
    final e = d.edificio;
    final fondo =
        principal ? esquema.primaryContainer : esquema.surfaceContainerHigh;
    final texto =
        principal ? esquema.onPrimaryContainer : esquema.onSurface;
    final foto = principal ? 88.0 : 64.0;

    return Card(
      key: ValueKey(e.id),
      color: fondo,
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: () => _abrirDetalle(e),
        child: Row(
          children: [
            SizedBox(
              width: foto,
              height: foto,
              child: FotoFachada(
                edificio: e,
                sinFoto: Icon(Icons.apartment, size: foto / 2, color: texto),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_direccion(d)} · ${_distanciaTexto(d)}',
                      style: tema.textTheme.labelLarge?.copyWith(color: texto),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.nombre,
                      style: (principal
                              ? tema.textTheme.titleMedium
                              : tema.textTheme.bodyLarge)
                          ?.copyWith(color: texto),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (principal)
                      Text(
                        'Toca para ver la información',
                        style: tema.textTheme.bodySmall?.copyWith(color: texto),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Ocultar',
              icon: Icon(Icons.close, color: texto),
              onPressed: () => setState(() => _ocultos.add(e.id)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorGps(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_off, size: 64),
            const SizedBox(height: 16),
            Text(_errorUbicacion!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                await Geolocator.openLocationSettings();
                _iniciar();
              },
              child: const Text('Activar ubicación'),
            ),
            TextButton(onPressed: _iniciar, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}
