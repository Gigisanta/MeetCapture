// MeetCaptureLauncher.m — Native macOS menu bar app with SF Symbols
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

// ── Paths ───────────────────────────────────────────────────────────────────
NSString *homeDir(void) { return NSHomeDirectory(); }
NSString *meetingsDir(void) { return [homeDir() stringByAppendingPathComponent:@"meetings"]; }
NSString *stateFile(void) { return [meetingsDir() stringByAppendingPathComponent:@".daemon_state.json"]; }
NSString *pidFile(void) { return [meetingsDir() stringByAppendingPathComponent:@".daemon.pid"]; }
NSString *configFile(void) { return [homeDir() stringByAppendingPathComponent:@".meetcapture.json"]; }
NSString *daemonScript(void) {
    NSString *inBundle = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"meet-daemon.py"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:inBundle]) return inBundle;
    return [meetingsDir() stringByAppendingPathComponent:@"meet-daemon.py"];
}
NSString *findPython(void) {
    NSString *venv = [meetingsDir() stringByAppendingPathComponent:@".app-venv/bin/python3"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:venv]) return venv;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/opt/homebrew/bin/python3"]) return @"/opt/homebrew/bin/python3";
    return @"/usr/bin/python3";
}
NSDictionary *loadState(void) {
    NSData *d = [NSData dataWithContentsOfFile:stateFile()];
    if (!d) return @{};
    NSError *e = nil;
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:&e] ?: @{};
}
NSDictionary *loadConfig(void) {
    NSData *d = [NSData dataWithContentsOfFile:configFile()];
    if (!d) return @{};
    NSError *e = nil;
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:&e] ?: @{};
}
void saveConfig(NSDictionary *cfg) {
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted error:&e];
    if (d) [d writeToFile:configFile() atomically:YES];
}
NSInteger readPid(void) {
    NSString *s = [NSString stringWithContentsOfFile:pidFile() encoding:NSUTF8StringEncoding error:nil];
    return s ? [s integerValue] : 0;
}
BOOL isAlive(NSInteger pid) { return pid > 0 && kill((int)pid, 0) == 0; }

// ── SF Symbol Icon Helper ───────────────────────────────────────────────────

NSImage *sfIcon(NSString *symbolName, NSColor *tintColor) {
    // Use SF Symbols (available macOS 11+)
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                            accessibilityDescription:@"MeetCapture"];
    if (img) {
        // Configure for template rendering
        [img setTemplate:YES];
        
        // Create a colored version using NSTextAttachment
        if (tintColor) {
            NSSize size = NSMakeSize(18, 18);
            NSImage *colored = [[NSImage alloc] initWithSize:size];
            [colored lockFocus];
            
            // Draw the symbol
            NSRect rect = NSMakeRect(0, 0, size.width, size.height);
            [img drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
            
            // Apply tint
            [tintColor set];
            NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
            
            [colored unlockFocus];
            [colored setTemplate:NO];
            return colored;
        }
        return img;
    }
    
    // Fallback: simple text
    return nil;
}

// ── App Delegate ────────────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *menu;
@property (strong) NSTimer *pollTimer;
@property (strong) NSTask *daemonTask;
@property (strong) NSMenuItem *statusLine;
@property (strong) NSMenuItem *meetingLine;
@property (strong) NSMenuItem *stopItem;
@property (assign) BOOL isRecording;
@property (assign) BOOL isRunning;
@property (copy) NSString *meetingTitle;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Status bar item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    [self updateIcon:NO recording:NO];
    
    // Menu
    self.menu = [[NSMenu alloc] init];
    [self.menu setAutoenablesItems:NO];
    
    // Status
    self.statusLine = [self menuItem:@"Starting..." enabled:NO];
    self.meetingLine = [self menuItem:@"" enabled:NO];
    [self.menu addItem:self.statusLine];
    [self.menu addItem:self.meetingLine];
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    // Actions
    self.stopItem = [self menuItem:@"Stop Recording" action:@selector(stopRecording) key:@"" enabled:NO];
    [self.menu addItem:self.stopItem];
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    [self.menu addItem:[self menuItem:@"Open Transcripts Folder" action:@selector(openTranscripts) key:@"" enabled:YES]];
    [self.menu addItem:[self menuItem:@"View Log" action:@selector(viewLog) key:@"" enabled:YES]];
    [self.menu addItem:[self menuItem:@"Settings..." action:@selector(showSettings) key:@"," enabled:YES]];
    [self.menu addItem:[NSMenuItem separatorItem]];
    [self.menu addItem:[self menuItem:@"Quit MeetCapture" action:@selector(quitApp) key:@"q" enabled:YES]];
    
    [self.statusItem setMenu:self.menu];
    
    // Auto-start daemon
    NSDictionary *cfg = loadConfig();
    if (![cfg objectForKey:@"auto_start"] || [[cfg objectForKey:@"auto_start"] boolValue]) {
        [self startDaemon];
    }
    
    // Poll every 3s
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (NSMenuItem *)menuItem:(NSString *)title enabled:(BOOL)enabled {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    [item setEnabled:enabled];
    return item;
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key enabled:(BOOL)enabled {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    [item setEnabled:enabled];
    return item;
}

- (void)updateIcon:(BOOL)running recording:(BOOL)recording {
    NSImage *img = nil;
    
    if (recording) {
        // Red mic.fill when recording
        img = sfIcon(@"mic.fill", [NSColor systemRedColor]);
    } else if (running) {
        // Default mic when idle
        img = sfIcon(@"mic", [NSColor labelColor]);
    } else {
        // Orange mic.slash when stopped
        img = sfIcon(@"mic.slash", [NSColor systemOrangeColor]);
    }
    
    if (img) {
        [[self.statusItem button] setImage:img];
    } else {
        // Fallback to text if SF Symbols not available
        [[self.statusItem button] setTitle:recording ? @"◉" : (running ? @"●" : @"⚠")];
    }
}

- (void)poll {
    NSDictionary *state = loadState();
    NSInteger pid = readPid();
    BOOL alive = (pid > 0 && isAlive(pid)) || (self.daemonTask && [self.daemonTask isRunning]);
    
    self.isRecording = [[state objectForKey:@"recording"] boolValue];
    self.meetingTitle = [state objectForKey:@"title"] ?: @"";
    self.isRunning = alive;
    
    [self updateIcon:alive recording:self.isRecording];
    
    if (self.isRecording) {
        [self.statusLine setTitle:@"Recording"];
        [self.meetingLine setTitle:self.meetingTitle];
        [self.stopItem setEnabled:YES];
    } else if (alive) {
        [self.statusLine setTitle:@"Waiting for meeting"];
        [self.meetingLine setTitle:@""];
        [self.stopItem setEnabled:NO];
    } else {
        [self.statusLine setTitle:@"Daemon stopped"];
        [self.meetingLine setTitle:@""];
        [self.stopItem setEnabled:NO];
    }
}

- (void)startDaemon {
    NSInteger pid = readPid();
    if (pid > 0 && isAlive(pid)) return;
    
    self.daemonTask = [[NSTask alloc] init];
    [self.daemonTask setLaunchPath:findPython()];
    [self.daemonTask setArguments:@[daemonScript(), @"--daemon"]];
    
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
    [env setObject:@"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" forKey:@"PATH"];
    [env setObject:@"1" forKey:@"PYTHONUNBUFFERED"];
    [self.daemonTask setEnvironment:env];
    
    NSString *logPath = [meetingsDir() stringByAppendingPathComponent:@".daemon.log"];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *logH = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [logH seekToEndOfFile];
    [self.daemonTask setStandardOutput:logH];
    [self.daemonTask setStandardError:logH];
    
    @try { [self.daemonTask launch]; }
    @catch (NSException *e) { NSLog(@"Daemon failed: %@", e.reason); }
}

- (void)stopRecording {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:findPython()];
    [task setArguments:@[daemonScript(), @"--stop"]];
    [task launch];
    [task waitUntilExit];
}

- (void)openTranscripts {
    NSDictionary *cfg = loadConfig();
    NSString *dir = [cfg objectForKey:@"transcript_dir"];
    if (!dir) dir = [@"~/.hermes/TechPartners/MaatWork/meetings/transcripts" stringByExpandingTildeInPath];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
}

- (void)viewLog {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[meetingsDir() stringByAppendingPathComponent:@".daemon.log"]]];
}

- (void)showSettings {
    NSDictionary *cfg = loadConfig();
    NSString *dir = [cfg objectForKey:@"transcript_dir"] ?: @"Default location";
    
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"MeetCapture Settings"];
    [alert setInformativeText:[NSString stringWithFormat:@"Transcript folder:\n%@\n\nClick 'Change' to pick a different folder.", dir]];
    [alert addButtonWithTitle:@"Change Folder"];
    [alert addButtonWithTitle:@"Close"];
    
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        [panel setCanChooseDirectories:YES];
        [panel setCanChooseFiles:NO];
        [panel setAllowsMultipleSelection:NO];
        
        if ([panel runModal] == NSModalResponseOK) {
            NSString *newDir = [[[panel URLs] objectAtIndex:0] path];
            NSMutableDictionary *newCfg = [NSMutableDictionary dictionaryWithDictionary:cfg];
            [newCfg setObject:newDir forKey:@"transcript_dir"];
            saveConfig(newCfg);
            
            NSAlert *ok = [[NSAlert alloc] init];
            [ok setMessageText:@"Saved"];
            [ok setInformativeText:[NSString stringWithFormat:@"Transcripts → %@", newDir]];
            [ok runModal];
        }
    }
}

- (void)quitApp {
    if (self.daemonTask && [self.daemonTask isRunning]) [self.daemonTask terminate];
    [NSApp terminate:nil];
}

@end

// ── Main ────────────────────────────────────────────────────────────────────
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
