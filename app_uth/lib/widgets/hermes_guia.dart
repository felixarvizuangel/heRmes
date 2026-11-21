import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Hermes, el guía de la app: su avatar flota (sube y baja) y habla con un
/// globo de diálogo. Si existe `assets/icon/hermes_guia.png` (un personaje
/// con fondo transparente) se usa; si no, se usa el ícono de la R alada.
class HermesGuia extends StatefulWidget {
  const HermesGuia({super.key, required this.mensaje, this.onTap});

  /// Lo que dice Hermes. Al cambiar, el globo hace una animación.
  final String mensaje;
  final VoidCallback? onTap;

  @override
  State<HermesGuia> createState() => _HermesGuiaState();
}

class _HermesGuiaState extends State<HermesGuia>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flotar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _flotar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: widget.onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Avatar flotando.
          AnimatedBuilder(
            animation: _flotar,
            builder: (_, child) => Transform.translate(
              offset: Offset(0, -6 * math.sin(_flotar.value * math.pi)),
              child: child,
            ),
            // Personaje de cuerpo completo con fondo transparente.
            child: Image.asset(
              'assets/icon/hermes_guia.png',
              width: 96,
              height: 96,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => ClipOval(
                child: Image.asset('assets/icon/hermes_icon.png',
                    width: 64, height: 64, fit: BoxFit.cover),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Globo de diálogo con animación al cambiar el mensaje.
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
                alignment: Alignment.bottomLeft,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: Container(
                key: ValueKey(widget.mensaje),
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: esquema.primaryContainer,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                    bottomLeft: Radius.circular(4),
                  ),
                  boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
                ),
                child: Text(
                  widget.mensaje,
                  style: TextStyle(
                    color: esquema.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
