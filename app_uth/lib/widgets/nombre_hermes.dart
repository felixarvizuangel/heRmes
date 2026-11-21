import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Logotipo de texto "heRmes".
///
/// - "he" y "mes" en Cinzel (letra de inscripciones de templos clásicos).
/// - La "R" en Cinzel Decorative y en un color de acento: es la R de Radar.
///
/// El color se elige según el FONDO real donde se dibuja (la barra de arriba
/// o el cuerpo de la pantalla), midiendo el contraste como lo hace la norma
/// de accesibilidad WCAG. Así el nombre se lee bien en los 20 temas, claros
/// u oscuros, sin colores fijos.
class NombreHermes extends StatelessWidget {
  const NombreHermes({
    super.key,
    this.tamano = 22,
    this.color,
    this.colorR,
    this.fondo,
    this.enBarra = false,
  });

  /// Tamaño de letra en puntos.
  final double tamano;

  /// Color fijo de "he" y "mes" (si es null se calcula según el fondo).
  final Color? color;

  /// Color fijo de la "R" (si es null se elige el acento más visible).
  final Color? colorR;

  /// Fondo sobre el que se dibuja. Si es null se deduce del tema.
  final Color? fondo;

  /// true cuando va dentro de la AppBar (el fondo es el de la barra).
  final bool enBarra;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final esquema = tema.colorScheme;

    final bg = fondo ??
        (enBarra
            ? (tema.appBarTheme.backgroundColor ?? esquema.surface)
            : tema.scaffoldBackgroundColor);

    // Texto base: el que más contraste tenga contra el fondo.
    final base = color ??
        _mejor(bg, [
          if (enBarra) tema.appBarTheme.foregroundColor ?? esquema.onSurface,
          esquema.onSurface,
          Colors.white,
          Colors.black,
        ], minimo: 4.5);

    // R: primer acento del tema que se distinga bien del fondo (≥ 3:1);
    // si ninguno, la misma del texto base (se distingue por la tipografía).
    final r = colorR ??
        _primeroVisible(bg, [
          esquema.secondary,
          esquema.primary,
          esquema.tertiary,
          if (enBarra) esquema.secondaryContainer,
          if (enBarra) esquema.primaryContainer,
        ]) ??
        base;

    final sombra = [
      Shadow(
        color: (_luz(bg) > 0.5 ? Colors.black : Colors.white).withValues(alpha: 0.18),
        blurRadius: tamano * 0.08,
        offset: Offset(0, tamano * 0.03),
      ),
    ];

    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontFamily: 'Cinzel',
          fontWeight: FontWeight.w700,
          fontSize: tamano,
          color: base,
          letterSpacing: tamano * 0.04,
          shadows: sombra,
        ),
        children: [
          const TextSpan(text: 'he'),
          TextSpan(
            text: 'R',
            style: TextStyle(
              fontFamily: 'CinzelDecorative',
              fontWeight: FontWeight.w700,
              fontSize: tamano * 1.15,
              color: r,
            ),
          ),
          const TextSpan(text: 'mes'),
        ],
      ),
      semanticsLabel: 'Hermes',
      textAlign: TextAlign.center,
    );
  }

  // ───── Contraste WCAG: (L1 + 0.05) / (L2 + 0.05), L = luminancia relativa ─────

  static double _luz(Color c) => c.computeLuminance();

  static double contraste(Color a, Color b) {
    final la = _luz(a), lb = _luz(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  static Color? _primeroVisible(Color fondo, List<Color> opciones) {
    for (final c in opciones) {
      if (contraste(c, fondo) >= 3.0) return c;
    }
    return null;
  }

  static Color _mejor(Color fondo, List<Color> opciones, {double minimo = 4.5}) {
    for (final c in opciones) {
      if (contraste(c, fondo) >= minimo) return c;
    }
    opciones.sort((a, b) => contraste(b, fondo).compareTo(contraste(a, fondo)));
    return opciones.first;
  }
}
