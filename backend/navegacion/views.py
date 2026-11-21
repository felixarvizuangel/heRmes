from django.utils import timezone
from rest_framework import mixins, permissions, viewsets
from rest_framework.throttling import AnonRateThrottle
from rest_framework.decorators import api_view, permission_classes
from rest_framework.response import Response

from .models import Andador, Edificio, PuntoAcceso, ReporteVial
from .serializers import AndadorSerializer, EdificioSerializer, PuntoAccesoSerializer, ReporteVialSerializer


class EdificioViewSet(viewsets.ModelViewSet):
    """Lectura pública para la app móvil; alta/edición/baja solo con sesión de administrador."""

    serializer_class = EdificioSerializer
    permission_classes = [permissions.IsAuthenticatedOrReadOnly]

    def get_queryset(self):
        qs = Edificio.objects.prefetch_related("coordenadas")
        if self.request.user.is_staff:
            return qs
        return qs.filter(activo=True)


class PuntoAccesoViewSet(viewsets.ModelViewSet):
    """Puertas peatonales y entradas de autos del campus."""

    serializer_class = PuntoAccesoSerializer
    permission_classes = [permissions.IsAuthenticatedOrReadOnly]

    def get_queryset(self):
        qs = PuntoAcceso.objects.all()
        return qs if self.request.user.is_staff else qs.filter(activo=True)


class AndadorViewSet(viewsets.ModelViewSet):
    """Tramos caminables (grafo de andadores para la ruta a pie)."""

    serializer_class = AndadorSerializer
    permission_classes = [permissions.IsAuthenticatedOrReadOnly]
    pagination_class = None

    def get_queryset(self):
        qs = Andador.objects.all()
        return qs if self.request.user.is_staff else qs.filter(activo=True)


@api_view(["GET"])
@permission_classes([permissions.AllowAny])
def campus(request):
    """Todo lo del campus que no es edificio, en UNA sola petición para la app:
    puertas/entradas y andadores (la app lo guarda y después trabaja local)."""
    return Response(
        {
            "accesos": PuntoAccesoSerializer(PuntoAcceso.objects.filter(activo=True), many=True).data,
            "andadores": AndadorSerializer(Andador.objects.filter(activo=True), many=True).data,
        }
    )



class ReportesThrottle(AnonRateThrottle):
    rate = "20/hour"


class ReporteVialViewSet(mixins.ListModelMixin, mixins.CreateModelMixin, viewsets.GenericViewSet):
    """Reportes de la comunidad para el modo carro: cualquiera los ve y los
    crea (sin cuenta, máx. 20 por hora por IP); se ocultan solos al caducar.
    Borrar/editar solo desde el admin."""

    serializer_class = ReporteVialSerializer
    permission_classes = [permissions.AllowAny]
    pagination_class = None

    def get_queryset(self):
        return ReporteVial.objects.filter(activo=True, expira__gt=timezone.now())

    def get_throttles(self):
        return [ReportesThrottle()] if self.request.method == "POST" else []
