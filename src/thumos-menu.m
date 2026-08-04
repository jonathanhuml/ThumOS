#import <AppKit/AppKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <fcntl.h>
#import <math.h>
#import <stdint.h>
#import <sqlite3.h>
#import <sys/file.h>
#import <sys/types.h>
#import <unistd.h>

static NSString * const THDaemonLabel = @"io.thumos.daemon";
static NSString * const THSessionsRootDefaultsKey = @"ThumOSSessionsRoot";
static int gInstanceLockFD = -1;

@interface THTaskResult : NSObject
@property(nonatomic) int status;
@property(nonatomic, copy) NSString *output;
@end

@implementation THTaskResult
@end

@interface THWaveformView : NSView
@property(nonatomic, copy) NSArray<NSDictionary *> *samples;
@property(nonatomic, copy) NSArray<NSDictionary *> *annotations;
@property(nonatomic, copy) NSArray<NSString *> *channels;
@property(nonatomic) NSTimeInterval duration;
@end

@implementation THWaveformView

- (BOOL)isFlipped {
    return YES;
}

- (void)setSamples:(NSArray<NSDictionary *> *)samples {
    _samples = [samples copy];
    [self setNeedsDisplay:YES];
}

- (void)setAnnotations:(NSArray<NSDictionary *> *)annotations {
    _annotations = [annotations copy];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);

    if (self.samples.count == 0 || self.channels.count == 0 || self.duration <= 0.0) {
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:13],
                                     NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
        [@"No Muse samples found for this session." drawInRect:NSInsetRect(self.bounds, 24, 24)
                                                withAttributes:attributes];
        return;
    }

    CGFloat left = 58.0;
    CGFloat right = 18.0;
    CGFloat top = 22.0;
    CGFloat bottom = 28.0;
    NSRect plotRect = NSMakeRect(left,
                                 top,
                                 MAX(10.0, self.bounds.size.width - left - right),
                                 MAX(10.0, self.bounds.size.height - top - bottom));
    CGFloat laneHeight = plotRect.size.height / self.channels.count;

    NSDictionary *labelAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                      NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    NSDictionary *annotationAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                           NSForegroundColorAttributeName: [NSColor systemRedColor]};

    [[NSColor separatorColor] setStroke];
    for (NSUInteger index = 0; index < self.channels.count; index++) {
        CGFloat y = plotRect.origin.y + laneHeight * index;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plotRect.origin.x, y + laneHeight * 0.5)];
        [line lineToPoint:NSMakePoint(NSMaxX(plotRect), y + laneHeight * 0.5)];
        line.lineWidth = 1.0;
        [line stroke];

        NSString *channel = self.channels[index];
        [channel drawInRect:NSMakeRect(10, y + laneHeight * 0.5 - 8, 44, 16)
             withAttributes:labelAttributes];
    }

    NSMutableDictionary<NSString *, NSNumber *> *maxAbsByChannel = [NSMutableDictionary dictionary];
    for (NSDictionary *sample in self.samples) {
        NSString *channel = sample[@"channel"];
        double value = [sample[@"value"] doubleValue];
        double maxAbs = MAX([maxAbsByChannel[channel] doubleValue], fabs(value));
        maxAbsByChannel[channel] = @(maxAbs);
    }

    NSArray<NSColor *> *colors = @[
        [NSColor systemBlueColor],
        [NSColor systemGreenColor],
        [NSColor systemOrangeColor],
        [NSColor systemPurpleColor]
    ];

    for (NSUInteger channelIndex = 0; channelIndex < self.channels.count; channelIndex++) {
        NSString *channel = self.channels[channelIndex];
        double maxAbs = MAX([maxAbsByChannel[channel] doubleValue], 1.0);
        CGFloat centerY = plotRect.origin.y + laneHeight * channelIndex + laneHeight * 0.5;
        CGFloat amplitude = laneHeight * 0.42;
        NSBezierPath *path = [NSBezierPath bezierPath];
        BOOL hasPoint = NO;

        for (NSDictionary *sample in self.samples) {
            if (![sample[@"channel"] isEqualToString:channel]) {
                continue;
            }

            double seconds = [sample[@"seconds"] doubleValue];
            double value = [sample[@"value"] doubleValue];
            CGFloat x = plotRect.origin.x + (CGFloat)(seconds / self.duration) * plotRect.size.width;
            CGFloat y = centerY - (CGFloat)(value / maxAbs) * amplitude;
            if (!hasPoint) {
                [path moveToPoint:NSMakePoint(x, y)];
                hasPoint = YES;
            } else {
                [path lineToPoint:NSMakePoint(x, y)];
            }
        }

        [colors[channelIndex % colors.count] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }

    for (NSDictionary *annotation in self.annotations) {
        double seconds = [annotation[@"seconds"] doubleValue];
        if (seconds < 0.0 || seconds > self.duration) {
            continue;
        }

        CGFloat x = plotRect.origin.x + (CGFloat)(seconds / self.duration) * plotRect.size.width;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x, plotRect.origin.y)];
        [line lineToPoint:NSMakePoint(x, NSMaxY(plotRect))];
        line.lineWidth = 1.0;
        CGFloat dash[] = {4.0, 3.0};
        [line setLineDash:dash count:2 phase:0.0];
        [[NSColor systemRedColor] setStroke];
        [line stroke];

        NSString *label = annotation[@"label"] ?: @"event";
        [label drawInRect:NSMakeRect(x + 3, plotRect.origin.y + 2, 110, 14)
           withAttributes:annotationAttributes];
    }

    NSString *durationText = [NSString stringWithFormat:@"%.1fs", self.duration];
    [durationText drawInRect:NSMakeRect(NSMaxX(plotRect) - 56, NSMaxY(plotRect) + 5, 56, 16)
              withAttributes:labelAttributes];
}

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

static NSString *THActiveAppBundleID(void) {
    NSRunningApplication *application = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return application.bundleIdentifier ?: @"";
}

static NSString *THJSONString(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (data == nil) {
        return @"{}";
    }

    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static CFStringRef THCreateHIDPropertyKey(const char *key) {
    return CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
}

static NSString *THHIDStringProperty(IOHIDDeviceRef device, const char *key) {
    CFStringRef keyRef = THCreateHIDPropertyKey(key);
    CFTypeRef value = IOHIDDeviceGetProperty(device, keyRef);
    CFRelease(keyRef);

    if (value == NULL) {
        return @"";
    }

    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        return (__bridge NSString *)value;
    }

    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        return [(__bridge NSNumber *)value stringValue];
    }

    return [(__bridge id)value description] ?: @"";
}

static NSNumber *THHIDNumberProperty(IOHIDDeviceRef device, const char *key) {
    CFStringRef keyRef = THCreateHIDPropertyKey(key);
    CFTypeRef value = IOHIDDeviceGetProperty(device, keyRef);
    CFRelease(keyRef);

    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return nil;
    }

    return (__bridge NSNumber *)value;
}

static NSString *THHIDDeviceName(IOHIDDeviceRef device) {
    NSString *product = THHIDStringProperty(device, kIOHIDProductKey);
    NSString *manufacturer = THHIDStringProperty(device, kIOHIDManufacturerKey);

    if (manufacturer.length > 0 && product.length > 0) {
        return [NSString stringWithFormat:@"%@ %@", manufacturer, product];
    }

    if (product.length > 0) {
        return product;
    }

    return @"Unknown HID Device";
}

static BOOL THHIDDeviceMatchesProduct(IOHIDDeviceRef device, NSString *productContains) {
    if (productContains.length == 0) {
        return YES;
    }

    NSString *needle = [productContains lowercaseString];
    NSString *product = [THHIDStringProperty(device, kIOHIDProductKey) lowercaseString];
    NSString *manufacturer = [THHIDStringProperty(device, kIOHIDManufacturerKey) lowercaseString];
    NSString *name = [THHIDDeviceName(device) lowercaseString];

    return [product containsString:needle] ||
           [manufacturer containsString:needle] ||
           [name containsString:needle];
}

static NSString *THHIDUsageName(uint32_t usagePage, uint32_t usage) {
    if (usagePage == 0x07) {
        if (usage >= 0x04 && usage <= 0x1d) {
            unichar letter = (unichar)('a' + (usage - 0x04));
            return [NSString stringWithFormat:@"keyboard.%C", letter];
        }

        NSDictionary<NSNumber *, NSString *> *keyboardNames = @{
            @0x28: @"keyboard.return",
            @0x29: @"keyboard.escape",
            @0x2a: @"keyboard.delete",
            @0x2b: @"keyboard.tab",
            @0x2c: @"keyboard.space",
            @0x4f: @"keyboard.right-arrow",
            @0x50: @"keyboard.left-arrow",
            @0x51: @"keyboard.down-arrow",
            @0x52: @"keyboard.up-arrow",
            @0x58: @"keyboard.keypad-enter"
        };
        return keyboardNames[@(usage)] ?: [NSString stringWithFormat:@"keyboard.0x%02x", usage];
    }

    if (usagePage == 0x09) {
        return [NSString stringWithFormat:@"button.%u", usage];
    }

    if (usagePage == 0x0c) {
        return [NSString stringWithFormat:@"consumer.0x%02x", usage];
    }

    return [NSString stringWithFormat:@"hid.0x%02x.0x%02x", usagePage, usage];
}

static BOOL THHIDShouldRecordUsage(uint32_t usagePage, uint32_t usage) {
    if (usagePage == 0x07 && (usage == 0xffffffffu || usage <= 0x03)) {
        return NO;
    }

    return usagePage == 0x07 || usagePage == 0x09 || usagePage == 0x0c;
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

static NSString *THDefaultSessionsRootDirectory(void) {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *documentsURL = urls.firstObject;
    NSString *base = documentsURL.path.length > 0 ? documentsURL.path : THExpandTilde(@"~/Documents");
    return [base stringByAppendingPathComponent:@"ThumOS Sessions"];
}

static NSString *THSessionDirectoryName(void) {
    return [NSString stringWithFormat:@"thumos-session-%@", THFilenameTimestamp()];
}

static NSString *THCreatorEventsFilename(void) {
    return @"creator-events.csv";
}

static NSString *THMuseEventsFilename(void) {
    return @"muse-eeg.csv";
}

static NSString *THAnnotationsFilename(void) {
    return @"annotations.csv";
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
@property(nonatomic, strong) NSTextField *windowOutputFolderLabel;
@property(nonatomic, strong) NSPopUpButton *windowSessionPopup;
@property(nonatomic, strong) NSWindow *waveformWindow;
@property(nonatomic, strong) THWaveformView *waveformView;
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
@property(nonatomic, copy) NSString *recordingStatusOverride;
@property(nonatomic, copy) NSString *sessionsRootPath;
@property(nonatomic, copy) NSString *currentSessionDirectory;
@property(nonatomic, strong) NSFileHandle *creatorEventsFileHandle;
@property(nonatomic, strong) NSFileHandle *annotationsFileHandle;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *creatorRecentCommands;
@property(nonatomic) BOOL updatingSwitch;
@property(nonatomic) BOOL museConnected;
@property(nonatomic) BOOL museConnecting;
@property(nonatomic) BOOL museStreaming;
@property(nonatomic) BOOL eegRecording;
@property(nonatomic) BOOL talkOpen;
- (void)handleCreatorHIDValue:(IOHIDValueRef)value result:(IOReturn)result;
@end

static void THCreatorHIDValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)sender;
    ThumOSMenuController *controller = (__bridge ThumOSMenuController *)context;
    [controller handleCreatorHIDValue:value result:result];
}

@implementation ThumOSMenuController {
    IOHIDManagerRef _creatorHIDManager;
    sqlite3 *_creatorDatabase;
    sqlite3_stmt *_creatorInsertStatement;
    NSISO8601DateFormatter *_creatorDateFormatter;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildApplicationMenu];
    [self buildStatusItem];
    [self buildPopover];
    [self buildMainWindow];
    [self configureMuseChannelMap];
    [self loadSessionsRoot];
    [self disableLaunchAgentRecorder];
    [self refreshStatus];
    [self refreshSessionList:nil];
    [self showMainWindow:nil];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(refreshStatus)
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

- (void)loadSessionsRoot {
    NSString *savedPath = [[NSUserDefaults standardUserDefaults] stringForKey:THSessionsRootDefaultsKey];
    self.sessionsRootPath = savedPath.length > 0 ? [savedPath stringByExpandingTildeInPath] : THDefaultSessionsRootDirectory();
    self.creatorRecentCommands = [NSMutableArray array];
    [self updateOutputFolderLabel];
}

- (NSString *)displayPath:(NSString *)path {
    NSString *home = NSHomeDirectory();
    if ([path hasPrefix:home]) {
        return [path stringByReplacingCharactersInRange:NSMakeRange(0, home.length) withString:@"~"];
    }
    return path ?: @"";
}

- (void)updateOutputFolderLabel {
    self.windowOutputFolderLabel.stringValue = self.sessionsRootPath.length > 0 ? [self displayPath:self.sessionsRootPath] : @"No folder selected";
}

- (BOOL)ensureSessionsRootWithMessage:(NSString **)message {
    if (self.sessionsRootPath.length == 0) {
        self.sessionsRootPath = THDefaultSessionsRootDirectory();
    }

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:self.sessionsRootPath
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        if (message != NULL) {
            *message = error.localizedDescription ?: @"Could not create sessions folder.";
        }
        return NO;
    }

    return YES;
}

- (void)chooseOutputFolder:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = self.sessionsRootPath.length > 0 ? [NSURL fileURLWithPath:self.sessionsRootPath] : nil;
    panel.message = @"Choose where ThumOS session folders should be saved.";

    if ([panel runModal] != NSModalResponseOK || panel.URL.path.length == 0) {
        return;
    }

    self.sessionsRootPath = panel.URL.path;
    [[NSUserDefaults standardUserDefaults] setObject:self.sessionsRootPath forKey:THSessionsRootDefaultsKey];
    [self updateOutputFolderLabel];
    [self refreshSessionList:nil];
}

- (NSArray<NSString *> *)sessionDirectories {
    if (self.sessionsRootPath.length == 0) {
        return @[];
    }

    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.sessionsRootPath error:nil];
    NSMutableArray<NSString *> *sessions = [NSMutableArray array];
    for (NSString *item in items) {
        NSString *path = [self.sessionsRootPath stringByAppendingPathComponent:item];
        BOOL isDirectory = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
            NSString *musePath = [path stringByAppendingPathComponent:THMuseEventsFilename()];
            NSString *creatorPath = [path stringByAppendingPathComponent:THCreatorEventsFilename()];
            if ([[NSFileManager defaultManager] fileExistsAtPath:musePath] ||
                [[NSFileManager defaultManager] fileExistsAtPath:creatorPath]) {
                [sessions addObject:path];
            }
        }
    }

    return [sessions sortedArrayUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
        return [[second lastPathComponent] compare:[first lastPathComponent]];
    }];
}

- (void)refreshSessionList:(id)sender {
    (void)sender;
    [self.windowSessionPopup removeAllItems];
    NSArray<NSString *> *sessions = [self sessionDirectories];
    if (sessions.count == 0) {
        [self.windowSessionPopup addItemWithTitle:@"No sessions"];
        self.windowSessionPopup.enabled = NO;
        return;
    }

    self.windowSessionPopup.enabled = YES;
    for (NSString *path in sessions) {
        [self.windowSessionPopup addItemWithTitle:path.lastPathComponent];
        self.windowSessionPopup.lastItem.representedObject = path;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.refreshTimer invalidate];
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

    NSTextField *recording = [self labelWithString:@"Session Recording"
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
    NSRect frame = NSMakeRect(0, 0, 700, 470);
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
                                         frame:NSMakeRect(24, 412, 220, 28)
                                          font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                         color:nil];
    [content addSubview:title];

    NSTextField *subtitle = [self labelWithString:@"Creator Micro and Muse recorder"
                                            frame:NSMakeRect(24, 388, 300, 18)
                                             font:[NSFont systemFontOfSize:12]
                                            color:[NSColor secondaryLabelColor]];
    [content addSubview:subtitle];

    NSTextField *recording = [self labelWithString:@"Session Recording"
                                             frame:NSMakeRect(24, 342, 180, 20)
                                              font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                             color:nil];
    [content addSubview:recording];

    self.windowRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(624, 336, 50, 28)];
    self.windowRecordingSwitch.target = self;
    self.windowRecordingSwitch.action = @selector(toggleRecording:);
    [content addSubview:self.windowRecordingSwitch];

    self.windowStatusLabel = [self labelWithString:@"Off"
                                             frame:NSMakeRect(24, 318, 640, 18)
                                              font:[NSFont systemFontOfSize:12]
                                             color:[NSColor secondaryLabelColor]];
    [content addSubview:self.windowStatusLabel];

    NSTextField *museLabel = [self labelWithString:@"Muse Headset"
                                             frame:NSMakeRect(24, 278, 180, 20)
                                              font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                             color:nil];
    [content addSubview:museLabel];

    self.windowMuseButton = [NSButton buttonWithTitle:@"Connect Muse" target:self action:@selector(toggleMuseConnection:)];
    self.windowMuseButton.frame = NSMakeRect(558, 273, 116, 28);
    [content addSubview:self.windowMuseButton];

    self.windowMuseStatusLabel = [self labelWithString:@"Disconnected"
                                                 frame:NSMakeRect(24, 254, 640, 18)
                                                  font:[NSFont systemFontOfSize:12]
                                                 color:[NSColor secondaryLabelColor]];
    [content addSubview:self.windowMuseStatusLabel];

    NSTextField *folderLabel = [self labelWithString:@"Output Folder"
                                               frame:NSMakeRect(24, 214, 180, 20)
                                                font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                               color:nil];
    [content addSubview:folderLabel];

    NSButton *chooseFolderButton = [NSButton buttonWithTitle:@"Choose Folder" target:self action:@selector(chooseOutputFolder:)];
    chooseFolderButton.frame = NSMakeRect(548, 209, 126, 28);
    [content addSubview:chooseFolderButton];

    self.windowOutputFolderLabel = [self labelWithString:@""
                                                  frame:NSMakeRect(24, 190, 640, 18)
                                                   font:[NSFont systemFontOfSize:12]
                                                  color:[NSColor secondaryLabelColor]];
    [content addSubview:self.windowOutputFolderLabel];

    NSTextField *sessionsLabel = [self labelWithString:@"Session Viewer"
                                                 frame:NSMakeRect(24, 150, 180, 20)
                                                  font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                                 color:nil];
    [content addSubview:sessionsLabel];

    self.windowSessionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 116, 360, 30) pullsDown:NO];
    [content addSubview:self.windowSessionPopup];

    NSButton *refreshSessionsButton = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshSessionList:)];
    refreshSessionsButton.frame = NSMakeRect(396, 117, 82, 28);
    [content addSubview:refreshSessionsButton];

    NSButton *viewWaveformButton = [NSButton buttonWithTitle:@"View Waveform" target:self action:@selector(showWaveform:)];
    viewWaveformButton.frame = NSMakeRect(486, 117, 120, 28);
    [content addSubview:viewWaveformButton];

    NSTextField *databaseLabel = [self labelWithString:@"Data"
                                                 frame:NSMakeRect(24, 74, 80, 18)
                                                  font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                                 color:nil];
    [content addSubview:databaseLabel];

    NSButton *showDataButton = [NSButton buttonWithTitle:@"Show Data" target:self action:@selector(showData:)];
    showDataButton.frame = NSMakeRect(20, 38, 92, 28);
    [content addSubview:showDataButton];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export CSV" target:self action:@selector(exportCSV:)];
    exportButton.frame = NSMakeRect(120, 38, 96, 28);
    [content addSubview:exportButton];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear Events" target:self action:@selector(clearEvents:)];
    clearButton.frame = NSMakeRect(564, 39, 110, 28);
    [content addSubview:clearButton];

    [self updateOutputFolderLabel];
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
    return _creatorHIDManager != NULL;
}

- (BOOL)ensureCreatorInputMonitoringAccessWithMessage:(NSString **)message {
    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    if (access == kIOHIDAccessTypeGranted) {
        return YES;
    }

    if (access == kIOHIDAccessTypeUnknown) {
        if (IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)) {
            return YES;
        }
        access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    }

    if (message != NULL) {
        *message = access == kIOHIDAccessTypeDenied
            ? @"Allow ThumOS in System Settings > Privacy & Security > Input Monitoring."
            : @"Input Monitoring permission is required for Creator Recording.";
    }

    NSURL *settingsURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"];
    if (settingsURL != nil) {
        [[NSWorkspace sharedWorkspace] openURL:settingsURL];
    }
    return NO;
}

- (void)refreshStatus {
    BOOL running = [self isRecording];

    self.updatingSwitch = YES;
    self.popoverRecordingSwitch.state = running ? NSControlStateValueOn : NSControlStateValueOff;
    self.windowRecordingSwitch.state = running ? NSControlStateValueOn : NSControlStateValueOff;
     self.updatingSwitch = NO;
     self.statusItem.button.title = running ? @"ThumOS On" : @"ThumOS Off";
    NSString *stoppedStatus = self.recordingStatusOverride.length > 0 ? self.recordingStatusOverride : @"Recorder is stopped.";
    self.popoverStatusLabel.stringValue = running ? @"Recorder is running" : stoppedStatus;
    self.windowStatusLabel.stringValue = running ? @"Recorder is running in the background." : stoppedStatus;
     [self syncMuseControls];
 }

- (void)toggleRecording:(id)sender {
    (void)sender;
    if (self.updatingSwitch) {
        return;
    }

    NSSwitch *senderSwitch = [sender isKindOfClass:[NSSwitch class]] ? sender : nil;
    BOOL shouldRecord = senderSwitch.state == NSControlStateValueOn;
    if (shouldRecord) {
         NSString *permissionMessage = nil;
         if (![self ensureCreatorInputMonitoringAccessWithMessage:&permissionMessage]) {
            self.recordingStatusOverride = permissionMessage ?: @"Input Monitoring permission is required.";
             self.updatingSwitch = YES;
             self.popoverRecordingSwitch.state = NSControlStateValueOff;
             self.windowRecordingSwitch.state = NSControlStateValueOff;
             self.updatingSwitch = NO;
            [self refreshStatus];
             return;
         }
     }

    self.recordingStatusOverride = nil;
     self.popoverRecordingSwitch.enabled = NO;
    self.windowRecordingSwitch.enabled = NO;
    self.popoverStatusLabel.stringValue = shouldRecord ? @"Starting..." : @"Stopping...";
    self.windowStatusLabel.stringValue = shouldRecord ? @"Starting recorder..." : @"Stopping recorder...";

    NSString *message = nil;
    BOOL success = shouldRecord ? [self startRecording:&message] : [self stopRecording:&message];
    self.popoverRecordingSwitch.enabled = YES;
    self.windowRecordingSwitch.enabled = YES;
    if (!success) {
        self.recordingStatusOverride = message ?: @"Error";
    } else {
        self.recordingStatusOverride = nil;
        [self refreshSessionList:nil];
    }
    [self refreshStatus];
  }

- (BOOL)openSessionFilesWithMessage:(NSString **)message {
    if (![self ensureSessionsRootWithMessage:message]) {
        return NO;
    }

    NSString *sessionDirectory = [self.sessionsRootPath stringByAppendingPathComponent:THSessionDirectoryName()];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:sessionDirectory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        if (message != NULL) {
            *message = error.localizedDescription ?: @"Could not create session folder.";
        }
        return NO;
    }

    NSString *creatorPath = [sessionDirectory stringByAppendingPathComponent:THCreatorEventsFilename()];
    NSString *annotationsPath = [sessionDirectory stringByAppendingPathComponent:THAnnotationsFilename()];
    NSString *creatorHeader = @"timestamp_utc,monotonic_ns,device_name,command_id,event_type,key_code,raw_payload\n";
    NSString *annotationsHeader = @"timestamp_utc,monotonic_ns,label,type,command_id\n";

    if (![creatorHeader writeToFile:creatorPath atomically:YES encoding:NSUTF8StringEncoding error:&error] ||
        ![annotationsHeader writeToFile:annotationsPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        if (message != NULL) {
            *message = error.localizedDescription ?: @"Could not create session CSV files.";
        }
        return NO;
    }

    self.creatorEventsFileHandle = [NSFileHandle fileHandleForWritingAtPath:creatorPath];
    self.annotationsFileHandle = [NSFileHandle fileHandleForWritingAtPath:annotationsPath];
    if (self.creatorEventsFileHandle == nil || self.annotationsFileHandle == nil) {
        if (message != NULL) {
            *message = @"Could not open session CSV files for writing.";
        }
        self.creatorEventsFileHandle = nil;
        self.annotationsFileHandle = nil;
        return NO;
    }

    [self.creatorEventsFileHandle seekToEndOfFile];
    [self.annotationsFileHandle seekToEndOfFile];
    self.currentSessionDirectory = sessionDirectory;
    [self.creatorRecentCommands removeAllObjects];
    self.talkOpen = NO;

    NSDictionary *metadata = @{
        @"started_at_utc": THISODateString([NSDate date]),
        @"session_folder": sessionDirectory.lastPathComponent,
        @"format_version": @1,
        @"creator_events": THCreatorEventsFilename(),
        @"muse_eeg": THMuseEventsFilename(),
        @"annotations": THAnnotationsFilename()
    };
    NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil];
    if (metadataData != nil) {
        NSString *metadataPath = [sessionDirectory stringByAppendingPathComponent:@"session.json"];
        [metadataData writeToFile:metadataPath atomically:YES];
    }

    return YES;
}

- (void)closeSessionFiles {
    if (self.creatorEventsFileHandle != nil) {
        @try {
            [self.creatorEventsFileHandle closeFile];
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
    if (self.annotationsFileHandle != nil) {
        @try {
            [self.annotationsFileHandle closeFile];
        } @catch (NSException *exception) {
            (void)exception;
        }
    }

    self.creatorEventsFileHandle = nil;
    self.annotationsFileHandle = nil;
    [self.creatorRecentCommands removeAllObjects];
    self.talkOpen = NO;
}

- (void)writeLine:(NSString *)line toFileHandle:(NSFileHandle *)fileHandle {
    if (line.length == 0 || fileHandle == nil) {
        return;
    }

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    @try {
        [fileHandle writeData:data];
    } @catch (NSException *exception) {
        (void)exception;
    }
}

- (BOOL)isCreatorCommandModifierCommandID:(NSString *)commandID {
    return [commandID isEqualToString:@"keyboard.0xe3"] ||
           [commandID isEqualToString:@"keyboard.0xe7"] ||
           [commandID isEqualToString:@"keyboard.left-command"] ||
           [commandID isEqualToString:@"keyboard.right-command"];
}

- (NSUInteger)recentCommandCountForCommandID:(NSString *)commandID beforeMonotonicNS:(sqlite3_int64)monotonicNS windowNS:(sqlite3_int64)windowNS {
    NSUInteger count = 0;
    for (NSDictionary *entry in self.creatorRecentCommands) {
        sqlite3_int64 entryNS = [entry[@"monotonicNS"] longLongValue];
        if (entryNS > 0 && monotonicNS >= entryNS && (monotonicNS - entryNS) <= windowNS &&
            [entry[@"commandID"] isEqualToString:commandID]) {
            count++;
        }
    }
    return count;
}

- (BOOL)hasRecentCommandModifierBeforeMonotonicNS:(sqlite3_int64)monotonicNS windowNS:(sqlite3_int64)windowNS {
    for (NSDictionary *entry in self.creatorRecentCommands) {
        sqlite3_int64 entryNS = [entry[@"monotonicNS"] longLongValue];
        NSString *commandID = entry[@"commandID"];
        if (entryNS > 0 && monotonicNS >= entryNS && (monotonicNS - entryNS) <= windowNS &&
            [self isCreatorCommandModifierCommandID:commandID]) {
            return YES;
        }
    }
    return NO;
}

- (void)writeAnnotationWithTimestamp:(NSString *)timestampUTC
                         monotonicNS:(sqlite3_int64)monotonicNS
                               label:(NSString *)label
                                type:(NSString *)type
                           commandID:(NSString *)commandID {
    NSString *line = [NSString stringWithFormat:@"%@,%lld,%@,%@,%@\n",
                                                timestampUTC ?: @"",
                                                monotonicNS,
                                                THCSVField(label),
                                                THCSVField(type),
                                                THCSVField(commandID)];
    [self writeLine:line toFileHandle:self.annotationsFileHandle];
}

- (void)processSemanticCreatorCommandID:(NSString *)commandID timestampUTC:(NSString *)timestampUTC monotonicNS:(sqlite3_int64)monotonicNS {
    sqlite3_int64 sequenceWindowNS = 900000000LL;

    if ([commandID isEqualToString:@"keyboard.return"] || [commandID isEqualToString:@"keyboard.keypad-enter"]) {
        NSUInteger downCount = [self recentCommandCountForCommandID:@"keyboard.down-arrow"
                                                  beforeMonotonicNS:monotonicNS
                                                           windowNS:sequenceWindowNS];
        if (downCount >= 2) {
            [self writeAnnotationWithTimestamp:timestampUTC monotonicNS:monotonicNS label:@"no" type:@"no" commandID:commandID];
        } else if (downCount == 1) {
            [self writeAnnotationWithTimestamp:timestampUTC monotonicNS:monotonicNS label:@"allow permission" type:@"allow_permission" commandID:commandID];
        } else {
            [self writeAnnotationWithTimestamp:timestampUTC monotonicNS:monotonicNS label:@"yes" type:@"yes" commandID:commandID];
        }
    } else if ([commandID isEqualToString:@"keyboard.right-arrow"] &&
               [self hasRecentCommandModifierBeforeMonotonicNS:monotonicNS windowNS:sequenceWindowNS]) {
        self.talkOpen = !self.talkOpen;
        NSString *type = self.talkOpen ? @"talk_start" : @"talk_end";
        NSString *label = self.talkOpen ? @"talk start" : @"talk end";
        [self writeAnnotationWithTimestamp:timestampUTC monotonicNS:monotonicNS label:label type:type commandID:commandID];
    }

    [self.creatorRecentCommands addObject:@{@"commandID": commandID ?: @"",
                                            @"monotonicNS": @(monotonicNS)}];
    NSMutableArray<NSDictionary *> *kept = [NSMutableArray array];
    sqlite3_int64 keepWindowNS = 2000000000LL;
    for (NSDictionary *entry in self.creatorRecentCommands) {
        sqlite3_int64 entryNS = [entry[@"monotonicNS"] longLongValue];
        if (entryNS > 0 && monotonicNS >= entryNS && (monotonicNS - entryNS) <= keepWindowNS) {
            [kept addObject:entry];
        }
    }
    self.creatorRecentCommands = kept;
}

- (NSString *)creatorSQLiteErrorMessage:(NSString *)fallback {
    const char *message = _creatorDatabase != NULL ? sqlite3_errmsg(_creatorDatabase) : NULL;
    if (message != NULL) {
        return [NSString stringWithUTF8String:message];
    }
    return fallback;
}

- (BOOL)openCreatorEventStoreWithMessage:(NSString **)message {
    if (_creatorDatabase != NULL && _creatorInsertStatement != NULL) {
        return YES;
    }

    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:THApplicationSupportDirectory()
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&directoryError]) {
        if (message != NULL) {
            *message = directoryError.localizedDescription;
        }
        return NO;
    }

    if (sqlite3_open_v2([THDatabasePath() fileSystemRepresentation],
                        &_creatorDatabase,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                        NULL) != SQLITE_OK) {
        if (message != NULL) {
            *message = [self creatorSQLiteErrorMessage:@"Could not open event database."];
        }
        [self closeCreatorEventStore];
        return NO;
    }

    const char *schema =
        "PRAGMA journal_mode=WAL;"
        "CREATE TABLE IF NOT EXISTS input_events ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  source TEXT NOT NULL,"
        "  device_name TEXT,"
        "  command_id TEXT NOT NULL,"
        "  command_label TEXT NOT NULL,"
        "  event_type TEXT NOT NULL,"
        "  key_code INTEGER NOT NULL,"
        "  modifiers INTEGER NOT NULL,"
        "  occurred_at_utc TEXT NOT NULL,"
        "  monotonic_ns INTEGER NOT NULL,"
        "  active_app_bundle_id TEXT,"
        "  raw_payload TEXT"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_input_events_occurred_at ON input_events(occurred_at_utc);"
        "CREATE INDEX IF NOT EXISTS idx_input_events_command ON input_events(command_id, occurred_at_utc);";

    char *errorMessage = NULL;
    if (sqlite3_exec(_creatorDatabase, schema, NULL, NULL, &errorMessage) != SQLITE_OK) {
        if (message != NULL) {
            *message = errorMessage != NULL ? [NSString stringWithUTF8String:errorMessage] : @"Could not initialize event database.";
        }
        sqlite3_free(errorMessage);
        [self closeCreatorEventStore];
        return NO;
    }
    sqlite3_free(errorMessage);

    const char *insertSQL =
        "INSERT INTO input_events ("
        "source, device_name, command_id, command_label, event_type, key_code, modifiers, occurred_at_utc, monotonic_ns, active_app_bundle_id, raw_payload"
        ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";
    if (sqlite3_prepare_v2(_creatorDatabase, insertSQL, -1, &_creatorInsertStatement, NULL) != SQLITE_OK) {
        if (message != NULL) {
            *message = [self creatorSQLiteErrorMessage:@"Could not prepare event insert."];
        }
        [self closeCreatorEventStore];
        return NO;
    }

    _creatorDateFormatter = [[NSISO8601DateFormatter alloc] init];
    _creatorDateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    _creatorDateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return YES;
}

- (void)closeCreatorEventStore {
    if (_creatorInsertStatement != NULL) {
        sqlite3_finalize(_creatorInsertStatement);
        _creatorInsertStatement = NULL;
    }

    if (_creatorDatabase != NULL) {
        sqlite3_close(_creatorDatabase);
        _creatorDatabase = NULL;
    }

    _creatorDateFormatter = nil;
}

- (BOOL)recordCreatorHIDEventWithDeviceName:(NSString *)deviceName
                                  commandID:(NSString *)commandID
                                  eventType:(NSString *)eventType
                                    keyCode:(NSInteger)keyCode
                                monotonicNS:(sqlite3_int64)monotonicNS
                                 rawPayload:(NSString *)rawPayload {
    if (_creatorInsertStatement == NULL) {
        return NO;
    }

    NSString *occurredAt = [_creatorDateFormatter stringFromDate:[NSDate date]];
    NSString *activeAppBundleID = THActiveAppBundleID();

    sqlite3_reset(_creatorInsertStatement);
    sqlite3_clear_bindings(_creatorInsertStatement);
    sqlite3_bind_text(_creatorInsertStatement, 1, "hid", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_creatorInsertStatement, 2, [deviceName UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_creatorInsertStatement, 3, [commandID UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_creatorInsertStatement, 4, [commandID UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_creatorInsertStatement, 5, [eventType UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(_creatorInsertStatement, 6, (sqlite3_int64)keyCode);
    sqlite3_bind_int64(_creatorInsertStatement, 7, 0);
    sqlite3_bind_text(_creatorInsertStatement, 8, [occurredAt UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(_creatorInsertStatement, 9, monotonicNS);
    sqlite3_bind_text(_creatorInsertStatement, 10, [activeAppBundleID UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_creatorInsertStatement, 11, [rawPayload UTF8String], -1, SQLITE_TRANSIENT);

    int stepResult = sqlite3_step(_creatorInsertStatement);
    sqlite3_reset(_creatorInsertStatement);
    return stepResult == SQLITE_DONE;
}

- (void)handleCreatorHIDValue:(IOHIDValueRef)value result:(IOReturn)result {
    if (result != kIOReturnSuccess || value == NULL || _creatorInsertStatement == NULL) {
        return;
    }

    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (element == NULL) {
        return;
    }

    uint32_t usagePage = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    if (!THHIDShouldRecordUsage(usagePage, usage)) {
        return;
    }

    IOHIDDeviceRef device = IOHIDElementGetDevice(element);
    if (device == NULL || !THHIDDeviceMatchesProduct(device, @"Creator")) {
        return;
    }

    CFIndex integerValue = IOHIDValueGetIntegerValue(value);
    if (integerValue == 0) {
        return;
    }

    NSString *usageName = THHIDUsageName(usagePage, usage);
    NSString *deviceName = THHIDDeviceName(device);
    NSNumber *vendorID = THHIDNumberProperty(device, kIOHIDVendorIDKey) ?: @-1;
    NSNumber *productID = THHIDNumberProperty(device, kIOHIDProductIDKey) ?: @-1;
    NSNumber *locationID = THHIDNumberProperty(device, kIOHIDLocationIDKey) ?: @-1;
    NSString *transport = THHIDStringProperty(device, kIOHIDTransportKey);
    NSString *manufacturer = THHIDStringProperty(device, kIOHIDManufacturerKey);
    NSString *product = THHIDStringProperty(device, kIOHIDProductKey);
    uint64_t hidTimestamp = IOHIDValueGetTimeStamp(value);
    NSString *rawPayload = THJSONString(@{
        @"vendorID": vendorID,
        @"productID": productID,
        @"locationID": locationID,
        @"transport": transport,
        @"manufacturer": manufacturer,
        @"product": product,
        @"usagePage": @(usagePage),
        @"usage": @(usage),
        @"value": @((long long)integerValue),
        @"hidTimestamp": @(hidTimestamp)
    });

    [self recordCreatorHIDEventWithDeviceName:deviceName
                                    commandID:usageName
                                    eventType:@"press"
                                      keyCode:(NSInteger)usage
                                  monotonicNS:(sqlite3_int64)hidTimestamp
                                   rawPayload:rawPayload];
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

    if (![self ensureCreatorInputMonitoringAccessWithMessage:message]) {
        return NO;
    }

    if (![self openCreatorEventStoreWithMessage:message]) {
        return NO;
    }

    _creatorHIDManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (_creatorHIDManager == NULL) {
        if (message != NULL) {
            *message = @"Could not create Creator HID monitor.";
        }
        [self closeCreatorEventStore];
        return NO;
    }

    IOHIDManagerSetDeviceMatching(_creatorHIDManager, NULL);
    IOHIDManagerRegisterInputValueCallback(_creatorHIDManager, THCreatorHIDValueCallback, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_creatorHIDManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);

    IOReturn openResult = IOHIDManagerOpen(_creatorHIDManager, kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
        if (message != NULL) {
            *message = [NSString stringWithFormat:@"Could not open Creator HID monitor: 0x%x", openResult];
        }
        [self stopRecording:nil];
        return NO;
    }

    return YES;
}

- (BOOL)stopRecording:(NSString **)message {
    (void)message;
    if (_creatorHIDManager != NULL) {
        IOHIDManagerUnscheduleFromRunLoop(_creatorHIDManager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDManagerClose(_creatorHIDManager, kIOHIDOptionsTypeNone);
        CFRelease(_creatorHIDManager);
        _creatorHIDManager = NULL;
    }

    [self closeCreatorEventStore];
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
