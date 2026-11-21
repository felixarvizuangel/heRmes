from django.urls import include, path
from rest_framework.routers import DefaultRouter

from .views import AndadorViewSet, EdificioViewSet, PuntoAccesoViewSet, ReporteVialViewSet, campus

router = DefaultRouter()
router.register(r'edificios', EdificioViewSet, basename='edificio')
router.register(r'accesos', PuntoAccesoViewSet, basename='acceso')
router.register(r'andadores', AndadorViewSet, basename='andador')
router.register(r'reportes', ReporteVialViewSet, basename='reporte')

urlpatterns = [
    path('campus/', campus, name='campus'),
    path('', include(router.urls)),
]
