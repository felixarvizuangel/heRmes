import 'package:app_uth/services/ruta_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('recortar: descarta lo ya caminado y mide el desvío', () {
    final ruta = [
      const LatLng(29.0000, -110.9000),
      const LatLng(29.0005, -110.9000),
      const LatLng(29.0010, -110.9000),
      const LatLng(29.0010, -110.9005),
    ];
    const yo = LatLng(29.00051, -110.9000);
    final r = RutaService.recortar(ruta, yo);
    expect(r.restante.first, yo);
    expect(r.restante.length, 3); // yo + 2 puntos que faltan
    expect(r.desvio, lessThan(2));
    expect(RutaService.largo(ruta), closeTo(111 + 48.6, 2));
  });
}
