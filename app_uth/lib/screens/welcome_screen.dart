import 'package:flutter/material.dart';

import '../models/edificio_model.dart';
import '../services/api_service.dart';
import '../theme/tema_controller.dart';
import '../widgets/hermes_cargando.dart';
import '../widgets/nombre_hermes.dart';
import 'directorio_screen.dart';
import 'free_nav_screen.dart';
import 'map_screen.dart';

/// Pantalla de bienvenida (nivel 7).
///
/// Flujo pedido por el profe:
/// 1. Al abrir la app se hace UNA petición al backend para traer los edificios.
/// 2. Se guardan en el dispositivo ([ApiService] los persiste con
///    SharedPreferences). Si no hay red, se usan los datos guardados.
/// 3. Se pregunta "¿Cómo quieres navegar?":
///    - Buscar un lugar      → Directorio con búsqueda → Detalle → Brújula (Modo A, nivel 9)
///    - Navegar libremente   → Spinner + geocerca (Modo B, nivel 8)
///    - Ver edificios        → Directorio → Detalle, sin navegar (nivel 7)
///
/// Todas las pantallas siguientes reciben la lista LOCAL; ninguna vuelve a
/// pedir datos a la red para consultar.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, this.apiService});

  final ApiService? apiService;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();

  ResultadoEdificios? _resultado;
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sincronizar();
  }

  @override
  void dispose() {
    if (widget.apiService == null) _api.dispose();
    super.dispose();
  }

  /// Descarga el catálogo (red primero, caché local como respaldo).
  Future<void> _sincronizar({bool forzarRed = false}) async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final r = await _api.obtenerEdificios(forzarRed: forzarRed);
      if (!mounted) return;
      setState(() {
        _resultado = r;
        _cargando = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = e.mensaje;
      });
    }
  }

  List<Edificio> get _edificios => _resultado?.edificios ?? const [];

  bool get _listo => !_cargando && _edificios.isNotEmpty;

  void _abrir(Widget pantalla) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => pantalla));
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;

    return Scaffold(
      // Barra limpia: el nombre va grande en el encabezado, no repetido arriba.
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: esquema.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: const [BotonTemas()],
      ),
      extendBodyBehindAppBar: true,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            // ── Encabezado: radar + nombre + lema ──
            Center(
              child: HermesCargando(
                tamano: 120,
                mostrarIcono: false,
                color: esquema.primary,
              ),
            ),
            const NombreHermes(tamano: 46),
            const SizedBox(height: 2),
            Text(
              'Tu guía del campus UTH',
              style: tema.textTheme.titleMedium
                  ?.copyWith(color: esquema.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Center(child: _estadoSincronizacion(context)),
            const SizedBox(height: 24),

            // ── Acción principal ──
            Text('¿A dónde quieres ir?', style: tema.textTheme.titleLarge),
            const SizedBox(height: 10),
            _OpcionNavegacion(
              icono: Icons.search,
              titulo: 'Buscar un lugar',
              detalle: 'Cafetería, biblioteca, rectoría, servicios escolares…',
              habilitado: _listo,
              destacado: true,
              onTap: () => _abrir(DirectorioScreen(
                edificios: _edificios,
                apiService: _api,
                modoBusqueda: true,
              )),
            ),
            const SizedBox(height: 20),

            // ── Otras formas de navegar: 3 mosaicos ──
            Text('O explora el campus', style: tema.textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _Mosaico(
                    icono: Icons.directions_walk,
                    titulo: 'Navegar\nlibremente',
                    habilitado: _listo,
                    onTap: () => _abrir(FreeNavScreen(
                      edificios: _edificios,
                      apiService: _api,
                    )),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Mosaico(
                    icono: Icons.apartment,
                    titulo: 'Ver\nedificios',
                    habilitado: _listo,
                    onTap: () => _abrir(DirectorioScreen(
                      edificios: _edificios,
                      apiService: _api,
                    )),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Mosaico(
                    icono: Icons.map_outlined,
                    titulo: 'Mapa del\ncampus',
                    habilitado: _listo,
                    onTap: () => _abrir(MapScreen(apiService: _api)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Tarjeta con el resultado de la descarga inicial.
  Widget _estadoSincronizacion(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;

    if (_cargando) {
      // Radar de heRmes girando mientras se sincroniza (botón ⟳).
      return Column(
        children: [
          HermesCargando(
            tamano: 72,
            mostrarIcono: false,
            color: esquema.primary,
          ),
          const SizedBox(height: 8),
          const Text('Buscando edificios…', textAlign: TextAlign.center),
        ],
      );
    }

    if (_error != null) {
      return Card(
        color: esquema.errorContainer,
        child: ListTile(
          leading: Icon(Icons.cloud_off, color: esquema.onErrorContainer),
          title: Text(_error!,
              style: TextStyle(color: esquema.onErrorContainer)),
          trailing: TextButton(
            onPressed: () => _sincronizar(forzarRed: true),
            child: const Text('Reintentar'),
          ),
        ),
      );
    }

    final r = _resultado!;
    final f = r.sincronizadoEn;
    final fecha = f == null
        ? ''
        : ' · ${_dos(f.day)}/${_dos(f.month)} ${_dos(f.hour)}:${_dos(f.minute)}';
    final offline = r.esOffline;

    // Píldora compacta: "✓ 23 lugares · Sincronizado 19/11 23:37  ⟳".
    final fondo =
        offline ? esquema.tertiaryContainer : esquema.secondaryContainer;
    final texto =
        offline ? esquema.onTertiaryContainer : esquema.onSecondaryContainer;
    return Material(
      color: fondo,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => _sincronizar(forzarRed: true),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(offline ? Icons.cloud_off : Icons.cloud_done,
                  size: 18, color: texto),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${r.edificios.length} lugares guardados · '
                  '${offline ? 'Sin conexión' : 'Sincronizado'}$fecha',
                  style: TextStyle(color: texto, fontSize: 13),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Sincronizar',
                child: Icon(Icons.sync, size: 18, color: texto),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _dos(int n) => n.toString().padLeft(2, '0');
}

/// Botón grande de cada modo de navegación.
class _OpcionNavegacion extends StatelessWidget {
  const _OpcionNavegacion({
    required this.icono,
    required this.titulo,
    required this.detalle,
    required this.habilitado,
    required this.onTap,
    this.destacado = false,
  });

  final IconData icono;
  final String titulo;
  final String detalle;
  final bool habilitado;
  final bool destacado;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final fondo =
        destacado ? esquema.primaryContainer : esquema.surfaceContainerHigh;
    final texto =
        destacado ? esquema.onPrimaryContainer : esquema.onSurface;

    return Opacity(
      opacity: habilitado ? 1 : 0.5,
      child: Card(
        color: fondo,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: habilitado ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _IconoMenu(icono: icono, tamano: 64, color: texto),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(titulo,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: texto)),
                      const SizedBox(height: 4),
                      Text(detalle,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: texto)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: texto),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mosaico cuadrado para las formas secundarias de navegar.
class _Mosaico extends StatelessWidget {
  const _Mosaico({
    required this.icono,
    required this.titulo,
    required this.habilitado,
    required this.onTap,
  });

  final IconData icono;
  final String titulo;
  final bool habilitado;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return Opacity(
      opacity: habilitado ? 1 : 0.5,
      child: Card(
        margin: EdgeInsets.zero,
        color: esquema.surfaceContainerHigh,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: habilitado ? onTap : null,
          child: AspectRatio(
            aspectRatio: 0.95,
            child: Padding(
              padding: const EdgeInsets.all(10),
              // El ícono se encoge y el texto se escala para caber siempre,
              // aunque el teléfono tenga la letra grande (sin "overflowed").
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _IconoMenu(
                          icono: icono, tamano: 64, color: esquema.primary),
                    ),
                  ),
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      titulo,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(color: esquema.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ícono ilustrado del menú (assets/icon/menu_*.png, fondo transparente).
/// Si la imagen no existe, usa el ícono de Material como respaldo.
class _IconoMenu extends StatelessWidget {
  const _IconoMenu({required this.icono, required this.tamano, required this.color});

  final IconData icono;
  final double tamano;
  final Color color;

  static final _imagenes = <IconData, String>{
    Icons.search: 'assets/icon/menu_buscar.png',
    Icons.directions_walk: 'assets/icon/menu_libre.png',
    Icons.apartment: 'assets/icon/menu_edificios.png',
    Icons.map_outlined: 'assets/icon/menu_mapa.png',
  };

  @override
  Widget build(BuildContext context) {
    final ruta = _imagenes[icono];
    final respaldo = Icon(icono, size: tamano * 0.6, color: color);
    if (ruta == null) return respaldo;
    return Image.asset(
      ruta,
      width: tamano,
      height: tamano,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => respaldo,
    );
  }
}
