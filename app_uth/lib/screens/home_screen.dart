import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'map_screen.dart';
import 'radar_screen.dart';

/// Contenedor con barra de navegación inferior (Material 3):
/// Radar/Brújula  ↔  Mapa del campus. Comparten un único [ApiService].
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.apiService});

  final ApiService? apiService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();
  int _indice = 0;

  @override
  void dispose() {
    if (widget.apiService == null) _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _indice,
        children: [
          RadarScreen(apiService: _api),
          MapScreen(apiService: _api),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _indice,
        onDestinationSelected: (i) => setState(() => _indice = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: 'Radar',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Mapa',
          ),
        ],
      ),
    );
  }
}