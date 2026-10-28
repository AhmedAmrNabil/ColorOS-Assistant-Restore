package io.github.andrea_lyz.assistrestore;

import android.app.KeyguardManager;
import android.content.Context;
import android.content.Intent;
import android.os.UserHandle;
import android.provider.MediaStore;
import android.content.pm.PackageManager;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

import io.github.libxposed.api.XposedInterface;

/**
 * Power-key double press: replaces the OEM wallet quick launch with launching the camera.
 *
 * <p>A China build funnels the double press into {@code OplusWalletController.startWallet}, which
 * starts the wallet named by {@code /etc/extension/default_wallet_configuration.xml} (the ColorOS
 * wallet). This hook intercepts that call site and instead launches the camera (secure camera over
 * keyguard if locked, or standard camera if unlocked).</p>
 */
final class CameraHooks {
    private static final String WALLET_CONTROLLER =
            "com.android.server.policy.OplusWalletController";

    private CameraHooks() {
    }

    static void install(AssistRestoreModule module, ClassLoader classLoader) {
        try {
            Class<?> controller = Class.forName(WALLET_CONTROLLER, true, classLoader);
            Method startWallet = controller.getDeclaredMethod("startWallet", boolean.class);
            startWallet.setAccessible(true);
            Field contextField = controller.getDeclaredField("mContext");
            contextField.setAccessible(true);

            module.hook(startWallet)
                    .setId("double_press_camera")
                    .setExceptionMode(XposedInterface.ExceptionMode.PROTECTIVE)
                    .intercept(chain -> {
                        if (!AssistConfig.isEnabled(HookPrefs.get())
                                || !AssistConfig.doublePressCamera(HookPrefs.get())) {
                            return chain.proceed();
                        }
                        if (launchCamera(module, chain.getThisObject(), contextField)) {
                            return null;
                        }
                        // Never leave the gesture unanswered: fall back to the OEM wallet.
                        return chain.proceed();
                    });
            module.logInfo("hook_installed target=" + WALLET_CONTROLLER + ".startWallet");
        } catch (Throwable t) {
            module.logError("hook_failed target=" + WALLET_CONTROLLER + ".startWallet", t);
        }
    }

    /** @return {@code true} when the camera was asked to start */
    private static boolean launchCamera(
            AssistRestoreModule module, Object controller, Field contextField) {
        try {
            Object value = contextField.get(controller);
            if (!(value instanceof Context)) {
                module.logWarn("double_press_camera_failed reason=no_context");
                return false;
            }
            Context context = (Context) value;
            KeyguardManager km = context.getSystemService(KeyguardManager.class);
            boolean locked = km != null && km.isKeyguardLocked();

            Intent intent = new Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

            // On the lockscreen prefer the secure camera, so the gallery stays locked
            if (locked) {
                Intent secure = new Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA_SECURE)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                                | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
                if (context.getPackageManager()
                        .resolveActivity(secure, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                    intent = secure;
                }
            }

            startForCurrentUser(context, intent);
            module.logInfo("double_press_camera target=" + intent.getAction()
                    + " locked=" + locked + " launched=true");
            return true;
        } catch (Throwable t) {
            module.logWarn("double_press_camera_failed " + t);
            return false;
        }
    }

    /**
     * {@code Context.startActivityAsUser} is hidden API: it is reached reflectively so the activity
     * lands on the current user exactly like the OEM call does, with the public call as fallback.
     */
    private static void startForCurrentUser(Context context, Intent intent) {
        try {
            Method startActivityAsUser =
                    Context.class.getMethod("startActivityAsUser", Intent.class, UserHandle.class);
            // UserHandle.CURRENT is hidden API as well; both are resolved by reflection.
            Object currentUser = UserHandle.class.getField("CURRENT").get(null);
            startActivityAsUser.invoke(context, intent, currentUser);
            return;
        } catch (Throwable ignored) {
            // Hidden overload unavailable: fall through to the public call.
        }
        context.startActivity(intent);
    }
}
