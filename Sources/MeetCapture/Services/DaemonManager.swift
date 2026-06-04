// DaemonManager.swift
// MeetCapture v4 — SMAppService daemon lifecycle management

import ServiceManagement
import os.log
import Foundation

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
            // Try SMAppService first
            do {
                try agentService.register()
                logger.info("Daemon registered successfully via SMAppService")
                refreshStatus()
            } catch {
                logger.warning("SMAppService registration failed: \(error.localizedDescription)")
                logger.info("Falling back to launchctl bootstrap")
                // Fallback: use launchctl directly
                registerViaLaunchctl()
            }
            
        case .enabled:
            logger.info("Daemon already registered and enabled")
            
        case .requiresApproval:
            logger.warning("Daemon requires user approval in System Settings")
            openSystemSettings()
            
        case .notFound:
            logger.warning("Daemon plist not found by SMAppService, trying direct registration")
            registerViaLaunchctl()
            
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
    
    // MARK: - Fallback Registration
    
    /// Register daemon via launchctl bootstrap (fallback when SMAppService fails)
    private func registerViaLaunchctl() {
        guard let bundlePath = Bundle.main.bundlePath as NSString? else {
            logger.error("Cannot determine bundle path")
            return
        }
        let srcPlist = "\(bundlePath)/Contents/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist"
        let dstPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist"
        
        guard FileManager.default.fileExists(atPath: srcPlist) else {
            logger.error("Daemon plist not found at: \(srcPlist)")
            return
        }
        
        // Copy plist to user's LaunchAgents directory with absolute paths
        let pythonPath = "\(bundlePath)/Contents/Resources/meet-daemon"
        let logPath = "/tmp/meetcapture-daemon.log"
        
        // Read plist and update paths
        guard var plistData = NSMutableDictionary(contentsOfFile: srcPlist) as? [String: Any] else {
            logger.error("Cannot read daemon plist")
            return
        }
        
        // Replace BundleProgram with ProgramArguments using absolute paths
        plistData.removeValue(forKey: "BundleProgram")
        plistData["ProgramArguments"] = [pythonPath]
        plistData["StandardOutPath"] = logPath
        plistData["StandardErrorPath"] = logPath
        
        // Write updated plist
        let updatedPlist = NSDictionary(dictionary: plistData)
        guard updatedPlist.write(toFile: dstPlist, atomically: true) else {
            logger.error("Cannot write daemon plist to \(dstPlist)")
            return
        }
        
        // Load via launchctl
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", dstPlist]
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logger.info("Daemon registered via launchctl load")
            } else {
                logger.warning("launchctl load exited: \(process.terminationStatus)")
            }
        } catch {
            logger.warning("launchctl load failed: \(error.localizedDescription)")
        }
        
        refreshStatus()
    }
}
