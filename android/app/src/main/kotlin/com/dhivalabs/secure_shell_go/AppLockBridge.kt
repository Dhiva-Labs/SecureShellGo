package com.dhivalabs.secure_shell_go

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The platform half of the optional app lock (`app_lock.dart`).
 *
 * A hand-rolled channel rather than `androidx.biometric`, which is the
 * standing policy for Android work in this project — see `StorageBridge.kt`
 * for the argument. Here it costs less than usual: the *framework*
 * [BiometricPrompt] has offered a device-credential fallback since API 30,
 * and a deprecated equivalent since API 28, so the AndroidX wrapper would be
 * buying compatibility this app can reach without a new Gradle dependency.
 *
 * Three tiers, because minSdk is 23:
 *
 *  - **API 30+** — [BiometricPrompt] with
 *    `setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)`. One
 *    sheet, fingerprint or face with PIN/pattern/password behind it.
 *  - **API 28–29** — the same prompt with the deprecated
 *    `setDeviceCredentialAllowed(true)`, which is the only way to get the
 *    credential fallback on those two levels.
 *  - **API 23–27** — no framework [BiometricPrompt] at all, so
 *    [KeyguardManager.createConfirmDeviceCredentialIntent] and the ordinary
 *    activity-result path. Credential only, no biometrics, which is the
 *    honest limit of what those levels expose without AndroidX.
 *
 * Every path resolves to exactly one of the strings `app_lock.dart` parses,
 * exactly once. A path that resolved twice would leave a `MethodChannel`
 * result completed more than once (a hard crash on the Flutter side); one
 * that never resolved would leave the lock screen up with a spinner and no
 * way past it, which is the failure this feature least tolerates.
 */
class AppLockBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.dhivalabs.secure_shell_go/app_lock"

        /** Distinct from StorageBridge's codes so the two never collide. */
        const val REQUEST_CONFIRM_CREDENTIAL = 0x5351

        private const val RESULT_SUCCESS = "success"
        private const val RESULT_FAILED = "failed"
        private const val RESULT_CANCELLED = "cancelled"
        private const val RESULT_LOCKED_OUT = "lockedOut"
        private const val RESULT_UNAVAILABLE = "unavailable"

        /**
         * BiometricPrompt's error codes, written out rather than referenced
         * through `BiometricPrompt.BIOMETRIC_ERROR_*`.
         *
         * The constants are inherited from the `BiometricConstants`
         * interface, and which of them are public API has moved around
         * between 28 and 30. The *values* have not — they are frozen platform
         * ABI, shared with `androidx.biometric`'s `BiometricPrompt` and with
         * `FingerprintManager` before it, and cannot change without breaking
         * every app that ships the AndroidX wrapper. Spelling them out here
         * compiles identically on every level this app supports.
         */
        private const val ERROR_HW_UNAVAILABLE = 1
        private const val ERROR_CANCELED = 5
        private const val ERROR_LOCKOUT = 7
        private const val ERROR_LOCKOUT_PERMANENT = 9
        private const val ERROR_USER_CANCELED = 10
        private const val ERROR_NO_BIOMETRICS = 11
        private const val ERROR_HW_NOT_PRESENT = 12
        private const val ERROR_NEGATIVE_BUTTON = 13
    }

    private val main = Handler(Looper.getMainLooper())

    /**
     * The in-flight authentication, or null. Also the re-entrancy guard: a
     * second `authenticate` while a sheet is already up is answered
     * immediately rather than raising a second sheet over the first.
     */
    private var pending: MethodChannel.Result? = null

    private var cancellationSignal: CancellationSignal? = null

    /**
     * Whether the user has actually got a fingerprint or PIN wrong during
     * this attempt.
     *
     * [BiometricPrompt.AuthenticationCallback.onAuthenticationFailed] fires
     * on a rejected finger *without* closing the sheet, so it is not itself a
     * terminal answer. This records that it happened, so that a user who
     * fails twice and then dismisses the sheet is reported as `failed` rather
     * than `cancelled` — the difference decides whether the attempt counts
     * toward the cooldown in `app_lock_controller.dart`.
     */
    private var sawRejection = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "support" -> result.success(support())
            "authenticate" -> authenticate(result)
            "setSecure" -> {
                setSecure(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * `isDeviceSecure` rather than a biometric-capability query, on purpose.
     * It is available all the way down to API 23 and it answers the question
     * that actually matters: is there any credential to check against. A
     * device with no biometrics but a PIN is perfectly lockable; a device
     * with a fingerprint reader and no screen lock is not.
     */
    private fun support(): String {
        val keyguard = keyguardManager() ?: return RESULT_UNAVAILABLE
        return if (keyguard.isDeviceSecure) "available" else "noDeviceCredential"
    }

    private fun authenticate(result: MethodChannel.Result) {
        if (pending != null) {
            // Already showing. Answering `cancelled` keeps the Dart side's
            // accounting honest — nothing was tried, so nothing failed.
            result.success(RESULT_CANCELLED)
            return
        }
        val keyguard = keyguardManager()
        if (keyguard == null || !keyguard.isDeviceSecure) {
            result.success(RESULT_UNAVAILABLE)
            return
        }

        pending = result
        sawRejection = false

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            showBiometricPrompt()
        } else {
            showConfirmCredential(keyguard)
        }
    }

    private fun showBiometricPrompt() {
        val signal = CancellationSignal()
        cancellationSignal = signal

        val builder = BiometricPrompt.Builder(activity)
            .setTitle("Unlock SecureShell Go")
            .setDescription("Your sessions and tunnels are still running.")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
        } else {
            // API 28–29: the only route to a credential fallback. Deprecated
            // in 30, which is why the branch above exists.
            @Suppress("DEPRECATION")
            builder.setDeviceCredentialAllowed(true)
        }

        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(
                authResult: BiometricPrompt.AuthenticationResult?,
            ) {
                finish(RESULT_SUCCESS)
            }

            /**
             * A rejected finger. The sheet stays up and the user may try
             * again, so this is recorded rather than answered.
             */
            override fun onAuthenticationFailed() {
                sawRejection = true
            }

            override fun onAuthenticationError(
                errorCode: Int,
                errString: CharSequence?,
            ) {
                finish(mapError(errorCode))
            }
        }

        runCatching {
            builder.build().authenticate(
                signal,
                activity.mainExecutor,
                callback,
            )
        }.onFailure {
            // The sheet could not be raised at all. Answering `unavailable`
            // makes the Dart side fail open rather than leaving the gate up
            // with nothing behind the Unlock button.
            finish(RESULT_UNAVAILABLE)
        }
    }

    private fun mapError(errorCode: Int): String = when (errorCode) {
        ERROR_LOCKOUT, ERROR_LOCKOUT_PERMANENT -> RESULT_LOCKED_OUT

        ERROR_USER_CANCELED, ERROR_CANCELED, ERROR_NEGATIVE_BUTTON ->
            // Dismissing after getting it wrong is a failed attempt the user
            // gave up on, not a clean cancel. See [sawRejection].
            if (sawRejection) RESULT_FAILED else RESULT_CANCELLED

        ERROR_HW_NOT_PRESENT, ERROR_HW_UNAVAILABLE, ERROR_NO_BIOMETRICS ->
            // With DEVICE_CREDENTIAL allowed these should not arrive at all;
            // if they do, the sheet cannot authenticate anyone and the Dart
            // side should fail open rather than hold the gate shut.
            RESULT_UNAVAILABLE

        else -> RESULT_FAILED
    }

    /** API 23–27: the system credential screen, as an activity result. */
    private fun showConfirmCredential(keyguard: KeyguardManager) {
        @Suppress("DEPRECATION")
        val intent = keyguard.createConfirmDeviceCredentialIntent(
            "Unlock SecureShell Go",
            "Your sessions and tunnels are still running.",
        )
        if (intent == null) {
            finish(RESULT_UNAVAILABLE)
            return
        }
        runCatching {
            activity.startActivityForResult(intent, REQUEST_CONFIRM_CREDENTIAL)
        }.onFailure { finish(RESULT_UNAVAILABLE) }
    }

    /** Returns true when this bridge owned the result. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CONFIRM_CREDENTIAL) return false
        finish(
            if (resultCode == Activity.RESULT_OK) RESULT_SUCCESS
            else RESULT_CANCELLED,
        )
        return true
    }

    /**
     * Keeps the app's contents out of screenshots and the recent-apps
     * thumbnail while the lock is switched on.
     *
     * Set from the moment the setting is enabled rather than when the gate
     * goes up, because the thumbnail the launcher shows is captured as the
     * app is *leaving* — by the time the lock screen is drawn, the snapshot
     * of the terminal behind it has already been taken.
     */
    private fun setSecure(enabled: Boolean) {
        main.post {
            runCatching {
                if (enabled) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
            }
        }
    }

    /** Answers the pending call exactly once, on the main thread. */
    private fun finish(outcome: String) {
        val result = pending ?: return
        pending = null
        cancellationSignal = null
        main.post { runCatching { result.success(outcome) } }
    }

    fun dispose() {
        runCatching { cancellationSignal?.cancel() }
        cancellationSignal = null
        // A pending call whose activity is going away would otherwise leave
        // the Dart future hanging forever, and with it the lock screen.
        finish(RESULT_UNAVAILABLE)
    }

    private fun keyguardManager(): KeyguardManager? =
        activity.getSystemService(KeyguardManager::class.java)
}
