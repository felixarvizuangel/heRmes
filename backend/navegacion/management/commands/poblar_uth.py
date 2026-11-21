"""
Comando: python manage.py poblar_uth [--json edificios_uth.json] [--limpiar] [--app navegacion] [--dry-run]
         (sin --json carga la lista de EJEMPLO de abajo, con coordenadas inventadas)

--json: archivo exportado desde diseno/mapa_uth.html (trazado sobre vista satelital) con
        coordenadas REALES: [{codigo, nombre, categoria, radio_cobertura_m, entrada:[lat,lon],
        perimetro:[[lat,lon],...]}]
--limpiar: Edificio.objects.all().delete() antes de insertar (borra también sus coordenadas).

Puebla Edificio + EdificioCoordenadasGPS (ENTRADA_PRINCIPAL + PERIMETRO) del campus UTH.
Idempotente: Edificio por `codigo` (update_or_create); coordenadas por (edificio, tipo, orden).

COORDENADAS APROXIMADAS: cada edificio se define como desplazamiento en metros (este/norte)
desde ORIGEN_CAMPUS. Ajusta ORIGEN_CAMPUS (o pasa --lat/--lon) con Google Maps y afina
los offsets de cada edificio midiendo sobre la vista satelital.
"""

import json
import math
from datetime import datetime, time
from decimal import ROUND_HALF_UP, Decimal

from django.apps import apps
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

APP_LABEL_DEFAULT = "navegacion"  # cambia a "campus" si tu app se llama así

# Punto de referencia (acceso principal del campus). APROXIMADO: afínalo en Google Maps.
ORIGEN_CAMPUS = (29.018900, -110.922700)

METROS_POR_GRADO_LAT = 111_320.0

# offset_e/offset_n: centro del edificio en metros desde ORIGEN_CAMPUS (+este, +norte).
# ancho/largo: dimensiones del rectángulo perimetral en metros (eje E-O / eje N-S).
# entrada: offset en metros de la entrada principal relativo al CENTRO del edificio.
EDIFICIOS = [
    {
        "codigo": "EDIF-A",
        "nombre": "Edificio A (Docencia)",
        "descripcion": "Aulas de docencia y coordinaciones de carrera.",
        "categoria": "ACADEMICO",
        "dependencias": ["Aulas A1-A12", "Coordinación TI", "Sala de maestros"],
        "palabras_clave": ["edificio a", "aulas", "docencia", "salones", "ti"],
        "hora_apertura": time(7, 0),
        "hora_cierre": time(21, 0),
        "radio_cobertura_m": 25,
        "offset_e": -60, "offset_n": 80, "ancho": 50, "largo": 18,
        "entrada": (0, -9),
    },
    {
        "codigo": "EDIF-B",
        "nombre": "Edificio B (Docencia)",
        "descripcion": "Aulas, laboratorios de cómputo y coordinaciones.",
        "categoria": "ACADEMICO",
        "dependencias": ["Aulas B1-B12", "Laboratorio de Cómputo", "Coordinación Mecatrónica"],
        "palabras_clave": ["edificio b", "aulas", "laboratorio", "computo", "mecatronica"],
        "hora_apertura": time(7, 0),
        "hora_cierre": time(21, 0),
        "radio_cobertura_m": 25,
        "offset_e": 10, "offset_n": 80, "ancho": 50, "largo": 18,
        "entrada": (0, -9),
    },
    {
        "codigo": "EDIF-C",
        "nombre": "Edificio C (Laboratorios Pesados)",
        "descripcion": "Talleres y laboratorios de manufactura, mantenimiento y energías.",
        "categoria": "ACADEMICO",
        "dependencias": ["Taller de Manufactura", "Laboratorio de Mantenimiento", "Laboratorio de Energías"],
        "palabras_clave": ["edificio c", "taller", "laboratorio pesado", "manufactura", "mantenimiento"],
        "hora_apertura": time(7, 0),
        "hora_cierre": time(20, 0),
        "radio_cobertura_m": 30,
        "offset_e": 80, "offset_n": 130, "ancho": 60, "largo": 25,
        "entrada": (-30, 0),
    },
    {
        "codigo": "RECT",
        "nombre": "Rectoría",
        "descripcion": "Rectoría, servicios escolares y caja.",
        "categoria": "ADMINISTRATIVO",
        "dependencias": ["Rectoría", "Servicios Escolares", "Caja", "Recursos Humanos"],
        "palabras_clave": ["rectoria", "servicios escolares", "caja", "pagos", "inscripcion", "constancia"],
        "hora_apertura": time(8, 0),
        "hora_cierre": time(16, 0),
        "radio_cobertura_m": 20,
        "offset_e": 0, "offset_n": 30, "ancho": 40, "largo": 16,
        "entrada": (0, -8),
    },
    {
        "codigo": "VINC",
        "nombre": "Vinculación",
        "descripcion": "Vinculación, estadías, bolsa de trabajo y educación continua.",
        "categoria": "ADMINISTRATIVO",
        "dependencias": ["Estadías", "Bolsa de Trabajo", "Educación Continua", "Servicio Social"],
        "palabras_clave": ["vinculacion", "estadias", "practicas", "bolsa de trabajo", "servicio social"],
        "hora_apertura": time(8, 0),
        "hora_cierre": time(16, 0),
        "radio_cobertura_m": 20,
        "offset_e": 55, "offset_n": 30, "ancho": 30, "largo": 14,
        "entrada": (0, -7),
    },
    {
        "codigo": "BIBL",
        "nombre": "Biblioteca",
        "descripcion": "Centro de información, acervo y salas de estudio.",
        "categoria": "SERVICIOS",
        "dependencias": ["Acervo", "Sala de estudio", "Préstamo de equipo"],
        "palabras_clave": ["biblioteca", "libros", "estudio", "prestamo", "cubiculos"],
        "hora_apertura": time(7, 30),
        "hora_cierre": time(20, 0),
        "radio_cobertura_m": 20,
        "offset_e": -55, "offset_n": 30, "ancho": 30, "largo": 20,
        "entrada": (0, -10),
    },
    {
        "codigo": "CAFE",
        "nombre": "Cafetería",
        "descripcion": "Cafetería y área de comedor.",
        "categoria": "SERVICIOS",
        "dependencias": ["Cafetería", "Comedor"],
        "palabras_clave": ["cafeteria", "comida", "comedor", "desayuno", "cafe"],
        "hora_apertura": time(7, 0),
        "hora_cierre": time(19, 0),
        "radio_cobertura_m": 15,
        "offset_e": -20, "offset_n": 115, "ancho": 22, "largo": 14,
        "entrada": (0, -7),
    },
    {
        "codigo": "MED",
        "nombre": "Servicio Médico y Psicopedagogía",
        "descripcion": "Consultorio médico y atención psicopedagógica.",
        "categoria": "SERVICIOS",
        "dependencias": ["Consultorio médico", "Psicopedagogía", "Tutorías"],
        "palabras_clave": ["medico", "enfermeria", "psicologo", "psicopedagogia", "salud"],
        "hora_apertura": time(8, 0),
        "hora_cierre": time(18, 0),
        "radio_cobertura_m": 12,
        "offset_e": 30, "offset_n": 115, "ancho": 16, "largo": 10,
        "entrada": (0, -5),
    },
    {
        "codigo": "DEP",
        "nombre": "Canchas y Gimnasio",
        "descripcion": "Áreas deportivas: canchas de usos múltiples y gimnasio.",
        "categoria": "SERVICIOS",
        "dependencias": ["Cancha de fútbol", "Canchas de usos múltiples", "Gimnasio"],
        "palabras_clave": ["canchas", "gimnasio", "deportes", "futbol", "basquetbol"],
        "hora_apertura": time(7, 0),
        "hora_cierre": time(21, 0),
        "radio_cobertura_m": 50,
        "offset_e": -120, "offset_n": 170, "ancho": 90, "largo": 60,
        "entrada": (45, 0),
    },
]

SEIS_DEC = Decimal("0.000001")


def _a_gps(lat0, lon0, este_m, norte_m):
    """Proyección local equirectangular (error < 1 cm a escala de campus)."""
    lat = lat0 + norte_m / METROS_POR_GRADO_LAT
    lon = lon0 + este_m / (METROS_POR_GRADO_LAT * math.cos(math.radians(lat0)))
    return (
        Decimal(str(lat)).quantize(SEIS_DEC, rounding=ROUND_HALF_UP),
        Decimal(str(lon)).quantize(SEIS_DEC, rounding=ROUND_HALF_UP),
    )


def _puntos(lat0, lon0, d):
    ce, cn = d["offset_e"], d["offset_n"]
    me, mn = d["ancho"] / 2, d["largo"] / 2
    ee, en = d["entrada"]
    puntos = [("ENTRADA_PRINCIPAL", "Entrada principal", 0, ce + ee, cn + en)]
    esquinas = [("Esquina NO", -me, mn), ("Esquina NE", me, mn), ("Esquina SE", me, -mn), ("Esquina SO", -me, -mn)]
    for i, (etq, de, dn) in enumerate(esquinas, start=1):
        puntos.append(("PERIMETRO", etq, i, ce + de, cn + dn))
    return [(tipo, etq, orden, *_a_gps(lat0, lon0, e, n)) for tipo, etq, orden, e, n in puntos]


def _hora(valor):
    if not valor:
        return None
    return datetime.strptime(valor[:5], "%H:%M").time()


def _decimal(valor, nombre):
    try:
        d = Decimal(str(valor)).quantize(SEIS_DEC, rounding=ROUND_HALF_UP)
    except Exception as exc:
        raise CommandError(f"Coordenada inválida en {nombre}: {valor!r}") from exc
    return d


def _desde_json(ruta):
    try:
        with open(ruta, encoding="utf-8") as fh:
            crudo = json.load(fh)
    except (OSError, ValueError) as exc:
        raise CommandError(f"No pude leer {ruta}: {exc}") from exc
    if not isinstance(crudo, list) or not crudo:
        raise CommandError("El JSON debe ser una lista no vacía de edificios.")

    categorias = {"ACADEMICO", "ADMINISTRATIVO", "SERVICIOS"}
    lista = []
    for n, b in enumerate(crudo, start=1):
        cod = str(b.get("codigo", "")).strip()
        if not cod or not b.get("nombre"):
            raise CommandError(f"Edificio #{n}: faltan codigo y/o nombre.")
        per = b.get("perimetro") or []
        if len(per) < 3 or not b.get("entrada"):
            raise CommandError(f"{cod}: requiere entrada y al menos 3 puntos de perímetro.")
        puntos = [("ENTRADA_PRINCIPAL", "Entrada principal", 0,
                   _decimal(b["entrada"][0], cod), _decimal(b["entrada"][1], cod))]
        for i, (la, lo) in enumerate(per, start=1):
            puntos.append(("PERIMETRO", f"Esquina {i}", i, _decimal(la, cod), _decimal(lo, cod)))
        for _, _, _, la, lo in puntos:
            if not (-90 <= la <= 90 and -180 <= lo <= 180):
                raise CommandError(f"{cod}: coordenada fuera de rango.")
        cat = b.get("categoria", "ACADEMICO")
        lista.append({
            "codigo": cod,
            "nombre": b["nombre"],
            "descripcion": b.get("descripcion", ""),
            "categoria": cat if cat in categorias else "ACADEMICO",
            "dependencias": b.get("dependencias", []),
            "palabras_clave": b.get("palabras_clave", []),
            "hora_apertura": _hora(b.get("hora_apertura")),
            "hora_cierre": _hora(b.get("hora_cierre")),
            "radio_cobertura_m": int(b.get("radio_cobertura_m", 20)),
            "puntos": puntos,
        })
    return lista


class Command(BaseCommand):
    help = "Pobla edificios del campus UTH (ENTRADA_PRINCIPAL + PERIMETRO + radio). Idempotente."

    def add_arguments(self, parser):
        parser.add_argument("--app", default=APP_LABEL_DEFAULT, help="App label que contiene los modelos.")
        parser.add_argument("--json", dest="ruta_json", help="Archivo JSON con coordenadas reales (mapa_uth.html).")
        parser.add_argument("--limpiar", action="store_true", help="Borra TODOS los edificios antes de insertar.")
        parser.add_argument("--lat", type=float, default=ORIGEN_CAMPUS[0], help="Origen de la lista de ejemplo.")
        parser.add_argument("--lon", type=float, default=ORIGEN_CAMPUS[1], help="Origen de la lista de ejemplo.")
        parser.add_argument("--purgar", action="store_true", help="Desactiva edificios no listados.")
        parser.add_argument("--dry-run", action="store_true", help="Muestra lo que haría sin escribir en la BD.")

    def handle(self, *args, **opts):
        try:
            Edificio = apps.get_model(opts["app"], "Edificio")
            Coordenada = apps.get_model(opts["app"], "EdificioCoordenadasGPS")
        except LookupError as exc:
            raise CommandError(f"No encuentro los modelos en la app '{opts['app']}'. Usa --app <label>.") from exc

        if opts["ruta_json"]:
            lista = _desde_json(opts["ruta_json"])
            self.stdout.write(self.style.SUCCESS(f"Coordenadas desde {opts['ruta_json']} ({len(lista)} edificios)."))
        else:
            lat0, lon0 = opts["lat"], opts["lon"]
            if not (-90 <= lat0 <= 90 and -180 <= lon0 <= 180):
                raise CommandError("Origen fuera de rango.")
            lista = [{**d, "puntos": _puntos(lat0, lon0, d)} for d in EDIFICIOS]
            self.stdout.write(self.style.WARNING(
                "Usando lista de EJEMPLO con coordenadas inventadas. Para coordenadas reales usa --json."
            ))

        for d in lista:
            if not 5 <= d["radio_cobertura_m"] <= 100:
                raise CommandError(f"{d['codigo']}: radio_cobertura_m debe estar entre 5 y 100.")
            ha, hc = d.get("hora_apertura"), d.get("hora_cierre")
            if ha and hc and hc <= ha:
                raise CommandError(f"{d['codigo']}: hora_cierre debe ser mayor a hora_apertura.")

        creados = actualizados = 0
        with transaction.atomic():
            if opts["limpiar"]:
                n, _ = Edificio.objects.all().delete()
                self.stdout.write(self.style.WARNING(f"Limpieza previa: {n} registros eliminados."))

            for d in lista:
                defaults = {
                    k: d[k]
                    for k in ("nombre", "descripcion", "categoria", "dependencias", "palabras_clave",
                              "hora_apertura", "hora_cierre", "radio_cobertura_m")
                }
                defaults["activo"] = True
                edificio, creado = Edificio.objects.update_or_create(codigo=d["codigo"], defaults=defaults)
                creados += creado
                actualizados += not creado

                vigentes = []
                for tipo, etiqueta, orden, lat, lon in d["puntos"]:
                    coord, _ = Coordenada.objects.update_or_create(
                        edificio=edificio, tipo=tipo, orden=orden,
                        defaults={"etiqueta": etiqueta, "latitud": lat, "longitud": lon},
                    )
                    vigentes.append(coord.pk)
                Coordenada.objects.filter(edificio=edificio).exclude(pk__in=vigentes).delete()

                ent = d["puntos"][0]
                self.stdout.write(
                    f"{'+' if creado else '~'} {d['codigo']:<8} {d['nombre'][:34]:<34} "
                    f"r={d['radio_cobertura_m']:>3} m  entrada=({ent[3]}, {ent[4]})  perímetro={len(d['puntos']) - 1} pts"
                )

            if opts["purgar"] and not opts["limpiar"]:
                n = Edificio.objects.exclude(codigo__in=[d["codigo"] for d in lista]).update(activo=False)
                self.stdout.write(self.style.WARNING(f"Desactivados {n} edificios no listados."))

            if opts["dry_run"]:
                transaction.set_rollback(True)
                self.stdout.write(self.style.NOTICE("DRY-RUN: cambios revertidos."))

        self.stdout.write(self.style.SUCCESS(
            f"OK: {creados} creados, {actualizados} actualizados, "
            f"{Coordenada.objects.count()} coordenadas totales."
        ))
