package com.example.split_together

import android.accounts.Account
import android.accounts.AccountManager
import android.app.Activity
import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.AccountPicker
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Only the account name and per-account backup time are kept in device-local preferences. */
internal class DriveBackupAuth(private val activity: Activity) {
    private val prefs = activity.getSharedPreferences("drive_backup", Context.MODE_PRIVATE)
    private val authorization by lazy { Identity.getAuthorizationClient(activity) }
    private val account: String? get() = prefs.getString("account", null)
    private var pending: Attempt? = null

    private class Attempt(val reply: MethodChannel.Result, val connecting: Boolean, var name: String?)

    fun handle(call: MethodCall, reply: MethodChannel.Result) {
        val name = call.argument<String>("account")
        if (pending != null && call.method != "currentAccount") {
            reply.error("busy", null, null)
            return
        }
        when (call.method) {
            "currentAccount" -> reply.success(account)
            "disconnect" -> {
                prefs.edit().remove("account").apply()
                reply.success(null)
            }
            "connect" -> {
                // No subsequent failure or cancellation can resurrect the previous account.
                prefs.edit().remove("account").apply()
                val attempt = Attempt(reply, true, null)
                pending = attempt
                try {
                    val options = AccountPicker.AccountChooserOptions.Builder()
                        .setAllowableAccountsTypes(listOf("com.google"))
                        .setAlwaysShowAccountPicker(true)
                        .build()
                    activity.startActivityForResult(AccountPicker.newChooseAccountIntent(options), PICK_ACCOUNT)
                } catch (_: Exception) {
                    fail(attempt, "play-services")
                }
            }
            "access", "expired", "lastKnownBackup", "rememberLatest" -> {
                if (name.isNullOrBlank() || name != account) {
                    reply.error("account-changed", null, null)
                    return
                }
                when (call.method) {
                    "access" -> {
                        val attempt = Attempt(reply, false, name)
                        pending = attempt
                        authorize(attempt)
                    }
                    "expired" -> {
                        prefs.edit().remove("account").apply()
                        // Evict Google's rejected cached token; never persist it in the app.
                        val token = call.argument<String>("token")
                        if (!token.isNullOrEmpty()) {
                            try {
                                authorization.clearToken(ClearTokenRequest.builder().setToken(token).build())
                            } catch (_: Exception) {
                                // Forgetting the local link still works when Play services is unavailable.
                            }
                        }
                        reply.success(null)
                    }
                    "lastKnownBackup" -> reply.success(prefs.getString("latest:" + name, null))
                    "rememberLatest" -> {
                        prefs.edit().putString("latest:" + name, call.argument<String>("date")).apply()
                        reply.success(null)
                    }
                }
            }
            else -> reply.notImplemented()
        }
    }

    private fun authorize(attempt: Attempt) {
        val name = attempt.name ?: return fail(attempt, "cancelled")
        try {
            val request = AuthorizationRequest.builder()
                .setAccount(Account(name, "com.google"))
                .setRequestedScopes(listOf(Scope(APP_DATA_SCOPE)))
                .setOptOutIncludingGrantedScopes(true)
                .build()
            authorization.authorize(request)
                .addOnSuccessListener { response ->
                    if (pending === attempt) {
                        if (response.hasResolution()) {
                            if (attempt.connecting) requestConsent(attempt, response)
                            else fail(attempt, "expired")
                        } else {
                            complete(attempt, response)
                        }
                    }
                }
                .addOnFailureListener { fail(attempt, errorCode(it)) }
        } catch (_: Exception) {
            fail(attempt, "play-services")
        }
    }

    private fun requestConsent(attempt: Attempt, response: AuthorizationResult) {
        val sender = response.pendingIntent?.intentSender ?: return fail(attempt, "setup")
        try {
            activity.startIntentSenderForResult(sender, AUTHORIZE, null, 0, 0, 0)
        } catch (_: Exception) {
            fail(attempt, "play-services")
        }
    }

    fun onActivityResult(request: Int, result: Int, data: Intent?): Boolean {
        if (request != PICK_ACCOUNT && request != AUTHORIZE) return false
        val attempt = pending ?: return true
        if (result != Activity.RESULT_OK || data == null) {
            fail(attempt, "cancelled")
        } else if (request == PICK_ACCOUNT) {
            val chosen = data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
            if (chosen.isNullOrBlank() || data.getStringExtra(AccountManager.KEY_ACCOUNT_TYPE) != "com.google") {
                fail(attempt, "cancelled")
            } else {
                attempt.name = chosen
                authorize(attempt)
            }
        } else {
            try {
                complete(attempt, authorization.getAuthorizationResultFromIntent(data))
            } catch (e: Exception) {
                fail(attempt, errorCode(e))
            }
        }
        return true
    }

    private fun complete(attempt: Attempt, response: AuthorizationResult) {
        val token = response.accessToken
        if (token.isNullOrBlank() || !response.grantedScopes.contains(APP_DATA_SCOPE)) {
            fail(attempt, "expired")
            return
        }
        pending = null
        if (attempt.connecting) {
            prefs.edit().putString("account", attempt.name).apply()
            attempt.reply.success(attempt.name)
        } else {
            attempt.reply.success(mapOf("token" to token, "package" to activity.packageName))
        }
    }

    private fun errorCode(e: Exception) = when ((e as? ApiException)?.statusCode) {
        CommonStatusCodes.CANCELED -> "cancelled"
        CommonStatusCodes.NETWORK_ERROR, CommonStatusCodes.TIMEOUT -> "offline"
        CommonStatusCodes.SIGN_IN_REQUIRED, CommonStatusCodes.INVALID_ACCOUNT -> "expired"
        CommonStatusCodes.DEVELOPER_ERROR -> "setup"
        else -> "authorization"
    }

    private fun fail(attempt: Attempt, code: String) {
        if (pending !== attempt) return
        pending = null
        if (code == "expired" && attempt.name == account) prefs.edit().remove("account").apply()
        attempt.reply.error(code, null, null)
    }

    fun close() {
        pending?.let { fail(it, "cancelled") }
    }

    private companion object {
        const val PICK_ACCOUNT = 0x5D11
        const val AUTHORIZE = 0x5D12
        const val APP_DATA_SCOPE = "https://www.googleapis.com/auth/drive.appdata"
    }
}
