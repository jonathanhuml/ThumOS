#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/types.h>
#import <unistd.h>

static NSString * const THDaemonLabel = @"io.thumos.daemon";
static int gInstanceLockFD = -1;

@interface THTaskResult : NSObject
@property(nonatomic) int status;
@property(nonatomic, copy) NSString *output;
@end

@implementation THTaskResult
@end

static NSString *THExpandTilde(NSString *path) {
    return [path stringByExpandingTildeInPath];
}

static NSString *THLaunchDomain(void) {
    return [NSString stringWithFormat:@"gui/%u", getuid()];
}

static NSString *THLaunchServiceTarget(void) {
    return [NSString stringWithFormat:@"%@/%@", THLaunchDomain(), THDaemonLabel];
}

static THTaskResult *THRunTask(NSString *launchPath, NSArray<NSString *> *arguments) {
    THTaskResult *result = [[THTaskResult alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = arguments;
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        result.status = task.terminationStatus;
        result.output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    } @catch (NSException *exception) {
        result.status = 127;
        result.output = exception.reason ?: @"Task launch failed.";
    }

    return result;
}

static NSString *THBundledDaemonPath(void) {
    NSString *executableDirectory = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    NSString *bundledDaemon = [executableDirectory stringByAppendingPathComponent:@"thumosd"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:bundledDaemon]) {
        return bundledDaemon;
    }

    NSString *developmentDaemon = [@"build/thumosd" stringByStandardizingPath];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:developmentDaemon]) {
        return developmentDaemon;
    }

    return bundledDaemon;
}

static NSString *THLaunchAgentPath(void) {
    return THExpandTilde(@"~/Library/LaunchAgents/io.thumos.daemon.plist");
}

static NSString *THLogDirectory(void) {
    return THExpandTilde(@"~/Library/Logs/ThumOS");
}

static NSString *THApplicationSupportDirectory(void) {
    return THExpandTilde(@"~/Library/Application Support/ThumOS");
}

static BOOL THAcquireSingleInstanceLock(NSError **error) {
    NSString *directory = THApplicationSupportDirectory();
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:error]) {
        return NO;
    }

    NSString *lockPath = [directory stringByAppendingPathComponent:@"thumos-menu.lock"];
    int lockFD = open([lockPath fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (lockFD == -1) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open lock file at %@", lockPath]}];
        }
        return NO;
    }

    if (flock(lockFD, LOCK_EX | LOCK_NB) == -1) {
        close(lockFD);
        return NO;
    }

    ftruncate(lockFD, 0);
    dprintf(lockFD, "%d\n", getpid());
    gInstanceLockFD = lockFD;
    return YES;
}

static NSString *THDatabasePath(void) {
    return [THApplicationSupportDirectory() stringByAppendingPathComponent:@"events.sqlite3"];
}

static NSString *THRunSQLite(NSArray<NSString *> *arguments) {
    NSString *databasePath = THDatabasePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:databasePath]) {
        return @"";
    }

    NSMutableArray<NSString *> *taskArguments = [NSMutableArray arrayWithArray:arguments];
    if (taskArguments.count == 0) {
        [taskArguments addObject:databasePath];
    } else {
        [taskArguments insertObject:databasePath atIndex:taskArguments.count - 1];
    }
    THTaskResult *result = THRunTask(@"/usr/bin/sqlite3", taskArguments);
    if (result.status != 0) {
        return result.output.length > 0 ? result.output : @"Could not read events.";
    }

    return result.output;
}

static NSString *THRecentEventsText(void) {
    NSString *databasePath = THDatabasePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:databasePath]) {
        return @"No data recorded yet.";
    }

    NSString *query =
        @"select occurred_at_utc as time, device_name as device, command_id as command, event_type as event "
         "from input_events "
         "where source = 'hid' "
         "order by id desc "
         "limit 200;";
    NSString *output = THRunSQLite(@[@"-header", @"-column", query]);
    NSString *trimmed = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? output : @"No data recorded yet.";
}

static NSString *THEventsCSVText(void) {
    NSString *query =
        @"select occurred_at_utc as time, source, device_name as device, command_id as command, event_type as event, active_app_bundle_id as active_app "
         "from input_events "
         "where source = 'hid' "
         "order by id;";
    return THRunSQLite(@[@"-header", @"-csv", query]);
}

static NSString *THDefaultExportFilename(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd-HHmmss";
    return [NSString stringWithFormat:@"thumos-events-%@.csv", [formatter stringFromDate:[NSDate date]]];
}

@interface ThumOSMenuController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) NSWindow *mainWindow;
@property(nonatomic, strong) NSSwitch *popoverRecordingSwitch;
@property(nonatomic, strong) NSSwitch *windowRecordingSwitch;
@property(nonatomic, strong) NSTextField *popoverStatusLabel;
@property(nonatomic, strong) NSTextField *windowStatusLabel;
@property(nonatomic, strong) NSWindow *dataWindow;
@property(nonatomic, strong) NSTextView *dataTextView;
@property(nonatomic, strong) NSTask *recorderTask;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic) BOOL updatingSwitch;
@end

@implementation ThumOSMenuController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildApplicationMenu];
    [self buildStatusItem];
    [self buildPopover];
    [self buildMainWindow];
    [self disableLaunchAgentRecorder];
    [self refreshStatus];
    [self showMainWindow:nil];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(refreshStatus)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self stopRecording:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    [self showMainWindow:nil];
    return YES;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (void)buildApplicationMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"ThumOS"];
    NSMenuItem *showItem = [[NSMenuItem alloc] initWithTitle:@"Show ThumOS" action:@selector(showMainWindow:) keyEquivalent:@""];
    showItem.target = self;
    [appMenu addItem:showItem];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit ThumOS" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [appMenu addItem:quitItem];

    appMenuItem.submenu = appMenu;
    NSApp.mainMenu = mainMenu;
}

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"ThumOS";
    self.statusItem.button.toolTip = @"ThumOS recorder";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
}

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame font:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:string];
    label.frame = frame;
    label.font = font;
    label.textColor = color ?: [NSColor labelColor];
    return label;
}

- (void)buildPopover {
    NSViewController *controller = [[NSViewController alloc] init];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 172)];

    NSTextField *title = [self labelWithString:@"ThumOS"
                                         frame:NSMakeRect(16, 134, 150, 24)
                                          font:[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold]
                                         color:nil];
    [view addSubview:title];

    NSTextField *recording = [self labelWithString:@"Recording"
                                             frame:NSMakeRect(16, 100, 120, 18)
                                              font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                             color:nil];
    [view addSubview:recording];

    self.popoverRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(190, 94, 50, 28)];
    self.popoverRecordingSwitch.target = self;
    self.popoverRecordingSwitch.action = @selector(toggleRecording:);
    [view addSubview:self.popoverRecordingSwitch];

    self.popoverStatusLabel = [self labelWithString:@"Off"
                                              frame:NSMakeRect(16, 76, 224, 16)
                                               font:[NSFont systemFontOfSize:11]
                                              color:[NSColor secondaryLabelColor]];
    [view addSubview:self.popoverStatusLabel];

    NSButton *showButton = [NSButton buttonWithTitle:@"Open App" target:self action:@selector(showMainWindow:)];
    showButton.frame = NSMakeRect(14, 8, 96, 24);
    [view addSubview:showButton];

    NSButton *dataButton = [NSButton buttonWithTitle:@"Show Data" target:self action:@selector(showData:)];
    dataButton.frame = NSMakeRect(116, 8, 86, 24);
    [view addSubview:dataButton];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export" target:self action:@selector(exportCSV:)];
    exportButton.frame = NSMakeRect(14, 42, 74, 24);
    [view addSubview:exportButton];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearEvents:)];
    clearButton.frame = NSMakeRect(94, 42, 64, 24);
    [view addSubview:clearButton];

    controller.view = view;
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = controller;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.delegate = self;
}

- (void)buildMainWindow {
    NSRect frame = NSMakeRect(0, 0, 420, 260);
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.mainWindow.title = @"ThumOS";
    self.mainWindow.delegate = self;
    self.mainWindow.releasedWhenClosed = NO;
    [self.mainWindow center];

    NSView *content = [[NSView alloc] initWithFrame:frame];
    self.mainWindow.contentView = content;

    NSTextField *title = [self labelWithString:@"ThumOS"
                                         frame:NSMakeRect(24, 202, 220, 28)
                                          font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                         color:nil];
    [content addSubview:title];

    NSTextField *subtitle = [self labelWithString:@"Creator Micro recorder"
                                            frame:NSMakeRect(24, 178, 250, 18)
                                             font:[NSFont systemFontOfSize:12]
                                            color:[NSColor secondaryLabelColor]];
    [content addSubview:subtitle];

    NSTextField *recording = [self labelWithString:@"Recording"
                                             frame:NSMakeRect(24, 130, 150, 20)
                                              font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                             color:nil];
    [content addSubview:recording];

    self.windowRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(344, 124, 50, 28)];
    self.windowRecordingSwitch.target = self;
    self.windowRecordingSwitch.action = @selector(toggleRecording:);
    [content addSubview:self.windowRecordingSwitch];

    self.windowStatusLabel = [self labelWithString:@"Off"
                                             frame:NSMakeRect(24, 106, 360, 18)
                                              font:[NSFont systemFontOfSize:12]
                                             color:[NSColor secondaryLabelColor]];
    [content addSubview:self.windowStatusLabel];

    NSTextField *databaseLabel = [self labelWithString:@"Data"
                                                 frame:NSMakeRect(24, 70, 80, 18)
                                                  font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                                 color:nil];
    [content addSubview:databaseLabel];

    NSButton *showDataButton = [NSButton buttonWithTitle:@"Show Data" target:self action:@selector(showData:)];
    showDataButton.frame = NSMakeRect(20, 42, 92, 28);
    [content addSubview:showDataButton];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export CSV" target:self action:@selector(exportCSV:)];
    exportButton.frame = NSMakeRect(120, 42, 96, 28);
    [content addSubview:exportButton];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear Events" target:self action:@selector(clearEvents:)];
    clearButton.frame = NSMakeRect(286, 43, 110, 28);
    [content addSubview:clearButton];
}

- (void)togglePopover:(id)sender {
    (void)sender;
    if (self.popover.shown) {
        [self.popover close];
    } else {
        [self refreshStatus];
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
    }
}

- (void)showMainWindow:(id)sender {
    (void)sender;
    [self.popover close];
    [self refreshStatus];
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)writeLaunchAgent:(NSError **)error {
    NSString *plistPath = THLaunchAgentPath();
    NSString *logDirectory = THLogDirectory();
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if (![fileManager createDirectoryAtPath:[plistPath stringByDeletingLastPathComponent]
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:error]) {
        return NO;
    }

    if (![fileManager createDirectoryAtPath:logDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:error]) {
        return NO;
    }

    NSDictionary *plist = @{
        @"Label": THDaemonLabel,
        @"ProgramArguments": @[
            THBundledDaemonPath(),
            @"--hid-record",
            @"--hid-product",
            @"Creator"
        ],
        @"RunAtLoad": @YES,
        @"KeepAlive": @YES,
        @"StandardOutPath": [logDirectory stringByAppendingPathComponent:@"thumosd.out.log"],
        @"StandardErrorPath": [logDirectory stringByAppendingPathComponent:@"thumosd.err.log"]
    };

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    if (data == nil) {
        return NO;
    }

    return [data writeToFile:plistPath options:NSDataWritingAtomic error:error];
}

- (BOOL)isRecording {
    return self.recorderTask != nil && self.recorderTask.running;
}

- (void)refreshStatus {
    BOOL running = [self isRecording];

    self.updatingSwitch = YES;
    self.popoverRecordingSwitch.state = running ? NSControlStateValueOn : NSControlStateValueOff;
    self.windowRecordingSwitch.state = running ? NSControlStateValueOn : NSControlStateValueOff;
    self.updatingSwitch = NO;
    self.statusItem.button.title = running ? @"ThumOS On" : @"ThumOS Off";
    self.popoverStatusLabel.stringValue = running ? @"Recorder is running" : @"Recorder is stopped";
    self.windowStatusLabel.stringValue = running ? @"Recorder is running in the background." : @"Recorder is stopped.";
}

- (void)toggleRecording:(id)sender {
    (void)sender;
    if (self.updatingSwitch) {
        return;
    }

    NSSwitch *senderSwitch = [sender isKindOfClass:[NSSwitch class]] ? sender : nil;
    BOOL shouldRecord = senderSwitch.state == NSControlStateValueOn;
    self.popoverRecordingSwitch.enabled = NO;
    self.windowRecordingSwitch.enabled = NO;
    self.popoverStatusLabel.stringValue = shouldRecord ? @"Starting..." : @"Stopping...";
    self.windowStatusLabel.stringValue = shouldRecord ? @"Starting recorder..." : @"Stopping recorder...";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *message = nil;
        BOOL success = shouldRecord ? [self startRecording:&message] : [self stopRecording:&message];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.popoverRecordingSwitch.enabled = YES;
            self.windowRecordingSwitch.enabled = YES;
            [self refreshStatus];
            if (!success) {
                self.popoverStatusLabel.stringValue = message ?: @"Error";
                self.windowStatusLabel.stringValue = message ?: @"Error";
            }
        });
    });
}

- (void)buildDataWindowIfNeeded {
    if (self.dataWindow != nil) {
        return;
    }

    NSRect frame = NSMakeRect(0, 0, 760, 420);
    self.dataWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.dataWindow.title = @"ThumOS Data";
    self.dataWindow.releasedWhenClosed = NO;
    [self.dataWindow center];

    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.dataWindow.contentView = content;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 58, 728, 344)];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    self.dataTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 728, 344)];
    self.dataTextView.editable = NO;
    self.dataTextView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.dataTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = self.dataTextView;
    [content addSubview:scrollView];

    NSButton *refreshButton = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshDataWindow:)];
    refreshButton.frame = NSMakeRect(16, 18, 82, 28);
    refreshButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:refreshButton];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export CSV" target:self action:@selector(exportCSV:)];
    exportButton.frame = NSMakeRect(106, 18, 96, 28);
    exportButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:exportButton];
}

- (void)refreshDataWindow:(id)sender {
    (void)sender;
    self.dataTextView.string = THRecentEventsText();
}

- (void)showData:(id)sender {
    (void)sender;
    [self.popover close];
    [self buildDataWindowIfNeeded];
    [self refreshDataWindow:nil];
    [self.dataWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)exportCSV:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"csv"]];
    panel.nameFieldStringValue = THDefaultExportFilename();
    panel.canCreateDirectories = YES;

    NSModalResponse response = [panel runModal];
    if (response != NSModalResponseOK || panel.URL == nil) {
        return;
    }

    NSString *csv = THEventsCSVText();
    if (csv.length == 0) {
        csv = @"time,source,device,command,event,active_app\n";
    }

    NSError *error = nil;
    BOOL wrote = [csv writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!wrote) {
        self.windowStatusLabel.stringValue = error.localizedDescription ?: @"Export failed.";
        self.popoverStatusLabel.stringValue = error.localizedDescription ?: @"Export failed.";
    }
}

- (void)clearEvents:(id)sender {
    (void)sender;
    NSString *databasePath = THDatabasePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:databasePath]) {
        [self refreshStatus];
        return;
    }

    self.popoverStatusLabel.stringValue = @"Clearing events...";
    self.windowStatusLabel.stringValue = @"Clearing events...";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        THRunTask(@"/usr/bin/sqlite3", @[databasePath, @"DELETE FROM input_events; PRAGMA wal_checkpoint(TRUNCATE);"]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshStatus];
        });
    });
}

- (BOOL)startRecording:(NSString **)message {
    if ([self isRecording]) {
        return YES;
    }

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:THLogDirectory()
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        if (message != NULL) {
            *message = error.localizedDescription;
        }
        return NO;
    }

    NSString *stdoutPath = [THLogDirectory() stringByAppendingPathComponent:@"thumosd.out.log"];
    NSString *stderrPath = [THLogDirectory() stringByAppendingPathComponent:@"thumosd.err.log"];
    [[NSFileManager defaultManager] createFileAtPath:stdoutPath contents:nil attributes:nil];
    [[NSFileManager defaultManager] createFileAtPath:stderrPath contents:nil attributes:nil];

    NSFileHandle *stdoutHandle = [NSFileHandle fileHandleForWritingAtPath:stdoutPath];
    NSFileHandle *stderrHandle = [NSFileHandle fileHandleForWritingAtPath:stderrPath];
    [stdoutHandle seekToEndOfFile];
    [stderrHandle seekToEndOfFile];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = THBundledDaemonPath();
    task.arguments = @[@"--hid-record", @"--hid-product", @"Creator"];
    task.standardOutput = stdoutHandle;
    task.standardError = stderrHandle;

    @try {
        [task launch];
    } @catch (NSException *exception) {
        if (message != NULL) {
            *message = exception.reason ?: @"Could not start recorder.";
        }
        return NO;
    }

    self.recorderTask = task;
    return YES;
}

- (BOOL)stopRecording:(NSString **)message {
    (void)message;
    if (self.recorderTask == nil) {
        return YES;
    }

    if (self.recorderTask.running) {
        [self.recorderTask terminate];
    }

    self.recorderTask = nil;
    return YES;
}

- (void)disableLaunchAgentRecorder {
    THRunTask(@"/bin/launchctl", @[@"disable", THLaunchServiceTarget()]);
    THRunTask(@"/bin/launchctl", @[@"bootout", THLaunchServiceTarget()]);
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSError *lockError = nil;
        if (!THAcquireSingleInstanceLock(&lockError)) {
            return lockError == nil ? 0 : 1;
        }

        NSApplication *application = [NSApplication sharedApplication];
        ThumOSMenuController *delegate = [[ThumOSMenuController alloc] init];
        application.delegate = delegate;
        [application run];
    }

    return 0;
}
