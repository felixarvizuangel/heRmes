import 'package:flutter/material.dart';

import '../models/edificio_model.dart';
import '../services/api_service.dart';
import '../widgets/foto_fachada.dart';
import 'map_screen.dart';
import 'radar_screen.dart';

/// Pantalla de detalle del inmueble (nivel 7).
///
/// Muestra todo lo que viene en la lista local: foto, categoría, horario,
/// descripción, dependencias, palabras clave y puntos de acceso.
/// El botón "Navegar aquí" abre la brújula (Modo A) con este destino.
class DetalleScreen extends StatelessWidget {
  const DetalleScreen({
    super.key,
    required this.edificio,
    this.apiService,
    this.mostrarNavegar = true,
  });

  final Edificio edificio;
  final ApiService? apiService;

  /// false cuando se abre desde la navegación libre (ya estás ahí).
  final bool mostrarNavegar;

  @override
  Widget build(BuildContext context) {
    final e = edificio;
    final tema = Theme.of(context);
    final abierto = e.estaAbierto();

    return Scaffold(
      appBar: AppBar(title: Text(e.codigo.isEmpty ? 'Detalle' : e.codigo)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // Fachada + vista aérea (incluidas en la app: se ven sin conexión).
            GaleriaEdificio(edificio: e),
            const SizedBox(height: 12),
            Text(e.nombre, style: tema.textTheme.headlineSmall),
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
                        '${abierto == true ? 'Abierto' : 'Cerrado'} · ${e.horarioTexto}'),
                  ),
              ],
            ),
            if (e.descripcion.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(e.descripcion, style: tema.textTheme.bodyLarge),
            ],
            if (e.dependencias.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Dependencias', style: tema.textTheme.titleMedium),
              for (final d in e.dependencias)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.chevron_right),
                  title: Text(d),
                ),
            ],
            if (e.palabrasClave.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Servicios y trámites', style: tema.textTheme.titleMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final p in e.palabrasVisibles)
                    Chip(label: Text(p), visualDensity: VisualDensity.compact),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text('Puntos de acceso', style: tema.textTheme.titleMedium),
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
      ),
      bottomNavigationBar: !mostrarNavegar
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    // Mapa con tu posición, este destino y la línea recta.
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 52)),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Mapa'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MapScreen(
                            apiService: apiService,
                            destinoInicial: e,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52)),
                        icon: const Icon(Icons.navigation),
                        label: const Text('Navegar aquí'),
                        // Abre la brújula (Modo A) ya con el destino elegido.
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RadarScreen(
                              apiService: apiService,
                              edificioInicial: e,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
