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
    CGFloat bottom = 72.0;
    NSRect plotRect = NSMakeRect(left,
                                 top,
                                 MAX(10.0, self.bounds.size.width - left - right),
                                 MAX(10.0, self.bounds.size.height - top - bottom));
    CGFloat laneHeight = plotRect.size.height / self.channels.count;

    NSDictionary *labelAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                      NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    NSDictionary *annotationAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                           NSForegroundColorAttributeName: [NSColor blackColor]};
    NSColor *waveformColor = [NSColor systemBlueColor];
    NSColor *annotationColor = [[NSColor blackColor] colorWithAlphaComponent:0.72];

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

        [waveformColor setStroke];
        path.lineWidth = 1.2;
        [path stroke];
    }

    NSMutableArray<NSDictionary *> *visibleAnnotations = [NSMutableArray array];
    for (NSDictionary *annotation in self.annotations) {
        double seconds = [annotation[@"seconds"] doubleValue];
        if (seconds < 0.0 || seconds > self.duration) {
            continue;
        }
        [visibleAnnotations addObject:annotation];
    }

    [visibleAnnotations sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        double firstSeconds = [first[@"seconds"] doubleValue];
        double secondSeconds = [second[@"seconds"] doubleValue];
        if (firstSeconds < secondSeconds) {
            return NSOrderedAscending;
        }
        if (firstSeconds > secondSeconds) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    CGFloat labelGap = 5.0;
    CGFloat labelBandY = NSMaxY(plotRect) + 7.0;
    CGFloat maxLabelRight = NSMaxX(plotRect);
    CGFloat labelRightEdge = plotRect.origin.x;

    for (NSDictionary *annotation in visibleAnnotations) {
        double seconds = [annotation[@"seconds"] doubleValue];

        CGFloat x = plotRect.origin.x + (CGFloat)(seconds / self.duration) * plotRect.size.width;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x, plotRect.origin.y)];
        [line lineToPoint:NSMakePoint(x, NSMaxY(plotRect) + 4.0)];
        line.lineWidth = 1.0;
        CGFloat dash[] = {4.0, 3.0};
        [line setLineDash:dash count:2 phase:0.0];
        [annotationColor setStroke];
        [line stroke];

        NSString *sourceLabel = annotation[@"label"] ?: @"event";
        NSString *sourceType = annotation[@"type"] ?: @"";
        NSString *label = sourceLabel;
        if ([sourceType isEqualToString:@"yes"] || [sourceLabel isEqualToString:@"yes"]) {
            label = @"Y";
        } else if ([sourceType isEqualToString:@"no"] || [sourceLabel isEqualToString:@"no"]) {
            label = @"N";
        } else if ([sourceType isEqualToString:@"allow_permission"] || [sourceLabel isEqualToString:@"allow permission"]) {
            label = @"P";
        } else if ([sourceType hasPrefix:@"talk"] || [sourceLabel hasPrefix:@"talk"]) {
            label = @"T";
        }
        CGFloat measuredWidth = [label sizeWithAttributes:annotationAttributes].width + 10.0;
        CGFloat labelWidth = MIN(MAX(measuredWidth, 18.0), 24.0);
        CGFloat preferredX = MIN(MAX(x - labelWidth * 0.5, plotRect.origin.x), maxLabelRight - labelWidth);
        CGFloat labelX = MAX(preferredX, labelRightEdge + labelGap);
        if (labelX + labelWidth > maxLabelRight) {
            continue;
        }

        [label drawInRect:NSMakeRect(labelX, labelBandY, labelWidth, 14.0)
           withAttributes:annotationAttributes];
        labelRightEdge = labelX + labelWidth;
    }

    NSString *durationText = [NSString stringWithFormat:@"%.1fs", self.duration];
    [durationText drawInRect:NSMakeRect(NSMaxX(plotRect) - 56, self.bounds.size.height - 20.0, 56, 16)
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

static NSString *THCreatorEventsHeader(void) {
    return @"timestamp_utc,monotonic_ns,device_name,command_id,event_type,key_code,raw_payload\n";
}

static NSString *THMuseEventsHeader(void) {
    return @"recording_started_at_utc,sample_timestamp_utc,device_name,channel,channel_sample_index,value_uv\n";
}

static NSString *THAnnotationsHeader(void) {
    return @"timestamp_utc,monotonic_ns,label,type,command_id\n";
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
@property(nonatomic, strong) NSTextField *viewerFolderLabel;
@property(nonatomic, strong) NSTextField *viewerStatusLabel;
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
@property(nonatomic, copy) NSString *viewerSessionsRootPath;
@property(nonatomic, copy) NSString *currentSessionDirectory;
@property(nonatomic, copy) NSString *lastFinishedSessionDirectory;
@property(nonatomic, strong) NSFileHandle *creatorEventsFileHandle;
@property(nonatomic, strong) NSFileHandle *annotationsFileHandle;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *creatorRecentCommands;
@property(nonatomic) BOOL updatingSwitch;
@property(nonatomic) BOOL museConnected;
@property(nonatomic) BOOL museConnecting;
@property(nonatomic) BOOL museStreaming;
@property(nonatomic) BOOL eegRecording;
@property(nonatomic) BOOL talkOpen;
@property(nonatomic) BOOL recordingStatusIsError;
@property(nonatomic) BOOL viewerFolderCustomized;
- (void)handleCreatorHIDValue:(IOHIDValueRef)value result:(IOReturn)result;
- (void)refreshSessionListSelectingPath:(NSString *)preferredPath;
- (NSString *)sessionDirectoryForActions;
- (BOOL)sessionDirectoryHasData:(NSString *)path;
- (BOOL)sessionDirectoryHasAnnotatedWaveform:(NSString *)path;
- (void)chooseViewerFolder:(id)sender;
- (void)selectViewerSession:(id)sender;
- (void)openSelectedSessionFolder:(id)sender;
- (void)startEEGRecording;
- (NSImage *)crownStatusImageForRecording:(BOOL)recording;
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
    self.viewerSessionsRootPath = self.sessionsRootPath;
    self.viewerFolderCustomized = NO;
    self.creatorRecentCommands = [NSMutableArray array];
    [self updateOutputFolderLabel];
    [self updateViewerFolderLabel];
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

- (void)updateViewerFolderLabel {
    self.viewerFolderLabel.stringValue = self.viewerSessionsRootPath.length > 0 ? [self displayPath:self.viewerSessionsRootPath] : @"No viewer folder selected";
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
    if (!self.viewerFolderCustomized) {
        self.viewerSessionsRootPath = self.sessionsRootPath;
        [self updateViewerFolderLabel];
    }
    [self updateOutputFolderLabel];
    [self refreshSessionList:nil];
}

- (void)chooseViewerFolder:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = self.viewerSessionsRootPath.length > 0 ? [NSURL fileURLWithPath:self.viewerSessionsRootPath] : nil;
    panel.message = @"Choose a folder containing ThumOS session folders.";

    if ([panel runModal] != NSModalResponseOK || panel.URL.path.length == 0) {
        return;
    }

    self.viewerSessionsRootPath = panel.URL.path;
    self.viewerFolderCustomized = YES;
    [self updateViewerFolderLabel];
    [self refreshSessionList:nil];
}

- (BOOL)fileAtPath:(NSString *)path hasBytesBeyondHeader:(NSString *)header {
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attributes == nil) {
        return NO;
    }

    unsigned long long fileSize = [attributes fileSize];
    NSUInteger headerSize = [[header dataUsingEncoding:NSUTF8StringEncoding] length];
    return fileSize > headerSize;
}

- (BOOL)sessionDirectoryHasData:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }

    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
        return NO;
    }

    NSString *musePath = [path stringByAppendingPathComponent:THMuseEventsFilename()];
    NSString *creatorPath = [path stringByAppendingPathComponent:THCreatorEventsFilename()];
    NSString *annotationsPath = [path stringByAppendingPathComponent:THAnnotationsFilename()];
    return [[NSFileManager defaultManager] fileExistsAtPath:musePath] ||
           [[NSFileManager defaultManager] fileExistsAtPath:creatorPath] ||
           [[NSFileManager defaultManager] fileExistsAtPath:annotationsPath];
}

- (BOOL)sessionDirectoryHasAnnotatedWaveform:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }

    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
        return NO;
    }

    NSString *musePath = [path stringByAppendingPathComponent:THMuseEventsFilename()];
    NSString *annotationsPath = [path stringByAppendingPathComponent:THAnnotationsFilename()];
    return [self fileAtPath:musePath hasBytesBeyondHeader:THMuseEventsHeader()] &&
           [self fileAtPath:annotationsPath hasBytesBeyondHeader:THAnnotationsHeader()];
}

- (void)addSessionDirectoriesFromRoot:(NSString *)root toSet:(NSMutableSet<NSString *> *)sessions {
    NSString *standardRoot = [[root stringByExpandingTildeInPath] stringByStandardizingPath];
    if (standardRoot.length == 0) {
        return;
    }

    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:standardRoot error:nil];
    for (NSString *item in items) {
        NSString *path = [[standardRoot stringByAppendingPathComponent:item] stringByStandardizingPath];
        if ([self sessionDirectoryHasAnnotatedWaveform:path]) {
            [sessions addObject:path];
        }
    }
}

- (NSArray<NSString *> *)sessionDirectories {
    NSMutableSet<NSString *> *sessions = [NSMutableSet set];
    NSString *root = self.viewerSessionsRootPath.length > 0 ? self.viewerSessionsRootPath : self.sessionsRootPath;
    [self addSessionDirectoriesFromRoot:root toSet:sessions];

    NSString *lastFinished = [self.lastFinishedSessionDirectory stringByStandardizingPath];
    if ([self sessionDirectoryHasAnnotatedWaveform:lastFinished]) {
        [sessions addObject:lastFinished];
    }

    return [sessions.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
        return [[second lastPathComponent] compare:[first lastPathComponent]];
    }];
}

- (void)refreshSessionList:(id)sender {
    (void)sender;
    [self refreshSessionListSelectingPath:nil];
}

- (void)refreshSessionListSelectingPath:(NSString *)preferredPath {
    NSString *previousSelection = preferredPath ?: [self selectedSessionDirectory] ?: self.lastFinishedSessionDirectory;
    NSString *standardPreviousSelection = [previousSelection stringByStandardizingPath];
    [self.windowSessionPopup removeAllItems];

    NSArray<NSString *> *sessions = [self sessionDirectories];
    if (sessions.count == 0) {
        [self.windowSessionPopup addItemWithTitle:@"No annotated waveforms"];
        self.windowSessionPopup.enabled = NO;
        self.viewerStatusLabel.stringValue = @"No annotated waveforms found.";
        self.viewerStatusLabel.textColor = [NSColor secondaryLabelColor];
        self.waveformView.samples = @[];
        self.waveformView.annotations = @[];
        self.waveformView.channels = @[];
        self.waveformView.duration = 0.0;
        return;
    }

    self.windowSessionPopup.enabled = YES;
    BOOL selectedPreferred = NO;
    for (NSString *path in sessions) {
        [self.windowSessionPopup addItemWithTitle:path.lastPathComponent];
        self.windowSessionPopup.lastItem.representedObject = path;
        if (!selectedPreferred &&
            standardPreviousSelection.length > 0 &&
            [[path stringByStandardizingPath] isEqualToString:standardPreviousSelection]) {
            [self.windowSessionPopup selectItem:self.windowSessionPopup.lastItem];
            selectedPreferred = YES;
        }
    }

    [self selectViewerSession:nil];
}

- (NSString *)selectedSessionDirectory {
    id representedObject = self.windowSessionPopup.selectedItem.representedObject;
    return [representedObject isKindOfClass:[NSString class]] ? representedObject : nil;
}

- (NSString *)sessionDirectoryForActions {
    NSString *selected = [self selectedSessionDirectory];
    if ([self sessionDirectoryHasData:selected]) {
        return selected;
    }
    if ([self sessionDirectoryHasData:self.currentSessionDirectory]) {
        return self.currentSessionDirectory;
    }
    if ([self sessionDirectoryHasData:self.lastFinishedSessionDirectory]) {
        return self.lastFinishedSessionDirectory;
    }
    return nil;
}

- (NSDate *)dateFromISOString:(NSString *)string formatter:(NSISO8601DateFormatter *)formatter {
    if (string.length == 0) {
        return nil;
    }
    return [formatter dateFromString:string];
}

- (BOOL)loadWaveformSession:(NSString *)sessionDirectory message:(NSString **)message {
    NSString *musePath = [sessionDirectory stringByAppendingPathComponent:THMuseEventsFilename()];
    NSString *annotationsPath = [sessionDirectory stringByAppendingPathComponent:THAnnotationsFilename()];
    NSString *museText = [NSString stringWithContentsOfFile:musePath encoding:NSUTF8StringEncoding error:nil];
    if (museText.length == 0) {
        if (message != NULL) {
            *message = @"Selected session has no Muse EEG CSV.";
        }
        return NO;
    }

    NSArray<NSString *> *lines = [museText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSUInteger sampleLineCount = lines.count > 0 ? lines.count - 1 : 0;
    NSUInteger stride = MAX((NSUInteger)1, sampleLineCount / 80000);
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *channels = [NSMutableOrderedSet orderedSet];
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];

    NSDate *startDate = nil;
    NSDate *endDate = nil;
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index];
        if (line.length == 0 || (index % stride) != 0) {
            continue;
        }

        NSArray<NSString *> *columns = [line componentsSeparatedByString:@","];
        if (columns.count < 6) {
            continue;
        }

        NSDate *sampleDate = [self dateFromISOString:columns[1] formatter:formatter];
        if (sampleDate == nil) {
            continue;
        }
        if (startDate == nil) {
            startDate = sampleDate;
        }
        endDate = sampleDate;
        NSString *channel = columns[3];
        [channels addObject:channel];
        NSTimeInterval seconds = [sampleDate timeIntervalSinceDate:startDate];
        [samples addObject:@{@"seconds": @(MAX(0.0, seconds)),
                             @"channel": channel,
                             @"value": @([columns[5] doubleValue])}];
    }

    if (samples.count == 0 || startDate == nil) {
        if (message != NULL) {
            *message = @"Selected session has no readable Muse samples.";
        }
        return NO;
    }

    NSString *annotationsText = [NSString stringWithContentsOfFile:annotationsPath encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<NSDictionary *> *annotations = [NSMutableArray array];
    for (NSString *line in [annotationsText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0 || [line hasPrefix:@"timestamp_utc,"]) {
            continue;
        }

        NSArray<NSString *> *columns = [line componentsSeparatedByString:@","];
        if (columns.count < 4) {
            continue;
        }

        NSDate *annotationDate = [self dateFromISOString:columns[0] formatter:formatter];
        if (annotationDate == nil) {
            continue;
        }
        NSTimeInterval seconds = [annotationDate timeIntervalSinceDate:startDate];
        [annotations addObject:@{@"seconds": @(seconds),
                                 @"label": columns[2],
                                 @"type": columns[3]}];
    }

    self.waveformView.samples = samples;
    self.waveformView.annotations = annotations;
    self.waveformView.channels = channels.array;
    self.waveformView.duration = MAX([endDate timeIntervalSinceDate:startDate], 0.1);
    return YES;
}

- (void)buildWaveformWindowIfNeeded {
    if (self.waveformWindow != nil) {
        return;
    }

    NSRect frame = NSMakeRect(0, 0, 920, 540);
    self.waveformWindow = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    self.waveformWindow.title = @"ThumOS Waveform";
    self.waveformWindow.releasedWhenClosed = NO;
    [self.waveformWindow center];

    self.waveformView = [[THWaveformView alloc] initWithFrame:frame];
    self.waveformView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.waveformWindow.contentView = self.waveformView;
}

- (void)showWaveform:(id)sender {
    (void)sender;
    NSString *sessionDirectory = [self sessionDirectoryForActions];
    if (sessionDirectory.length == 0) {
        self.viewerStatusLabel.stringValue = @"Select an annotated waveform first.";
        self.viewerStatusLabel.textColor = [NSColor secondaryLabelColor];
        return;
    }

    NSString *message = nil;
    if (![self loadWaveformSession:sessionDirectory message:&message]) {
        self.viewerStatusLabel.stringValue = message ?: @"Could not load waveform.";
        self.viewerStatusLabel.textColor = [NSColor systemRedColor];
        return;
    }

    self.viewerStatusLabel.stringValue = [NSString stringWithFormat:@"Showing %@", sessionDirectory.lastPathComponent];
    self.viewerStatusLabel.textColor = [NSColor secondaryLabelColor];
}

- (void)selectViewerSession:(id)sender {
    (void)sender;
    [self showWaveform:nil];
}

- (void)openSelectedSessionFolder:(id)sender {
    (void)sender;
    NSString *sessionDirectory = [self sessionDirectoryForActions];
    if (sessionDirectory.length == 0) {
        self.viewerStatusLabel.stringValue = [NSString stringWithFormat:@"No annotated waveforms found in %@.", [self displayPath:self.viewerSessionsRootPath]];
        self.viewerStatusLabel.textColor = [NSColor secondaryLabelColor];
        return;
    }

    NSURL *sessionURL = [NSURL fileURLWithPath:sessionDirectory];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[sessionURL]];
    self.viewerStatusLabel.stringValue = [NSString stringWithFormat:@"Opened %@", [self displayPath:sessionDirectory]];
    self.viewerStatusLabel.textColor = [NSColor secondaryLabelColor];
}

- (NSString *)selectedSessionCreatorEventsText {
    NSString *sessionDirectory = [self sessionDirectoryForActions];
    if (sessionDirectory.length == 0) {
        return @"Select a session first.";
    }

    NSString *path = [sessionDirectory stringByAppendingPathComponent:THCreatorEventsFilename()];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return text.length > 0 ? text : @"No Creator events found for this session.";
}

- (NSString *)selectedSessionExportFilename {
    NSString *sessionDirectory = [self sessionDirectoryForActions];
    NSString *name = sessionDirectory.lastPathComponent.length > 0 ? sessionDirectory.lastPathComponent : @"thumos-session";
    return [NSString stringWithFormat:@"%@-creator-events.csv", name];
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
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.title = @"";
    self.statusItem.button.image = [self crownStatusImageForRecording:NO];
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.toolTip = @"ThumOS recorder";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
}

- (NSImage *)crownStatusImageForRecording:(BOOL)recording {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [image lockFocus];

    [[NSColor clearColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 18, 18));
    [[NSColor blackColor] setStroke];
    [[NSColor blackColor] setFill];

    NSBezierPath *crown = [NSBezierPath bezierPath];
    [crown moveToPoint:NSMakePoint(3.4, 4.6)];
    [crown lineToPoint:NSMakePoint(3.4, 13.2)];
    [crown lineToPoint:NSMakePoint(6.8, 8.8)];
    [crown lineToPoint:NSMakePoint(9.0, 14.8)];
    [crown lineToPoint:NSMakePoint(11.2, 8.8)];
    [crown lineToPoint:NSMakePoint(14.6, 13.2)];
    [crown lineToPoint:NSMakePoint(14.6, 4.6)];
    [crown closePath];
    crown.lineWidth = 1.35;
    crown.lineJoinStyle = NSLineJoinStyleRound;
    if (recording) {
        [crown fill];
    }
    [crown stroke];

    NSBezierPath *base = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(3.0, 2.5, 12.0, 2.8)
                                                         xRadius:1.0
                                                         yRadius:1.0];
    base.lineWidth = 1.25;
    if (recording) {
        [base fill];
    }
    [base stroke];

    [image unlockFocus];
    image.template = YES;
    return image;
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

    controller.view = view;
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = controller;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.delegate = self;
}

- (void)buildMainWindow {
    NSRect frame = NSMakeRect(0, 0, 920, 620);
    self.mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.mainWindow.title = @"ThumOS";
    self.mainWindow.delegate = self;
    self.mainWindow.releasedWhenClosed = NO;
    self.mainWindow.minSize = NSMakeSize(720, 500);
    [self.mainWindow center];

    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.mainWindow.contentView = content;

    NSTextField *title = [self labelWithString:@"ThumOS"
                                         frame:NSMakeRect(24, 562, 220, 28)
                                          font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                         color:nil];
    title.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [content addSubview:title];

    NSTextField *subtitle = [self labelWithString:@"Creator Micro and Muse recorder"
                                            frame:NSMakeRect(24, 538, 300, 18)
                                             font:[NSFont systemFontOfSize:12]
                                            color:[NSColor secondaryLabelColor]];
    subtitle.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [content addSubview:subtitle];

    NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(20, 20, 880, 500)];
    tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:tabView];

    NSTabViewItem *controlItem = [[NSTabViewItem alloc] initWithIdentifier:@"control"];
    controlItem.label = @"Control";
    NSView *controlView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 860, 450)];
    controlView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    controlItem.view = controlView;
    [tabView addTabViewItem:controlItem];

    NSTextField *recording = [self labelWithString:@"Session Recording"
                                             frame:NSMakeRect(24, 385, 180, 20)
                                              font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                             color:nil];
    recording.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [controlView addSubview:recording];

    self.windowRecordingSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(780, 379, 50, 28)];
    self.windowRecordingSwitch.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.windowRecordingSwitch.target = self;
    self.windowRecordingSwitch.action = @selector(toggleRecording:);
    [controlView addSubview:self.windowRecordingSwitch];

    self.windowStatusLabel = [self labelWithString:@"Off"
                                             frame:NSMakeRect(24, 361, 800, 18)
                                              font:[NSFont systemFontOfSize:12]
                                             color:[NSColor secondaryLabelColor]];
    self.windowStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [controlView addSubview:self.windowStatusLabel];

    NSTextField *museLabel = [self labelWithString:@"Muse Headset"
                                             frame:NSMakeRect(24, 306, 180, 20)
                                              font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                             color:nil];
    museLabel.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [controlView addSubview:museLabel];

    self.windowMuseButton = [NSButton buttonWithTitle:@"Connect Muse" target:self action:@selector(toggleMuseConnection:)];
    self.windowMuseButton.frame = NSMakeRect(704, 301, 126, 28);
    self.windowMuseButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [controlView addSubview:self.windowMuseButton];

    self.windowMuseStatusLabel = [self labelWithString:@"Disconnected"
                                                 frame:NSMakeRect(24, 282, 800, 18)
                                                  font:[NSFont systemFontOfSize:12]
                                                 color:[NSColor secondaryLabelColor]];
    self.windowMuseStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [controlView addSubview:self.windowMuseStatusLabel];

    NSTextField *folderLabel = [self labelWithString:@"Output Folder"
                                               frame:NSMakeRect(24, 226, 180, 20)
                                                font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                               color:nil];
    folderLabel.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [controlView addSubview:folderLabel];

    NSButton *chooseFolderButton = [NSButton buttonWithTitle:@"Choose Folder" target:self action:@selector(chooseOutputFolder:)];
    chooseFolderButton.frame = NSMakeRect(704, 221, 126, 28);
    chooseFolderButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [controlView addSubview:chooseFolderButton];

    self.windowOutputFolderLabel = [self labelWithString:@""
                                                  frame:NSMakeRect(24, 202, 800, 18)
                                                   font:[NSFont systemFontOfSize:12]
                                                  color:[NSColor secondaryLabelColor]];
    self.windowOutputFolderLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [controlView addSubview:self.windowOutputFolderLabel];

    NSTabViewItem *viewerItem = [[NSTabViewItem alloc] initWithIdentifier:@"viewer"];
    viewerItem.label = @"Viewer";
    NSView *viewerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 860, 450)];
    viewerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    viewerItem.view = viewerView;
    [tabView addTabViewItem:viewerItem];

    NSTextField *viewerFolderTitle = [self labelWithString:@"Viewer Folder"
                                                     frame:NSMakeRect(24, 390, 180, 20)
                                                      font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                                     color:nil];
    viewerFolderTitle.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:viewerFolderTitle];

    NSButton *chooseViewerFolderButton = [NSButton buttonWithTitle:@"Choose Folder" target:self action:@selector(chooseViewerFolder:)];
    chooseViewerFolderButton.frame = NSMakeRect(150, 386, 112, 28);
    chooseViewerFolderButton.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:chooseViewerFolderButton];

    self.viewerFolderLabel = [self labelWithString:@""
                                             frame:NSMakeRect(24, 366, 238, 18)
                                              font:[NSFont systemFontOfSize:11]
                                             color:[NSColor secondaryLabelColor]];
    self.viewerFolderLabel.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:self.viewerFolderLabel];

    NSTextField *sessionsLabel = [self labelWithString:@"Annotated Waveforms"
                                                 frame:NSMakeRect(24, 326, 220, 20)
                                                  font:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium]
                                                 color:nil];
    sessionsLabel.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:sessionsLabel];

    self.windowSessionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 292, 238, 30) pullsDown:NO];
    self.windowSessionPopup.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    self.windowSessionPopup.target = self;
    self.windowSessionPopup.action = @selector(selectViewerSession:);
    [viewerView addSubview:self.windowSessionPopup];

    NSButton *refreshSessionsButton = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshSessionList:)];
    refreshSessionsButton.frame = NSMakeRect(24, 250, 78, 28);
    refreshSessionsButton.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:refreshSessionsButton];

    NSButton *openSessionButton = [NSButton buttonWithTitle:@"Open Folder" target:self action:@selector(openSelectedSessionFolder:)];
    openSessionButton.frame = NSMakeRect(112, 250, 106, 28);
    openSessionButton.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:openSessionButton];

    NSTextField *databaseLabel = [self labelWithString:@"Data"
                                                 frame:NSMakeRect(24, 200, 80, 18)
                                                  font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                                 color:nil];
    databaseLabel.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:databaseLabel];

    NSButton *showDataButton = [NSButton buttonWithTitle:@"Show Data" target:self action:@selector(showData:)];
    showDataButton.frame = NSMakeRect(20, 164, 92, 28);
    showDataButton.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:showDataButton];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export CSV" target:self action:@selector(exportCSV:)];
    exportButton.frame = NSMakeRect(120, 164, 96, 28);
    exportButton.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [viewerView addSubview:exportButton];

    self.viewerStatusLabel = [self labelWithString:@"Select an annotated waveform."
                                             frame:NSMakeRect(300, 410, 520, 18)
                                              font:[NSFont systemFontOfSize:12]
                                             color:[NSColor secondaryLabelColor]];
    self.viewerStatusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [viewerView addSubview:self.viewerStatusLabel];

    self.waveformView = [[THWaveformView alloc] initWithFrame:NSMakeRect(300, 36, 540, 360)];
    self.waveformView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [viewerView addSubview:self.waveformView];

    [self updateOutputFolderLabel];
    [self updateViewerFolderLabel];
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
    self.statusItem.button.title = @"";
    self.statusItem.button.image = [self crownStatusImageForRecording:running];
    self.statusItem.button.toolTip = running ? @"ThumOS recorder is on" : @"ThumOS recorder is off";
    NSString *runningStatus = self.recordingStatusOverride.length > 0 ? self.recordingStatusOverride : @"Recording session.";
    NSString *stoppedStatus = self.recordingStatusOverride.length > 0 ? self.recordingStatusOverride : @"Recorder is stopped.";
    NSColor *statusColor = self.recordingStatusIsError ? [NSColor systemRedColor] : [NSColor secondaryLabelColor];
    self.popoverStatusLabel.textColor = statusColor;
    self.windowStatusLabel.textColor = statusColor;
    self.popoverStatusLabel.stringValue = running ? runningStatus : stoppedStatus;
    self.windowStatusLabel.stringValue = running ? runningStatus : stoppedStatus;
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
        if (!self.museConnected) {
            self.recordingStatusOverride = @"Muse headset is not connected.";
            self.recordingStatusIsError = YES;
            self.updatingSwitch = YES;
            self.popoverRecordingSwitch.state = NSControlStateValueOff;
            self.windowRecordingSwitch.state = NSControlStateValueOff;
            self.updatingSwitch = NO;
            [self refreshStatus];
            return;
        }

         NSString *permissionMessage = nil;
         if (![self ensureCreatorInputMonitoringAccessWithMessage:&permissionMessage]) {
            self.recordingStatusOverride = permissionMessage ?: @"Input Monitoring permission is required.";
            self.recordingStatusIsError = YES;
             self.updatingSwitch = YES;
             self.popoverRecordingSwitch.state = NSControlStateValueOff;
             self.windowRecordingSwitch.state = NSControlStateValueOff;
             self.updatingSwitch = NO;
            [self refreshStatus];
             return;
         }
     }

    self.recordingStatusOverride = nil;
    self.recordingStatusIsError = NO;
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
        self.recordingStatusIsError = YES;
    } else {
        self.recordingStatusOverride = message;
        self.recordingStatusIsError = NO;
        [self refreshSessionListSelectingPath:shouldRecord ? self.currentSessionDirectory : self.lastFinishedSessionDirectory];
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
    NSString *creatorHeader = THCreatorEventsHeader();
    NSString *annotationsHeader = THAnnotationsHeader();

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
    if (self.creatorEventsFileHandle == nil) {
        return NO;
    }

    NSString *timestampUTC = THISODateString([NSDate date]);
    NSString *line = [NSString stringWithFormat:@"%@,%lld,%@,%@,%@,%ld,%@\n",
                                                timestampUTC,
                                                monotonicNS,
                                                THCSVField(deviceName),
                                                THCSVField(commandID),
                                                THCSVField(eventType),
                                                (long)keyCode,
                                                THCSVField(rawPayload)];
    [self writeLine:line toFileHandle:self.creatorEventsFileHandle];
    [self processSemanticCreatorCommandID:commandID timestampUTC:timestampUTC monotonicNS:monotonicNS];
    return YES;
}

- (void)handleCreatorHIDValue:(IOHIDValueRef)value result:(IOReturn)result {
    if (result != kIOReturnSuccess || value == NULL || self.creatorEventsFileHandle == nil) {
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
    if (connected && [self.recordingStatusOverride isEqualToString:@"Muse headset is not connected."]) {
        self.recordingStatusOverride = nil;
        self.recordingStatusIsError = NO;
        [self refreshStatus];
    }
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
    if ([self isRecording] && !self.eegRecording) {
        [self startEEGRecording];
    }
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

    if (self.currentSessionDirectory.length == 0) {
        [self setMuseStatus:@"Start a session before EEG recording." connected:YES];
        return;
    }

    NSError *error = nil;
    NSString *filename = THMuseEventsFilename();
    NSString *path = [self.currentSessionDirectory stringByAppendingPathComponent:filename];
    NSString *header = THMuseEventsHeader();
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
    BOOL stoppedSession = NO;
    if ([self isRecording]) {
        NSString *message = nil;
        [self stopRecording:&message];
        self.recordingStatusOverride = @"Stopped recording because Muse headset disconnected.";
        self.recordingStatusIsError = YES;
        [self refreshSessionListSelectingPath:self.lastFinishedSessionDirectory];
        stoppedSession = YES;
    } else if (self.eegRecording || self.eegFileHandle != nil) {
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
    if (stoppedSession) {
        [self refreshStatus];
    }
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

    BOOL stoppedSession = NO;
    if ([self isRecording]) {
        NSString *savedMessage = nil;
        [self stopRecording:&savedMessage];
        self.recordingStatusOverride = @"Stopped recording because Muse headset disconnected.";
        self.recordingStatusIsError = YES;
        [self refreshSessionListSelectingPath:self.lastFinishedSessionDirectory];
        stoppedSession = YES;
    } else if (self.eegRecording || self.eegFileHandle != nil) {
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
    if (stoppedSession) {
        [self refreshStatus];
    }
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
    self.dataTextView.string = [self selectedSessionCreatorEventsText];
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
    panel.nameFieldStringValue = [self selectedSessionExportFilename];
    panel.canCreateDirectories = YES;

    NSModalResponse response = [panel runModal];
    if (response != NSModalResponseOK || panel.URL == nil) {
        return;
    }

    NSString *csv = [self selectedSessionCreatorEventsText];
    if (csv.length == 0) {
        csv = @"timestamp_utc,monotonic_ns,device_name,command_id,event_type,key_code,raw_payload\n";
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

    if (!self.museConnected) {
        if (message != NULL) {
            *message = @"Muse headset is not connected.";
        }
        return NO;
    }

    if (![self ensureCreatorInputMonitoringAccessWithMessage:message]) {
        return NO;
    }

    if (![self openSessionFilesWithMessage:message]) {
        return NO;
    }

    _creatorHIDManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (_creatorHIDManager == NULL) {
        if (message != NULL) {
            *message = @"Could not create Creator HID monitor.";
        }
        [self closeSessionFiles];
        self.currentSessionDirectory = nil;
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

    [self startEEGRecording];
    if (!self.eegRecording) {
        if (message != NULL) {
            NSString *museMessage = self.windowMuseStatusLabel.stringValue;
            *message = museMessage.length > 0 ? museMessage : @"Could not start Muse EEG recording.";
        }
        [self stopRecording:nil];
        return NO;
    }

    if (message != NULL) {
        *message = [NSString stringWithFormat:@"Recording %@", self.currentSessionDirectory.lastPathComponent ?: @"session"];
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

    if (self.eegRecording || self.eegFileHandle != nil) {
        [self stopEEGRecordingWithStatus:NO];
    }

    NSString *finishedSession = self.currentSessionDirectory;
    [self closeSessionFiles];
    self.currentSessionDirectory = nil;
    if (finishedSession.length > 0) {
        self.lastFinishedSessionDirectory = finishedSession;
        if (message != NULL) {
            if ([self sessionDirectoryHasData:finishedSession]) {
                *message = [NSString stringWithFormat:@"Saved %@ in %@", finishedSession.lastPathComponent, [self displayPath:finishedSession.stringByDeletingLastPathComponent]];
            } else {
                *message = [NSString stringWithFormat:@"Stopped; session folder not found at %@", [self displayPath:finishedSession]];
            }
        }
    }
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
