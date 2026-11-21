import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'uth_themes.dart';

/// Tema activo + persistencia en shared_preferences.
class TemaController extends ChangeNotifier {
  TemaController._(this._prefs, this._actual);

  static const String _clave = 'uth_tema_id';

  final SharedPreferences? _prefs;
  UthTema _actual;

  UthTema get actual => _actual;
  int get indice => UthTemas.todos.indexOf(_actual);

  /// Lee el tema guardado; si falla el almacenamiento usa el tema 1.
  static Future<TemaController> cargar() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null;
    }
    return TemaController._(prefs, UthTemas.porId(prefs?.getString(_clave)));
  }

  /// Controlador sin persistencia (tests).
  factory TemaController.enMemoria([UthTema? tema]) =>
      TemaController._(null, tema ?? UthTemas.todos.first);

  Future<void> seleccionar(UthTema tema) async {
    if (identical(tema, _actual)) return;
    _actual = tema;
    notifyListeners();
    await _prefs?.setString(_clave, tema.id);
  }

  Future<void> desplazar(int paso) {
    final n = UthTemas.todos.length;
    return seleccionar(UthTemas.todos[(indice + paso) % n]);
  }
}

/// Expone el [TemaController] al árbol de widgets.
class TemaScope extends InheritedNotifier<TemaController> {
  const TemaScope({
    super.key,
    required TemaController controller,
    required super.child,
  }) : super(notifier: controller);

  static TemaController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TemaScope>();
    assert(scope != null, 'Falta TemaScope sobre MaterialApp');
    return scope!.notifier!;
  }
}

/// Botón de paleta para la AppBar.
/// Toque: abre el selector. Mantener presionado: siguiente tema.
class BotonTemas extends StatelessWidget {
  const BotonTemas({super.key});

  @override
  Widget build(BuildContext context) {
    final temas = TemaScope.of(context);
    return IconButton(
      tooltip: 'Tema: ${temas.actual.nombre}',
      icon: const Icon(Icons.palette_outlined),
      onPressed: () => mostrarSelectorTemas(context),
      onLongPress: () async {
        await temas.desplazar(1);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            duration: const Duration(milliseconds: 1200),
            content: Text(
                '${temas.indice + 1}/${UthTemas.todos.length} · ${temas.actual.nombre}'),
          ));
      },
    );
  }
}

Future<void> mostrarSelectorTemas(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const _SelectorTemas(),
  );
}

class _SelectorTemas extends StatelessWidget {
  const _SelectorTemas();

  @override
  Widget build(BuildContext context) {
    final temas = TemaScope.of(context);
    final tema = Theme.of(context);
    final total = UthTemas.todos.length;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Tema ${temas.indice + 1}/$total · ${temas.actual.nombre}',
                    style: tema.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Anterior',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => temas.desplazar(-1),
                ),
                IconButton.filledTonal(
                  tooltip: 'Siguiente',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => temas.desplazar(1),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: total,
              itemBuilder: (context, i) {
                final t = UthTemas.todos[i];
                final elegido = identical(t, temas.actual);
                return ListTile(
                  minTileHeight: 72,
                  selected: elegido,
                  leading: _Muestra(tema: t),
                  title: Text('${i + 1}. ${t.nombre}'),
                  subtitle: Text(
                      '${t.oscuro ? 'Oscuro' : 'Claro'}${i == 0 ? ' · recomendado' : ''}'),
                  trailing: elegido ? const Icon(Icons.check_circle) : null,
                  onTap: () => temas.seleccionar(t),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Miniatura: fondo, barra superior, punto primario y punto acento.
class _Muestra extends StatelessWidget {
  const _Muestra({required this.tema});

  final UthTema tema;

  @override
  Widget build(BuildContext context) {
    Widget punto(Color c) => Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: tema.texto.withValues(alpha: 0.4)),
          ),
        );
    return Container(
      width: 56,
      height: 48,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tema.fondo,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        children: [
          Container(height: 12, color: tema.barra),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [punto(tema.primario), punto(tema.acento)],
            ),
          ),
          Container(height: 8, color: tema.superficie),
        ],
      ),
    );
  }
}
