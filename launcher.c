// MeetCapture launcher — compiled binary for macOS .app bundle
// This binary finds the Python venv and launches the app
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    char exe_path[4096];
    uint32_t size = sizeof(exe_path);
    _NSGetExecutablePath(exe_path, &size);
    
    // Navigate: Contents/MacOS/MeetCapture → Contents/Resources
    char *macos_dir = dirname(exe_path);          // .../Contents/MacOS
    char *contents_dir = dirname(macos_dir);       // .../Contents
    char resources[4096];
    snprintf(resources, sizeof(resources), "%s/Resources", contents_dir);
    
    // Navigate: .../Contents → .../ (app bundle root) → parent (where .app lives)
    char app_bundle[4096];
    strncpy(app_bundle, contents_dir, sizeof(app_bundle));
    // Go up from Contents to .app bundle, then up to parent dir
    char *last_slash = strrchr(app_bundle, '/');
    if (last_slash) *last_slash = '\0';  // now points to .app bundle
    last_slash = strrchr(app_bundle, '/');
    if (last_slash) *last_slash = '\0';  // now points to parent of .app
    
    // Venv is at <parent>/.app-venv/bin/python3
    char venv_python[4096];
    snprintf(venv_python, sizeof(venv_python), "%s/.app-venv/bin/python3", app_bundle);
    
    // Main script
    char script[4096];
    snprintf(script, sizeof(script), "%s/MeetCaptureApp.py", resources);
    
    // Set environment
    setenv("PYTHONUNBUFFERED", "1", 1);
    setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", 1);
    
    // Try venv Python first (has rumps installed)
    if (access(venv_python, X_OK) == 0) {
        execl(venv_python, "python3", script, NULL);
    }
    
    // Fallback: try common Python locations
    const char *candidates[] = {
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        if (access(candidates[i], X_OK) == 0) {
            execl(candidates[i], "python3", script, NULL);
        }
    }
    
    fprintf(stderr, "MeetCapture: No Python3 found\n");
    return 1;
}
