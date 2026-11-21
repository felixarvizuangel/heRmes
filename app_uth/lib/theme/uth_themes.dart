import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Paleta base (16 colores de referencia). Todos los temas salen de aquí.
abstract final class UthPaleta {
  static const Color lavanda = Color(0xFFD2C3F6);
  static const Color violeta = Color(0xFF36255C);
  static const Color onyx = Color(0xFF020202);
  static const Color celeste = Color(0xFFB2D5E5);
  static const Color vino = Color(0xFF32292F);
  static const Color turquesa = Color(0xFF99E1D9);
  static const Color carbon = Color(0xFF171717);
  static const Color lima = Color(0xFFC6FF34);
  static const Color cosmic = Color(0xFF23212C);
  static const Color vainilla = Color(0xFFF1FEC8);
  static const Color rosa = Color(0xFFF2C4CE);
  static const Color navy = Color(0xFF062045);
  static const Color limaClara = Color(0xFFCDFC8A);
  static const Color teal = Color(0xFF022E21);
  static const Color jet = Color(0xFF1D1D1D);
  static const Color orquidea = Color(0xFFE5BDDF);
}

/// Colores propios de la app que Material 3 no cubre: aguja del radar,
/// ficha de llegada y pines del mapa por categoría.
@immutable
class UthColores extends ThemeExtension<UthColores> {
  const UthColores({
    required this.aguja,
    required this.llegada,
    required this.sobreLlegada,
    required this.pinAcademico,
    required this.pinAdministrativo,
    required this.pinServicios,
    required this.bordePin,
    required this.mapaOscuro,
  });

  final Color aguja;
  final Color llegada;
  final Color sobreLlegada;
  final Color pinAcademico;
  final Color pinAdministrativo;
  final Color pinServicios;
  final Color bordePin;

  /// true → teselas OSM invertidas (modo noche).
  final bool mapaOscuro;

  static UthColores of(BuildContext context) =>
      Theme.of(context).extension<UthColores>() ?? UthTemas.todos.first.colores;

  @override
  UthColores copyWith({
    Color? aguja,
    Color? llegada,
    Color? sobreLlegada,
    Color? pinAcademico,
    Color? pinAdministrativo,
    Color? pinServicios,
    Color? bordePin,
    bool? mapaOscuro,
  }) =>
      UthColores(
        aguja: aguja ?? this.aguja,
        llegada: llegada ?? this.llegada,
        sobreLlegada: sobreLlegada ?? this.sobreLlegada,
        pinAcademico: pinAcademico ?? this.pinAcademico,
        pinAdministrativo: pinAdministrativo ?? this.pinAdministrativo,
        pinServicios: pinServicios ?? this.pinServicios,
        bordePin: bordePin ?? this.bordePin,
        mapaOscuro: mapaOscuro ?? this.mapaOscuro,
      );

  @override
  UthColores lerp(UthColores? other, double t) {
    if (other == null) return this;
    return UthColores(
      aguja: Color.lerp(aguja, other.aguja, t)!,
      llegada: Color.lerp(llegada, other.llegada, t)!,
      sobreLlegada: Color.lerp(sobreLlegada, other.sobreLlegada, t)!,
      pinAcademico: Color.lerp(pinAcademico, other.pinAcademico, t)!,
      pinAdministrativo:
          Color.lerp(pinAdministrativo, other.pinAdministrativo, t)!,
      pinServicios: Color.lerp(pinServicios, other.pinServicios, t)!,
      bordePin: Color.lerp(bordePin, other.bordePin, t)!,
      mapaOscuro: t < 0.5 ? mapaOscuro : other.mapaOscuro,
    );
  }
}

/// Una combinación de color con nombre. Los roles de Material 3 se derivan
/// de 7 colores eligiendo siempre el texto con mayor contraste (WCAG AA).
class UthTema {
  UthTema({
    required this.id,
    required this.nombre,
    required this.brillo,
    required this.fondo,
    required this.superficie,
    required this.texto,
    required this.primario,
    required this.secundario,
    required this.acento,
    required this.barra,
    required this.pines,
  }) : assert(pines.length == 3);

  final String id;
  final String nombre;
  final Brightness brillo;
  final Color fondo;
  final Color superficie;
  final Color texto;
  final Color primario;
  final Color secundario;
  final Color acento;
  final Color barra;

  /// Académico, administrativo, servicios.
  final List<Color> pines;

  bool get oscuro => brillo == Brightness.dark;

  late final ThemeData data = _construir();

  UthColores get colores => data.extension<UthColores>()!;

  // ───────────────────────── Contraste ─────────────────────────

  static double contraste(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final (hi, lo) = la > lb ? (la, lb) : (lb, la);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Texto legible sobre [c]: el de mayor contraste entre los candidatos.
  Color sobre(Color c) {
    var mejor = texto;
    for (final x in [fondo, UthPaleta.onyx, UthPaleta.vainilla]) {
      if (contraste(c, x) > contraste(c, mejor)) mejor = x;
    }
    return mejor;
  }

  /// Mezcla texto→fondo en [t] y la acerca al texto hasta cumplir [minimo]
  /// contra fondo y superficie.
  Color _mezclaLegible(double t, double minimo) {
    var k = t;
    while (k > 0) {
      final c = Color.lerp(texto, fondo, k)!;
      if (contraste(c, fondo) >= minimo && contraste(c, superficie) >= minimo) {
        return c;
      }
      k -= 0.02;
    }
    return texto;
  }

  Color _mezcla(Color c, double t) => Color.lerp(fondo, c, t)!;

  // ───────────────────────── ThemeData ─────────────────────────

  ThemeData _construir() {
    // Terciario se usa como texto: requiere 4.5:1; si el acento no llega,
    // cae a secundario o primario y el acento queda como contenedor.
    final terciario = contraste(acento, fondo) >= 4.5
        ? acento
        : (contraste(secundario, fondo) >= 4.5 ? secundario : primario);
    // Aguja = elemento gráfico: basta 3:1.
    final aguja = contraste(acento, fondo) >= 3 ? acento : primario;

    final error = oscuro ? const Color(0xFFFFB4AB) : const Color(0xFF8C1D18);
    final errorContainer =
        oscuro ? const Color(0xFF93000A) : const Color(0xFFFFDAD6);

    final primaryContainer = _mezcla(primario, 0.22);
    final secondaryContainer = _mezcla(secundario, 0.30);

    final scheme = ColorScheme(
      brightness: brillo,
      primary: primario,
      onPrimary: sobre(primario),
      primaryContainer: primaryContainer,
      onPrimaryContainer: sobre(primaryContainer),
      secondary: secundario,
      onSecondary: sobre(secundario),
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: sobre(secondaryContainer),
      tertiary: terciario,
      onTertiary: sobre(terciario),
      tertiaryContainer: acento,
      onTertiaryContainer: sobre(acento),
      error: error,
      onError: sobre(error),
      errorContainer: errorContainer,
      onErrorContainer:
          oscuro ? const Color(0xFFFFDAD6) : const Color(0xFF410002),
      surface: fondo,
      onSurface: texto,
      onSurfaceVariant: _mezclaLegible(0.28, 4.5),
      surfaceDim: Color.lerp(fondo, UthPaleta.onyx, oscuro ? 0.3 : 0.08)!,
      surfaceBright: Color.lerp(fondo, superficie, oscuro ? 0.9 : 0.1)!,
      surfaceContainerLowest: fondo,
      surfaceContainerLow: Color.lerp(fondo, superficie, 0.35)!,
      surfaceContainer: Color.lerp(fondo, superficie, 0.6)!,
      surfaceContainerHigh: Color.lerp(fondo, superficie, 0.8)!,
      surfaceContainerHighest: superficie,
      outline: _mezclaLegible(0.5, 3),
      outlineVariant: Color.lerp(texto, fondo, 0.78)!,
      shadow: UthPaleta.onyx,
      scrim: UthPaleta.onyx,
      inverseSurface: texto,
      onInverseSurface: fondo,
      inversePrimary: fondo,
      surfaceTint: primario,
    );

    final sobreBarra = sobre(barra);
    final sobreAcento = sobre(acento);

    return ThemeData(
      useMaterial3: true,
      brightness: brillo,
      colorScheme: scheme,
      scaffoldBackgroundColor: fondo,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: barra,
        foregroundColor: sobreBarra,
        systemOverlayStyle: barra.computeLuminance() < 0.4
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: sobreBarra,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: superficie,
        indicatorColor: acento,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected)
                ? sobreAcento
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: aguja,
        linearTrackColor: scheme.outlineVariant,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: fondo,
        dragHandleColor: scheme.onSurfaceVariant,
      ),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      extensions: [
        UthColores(
          aguja: aguja,
          llegada: acento,
          sobreLlegada: sobreAcento,
          pinAcademico: pines[0],
          pinAdministrativo: pines[1],
          pinServicios: pines[2],
          bordePin: UthPaleta.onyx,
          mapaOscuro: oscuro,
        ),
      ],
    );
  }
}

/// Las 20 combinaciones. La 1 es la recomendada.
abstract final class UthTemas {
  static final List<UthTema> todos = [
    UthTema(
      id: 'navy_lima',
      nombre: 'Navy Lima',
      brillo: Brightness.light,
      fondo: UthPaleta.vainilla,
      superficie: UthPaleta.celeste,
      texto: UthPaleta.navy,
      primario: UthPaleta.navy,
      secundario: UthPaleta.teal,
      acento: UthPaleta.lima,
      barra: UthPaleta.navy,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'navy_lima_noche',
      nombre: 'Navy Lima Noche',
      brillo: Brightness.dark,
      fondo: UthPaleta.carbon,
      superficie: UthPaleta.cosmic,
      texto: UthPaleta.celeste,
      primario: UthPaleta.celeste,
      secundario: UthPaleta.turquesa,
      acento: UthPaleta.lima,
      barra: UthPaleta.navy,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.lima],
    ),
    UthTema(
      id: 'lavanda_violeta',
      nombre: 'Lavanda Violeta',
      brillo: Brightness.light,
      fondo: UthPaleta.lavanda,
      superficie: UthPaleta.orquidea,
      texto: UthPaleta.violeta,
      primario: UthPaleta.violeta,
      secundario: UthPaleta.vino,
      acento: UthPaleta.lima,
      barra: UthPaleta.violeta,
      pines: [UthPaleta.celeste, UthPaleta.rosa, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'violeta_nocturno',
      nombre: 'Violeta Nocturno',
      brillo: Brightness.dark,
      fondo: UthPaleta.violeta,
      superficie: UthPaleta.cosmic,
      texto: UthPaleta.lavanda,
      primario: UthPaleta.lavanda,
      secundario: UthPaleta.orquidea,
      acento: UthPaleta.lima,
      barra: UthPaleta.cosmic,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.lima],
    ),
    UthTema(
      id: 'cosmic_lima',
      nombre: 'Cosmic Lima',
      brillo: Brightness.dark,
      fondo: UthPaleta.cosmic,
      superficie: UthPaleta.jet,
      texto: UthPaleta.vainilla,
      primario: UthPaleta.lima,
      secundario: UthPaleta.lavanda,
      acento: UthPaleta.turquesa,
      barra: UthPaleta.cosmic,
      pines: [UthPaleta.turquesa, UthPaleta.lavanda, UthPaleta.lima],
    ),
    UthTema(
      id: 'onyx_neon',
      nombre: 'Onyx Neón',
      brillo: Brightness.dark,
      fondo: UthPaleta.onyx,
      superficie: UthPaleta.carbon,
      texto: UthPaleta.vainilla,
      primario: UthPaleta.lima,
      secundario: UthPaleta.limaClara,
      acento: UthPaleta.orquidea,
      barra: UthPaleta.onyx,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.lima],
    ),
    UthTema(
      id: 'bosque_teal',
      nombre: 'Bosque Teal',
      brillo: Brightness.dark,
      fondo: UthPaleta.teal,
      superficie: UthPaleta.jet,
      texto: UthPaleta.vainilla,
      primario: UthPaleta.limaClara,
      secundario: UthPaleta.turquesa,
      acento: UthPaleta.rosa,
      barra: UthPaleta.teal,
      pines: [UthPaleta.turquesa, UthPaleta.rosa, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'menta_teal',
      nombre: 'Menta Teal',
      brillo: Brightness.light,
      fondo: UthPaleta.turquesa,
      superficie: UthPaleta.celeste,
      texto: UthPaleta.teal,
      primario: UthPaleta.teal,
      secundario: UthPaleta.navy,
      acento: UthPaleta.lima,
      barra: UthPaleta.teal,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'vainilla_teal',
      nombre: 'Vainilla Teal',
      brillo: Brightness.light,
      fondo: UthPaleta.vainilla,
      superficie: UthPaleta.limaClara,
      texto: UthPaleta.teal,
      primario: UthPaleta.teal,
      secundario: UthPaleta.navy,
      acento: UthPaleta.turquesa,
      barra: UthPaleta.teal,
      pines: [UthPaleta.turquesa, UthPaleta.rosa, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'rosa_vino',
      nombre: 'Rosa Vino',
      brillo: Brightness.light,
      fondo: UthPaleta.rosa,
      superficie: UthPaleta.orquidea,
      texto: UthPaleta.vino,
      primario: UthPaleta.vino,
      secundario: UthPaleta.violeta,
      acento: UthPaleta.turquesa,
      barra: UthPaleta.vino,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'vino_rosa',
      nombre: 'Vino Rosa',
      brillo: Brightness.dark,
      fondo: UthPaleta.vino,
      superficie: UthPaleta.jet,
      texto: UthPaleta.rosa,
      primario: UthPaleta.rosa,
      secundario: UthPaleta.orquidea,
      acento: UthPaleta.limaClara,
      barra: UthPaleta.vino,
      pines: [UthPaleta.celeste, UthPaleta.rosa, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'orquidea_navy',
      nombre: 'Orquídea Navy',
      brillo: Brightness.light,
      fondo: UthPaleta.orquidea,
      superficie: UthPaleta.rosa,
      texto: UthPaleta.navy,
      primario: UthPaleta.navy,
      secundario: UthPaleta.violeta,
      acento: UthPaleta.celeste,
      barra: UthPaleta.navy,
      pines: [UthPaleta.celeste, UthPaleta.lavanda, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'carbon_turquesa',
      nombre: 'Carbón Turquesa',
      brillo: Brightness.dark,
      fondo: UthPaleta.carbon,
      superficie: UthPaleta.jet,
      texto: UthPaleta.vainilla,
      primario: UthPaleta.turquesa,
      secundario: UthPaleta.celeste,
      acento: UthPaleta.rosa,
      barra: UthPaleta.jet,
      pines: [UthPaleta.celeste, UthPaleta.rosa, UthPaleta.lima],
    ),
    UthTema(
      id: 'medianoche',
      nombre: 'Medianoche',
      brillo: Brightness.dark,
      fondo: UthPaleta.navy,
      superficie: UthPaleta.cosmic,
      texto: UthPaleta.celeste,
      primario: UthPaleta.turquesa,
      secundario: UthPaleta.lavanda,
      acento: UthPaleta.rosa,
      barra: UthPaleta.navy,
      pines: [UthPaleta.turquesa, UthPaleta.rosa, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'cielo_navy',
      nombre: 'Cielo Navy',
      brillo: Brightness.light,
      fondo: UthPaleta.celeste,
      superficie: UthPaleta.turquesa,
      texto: UthPaleta.navy,
      primario: UthPaleta.navy,
      secundario: UthPaleta.teal,
      acento: UthPaleta.rosa,
      barra: UthPaleta.navy,
      pines: [UthPaleta.vainilla, UthPaleta.rosa, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'jet_orquidea',
      nombre: 'Jet Orquídea',
      brillo: Brightness.dark,
      fondo: UthPaleta.jet,
      superficie: UthPaleta.cosmic,
      texto: UthPaleta.vainilla,
      primario: UthPaleta.orquidea,
      secundario: UthPaleta.lavanda,
      acento: UthPaleta.lima,
      barra: UthPaleta.jet,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.lima],
    ),
    UthTema(
      id: 'lima_onyx',
      nombre: 'Lima Onyx',
      brillo: Brightness.light,
      fondo: UthPaleta.limaClara,
      superficie: UthPaleta.vainilla,
      texto: UthPaleta.onyx,
      primario: UthPaleta.jet,
      secundario: UthPaleta.teal,
      acento: UthPaleta.violeta,
      barra: UthPaleta.jet,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.vainilla],
    ),
    UthTema(
      id: 'vainilla_violeta',
      nombre: 'Vainilla Violeta',
      brillo: Brightness.light,
      fondo: UthPaleta.vainilla,
      superficie: UthPaleta.lavanda,
      texto: UthPaleta.violeta,
      primario: UthPaleta.violeta,
      secundario: UthPaleta.navy,
      acento: UthPaleta.lima,
      barra: UthPaleta.violeta,
      pines: [UthPaleta.celeste, UthPaleta.lavanda, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'cosmic_rosa',
      nombre: 'Cosmic Rosa',
      brillo: Brightness.dark,
      fondo: UthPaleta.cosmic,
      superficie: UthPaleta.vino,
      texto: UthPaleta.rosa,
      primario: UthPaleta.rosa,
      secundario: UthPaleta.lavanda,
      acento: UthPaleta.turquesa,
      barra: UthPaleta.vino,
      pines: [UthPaleta.turquesa, UthPaleta.rosa, UthPaleta.limaClara],
    ),
    UthTema(
      id: 'pastel_mix',
      nombre: 'Pastel Mix',
      brillo: Brightness.light,
      fondo: UthPaleta.vainilla,
      superficie: UthPaleta.celeste,
      texto: UthPaleta.jet,
      primario: UthPaleta.navy,
      secundario: UthPaleta.violeta,
      acento: UthPaleta.orquidea,
      barra: UthPaleta.navy,
      pines: [UthPaleta.celeste, UthPaleta.orquidea, UthPaleta.limaClara],
    ),
  ];

  static UthTema porId(String? id) =>
      todos.firstWhere((t) => t.id == id, orElse: () => todos.first);
}
