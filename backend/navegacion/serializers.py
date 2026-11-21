from rest_framework import serializers
from django.db import transaction  # <-- Importación agregada
from .models import Andador, Edificio, EdificioCoordenadasGPS, PuntoAcceso, ReporteVial

class EdificioCoordenadasGPSSerializer(serializers.ModelSerializer):
    class Meta:
        model = EdificioCoordenadasGPS
        fields = '__all__'


class EdificioSerializer(serializers.ModelSerializer):
    coordenadas = EdificioCoordenadasGPSSerializer(many=True)
    dependencias = serializers.ListField(
        child=serializers.CharField(max_length=120, allow_blank=False),
        required=False,
        default=list,
    )
    palabras_clave = serializers.ListField(
        child=serializers.CharField(max_length=60, allow_blank=False),
        required=False,
        default=list,
    )
    url_video = serializers.URLField(
        max_length=255, allow_null=True, allow_blank=True, required=False
    )
    video_archivo = serializers.FileField(write_only=True, required=False, allow_null=True)
    categoria_display = serializers.CharField(source="get_categoria_display", read_only=True)

    class Meta:
        model = Edificio
        fields = [
            "id",
            "codigo",
            "nombre",
            "descripcion",
            "categoria",
            "categoria_display",
            "dependencias",
            "palabras_clave",
            "hora_apertura",
            "hora_cierre",
            "radio_cobertura_m",
            "foto_fachada",
            "video_archivo",
            "url_video",
            "activo",
            "actualizado",
            "coordenadas",
        ]
        read_only_fields = ["id", "actualizado"]

    def validate_url_video(self, value):
        return value or None

    def validate_dependencias(self, value):
        return list(dict.fromkeys(v.strip() for v in value if v.strip()))

    def validate_palabras_clave(self, value):
        return list(dict.fromkeys(v.strip().lower() for v in value if v.strip()))

    def validate_coordenadas(self, value):
        if not value:
            raise serializers.ValidationError("Registra al menos un punto GPS.")
        principales = sum(1 for c in value if c.get("tipo") == EdificioCoordenadasGPS.Tipo.ENTRADA_PRINCIPAL)
        if principales != 1:
            raise serializers.ValidationError("Debe existir exactamente una ENTRADA_PRINCIPAL.")
        vistos = set()
        for c in value:
            clave = (c["latitud"], c["longitud"])
            if clave in vistos:
                raise serializers.ValidationError(f"Punto duplicado: {clave[0]}, {clave[1]}.")
            vistos.add(clave)
        return value

    def validate(self, attrs):
        apertura = attrs.get("hora_apertura", getattr(self.instance, "hora_apertura", None))
        cierre = attrs.get("hora_cierre", getattr(self.instance, "hora_cierre", None))
        if apertura and cierre and cierre <= apertura:
            raise serializers.ValidationError({"hora_cierre": "Debe ser posterior a la hora de apertura."})
        return attrs

    def to_representation(self, instance):
        data = super().to_representation(instance)
        url = instance.video_url_efectiva if hasattr(instance, 'video_url_efectiva') else None
        request = self.context.get("request")
        if url and getattr(instance, 'video_archivo', None) and request is not None:
            url = request.build_absolute_uri(url)
        data["url_video"] = url
        return data

    @staticmethod
    def _guardar_coordenadas(edificio, coordenadas):
        EdificioCoordenadasGPS.objects.bulk_create(
            EdificioCoordenadasGPS(edificio=edificio, **c) for c in coordenadas
        )

    @transaction.atomic
    def create(self, validated_data):
        coordenadas = validated_data.pop("coordenadas")
        edificio = Edificio.objects.create(**validated_data)
        self._guardar_coordenadas(edificio, coordenadas)
        return edificio

    @transaction.atomic
    def update(self, instance, validated_data):
        coordenadas = validated_data.pop("coordenadas", None)
        for campo, valor in validated_data.items():
            setattr(instance, campo, valor)
        instance.save()
        if coordenadas is not None:
            instance.coordenadas.all().delete()
            self._guardar_coordenadas(instance, coordenadas)
        return instance

class PuntoAccesoSerializer(serializers.ModelSerializer):
    tipo_display = serializers.CharField(source="get_tipo_display", read_only=True)

    class Meta:
        model = PuntoAcceso
        fields = ["id", "nombre", "tipo", "tipo_display", "descripcion", "latitud", "longitud", "validado", "activo", "orden"]
        read_only_fields = ["id"]


class AndadorSerializer(serializers.ModelSerializer):
    class Meta:
        model = Andador
        fields = ["id", "nombre", "tipo", "puntos", "osm_id", "activo"]
        read_only_fields = ["id"]

    def validate_puntos(self, value):
        if not isinstance(value, list) or len(value) < 2:
            raise serializers.ValidationError("Se necesitan al menos 2 puntos [lat, lon].")
        limpios = []
        for p in value:
            try:
                lat, lon = float(p[0]), float(p[1])
            except (TypeError, ValueError, IndexError):
                raise serializers.ValidationError(f"Punto inválido: {p!r}")
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                raise serializers.ValidationError(f"Punto fuera de rango: {p!r}")
            limpios.append([round(lat, 7), round(lon, 7)])
        return limpios



class ReporteVialSerializer(serializers.ModelSerializer):
    tipo_display = serializers.CharField(source="get_tipo_display", read_only=True)

    class Meta:
        model = ReporteVial
        fields = ["id", "tipo", "tipo_display", "descripcion", "latitud", "longitud", "creado", "expira"]
        read_only_fields = ["id", "creado", "expira"]

    def validate(self, attrs):
        # Solo Hermosillo y alrededores: evita reportes basura lejos de la ciudad.
        lat, lon = float(attrs["latitud"]), float(attrs["longitud"])
        if not (28.85 <= lat <= 29.25 and -111.20 <= lon <= -110.75):
            raise serializers.ValidationError("El reporte debe estar en Hermosillo.")
        return attrs
