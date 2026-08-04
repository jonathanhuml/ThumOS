#import <AppKit/AppKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <fcntl.h>
#import <stdint.h>
#import <sqlite3.h>
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

static NSString *THISODateString(NSDate *date) {
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [formatter stringFromDate:date ?: [NSDate date]];
}

static NSString *THFilenameTimestamp(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return [formatter stringFromDate:[NSDate date]];
}

static CBUUID *THMuseServiceUUID(void) {
    return [CBUUID UUIDWithString:@"0000FE8D-0000-1000-8000-00805F9B34FB"];
}

static CBUUID *THMuseControlUUID(void) {
    return [CBUUID UUIDWithString:@"273E0001-4C4D-454D-96BE-F03BAC821358"];
}

static NSArray<CBUUID *> *THMuseEEGUUIDs(void) {
    return @[
        [CBUUID UUIDWithString:@"273E0003-4C4D-454D-96BE-F03BAC821358"],
        [CBUUID UUIDWithString:@"273E0004-4C4D-454D-96BE-F03BAC821358"],
        [CBUUID UUIDWithString:@"273E0005-4C4D-454D-96BE-F03BAC821358"],
        [CBUUID UUIDWithString:@"273E0006-4C4D-454D-96BE-F03BAC821358"]
    ];
}

static NSData *THMuseStartCommand(void) {
    const unsigned char bytes[] = {0x02, 0x64, 0x0a};
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSData *THMuseStopCommand(void) {
    const unsigned char bytes[] = {0x02, 0x68, 0x0a};
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSString *THApplicationSupportDirectory(void) {
    return THExpandTilde(@"~/Library/Application Support/ThumOS");
}

static NSString *THEEGRecordingsDirectory(void) {
    return [THApplicationSupportDirectory() stringByAppendingPathComponent:@"eeg-recordings"];
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

static NSString *THCSVField(NSString *value) {
    NSString *safeValue = value ?: @"";
    NSString *escapedValue = [safeValue stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
    BOOL needsQuotes = [escapedValue rangeOfString:@","].location != NSNotFound ||
                       [escapedValue rangeOfString:@"\""].location != NSNotFound ||
                       [escapedValue rangeOfString:@"\n"].location != NSNotFound ||
                       [escapedValue rangeOfString:@"\r"].location != NSNotFound;
    return needsQuotes ? [NSString stringWithFormat:@"\"%@\"", escapedValue] : escapedValue;
}

@interface ThumOSMenuController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) NSWindow *mainWindow;
@property(nonatomic, strong) NSSwitch *popoverRecordingSwitch;
@property(nonatomic, strong) NSSwitch *windowRecordingSwitch;
@property(nonatomic, strong) NSTextField *popoverStatusLabel;
@property(nonatomic, strong) NSTextField *windowStatusLabel;
@property(nonatomic, strong) NSTextField *popoverMuseStatusLabel;
@property(nonatomic, strong) NSTextField *windowMuseStatusLabel;
@property(nonatomic, strong) NSButton *popoverMuseButton;
@property(nonatomic, strong) NSButton *windowMuseButton;
@property(nonatomic, strong) NSSwitch *popoverEEGRecordingSwitch;
@property(nonatomic, strong) NSSwitch *windowEEGRecordingSwitch;
@property(nonatomic, strong) NSWindow *dataWindow;
@property(nonatomic, strong) NSTextView *dataTextView;
@property(nonatomic, strong) NSTask *recorderTask;
@property(nonatomic, strong) CBCentralManager *centralManager;
@property(nonatomic, strong) CBPeripheral *musePeripheral;
@property(nonatomic, strong) CBCharacteristic *museControlCharacteristic;
@property(nonatomic, strong) NSDictionary<CBUUID *, NSString *> *museChannelByUUID;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *museSampleIndexByChannel;
@property(nonatomic, strong) NSMutableSet<CBUUID *> *museDiscoveredEEGUUIDs;
@property(nonatomic, strong) NSMutableSet<CBUUID *> *museNotifyingEEGUUIDs;
@property(nonatomic, strong) NSFileHandle *eegFileHandle;
@property(nonatomic, copy) NSString *eegRecordingPath;
@property(nonatomic, copy) NSString *eegRecordingStartedAtUTC;
@property(nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic, strong) NSTimer *creatorTriggerTimer;
@property(nonatomic) sqlite3_int64 creatorTriggerLastEventID;
@property(nonatomic) sqlite3_int64 creatorTriggerLastControlNS;
@property(nonatomic) sqlite3_int64 creatorTriggerLastCNS;
@property(nonatomic) sqlite3_int64 creatorTriggerLastENS;
@property(nonatomic) sqlite3_int64 creatorTriggerLastToggleNS;
@property(nonatomic) BOOL updatingSwitch;
@property(nonatomic) BOOL museConnected;
@property(nonatomic) BOOL museConnecting;
@property(nonatomic) BOOL museStreaming;
@property(nonatomic) BOOL eegRecording;
@end

@implementation ThumOSMenuController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildApplicationMenu];
    [self buildStatusItem];
    [self buildPopover];
    [self buildMainWindow];
    [self configureMuseChannelMap];
    [self disableLaunchAgentRecorder];
    [self refreshStatus];
    [self showMainWindow:nil];
    [self initializeCreatorTriggerCursor];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(refreshStatus)
                                                       userInfo:nil
                                                        repeats:YES];
    self.creatorTriggerTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                                target:self
                                                              selector:@selector(pollCreatorTrigger:)
                                                              userInfo:nil
                                                               repeats:YES];
}

- (void)configureMuseChannelMap {
    NSArray<CBUUID *> *uuids = THMuseEEGUUIDs();
    self.museChannelByUUID = @{
        uuids[0]: @"TP9",
        uuids[1]: @"AF7",
        uuids[2]: @"AF8",
        uuids[3]: @"TP10"
    };
    self.museSampleIndexByChannel = [NSMutableDictionary dictionary];
    self.museDiscoveredEEGUUIDs = [NSMutableSet set];
    self.museNotifyingEEGUUIDs = [NSMutableSet set];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.refreshTimer invalidate];
    [self.creatorTriggerTimer invalidate];
    [self stopRecording:nil];
    [self disconnectMuse];
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
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 260)];

    NSTextField *title = [self labelWithString:@"ThumOS"
                                         frame:NSMakeRect(16, 222, 150, 24)
                                          font:[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold]
                                         color:nil];
    [view addSubview:title];

    NSTextField *recording = [self labelWithString:@"Creator Recording"
                                             frame:NSMakeRect(16, 188, 160, 18)
                                              font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                             color:nil];
    [view addSubview:recording];

    self.popoverRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(210, 182, 50, 28)];
    self.popoverRecordingSwitch.target = self;
    self.popoverRecordingSwitch.action = @selector(toggleRecording:);
    [view addSubview:self.popoverRecordingSwitch];

    self.popoverStatusLabel = [self labelWithString:@"Off"
                                              frame:NSMakeRect(16, 164, 244, 16)
                                               font:[NSFont systemFontOfSize:11]
                                              color:[NSColor secondaryLabelColor]];
    [view addSubview:self.popoverStatusLabel];

    NSTextField *muse = [self labelWithString:@"Muse Headset"
                                        frame:NSMakeRect(16, 126, 160, 18)
                                         font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                        color:nil];
    [view addSubview:muse];

    self.popoverMuseButton = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(toggleMuseConnection:)];
    self.popoverMuseButton.frame = NSMakeRect(180, 120, 82, 26);
    [view addSubview:self.popoverMuseButton];

    self.popoverMuseStatusLabel = [self labelWithString:@"Disconnected"
                                                  frame:NSMakeRect(16, 102, 244, 16)
                                                   font:[NSFont systemFontOfSize:11]
                                                  color:[NSColor secondaryLabelColor]];
    [view addSubview:self.popoverMuseStatusLabel];

    NSTextField *eegRecording = [self labelWithString:@"EEG Recording"
                                                frame:NSMakeRect(16, 72, 160, 18)
                                                 font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                                color:nil];
    [view addSubview:eegRecording];

    self.popoverEEGRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(210, 66, 50, 28)];
    self.popoverEEGRecordingSwitch.target = self;
    self.popoverEEGRecordingSwitch.action = @selector(toggleEEGRecording:);
    self.popoverEEGRecordingSwitch.enabled = NO;
    [view addSubview:self.popoverEEGRecordingSwitch];

    NSButton *showButton = [NSButton buttonWithTitle:@"Open App" target:self action:@selector(showMainWindow:)];
    showButton.frame = NSMakeRect(14, 8, 96, 24);
    [view addSubview:showButton];

    NSButton *dataButton = [NSButton buttonWithTitle:@"Show Data" target:self action:@selector(showData:)];
    dataButton.frame = NSMakeRect(116, 8, 86, 24);
    [view addSubview:dataButton];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export" target:self action:@selector(exportCSV:)];
    exportButton.frame = NSMakeRect(14, 36, 74, 24);
    [view addSubview:exportButton];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearEvents:)];
    clearButton.frame = NSMakeRect(94, 36, 64, 24);
    [view addSubview:clearButton];

    controller.view = view;
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = controller;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.delegate = self;
}

- (void)buildMainWindow {
    NSRect frame = NSMakeRect(0, 0, 520, 360);
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
                                         frame:NSMakeRect(24, 302, 220, 28)
                                          font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                         color:nil];
    [content addSubview:title];

    NSTextField *subtitle = [self labelWithString:@"Creator Micro and Muse recorder"
                                            frame:NSMakeRect(24, 278, 300, 18)
                                             font:[NSFont systemFontOfSize:12]
                                            color:[NSColor secondaryLabelColor]];
    [content addSubview:subtitle];

    NSTextField *recording = [self labelWithString:@"Creator Recording"
                                             frame:NSMakeRect(24, 232, 180, 20)
                                              font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                             color:nil];
    [content addSubview:recording];

    self.windowRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(444, 226, 50, 28)];
    self.windowRecordingSwitch.target = self;
    self.windowRecordingSwitch.action = @selector(toggleRecording:);
    [content addSubview:self.windowRecordingSwitch];

    self.windowStatusLabel = [self labelWithString:@"Off"
                                             frame:NSMakeRect(24, 208, 460, 18)
                                              font:[NSFont systemFontOfSize:12]
                                             color:[NSColor secondaryLabelColor]];
    [content addSubview:self.windowStatusLabel];

    NSTextField *museLabel = [self labelWithString:@"Muse Headset"
                                             frame:NSMakeRect(24, 162, 180, 20)
                                              font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                             color:nil];
    [content addSubview:museLabel];

    self.windowMuseButton = [NSButton buttonWithTitle:@"Connect Muse" target:self action:@selector(toggleMuseConnection:)];
    self.windowMuseButton.frame = NSMakeRect(380, 157, 116, 28);
    [content addSubview:self.windowMuseButton];

    self.windowMuseStatusLabel = [self labelWithString:@"Disconnected"
                                                 frame:NSMakeRect(24, 138, 460, 18)
                                                  font:[NSFont systemFontOfSize:12]
                                                 color:[NSColor secondaryLabelColor]];
    [content addSubview:self.windowMuseStatusLabel];

    NSTextField *eegLabel = [self labelWithString:@"EEG Recording"
                                            frame:NSMakeRect(24, 100, 180, 20)
                                             font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                            color:nil];
    [content addSubview:eegLabel];

    self.windowEEGRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(444, 94, 50, 28)];
    self.windowEEGRecordingSwitch.target = self;
    self.windowEEGRecordingSwitch.action = @selector(toggleEEGRecording:);
    self.windowEEGRecordingSwitch.enabled = NO;
    [content addSubview:self.windowEEGRecordingSwitch];

    NSTextField *databaseLabel = [self labelWithString:@"Data"
                                                 frame:NSMakeRect(24, 62, 80, 18)
                                                  font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                                 color:nil];
    [content addSubview:databaseLabel];

    NSButton *showDataButton = [NSButton buttonWithTitle:@"Show Data" target:self action:@selector(showData:)];
    showDataButton.frame = NSMakeRect(20, 28, 92, 28);
    [content addSubview:showDataButton];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export CSV" target:self action:@selector(exportCSV:)];
    exportButton.frame = NSMakeRect(120, 28, 96, 28);
    [content addSubview:exportButton];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear Events" target:self action:@selector(clearEvents:)];
    clearButton.frame = NSMakeRect(386, 29, 110, 28);
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
    [self syncMuseControls];
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

- (void)initializeCreatorTriggerCursor {
    self.creatorTriggerLastEventID = 0;
    self.creatorTriggerLastControlNS = 0;
    self.creatorTriggerLastCNS = 0;
    self.creatorTriggerLastENS = 0;
    self.creatorTriggerLastToggleNS = 0;

    NSString *databasePath = THDatabasePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:databasePath]) {
        return;
    }

    sqlite3 *database = NULL;
    if (sqlite3_open_v2([databasePath fileSystemRepresentation], &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database != NULL) {
            sqlite3_close(database);
        }
        return;
    }

    sqlite3_stmt *statement = NULL;
    const char *sql = "select coalesce(max(id), 0) from input_events where source = 'hid';";
    if (sqlite3_prepare_v2(database, sql, -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            self.creatorTriggerLastEventID = sqlite3_column_int64(statement, 0);
        }
    }

    sqlite3_finalize(statement);
    sqlite3_close(database);
}

- (BOOL)isCreatorTriggerControlCommandID:(NSString *)commandID {
    return [commandID isEqualToString:@"keyboard.0xe0"] ||
           [commandID isEqualToString:@"keyboard.0xe4"] ||
           [commandID isEqualToString:@"keyboard.left-control"] ||
           [commandID isEqualToString:@"keyboard.right-control"];
}

- (void)toggleEEGRecordingFromCreatorCommand {
    if (![self isMuseRunning] || !self.museConnected) {
        self.eegRecording = NO;
        [self syncMuseControls];
        [self setMuseStatus:@"Connect Muse before Creator EEG toggle." connected:self.museConnected];
        return;
    }

    if (self.eegRecording) {
        [self stopEEGRecordingWithStatus:YES];
    } else {
        [self startEEGRecording];
    }
}

- (void)processCreatorTriggerCommandID:(NSString *)commandID monotonicNS:(sqlite3_int64)monotonicNS {
    if (commandID.length == 0 || monotonicNS <= 0) {
        return;
    }

    BOOL relevant = YES;
    if ([self isCreatorTriggerControlCommandID:commandID]) {
        self.creatorTriggerLastControlNS = monotonicNS;
    } else if ([commandID isEqualToString:@"keyboard.c"]) {
        self.creatorTriggerLastCNS = monotonicNS;
    } else if ([commandID isEqualToString:@"keyboard.e"]) {
        self.creatorTriggerLastENS = monotonicNS;
    } else {
        relevant = NO;
    }

    if (!relevant ||
        self.creatorTriggerLastControlNS <= 0 ||
        self.creatorTriggerLastCNS <= 0 ||
        self.creatorTriggerLastENS <= 0) {
        return;
    }

    sqlite3_int64 newest = MAX(self.creatorTriggerLastControlNS, MAX(self.creatorTriggerLastCNS, self.creatorTriggerLastENS));
    sqlite3_int64 oldest = MIN(self.creatorTriggerLastControlNS, MIN(self.creatorTriggerLastCNS, self.creatorTriggerLastENS));
    sqlite3_int64 windowNS = 1200000000LL;
    sqlite3_int64 debounceNS = 1500000000LL;

    if ((newest - oldest) <= windowNS && (newest - self.creatorTriggerLastToggleNS) > debounceNS) {
        self.creatorTriggerLastToggleNS = newest;
        self.creatorTriggerLastControlNS = 0;
        self.creatorTriggerLastCNS = 0;
        self.creatorTriggerLastENS = 0;
        [self toggleEEGRecordingFromCreatorCommand];
    }
}

- (void)pollCreatorTrigger:(NSTimer *)timer {
    (void)timer;
    if (![self isRecording]) {
        return;
    }

    NSString *databasePath = THDatabasePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:databasePath]) {
        return;
    }

    sqlite3 *database = NULL;
    if (sqlite3_open_v2([databasePath fileSystemRepresentation], &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (database != NULL) {
            sqlite3_close(database);
        }
        return;
    }

    sqlite3_stmt *statement = NULL;
    const char *sql =
        "select id, command_id, monotonic_ns "
        "from input_events "
        "where source = 'hid' and event_type = 'press' and id > ? "
        "order by id asc "
        "limit 100;";
    if (sqlite3_prepare_v2(database, sql, -1, &statement, NULL) != SQLITE_OK) {
        sqlite3_close(database);
        return;
    }

    sqlite3_bind_int64(statement, 1, self.creatorTriggerLastEventID);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        sqlite3_int64 eventID = sqlite3_column_int64(statement, 0);
        const unsigned char *commandText = sqlite3_column_text(statement, 1);
        sqlite3_int64 monotonicNS = sqlite3_column_int64(statement, 2);
        NSString *commandID = commandText != NULL ? [NSString stringWithUTF8String:(const char *)commandText] : @"";

        self.creatorTriggerLastEventID = MAX(self.creatorTriggerLastEventID, eventID);
        [self processCreatorTriggerCommandID:commandID monotonicNS:monotonicNS];
    }

    sqlite3_finalize(statement);
    sqlite3_close(database);
}

- (BOOL)isMuseRunning {
    return self.museConnecting || self.museConnected || self.musePeripheral != nil;
}

- (void)setMuseStatus:(NSString *)message connected:(BOOL)connected {
    self.museConnected = connected;
    self.windowMuseStatusLabel.stringValue = message ?: @"Disconnected";
    self.popoverMuseStatusLabel.stringValue = message ?: @"Disconnected";
    [self syncMuseControls];
}

- (void)syncMuseControls {
    BOOL running = [self isMuseRunning];
    self.windowMuseButton.title = running ? @"Disconnect" : @"Connect Muse";
    self.popoverMuseButton.title = running ? @"Disconnect" : @"Connect";
    self.windowEEGRecordingSwitch.enabled = self.museConnected;
    self.popoverEEGRecordingSwitch.enabled = self.museConnected;

    self.updatingSwitch = YES;
    self.windowEEGRecordingSwitch.state = self.eegRecording ? NSControlStateValueOn : NSControlStateValueOff;
    self.popoverEEGRecordingSwitch.state = self.eegRecording ? NSControlStateValueOn : NSControlStateValueOff;
    self.updatingSwitch = NO;
}

- (void)toggleMuseConnection:(id)sender {
    (void)sender;
    if ([self isMuseRunning]) {
        [self disconnectMuse];
    } else {
        [self connectMuse];
    }
}

- (void)connectMuse {
    if ([self isMuseRunning]) {
        return;
    }

    self.museConnecting = YES;
    self.museConnected = NO;
    self.museStreaming = NO;
    self.musePeripheral = nil;
    self.museControlCharacteristic = nil;
    self.museDiscoveredEEGUUIDs = [NSMutableSet set];
    self.museNotifyingEEGUUIDs = [NSMutableSet set];
    [self setMuseStatus:@"Preparing Bluetooth..." connected:NO];

    if (self.centralManager == nil) {
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
        return;
    }

    [self startMuseScanIfReady];
}

- (void)startMuseScanIfReady {
    if (self.centralManager.state != CBManagerStatePoweredOn) {
        if (self.centralManager.state == CBManagerStateUnauthorized) {
            self.museConnecting = NO;
            [self setMuseStatus:@"Bluetooth permission denied for ThumOS." connected:NO];
        } else if (self.centralManager.state == CBManagerStatePoweredOff) {
            self.museConnecting = NO;
            [self setMuseStatus:@"Bluetooth is off." connected:NO];
        } else {
            [self setMuseStatus:@"Waiting for Bluetooth..." connected:NO];
        }
        return;
    }

    self.museConnecting = YES;
    self.museConnected = NO;
    self.museStreaming = NO;
    self.musePeripheral = nil;
    self.museControlCharacteristic = nil;
    self.museDiscoveredEEGUUIDs = [NSMutableSet set];
    self.museNotifyingEEGUUIDs = [NSMutableSet set];
    [self setMuseStatus:@"Scanning for Muse..." connected:NO];

    [self.centralManager stopScan];
    [self.centralManager scanForPeripheralsWithServices:@[THMuseServiceUUID()]
                                                options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

- (NSString *)museDisplayName {
    NSString *name = self.musePeripheral.name;
    return name.length > 0 ? name : @"Muse";
}

- (void)museReadyIfPossible {
    if (!self.museConnecting || self.museConnected || self.museControlCharacteristic == nil) {
        return;
    }

    if (self.museNotifyingEEGUUIDs.count < THMuseEEGUUIDs().count) {
        return;
    }

    self.museConnecting = NO;
    [self setMuseStatus:[NSString stringWithFormat:@"Connected to %@", [self museDisplayName]] connected:YES];
}

- (BOOL)writeMuseControlCommand:(NSData *)command {
    if (self.musePeripheral == nil || self.museControlCharacteristic == nil) {
        [self setMuseStatus:@"Muse control channel is not ready." connected:self.museConnected];
        return NO;
    }

    CBCharacteristicProperties properties = self.museControlCharacteristic.properties;
    BOOL canWrite = (properties & CBCharacteristicPropertyWrite) != 0;
    BOOL canWriteWithoutResponse = (properties & CBCharacteristicPropertyWriteWithoutResponse) != 0;
    if (!canWrite && !canWriteWithoutResponse) {
        [self setMuseStatus:@"Muse control channel is not writable." connected:self.museConnected];
        return NO;
    }

    CBCharacteristicWriteType writeType = canWriteWithoutResponse ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
    [self.musePeripheral writeValue:command forCharacteristic:self.museControlCharacteristic type:writeType];
    return YES;
}

- (NSArray<NSNumber *> *)decodeMuseSamples:(NSData *)data {
    if (data.length < 20) {
        return @[];
    }

    const uint8_t *bytes = data.bytes;
    NSMutableArray<NSNumber *> *samples = [NSMutableArray arrayWithCapacity:12];
    for (NSUInteger i = 0; i < 12; i++) {
        NSUInteger bitOffset = i * 12;
        NSUInteger byteOffset = 2 + (bitOffset / 8);
        NSUInteger shift = bitOffset % 8;
        uint32_t b0 = byteOffset < data.length ? bytes[byteOffset] : 0;
        uint32_t b1 = (byteOffset + 1) < data.length ? bytes[byteOffset + 1] : 0;
        uint32_t b2 = (byteOffset + 2) < data.length ? bytes[byteOffset + 2] : 0;
        uint32_t raw = (((b0 << 16) | (b1 << 8) | b2) >> (12 - shift)) & 0xFFF;
        double microvolts = ((double)raw - 0x800) * 0.48828125;
        [samples addObject:@(microvolts)];
    }

    return samples;
}

- (void)appendMuseSamples:(NSArray<NSNumber *> *)samples channel:(NSString *)channel timestamp:(NSDate *)timestamp {
    if (self.eegFileHandle == nil || samples.count == 0 || channel.length == 0) {
        return;
    }

    NSString *sampleTime = THISODateString(timestamp);
    NSString *recordingStartedAt = self.eegRecordingStartedAtUTC ?: sampleTime;
    NSString *deviceName = [self museDisplayName];
    NSUInteger sampleIndex = [self.museSampleIndexByChannel[channel] unsignedIntegerValue];
    NSMutableString *lines = [NSMutableString string];

    for (NSNumber *sample in samples) {
        sampleIndex++;
        [lines appendFormat:@"%@,%@,%@,%@,%lu,%.6f\n",
                            recordingStartedAt,
                            sampleTime,
                            THCSVField(deviceName),
                            THCSVField(channel),
                            (unsigned long)sampleIndex,
                            sample.doubleValue];
    }

    self.museSampleIndexByChannel[channel] = @(sampleIndex);

    NSData *lineData = [lines dataUsingEncoding:NSUTF8StringEncoding];
    @try {
        [self.eegFileHandle writeData:lineData];
    } @catch (NSException *exception) {
        (void)exception;
        [self stopEEGRecordingWithStatus:NO];
        [self setMuseStatus:@"Stopped EEG recording because the file could not be written." connected:self.museConnected];
    }
}

- (void)startEEGRecording {
    if (!self.museConnected) {
        self.eegRecording = NO;
        [self setMuseStatus:@"Connect Muse before EEG recording." connected:NO];
        return;
    }

    if (self.eegRecording) {
        return;
    }

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:THEEGRecordingsDirectory()
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        [self setMuseStatus:error.localizedDescription ?: @"Could not create EEG recording folder." connected:YES];
        return;
    }

    NSString *filename = [NSString stringWithFormat:@"muse-eeg-%@.csv", THFilenameTimestamp()];
    NSString *path = [THEEGRecordingsDirectory() stringByAppendingPathComponent:filename];
    NSString *header = @"recording_started_at_utc,sample_timestamp_utc,device_name,channel,channel_sample_index,value_uv\n";
    if (![header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self setMuseStatus:error.localizedDescription ?: @"Could not create EEG CSV." connected:YES];
        return;
    }

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fileHandle == nil) {
        [self setMuseStatus:@"Could not open EEG CSV for writing." connected:YES];
        return;
    }

    [fileHandle seekToEndOfFile];
    self.eegFileHandle = fileHandle;
    self.eegRecordingPath = path;
    self.eegRecordingStartedAtUTC = THISODateString([NSDate date]);
    [self.museSampleIndexByChannel removeAllObjects];

    if (![self writeMuseControlCommand:THMuseStartCommand()]) {
        [self.eegFileHandle closeFile];
        self.eegFileHandle = nil;
        self.eegRecordingPath = nil;
        self.eegRecordingStartedAtUTC = nil;
        return;
    }

    self.museStreaming = YES;
    self.eegRecording = YES;
    [self setMuseStatus:[NSString stringWithFormat:@"Recording EEG to %@", filename] connected:YES];
}

- (void)stopEEGRecordingWithStatus:(BOOL)updateStatus {
    NSString *path = self.eegRecordingPath;
    BOOL hadRecording = self.eegRecording || self.eegFileHandle != nil;

    if (self.museConnected && self.museStreaming) {
        [self writeMuseControlCommand:THMuseStopCommand()];
    }
    self.museStreaming = NO;
    self.eegRecording = NO;

    if (self.eegFileHandle != nil) {
        @try {
            [self.eegFileHandle closeFile];
        } @catch (NSException *exception) {
            (void)exception;
        }
    }

    self.eegFileHandle = nil;
    self.eegRecordingPath = nil;
    self.eegRecordingStartedAtUTC = nil;

    if (updateStatus && hadRecording) {
        NSString *filename = path.length > 0 ? [path lastPathComponent] : @"EEG CSV";
        [self setMuseStatus:[NSString stringWithFormat:@"Saved %@", filename] connected:self.museConnected];
    } else {
        [self syncMuseControls];
    }
}

- (void)disconnectMuse {
    if (self.eegRecording || self.eegFileHandle != nil) {
        [self stopEEGRecordingWithStatus:NO];
    } else if (self.museConnected && self.museStreaming) {
        [self writeMuseControlCommand:THMuseStopCommand()];
    }

    CBPeripheral *peripheral = self.musePeripheral;
    if (self.centralManager != nil) {
        [self.centralManager stopScan];
        if (peripheral != nil &&
            (peripheral.state == CBPeripheralStateConnected || peripheral.state == CBPeripheralStateConnecting)) {
            [self.centralManager cancelPeripheralConnection:peripheral];
        }
    }

    self.musePeripheral = nil;
    self.museControlCharacteristic = nil;
    self.museDiscoveredEEGUUIDs = [NSMutableSet set];
    self.museNotifyingEEGUUIDs = [NSMutableSet set];
    self.museConnecting = NO;
    self.museConnected = NO;
    self.museStreaming = NO;
    [self setMuseStatus:@"Disconnected" connected:NO];
}

- (void)toggleEEGRecording:(id)sender {
    if (self.updatingSwitch) {
        return;
    }
    if (![self isMuseRunning] || !self.museConnected) {
        self.eegRecording = NO;
        [self syncMuseControls];
        [self setMuseStatus:@"Connect Muse before EEG recording." connected:NO];
        return;
    }

    NSSwitch *senderSwitch = [sender isKindOfClass:[NSSwitch class]] ? sender : nil;
    BOOL shouldRecord = senderSwitch.state == NSControlStateValueOn;
    if (shouldRecord) {
        [self startEEGRecording];
    } else {
        [self stopEEGRecordingWithStatus:YES];
    }
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn) {
        if (self.museConnecting && !self.museConnected && self.musePeripheral == nil) {
            [self startMuseScanIfReady];
        }
        return;
    }

    if (!self.museConnecting && !self.museConnected) {
        return;
    }

    if (central.state == CBManagerStateUnauthorized) {
        self.museConnecting = NO;
        [self setMuseStatus:@"Bluetooth permission denied for ThumOS." connected:NO];
    } else if (central.state == CBManagerStatePoweredOff) {
        self.museConnecting = NO;
        [self setMuseStatus:@"Bluetooth is off." connected:NO];
    } else if (central.state == CBManagerStateUnsupported) {
        self.museConnecting = NO;
        [self setMuseStatus:@"Bluetooth is not supported on this Mac." connected:NO];
    } else {
        [self setMuseStatus:@"Waiting for Bluetooth..." connected:NO];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    (void)RSSI;
    if (!self.museConnecting || self.museConnected || self.musePeripheral != nil) {
        return;
    }

    NSString *advertisedName = [advertisementData[CBAdvertisementDataLocalNameKey] isKindOfClass:[NSString class]] ? advertisementData[CBAdvertisementDataLocalNameKey] : @"";
    NSString *name = peripheral.name.length > 0 ? peripheral.name : advertisedName;
    self.musePeripheral = peripheral;
    self.musePeripheral.delegate = self;

    [central stopScan];
    [self setMuseStatus:[NSString stringWithFormat:@"Connecting to %@...", name.length > 0 ? name : @"Muse"] connected:NO];
    [central connectPeripheral:peripheral options:nil];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    (void)central;
    if (peripheral != self.musePeripheral) {
        return;
    }

    self.museConnecting = YES;
    [self setMuseStatus:@"Discovering Muse services..." connected:NO];
    [peripheral discoverServices:@[THMuseServiceUUID()]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    (void)central;
    if (peripheral != self.musePeripheral) {
        return;
    }

    self.musePeripheral = nil;
    self.museControlCharacteristic = nil;
    self.museConnecting = NO;
    NSString *message = error.localizedDescription ?: @"Could not connect to Muse.";
    [self setMuseStatus:message connected:NO];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    (void)central;
    if (self.musePeripheral != nil && peripheral != self.musePeripheral) {
        return;
    }

    if (self.eegRecording || self.eegFileHandle != nil) {
        [self stopEEGRecordingWithStatus:NO];
    }

    self.musePeripheral = nil;
    self.museControlCharacteristic = nil;
    self.museDiscoveredEEGUUIDs = [NSMutableSet set];
    self.museNotifyingEEGUUIDs = [NSMutableSet set];
    self.museConnecting = NO;
    self.museConnected = NO;
    self.museStreaming = NO;

    NSString *message = error.localizedDescription ?: @"Disconnected";
    [self setMuseStatus:message connected:NO];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (peripheral != self.musePeripheral) {
        return;
    }

    if (error != nil) {
        self.museConnecting = NO;
        [self setMuseStatus:error.localizedDescription ?: @"Could not discover Muse services." connected:NO];
        return;
    }

    CBService *museService = nil;
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:THMuseServiceUUID()]) {
            museService = service;
            break;
        }
    }

    if (museService == nil) {
        self.museConnecting = NO;
        [self setMuseStatus:@"Muse service not found." connected:NO];
        [self.centralManager cancelPeripheralConnection:peripheral];
        return;
    }

    NSMutableArray<CBUUID *> *characteristicUUIDs = [NSMutableArray arrayWithObject:THMuseControlUUID()];
    [characteristicUUIDs addObjectsFromArray:THMuseEEGUUIDs()];
    [self setMuseStatus:@"Discovering Muse EEG channels..." connected:NO];
    [peripheral discoverCharacteristics:characteristicUUIDs forService:museService];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (peripheral != self.musePeripheral || ![service.UUID isEqual:THMuseServiceUUID()]) {
        return;
    }

    if (error != nil) {
        self.museConnecting = NO;
        [self setMuseStatus:error.localizedDescription ?: @"Could not discover Muse channels." connected:NO];
        return;
    }

    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:THMuseControlUUID()]) {
            self.museControlCharacteristic = characteristic;
            continue;
        }

        NSString *channel = self.museChannelByUUID[characteristic.UUID];
        if (channel.length == 0) {
            continue;
        }

        [self.museDiscoveredEEGUUIDs addObject:characteristic.UUID];
        CBCharacteristicProperties properties = characteristic.properties;
        if ((properties & CBCharacteristicPropertyNotify) == 0 &&
            (properties & CBCharacteristicPropertyIndicate) == 0) {
            self.museConnecting = NO;
            [self setMuseStatus:@"Muse EEG channel cannot stream notifications." connected:NO];
            return;
        }

        [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        if (characteristic.isNotifying) {
            [self.museNotifyingEEGUUIDs addObject:characteristic.UUID];
        }
    }

    if (self.museControlCharacteristic == nil) {
        self.museConnecting = NO;
        [self setMuseStatus:@"Muse control channel not found." connected:NO];
        return;
    }

    if (self.museDiscoveredEEGUUIDs.count < THMuseEEGUUIDs().count) {
        self.museConnecting = NO;
        [self setMuseStatus:@"Muse EEG channels not found." connected:NO];
        return;
    }

    [self setMuseStatus:@"Enabling Muse EEG channels..." connected:NO];
    [self museReadyIfPossible];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.musePeripheral || self.museChannelByUUID[characteristic.UUID] == nil) {
        return;
    }

    if (error != nil) {
        self.museConnecting = NO;
        [self setMuseStatus:error.localizedDescription ?: @"Could not enable Muse EEG channel." connected:NO];
        return;
    }

    if (characteristic.isNotifying) {
        [self.museNotifyingEEGUUIDs addObject:characteristic.UUID];
    } else {
        [self.museNotifyingEEGUUIDs removeObject:characteristic.UUID];
    }

    [self museReadyIfPossible];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != self.musePeripheral || error != nil || !self.eegRecording) {
        return;
    }

    NSString *channel = self.museChannelByUUID[characteristic.UUID];
    if (channel.length == 0) {
        return;
    }

    NSArray<NSNumber *> *samples = [self decodeMuseSamples:characteristic.value];
    [self appendMuseSamples:samples channel:channel timestamp:[NSDate date]];
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
