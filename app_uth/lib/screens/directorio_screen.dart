import 'package:flutter/material.dart';

import '../models/edificio_model.dart';
import '../services/api_service.dart';
import 'detalle_screen.dart';

/// Directorio de edificios (nivel 7 y búsqueda del nivel 9).
///
/// - Trabaja SOLO con la lista local recibida (no hace peticiones).
/// - Filtra en tiempo real por nombre, código, dependencia o palabra clave
///   ([Edificio.coincide]) y por categoría (Académico/Administrativo/Servicios).
/// - Al tocar un edificio abre [DetalleScreen]; desde ahí se puede navegar.
class DirectorioScreen extends StatefulWidget {
  const DirectorioScreen({
    super.key,
    required this.edificios,
    this.apiService,
    this.modoBusqueda = false,
  });

  final List<Edificio> edificios;
  final ApiService? apiService;

  /// true = "Buscar un lugar": título distinto y teclado abierto.
  final bool modoBusqueda;

  @override
  State<DirectorioScreen> createState() => _DirectorioScreenState();
}

class _DirectorioScreenState extends State<DirectorioScreen> {
  String _consulta = '';

  /// null = todas las categorías.
  CategoriaEdificio? _categoria;

  List<Edificio> get _filtrados {
    final lista = widget.edificios
        .where((e) => _categoria == null || e.categoria == _categoria)
        .where((e) => e.coincide(_consulta))
        .toList()
      ..sort((a, b) => a.nombre.compareTo(b.nombre));
    return lista;
  }

  void _abrirDetalle(Edificio e) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetalleScreen(edificio: e, apiService: widget.apiService),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtrados;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.modoBusqueda ? '¿A dónde vas?' : 'Edificios'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SearchBar(
                autoFocus: widget.modoBusqueda,
                hintText: 'Cafetería, biblioteca, rectoría…',
                leading: const Icon(Icons.search),
                onChanged: (v) => setState(() => _consulta = v),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _chip(null, 'Todas'),
                  for (final c in CategoriaEdificio.values) _chip(c, c.etiqueta),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('Sin coincidencias'))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final e = items[i];
                        return ListTile(
                          minTileHeight: 72,
                          leading: CircleAvatar(
                            child: Text(e.codigo.isEmpty
                                ? '?'
                                : e.codigo.split('-').last),
                          ),
                          title: Text(e.nombre),
                          subtitle: Text(
                            [e.categoriaDisplay, ...e.dependencias.take(2)]
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _abrirDetalle(e),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(CategoriaEdificio? c, String texto) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(texto),
        selected: _categoria == c,
        onSelected: (_) => setState(() => _categoria = c),
      ),
    );
  }
}
