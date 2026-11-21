from django import forms
from django.contrib import admin
from django.core.exceptions import ValidationError
from django.forms.models import BaseInlineFormSet
from django.utils.html import format_html

from .models import Andador, Edificio, EdificioCoordenadasGPS, PuntoAcceso, ReporteVial

admin.site.site_header = "heRmes · Panel administrativo UTH"
admin.site.site_title = "heRmes"
admin.site.index_title = "Gestión de edificios del campus"


class ListaPorLineaField(forms.CharField):
    """Muestra una lista JSON como texto (un elemento por línea) y la guarda como lista."""

    widget = forms.Textarea(attrs={"rows": 4, "cols": 60})

    def prepare_value(self, value):
        if isinstance(value, list):
            return "\n".join(value)
        return value

    def to_python(self, value):
        if not value:
            return []
        if isinstance(value, list):
            return value
        vistos = []
        for linea in str(value).replace(",", "\n").splitlines():
            linea = linea.strip()
            if linea and linea not in vistos:
                vistos.append(linea)
        return vistos


class EdificioForm(forms.ModelForm):
    dependencias = ListaPorLineaField(
        required=False, help_text="Una dependencia por línea (ej. Servicios Escolares)."
    )
    palabras_clave = ListaPorLineaField(
        required=False,
        help_text="Una palabra clave por línea: servicios, trámites, carreras u oficinas.",
    )

    class Meta:
        model = Edificio
        fields = "__all__"

    def clean_palabras_clave(self):
        return [p.lower() for p in self.cleaned_data["palabras_clave"]]

    def clean(self):
        datos = super().clean()
        apertura, cierre = datos.get("hora_apertura"), datos.get("hora_cierre")
        if apertura and cierre and cierre <= apertura:
            self.add_error("hora_cierre", "Debe ser posterior a la hora de apertura.")
        if datos.get("video_archivo") and datos.get("url_video"):
            self.add_error(
                "url_video", "Usa archivo MP4 o enlace, no ambos (se prioriza el archivo)."
            )
        return datos


class CoordenadasFormSet(BaseInlineFormSet):
    """Exige exactamente una ENTRADA_PRINCIPAL y ningún punto repetido."""

    def clean(self):
        super().clean()
        principales = 0
        vistos = set()
        total = 0
        for form in self.forms:
            if not hasattr(form, "cleaned_data") or not form.cleaned_data:
                continue
            if form.cleaned_data.get("DELETE"):
                continue
            total += 1
            if form.cleaned_data.get("tipo") == EdificioCoordenadasGPS.Tipo.ENTRADA_PRINCIPAL:
                principales += 1
            clave = (form.cleaned_data.get("latitud"), form.cleaned_data.get("longitud"))
            if clave in vistos:
                raise ValidationError(f"Punto GPS duplicado: {clave[0]}, {clave[1]}.")
            vistos.add(clave)
        if total == 0:
            raise ValidationError("Registra al menos un punto GPS.")
        if principales != 1:
            raise ValidationError("Debe existir exactamente una ENTRADA_PRINCIPAL.")


class CoordenadaInline(admin.TabularInline):
    model = EdificioCoordenadasGPS
    formset = CoordenadasFormSet
    extra = 1
    fields = ("tipo", "etiqueta", "latitud", "longitud", "orden", "ver_en_mapa")
    readonly_fields = ("ver_en_mapa",)
    ordering = ("orden", "id")

    @admin.display(description="Mapa")
    def ver_en_mapa(self, obj):
        if not obj or obj.latitud is None or obj.longitud is None:
            return "—"
        return format_html(
            '<a href="https://www.openstreetmap.org/?mlat={0}&mlon={1}#map=19/{0}/{1}" '
            'target="_blank">Ver</a>',
            obj.latitud,
            obj.longitud,
        )


@admin.register(Edificio)
class EdificioAdmin(admin.ModelAdmin):
    form = EdificioForm
    inlines = [CoordenadaInline]
    list_display = (
        "codigo",
        "nombre",
        "categoria",
        "radio_cobertura_m",
        "num_puntos",
        "tiene_foto",
        "tiene_video",
        "activo",
    )
    list_display_links = ("codigo", "nombre")
    list_editable = ("radio_cobertura_m", "activo")
    list_filter = ("categoria", "activo")
    search_fields = ("codigo", "nombre", "descripcion", "dependencias", "palabras_clave")
    ordering = ("categoria", "codigo")
    readonly_fields = ("vista_foto", "creado", "actualizado")
    fieldsets = (
        ("Datos generales", {"fields": ("codigo", "nombre", "categoria", "descripcion", "activo")}),
        ("Dependencias y búsqueda", {"fields": ("dependencias", "palabras_clave")}),
        ("Horario", {"fields": (("hora_apertura", "hora_cierre"),)}),
        ("Geocerca", {"fields": ("radio_cobertura_m",)}),
        ("Multimedia", {"fields": ("foto_fachada", "vista_foto", "video_archivo", "url_video")}),
        ("Registro", {"fields": ("creado", "actualizado"), "classes": ("collapse",)}),
    )

    def get_queryset(self, request):
        return super().get_queryset(request).prefetch_related("coordenadas")

    @admin.display(description="Puntos GPS")
    def num_puntos(self, obj):
        return len(obj.coordenadas.all())

    @admin.display(boolean=True, description="Foto")
    def tiene_foto(self, obj):
        return bool(obj.foto_fachada)

    @admin.display(boolean=True, description="Video")
    def tiene_video(self, obj):
        return bool(obj.video_url_efectiva)

    @admin.display(description="Vista previa")
    def vista_foto(self, obj):
        if not obj.foto_fachada:
            return "Sin foto"
        return format_html(
            '<img src="{}" style="max-height:180px;border-radius:8px">', obj.foto_fachada.url
        )


@admin.register(EdificioCoordenadasGPS)
class EdificioCoordenadasGPSAdmin(admin.ModelAdmin):
    list_display = ("edificio", "tipo", "etiqueta", "latitud", "longitud", "orden")
    list_filter = ("tipo", "edificio__categoria")
    search_fields = ("edificio__codigo", "edificio__nombre", "etiqueta")
    list_select_related = ("edificio",)


@admin.register(PuntoAcceso)
class PuntoAccesoAdmin(admin.ModelAdmin):
    list_display = ("nombre", "tipo", "latitud", "longitud", "validado", "activo", "orden")
    list_filter = ("tipo", "validado", "activo")
    list_editable = ("validado", "activo", "orden")
    search_fields = ("nombre", "descripcion")


@admin.register(Andador)
class AndadorAdmin(admin.ModelAdmin):
    list_display = ("id", "tipo", "nombre", "num_puntos", "osm_id", "activo")
    list_filter = ("tipo", "activo")
    list_editable = ("activo",)
    search_fields = ("nombre", "osm_id")

    @admin.display(description="Puntos")
    def num_puntos(self, obj):
        return len(obj.puntos or [])



@admin.register(ReporteVial)
class ReporteVialAdmin(admin.ModelAdmin):
    list_display = ("tipo", "descripcion", "latitud", "longitud", "creado", "expira", "activo")
    list_filter = ("tipo", "activo")
    list_editable = ("activo",)
    date_hierarchy = "creado"
