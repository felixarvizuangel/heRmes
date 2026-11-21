"""
Comando: python manage.py importar_andadores [--osm navegacion/datos/osm_campus_uth.json] [--dry-run]

Construye el GRAFO DE ANDADORES del campus (banquetas, andadores, cruces y
calles internas) a partir de un extracto de OpenStreetMap (© OpenStreetMap
contributors, licencia ODbL) y lo guarda en el modelo Andador.

Pasos:
  1. Toma los ways con highway = footway / path / pedestrian / cycleway /
     service / living_street / residential / tertiary / steps.
  2. Parte cada way en segmentos y DESCARTA todo segmento que cruce el
     polígono (perímetro) de un edificio EDIF-* de la BD. Así la ruta nunca
     atraviesa un edificio.
  2b. Marca como EXTERIOR las calles públicas fuera de la barda (De los
     Seris, su ciclovía) y todo tramo al poniente de la línea de la barda
     que pasa por las puertas (PuntoAcceso), p. ej. la rampa de autos antes
     de la caseta. La app no las usa para moverse DENTRO del campus: desde
     afuera entra por la puerta peatonal.
  3. Une callejones sin salida con el tramo más cercano (≤ 12 m) y une los
     pedazos sueltos con el grupo principal (≤ 45 m) mediante tramos ENLACE,
     siempre que el enlace no cruce un edificio.
  4. Reagrupa los segmentos en tramos (cadenas entre cruces) y reemplaza los
     Andador existentes.

El extracto OSM se descarga de Overpass con:
  [out:json];(way["highway"](29.0055,-110.9045,29.0118,-110.8985);
  way["building"](...););out body;>;out skel qt;
"""

import json
import math
from collections import defaultdict
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from navegacion.models import Andador, Edificio, EdificioCoordenadasGPS

HIGHWAYS = {
    "footway": Andador.Tipo.ANDADOR,
    "path": Andador.Tipo.ANDADOR,
    "pedestrian": Andador.Tipo.ANDADOR,
    "steps": Andador.Tipo.ANDADOR,
    "cycleway": Andador.Tipo.ANDADOR,
    "service": Andador.Tipo.CALLE,
    "living_street": Andador.Tipo.CALLE,
    "residential": Andador.Tipo.CALLE,
    "tertiary": Andador.Tipo.CALLE,
}
UNION_CALLEJON_M = 12.0
UNION_COMPONENTE_M = 45.0
TOLERANCIA_EXTREMO_M = 0.5

LAT0, LON0 = 29.0087, -110.9015  # centro aproximado del campus (proyección local)
M_LAT = 111_320.0
M_LON = 111_320.0 * math.cos(math.radians(LAT0))


def es_exterior(highway, tags):
    """Calle pública FUERA de la barda (De los Seris, su ciclovía y el
    bulevar). La app solo la usa para llegar a la puerta peatonal: desde
    afuera se entra al campus por la puerta, no por la entrada de autos."""
    return highway in ("tertiary", "cycleway") or "seris" in tags.get("name", "").lower()


class Barda:
    """Línea de la barda poniente (sobre De los Seris), trazada por las
    puertas del campus (PuntoAcceso): lo que queda al poniente es la calle."""

    def __init__(self, puntos):
        puntos = sorted(puntos)  # por latitud
        self.ok = len(puntos) >= 2 and math.dist(puntos[0], puntos[-1]) > 1e-5
        if self.ok:
            self.a = a_xy(*puntos[0])
            self.b = a_xy(*puntos[-1])

    def afuera(self, p):
        """True si p está al poniente de la barda (lado de la calle)."""
        if not self.ok:
            return False
        (ax, ay), (bx, by) = self.a, self.b
        # Producto cruz: con a al sur y b al norte, positivo = poniente.
        return (bx - ax) * (p[1] - ay) - (by - ay) * (p[0] - ax) > 0


def a_xy(lat, lon):
    return ((lon - LON0) * M_LON, (lat - LAT0) * M_LAT)


def a_latlon(x, y):
    return (round(LAT0 + y / M_LAT, 7), round(LON0 + x / M_LON, 7))


def _cruz(o, a, b):
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def interseccion(p1, p2, q1, q2):
    """Punto de cruce de los segmentos p1p2 y q1q2 (o None)."""
    r = (p2[0] - p1[0], p2[1] - p1[1])
    s = (q2[0] - q1[0], q2[1] - q1[1])
    den = r[0] * s[1] - r[1] * s[0]
    if abs(den) < 1e-12:
        return None
    qp = (q1[0] - p1[0], q1[1] - p1[1])
    t = (qp[0] * s[1] - qp[1] * s[0]) / den
    u = (qp[0] * r[1] - qp[1] * r[0]) / den
    if 0 <= t <= 1 and 0 <= u <= 1:
        return (p1[0] + t * r[0], p1[1] + t * r[1])
    return None


def dentro(p, poli):
    """Punto en polígono (ray casting)."""
    x, y = p
    res = False
    j = len(poli) - 1
    for i in range(len(poli)):
        xi, yi = poli[i]
        xj, yj = poli[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            res = not res
        j = i
    return res


def cruza_poligono(a, b, poli, tol=TOLERANCIA_EXTREMO_M):
    """True si el segmento ab entra al polígono (ignora toques a < tol de los extremos)."""
    largo = math.dist(a, b)
    if largo < 1e-9:
        return dentro(a, poli)
    for k in range(5):  # puntos interiores del segmento
        t = (k + 1) / 6
        if dentro((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])), poli):
            return True
    for i in range(len(poli)):
        c = interseccion(a, b, poli[i], poli[(i + 1) % len(poli)])
        if c and math.dist(c, a) > tol and math.dist(c, b) > tol:
            return True
    return False


def proyectar(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    l2 = dx * dx + dy * dy
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2))
    return t, (a[0] + t * dx, a[1] + t * dy)


class Grafo:
    def __init__(self):
        self.pos = {}  # id -> (x, y)
        self.ady = defaultdict(set)
        self.tipo = {}  # frozenset(a,b) -> (tipo, nombre, osm_id)
        self._sig = -1

    def nodo(self, nid, xy):
        self.pos[nid] = xy
        return nid

    def nuevo(self, xy):
        self._sig -= 1
        return self.nodo(self._sig, xy)

    def arista(self, a, b, info):
        if a == b:
            return
        self.ady[a].add(b)
        self.ady[b].add(a)
        self.tipo[frozenset((a, b))] = info

    def quitar(self, a, b):
        self.ady[a].discard(b)
        self.ady[b].discard(a)
        return self.tipo.pop(frozenset((a, b)), None)

    def aristas(self):
        return [tuple(k) for k in self.tipo]

    def componentes(self):
        vistos, comps = set(), []
        for n in list(self.ady):
            if n in vistos or not self.ady[n]:
                continue
            pila, comp = [n], set()
            while pila:
                v = pila.pop()
                if v in comp:
                    continue
                comp.add(v)
                pila.extend(self.ady[v] - comp)
            vistos |= comp
            comps.append(comp)
        return sorted(comps, key=len, reverse=True)


class Command(BaseCommand):
    help = "Importa el grafo de andadores del campus desde un extracto de OpenStreetMap."

    def add_arguments(self, parser):
        parser.add_argument("--osm", default=str(Path(__file__).resolve().parents[2] / "datos" / "osm_campus_uth.json"))
        parser.add_argument("--dry-run", action="store_true")

    def handle(self, *args, **opts):
        ruta = Path(opts["osm"])
        if not ruta.exists():
            raise CommandError(f"No existe {ruta}")
        osm = json.loads(ruta.read_text(encoding="utf-8"))
        nodos = {e["id"]: e for e in osm["elements"] if e["type"] == "node"}

        from navegacion.models import PuntoAcceso

        barda = Barda([(float(a.latitud), float(a.longitud)) for a in PuntoAcceso.objects.filter(activo=True, tipo__in=["PEATONAL", "VEHICULAR", "MIXTO"])])
        self.stdout.write(f"Barda poniente por las puertas: {'sí' if barda.ok else 'no (sin puertas)'}")
        poligonos = self._poligonos_edificios()
        self.stdout.write(f"Edificios con polígono (obstáculos): {len(poligonos)}")

        g = Grafo()
        descartados = 0
        for w in osm["elements"]:
            if w["type"] != "way":
                continue
            tags = w.get("tags", {})
            hw = tags.get("highway")
            if hw not in HIGHWAYS or tags.get("access") in ("private", "no") and hw != "cycleway":
                continue
            tipo = HIGHWAYS[hw]
            if es_exterior(hw, tags):
                tipo = Andador.Tipo.EXTERIOR
            elif tags.get("footway") == "sidewalk":
                tipo = Andador.Tipo.BANQUETA
            elif tags.get("footway") == "crossing":
                tipo = Andador.Tipo.CRUCE
            info = (tipo, tags.get("name", ""), w["id"])
            ids = [n for n in w["nodes"] if n in nodos]
            for n in ids:
                g.nodo(n, a_xy(nodos[n]["lat"], nodos[n]["lon"]))
            for a, b in zip(ids, ids[1:]):
                if any(cruza_poligono(g.pos[a], g.pos[b], p) for p in poligonos.values()):
                    descartados += 1
                    continue
                pa, pb = g.pos[a], g.pos[b]
                medio = ((pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2)
                if barda.afuera(medio) and info[0] != Andador.Tipo.EXTERIOR:
                    g.arista(a, b, (Andador.Tipo.EXTERIOR, info[1], info[2]))
                else:
                    g.arista(a, b, info)
        self.stdout.write(f"Segmentos OSM: {len(g.tipo)} · descartados por cruzar edificio: {descartados}")

        enlace = (Andador.Tipo.ENLACE, "", None)
        uniones = self._unir_callejones(g, poligonos, enlace)
        puentes = self._unir_componentes(g, poligonos, enlace)
        comps = g.componentes()
        self.stdout.write(
            f"Enlaces: {uniones} callejones + {puentes} pedazos sueltos · componentes: "
            f"{[len(c) for c in comps]}"
        )

        tramos = self._tramos(g)
        self.stdout.write(f"Tramos a guardar: {len(tramos)}")
        if opts["dry_run"]:
            self.stdout.write(json.dumps({"tramos": tramos[:3]}, ensure_ascii=False)[:600])
            return
        with transaction.atomic():
            Andador.objects.all().delete()
            Andador.objects.bulk_create(
                Andador(tipo=t["tipo"], nombre=t["nombre"], osm_id=t["osm_id"], puntos=t["puntos"]) for t in tramos
            )
        self.stdout.write(self.style.SUCCESS(f"Andador: {len(tramos)} tramos guardados."))

    # ───────────────────────── pasos ─────────────────────────

    @staticmethod
    def _poligonos_edificios():
        polis = {}
        for e in Edificio.objects.filter(codigo__startswith="EDIF-").prefetch_related("coordenadas"):
            per = [
                a_xy(float(c.latitud), float(c.longitud))
                for c in e.coordenadas.all()
                if c.tipo == EdificioCoordenadasGPS.Tipo.PERIMETRO
            ]
            if len(per) >= 3:
                polis[e.codigo] = per
        return polis

    @staticmethod
    def _libre(a, b, poligonos):
        return not any(cruza_poligono(a, b, p) for p in poligonos.values())

    def _mejor_proyeccion(self, g, p, excluir, maximo, poligonos):
        """Punto más cercano a p sobre una arista que no toque `excluir`."""
        mejor = None
        for a, b in g.aristas():
            if a in excluir or b in excluir:
                continue
            t, q = proyectar(p, g.pos[a], g.pos[b])
            d = math.dist(p, q)
            if d <= maximo and (mejor is None or d < mejor[0]) and self._libre(p, q, poligonos):
                mejor = (d, a, b, t, q)
        return mejor

    def _conectar(self, g, n, proy, enlace):
        d, a, b, t, q = proy
        if t <= 0.02 or math.dist(q, g.pos[a]) < 1.0:
            destino = a
        elif t >= 0.98 or math.dist(q, g.pos[b]) < 1.0:
            destino = b
        else:  # parte la arista a-b en q
            info = g.quitar(a, b)
            destino = g.nuevo(q)
            g.arista(a, destino, info)
            g.arista(destino, b, info)
        g.arista(n, destino, enlace)

    def _unir_callejones(self, g, poligonos, enlace):
        uniones = 0
        for n in [n for n, v in g.ady.items() if len(v) == 1]:
            vecinos = set(g.ady[n]) | {n}
            # no unir con el propio tramo: excluye 2 saltos hacia atrás
            for v in list(g.ady[n]):
                vecinos |= g.ady[v]
            proy = self._mejor_proyeccion(g, g.pos[n], vecinos, UNION_CALLEJON_M, poligonos)
            if proy:
                self._conectar(g, n, proy, enlace)
                uniones += 1
        return uniones

    def _unir_componentes(self, g, poligonos, enlace):
        puentes = 0
        for _ in range(50):
            comps = g.componentes()
            if len(comps) <= 1:
                break
            principal = comps[0]
            unido = False
            for comp in comps[1:]:
                mejor = None
                for n in comp:
                    proy = self._mejor_proyeccion(g, g.pos[n], comp, UNION_COMPONENTE_M, poligonos)
                    if proy and proy[1] in principal and (mejor is None or proy[0] < mejor[1][0]):
                        mejor = (n, proy)
                if mejor:
                    self._conectar(g, mejor[0], mejor[1], enlace)
                    puentes += 1
                    unido = True
                    break
            if not unido:
                break
        # descarta pedazos que no se pudieron unir (no sirven para rutear)
        comps = g.componentes()
        for comp in comps[1:]:
            for n in comp:
                for v in list(g.ady[n]):
                    g.quitar(n, v)
        return puentes

    @staticmethod
    def _tramos(g):
        """Cadenas de aristas del mismo tipo entre cruces (nodos de grado ≠ 2)."""
        usadas = set()
        tramos = []

        def seguir(inicio, sig):
            cadena = [inicio, sig]
            info = g.tipo[frozenset((inicio, sig))]
            usadas.add(frozenset((inicio, sig)))
            prev, act = inicio, sig
            while len(g.ady[act]) == 2:
                nxt = next(iter(g.ady[act] - {prev}))
                k = frozenset((act, nxt))
                if k in usadas or g.tipo.get(k) != info:
                    break
                usadas.add(k)
                cadena.append(nxt)
                prev, act = act, nxt
            return info, cadena

        orden = sorted(g.ady, key=lambda n: len(g.ady[n]) == 2)  # empieza por cruces
        for n in orden:
            for v in sorted(g.ady[n]):
                if frozenset((n, v)) in usadas:
                    continue
                (tipo, nombre, osm_id), cadena = seguir(n, v)
                tramos.append(
                    {
                        "tipo": tipo,
                        "nombre": nombre,
                        "osm_id": osm_id,
                        "puntos": [list(a_latlon(*g.pos[x])) for x in cadena],
                    }
                )
        return tramos
