import 'package:flutter/material.dart';

import '../models/edificio_model.dart';

/// Foto de fachada de un edificio que se ve AUNQUE NO HAYA INTERNET.
///
/// 1. Primero la copia incluida en la app: `assets/fachadas/<codigo>.jpg`
///    (las 18 fotos de Street View del backend, ≈ 2.3 MB).
/// 2. Si no hay copia (p. ej. una foto nueva subida desde el admin), la
///    descarga del backend (`foto_fachada`).
/// 3. Si el edificio no tiene fachada: su vista aérea
///    (`assets/aereas/<codigo>.jpg`, Esri World Imagery).
/// 4. Sin nada de eso: un ícono de edificio.
class FotoFachada extends StatelessWidget {
  const FotoFachada({
    super.key,
    required this.edificio,
    this.fit = BoxFit.cover,
    this.sinFoto,
  });

  final Edificio edificio;
  final BoxFit fit;

  /// Lo que se muestra si no hay foto (por defecto, un ícono).
  final Widget? sinFoto;

  /// Ruta del asset con la foto de [e] (EDIF-A → assets/fachadas/edif-a.jpg).
  static String asset(Edificio e) =>
      'assets/fachadas/${e.codigo.toLowerCase()}.jpg';

  /// Vista aérea de [e] (EDIF-A → assets/aereas/edif-a.jpg).
  static String aerea(Edificio e) =>
      'assets/aereas/${e.codigo.toLowerCase()}.jpg';

  /// true si el edificio tiene foto de FACHADA (en la app o en el backend).
  static bool tieneFoto(Edificio e) =>
      e.fotoFachada != null || _conAsset.contains(e.codigo.toUpperCase());

  /// Edificios con foto de fachada incluida en la app (assets/fachadas).
  static const Set<String> _conAsset = {
    'AREA-1', 'AREA-2', 'AREA-4', 'AREA-5', 'EDIF-A', 'EDIF-B', 'EDIF-D',
    'EDIF-E', 'EDIF-F', 'EDIF-H', 'EDIF-J', 'EDIF-K', 'EDIF-M', 'EDIF-P',
    'EDIF-Q', 'EDIF-R', 'EDIF-S', 'EDIF-T',
  };

  static const String creditoFachada = 'Imagen: Google Street View';
  static const String creditoAerea = 'Imagen: Esri World Imagery';

  @override
  Widget build(BuildContext context) {
    final respaldo = sinFoto ??
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.apartment, size: 48)),
        );
    final vistaAerea = Image.asset(aerea(edificio),
        fit: fit, errorBuilder: (_, __, ___) => respaldo);
    final url = edificio.fotoFachada;
    Widget red() => url == null
        ? vistaAerea
        : Image.network(url, fit: fit, errorBuilder: (_, __, ___) => vistaAerea);
    if (!_conAsset.contains(edificio.codigo.toUpperCase())) return red();
    return Image.asset(
      asset(edificio),
      fit: fit,
      errorBuilder: (_, __, ___) => red(),
    );
  }
}

/// Fachada + vista aérea para deslizar (detalle y radar). Si el edificio no
/// tiene fachada, muestra solo la vista aérea. Debajo va el crédito de la
/// imagen visible y unos puntitos que indican cuál es.
class GaleriaEdificio extends StatefulWidget {
  const GaleriaEdificio({super.key, required this.edificio});

  final Edificio edificio;

  @override
  State<GaleriaEdificio> createState() => _GaleriaEdificioState();
}

class _GaleriaEdificioState extends State<GaleriaEdificio> {
  int _pagina = 0;

  @override
  Widget build(BuildContext context) {
    final e = widget.edificio;
    final tema = Theme.of(context);
    final conFachada = FotoFachada.tieneFoto(e);
    final paginas = <({Widget imagen, String credito, String titulo})>[
      if (conFachada)
        (
          imagen: FotoFachada(edificio: e),
          credito: FotoFachada.creditoFachada,
          titulo: 'Fachada',
        ),
      (
        imagen: Image.asset(
          FotoFachada.aerea(e),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => ColoredBox(
            color: tema.colorScheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.apartment, size: 48)),
          ),
        ),
        credito: FotoFachada.creditoAerea,
        titulo: 'Desde arriba',
      ),
    ];
    final actual = paginas[_pagina.clamp(0, paginas.length - 1)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView(
                  onPageChanged: (i) => setState(() => _pagina = i),
                  children: [for (final p in paginas) p.imagen],
                ),
                // Etiqueta de la vista actual (Fachada / Desde arriba).
                Positioned(
                  left: 8,
                  top: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      child: Text(
                        paginas.length > 1
                            ? '${actual.titulo} · desliza'
                            : actual.titulo,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
                if (paginas.length > 1)
                  Positioned(
                    bottom: 8,
                    left: 0,
                    right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < paginas.length; i++)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _pagina
                                  ? Colors.white
                                  : Colors.white54,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(actual.credito, style: tema.textTheme.labelSmall),
        ),
      ],
    );
  }
}
