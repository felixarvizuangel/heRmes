package com.example.app_uth

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Avisos de heRmes con sonido: notificación local NATIVA (sin plugins, sin
 * dependencias extra ni desugaring).
 *
 * Canal Flutter "hermes/avisos":
 *  - iniciar: crea el canal de notificaciones (importancia ALTA = suena con
 *    el tono de notificaciones, vibra y aparece arriba) y pide el permiso de
 *    Android 13+.
 *  - avisar(titulo, cuerpo): muestra la notificación.
 *
 * El sonido y la vibración se fijan al CREAR el canal; si se cambian hay que
 * usar otro id de canal o desinstalar la app.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CANAL_FLUTTER = "hermes/avisos"
        private const val CANAL_ID = "hermes_avisos_v2"
        private const val CANAL_NOMBRE = "Avisos de heRmes"
        private const val PERMISO_REQ = 7031
        private val VIBRACION = longArrayOf(0, 350, 200, 350)
    }

    private var siguienteId = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CANAL_FLUTTER)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "iniciar" -> {
                            crearCanal()
                            pedirPermiso()
                            result.success(puedeNotificar())
                        }
                        "avisar" -> {
                            val titulo = call.argument<String>("titulo") ?: "heRmes"
                            val cuerpo = call.argument<String>("cuerpo") ?: ""
                            result.success(avisar(titulo, cuerpo))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("AVISO", e.message, null)
                }
            }
    }

    private fun manager() =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun crearCanal() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val canal = NotificationChannel(
            CANAL_ID, CANAL_NOMBRE, NotificationManager.IMPORTANCE_HIGH
        )
        canal.description = "Llegada al destino y edificios cercanos (con sonido y vibración)."
        canal.enableVibration(true)
        canal.vibrationPattern = VIBRACION
        canal.setSound(
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        )
        manager().createNotificationChannel(canal)
    }

    private fun pedirPermiso() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISO_REQ)
        }
    }

    private fun puedeNotificar(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun avisar(titulo: String, cuerpo: String): Boolean {
        crearCanal()
        if (!puedeNotificar()) return false
        val abrir = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder: Notification.Builder
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = Notification.Builder(this, CANAL_ID)
            builder.setTimeoutAfter(15000)
        } else {
            @Suppress("DEPRECATION")
            builder = Notification.Builder(this)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_SOUND)
                .setVibrate(VIBRACION)
        }
        builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(titulo)
            .setContentText(cuerpo)
            .setStyle(Notification.BigTextStyle().bigText(cuerpo))
            .setCategory(Notification.CATEGORY_NAVIGATION)
            .setContentIntent(abrir)
            .setAutoCancel(true)
        manager().notify(siguienteId++, builder.build())
        return true
    }
}
