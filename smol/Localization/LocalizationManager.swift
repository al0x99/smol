import Foundation
import SwiftUI
import Combine

/// Manages app localization with support for English and Italian
@MainActor
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var currentLanguage: Language {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "app_language")
        }
    }

    enum Language: String, CaseIterable, Identifiable {
        case english = "en"
        case italian = "it"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .english: return "English"
            case .italian: return "Italiano"
            }
        }

        var flag: String {
            switch self {
            case .english: return "🇬🇧"
            case .italian: return "🇮🇹"
            }
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "app_language"),
           let language = Language(rawValue: saved) {
            currentLanguage = language
        } else {
            // Detect system language
            let preferredLanguage = Locale.preferredLanguages.first ?? "en"
            currentLanguage = preferredLanguage.starts(with: "it") ? .italian : .english
        }
    }

    func localized(_ key: String) -> String {
        return Strings.localized(key, language: currentLanguage)
    }
}

// MARK: - Localized Strings

struct Strings {
    static func localized(_ key: String, language: LocalizationManager.Language) -> String {
        let strings = language == .italian ? italianStrings : englishStrings
        return strings[key] ?? key
    }

    // MARK: - English Strings

    static let englishStrings: [String: String] = [
        // Tab names
        "tab.dashboard": "Dashboard",
        "tab.cpu": "CPU",
        "tab.memory": "Memory",
        "tab.temperature": "Temperature",
        "tab.processes": "Processes",
        "tab.ai": "AI Assistant",
        "tab.settings": "Settings",
        "tab.fans": "Fans",
        "tab.system": "System",
        "tab.alerts": "Alerts",

        // Intro Tab
        "intro.tagline": "The system monitor that doesn't become the problem.",
        "intro.the_problem": "The Problem",
        "intro.the_solution": "The Solution",
        "intro.bloat1_problem": "500 MB app just to tell you about cache",
        "intro.bloat2_problem": "Updater running at 70% CPU for months",
        "intro.bloat3_problem": "16+ background processes doing nothing",
        "intro.solution1_title": "Memory Pressure, not GB used",
        "intro.solution1_desc": "On macOS, GB used means nothing. Pressure does.",
        "intro.solution2_title": "CPU usage, clear and simple",
        "intro.solution2_desc": "How hard your Mac is working, without alarmism.",
        "intro.solution3_title": "Swap = real problem",
        "intro.solution3_desc": "If there's swap, you really have a problem. Otherwise no.",
        "intro.solution4_title": "Find ghost processes",
        "intro.solution4_desc": "Identify who's stealing CPU for too long.",
        "intro.vs": "vs",
        "intro.size": "Size",
        "intro.ram": "RAM",
        "intro.philosophy": "Philosophy",
        "intro.philosophy_desc": "smol follows the principle: a system monitor that uses more resources than your apps is part of the problem.",
        "intro.no_bloat": "No bloat.",
        "intro.no_subscription": "No subscriptions.",
        "intro.just_info": "Just the info you need.",
        "intro.lets_go": "Let's see how your Mac is doing",
        "intro.open_dashboard": "Open Dashboard",

        // Dashboard
        "dashboard.title": "System Overview",
        "dashboard.cpu_usage": "CPU Usage",
        "dashboard.memory_pressure": "Memory Pressure",
        "dashboard.temperature": "Temperature",
        "dashboard.health_score": "Health Score",
        "dashboard.excellent": "Excellent",
        "dashboard.good": "Good",
        "dashboard.moderate": "Moderate",
        "dashboard.critical": "Critical",

        // CPU
        "cpu.title": "CPU Monitor",
        "cpu.usage": "Usage",
        "cpu.cores": "Cores",
        "cpu.threads": "Threads",
        "cpu.frequency": "Frequency",
        "cpu.load_average": "Load Average",

        // Memory
        "memory.title": "Memory Monitor",
        "memory.used": "Used",
        "memory.free": "Free",
        "memory.total": "Total",
        "memory.pressure": "Pressure",
        "memory.swap": "Swap",
        "memory.wired": "Wired",
        "memory.compressed": "Compressed",
        "memory.app_memory": "App Memory",
        "memory.cached": "Cached",

        // Temperature
        "temp.title": "Temperature Monitor",
        "temp.cpu": "CPU Temperature",
        "temp.gpu": "GPU Temperature",
        "temp.ssd": "SSD Temperature",
        "temp.fan_speed": "Fan Speed",
        "temp.normal": "Normal",
        "temp.elevated": "Elevated",
        "temp.high": "High",
        "temp.critical": "Critical",

        // Processes
        "processes.title": "Processes",
        "processes.name": "Name",
        "processes.pid": "PID",
        "processes.cpu": "CPU %",
        "processes.memory": "Memory",
        "processes.status": "Status",
        "processes.user": "User",
        "processes.terminate": "Terminate",
        "processes.search": "Search processes...",
        "processes.running": "running",
        "processes.sleeping": "sleeping",
        "processes.total": "Total Processes",

        // AI Assistant
        "ai.title": "AI Assistant",
        "ai.chat": "Chat",
        "ai.insights": "Insights",
        "ai.report": "Report",
        "ai.ask_placeholder": "Ask about your system...",
        "ai.send": "Send",
        "ai.clear": "Clear",
        "ai.generate_report": "Generate Report",
        "ai.export": "Export",
        "ai.anomalies": "Anomalies Detected",
        "ai.advice": "Recommendations",
        "ai.no_anomalies": "No anomalies detected",
        "ai.no_advice": "System running normally",
        "ai.ml_status": "ML Status",
        "ai.model_trained": "Model trained",
        "ai.model_training": "Training in progress...",
        "ai.model_not_trained": "Model not trained yet",
        "ai.samples_collected": "samples collected",
        "ai.train_model": "Train Model",
        "ai.training_requires": "Requires at least 500 samples",

        // Settings
        "settings.title": "Settings",
        "settings.general": "General",
        "settings.appearance": "Appearance",
        "settings.language": "Language",
        "settings.refresh_rate": "Refresh Rate",
        "settings.notifications": "Notifications",
        "settings.enable_notifications": "Enable Notifications",
        "settings.notify_high_cpu": "High CPU Alert",
        "settings.notify_high_memory": "High Memory Alert",
        "settings.notify_high_temp": "High Temperature Alert",
        "settings.about": "About",
        "settings.version": "Version",
        "settings.reset": "Reset Settings",

        // Alerts & Messages
        "alert.high_cpu": "High CPU usage detected",
        "alert.high_memory": "Memory pressure is critical",
        "alert.high_temp": "Temperature is elevated",
        "alert.process_terminated": "Process terminated",
        "alert.error": "Error",
        "alert.success": "Success",
        "alert.warning": "Warning",
        "alert.confirm": "Confirm",
        "alert.cancel": "Cancel",
        "alert.ok": "OK",

        // Self Monitor
        "self.title": "smol Resource Usage",
        "self.cpu": "CPU",
        "self.memory": "Memory",
        "self.threads": "Threads",
        "self.pid": "PID",

        // General
        "general.loading": "Loading...",
        "general.refresh": "Refresh",
        "general.close": "Close",
        "general.save": "Save",
        "general.delete": "Delete",
        "general.edit": "Edit",
        "general.copy": "Copy",
        "general.share": "Share",

        // Intro extra
        "intro.start_monitoring": "Start Monitoring",
        "intro.quote1": "\"Cleaning apps use 500MB to tell you your Mac is dirty.",
        "intro.quote2": "smol uses 5MB to tell you the truth.\"",

        // Overview
        "overview.in_use": "in use",
        "overview.all_good": "All good",
        "overview.attention": "Warning!",
        "overview.rising": "Rising",
        "overview.falling": "Falling",
        "overview.stable": "Stable",
        "overview.system_healthy": "System Healthy",
        "overview.warning": "Warning",
        "overview.critical": "Critical Status",

        // Processes
        "processes.search_placeholder": "Search processes...",
        "processes.count": "processes",
        "processes.anomalies": "anomalies",
        "processes.refresh": "Refresh",
        "processes.cpu_time": "CPU Time",

        // Alerts
        "alerts.monitoring_active": "Active Monitoring",
        "alerts.active_alerts": "Active Alerts",
        "alerts.no_alerts": "No Alerts",
        "alerts.no_anomalies_desc": "No anomalous processes.\nSystem running normally.",
        "alerts.what_monitors": "What does smol monitor?",
        "alerts.cpu_threshold_desc": "Processes with CPU >",
        "alerts.running_time_desc": "Running for >",
        "alerts.cpu_time_desc": "CPU time >",
        "alerts.minutes": "minutes",
        "alerts.known_bloatware": "Known problematic software",
        "alerts.quick_presets": "Quick Presets",
        "alerts.cpu_threshold": "CPU Threshold",
        "alerts.min_running_time": "Minimum Running Time",
        "alerts.cpu_time_threshold": "CPU Time Threshold",
        "alerts.reset_defaults": "Reset to Default",

        // Temperature
        "temp.average": "Average",
        "temp.peak": "Peak",
        "temp.sensors": "Sensors",
        "temp.last_updated": "Last updated",
        "temp.no_sensors": "Sensors Not Available",
        "temp.no_smc_access": "Unable to access SMC to read temperature sensors.",
        "temp.why_happens": "Why does this happen?",
        "temp.smc_requires": "On Apple Silicon M4, SMC access requires elevated privileges",
        "temp.app_no_permissions": "The app doesn't have the necessary permissions to read hardware sensors",
        "temp.helper_needed": "A privileged helper may be needed (like for fans)",
        "temp.thermal_state": "Current Thermal State",
        "temp.from_macos": "(from macOS API)",

        // Fans
        "fans.no_fans": "No Fans Detected",
        "fans.no_fans_desc": "No controllable fans found. Could be a fanless Mac (MacBook Air) or missing SMC permissions.",
        "fans.mode": "Mode",
        "fans.system_control": "macOS automatic control",
        "fans.max_control": "Fans at maximum RPM",
        "fans.automax_control": "Automatic with higher minimum",
        "fans.control_disabled": "Fans currently off",
        "fans.control_mode": "Control Mode",
        "fans.fans": "Fans",
        "fans.off": "OFF",
        "fans.fan_count": "Number of fans",
        "fans.max_rpm": "Maximum RPM",
        "fans.avg_rpm": "Average RPM",
        "fans.info": "Info",
        "fans.sleep_mode": "Fans in Sleep Mode",
        "fans.sleep_desc": "Mac is cool - fans are off. You can still control them!",
        "fans.why_fans_off": "Why are fans off?",
        "fans.why_fans_off_desc": "On Apple Silicon (M1/M2/M3/M4), when temperature is low, the system turns off fans to save energy. This is normal behavior.",
        "fans.when_control_works": "Can I control them?",
        "fans.when_control_works_desc": "Yes! Select 'Max' or 'Auto Max' to start the fans. They will spin up even from 0 RPM.",
        "fans.is_problem": "Is it a problem?",
        "fans.is_problem_desc": "No! It means your Mac is running efficiently. You can force fans on anytime using the controls above.",
        "fans.cold_status": "Status: System cold, fans available",

        // System Info
        "system.hardware": "Hardware",
        "system.processor": "Processor",
        "system.cores": "Cores",
        "system.uptime": "Uptime",
        "system.host_name": "Host Name",
        "system.day": "day",
        "system.days": "days",
        "system.made_with": "Made with Swift",
        "system.version": "Version",
        "system.license": "License",
        "system.realtime_resources": "Real-time resources",

        // Memory details
        "memory.details": "Memory Details",
        "memory.tip": "On macOS, \"used\" RAM means nothing. What matters is Memory Pressure and Swap.",

        // Suspicious processes
        "processes.suspicious": "Suspicious Process(es)",
        "processes.anomalous": "Anomalous Processes",
    ]

    // MARK: - Italian Strings

    static let italianStrings: [String: String] = [
        // Tab names
        "tab.dashboard": "Dashboard",
        "tab.cpu": "CPU",
        "tab.memory": "Memoria",
        "tab.temperature": "Temperatura",
        "tab.processes": "Processi",
        "tab.ai": "Assistente AI",
        "tab.settings": "Impostazioni",
        "tab.fans": "Ventole",
        "tab.system": "Sistema",
        "tab.alerts": "Avvisi",

        // Intro Tab
        "intro.tagline": "Il monitor di sistema che non diventa il problema.",
        "intro.the_problem": "Il Problema",
        "intro.the_solution": "La Soluzione",
        "intro.bloat1_problem": "500 MB di app per dirti che hai la cache",
        "intro.bloat2_problem": "Updater che gira al 70% CPU per mesi",
        "intro.bloat3_problem": "16+ processi in background che non fanno nulla",
        "intro.solution1_title": "Memory Pressure, non GB usati",
        "intro.solution1_desc": "Su macOS i GB usati non significano nulla. La pressure sì.",
        "intro.solution2_title": "CPU in uso, chiaro e semplice",
        "intro.solution2_desc": "Quanto sta lavorando il tuo Mac, senza allarmismi.",
        "intro.solution3_title": "Swap = problema reale",
        "intro.solution3_desc": "Se c'è swap, hai davvero un problema. Altrimenti no.",
        "intro.solution4_title": "Trova i processi fantasma",
        "intro.solution4_desc": "Identifica chi sta rubando CPU da troppo tempo.",
        "intro.vs": "vs",
        "intro.size": "Dimensione",
        "intro.ram": "RAM",
        "intro.philosophy": "Filosofia",
        "intro.philosophy_desc": "smol segue il principio: un monitor di sistema che usa più risorse delle tue app è parte del problema.",
        "intro.no_bloat": "Niente bloat.",
        "intro.no_subscription": "Niente abbonamenti.",
        "intro.just_info": "Solo le info che ti servono.",
        "intro.lets_go": "Vediamo come sta il tuo Mac",
        "intro.open_dashboard": "Apri Dashboard",

        // Dashboard
        "dashboard.title": "Panoramica Sistema",
        "dashboard.cpu_usage": "Utilizzo CPU",
        "dashboard.memory_pressure": "Pressione Memoria",
        "dashboard.temperature": "Temperatura",
        "dashboard.health_score": "Stato Salute",
        "dashboard.excellent": "Eccellente",
        "dashboard.good": "Buono",
        "dashboard.moderate": "Moderato",
        "dashboard.critical": "Critico",

        // CPU
        "cpu.title": "Monitor CPU",
        "cpu.usage": "Utilizzo",
        "cpu.cores": "Core",
        "cpu.threads": "Thread",
        "cpu.frequency": "Frequenza",
        "cpu.load_average": "Carico Medio",

        // Memory
        "memory.title": "Monitor Memoria",
        "memory.used": "Usata",
        "memory.free": "Libera",
        "memory.total": "Totale",
        "memory.pressure": "Pressione",
        "memory.swap": "Swap",
        "memory.wired": "Wired",
        "memory.compressed": "Compressa",
        "memory.app_memory": "Memoria App",
        "memory.cached": "Cache",

        // Temperature
        "temp.title": "Monitor Temperatura",
        "temp.cpu": "Temperatura CPU",
        "temp.gpu": "Temperatura GPU",
        "temp.ssd": "Temperatura SSD",
        "temp.fan_speed": "Velocità Ventola",
        "temp.normal": "Normale",
        "temp.elevated": "Elevata",
        "temp.high": "Alta",
        "temp.critical": "Critica",

        // Processes
        "processes.title": "Processi",
        "processes.name": "Nome",
        "processes.pid": "PID",
        "processes.cpu": "CPU %",
        "processes.memory": "Memoria",
        "processes.status": "Stato",
        "processes.user": "Utente",
        "processes.terminate": "Termina",
        "processes.search": "Cerca processi...",
        "processes.running": "in esecuzione",
        "processes.sleeping": "in pausa",
        "processes.total": "Processi Totali",

        // AI Assistant
        "ai.title": "Assistente AI",
        "ai.chat": "Chat",
        "ai.insights": "Analisi",
        "ai.report": "Report",
        "ai.ask_placeholder": "Chiedi informazioni sul sistema...",
        "ai.send": "Invia",
        "ai.clear": "Pulisci",
        "ai.generate_report": "Genera Report",
        "ai.export": "Esporta",
        "ai.anomalies": "Anomalie Rilevate",
        "ai.advice": "Raccomandazioni",
        "ai.no_anomalies": "Nessuna anomalia rilevata",
        "ai.no_advice": "Sistema funzionante normalmente",
        "ai.ml_status": "Stato ML",
        "ai.model_trained": "Modello addestrato",
        "ai.model_training": "Addestramento in corso...",
        "ai.model_not_trained": "Modello non ancora addestrato",
        "ai.samples_collected": "campioni raccolti",
        "ai.train_model": "Addestra Modello",
        "ai.training_requires": "Richiede almeno 500 campioni",

        // Settings
        "settings.title": "Impostazioni",
        "settings.general": "Generali",
        "settings.appearance": "Aspetto",
        "settings.language": "Lingua",
        "settings.refresh_rate": "Frequenza Aggiornamento",
        "settings.notifications": "Notifiche",
        "settings.enable_notifications": "Abilita Notifiche",
        "settings.notify_high_cpu": "Avviso CPU Alta",
        "settings.notify_high_memory": "Avviso Memoria Alta",
        "settings.notify_high_temp": "Avviso Temperatura Alta",
        "settings.about": "Informazioni",
        "settings.version": "Versione",
        "settings.reset": "Ripristina Impostazioni",

        // Alerts & Messages
        "alert.high_cpu": "Rilevato utilizzo CPU elevato",
        "alert.high_memory": "Pressione memoria critica",
        "alert.high_temp": "Temperatura elevata",
        "alert.process_terminated": "Processo terminato",
        "alert.error": "Errore",
        "alert.success": "Successo",
        "alert.warning": "Attenzione",
        "alert.confirm": "Conferma",
        "alert.cancel": "Annulla",
        "alert.ok": "OK",

        // Self Monitor
        "self.title": "Consumo risorse smol",
        "self.cpu": "CPU",
        "self.memory": "Memoria",
        "self.threads": "Thread",
        "self.pid": "PID",

        // General
        "general.loading": "Caricamento...",
        "general.refresh": "Aggiorna",
        "general.close": "Chiudi",
        "general.save": "Salva",
        "general.delete": "Elimina",
        "general.edit": "Modifica",
        "general.copy": "Copia",
        "general.share": "Condividi",

        // Intro extra
        "intro.start_monitoring": "Inizia a Monitorare",
        "intro.quote1": "\"Le app di pulizia usano 500MB per dirti che il Mac è sporco.",
        "intro.quote2": "smol usa 5MB per dirti la verità.\"",

        // Overview
        "overview.in_use": "in uso",
        "overview.all_good": "Tutto ok",
        "overview.attention": "Attenzione!",
        "overview.rising": "In salita",
        "overview.falling": "In discesa",
        "overview.stable": "Stabile",
        "overview.system_healthy": "Sistema in Salute",
        "overview.warning": "Attenzione",
        "overview.critical": "Stato Critico",

        // Processes
        "processes.search_placeholder": "Cerca processo...",
        "processes.count": "processi",
        "processes.anomalies": "anomalie",
        "processes.refresh": "Aggiorna",
        "processes.cpu_time": "CPU Time",

        // Alerts
        "alerts.monitoring_active": "Monitoraggio Attivo",
        "alerts.active_alerts": "Alert Attivi",
        "alerts.no_alerts": "Nessun Alert",
        "alerts.no_anomalies_desc": "Non ci sono processi anomali.\nIl sistema sta funzionando correttamente.",
        "alerts.what_monitors": "Cosa monitora smol?",
        "alerts.cpu_threshold_desc": "Processi con CPU >",
        "alerts.running_time_desc": "In esecuzione da >",
        "alerts.cpu_time_desc": "CPU time >",
        "alerts.minutes": "minuti",
        "alerts.known_bloatware": "Software noto per essere problematico",
        "alerts.quick_presets": "Preset Rapidi",
        "alerts.cpu_threshold": "Soglia CPU",
        "alerts.min_running_time": "Tempo Minimo Esecuzione",
        "alerts.cpu_time_threshold": "Soglia CPU Time",
        "alerts.reset_defaults": "Ripristina Default",

        // Temperature
        "temp.average": "Media",
        "temp.peak": "Picco",
        "temp.sensors": "Sensori",
        "temp.last_updated": "Ultimo aggiornamento",
        "temp.no_sensors": "Sensori Non Disponibili",
        "temp.no_smc_access": "Non è stato possibile accedere al SMC per leggere i sensori temperatura.",
        "temp.why_happens": "Perché succede?",
        "temp.smc_requires": "Su Apple Silicon M4, l'accesso SMC richiede privilegi elevati",
        "temp.app_no_permissions": "L'app non ha i permessi necessari per leggere i sensori hardware",
        "temp.helper_needed": "Potrebbe essere necessario un helper privilegiato (come per le ventole)",
        "temp.thermal_state": "Thermal State Attuale",
        "temp.from_macos": "(da macOS API)",

        // Fans
        "fans.no_fans": "Nessuna Ventola Rilevata",
        "fans.no_fans_desc": "Non sono state trovate ventole controllabili. Potrebbe essere un Mac senza ventole (MacBook Air) o mancano i permessi SMC.",
        "fans.mode": "Modalità",
        "fans.system_control": "Controllo automatico macOS",
        "fans.max_control": "Ventole al massimo RPM",
        "fans.automax_control": "Automatico con minimo più alto",
        "fans.control_disabled": "Ventole attualmente spente",
        "fans.control_mode": "Modalità Controllo",
        "fans.fans": "Ventole",
        "fans.off": "SPENTE",
        "fans.fan_count": "Numero ventole",
        "fans.max_rpm": "RPM Massimo",
        "fans.avg_rpm": "RPM Medio",
        "fans.info": "Info",
        "fans.sleep_mode": "Ventole in Sleep Mode",
        "fans.sleep_desc": "Il Mac è freddo - ventole spente. Puoi comunque controllarle!",
        "fans.why_fans_off": "Perché sono spente?",
        "fans.why_fans_off_desc": "Su Apple Silicon (M1/M2/M3/M4), quando la temperatura è bassa, il sistema spegne le ventole per risparmiare energia. È un comportamento normale.",
        "fans.when_control_works": "Posso controllarle?",
        "fans.when_control_works_desc": "Sì! Seleziona 'Max' o 'Auto Max' per avviare le ventole. Partiranno anche da 0 RPM.",
        "fans.is_problem": "È un problema?",
        "fans.is_problem_desc": "No! Significa che il tuo Mac sta funzionando in modo efficiente. Puoi forzare l'avvio delle ventole in qualsiasi momento usando i controlli sopra.",
        "fans.cold_status": "Stato: Sistema freddo, ventole disponibili",

        // System Info
        "system.hardware": "Hardware",
        "system.processor": "Processore",
        "system.cores": "Core",
        "system.uptime": "Uptime",
        "system.host_name": "Nome Host",
        "system.day": "giorno",
        "system.days": "giorni",
        "system.made_with": "Fatto con Swift",
        "system.version": "Versione",
        "system.license": "Licenza",
        "system.realtime_resources": "Risorse in tempo reale",

        // Memory details
        "memory.details": "Dettaglio Memoria",
        "memory.tip": "Su macOS, la RAM \"usata\" non significa nulla. Quello che conta è la Memory Pressure e lo Swap.",

        // Suspicious processes
        "processes.suspicious": "Processo/i Sospetto/i",
        "processes.anomalous": "Processi Anomali",
    ]
}

// MARK: - SwiftUI Extension

extension String {
    /// Localized string using the shared manager (MainActor)
    @MainActor
    func localized(_ manager: LocalizationManager) -> String {
        return manager.localized(self)
    }

    /// Non-isolated version using specified language directly
    func localized(language: LocalizationManager.Language) -> String {
        return Strings.localized(self, language: language)
    }
}

// MARK: - Localized Text View

struct LocalizedText: View {
    let key: String
    @ObservedObject var localization = LocalizationManager.shared

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(localization.localized(key))
    }
}

// MARK: - Language Picker View

struct LanguagePickerView: View {
    @ObservedObject var localization = LocalizationManager.shared

    var body: some View {
        Picker(localization.localized("settings.language"), selection: $localization.currentLanguage) {
            ForEach(LocalizationManager.Language.allCases) { language in
                HStack {
                    Text(language.flag)
                    Text(language.displayName)
                }
                .tag(language)
            }
        }
        .pickerStyle(.menu)
    }
}
