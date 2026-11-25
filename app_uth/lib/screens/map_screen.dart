import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/campus_model.dart';
import '../models/edificio_model.dart';
import '../services/api_service.dart';
import '../services/auto_service.dart';
import '../services/aviso_service.dart';
import '../services/geo_math_service.dart';
import '../services/geocerca_service.dart';
import '../services/ruta_service.dart';
import '../theme/tema_controller.dart';
import '../theme/uth_themes.dart';
import '../widgets/hermes_guia.dart';
import 'detalle_screen.dart';

/// Cómo llega el usuario al campus (selector del mapa).
enum ModoLlegada {
  pie('A pie', Icons.directions_walk),
  carro('Carro', Icons.directions_car);

  const ModoLlegada(this.etiqueta, this.icono);
  final String etiqueta;
  final IconData icono;
}

/// Identificador de la app para las políticas de uso de OpenStreetMap.
/// Cámbialo por tu `applicationId` de Android (android/app/build.gradle).
const String kUserAgentPackage = 'mx.edu.uth.radar';

/// Vista de mapa interactivo (OpenStreetMap + flutter_map, gratuito) con
/// todos los edificios del campus: entrada principal, perímetro y radio.
///
/// Extra 2 (mapa completo):
/// - Marcador del usuario en vivo (GPS) con su círculo de precisión.
/// - Marcador del destino elegido (tocar un edificio → "Fijar destino",
///   o abrir el mapa desde el detalle con [destinoInicial]).
/// - Ruta a pie usuario → puerta más cercana del destino por el GRAFO DE
///   ANDADORES (banquetas y andadores, nunca cruza un edificio); fuera del
///   campus OSRM; sin nada de eso, línea recta con distancia Haversine.
/// - Puertas peatonales y entradas de autos del campus (`/api/campus/`).
/// - Aviso de llegada con notificación, sonido y vibración ([AvisoService]).
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.apiService, this.destinoInicial});

  /// Si se inyecta (p. ej. desde la bienvenida) no se cierra aquí.
  final ApiService? apiService;

  /// Destino ya elegido (p. ej. desde la pantalla de detalle).
  final Edificio? destinoInicial;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  late final ApiService _api = widget.apiService ?? ApiService();
  final MapController _mapController = MapController();

  ResultadoEdificios? _resultado;
  String? _errorCarga;
  bool _cargando = true;
  // Círculos de radio ocultos (el usuario no los quiere en el mapa).
  final bool _mostrarRadios = false;
  bool _mapaListo = false;

  // GPS
  StreamSubscription<Position>? _subPosicion;
  Position? _posicion;
  String? _avisoGps;

  // Destino
  late Edificio? _destino = widget.destinoInicial;

  // Modo ruta: avisos "Pasaste por…" y llegada.
  final GeocercaService _geocercaRuta = GeocercaService();
  bool _llego = false;

  // Ruta a pie (andadores u OSRM). null = sin ruta -> se usa línea recta.
  final RutaService _rutas = RutaService();
  List<LatLng>? _rutaCalles;
  OrigenRuta? _origenRuta;

  // Puertas peatonales / entradas de autos + andadores (una petición).
  CampusDatos _campus = CampusDatos.vacio;

  // Modo de llegada: a pie (andadores), carro (OSRM auto + reportes) o camión.
  ModoLlegada _modo = ModoLlegada.pie;
  final AutoService _auto = AutoService();
  RutaAuto? _rutaAuto;
  bool _pidiendoAuto = false;
  DateTime _ultimaAuto = DateTime(2000);
  List<ReporteVial> _reportes = const [];
  DateTime _ultimosReportes = DateTime(2000);
  bool _pidiendoRuta = false;
  DateTime _ultimaRuta = DateTime(2000);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cargar();
    _iniciarGps();
  }

  @override
  void dispose() {
    _rutas.dispose();
    _auto.dispose();
    _tHermes?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _subPosicion?.cancel();
    _mapController.dispose();
    if (widget.apiService == null) _api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ahorra batería: el GPS se apaga con la app en segundo plano.
    if (state == AppLifecycleState.paused) {
      _subPosicion?.cancel();
      _subPosicion = null;
    } else if (state == AppLifecycleState.resumed && _subPosicion == null) {
      _iniciarGps();
    }
  }

  // ───────────────────────── Datos ─────────────────────────

  /// Lee la lista LOCAL (ApiService solo va a la red con [forzarRed]).
  Future<void> _cargar({bool forzarRed = false}) async {
    setState(() {
      _cargando = true;
      _errorCarga = null;
    });
    try {
      final r = await _api.obtenerEdificios(forzarRed: forzarRed);
      final campus = await _api.obtenerCampus(forzarRed: forzarRed);
      if (!mounted) return;
      _rutas.configurar(campus, r.edificios);
      setState(() {
        _resultado = r;
        _campus = campus;
        _cargando = false;
      });
      // Con el grafo listo, recalcula la ruta (ya no en línea recta).
      _ultimaRuta = DateTime(2000);
      _rutaCalles = null;
      _actualizarRutaCalles();
      if (_mapaListo) _encuadrar();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _errorCarga = e.mensaje;
      });
    }
  }

  // ───────────────────────── GPS ─────────────────────────

  /// Posición del usuario en vivo. Si no hay permiso o el GPS está apagado,
  /// el mapa sigue funcionando sin el marcador del usuario.
  Future<void> _iniciarGps() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) setState(() => _avisoGps = 'GPS apagado');
      return;
    }
    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }
    if (!mounted) return;
    if (permiso == LocationPermission.denied ||
        permiso == LocationPermission.deniedForever) {
      setState(() => _avisoGps = 'Sin permiso de ubicación');
      return;
    }
    setState(() => _avisoGps = null);
    await _subPosicion?.cancel();
    _subPosicion = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2, // redibuja cada 2 m de movimiento
      ),
    ).listen((pos) {
      if (!mounted) return;
      setState(() => _posicion = pos);
      _revisarRuta(pos);
      _actualizarRutaCalles();
    });
  }

  LatLng? get _usuario {
    final p = _posicion;
    return p == null ? null : LatLng(p.latitude, p.longitude);
  }

  /// Puerta del destino más cercana al usuario (o su entrada principal si
  /// todavía no hay GPS). La línea recta termina aquí.
  CoordenadaGps? get _puntoDestino {
    final d = _destino;
    if (d == null) return null;
    final p = _posicion;
    return p == null
        ? d.entradaPrincipal
        : d.puertaMasCercana(p.latitude, p.longitude);
  }

  /// Distancia Haversine usuario → puerta del destino, en metros.
  double? get _distanciaDestino {
    final p = _posicion;
    final punto = _puntoDestino;
    if (p == null || punto == null) return null;
    return punto.distanciaDesde(p.latitude, p.longitude);
  }

  /// Modo ruta (con destino): mientras caminas, avisa al pasar junto a otro
  /// edificio (geocerca de 20 m, sin repetir) y al llegar a la puerta (15 m).
  void _revisarRuta(Position pos) {
    final destino = _destino;
    final r = _resultado;
    if (destino == null || r == null) return;

    final dist = _distanciaDestino;
    if (!_llego && dist != null && GeoMathService.hasArrived(dist)) {
      _llego = true;
      // Notificación con sonido + vibración (antes solo "click", no se oía).
      AvisoService.instancia
          .avisar('🏁 Llegaste a ${destino.codigo}', destino.nombre);
      _aviso('🏁 Llegaste a ${destino.nombre}');
      return;
    }

    final otros = r.edificios.where((e) => e != destino).toList();
    final paso = _geocercaRuta.evaluar(otros, pos.latitude, pos.longitude).nuevo;
    if (paso != null) {
      HapticFeedback.mediumImpact();
      _aviso('Pasaste por ${paso.edificio.nombre}');
    }
  }

  /// Hermes dice [texto] durante 5 s y luego vuelve a su mensaje de guía.
  void _aviso(String texto) {
    _tHermes?.cancel();
    setState(() => _hermesDice = texto);
    _tHermes = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _hermesDice = null);
    });
  }

  String? _hermesDice;
  Timer? _tHermes;

  /// Mensaje "normal" de Hermes según qué tan cerca estás.
  String _mensajeHermes(Edificio d) {
    if (_hermesDice != null) return _hermesDice!;
    if (_llego) return '¡Llegamos! Esta es ${d.nombre}. Tócame para ver la info.';
    final dist = _distanciaDestino;
    if (dist == null) return 'Hermes te lleva a ${d.nombre}… esperando tu GPS.';
    if (dist <= 40) return '¡Ya casi! Faltan ${dist.round()} m.';
    if (_modo == ModoLlegada.carro && _rutaAuto != null) {
      final e = _rutaAuto!.estacionamiento;
      return e == null
          ? 'Maneja hasta la entrada de autos, estaciónate y sígueme a pie.'
          : 'Maneja hasta el ${e.nombre}, estaciónate ahí y sígueme a pie.';
    }
    if (_origenRuta?.vieneDeAfuera ?? false) {
      return 'Vienes de afuera: entra por la puerta peatonal y sígueme a ${d.nombre}.';
    }
    if (_origenRuta == OrigenRuta.andadores) {
      return 'Ya estás en el campus: te llevo por los andadores a ${d.nombre}.';
    }
    return 'Hermes te lleva a ${d.nombre}. ¡Sígueme!';
  }

  /// Con destino solo se dibuja ese edificio; sin destino, todos.
  List<Edificio> _visibles(List<Edificio> todos) {
    final d = _destino;
    return d == null ? todos : [d];
  }

  void _fijarDestino(Edificio? e) {
    _geocercaRuta.reiniciar();
    _rutaCalles = null;
    _origenRuta = null;
    _ultimaRuta = DateTime(2000);
    _rutaAuto = null;
    _ultimaAuto = DateTime(2000);
    _llego = false;
    setState(() => _destino = e);
    if (e != null) {
      _encuadrarRuta();
      _actualizarRutaCalles(); // pide la ruta por calles de inmediato
    }
  }

  // ───────────────────────── Geometría ─────────────────────────

  static LatLng? _entrada(Edificio e) {
    final c = e.entradaPrincipal;
    return c == null ? null : LatLng(c.latitud, c.longitud);
  }

  static List<LatLng> _perimetro(Edificio e) {
    final puntos = e.coordenadas
        .where((c) => c.tipo == TipoCoordenada.perimetro)
        .toList()
      ..sort((a, b) => a.orden.compareTo(b.orden));
    return puntos
        .map((c) => LatLng(c.latitud, c.longitud))
        .toList(growable: false);
  }

  /// Centro del edificio: promedio del perímetro (o la entrada si no hay).
  static LatLng? _centro(Edificio e) {
    final per = _perimetro(e);
    if (per.isEmpty) return _entrada(e);
    final lat = per.map((p) => p.latitude).reduce((a, b) => a + b) / per.length;
    final lon =
        per.map((p) => p.longitude).reduce((a, b) => a + b) / per.length;
    return LatLng(lat, lon);
  }

  List<LatLng> _todosLosPuntos(List<Edificio> edificios) => [
        for (final e in edificios)
          for (final c in e.coordenadas) LatLng(c.latitud, c.longitud),
      ];

  CameraFit? _camaraAjustada(List<Edificio> edificios) {
    final puntos = _todosLosPuntos(edificios);
    if (puntos.isEmpty) return null;
    return CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(puntos),
      padding: const EdgeInsets.all(48),
      maxZoom: 18,
    );
  }

  void _encuadrar() {
    final r = _resultado;
    if (r == null || !_mapaListo) return;
    final fit = _camaraAjustada(r.edificios);
    if (fit != null) _mapController.fitCamera(fit);
  }

  /// Encuadra usuario + destino (o solo el destino si no hay GPS).
  void _encuadrarRuta() {
    if (!_mapaListo) return;
    final punto = _puntoDestino;
    if (punto == null) return;
    final destino = LatLng(punto.latitud, punto.longitud);
    final usuario = _usuario;
    if (usuario == null) {
      _mapController.move(destino, 18);
      return;
    }
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints([usuario, destino]),
      padding: const EdgeInsets.fromLTRB(64, 120, 64, 96),
      maxZoom: 18,
    ));
  }

  void _centrarEnMi() {
    final u = _usuario;
    if (u != null && _mapaListo) _mapController.move(u, 18);
  }

  UthColores get _uth => UthColores.of(context);

  /// Relleno del pin / polígono según categoría (colores del tema).
  Color _color(CategoriaEdificio c) => switch (c) {
        CategoriaEdificio.academico => _uth.pinAcademico,
        CategoriaEdificio.administrativo => _uth.pinAdministrativo,
        CategoriaEdificio.servicios => _uth.pinServicios,
      };

  /// Trazo legible sobre las teselas: en mapa claro se oscurece el pastel.
  Color _trazo(CategoriaEdificio c) =>
      _uth.mapaOscuro ? _color(c) : Color.lerp(_color(c), _uth.bordePin, 0.55)!;

  static String _fecha(DateTime d) {
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(d.day)}/${dos(d.month)} ${dos(d.hour)}:${dos(d.minute)}';
  }

  static String _metros(double m) =>
      m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(2)} km';

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mapa del campus'),
        actions: [
          const BotonTemas(),
          IconButton(
            tooltip: 'Sincronizar',
            icon: const Icon(Icons.sync),
            onPressed: _cargando ? null : () => _cargar(forzarRed: true),
          ),
        ],
      ),
      body: _cuerpo(context),
    );
  }

  Widget _cuerpo(BuildContext context) {
    final r = _resultado;
    if (r == null) {
      if (_cargando) return const Center(child: CircularProgressIndicator());
      return _mensaje(
        icono: Icons.cloud_off,
        titulo: 'No se pudo cargar el catálogo',
        detalle: _errorCarga ?? 'Error desconocido.',
        accion: () => _cargar(),
      );
    }
    final fit = _camaraAjustada(r.edificios);
    if (fit == null) {
      return _mensaje(
        icono: Icons.map_outlined,
        titulo: 'Sin edificios con coordenadas',
        detalle: 'Ejecuta poblar_uth en el backend y vuelve a intentar.',
        accion: () => _cargar(forzarRed: true),
      );
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCameraFit: fit,
            minZoom: 3,
            maxZoom: 19,
            onMapReady: () {
              _mapaListo = true;
              if (_destino != null) _encuadrarRuta();
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: kUserAgentPackage,
              maxZoom: 19,
              tileBuilder: _uth.mapaOscuro ? darkModeTileBuilder : null,
            ),
            PolygonLayer(polygons: _poligonos(_visibles(r.edificios))),
            if (_mostrarRadios) CircleLayer(circles: _circulos(_visibles(r.edificios))),
            // Puertas peatonales y entradas de autos del campus.
            MarkerLayer(markers: _marcadoresAcceso()),
            // Reportes de la comunidad (solo en modo carro).
            MarkerLayer(markers: _marcadoresReporte()),
            // Línea recta usuario → destino (debajo de los marcadores).
            PolylineLayer(polylines: _ruta()),
            MarkerLayer(markers: _marcadores(_visibles(r.edificios))),
            // Precisión del GPS + punto azul del usuario (arriba de todo).
            CircleLayer(circles: _precisionUsuario()),
            MarkerLayer(markers: _marcadorUsuario()),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
        if (_cargando) const LinearProgressIndicator(),
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Column(
            children: [
              if (r.esOffline) _bannerOffline(context, r),
              if (_destino != null) _tarjetaDestino(context, _destino!),
              if (_destino != null) _selectorModo(context),
            ],
          ),
        ),
        if (_destino == null)
          Positioned(left: 12, bottom: 28, child: _leyenda(context))
        else
          // Hermes guía con globo de diálogo (deja libre la columna de botones).
          Positioned(
            left: 12,
            right: 72,
            bottom: 28,
            child: HermesGuia(
              mensaje: _mensajeHermes(_destino!),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    DetalleScreen(edificio: _destino!, apiService: _api),
              )),
            ),
          ),
        Positioned(
          right: 12,
          bottom: 28,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_destino != null && _modo == ModoLlegada.carro) ...[
                FloatingActionButton.small(
                  heroTag: null,
                  tooltip: 'Reportar bache, retén o calle cerrada',
                  backgroundColor: const Color(0xFFEF6C00),
                  foregroundColor: Colors.white,
                  onPressed: _reportar,
                  child: const Icon(Icons.add_road),
                ),
                const SizedBox(height: 8),
              ],
              FloatingActionButton.small(
                heroTag: null,
                tooltip: _avisoGps ?? 'Mi ubicación',
                onPressed: _usuario == null ? _iniciarGps : _centrarEnMi,
                child: Icon(_avisoGps != null
                    ? Icons.location_disabled
                    : Icons.my_location),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                heroTag: null,
                tooltip: 'Encuadrar campus',
                onPressed: _encuadrar,
                child: const Icon(Icons.fit_screen),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Polygon> _poligonos(List<Edificio> edificios) => [
        for (final e in edificios)
          if (_perimetro(e).length >= 3)
            Polygon(
              points: _perimetro(e),
              color: _color(e.categoria).withValues(alpha: 0.35),
              borderColor: _trazo(e.categoria),
              borderStrokeWidth: e == _destino ? 4 : 2,
            ),
      ];

  List<CircleMarker> _circulos(List<Edificio> edificios) => [
        for (final e in edificios)
          if (_centro(e) != null)
            CircleMarker(
              point: _centro(e)!,
              radius: e.radioCoberturaM.toDouble(),
              useRadiusInMeter: true,
              color: _color(e.categoria).withValues(alpha: 0.10),
              borderColor: _trazo(e.categoria).withValues(alpha: 0.8),
              borderStrokeWidth: 1.5,
            ),
      ];

  /// Calcula la ruta al fijar destino y la recalcula si el usuario se desvía
  /// más de 25 m. Con andadores es local (cada 3 s como máximo); con OSRM
  /// se limita a una petición cada 15 s.
  Future<void> _actualizarRutaCalles() async {
    if (_modo == ModoLlegada.carro) {
      _actualizarRutaAuto();
      return;
    }
    final u = _usuario;
    final punto = _puntoDestino;
    if (u == null || punto == null || _pidiendoRuta || _llego) return;
    final ruta = _rutaCalles;
    // Desde afuera puede pedirse a OSRM (servidor público): máx. cada 15 s.
    final espera = (_origenRuta?.vieneDeAfuera ?? false)
        ? const Duration(seconds: 15)
        : const Duration(seconds: 3);
    // La ruta se calculó "desde afuera" pero ya estás DENTRO y todavía te
    // mandaría a salir: se rehace solo por andadores, sin esperar.
    final yaAdentro = ruta != null &&
        (_origenRuta?.vieneDeAfuera ?? false) &&
        _rutas.dentroDelCampus(u) &&
        RutaService.recortar(ruta, u).restante.skip(1).any(_rutas.estaFuera);
    if (!yaAdentro) {
      if (DateTime.now().difference(_ultimaRuta) < espera) return;
      if (ruta != null && RutaService.recortar(ruta, u).desvio <= 25) return;
    }
    _pidiendoRuta = true;
    _ultimaRuta = DateTime.now();
    final nueva =
        await _rutas.calcular(u, LatLng(punto.latitud, punto.longitud));
    _pidiendoRuta = false;
    if (!mounted || _destino == null) return;
    setState(() {
      if (nueva != null) {
        _rutaCalles = nueva.puntos;
        _origenRuta = nueva.origen;
      }
    });
  }

  // ───────────────────────── Modo carro ─────────────────────────

  /// Entrada de autos del campus (la que se llama "Entrada…", si hay).
  PuntoAcceso? get _entradaAutos {
    final autos = [
      for (final a in _campus.accesos)
        if (a.esVehicular) a,
    ];
    if (autos.isEmpty) return null;
    return autos.firstWhere(
      (a) => a.nombre.toLowerCase().contains('entrada'),
      orElse: () => autos.first,
    );
  }

  Future<void> _cambiarModo(ModoLlegada m) async {
    setState(() {
      _modo = m;
      _rutaAuto = null;
      _ultimaAuto = DateTime(2000);
      _ultimaRuta = DateTime(2000);
    });
    if (m == ModoLlegada.carro) await _cargarReportes(forzar: true);
    _actualizarRutaCalles();
  }

  /// Reportes de la comunidad (cada 2 min como máximo).
  Future<void> _cargarReportes({bool forzar = false}) async {
    if (!forzar &&
        DateTime.now().difference(_ultimosReportes) <
            const Duration(minutes: 2)) {
      return;
    }
    _ultimosReportes = DateTime.now();
    final r = await _api.obtenerReportes();
    if (mounted) setState(() => _reportes = r);
  }

  /// Ruta en carro hasta la entrada de autos (+ tramo a pie). Se recalcula
  /// si te desvías más de 60 m (máximo cada 20 s: OSRM es un servidor
  /// público). Ya dentro del campus se usa la ruta a pie normal.
  Future<void> _actualizarRutaAuto() async {
    final u = _usuario;
    final punto = _puntoDestino;
    final entrada = _entradaAutos;
    if (u == null || punto == null || _pidiendoAuto || _llego) return;
    final previa = _rutaAuto;
    // Ya adentro: sigue manejando por las calles internas hasta el
    // estacionamiento; al llegar (≤ 30 m) cambia a la ruta a pie.
    final yaEstaciono = previa == null ||
        GeoMathService.haversineDistance(u.latitude, u.longitude,
                previa.aPie.first.latitude, previa.aPie.first.longitude) <=
            30;
    if (entrada == null || (!_rutas.estaFuera(u) && yaEstaciono)) {
      // Sin entrada de autos cargada o ya estacionado adentro: a pie.
      if (_rutaAuto != null) setState(() => _rutaAuto = null);
      _modoPieTemporal();
      return;
    }
    // Manejando dentro del campus: se conserva la ruta interna (OSRM no
    // conoce las calles del campus y la mandaría de regreso a la entrada).
    if (!_rutas.estaFuera(u)) return;
    _cargarReportes();
    if (DateTime.now().difference(_ultimaAuto) < const Duration(seconds: 20)) {
      return;
    }
    final actual = _rutaAuto;
    if (actual != null && RutaService.recortar(actual.manejo, u).desvio <= 60) {
      return;
    }
    _pidiendoAuto = true;
    _ultimaAuto = DateTime.now();
    final nueva = await _auto.calcular(
      desde: u,
      entradaAutos: entrada.punto,
      puerta: LatLng(punto.latitud, punto.longitud),
      pie: _rutas,
      reportes: _reportes,
      estacionamientos: [
        for (final a in _campus.accesos)
          if (a.esEstacionamiento) a,
      ],
    );
    _pidiendoAuto = false;
    if (!mounted || _destino == null || _modo != ModoLlegada.carro) return;
    if (nueva == null) {
      _aviso('Sin internet para la ruta en carro; te muestro la línea recta.');
      return;
    }
    setState(() => _rutaAuto = nueva);
    final peligros = nueva.reportesEnRuta;
    if (peligros.isNotEmpty) {
      final p = peligros.first;
      AvisoService.instancia.avisar(
        '⚠ ${p.tipo.etiqueta} en tu ruta',
        peligros.length == 1
            ? 'Reportado por la comunidad. Maneja con cuidado.'
            : '${peligros.length} reportes en tu ruta. Maneja con cuidado.',
      );
    }
  }

  /// En modo carro pero ya adentro del campus: calcula la ruta a pie.
  Future<void> _modoPieTemporal() async {
    final u = _usuario;
    final punto = _puntoDestino;
    if (u == null || punto == null || _pidiendoRuta) return;
    if (DateTime.now().difference(_ultimaRuta) < const Duration(seconds: 3)) {
      return;
    }
    final ruta = _rutaCalles;
    if (ruta != null && RutaService.recortar(ruta, u).desvio <= 25) return;
    _pidiendoRuta = true;
    _ultimaRuta = DateTime.now();
    final nueva =
        await _rutas.calcular(u, LatLng(punto.latitud, punto.longitud));
    _pidiendoRuta = false;
    if (!mounted || nueva == null) return;
    setState(() {
      _rutaCalles = nueva.puntos;
      _origenRuta = nueva.origen;
    });
  }

  /// Reporta un obstáculo en tu posición actual (o el centro del mapa).
  Future<void> _reportar() async {
    final tipo = await showModalBottomSheet<TipoReporte>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('¿Qué hay en el camino? Se reporta donde estás.'),
            ),
            for (final t in TipoReporte.values)
              ListTile(
                leading: Icon(_iconoReporte(t), color: _colorReporte(t)),
                title: Text(t.etiqueta),
                onTap: () => Navigator.of(ctx).pop(t),
              ),
          ],
        ),
      ),
    );
    if (tipo == null || !mounted) return;
    final aqui = _usuario ?? _mapController.camera.center;
    final error =
        await _api.crearReporte(tipo, aqui.latitude, aqui.longitude);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ?? 'Gracias: ${tipo.etiqueta} reportado.'),
    ));
    if (error == null) {
      await _cargarReportes(forzar: true);
      _ultimaAuto = DateTime(2000);
      _rutaAuto = null;
      _actualizarRutaCalles();
    }
  }

  static IconData _iconoReporte(TipoReporte t) => switch (t) {
        TipoReporte.bache => Icons.warning_amber,
        TipoReporte.reten => Icons.local_police,
        TipoReporte.cerrada => Icons.block,
        TipoReporte.obra => Icons.construction,
        TipoReporte.otro => Icons.report,
      };

  static Color _colorReporte(TipoReporte t) => switch (t) {
        TipoReporte.cerrada => const Color(0xFFD32F2F),
        TipoReporte.reten => const Color(0xFF1565C0),
        _ => const Color(0xFFEF6C00),
      };

  List<Marker> _marcadoresReporte() {
    if (_modo != ModoLlegada.carro) return const [];
    return [
      for (final r in _reportes)
        Marker(
          point: r.punto,
          width: 30,
          height: 30,
          child: GestureDetector(
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '${r.tipo.etiqueta}${r.descripcion.isEmpty ? '' : ': ${r.descripcion}'}'
                  '${r.creado == null ? '' : ' · ${_fecha(r.creado!)}'}'),
            )),
            child: Container(
              decoration: BoxDecoration(
                color: _colorReporte(r.tipo),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Icon(_iconoReporte(r.tipo), size: 16, color: Colors.white),
            ),
          ),
        ),
    ];
  }

  /// Selector "¿Cómo llegas?" debajo de la tarjeta del destino.
  Widget _selectorModo(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SegmentedButton<ModoLlegada>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.surface,
          visualDensity: VisualDensity.compact,
        ),
        segments: [
          for (final m in ModoLlegada.values)
            ButtonSegment(value: m, icon: Icon(m.icono), label: Text(m.etiqueta)),
        ],
        selected: {_modo},
        onSelectionChanged: (s) => _cambiarModo(s.first),
      ),
    );
  }

  /// Lo que falta por caminar: por calles si hay ruta; si no, línea recta.
  /// El tramo ya recorrido se descarta (la línea se va "comiendo").
  List<LatLng> _puntosRuta(LatLng u, CoordenadaGps punto) {
    final ruta = _rutaCalles;
    if (ruta == null) return [u, LatLng(punto.latitud, punto.longitud)];
    return RutaService.recortar(ruta, u).restante;
  }

  /// Polilínea usuario → puerta del destino (por calles o recta).
  List<Polyline> _ruta() {
    final u = _usuario;
    final punto = _puntoDestino;
    if (u == null || punto == null) return const [];
    final esquema = Theme.of(context).colorScheme;
    final auto = _rutaAuto;
    if (_modo == ModoLlegada.carro && auto != null) {
      return [
        // Manejo: línea continua gruesa (lo que falta).
        Polyline(
          points: RutaService.recortar(auto.manejo, u).restante,
          strokeWidth: 7,
          color: esquema.tertiary,
          borderStrokeWidth: 2,
          borderColor: esquema.surface,
        ),
        // Después de estacionarte: a pie por andadores (punteada).
        Polyline(
          points: auto.aPie,
          strokeWidth: 5,
          color: esquema.primary,
          borderStrokeWidth: 2,
          borderColor: esquema.surface,
          pattern: StrokePattern.dashed(segments: const [14, 8]),
        ),
      ];
    }
    return [
      Polyline(
        points: _puntosRuta(u, punto),
        strokeWidth: 5,
        color: esquema.primary,
        borderStrokeWidth: 2,
        borderColor: esquema.surface,
        pattern: StrokePattern.dashed(segments: const [14, 8]),
      ),
    ];
  }

  List<CircleMarker> _precisionUsuario() {
    final p = _posicion;
    if (p == null) return const [];
    final azul = Theme.of(context).colorScheme.primary;
    return [
      CircleMarker(
        point: LatLng(p.latitude, p.longitude),
        radius: p.accuracy,
        useRadiusInMeter: true,
        color: azul.withValues(alpha: 0.12),
        borderColor: azul.withValues(alpha: 0.4),
        borderStrokeWidth: 1,
      ),
    ];
  }

  List<Marker> _marcadorUsuario() {
    final u = _usuario;
    if (u == null) return const [];
    final esquema = Theme.of(context).colorScheme;
    return [
      Marker(
        point: u,
        width: 48,
        height: 48,
        // Personaje caminando: "tú estás aquí".
        child: Container(
          decoration: BoxDecoration(
            color: esquema.primary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45)],
          ),
          child: Icon(Icons.directions_walk, color: esquema.onPrimary, size: 28),
        ),
      ),
    ];
  }

  List<Marker> _marcadores(List<Edificio> edificios) {
    final esquema = Theme.of(context).colorScheme;
    final punto = _puntoDestino;
    return [
      for (final e in edificios)
        if (_entrada(e) != null && e != _destino)
          Marker(
            point: _entrada(e)!,
            width: 96,
            height: 64,
            // El pin queda por encima del punto: su punta marca la puerta.
            alignment: Alignment.topCenter,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _mostrarDetalle(e),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _etiqueta(e.codigo, esquema.surface.withValues(alpha: 0.94),
                      esquema.onSurface, _trazo(e.categoria)),
                  _Pin(relleno: _color(e.categoria), borde: _uth.bordePin),
                ],
              ),
            ),
          ),
      // Marcador del destino: más grande y con bandera.
      if (_destino != null && punto != null)
        Marker(
          point: LatLng(punto.latitud, punto.longitud),
          width: 140,
          height: 76,
          alignment: Alignment.topCenter,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _mostrarDetalle(_destino!),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _etiqueta('🏁 ${_destino!.codigo}', esquema.primary,
                    esquema.onPrimary, esquema.onPrimary),
                Icon(Icons.location_on, size: 48, color: esquema.primary),
              ],
            ),
          ),
        ),
    ];
  }

  /// Puertas peatonales (verde, persona) y entradas de autos (ámbar, auto).
  List<Marker> _marcadoresAcceso() {
    final esquema = Theme.of(context).colorScheme;
    // Con destino solo se ven las puertas del modo elegido (a pie: la
    // peatonal; en carro: entrada y salida de autos), para no confundir.
    bool visible(PuntoAcceso a) {
      // Estacionamientos: solo en carro. La parada de camión: siempre.
      if (a.esEstacionamiento) return _modo == ModoLlegada.carro;
      if (a.esParada) return true;
      if (_destino == null || a.tipo == TipoAcceso.mixto) return true;
      return _modo == ModoLlegada.carro ? a.esVehicular : a.esPeatonal;
    }

    return [
      for (final a in _campus.accesos.where(visible))
        Marker(
          point: a.punto,
          width: 34,
          height: 34,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _mostrarAcceso(a),
            child: Container(
              decoration: BoxDecoration(
                color: _colorAcceso(a.tipo),
                shape: BoxShape.circle,
                border: Border.all(color: esquema.surface, width: 2.5),
                boxShadow: const [
                  BoxShadow(blurRadius: 4, color: Colors.black38),
                ],
              ),
              child: Icon(_iconoAcceso(a.tipo), size: 18, color: Colors.white),
            ),
          ),
        ),
    ];
  }

  static Color _colorAcceso(TipoAcceso t) => switch (t) {
        TipoAcceso.vehicular => const Color(0xFFE09A00),
        TipoAcceso.peatonal => const Color(0xFF2E9E5B),
        TipoAcceso.mixto => const Color(0xFF3B7DD8),
        TipoAcceso.estacionamiento => const Color(0xFF1E5AA8),
        TipoAcceso.parada => const Color(0xFF7B3FA0),
      };

  static IconData _iconoAcceso(TipoAcceso t) => switch (t) {
        TipoAcceso.vehicular => Icons.directions_car,
        TipoAcceso.peatonal => Icons.directions_walk,
        TipoAcceso.mixto => Icons.door_sliding,
        TipoAcceso.estacionamiento => Icons.local_parking,
        TipoAcceso.parada => Icons.directions_bus,
      };

  void _mostrarAcceso(PuntoAcceso a) {
    final u = _usuario;
    final dist = u == null
        ? null
        : GeoMathService.haversineDistance(
            u.latitude, u.longitude, a.latitud, a.longitud);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final tema = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.nombre, style: tema.textTheme.titleLarge),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  Chip(
                    avatar: Icon(_iconoAcceso(a.tipo), size: 16),
                    label: Text(a.tipo.etiqueta),
                  ),
                  if (dist != null) Chip(label: Text('A ${_metros(dist)}')),
                  if (!a.validado)
                    const Chip(
                      avatar: Icon(Icons.info_outline, size: 16),
                      label: Text('Ubicación aproximada'),
                    ),
                ]),
                if (a.descripcion.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(a.descripcion),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _etiqueta(String texto, Color fondo, Color color, Color borde) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borde, width: 1.5),
      ),
      child: Text(
        texto,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// "En carro 4.2 km (~9 min) + 180 m a pie · ⚠ 1 reporte".
  String _textoAuto(RutaAuto a) {
    final min = (a.segundosManejo / 60).ceil();
    final aviso = a.reportesEnRuta.isEmpty
        ? ''
        : ' · ⚠ ${a.reportesEnRuta.length} reporte${a.reportesEnRuta.length == 1 ? '' : 's'}';
    return 'En carro ${_metros(a.metrosManejo)} (~$min min) + ${_metros(a.metrosAPie)} a pie$aviso';
  }

  /// Tarjeta superior con el destino y la distancia en vivo.
  Widget _tarjetaDestino(BuildContext context, Edificio d) {
    final tema = Theme.of(context);
    final distancia = _distanciaDestino;
    return Card(
      color: tema.colorScheme.primaryContainer,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.flag, color: tema.colorScheme.onPrimaryContainer),
        title: Text(
          d.nombre,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: tema.colorScheme.onPrimaryContainer),
        ),
        subtitle: Text(
          distancia == null
              ? (_avisoGps ?? 'Esperando GPS…')
              : (_modo == ModoLlegada.carro && _rutaAuto != null)
                  ? _textoAuto(_rutaAuto!)
              : (_rutaCalles != null
                  ? '${(_origenRuta ?? OrigenRuta.calles).texto}: ${_metros(RutaService.largo(_puntosRuta(_usuario!, _puntoDestino!)))}'
                  : 'En línea recta: ${_metros(distancia)}'),
          style: TextStyle(color: tema.colorScheme.onPrimaryContainer),
        ),
        onTap: _encuadrarRuta,
        trailing: IconButton(
          tooltip: 'Quitar destino',
          icon: const Icon(Icons.close),
          onPressed: () => _fijarDestino(null),
        ),
      ),
    );
  }

  void _mostrarDetalle(Edificio e) {
    final abierto = e.estaAbierto();
    final esDestino = e == _destino;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final tema = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.nombre, style: tema.textTheme.titleLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Chip(
                      avatar: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _color(e.categoria),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: _trazo(e.categoria), width: 1.5),
                        ),
                      ),
                      label: Text(e.categoriaDisplay),
                    ),
                    Chip(label: Text('Radio ${e.radioCoberturaM} m')),
                    if (e.horarioTexto != null)
                      Chip(
                        avatar: Icon(
                          abierto == true
                              ? Icons.lock_open
                              : Icons.lock_outline,
                          size: 16,
                        ),
                        label: Text(
                          '${e.horarioTexto} · ${abierto == true ? 'Abierto' : 'Cerrado'}',
                        ),
                      ),
                  ],
                ),
                if (e.descripcion.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(e.descripcion,
                      maxLines: 3, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.info_outline),
                        label: const Text('Ver detalle'),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                DetalleScreen(edificio: e, apiService: _api),
                          ));
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: Icon(esDestino ? Icons.close : Icons.flag),
                        label: Text(esDestino ? 'Quitar destino' : 'Fijar destino'),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _fijarDestino(esDestino ? null : e);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bannerOffline(BuildContext context, ResultadoEdificios r) {
    final esquema = Theme.of(context).colorScheme;
    final fecha = r.sincronizadoEn == null
        ? ''
        : ' · datos de ${_fecha(r.sincronizadoEn!)}';
    return Material(
      color: esquema.tertiaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 18, color: esquema.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Offline$fecha',
                style: TextStyle(color: esquema.onTertiaryContainer),
              ),
            ),
            TextButton(
              onPressed: _cargando ? null : () => _cargar(forzarRed: true),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leyenda(BuildContext context) {
    Widget fila(CategoriaEdificio c) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: _color(c),
                shape: BoxShape.circle,
                border: Border.all(color: _trazo(c), width: 1.5),
              ),
            ),
            const SizedBox(width: 6),
            Text(c.etiqueta, style: const TextStyle(fontSize: 12)),
          ],
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in CategoriaEdificio.values) fila(c),
            if (_campus.accesos.any((a) => a.esPeatonal))
              _filaAcceso(TipoAcceso.peatonal),
            if (_campus.accesos.any((a) => a.esVehicular))
              _filaAcceso(TipoAcceso.vehicular),
            if (_campus.accesos.any((a) => a.esParada))
              _filaAcceso(TipoAcceso.parada),
          ],
        ),
      ),
    );
  }

  Widget _filaAcceso(TipoAcceso t) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration:
                  BoxDecoration(color: _colorAcceso(t), shape: BoxShape.circle),
              child: Icon(_iconoAcceso(t), size: 10, color: Colors.white),
            ),
            const SizedBox(width: 6),
            Text(t.etiqueta, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );

  Widget _mensaje({
    required IconData icono,
    required String titulo,
    required String detalle,
    required VoidCallback accion,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 56),
            const SizedBox(height: 12),
            Text(titulo,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(detalle, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: accion, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}

/// Pin con contorno: el relleno pastel se lee sobre teselas claras y oscuras.
class _Pin extends StatelessWidget {
  const _Pin({required this.relleno, required this.borde});

  final Color relleno;
  final Color borde;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.location_on, size: 40, color: borde),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Icon(Icons.location_on, size: 32, color: relleno),
          ),
        ],
      ),
    );
  }
}
