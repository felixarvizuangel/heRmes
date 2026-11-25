import json
import tempfile
from decimal import Decimal
from io import StringIO
from pathlib import Path

from django.core.management import call_command
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from .models import Andador, Edificio, EdificioCoordenadasGPS, PuntoAcceso

LAT0, LON0 = 29.0, -110.9


@override_settings(ALLOWED_HOSTS=["testserver"])
class CampusApiTests(TestCase):
    def setUp(self):
        self.api = APIClient()
        PuntoAcceso.objects.create(
            nombre="Entrada de autos", tipo="VEHICULAR", latitud=Decimal("29.0087"), longitud=Decimal("-110.9033")
        )
        PuntoAcceso.objects.create(
            nombre="Oculta", tipo="PEATONAL", latitud=Decimal("29.0"), longitud=Decimal("-110.9"), activo=False
        )
        Andador.objects.create(tipo="BANQUETA", puntos=[[29.0, -110.9], [29.001, -110.9]])

    def test_campus_una_sola_peticion(self):
        r = self.api.get("/api/campus/")
        self.assertEqual(r.status_code, 200)
        self.assertEqual([a["nombre"] for a in r.json()["accesos"]], ["Entrada de autos"])
        self.assertEqual(r.json()["accesos"][0]["tipo_display"], "Entrada de autos")
        self.assertEqual(len(r.json()["andadores"]), 1)
        # Barda del campus: polígono cerrado alrededor de la puerta peatonal.
        perimetro = r.json()["perimetro"]
        self.assertGreaterEqual(len(perimetro), 3)
        self.assertTrue(all(len(p) == 2 for p in perimetro))

    def test_anonimo_no_puede_escribir(self):
        r = self.api.post("/api/accesos/", {"nombre": "x", "tipo": "PEATONAL", "latitud": 29, "longitud": -110}, format="json")
        self.assertIn(r.status_code, (401, 403))

    def test_andador_valida_puntos(self):
        from .serializers import AndadorSerializer

        self.assertFalse(AndadorSerializer(data={"tipo": "ANDADOR", "puntos": [[29, -110]]}).is_valid())
        self.assertFalse(AndadorSerializer(data={"tipo": "ANDADOR", "puntos": [[99, -110], [29, -110]]}).is_valid())
        self.assertTrue(AndadorSerializer(data={"tipo": "ANDADOR", "puntos": [[29, -110], [29.001, -110]]}).is_valid())


class ImportarAndadoresTests(TestCase):
    """El grafo nunca debe cruzar el polígono de un edificio."""

    def setUp(self):
        e = Edificio.objects.create(codigo="EDIF-X", nombre="X")
        esquinas = [(0.0001, 0.0001), (0.0001, 0.0004), (0.0004, 0.0004), (0.0004, 0.0001)]
        EdificioCoordenadasGPS.objects.create(
            edificio=e, tipo="ENTRADA_PRINCIPAL", latitud=Decimal("29.000250"), longitud=Decimal("-110.899600")
        )
        for i, (dl, dn) in enumerate(esquinas, 1):
            EdificioCoordenadasGPS.objects.create(
                edificio=e,
                tipo="PERIMETRO",
                latitud=Decimal(str(round(LAT0 + dl, 6))),
                longitud=Decimal(str(round(LON0 + dn, 6))),
                orden=i,
            )

    def _osm(self, ways):
        nodos, elementos, nid = {}, [], 1
        for wid, (tags, pts) in enumerate(ways, 100):
            ids = []
            for p in pts:
                if p not in nodos:
                    nodos[p] = nid
                    elementos.append({"type": "node", "id": nid, "lat": LAT0 + p[0], "lon": LON0 + p[1]})
                    nid += 1
                ids.append(nodos[p])
            elementos.append({"type": "way", "id": wid, "nodes": ids, "tags": tags})
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        json.dump({"elements": elementos}, f)
        f.close()
        return f.name

    def test_descarta_tramo_que_cruza_y_conserva_el_rodeo(self):
        ruta = self._osm(
            [
                # atraviesa el edificio de oeste a este -> se descarta
                ({"highway": "footway"}, [(0.00025, 0.0), (0.00025, 0.0005)]),
                # rodeo por el norte -> se conserva
                ({"highway": "footway", "footway": "sidewalk"}, [(0.00025, 0.0), (0.0005, 0.0), (0.0005, 0.0005), (0.00025, 0.0005)]),
            ]
        )
        out = StringIO()
        call_command("importar_andadores", osm=ruta, stdout=out)
        Path(ruta).unlink()
        self.assertIn("descartados por cruzar edificio: 1", out.getvalue())
        self.assertTrue(Andador.objects.exists())
        self.assertTrue(all(a.tipo == "BANQUETA" for a in Andador.objects.all()))
        for a in Andador.objects.all():
            for lat, lon in a.puntos:
                self.assertFalse(
                    LAT0 + 0.0001 < lat < LAT0 + 0.0004 and LON0 + 0.0001 < lon < LON0 + 0.0004,
                    "ningún punto del grafo dentro del edificio",
                )


class CargarAccesosTests(TestCase):
    def test_aproximadas_quedan_sin_validar_e_idempotente(self):
        call_command("cargar_accesos", stdout=StringIO())
        call_command("cargar_accesos", stdout=StringIO())
        self.assertGreaterEqual(PuntoAcceso.objects.count(), 3)
        self.assertFalse(PuntoAcceso.objects.filter(validado=True).exists())
        self.assertTrue(PuntoAcceso.objects.filter(tipo="VEHICULAR").exists())
        self.assertTrue(PuntoAcceso.objects.filter(tipo="PEATONAL").exists())


@override_settings(ALLOWED_HOSTS=["testserver"])
class ReportesVialesTests(TestCase):
    def test_crear_listar_y_caducar(self):
        from datetime import timedelta

        from django.utils import timezone

        from .models import ReporteVial

        api = APIClient()
        r = api.post("/api/reportes/", {"tipo": "RETEN", "latitud": "29.0700", "longitud": "-110.9600"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["tipo_display"], "Retén")
        self.assertEqual(len(api.get("/api/reportes/").json()), 1)
        # Caducado: ya no aparece.
        ReporteVial.objects.update(expira=timezone.now() - timedelta(minutes=1))
        self.assertEqual(api.get("/api/reportes/").json(), [])

    def test_fuera_de_hermosillo_se_rechaza(self):
        r = APIClient().post("/api/reportes/", {"tipo": "BACHE", "latitud": 19.43, "longitud": -99.13}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_anonimo_no_borra(self):
        from .models import ReporteVial

        rep = ReporteVial.objects.create(tipo="BACHE", latitud=Decimal("29.07"), longitud=Decimal("-110.96"))
        self.assertIn(APIClient().delete(f"/api/reportes/{rep.id}/").status_code, (403, 404, 405))
