// MeetCaptureLauncher.m — Professional native macOS menu bar app
// Draws a proper microphone icon, clean menu, reliable daemon management
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
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    return dict ?: @{};
}

NSDictionary *loadConfig(void) {
    NSData *d = [NSData dataWithContentsOfFile:configFile()];
    if (!d) return @{};
    NSError *e = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    return dict ?: @{};
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

BOOL isAlive(NSInteger pid) {
    return pid > 0 && kill((int)pid, 0) == 0;
}

// ── Icon Drawing ────────────────────────────────────────────────────────────

NSImage *micIcon(NSColor *color, BOOL recording) {
    CGFloat size = 16;
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [img lockFocus];
    
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextSetAllowsAntialiasing(ctx, YES);
    CGContextSetShouldAntialias(ctx, YES);
    
    [color setStroke];
    [color setFill];
    
    CGFloat w = size;
    CGFloat h = size;
    CGFloat cx = w / 2;
    
    // Mic body (rounded rect)
    CGFloat micW = w * 0.28;
    CGFloat micH = h * 0.4;
    CGFloat micX = cx - micW / 2;
    CGFloat micY = h * 0.15;
    CGFloat radius = micW / 2;
    
    NSBezierPath *mic = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(micX, micY, micW, micH)
                                                         xRadius:radius yRadius:radius];
    [mic setLineWidth:1.2];
    [mic stroke];
    
    // Mic arc
    CGFloat arcR = w * 0.22;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, micY + micH * 0.3)
                                     radius:arcR
                                 startAngle:180 endAngle:0];
    [arc setLineWidth:1.2];
    [arc stroke];
    
    // Mic stand (vertical line)
    NSBezierPath *stand = [NSBezierPath bezierPath];
    [stand moveToPoint:NSMakePoint(cx, micY + micH + arcR * 0.5)];
    [stand lineToPoint:NSMakePoint(cx, h * 0.85)];
    [stand setLineWidth:1.2];
    [stand stroke];
    
    // Mic base (horizontal line)
    NSBezierPath *base = [NSBezierPath bezierPath];
    CGFloat baseW = w * 0.3;
    [base moveToPoint:NSMakePoint(cx - baseW / 2, h * 0.85)];
    [base lineToPoint:NSMakePoint(cx + baseW / 2, h * 0.85)];
    [base setLineWidth:1.5];
    [base stroke];
    
    // Recording indicator (red dot)
    if (recording) {
        [[NSColor systemRedColor] setFill];
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(w * 0.65, h * 0.6, w * 0.25, h * 0.25)];
        [dot fill];
    }
    
    [img unlockFocus];
    [img setTemplate:NO];
    return img;
}

// ── App Delegate ────────────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *menu;
@property (strong) NSTimer *pollTimer;
@property (strong) NSTask *daemonTask;
@property (strong) NSMenuItem *statusItem1;
@property (strong) NSMenuItem *statusItem2;
@property (strong) NSMenuItem *stopItem;
@property (assign) BOOL isRecording;
@property (assign) BOOL isRunning;
@property (copy) NSString *meetingTitle;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Status bar item with fixed width
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    [[self.statusItem button] setImage:micIcon([NSColor labelColor], NO)];
    
    // Menu
    self.menu = [[NSMenu alloc] init];
    [self.menu setAutoenablesItems:NO];
    
    // Status line
    self.statusItem1 = [[NSMenuItem alloc] initWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    [self.statusItem1 setEnabled:NO];
    [self.menu addItem:self.statusItem1];
    
    // Meeting line
    self.statusItem2 = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [self.statusItem2 setEnabled:NO];
    [self.menu addItem:self.statusItem2];
    
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    // Stop Recording
    self.stopItem = [[NSMenuItem alloc] initWithTitle:@"Stop Recording" action:@selector(stopRecording) keyEquivalent:@""];
    [self.stopItem setEnabled:NO];
    [self.menu addItem:self.stopItem];
    
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    // Open Transcripts
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open Transcripts Folder" action:@selector(openTranscripts) keyEquivalent:@""];
    [self.menu addItem:openItem];
    
    // View Log
    NSMenuItem *logItem = [[NSMenuItem alloc] initWithTitle:@"View Log" action:@selector(viewLog) keyEquivalent:@""];
    [self.menu addItem:logItem];
    
    // Settings
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings..." action:@selector(showSettings) keyEquivalent:@","];
    [self.menu addItem:settingsItem];
    
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    // Quit
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit MeetCapture" action:@selector(quitApp) keyEquivalent:@"q"];
    [self.menu addItem:quitItem];
    
    [self.statusItem setMenu:self.menu];
    
    // Auto-start daemon
    NSDictionary *cfg = loadConfig();
    if (![cfg objectForKey:@"auto_start"] || [[cfg objectForKey:@"auto_start"] boolValue]) {
        [self startDaemon];
    }
    
    // Poll every 3s
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)poll {
    NSDictionary *state = loadState();
    NSInteger pid = readPid();
    BOOL alive = (pid > 0 && isAlive(pid)) || (self.daemonTask && [self.daemonTask isRunning]);
    
    self.isRecording = [[state objectForKey:@"recording"] boolValue];
    self.meetingTitle = [state objectForKey:@"title"] ?: @"";
    self.isRunning = alive;
    
    if (self.isRecording) {
        [[self.statusItem button] setImage:micIcon([NSColor systemRedColor], YES)];
        [self.statusItem1 setTitle:@"Recording"];
        [self.statusItem2 setTitle:self.meetingTitle];
        [self.stopItem setEnabled:YES];
    } else if (alive) {
        [[self.statusItem button] setImage:micIcon([NSColor labelColor], NO)];
        [self.statusItem1 setTitle:@"Waiting for meeting"];
        [self.statusItem2 setTitle:@""];
        [self.stopItem setEnabled:NO];
    } else {
        [[self.statusItem button] setImage:micIcon([NSColor systemOrangeColor], NO)];
        [self.statusItem1 setTitle:@"Daemon stopped"];
        [self.statusItem2 setTitle:@""];
        [self.stopItem setEnabled:NO];
    }
}

- (void)startDaemon {
    NSInteger pid = readPid();
    if (pid > 0 && isAlive(pid)) return;
    
    NSString *python = findPython();
    NSString *script = daemonScript();
    
    self.daemonTask = [[NSTask alloc] init];
    [self.daemonTask setLaunchPath:python];
    [self.daemonTask setArguments:@[script, @"--daemon"]];
    
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
    
    @try {
        [self.daemonTask launch];
    } @catch (NSException *e) {
        NSLog(@"Daemon start failed: %@", e.reason);
    }
}

- (void)stopRecording {
    NSString *python = findPython();
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:python];
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
    NSString *log = [meetingsDir() stringByAppendingPathComponent:@".daemon.log"];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:log]];
}

- (void)showSettings {
    NSDictionary *cfg = loadConfig();
    NSString *dir = [cfg objectForKey:@"transcript_dir"] ?: @"Default";
    
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"MeetCapture Settings"];
    [alert setInformativeText:[NSString stringWithFormat:@"Transcript directory:\n%@\n\nClick 'Change' to select a different folder.", dir]];
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
            [ok setInformativeText:[NSString stringWithFormat:@"Transcripts will be saved to:\n%@", newDir]];
            [ok runModal];
        }
    }
}

- (void)quitApp {
    if (self.daemonTask && [self.daemonTask isRunning]) {
        [self.daemonTask terminate];
    }
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
