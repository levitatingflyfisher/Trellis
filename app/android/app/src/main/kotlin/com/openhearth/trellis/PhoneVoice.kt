package com.openhearth.trellis

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.UUID

/// The phone's own voice, saved to a file (board-0126): one sentence at a
/// time through `TextToSpeech.synthesizeToFile`, for the one tap and make
/// ahead in languages the downloaded voice can't speak. Dart reads each
/// WAV back (lib/features/reader/speech/phone_voice.dart).
///
/// Its own engine, apart from flutter_tts's: Read aloud may be speaking
/// on that one while an episode is being made, and the two must not set
/// each other's voice or stop each other. Every call is answered, done or
/// failed, so a job never waits forever on one sentence: a refusal at the
/// queue, an engine error, a stop and a sentence that never finishes
/// (the engine's service died) each end it.
object PhoneVoice {
    const val CHANNEL = "com.openhearth.trellis/phone_voice"

    /// Longer than any one sentence takes, even with a network voice.
    private const val SENTENCE_LIMIT_MS = 120_000L

    private val main = Handler(Looper.getMainLooper())
    private var context: Context? = null
    private var tts: TextToSpeech? = null
    private var engineAtStart: String? = null

    /// Null while the engine starts, then whether it did.
    private var ready: Boolean? = null
    private val waiting = mutableListOf<(TextToSpeech?) -> Unit>()

    /// The sentences being written, by utterance id: each is answered once.
    private val pending = HashMap<String, MethodChannel.Result>()

    fun attach(messenger: BinaryMessenger, context: Context) {
        this.context = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "voices" -> {
                    restartIfEngineChanged()
                    withEngine(result) { voices(it, result) }
                }
                "sayToFile" -> {
                    val text = call.argument<String>("text")
                    val lang = call.argument<String>("lang")
                    val voice = call.argument<String>("voice")
                    val path = call.argument<String>("path")
                    if (text == null || lang == null || path == null) {
                        result.error("arguments", "text, lang and path are needed", null)
                    } else {
                        withEngine(result) { say(it, text, lang, voice, path, result) }
                    }
                }
                "openSettings" -> result.success(openSettings())
                else -> result.notImplemented()
            }
        }
    }

    /// Runs [action] once the engine has started; answers [result] with an
    /// error when it can't. A failed start is tried again on the next call:
    /// an engine may be installed or enabled in the meantime.
    private fun withEngine(result: MethodChannel.Result, action: (TextToSpeech) -> Unit) {
        val run: (TextToSpeech?) -> Unit = { engine ->
            if (engine == null) {
                result.error("engine", "The phone's text-to-speech didn't start", null)
            } else {
                try {
                    action(engine)
                } catch (e: Exception) {
                    result.error("engine", e.message, null)
                }
            }
        }
        when (ready) {
            true -> run(tts)
            false -> {
                tts?.shutdown()
                tts = null
                ready = null
                waiting.add(run)
                start()
            }
            null -> {
                waiting.add(run)
                if (tts == null) start()
            }
        }
    }

    private fun start() {
        val ctx = context ?: return answerWaiting(null)
        tts = TextToSpeech(ctx) { status ->
            main.post {
                ready = status == TextToSpeech.SUCCESS
                val engine = if (ready == true) tts else null
                engine?.setOnUtteranceProgressListener(listener)
                engineAtStart = engine?.defaultEngine
                answerWaiting(engine)
            }
        }
    }

    private fun answerWaiting(engine: TextToSpeech?) {
        val all = waiting.toList()
        waiting.clear()
        for (w in all) w(engine)
    }

    /// The listener chose another engine in Android's settings: start on
    /// that one, unless a sentence is being written on this one.
    private fun restartIfEngineChanged() {
        val engine = tts ?: return
        if (ready != true || pending.isNotEmpty()) return
        if (engine.defaultEngine != engineAtStart) {
            engine.shutdown()
            tts = null
            ready = null
        }
    }

    private fun installed(engine: TextToSpeech): List<Voice> =
        ((try { engine.voices } catch (e: Exception) { null }) ?: emptySet<Voice>())
            .filter { it.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true }

    private fun voices(engine: TextToSpeech, result: MethodChannel.Result) {
        val name = engine.defaultEngine
        val label = try {
            engine.engines.firstOrNull { it.name == name }?.label
        } catch (e: Exception) {
            null
        }
        result.success(mapOf(
            "engine" to label,
            "voices" to installed(engine).map {
                mapOf(
                    "name" to it.name,
                    "locale" to it.locale.toLanguageTag(),
                    "network" to it.isNetworkConnectionRequired,
                )
            },
        ))
    }

    /// The voice for [lang]: [name] when it is still installed; else the
    /// engine's own for the language, unless that one needs the internet
    /// and one on the phone can say it; null when none can.
    private fun pick(engine: TextToSpeech, lang: String, name: String?): Voice? {
        val wanted = Locale.forLanguageTag(lang).language
        val mine = installed(engine).filter { it.locale.language == wanted }
        if (name != null) mine.firstOrNull { it.name == name }?.let { return it }
        val offline = mine.firstOrNull { !it.isNetworkConnectionRequired }
        val available = engine.setLanguage(Locale.forLanguageTag(lang))
        if (available < TextToSpeech.LANG_AVAILABLE) return offline ?: mine.firstOrNull()
        val own = engine.voice?.takeIf { it.locale.language == wanted }
        if (own != null && !own.isNetworkConnectionRequired) return own
        return offline ?: own ?: mine.firstOrNull()
    }

    private fun say(
        engine: TextToSpeech,
        text: String,
        lang: String,
        name: String?,
        path: String,
        result: MethodChannel.Result,
    ) {
        val voice = pick(engine, lang, name)
            ?: return result.error("no-voice", "No $lang voice is installed", null)
        engine.voice = voice
        val file = File(path)
        file.parentFile?.mkdirs()
        val id = "trellis-" + UUID.randomUUID()
        pending[id] = result
        if (engine.synthesizeToFile(text, Bundle(), file, id) != TextToSpeech.SUCCESS) {
            pending.remove(id)
            result.error("refused", "The voice didn't take the sentence", null)
            return
        }
        main.postDelayed({
            pending.remove(id)?.let {
                engine.stop()
                it.error("stalled", "The voice stopped answering", null)
            }
        }, SENTENCE_LIMIT_MS)
    }

    private fun finish(id: String?, answer: (MethodChannel.Result) -> Unit) {
        if (id == null) return
        main.post { pending.remove(id)?.let(answer) }
    }

    private val listener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}

        override fun onDone(utteranceId: String?) = finish(utteranceId) { it.success(true) }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) =
            finish(utteranceId) { it.error("failed", "The voice failed", null) }

        override fun onError(utteranceId: String?, errorCode: Int) =
            finish(utteranceId) { it.error("failed", "The voice failed ($errorCode)", null) }

        override fun onStop(utteranceId: String?, interrupted: Boolean) =
            finish(utteranceId) { it.error("stopped", "The voice was stopped", null) }
    }

    /// Android's text-to-speech settings, where a voice is added. Not
    /// every phone's settings app has the page.
    private fun openSettings(): Boolean {
        val ctx = context ?: return false
        return try {
            ctx.startActivity(
                Intent("com.android.settings.TTS_SETTINGS")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }
}
