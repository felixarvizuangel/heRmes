import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../models/edificio_model.dart';
import '../services/api_service.dart';
import '../services/geo_math_service.dart';
import '../theme/tema_controller.dart';
import '../theme/uth_themes.dart';
import '../widgets/foto_fachada.dart';

/// Estado del permiso / servicio de ubicación.
enum _EstadoUbicacion {
  verificando,
  servicioApagado,
  denegado,
  denegadoPermanente,
  activo,
}

/// Modo A · Navegación por brújula (radar) hacia la puerta del edificio.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, this.apiService, this.edificioInicial});

  final ApiService? apiService;
  final Edificio? edificioInicial;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> with WidgetsBindingObserver {
  /// Por encima de este error (m) el GPS se considera de baja precisión.
  static const double _umbralPrecisionM = 20.0;

  /// Histéresis para re-armar el aviso de llegada.
  static const double _histeresisM = 5.0;

  late final ApiService _api = widget.apiService ?? ApiService();
  final CompassLowPassFilter _filtro = CompassLowPassFilter(alpha: 0.15);

  // Catálogo
  ResultadoEdificios? _resultado;
  bool _cargando = true;
  String? _errorCarga;
  Edificio? _seleccionado;

  // Sensores
  _EstadoUbicacion _estadoUbicacion = _EstadoUbicacion.verificando;
  StreamSubscription<Position>? _subPosicion;
  StreamSubscription<ServiceStatus>? _subServicio;
  StreamSubscription<CompassEvent>? _subBrujula;
  Position? _posicion;
  double? _heading; // filtrado, [0, 360)
  double? _precisionBrujula;
  bool _sinMagnetometro = false;

  // Derivados
  CoordenadaGps? _destino;
  double? _distancia;
  double? _rumbo;
  Cuadrante? _cuadrante;
  double? _distanciaInicial;
  bool _llegadaNotificada = false;

  // Rotaciones acumuladas (en vueltas) para animar siempre por el camino corto.
  double _vueltasAguja = 0;
  double _vueltasDial = 0;
  double? _ultimaRotAguja;
  double? _ultimoHeadingDial;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _seleccionado = widget.edificioInicial;
    _cargarEdificios();
    _iniciarUbicacion();
    _iniciarBrujula();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detenerSensores();
    _subServicio?.cancel();
    if (widget.apiService == null) _api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _detenerSensores();
    } else if (state == AppLifecycleState.resumed) {
      _filtro.reset();
      _iniciarUbicacion();
      _iniciarBrujula();
    }
  }

  // ───────────────────────── Datos ─────────────────────────

  Future<void> _cargarEdificios({bool forzarRed = false}) async {
    setState(() {
      _cargando = true;
      _errorCarga = null;
    });
    try {
      final r = await _api.obtenerEdificios(forzarRed: forzarRed);
      if (!mounted) return;
      setState(() {
        _resultado = r;
        _cargando = false;
        // Re-vincula la selección con la versión más reciente del edificio.
        final actual = _seleccionado;
        if (actual != null) {
          _seleccionado = r.edificios
              .firstWhere((e) => e.id == actual.id, orElse: () => actual);
        }
        _recalcular();
      });
      if (r.esOffline && r.error != null) _snack(r.error!);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _errorCarga = e.mensaje;
      });
    }
  }

  // ───────────────────────── Ubicación ─────────────────────────

  Future<void> _iniciarUbicacion() async {
    _subServicio ??= _escucharServicio();

    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) {
        setState(() => _estadoUbicacion = _EstadoUbicacion.servicioApagado);
      }
      return;
    }

    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }
    if (!mounted) return;

    if (permiso == LocationPermission.denied) {
      setState(() => _estadoUbicacion = _EstadoUbicacion.denegado);
      return;
    }
    if (permiso == LocationPermission.deniedForever) {
      setState(() => _estadoUbicacion = _EstadoUbicacion.denegadoPermanente);
      return;
    }

    setState(() => _estadoUbicacion = _EstadoUbicacion.activo);
    await _subPosicion?.cancel();
    _subPosicion = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      ),
    ).listen(
      (pos) {
        if (!mounted) return;
        setState(() {
          _posicion = pos;
          _recalcular();
        });
      },
      onError: (Object _) {
        if (mounted) {
          setState(() => _estadoUbicacion = _EstadoUbicacion.servicioApagado);
        }
      },
    );
  }

  StreamSubscription<ServiceStatus>? _escucharServicio() {
    try {
      return Geolocator.getServiceStatusStream().listen((estado) {
        if (estado == ServiceStatus.enabled) {
          _iniciarUbicacion();
        } else if (mounted) {
          _subPosicion?.cancel();
          _subPosicion = null;
          setState(() => _estadoUbicacion = _EstadoUbicacion.servicioApagado);
        }
      });
    } on UnimplementedError {
      return null;
    }
  }

  // ───────────────────────── Brújula ─────────────────────────

  void _iniciarBrujula() {
    _subBrujula?.cancel();
    final eventos = FlutterCompass.events;
    if (eventos == null) {
      setState(() => _sinMagnetometro = true);
      return;
    }
    _subBrujula = eventos.listen(
      (evento) {
        final raw = evento.heading;
        if (!mounted) return;
        if (raw == null) {
          setState(() => _sinMagnetometro = true);
          return;
        }
        setState(() {
          _sinMagnetometro = false;
          _precisionBrujula = evento.accuracy;
          _heading = _filtro.filter(raw);
          _recalcular();
        });
      },
      onError: (Object _) {
        if (mounted) setState(() => _sinMagnetometro = true);
      },
    );
  }

  void _detenerSensores() {
    _subPosicion?.cancel();
    _subPosicion = null;
    _subBrujula?.cancel();
    _subBrujula = null;
  }

  // ───────────────────────── Cálculo ─────────────────────────

  /// Recalcula destino, distancia, rumbo, cuadrante y rotaciones.
  /// Se invoca dentro de setState.
  void _recalcular() {
    final edificio = _seleccionado;
    final pos = _posicion;
    final heading = _heading;

    // Dial: gira con -heading por el camino más corto.
    if (heading != null) {
      final previo = _ultimoHeadingDial;
      if (previo == null) {
        _vueltasDial = -heading / 360.0;
      } else {
        _vueltasDial -=
            GeoMathService.shortestAngleDelta(previo, heading) / 360.0;
      }
      _ultimoHeadingDial = heading;
    }

    if (edificio == null || pos == null) {
      _destino = edificio?.entradaPrincipal;
      _distancia = null;
      _rumbo = null;
      _cuadrante = null;
      return;
    }

    final destino = edificio.puertaMasCercana(pos.latitude, pos.longitude);
    _destino = destino;
    if (destino == null) return;

    final d = destino.distanciaDesde(pos.latitude, pos.longitude);
    final b = destino.rumboDesde(pos.latitude, pos.longitude);
    _distancia = d;
    _rumbo = b;
    _distanciaInicial ??= d;

    if (heading != null) {
      // Aguja: (bearing − heading) mod 360, animada por el camino más corto.
      final rot = GeoMathService.needleRotation(b, heading);
      final previa = _ultimaRotAguja;
      if (previa == null) {
        _vueltasAguja = rot / 360.0;
      } else {
        _vueltasAguja += GeoMathService.shortestAngleDelta(previa, rot) / 360.0;
      }
      _ultimaRotAguja = rot;

      final nuevo = GeoMathService.quadrant(b, heading);
      if (_cuadrante != null && nuevo != _cuadrante) {
        HapticFeedback.selectionClick();
      }
      _cuadrante = nuevo;
    } else {
      _cuadrante = null;
    }

    // Llegada (umbral 15 m) con histéresis.
    if (GeoMathService.hasArrived(d) && !_llegadaNotificada) {
      _llegadaNotificada = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _alLlegar(edificio));
    } else if (d > GeoMathService.arrivalThresholdMeters + _histeresisM) {
      _llegadaNotificada = false;
    }
  }

  void _seleccionar(Edificio? edificio) {
    setState(() {
      _seleccionado = edificio;
      _distanciaInicial = null;
      _llegadaNotificada = false;
      _ultimaRotAguja = null;
      _cuadrante = null;
      _filtro.reset();
      _ultimoHeadingDial = null;
      _recalcular();
    });
  }

  Future<void> _alLlegar(Edificio edificio) async {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    await _mostrarFicha(edificio, llegada: true);
  }

  void _snack(String mensaje) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(mensaje)));
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final edificio = _seleccionado;
    return Scaffold(
      appBar: AppBar(
        leading: edificio == null
            ? null
            : IconButton(
                tooltip: 'Detener ruta',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _seleccionar(null),
              ),
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _abrirSelector,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        edificio?.nombre ?? 'Elige un destino',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
                if (_destino != null)
                  Text(
                    _destino!.nombreVisible,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).appBarTheme.foregroundColor),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          const BotonTemas(),
          IconButton(
            tooltip: 'Sincronizar',
            icon: const Icon(Icons.sync),
            onPressed:
                _cargando ? null : () => _cargarEdificios(forzarRed: true),
          ),
        ],
      ),
      body: SafeArea(child: _cuerpo(context)),
      bottomNavigationBar: edificio == null ? null : _acciones(edificio),
    );
  }

  Widget _cuerpo(BuildContext context) {
    if (_cargando && _resultado == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorCarga != null && _resultado == null) {
      return _EstadoVacio(
        icono: Icons.cloud_off,
        titulo: 'No se pudo cargar el catálogo',
        detalle: _errorCarga!,
        accion: 'Reintentar',
        onAccion: _cargarEdificios,
      );
    }

    return Column(
      children: [
        if (_resultado?.esOffline ?? false) _bannerOffline(context),
        if (_estadoUbicacion != _EstadoUbicacion.activo &&
            _estadoUbicacion != _EstadoUbicacion.verificando)
          _bannerUbicacion(context),
        Expanded(
          child: _seleccionado == null
              ? _EstadoVacio(
                  icono: Icons.explore_outlined,
                  titulo: 'Selecciona un edificio',
                  detalle:
                      'La aguja te guiará hasta la puerta más cercana del edificio.',
                  accion: 'Elegir destino',
                  onAccion: _abrirSelector,
                )
              : _radar(context),
        ),
      ],
    );
  }

  Widget _radar(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;
    final pos = _posicion;
    final baja = pos != null && pos.accuracy > _umbralPrecisionM;
    final distancia = _distancia;
    final calibrar = !_sinMagnetometro &&
        _precisionBrujula != null &&
        _precisionBrujula! > 30;

    return LayoutBuilder(
      builder: (context, c) {
        final lado = math.min(c.maxWidth - 48, c.maxHeight * 0.5);
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              if (calibrar)
                Chip(
                  avatar: const Icon(Icons.all_inclusive, size: 18),
                  label: const Text('Calibra: mueve el teléfono en ∞'),
                  backgroundColor: esquema.tertiaryContainer,
                ),
              const SizedBox(height: 8),
              SizedBox.square(
                dimension: lado.clamp(200.0, 360.0),
                child: _sinMagnetometro
                    ? _SinBrujula(esquema: esquema)
                    : _Dial(
                        vueltasDial: _vueltasDial,
                        vueltasAguja: _vueltasAguja,
                        cuadrante: _cuadrante,
                        mostrarAguja: _heading != null && _rumbo != null,
                      ),
              ),
              const SizedBox(height: 24),
              Semantics(
                liveRegion: true,
                label: distancia == null
                    ? 'Calculando distancia'
                    : '${_formatearDistancia(distancia)} hasta ${_seleccionado!.nombre}',
                child: Text(
                  distancia == null ? '— m' : _formatearDistancia(distancia),
                  style: tema.textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: baja ? esquema.outline : esquema.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _textoCuadrante(),
                style: tema.textTheme.headlineSmall?.copyWith(
                  color: _cuadrante == Cuadrante.aTusEspaldas
                      ? esquema.tertiary
                      : esquema.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _textoDetalle(baja),
                style: tema.textTheme.bodySmall
                    ?.copyWith(color: baja ? esquema.error : null),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              _progresoLlegada(context),
            ],
          ),
        );
      },
    );
  }

  Widget _progresoLlegada(BuildContext context) {
    final d = _distancia;
    final d0 = _distanciaInicial;
    const umbral = GeoMathService.arrivalThresholdMeters;
    double? valor;
    if (d != null && d0 != null) {
      final rango = d0 - umbral;
      valor = rango <= 0 ? 1.0 : (1 - (d - umbral) / rango).clamp(0.0, 1.0);
    }
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: valor, minHeight: 8),
          ),
        ),
        const SizedBox(width: 12),
        Text('${umbral.toStringAsFixed(0)} m llegada',
            style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }

  Widget _acciones(Edificio edificio) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                onPressed: () => _mostrarFicha(edificio),
                child: const Text('Ver ficha'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                onPressed: () => _seleccionar(null),
                icon: const Icon(Icons.stop),
                label: const Text('Detener ruta'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bannerOffline(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final f = _resultado?.sincronizadoEn;
    final fecha = f == null
        ? 'fecha desconocida'
        : '${_dos(f.day)}/${_dos(f.month)} ${_dos(f.hour)}:${_dos(f.minute)}';
    return Material(
      color: esquema.tertiaryContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.cloud_off, color: esquema.onTertiaryContainer),
        title: Text('Offline · datos de $fecha',
            style: TextStyle(color: esquema.onTertiaryContainer)),
        trailing: TextButton(
          onPressed: _cargando ? null : () => _cargarEdificios(forzarRed: true),
          child: const Text('Reintentar'),
        ),
      ),
    );
  }

  Widget _bannerUbicacion(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final (String texto, String accion, Future<void> Function() onTap) =
        switch (_estadoUbicacion) {
      _EstadoUbicacion.servicioApagado => (
          'El GPS está apagado.',
          'Activar',
          () async {
            await Geolocator.openLocationSettings();
          },
        ),
      _EstadoUbicacion.denegado => (
          'Se necesita permiso de ubicación.',
          'Permitir',
          _iniciarUbicacion,
        ),
      _ => (
          'Permiso de ubicación bloqueado.',
          'Ajustes',
          () async {
            await Geolocator.openAppSettings();
          },
        ),
    };
    return Material(
      color: esquema.errorContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.location_off, color: esquema.onErrorContainer),
        title: Text(texto, style: TextStyle(color: esquema.onErrorContainer)),
        trailing: TextButton(onPressed: onTap, child: Text(accion)),
      ),
    );
  }

  String _textoCuadrante() {
    if (_sinMagnetometro) return 'Sin brújula · sigue la distancia';
    if (_posicion == null) return 'Buscando señal GPS…';
    if (_heading == null) return 'Calibrando brújula…';
    final c = _cuadrante;
    if (c == null) return '';
    const flechas = {
      Cuadrante.alFrente: '▲',
      Cuadrante.aTuDerecha: '▶',
      Cuadrante.aTusEspaldas: '▼',
      Cuadrante.aTuIzquierda: '◀',
    };
    return '${flechas[c]}  ${c.texto.toUpperCase()}';
  }

  String _textoDetalle(bool baja) {
    final pos = _posicion;
    if (pos == null) return 'Esperando ubicación';
    final precision = '±${pos.accuracy.toStringAsFixed(0)} m';
    if (baja) return 'Precisión baja $precision · Buscando señal';
    final rumbo = _rumbo;
    return rumbo == null
        ? 'Precisión $precision'
        : 'Rumbo ${rumbo.toStringAsFixed(0)}° · Precisión $precision';
  }

  static String _formatearDistancia(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(2)} km' : '${m.round()} m';

  static String _dos(int n) => n.toString().padLeft(2, '0');

  // ───────────────────────── Hojas ─────────────────────────

  Future<void> _abrirSelector() async {
    final edificios = _resultado?.edificios ?? const <Edificio>[];
    if (edificios.isEmpty) {
      _snack('No hay edificios disponibles.');
      return;
    }
    final elegido = await showModalBottomSheet<Edificio>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) =>
          _SelectorEdificio(edificios: edificios, posicion: _posicion),
    );
    if (elegido != null) _seleccionar(elegido);
  }

  Future<void> _mostrarFicha(Edificio e, {bool llegada = false}) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final tema = Theme.of(context);
        final abierto = e.estaAbierto();
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          maxChildSize: 0.9,
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              if (llegada) _BannerLlegada(nombre: e.nombre),
              GaleriaEdificio(edificio: e),
              const SizedBox(height: 12),
              Text(e.nombre, style: tema.textTheme.titleLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  Chip(label: Text(e.categoriaDisplay)),
                  if (e.horarioTexto != null)
                    Chip(
                      avatar: Icon(
                        abierto == true ? Icons.lock_open : Icons.lock_clock,
                        size: 18,
                      ),
                      label: Text(
                          '${abierto == true ? 'Abierto' : 'Cerrado'} ${e.horarioTexto}'),
                    ),
                ],
              ),
              if (e.descripcion.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(e.descripcion, style: tema.textTheme.bodyMedium),
              ],
              if (e.dependencias.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Dependencias', style: tema.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final d in e.dependencias)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.chevron_right),
                    title: Text(d),
                  ),
              ],
              const SizedBox(height: 12),
              Text('Puntos de acceso', style: tema.textTheme.titleSmall),
              for (final p in e.puntosTransitables)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(p.tipo == TipoCoordenada.entradaPrincipal
                      ? Icons.door_front_door
                      : Icons.meeting_room_outlined),
                  title: Text(p.nombreVisible),
                  subtitle: Text(
                      '${p.latitud.toStringAsFixed(6)}, ${p.longitud.toStringAsFixed(6)}'),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── Widgets auxiliares ─────────────────────────

class _Dial extends StatelessWidget {
  const _Dial({
    required this.vueltasDial,
    required this.vueltasAguja,
    required this.cuadrante,
    required this.mostrarAguja,
  });

  final double vueltasDial;
  final double vueltasAguja;
  final Cuadrante? cuadrante;
  final bool mostrarAguja;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final estilo = Theme.of(context).textTheme;
    final uth = UthColores.of(context);
    const anim = Duration(milliseconds: 120);
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _CuadrantePainter(
            cuadrante: cuadrante,
            esquema: esquema,
            colorFrente: uth.aguja,
          ),
        ),
        AnimatedRotation(
          turns: vueltasDial,
          duration: anim,
          child: CustomPaint(
            painter: _AnilloPainter(
              esquema: esquema,
              estiloCardinal: estilo.titleMedium!,
            ),
          ),
        ),
        if (mostrarAguja)
          AnimatedRotation(
            turns: vueltasAguja,
            duration: anim,
            child: CustomPaint(
              painter: _AgujaPainter(
                punta: uth.aguja,
                cola: esquema.outlineVariant,
                sombra: esquema.shadow,
              ),
            ),
          ),
        Center(
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: esquema.onSurface,
              shape: BoxShape.circle,
              border: Border.all(color: esquema.surface, width: 3),
            ),
          ),
        ),
      ],
    );
  }
}

/// Arco del cuadrante activo, fijo respecto al teléfono (arriba = al frente).
class _CuadrantePainter extends CustomPainter {
  _CuadrantePainter({
    required this.cuadrante,
    required this.esquema,
    required this.colorFrente,
  });

  final Cuadrante? cuadrante;
  final ColorScheme esquema;
  final Color colorFrente;

  @override
  void paint(Canvas canvas, Size size) {
    final c = cuadrante;
    if (c == null) return;
    final centro = size.center(Offset.zero);
    final radio = size.shortestSide / 2;
    final centroAngulo = switch (c) {
      Cuadrante.alFrente => -math.pi / 2,
      Cuadrante.aTuDerecha => 0.0,
      Cuadrante.aTusEspaldas => math.pi / 2,
      Cuadrante.aTuIzquierda => math.pi,
    };
    final color = switch (c) {
      Cuadrante.alFrente => colorFrente,
      Cuadrante.aTusEspaldas => esquema.tertiary,
      _ => esquema.secondary,
    };
    final paint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawArc(
      Rect.fromCircle(center: centro, radius: radio),
      centroAngulo - math.pi / 4,
      math.pi / 2,
      true,
      paint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: centro, radius: radio - 3),
      centroAngulo - math.pi / 4,
      math.pi / 2,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CuadrantePainter old) =>
      old.cuadrante != cuadrante ||
      old.esquema != esquema ||
      old.colorFrente != colorFrente;
}

/// Anillo de grados (gira con −heading para que N apunte al norte real).
class _AnilloPainter extends CustomPainter {
  _AnilloPainter({required this.esquema, required this.estiloCardinal});

  final ColorScheme esquema;
  final TextStyle estiloCardinal;

  @override
  void paint(Canvas canvas, Size size) {
    final centro = size.center(Offset.zero);
    final radio = size.shortestSide / 2 - 10;

    canvas.drawCircle(
      centro,
      radio,
      Paint()
        ..color = esquema.outlineVariant
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final marca = Paint()..strokeCap = StrokeCap.round;
    for (var g = 0; g < 360; g += 10) {
      final a = GeoMathService.toRadians(g.toDouble()) - math.pi / 2;
      final larga = g % 30 == 0;
      final dir = Offset(math.cos(a), math.sin(a));
      marca
        ..color = larga ? esquema.onSurfaceVariant : esquema.outline
        ..strokeWidth = larga ? 2.5 : 1.2;
      canvas.drawLine(
        centro + dir * (radio - (larga ? 14 : 8)),
        centro + dir * radio,
        marca,
      );
    }

    const cardinales = {0: 'N', 90: 'E', 180: 'S', 270: 'O'};
    cardinales.forEach((g, letra) {
      final a = GeoMathService.toRadians(g.toDouble()) - math.pi / 2;
      final tp = TextPainter(
        text: TextSpan(
          text: letra,
          style: estiloCardinal.copyWith(
            color: g == 0 ? esquema.error : esquema.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final p = centro + Offset(math.cos(a), math.sin(a)) * (radio - 30);
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(a + math.pi / 2);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    });
  }

  @override
  bool shouldRepaint(_AnilloPainter old) =>
      old.esquema != esquema || old.estiloCardinal != estiloCardinal;
}

/// Aguja apuntando hacia arriba; la rotación la aplica AnimatedRotation.
class _AgujaPainter extends CustomPainter {
  _AgujaPainter({
    required this.punta,
    required this.cola,
    required this.sombra,
  });

  final Color punta;
  final Color cola;
  final Color sombra;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 48;
    final pathPunta = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + 16, c.dy)
      ..lineTo(c.dx, c.dy - 10)
      ..lineTo(c.dx - 16, c.dy)
      ..close();
    final pathCola = Path()
      ..moveTo(c.dx, c.dy + r * 0.45)
      ..lineTo(c.dx + 10, c.dy)
      ..lineTo(c.dx - 10, c.dy)
      ..close();
    canvas.drawShadow(pathPunta, sombra, 4, false);
    canvas.drawPath(pathPunta, Paint()..color = punta);
    canvas.drawPath(pathCola, Paint()..color = cola);
  }

  @override
  bool shouldRepaint(_AgujaPainter old) =>
      old.punta != punta || old.cola != cola || old.sombra != sombra;
}

/// Encabezado de la ficha cuando el usuario llega (color acento del tema).
class _BannerLlegada extends StatelessWidget {
  const _BannerLlegada({required this.nombre});

  final String nombre;

  @override
  Widget build(BuildContext context) {
    final uth = UthColores.of(context);
    final estilo = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: uth.llegada,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.where_to_vote, color: uth.sobreLlegada, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('¡Llegaste!',
                    style: estilo.titleMedium?.copyWith(
                        color: uth.sobreLlegada, fontWeight: FontWeight.w700)),
                Text(nombre,
                    style:
                        estilo.bodyMedium?.copyWith(color: uth.sobreLlegada)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SinBrujula extends StatelessWidget {
  const _SinBrujula({required this.esquema});

  final ColorScheme esquema;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: esquema.surfaceContainerHighest,
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.explore_off, size: 48, color: esquema.outline),
              const SizedBox(height: 8),
              const Text(
                'Este dispositivo no tiene magnetómetro',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EstadoVacio extends StatelessWidget {
  const _EstadoVacio({
    required this.icono,
    required this.titulo,
    required this.detalle,
    required this.accion,
    required this.onAccion,
  });

  final IconData icono;
  final String titulo;
  final String detalle;
  final String accion;
  final VoidCallback onAccion;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 64, color: tema.colorScheme.outline),
            const SizedBox(height: 16),
            Text(titulo,
                style: tema.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(detalle,
                style: tema.textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(onPressed: onAccion, child: Text(accion)),
          ],
        ),
      ),
    );
  }
}

/// Selector con búsqueda local (nombre, código, dependencia, palabra clave)
/// ordenado por distancia cuando hay GPS.
class _SelectorEdificio extends StatefulWidget {
  const _SelectorEdificio({required this.edificios, required this.posicion});

  final List<Edificio> edificios;
  final Position? posicion;

  @override
  State<_SelectorEdificio> createState() => _SelectorEdificioState();
}

class _SelectorEdificioState extends State<_SelectorEdificio> {
  String _consulta = '';

  @override
  Widget build(BuildContext context) {
    final pos = widget.posicion;
    final items = widget.edificios
        .where((e) => e.coincide(_consulta))
        .map((e) => (
              edificio: e,
              distancia: pos == null
                  ? null
                  : e.distanciaMinima(pos.latitude, pos.longitude),
            ))
        .toList()
      ..sort((a, b) {
        final da = a.distancia, db = b.distancia;
        if (da != null && db != null) return da.compareTo(db);
        return a.edificio.nombre.compareTo(b.edificio.nombre);
      });

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SearchBar(
                hintText: 'Buscar edificio, trámite…',
                leading: const Icon(Icons.search),
                onChanged: (v) => setState(() => _consulta = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('Sin coincidencias'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final it = items[i];
                        final e = it.edificio;
                        final d = it.distancia;
                        return ListTile(
                          minTileHeight: 72,
                          leading: CircleAvatar(
                              child: Text(e.codigo.isEmpty
                                  ? '?'
                                  : e.codigo.characters.first)),
                          title: Text(e.nombre),
                          subtitle: Text(
                            [e.categoriaDisplay, ...e.dependencias.take(2)]
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: d == null
                              ? null
                              : Text(_RadarScreenState._formatearDistancia(d)),
                          onTap: () => Navigator.pop(context, e),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
