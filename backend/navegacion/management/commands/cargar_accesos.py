"""
Comando: python manage.py cargar_accesos [--json accesos.json] [--limpiar]

Carga las puertas peatonales y entradas de autos del campus (modelo PuntoAcceso).
Idempotente: actualiza por `nombre`.

Sin --json carga las APROXIMADAS (validado=False), sacadas de OpenStreetMap
donde las calles y andadores del campus se unen con la calle De los Seris;
OSM no tiene marcados los portones. Confírmalas en sitio o con Google Maps y
pásalas en un JSON:

  [{"nombre": "Entrada de autos principal", "tipo": "VEHICULAR",
    "latitud": 29.008737, "longitud": -110.90329, "validado": true,
    "descripcion": "..."}]

tipo: PEATONAL | VEHICULAR | MIXTO
"""

import json
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from navegacion.models import PuntoAcceso

APROXIMADAS = [
    {
        "nombre": "Entrada de autos principal (calle Del Ingeniero)",
        "tipo": "VEHICULAR",
        "latitud": 29.008737,
        "longitud": -110.903290,
        "descripcion": "Acceso desde la calle De los Seris. Ubicación aproximada (OSM).",
    },
    {
        "nombre": "Puerta peatonal poniente",
        "tipo": "PEATONAL",
        "latitud": 29.008644,
        "longitud": -110.902994,
        "descripcion": "Inicio de la banqueta junto a la entrada de autos. Ubicación aproximada (OSM).",
    },
    {
        "nombre": "Entrada de autos norte (De los Seris)",
        "tipo": "VEHICULAR",
        "latitud": 29.011177,
        "longitud": -110.904066,
        "descripcion": "Calle interna norte que sale a De los Seris. Ubicación aproximada (OSM).",
    },
]


def _dec(v):
    return Decimal(str(v)).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)


class Command(BaseCommand):
    help = "Carga puertas peatonales y entradas de autos del campus."

    def add_arguments(self, parser):
        parser.add_argument("--json", help="Archivo con las puertas reales (validadas).")
        parser.add_argument("--limpiar", action="store_true", help="Borra las puertas existentes antes.")

    @transaction.atomic
    def handle(self, *args, **opts):
        if opts["json"]:
            ruta = Path(opts["json"])
            if not ruta.exists():
                raise CommandError(f"No existe {ruta}")
            datos = json.loads(ruta.read_text(encoding="utf-8"))
            por_defecto_validado = True
        else:
            datos = APROXIMADAS
            por_defecto_validado = False

        if opts["limpiar"]:
            PuntoAcceso.objects.all().delete()

        tipos = {t for t, _ in PuntoAcceso.Tipo.choices}
        for i, d in enumerate(datos):
            tipo = str(d.get("tipo", "")).upper()
            if tipo not in tipos:
                raise CommandError(f"Tipo inválido en {d.get('nombre')!r}: {tipo!r} (usa {sorted(tipos)})")
            obj, creado = PuntoAcceso.objects.update_or_create(
                nombre=d["nombre"],
                defaults={
                    "tipo": tipo,
                    "latitud": _dec(d["latitud"]),
                    "longitud": _dec(d["longitud"]),
                    "descripcion": d.get("descripcion", ""),
                    "validado": d.get("validado", por_defecto_validado),
                    "activo": d.get("activo", True),
                    "orden": d.get("orden", i),
                },
            )
            self.stdout.write(f"{'+' if creado else '~'} {obj}")
        self.stdout.write(self.style.SUCCESS(f"Puertas/entradas: {PuntoAcceso.objects.count()} en BD."))
