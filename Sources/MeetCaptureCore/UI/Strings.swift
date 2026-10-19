// Strings.swift
// Every user-facing string, in Spanish (rioplatense). One place to edit.

import Foundation

enum Strings {
    // Header / phases
    static let appName = AppInfo.name
    static let startingAudio = "Iniciando audio…"
    static func phase(_ phase: AppPhase, isStartingRecording: Bool = false) -> String {
        if isStartingRecording { return startingAudio }
        switch phase {
        case .idle: return "En espera"
        case .approaching: return "Reunión por empezar"
        case .recording: return "Grabando"
        case .transcribing: return "Transcribiendo"
        case .done: return "Listo"
        }
    }

    // Status card
    static func headline(_ phase: AppPhase, meeting: Meeting?, isStartingRecording: Bool = false) -> String {
        if isStartingRecording { return startingAudio }
        switch phase {
        case .idle: return "Lista para grabar"
        case .approaching: return meeting?.title ?? "Reunión por empezar"
        case .recording: return "Grabando"
        case .transcribing: return "Transcribiendo"
        case .done: return "Transcripción lista"
        }
    }
    static func subline(_ phase: AppPhase, micOnly: Bool, isStartingRecording: Bool = false) -> String {
        if isStartingRecording { return "Esperando que el sistema de audio esté listo" }
        switch phase {
        case .idle: return "Detecta llamadas de Meet, Zoom, Teams y más"
        case .approaching: return "Empieza a grabar cuando arranque la llamada"
        case .recording: return micOnly ? "Solo micrófono" : "Micrófono + audio de la llamada"
        case .transcribing: return "Generando la transcripción en tu Mac"
        case .done: return "Guardada en la carpeta de transcripciones"
        }
    }

    // Permissions
    static let micPermissionTitle = "Falta el permiso de micrófono"
    static let micPermissionBody = "Captura tu voz y el audio de la llamada."
    static let grant = "Permitir"
    static let openPrivacySettings = "Abrir Ajustes"
    static let micPermissionDenied = "Activá MeetCapture en Ajustes del Sistema › Privacidad y seguridad › Micrófono."
    static let systemAudioSilentTitle = "No llega audio de la llamada"
    static let systemAudioSilentBody = "Sólo se graba tu micrófono. Activá MeetCapture en Ajustes › Privacidad y seguridad › Grabación de pantalla y audio del sistema."
    static let micSilentTitle = "El micrófono no capta nada"
    static let micSilentBody = "Revisá que el dispositivo de entrada esté conectado y sin silenciar (Ajustes › Audio)."

    // Recovery
    static let recoveredRecording = "Grabación recuperada"
    static let recovering = "Transcribiendo grabaciones pendientes…"
    static let transcribePending = "Transcribir"
    static func pendingRecordings(_ count: Int) -> String {
        count == 1 ? "1 grabación sin transcribir" : "\(count) grabaciones sin transcribir"
    }
    static func exhaustedRecordings(_ count: Int) -> String {
        count == 1
            ? "1 agotó los reintentos automáticos; el audio se conserva"
            : "\(count) agotaron los reintentos automáticos; el audio se conserva"
    }
    static func recordingExhausted(_ title: String) -> String {
        "«\(title)» sigue sin transcripción completa tras \(RecordingRecovery.maxAutomaticAttempts) intentos automáticos. El audio se conserva: abrí MeetCapture y tocá \(transcribePending)."
    }

    // Menu bar
    static let menuBarHiddenTitle = "El ícono no está en la barra de menús"
    static let menuBarNotAllowed = "macOS lo tiene desactivado. En Ajustes del Sistema › Barra de menús, activá MeetCapture en «Permitir en la barra de menús». Mientras tanto, usala desde esta ventana."
    static let menuBarBehindNotch = "No entra en la barra y quedó detrás de la cámara. Sacá íconos que no uses (⌘ + arrastrar fuera de la barra). Mientras tanto, usala desde esta ventana."
    static let openMenuBarSettings = "Abrir Ajustes de la barra de menús"

    // Buttons
    static let record = "Grabar"
    static let stop = "Detener"
    static let transcribing = "Transcribiendo…"
    static let copy = "Copiar"
    static let retranscribe = "Re-transcribir"
    static let importAudio = "Importar audio…"
    static let importTitle = "Elegí un audio para transcribir"
    static let settings = "Ajustes"
    static let quit = "Salir"

    // Sections
    static let transcript = "Transcripción"
    static let nextMeeting = "Próxima reunión"
    static let history = "Historial"
    static let myNotes = "Mis notas"
    static let notesPlaceholder = "Anotá puntos clave mientras grabás…"
    static let searchPlaceholder = "Buscar reuniones…"
    static let noMeetings = "Todavía no hay reuniones"
    static let noSearchResults = "No se encontraron reuniones"
    static let now = "ahora"
    static func inMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "en \(minutes / 60) h \(minutes % 60) min" : "en \(minutes) min"
    }
    static func speakers(_ n: Int) -> String { n == 1 ? "1 hablante" : "\(n) hablantes" }
    static let showTranscript = "Mostrar en Finder"
    static let openMeetingNote = "Abrir nota Markdown"

    // Errors
    static let errorNoMicPermission = "Hace falta el permiso de micrófono. Abrí Ajustes del Sistema › Privacidad."
    static let errorNoRecording = "No se encontró la grabación."
    static let errorNoAudio = "No hay audio guardado para re-transcribir."
    static let errorAudioGone = "El audio ya no existe (lo borró la política de retención)."
    static let errorAudioRecovering = "Esa grabación se está recuperando en segundo plano; esperá a que termine."
    static let retranscription = "Re-transcripción"
    static func errorRecording(_ reason: String) -> String { "No se pudo grabar: \(reason)" }
    static func errorTranscription(_ reason: String) -> String { "Falló la transcripción: \(reason)" }
    static func errorPartialTranscript(_ chunks: Int) -> String {
        "La transcripción quedó con \(chunks) fragmento(s) sin texto; se conserva el audio para retranscribir"
    }
    static func errorImport(_ reason: String) -> String { "Falló la importación: \(reason)" }

    // Settings
    enum Settings {
        static let general = "General"
        static let audio = "Audio"
        static let asr = "ASR"
        static let summary = "Resumen"
        static let calendar = "Calendario"
        static let about = "Acerca de"

        static let autoRecord = "Grabar llamadas y reuniones automáticamente"
        static let autoRecordHelp = "Empieza a grabar cuando un navegador, Zoom, Teams o FaceTime usa el micrófono, aunque la llamada no esté en el calendario."
        static let notify = "Avisar cuando la transcripción esté lista"
        static let retention = "Audio original"
        static func retention(_ policy: RetentionPolicy) -> String {
            switch policy {
            case .deleteAfterHandoff: return "Borrar al terminar"
            case .keep24h: return "Guardar 24 horas"
            case .keep: return "Guardar siempre"
            }
        }
        static let maxDuration = "Duración máxima"
        static func hours(_ n: Int) -> String { n == 1 ? "1 hora" : "\(n) horas" }

        static let audioHelp = "La captura escribe PCM Int16 estéreo a 16 kHz (izquierda = sistema, derecha = micrófono)."
        static let micOnly = "Modo conversación (solo micrófono)"
        static let micOnlyHelp = "Para charlas al lado de la Mac o llamadas del teléfono: graba solo el micrófono elegido, sin audio del sistema."
        static let inputDevice = "Dispositivo de entrada"
        static let systemDefault = "Sistema (predeterminado)"
        static let micPermission = "Permiso de micrófono"
        static let calendarPermission = "Acceso al calendario"
        static let granted = "Concedido"
        static let required = "Pendiente"

        static let engine = "Motor"
        static let engineValue = "Parakeet TDT 0.6B en el Neural Engine, por canal; corre al terminar la grabación."
        static let language = "Idioma"
        static let spanish = "Español (es)"
        static let english = "Inglés (en)"
        static let autoDetect = "Detectar"
        static let diarize = "Identificar hablantes"
        static let diarizeHelp = "Tu micrófono sale como Gio; el audio de la llamada se separa en Participante 1, 2… Sin diarización queda como Participante."
        static let aliasesHelp = "Correcciones de nombres y siglas: \"aliases\" en config.json (pestaña Calendario › Editar config.json)."

        static let summaryHelp = "El resumen lo genera el dispatcher (tools/summary) leyendo ~/.meetcapture/summary.json."
        static let tagVocabularyDir = "Carpeta de etiquetas (opcional)"
        static let tagVocabularyHelp = "Lee etiquetas de archivos Markdown de esa carpeta. Sólo se usarán etiquetas existentes."
        static let endpoint = "Endpoint"
        static let summaryModel = "Modelo"
        static let apiKey = "API key"
        static let maxTokens = "Máximo de tokens"
        static let keepAudio = "Conservar el audio después del resumen"
        static let dryRun = "Modo prueba (no llama al modelo)"
        static let save = "Guardar"
        static let saved = "Guardado"

        static let whitelist = "Correos internos (no cuentan como externos)"
        static let whitelistEmpty = "Sin correos internos: cualquier invitado cuenta como externo."
        static let editConfig = "Editar config.json"
        static let reloadConfig = "Recargar"
        static let calendarHelp = "Solo se graban eventos con enlace de Google Meet y al menos un invitado externo."

        static let aboutTagline = "Transcripción local de llamadas: Meet, Zoom, Teams, WhatsApp y más."
        static let website = "Sitio"
        static let source = "Código"
        static let modelsCredit = "Modelos: NVIDIA Parakeet TDT y pyannote, vía FluidAudio (CC-BY-4.0)."
    }
}
