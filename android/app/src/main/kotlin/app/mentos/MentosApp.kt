package app.mentos

import android.app.Application
import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log

class MentosApp : Application() {
    private var multicast: WifiManager.MulticastLock? = null

    override fun onCreate() {
        super.onCreate()
        try {
            System.loadLibrary("mentos_net")
            installIroh(applicationContext)
        } catch (t: Throwable) {
            Log.e("mentos", "native network library failed to load", t)
        }
        try {
            val wifi = getSystemService(WifiManager::class.java) ?: return
            multicast = wifi.createMulticastLock("mentos").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (t: Throwable) {
            Log.w("mentos", "multicast lock not acquired", t)
        }
    }

    private external fun installIroh(context: Context)
}
