import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animación de carga de heRmes: un radar que barre alrededor del ícono
/// (la R alada) mientras una aguja de brújula gira buscando el norte.
///
/// - Anillos concéntricos fijos (como en el ícono).
/// - Un "barrido" de radar (abanico con degradado) que da una vuelta cada 2 s.
/// - Puntos que se encienden cuando el barrido pasa (edificios "detectados").
/// - El ícono al centro late suavemente.
class HermesCargando extends StatefulWidget {
  const HermesCargando({
    super.key,
    this.tamano = 200,
    this.color = const Color(0xFFC6F432), // verde lima heRmes
    this.mostrarIcono = true,
  });

  final double tamano;
  final Color color;

  /// Los tests lo ponen en false para que pumpAndSettle no espere una
  /// animación infinita. También se respeta "reducir animaciones" del sistema.
  static bool animar = true;

  /// false = solo el radar (para tamaños chicos, p. ej. dentro de una tarjeta).
  final bool mostrarIcono;

  @override
  State<HermesCargando> createState() => _HermesCargandoState();
}

class _HermesCargandoState extends State<HermesCargando>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final quieto = !HermesCargando.animar ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (quieto) {
      _c.value = 0.3;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tamano;
    return Semantics(
      label: 'Cargando',
      child: SizedBox.square(
        dimension: t,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // Latido del ícono: 0.94 → 1.0 → 0.94 (dos latidos por vuelta).
            final latido = 0.97 + 0.03 * math.sin(_c.value * 4 * math.pi);
            return Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size.square(t),
                  painter: _RadarPainter(progreso: _c.value, color: widget.color),
                ),
                if (widget.mostrarIcono)
                  Transform.scale(
                    scale: latido,
                    child: ClipOval(
                      child: Image.asset(
                        'assets/icon/hermes_icon.png',
                        width: t * 0.52,
                        height: t * 0.52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.explore,
                          size: t * 0.4,
                          color: widget.color,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progreso, required this.color});

  /// 0..1 = una vuelta completa del barrido.
  final double progreso;
  final Color color;

  // "Edificios" fijos en coordenadas polares (ángulo en vueltas, radio 0..1).
  static const _puntos = [
    (0.10, 0.82), (0.27, 0.66), (0.41, 0.90),
    (0.58, 0.74), (0.72, 0.86), (0.89, 0.64),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    // 1) Anillos concéntricos.
    final anillo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, r * 0.012)
      ..color = color.withValues(alpha: 0.35);
    for (final f in [0.98, 0.80, 0.62]) {
      canvas.drawCircle(c, r * f, anillo);
    }

    // 2) Marcas N/E/S/O de brújula en el anillo exterior.
    final marca = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = math.max(1.5, r * 0.02)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 4; i++) {
      final a = i * math.pi / 2 - math.pi / 2;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * r * 0.88, c + dir * r * 0.98, marca);
    }

    // 3) Barrido del radar: abanico de 70° con degradado que gira.
    //    El ángulo 0 de Flutter apunta al Este; restamos 90° para empezar
    //    en el Norte y sumamos la vuelta actual (progreso · 360°).
    final angulo = progreso * 2 * math.pi - math.pi / 2;
    const abertura = 70 * math.pi / 180;
    final rect = Rect.fromCircle(center: c, radius: r * 0.98);
    final barrido = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: abertura,
        colors: [color.withValues(alpha: 0.0), color.withValues(alpha: 0.45)],
        transform: GradientRotation(angulo - abertura),
      ).createShader(rect);
    canvas.drawArc(rect, angulo - abertura, abertura, true, barrido);

    // Línea brillante en el borde del barrido.
    final borde = Paint()
      ..color = color
      ..strokeWidth = math.max(1.5, r * 0.018)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      c,
      c + Offset(math.cos(angulo), math.sin(angulo)) * r * 0.98,
      borde,
    );

    // 4) Puntos que brillan justo después de que pasa el barrido.
    for (final (vuelta, dist) in _puntos) {
      // Qué tan atrás quedó el barrido respecto al punto (0 = acaba de pasar).
      final atraso = (progreso - vuelta) % 1.0;
      final brillo = (1 - atraso * 2.5).clamp(0.0, 1.0);
      if (brillo <= 0) continue;
      final a = vuelta * 2 * math.pi - math.pi / 2;
      final p = c + Offset(math.cos(a), math.sin(a)) * r * dist;
      canvas.drawCircle(
        p,
        r * 0.035 * (0.6 + 0.4 * brillo),
        Paint()..color = color.withValues(alpha: brillo),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progreso != progreso || old.color != color;
}
