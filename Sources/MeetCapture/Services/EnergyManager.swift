// EnergyManager.swift
// MeetCapture v4 — Power & memory management

import Foundation
import os.log

/// Manages energy assertions and memory pressure monitoring
final class EnergyManager {
    private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "energy")
    private var activity: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    
    enum MemoryLevel {
        case normal
        case warning
        case critical
    }
    
    var onMemoryPressure: ((MemoryLevel) -> Void)?
    
    // MARK: - Energy Assertions
    
    /// Prevent idle sleep and disable App Nap during recording
    func beginRecordingActivity() {
        guard activity == nil else { return }
        
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording Google Meet audio"
        )
        logger.info("Recording energy assertion began")
    }
    
    /// Release energy assertion when recording stops
    func endRecordingActivity() {
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            logger.info("Recording energy assertion ended")
        }
    }
    
    // MARK: - Memory Pressure
    
    /// Start monitoring memory pressure
    func startMemoryMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = self.memoryPressureSource?.data ?? []
            
            if event.contains(.critical) {
                self.logger.critical("Memory pressure CRITICAL")
                self.onMemoryPressure?(.critical)
            } else if event.contains(.warning) {
                self.logger.warning("Memory pressure warning")
                self.onMemoryPressure?(.warning)
            }
        }
        
        memoryPressureSource?.resume()
        logger.info("Memory pressure monitoring started")
    }
    
    /// Stop monitoring memory pressure
    func stopMemoryMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }
    
    // MARK: - Memory Info
    
    /// Get available memory in GB
    func availableMemoryGB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_073_741_824
    }
    
    /// Get total physical memory in GB
    func totalMemoryGB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
    
    /// Check current memory level
    func currentMemoryLevel() -> MemoryLevel {
        let total = totalMemoryGB()
        let used = availableMemoryGB()
        let ratio = used / total
        
        if ratio > 0.85 {
            return .critical
        } else if ratio > 0.70 {
            return .warning
        }
        return .normal
    }
    
    deinit {
        stopMemoryMonitoring()
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
