// DaemonManager.swift
// MeetCapture v4 — SMAppService daemon lifecycle management

import ServiceManagement
import os.log

/// Manages the background daemon via SMAppService
@MainActor
final class DaemonManager: ObservableObject {
    private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "daemon")
    
    // The daemon plist must be inside the app bundle at:
    // Contents/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist
    private let agentService = SMAppService.agent(plistName: "com.maatwork.meetcapture.daemon")
    
    @Published private(set) var status: SMAppService.Status = .notRegistered
    
    // MARK: - Registration
    
    /// Register daemon if not already registered
    func registerIfNeeded() {
        refreshStatus()
        
        switch status {
        case .notRegistered:
            do {
                try agentService.register()
                logger.info("Daemon registered successfully")
                refreshStatus()
            } catch {
                logger.error("Failed to register daemon: \(error.localizedDescription)")
            }
            
        case .enabled:
            logger.info("Daemon already registered and enabled")
            
        case .requiresApproval:
            logger.warning("Daemon requires user approval in System Settings")
            openSystemSettings()
            
        case .notFound:
            logger.error("Daemon plist not found in app bundle")
            
        @unknown default:
            logger.warning("Unknown daemon status: \(String(describing: self.status))")
        }
    }
    
    /// Unregister daemon
    func unregister() {
        do {
            try agentService.unregister()
            logger.info("Daemon unregistered")
            refreshStatus()
        } catch {
            logger.error("Failed to unregister daemon: \(error.localizedDescription)")
        }
    }
    
    /// Toggle registration
    func toggle() {
        if status == .enabled {
            unregister()
        } else {
            registerIfNeeded()
        }
    }
    
    // MARK: - Status
    
    func refreshStatus() {
        status = agentService.status
    }
    
    var isEnabled: Bool { status == .enabled }
    
    var statusDescription: String {
        switch status {
        case .enabled: return "Running"
        case .notRegistered: return "Not registered"
        case .notFound: return "Plist not found in bundle"
        case .requiresApproval: return "Needs approval"
        @unknown default: return "Unknown"
        }
    }
    
    // MARK: - System Settings
    
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
