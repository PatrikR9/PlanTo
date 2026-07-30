package app.planto.calendar

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.CalendarContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

private const val CHANNEL = "app.planto/calendar"
private const val REQUEST_CODE = 7301

/**
 * Reads busy/free times from the Android calendar store.
 *
 * PRIVACY CONTRACT — the reason this plugin exists instead of an off-the-shelf
 * one: the projections below list every column this app is capable of reading.
 * TITLE, DESCRIPTION, EVENT_LOCATION and ATTENDEE columns are absent, so
 * "PlanTo never reads your event titles" is enforced by the code that talks to
 * the content provider, not by a convention someone can forget in Dart.
 */
class PlantoCalendarPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() { activity = null }
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) =
        onAttachedToActivity(b)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission())
            "requestPermission" -> requestPermission(result)
            "calendars" -> {
                if (!hasPermission()) return denied(result)
                result.success(readCalendars())
            }
            "busyBlocks" -> {
                if (!hasPermission()) return denied(result)
                val from = (call.argument<Number>("from") ?: 0L).toLong()
                val to = (call.argument<Number>("to") ?: 0L).toLong()
                val ids = call.argument<List<String>>("calendarIds") ?: emptyList()
                result.success(readBusyBlocks(from, to, ids))
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    private fun denied(result: MethodChannel.Result) =
        result.error("PERMISSION_DENIED", "READ_CALENDAR not granted", null)

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) return result.success(true)

        val act = activity ?: return result.error(
            "NO_ACTIVITY", "Plugin is not attached to an activity", null
        )
        if (pendingResult != null) {
            return result.error("IN_PROGRESS", "A request is already pending", null)
        }
        pendingResult = result
        ActivityCompat.requestPermissions(
            act, arrayOf(Manifest.permission.READ_CALENDAR), REQUEST_CODE
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult ?: return false
        pendingResult = null

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED

        if (granted) {
            result.success(true)
        } else {
            // shouldShowRequestPermissionRationale is false AFTER a denial only
            // when the user chose "don't ask again" — the app must then send
            // them to Settings rather than asking again pointlessly.
            val permanent = activity?.let {
                !ActivityCompat.shouldShowRequestPermissionRationale(
                    it, Manifest.permission.READ_CALENDAR
                )
            } ?: false
            result.error(
                "PERMISSION_DENIED",
                "User denied calendar access",
                if (permanent) "permanently" else "once"
            )
        }
        return true
    }

    // ----------------------------------------------------------- calendars --
    private val calendarProjection = arrayOf(
        CalendarContract.Calendars._ID,
        CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
        CalendarContract.Calendars.ACCOUNT_NAME,
        CalendarContract.Calendars.IS_PRIMARY
    )

    private fun readCalendars(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val cursor: Cursor? = context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            calendarProjection,
            // Skip calendars the user has hidden in their calendar app.
            "${CalendarContract.Calendars.VISIBLE} = 1",
            null,
            null
        )
        cursor?.use {
            while (it.moveToNext()) {
                out.add(
                    mapOf(
                        "id" to it.getLong(0).toString(),
                        "name" to it.getString(1),
                        "account" to it.getString(2),
                        "primary" to (it.getInt(3) == 1)
                    )
                )
            }
        }
        return out
    }

    // --------------------------------------------------------- busy blocks --
    // BEGIN, END, ALL_DAY, AVAILABILITY, STATUS. No title. No location.
    // No description. No attendees. This array is the privacy contract.
    private val instanceProjection = arrayOf(
        CalendarContract.Instances.BEGIN,
        CalendarContract.Instances.END,
        CalendarContract.Instances.ALL_DAY,
        CalendarContract.Instances.AVAILABILITY,
        CalendarContract.Instances.STATUS,
        CalendarContract.Instances.CALENDAR_ID
    )

    private fun readBusyBlocks(
        from: Long,
        to: Long,
        calendarIds: List<String>
    ): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()

        // Instances.CONTENT_URI expands recurrence rules, exceptions and moved
        // occurrences for us. Doing that in Dart is a classic source of
        // off-by-one-week bugs around DST.
        val uri: Uri = CalendarContract.Instances.CONTENT_URI.buildUpon().let {
            ContentUris.appendId(it, from)
            ContentUris.appendId(it, to)
            it.build()
        }

        val selection = StringBuilder()
        val args = mutableListOf<String>()
        if (calendarIds.isNotEmpty()) {
            selection.append(
                "${CalendarContract.Instances.CALENDAR_ID} IN (" +
                    calendarIds.joinToString(",") { "?" } + ")"
            )
            args.addAll(calendarIds)
        }

        val cursor = context.contentResolver.query(
            uri,
            instanceProjection,
            if (selection.isEmpty()) null else selection.toString(),
            if (args.isEmpty()) null else args.toTypedArray(),
            null
        )

        cursor?.use {
            while (it.moveToNext()) {
                val availability = it.getInt(3)
                val status = it.getInt(4)

                // "Free"/transparent events (a birthday, a full-day marker you
                // set to Free) do not block a trip. Cancelled ones do not either.
                if (availability == CalendarContract.Instances.AVAILABILITY_FREE) continue
                if (status == CalendarContract.Instances.STATUS_CANCELED) continue

                out.add(
                    mapOf(
                        "start" to it.getLong(0),
                        "end" to it.getLong(1),
                        "allDay" to (it.getInt(2) == 1)
                    )
                )
            }
        }
        return out
    }
}
