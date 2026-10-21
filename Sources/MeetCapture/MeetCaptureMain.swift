// MeetCaptureMain.swift
// Executable entry point. Everything else lives in MeetCaptureCore so it can
// be unit-tested with `swift test`.

import MeetCaptureCore

@main
enum MeetCaptureMain {
    @MainActor
    static func main() {
        if TranscriptionWorker.runIfRequested() { return }
        if ModelPrefetch.runIfRequested() { return }
        if RealPipelineCheck.runIfRequested() { return }
        if PopoverSnapshot.runIfRequested() { return }
        MeetCaptureApp.main()
    }
}
