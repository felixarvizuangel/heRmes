from decimal import Decimal

from django.core.validators import (
    FileExtensionValidator,
    MaxValueValidator,
    MinValueValidator,
)
from django.db import models
from django.db.models import Q


class Edificio(models.Model):
    class Categoria(models.TextChoices):
        ACADEMICO = "ACADEMICO", "Académico"
        ADMINISTRATIVO = "ADMINISTRATIVO", "Administrativo"
        SERVICIOS = "SERVICIOS", "Servicios"

    codigo = models.CharField(max_length=20, unique=True)
    nombre = models.CharField(max_length=120)
    descripcion = models.TextField(blank=True)
    categoria = models.CharField(
        max_length=20, choices=Categoria.choices, default=Categoria.ACADEMICO, db_index=True
    )
    dependencias = models.JSONField(default=list, blank=True)
    palabras_clave = models.JSONField(default=list, blank=True)
    hora_apertura = models.TimeField(null=True, blank=True)
    hora_cierre = models.TimeField(null=True, blank=True)
    radio_cobertura_m = models.PositiveSmallIntegerField(
        default=20, validators=[MinValueValidator(5), MaxValueValidator(100)]
    )
    foto_fachada = models.ImageField(upload_to="fachadas/", null=True, blank=True)
    video_archivo = models.FileField(
        upload_to="videos/",
        null=True,
        blank=True,
        validators=[FileExtensionValidator(allowed_extensions=["mp4"])],
    )
    url_video = models.URLField(max_length=255, null=True, blank=True)
    activo = models.BooleanField(default=True)
    creado = models.DateTimeField(auto_now_add=True)
    actualizado = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "edificios"
        ordering = ["categoria", "nombre"]
        verbose_name = "edificio"
        verbose_name_plural = "edificios"
        constraints = [
            models.CheckConstraint(
                condition=Q(hora_apertura__isnull=True)
                | Q(hora_cierre__isnull=True)
                | Q(hora_cierre__gt=models.F("hora_apertura")),
                name="edificio_horario_valido",
            ),
        ]

    def __str__(self):
        return f"{self.codigo} · {self.nombre}"

    @property
    def video_url_efectiva(self):
        if self.video_archivo:
            return self.video_archivo.url
        return self.url_video or None


class EdificioCoordenadasGPS(models.Model):
    class Tipo(models.TextChoices):
        ENTRADA_PRINCIPAL = "ENTRADA_PRINCIPAL", "Entrada principal"
        ENTRADA_SECUNDARIA = "ENTRADA_SECUNDARIA", "Entrada secundaria"
        PERIMETRO = "PERIMETRO", "Perímetro"

    TIPOS_TRANSITABLES = (Tipo.ENTRADA_PRINCIPAL, Tipo.ENTRADA_SECUNDARIA)

    edificio = models.ForeignKey(
        Edificio, on_delete=models.CASCADE, related_name="coordenadas"
    )
    tipo = models.CharField(max_length=20, choices=Tipo.choices, db_index=True)
    etiqueta = models.CharField(max_length=60, blank=True)
    latitud = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        validators=[MinValueValidator(Decimal("-90")), MaxValueValidator(Decimal("90"))],
    )
    longitud = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        validators=[MinValueValidator(Decimal("-180")), MaxValueValidator(Decimal("180"))],
    )
    orden = models.PositiveSmallIntegerField(default=0)

    class Meta:
        db_table = "edificios_coordenadas_gps"
        ordering = ["edificio", "orden", "id"]
        verbose_name = "coordenada GPS"
        verbose_name_plural = "coordenadas GPS"
        constraints = [
            models.UniqueConstraint(
                fields=["edificio"],
                condition=Q(tipo="ENTRADA_PRINCIPAL"),
                name="unica_entrada_principal_por_edificio",
            ),
            models.CheckConstraint(
                condition=Q(latitud__gte=-90, latitud__lte=90)
                & Q(longitud__gte=-180, longitud__lte=180),
                name="coordenada_en_rango",
            ),
        ]
        indexes = [models.Index(fields=["edificio", "tipo"])]

    def __str__(self):
        return f"{self.edificio.codigo} · {self.Tipo(self.tipo).label} ({self.latitud}, {self.longitud})"

    @property
    def es_transitable(self):
        return self.tipo in self.TIPOS_TRANSITABLES


class PuntoAcceso(models.Model):
    """Puerta del campus (peatonal / entrada de autos) o estacionamiento
    interno (modo carro: se maneja hasta el más cercano al destino)."""

    class Tipo(models.TextChoices):
        PEATONAL = "PEATONAL", "Puerta peatonal"
        VEHICULAR = "VEHICULAR", "Entrada de autos"
        MIXTO = "MIXTO", "Peatonal y autos"
        ESTACIONAMIENTO = "ESTACIONAMIENTO", "Estacionamiento"
        PARADA = "PARADA", "Parada de camión"

    nombre = models.CharField(max_length=80)
    tipo = models.CharField(max_length=16, choices=Tipo.choices, db_index=True)
    descripcion = models.CharField(max_length=200, blank=True)
    latitud = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        validators=[MinValueValidator(Decimal("-90")), MaxValueValidator(Decimal("90"))],
    )
    longitud = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        validators=[MinValueValidator(Decimal("-180")), MaxValueValidator(Decimal("180"))],
    )
    validado = models.BooleanField(
        default=False, help_text="Desmarcado = coordenada aproximada, falta confirmarla en sitio."
    )
    activo = models.BooleanField(default=True)
    orden = models.PositiveSmallIntegerField(default=0)

    class Meta:
        db_table = "puntos_acceso"
        ordering = ["orden", "nombre"]
        verbose_name = "puerta / entrada del campus"
        verbose_name_plural = "puertas y entradas del campus"

    def __str__(self):
        return f"{self.nombre} ({self.Tipo(self.tipo).label})"

    @property
    def es_peatonal(self):
        return self.tipo in (self.Tipo.PEATONAL, self.Tipo.MIXTO)


class Andador(models.Model):
    """Tramo caminable del campus (banqueta, andador, cruce o calle interna).

    Los tramos forman el grafo de andadores con el que la app calcula la ruta
    a pie: dos tramos se conectan donde comparten un punto. Ningún tramo
    cruza el polígono de un edificio (lo valida `importar_andadores`).
    """

    class Tipo(models.TextChoices):
        ANDADOR = "ANDADOR", "Andador"
        BANQUETA = "BANQUETA", "Banqueta"
        CRUCE = "CRUCE", "Cruce peatonal"
        CALLE = "CALLE", "Calle interna"
        ENLACE = "ENLACE", "Enlace (unión entre tramos)"
        EXTERIOR = "EXTERIOR", "Calle o banqueta exterior (fuera de la barda)"

    nombre = models.CharField(max_length=80, blank=True)
    tipo = models.CharField(max_length=10, choices=Tipo.choices, default=Tipo.ANDADOR, db_index=True)
    puntos = models.JSONField(help_text="Lista de [latitud, longitud] en orden.")
    osm_id = models.BigIntegerField(null=True, blank=True, help_text="Way de OpenStreetMap de origen.")
    activo = models.BooleanField(default=True)

    class Meta:
        db_table = "andadores"
        ordering = ["tipo", "id"]
        verbose_name = "andador"
        verbose_name_plural = "andadores"

    def __str__(self):
        return f"{self.get_tipo_display()} #{self.pk} {self.nombre}".strip()

    def clean(self):
        from django.core.exceptions import ValidationError

        p = self.puntos
        if not isinstance(p, list) or len(p) < 2:
            raise ValidationError({"puntos": "Se necesitan al menos 2 puntos."})
        for punto in p:
            if (
                not isinstance(punto, (list, tuple))
                or len(punto) != 2
                or not -90 <= float(punto[0]) <= 90
                or not -180 <= float(punto[1]) <= 180
            ):
                raise ValidationError({"puntos": f"Punto inválido: {punto!r}"})


class ReporteVial(models.Model):
    """Obstáculo reportado por la comunidad para el modo carro (bache, retén,
    calle cerrada…). Caduca solo: después de `expira` ya no se muestra."""

    class Tipo(models.TextChoices):
        BACHE = "BACHE", "Bache / socavón"
        RETEN = "RETEN", "Retén"
        CERRADA = "CERRADA", "Calle cerrada"
        OBRA = "OBRA", "Obra en la calle"
        OTRO = "OTRO", "Otro"

    # Horas que dura cada tipo de reporte si nadie lo renueva.
    DURACION_H = {"BACHE": 72, "RETEN": 3, "CERRADA": 12, "OBRA": 48, "OTRO": 6}

    tipo = models.CharField(max_length=10, choices=Tipo.choices, db_index=True)
    descripcion = models.CharField(max_length=140, blank=True)
    latitud = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        validators=[MinValueValidator(Decimal("-90")), MaxValueValidator(Decimal("90"))],
    )
    longitud = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        validators=[MinValueValidator(Decimal("-180")), MaxValueValidator(Decimal("180"))],
    )
    creado = models.DateTimeField(auto_now_add=True)
    expira = models.DateTimeField(db_index=True)
    activo = models.BooleanField(default=True)

    class Meta:
        db_table = "reportes_viales"
        ordering = ["-creado"]
        verbose_name = "reporte vial"
        verbose_name_plural = "reportes viales"

    def __str__(self):
        return f"{self.get_tipo_display()} ({self.latitud}, {self.longitud})"

    def save(self, *args, **kwargs):
        if not self.expira:
            from datetime import timedelta

            from django.utils import timezone

            self.expira = timezone.now() + timedelta(hours=self.DURACION_H.get(self.tipo, 6))
        super().save(*args, **kwargs)
