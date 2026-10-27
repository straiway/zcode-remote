package dev.straiway.zcodeshell

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject

/**
 * @param autoNamed true 表示名称是系统自动取的（页面标题），可被后续标题自动更新；
 *                  用户手动重命名后置为 false，不再自动覆盖。
 */
data class SavedConnection(
    val name: String,
    val url: String,
    val savedAt: Long,
    val autoNamed: Boolean = true,
)

/**
 * 多连接的本地存储。
 *
 * 链接内含授权令牌、等同临时密钥，因此优先使用
 * EncryptedSharedPreferences（AES256-GCM，密钥在 Android KeyStore 中）；
 * 设备 KeyStore 异常（刷机、系统恢复等）时降级为应用私有目录的普通存储，
 * 避免直接崩溃——普通存储对其他应用仍不可见，只是不防 root。
 */
object ConnectionStore {

    private const val PREF_NAME = "connection"
    private const val KEY_LIST = "connections"
    private const val KEY_LEGACY_URL = "last_url"

    fun list(context: Context): List<SavedConnection> {
        val prefs = prefs(context)
        val raw = prefs.getString(KEY_LIST, null)
        val result = mutableListOf<SavedConnection>()
        if (raw != null) {
            runCatching {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    result += SavedConnection(
                        name = o.getString("name"),
                        url = o.getString("url"),
                        savedAt = o.getLong("savedAt"),
                        autoNamed = o.optBoolean("autoNamed", true),
                    )
                }
            }
        } else {
            // v0.1.x 只存过单条 last_url，迁移成列表里的第一条
            prefs.getString(KEY_LEGACY_URL, null)?.takeIf { it.isNotBlank() }?.let { legacy ->
                result += SavedConnection("我的电脑", legacy, System.currentTimeMillis())
                persist(context, result)
            }
            prefs.edit().remove(KEY_LEGACY_URL).apply()
        }
        return result.sortedByDescending { it.savedAt }
    }

    /** 新增或刷新一条连接。链接的 name 参数即电脑主机名，作为默认名称（锁定不随页面标题变）。 */
    fun upsert(context: Context, url: String): List<SavedConnection> {
        val current = list(context).toMutableList()
        val existing = current.firstOrNull { it.url == url }
        current.removeAll { it.url == url }
        val machineName = Uri.parse(url).getQueryParameter("name")?.trim().orEmpty()
        val entry = when {
            existing == null -> SavedConnection(
                name = machineName.ifBlank { "工作区 ${current.size + 1}" },
                url = url,
                savedAt = System.currentTimeMillis(),
                autoNamed = machineName.isBlank(),
            )
            existing.autoNamed && machineName.isNotEmpty() && isPlaceholderName(existing.name) ->
                existing.copy(name = machineName, autoNamed = false, savedAt = System.currentTimeMillis())
            else -> existing.copy(savedAt = System.currentTimeMillis())
        }
        current += entry
        val updated = current.sortedByDescending { it.savedAt }
        persist(context, updated)
        return updated
    }

    private fun isPlaceholderName(name: String): Boolean =
        name == "我的电脑" || Regex("^工作区 \\d+$").containsMatchIn(name)

    /** 用页面标题自动命名：只改 autoNamed 的连接，返回是否真的改了。 */
    fun autoRename(context: Context, url: String, title: String): Boolean {
        val connections = list(context)
        if (connections.none { it.url == url && it.autoNamed && it.name != title }) return false
        persist(
            context,
            connections.map { if (it.url == url && it.autoNamed) it.copy(name = title) else it },
        )
        return true
    }

    /** 用户手动重命名：锁定名称，不再自动覆盖。 */
    fun rename(context: Context, url: String, name: String) {
        persist(
            context,
            list(context).map { if (it.url == url) it.copy(name = name, autoNamed = false) else it },
        )
    }

    fun remove(context: Context, url: String) {
        persist(context, list(context).filterNot { it.url == url })
    }

    private fun persist(context: Context, connections: List<SavedConnection>) {
        val arr = JSONArray()
        connections.forEach { c ->
            arr.put(JSONObject().apply {
                put("name", c.name)
                put("url", c.url)
                put("savedAt", c.savedAt)
                put("autoNamed", c.autoNamed)
            })
        }
        prefs(context).edit().putString(KEY_LIST, arr.toString()).apply()
    }

    private fun prefs(context: Context): SharedPreferences = try {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            PREF_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (e: Exception) {
        context.getSharedPreferences("$PREF_NAME.fallback", Context.MODE_PRIVATE)
    }
}
