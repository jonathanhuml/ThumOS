#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <sqlite3.h>
#import <time.h>

static CFMachPortRef gEventTap = NULL;

static CGEventFlags THRelevantModifierMask(void) {
    return kCGEventFlagMaskShift |
           kCGEventFlagMaskControl |
           kCGEventFlagMaskAlternate |
           kCGEventFlagMaskCommand |
           kCGEventFlagMaskSecondaryFn;
}

static NSString *THExpandTilde(NSString *path) {
    return [path stringByExpandingTildeInPath];
}

static NSString *THDefaultConfigPath(void) {
    return THExpandTilde(@"~/.config/thumos/creator-micro-2.json");
}

static NSString *THDefaultDatabasePath(void) {
    return THExpandTilde(@"~/Library/Application Support/ThumOS/events.sqlite3");
}

static BOOL THEnsureParentDirectory(NSString *path, NSError **error) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    return [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:error];
}

static void THPrint(NSString *message) {
    fprintf(stdout, "%s\n", [message UTF8String]);
    fflush(stdout);
}

static void THPrintError(NSString *message) {
    fprintf(stderr, "%s\n", [message UTF8String]);
    fflush(stderr);
}

static NSString *THActiveAppBundleID(void) {
    NSRunningApplication *application = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (application.bundleIdentifier.length > 0) {
        return application.bundleIdentifier;
    }
    if (application.localizedName.length > 0) {
        return application.localizedName;
    }
    return @"";
}

static uint64_t THMonotonicNanoseconds(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static CGEventFlags THModifierMaskFromStrings(NSArray *items) {
    CGEventFlags mask = 0;

    for (id item in items) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }

        NSString *name = [(NSString *)item lowercaseString];
        if ([name isEqualToString:@"command"] || [name isEqualToString:@"cmd"] || [name isEqualToString:@"meta"]) {
            mask |= kCGEventFlagMaskCommand;
        } else if ([name isEqualToString:@"control"] || [name isEqualToString:@"ctrl"]) {
            mask |= kCGEventFlagMaskControl;
        } else if ([name isEqualToString:@"option"] || [name isEqualToString:@"alt"]) {
            mask |= kCGEventFlagMaskAlternate;
        } else if ([name isEqualToString:@"shift"]) {
            mask |= kCGEventFlagMaskShift;
        } else if ([name isEqualToString:@"fn"] || [name isEqualToString:@"function"]) {
            mask |= kCGEventFlagMaskSecondaryFn;
        }
    }

    return mask;
}

static NSString *THJSONString(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (data == nil) {
        return @"{}";
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static NSString *THModifierDescription(CGEventFlags flags) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    CGEventFlags relevantFlags = flags & THRelevantModifierMask();

    if ((relevantFlags & kCGEventFlagMaskControl) != 0) {
        [names addObject:@"control"];
    }
    if ((relevantFlags & kCGEventFlagMaskAlternate) != 0) {
        [names addObject:@"option"];
    }
    if ((relevantFlags & kCGEventFlagMaskCommand) != 0) {
        [names addObject:@"command"];
    }
    if ((relevantFlags & kCGEventFlagMaskShift) != 0) {
        [names addObject:@"shift"];
    }
    if ((relevantFlags & kCGEventFlagMaskSecondaryFn) != 0) {
        [names addObject:@"fn"];
    }

    if (names.count == 0) {
        return @"none";
    }

    return [names componentsJoinedByString:@"+"];
}

static NSString *THKeyCodeName(NSInteger keyCode) {
    static NSDictionary<NSNumber *, NSString *> *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @36: @"return",
            @48: @"tab",
            @49: @"space",
            @51: @"delete",
            @53: @"escape",
            @64: @"F17",
            @79: @"F18",
            @80: @"F19",
            @90: @"F20",
            @96: @"F5",
            @97: @"F6",
            @98: @"F7",
            @99: @"F3",
            @100: @"F8",
            @101: @"F9",
            @103: @"F11",
            @105: @"F13",
            @106: @"F16",
            @107: @"F14",
            @109: @"F10",
            @111: @"F12",
            @113: @"F15",
            @115: @"home",
            @116: @"pageup",
            @117: @"forward-delete",
            @118: @"F4",
            @119: @"end",
            @120: @"F2",
            @121: @"pagedown",
            @122: @"F1",
            @123: @"left-arrow",
            @124: @"right-arrow",
            @125: @"down-arrow",
            @126: @"up-arrow"
        };
    });

    NSString *name = names[@(keyCode)];
    return name ?: @"unknown";
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
        return [(__bridge NSString *)value copy];
    }

    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        long long number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &number);
        return [NSString stringWithFormat:@"%lld", number];
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

    long long number = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &number)) {
        return nil;
    }

    return @(number);
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
    if (manufacturer.length > 0) {
        return manufacturer;
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

static BOOL THHIDShouldPrintUsage(uint32_t usagePage, uint32_t usage) {
    if (usagePage == 0x07 && (usage == 0xffffffffu || usage <= 0x03)) {
        return NO;
    }

    return usagePage == 0x07 || usagePage == 0x09 || usagePage == 0x0c;
}

static BOOL THHIDListenAccessGranted(NSError **error) {
    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    if (access == kIOHIDAccessTypeGranted) {
        return YES;
    }

    if (error != NULL) {
        NSString *message = access == kIOHIDAccessTypeDenied
            ? @"Input Monitoring permission is denied for HID recording. Enable ThumOS in System Settings > Privacy & Security > Input Monitoring."
            : @"Input Monitoring permission is required for HID recording.";
        *error = [NSError errorWithDomain:@"ThumOSHID"
                                     code:kIOReturnNotPermitted
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

static int THListHIDDevices(void) {
    NSError *error = nil;
    if (!THHIDListenAccessGranted(&error)) {
        THPrintError([NSString stringWithFormat:@"thumosd: %@", error.localizedDescription]);
        return 1;
    }

    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (manager == NULL) {
        THPrintError(@"thumosd: could not create IOHIDManager.");
        return 1;
    }

    IOHIDManagerSetDeviceMatching(manager, NULL);
    IOReturn openResult = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
        THPrintError([NSString stringWithFormat:@"thumosd: could not open IOHIDManager: 0x%x", openResult]);
        CFRelease(manager);
        return 1;
    }

    CFSetRef deviceSet = IOHIDManagerCopyDevices(manager);
    if (deviceSet == NULL) {
        THPrint(@"No HID devices found.");
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return 0;
    }

    NSArray *devices = [(__bridge NSSet *)deviceSet allObjects];
    NSArray *sortedDevices = [devices sortedArrayUsingComparator:^NSComparisonResult(id first, id second) {
        NSString *firstName = THHIDDeviceName((__bridge IOHIDDeviceRef)first);
        NSString *secondName = THHIDDeviceName((__bridge IOHIDDeviceRef)second);
        return [firstName compare:secondName options:NSCaseInsensitiveSearch];
    }];

    for (id object in sortedDevices) {
        IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
        NSNumber *vendorID = THHIDNumberProperty(device, kIOHIDVendorIDKey);
        NSNumber *productID = THHIDNumberProperty(device, kIOHIDProductIDKey);
        NSNumber *locationID = THHIDNumberProperty(device, kIOHIDLocationIDKey);
        NSNumber *usagePage = THHIDNumberProperty(device, kIOHIDPrimaryUsagePageKey);
        NSNumber *usage = THHIDNumberProperty(device, kIOHIDPrimaryUsageKey);
        NSString *transport = THHIDStringProperty(device, kIOHIDTransportKey);
        NSString *manufacturer = THHIDStringProperty(device, kIOHIDManufacturerKey);
        NSString *product = THHIDStringProperty(device, kIOHIDProductKey);
        NSString *serial = THHIDStringProperty(device, kIOHIDSerialNumberKey);

        THPrint([NSString stringWithFormat:@"hid-device vendorID=%@ productID=%@ locationID=%@ usagePage=%@ usage=%@ transport=\"%@\" manufacturer=\"%@\" product=\"%@\" serial=\"%@\"",
                                           vendorID ?: @-1,
                                           productID ?: @-1,
                                           locationID ?: @-1,
                                           usagePage ?: @-1,
                                           usage ?: @-1,
                                           transport,
                                           manufacturer,
                                           product,
                                           serial]);
    }

    CFRelease(deviceSet);
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    CFRelease(manager);
    return 0;
}

@interface THCommandMapping : NSObject
@property(nonatomic, copy) NSString *commandID;
@property(nonatomic, copy) NSString *label;
@property(nonatomic) NSInteger keyCode;
@property(nonatomic) CGEventFlags modifiers;
@end

@implementation THCommandMapping
@end

@interface THConfig : NSObject
@property(nonatomic, copy) NSString *deviceName;
@property(nonatomic) BOOL captureReleases;
@property(nonatomic) BOOL ignoreAutoRepeat;
@property(nonatomic, copy) NSArray<THCommandMapping *> *commands;
+ (NSDictionary *)defaultJSONObject;
+ (BOOL)writeDefaultConfigAtPath:(NSString *)path overwrite:(BOOL)overwrite error:(NSError **)error;
+ (instancetype)loadFromPath:(NSString *)path error:(NSError **)error;
- (THCommandMapping *)mappingForKeyCode:(NSInteger)keyCode flags:(CGEventFlags)flags;
@end

@implementation THConfig

+ (NSArray *)defaultCommandObjects {
    NSArray *entries = @[
        @[@"creator.k01", @"Creator K01", @105, @[@"control", @"option", @"command"]],
        @[@"creator.k02", @"Creator K02", @107, @[@"control", @"option", @"command"]],
        @[@"creator.k03", @"Creator K03", @113, @[@"control", @"option", @"command"]],
        @[@"creator.k04", @"Creator K04", @106, @[@"control", @"option", @"command"]],
        @[@"creator.k05", @"Creator K05", @64, @[@"control", @"option", @"command"]],
        @[@"creator.k06", @"Creator K06", @79, @[@"control", @"option", @"command"]],
        @[@"creator.k07", @"Creator K07", @80, @[@"control", @"option", @"command"]],
        @[@"creator.k08", @"Creator K08", @90, @[@"control", @"option", @"command"]],
        @[@"creator.k09", @"Creator K09", @105, @[@"control", @"option", @"command", @"shift"]],
        @[@"creator.k10", @"Creator K10", @107, @[@"control", @"option", @"command", @"shift"]],
        @[@"creator.k11", @"Creator K11", @113, @[@"control", @"option", @"command", @"shift"]],
        @[@"creator.k12", @"Creator K12", @106, @[@"control", @"option", @"command", @"shift"]],
        @[@"creator.k13", @"Creator K13", @64, @[@"control", @"option", @"command", @"shift"]]
    ];

    NSMutableArray *commands = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSArray *entry in entries) {
        [commands addObject:@{
            @"id": entry[0],
            @"label": entry[1],
            @"keyCode": entry[2],
            @"modifiers": entry[3]
        }];
    }

    return commands;
}

+ (NSDictionary *)defaultJSONObject {
    return @{
        @"device": @{
            @"name": @"Creator Micro 2 Pro",
            @"inputMode": @"shortcut"
        },
        @"settings": @{
            @"captureReleases": @YES,
            @"ignoreAutoRepeat": @YES
        },
        @"commands": [self defaultCommandObjects]
    };
}

+ (BOOL)writeDefaultConfigAtPath:(NSString *)path overwrite:(BOOL)overwrite error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (!overwrite && [fileManager fileExistsAtPath:path]) {
        return YES;
    }

    if (!THEnsureParentDirectory(path, error)) {
        return NO;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:[self defaultJSONObject]
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:error];
    if (data == nil) {
        return NO;
    }

    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

+ (instancetype)loadFromPath:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (data == nil) {
        return nil;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"ThumOSConfig"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Config root must be a JSON object."}];
        }
        return nil;
    }

    NSDictionary *root = (NSDictionary *)json;
    THConfig *config = [[THConfig alloc] init];

    NSDictionary *device = [root[@"device"] isKindOfClass:[NSDictionary class]] ? root[@"device"] : @{};
    NSDictionary *settings = [root[@"settings"] isKindOfClass:[NSDictionary class]] ? root[@"settings"] : @{};
    NSArray *commandsJSON = [root[@"commands"] isKindOfClass:[NSArray class]] ? root[@"commands"] : @[];

    config.deviceName = [device[@"name"] isKindOfClass:[NSString class]] ? device[@"name"] : @"Creator Micro";
    config.captureReleases = [settings[@"captureReleases"] respondsToSelector:@selector(boolValue)] ? [settings[@"captureReleases"] boolValue] : YES;
    config.ignoreAutoRepeat = [settings[@"ignoreAutoRepeat"] respondsToSelector:@selector(boolValue)] ? [settings[@"ignoreAutoRepeat"] boolValue] : YES;

    NSMutableArray<THCommandMapping *> *commands = [NSMutableArray arrayWithCapacity:commandsJSON.count];
    for (id item in commandsJSON) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSDictionary *commandJSON = (NSDictionary *)item;
        NSString *commandID = [commandJSON[@"id"] isKindOfClass:[NSString class]] ? commandJSON[@"id"] : nil;
        NSString *label = [commandJSON[@"label"] isKindOfClass:[NSString class]] ? commandJSON[@"label"] : commandID;
        id keyCodeValue = commandJSON[@"keyCode"];
        NSArray *modifiers = [commandJSON[@"modifiers"] isKindOfClass:[NSArray class]] ? commandJSON[@"modifiers"] : @[];

        if (commandID.length == 0 || ![keyCodeValue respondsToSelector:@selector(integerValue)]) {
            continue;
        }

        THCommandMapping *mapping = [[THCommandMapping alloc] init];
        mapping.commandID = commandID;
        mapping.label = label ?: commandID;
        mapping.keyCode = [keyCodeValue integerValue];
        mapping.modifiers = THModifierMaskFromStrings(modifiers);
        [commands addObject:mapping];
    }

    config.commands = commands;
    return config;
}

- (THCommandMapping *)mappingForKeyCode:(NSInteger)keyCode flags:(CGEventFlags)flags {
    CGEventFlags relevantFlags = flags & THRelevantModifierMask();

    for (THCommandMapping *mapping in self.commands) {
        if (mapping.keyCode == keyCode && mapping.modifiers == relevantFlags) {
            return mapping;
        }
    }

    return nil;
}

@end

@interface THEventStore : NSObject
- (instancetype)initWithPath:(NSString *)path deviceName:(NSString *)deviceName;
- (BOOL)open:(NSError **)error;
- (BOOL)recordEventWithSource:(NSString *)source
                    deviceName:(NSString *)deviceName
                     commandID:(NSString *)commandID
                  commandLabel:(NSString *)commandLabel
                     eventType:(NSString *)eventType
                       keyCode:(NSInteger)keyCode
                     modifiers:(CGEventFlags)modifiers
             activeAppBundleID:(NSString *)activeAppBundleID
                    rawPayload:(NSString *)rawPayload
                         error:(NSError **)error;
- (BOOL)recordCommand:(THCommandMapping *)mapping
            eventType:(NSString *)eventType
              keyCode:(NSInteger)keyCode
                flags:(CGEventFlags)flags
     activeAppBundleID:(NSString *)activeAppBundleID
                source:(NSString *)source
                 error:(NSError **)error;
- (void)close;
@end

@implementation THEventStore {
    NSString *_path;
    NSString *_deviceName;
    sqlite3 *_database;
    sqlite3_stmt *_insertStatement;
    NSISO8601DateFormatter *_dateFormatter;
}

- (instancetype)initWithPath:(NSString *)path deviceName:(NSString *)deviceName {
    self = [super init];
    if (self != nil) {
        _path = [path copy];
        _deviceName = [deviceName copy];
        _dateFormatter = [[NSISO8601DateFormatter alloc] init];
        _dateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        _dateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    }
    return self;
}

- (BOOL)open:(NSError **)error {
    if (!THEnsureParentDirectory(_path, error)) {
        return NO;
    }

    int openResult = sqlite3_open([_path fileSystemRepresentation], &_database);
    if (openResult != SQLITE_OK) {
        [self fillSQLiteError:error message:@"Could not open SQLite database."];
        return NO;
    }

    sqlite3_busy_timeout(_database, 5000);

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

    char *schemaError = NULL;
    int schemaResult = sqlite3_exec(_database, schema, NULL, NULL, &schemaError);
    if (schemaResult != SQLITE_OK) {
        NSString *message = schemaError != NULL ? [NSString stringWithUTF8String:schemaError] : @"Could not initialize database schema.";
        sqlite3_free(schemaError);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"ThumOSSQLite"
                                         code:schemaResult
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return NO;
    }

    const char *insertSQL =
        "INSERT INTO input_events ("
        "source, device_name, command_id, command_label, event_type, key_code, modifiers, occurred_at_utc, monotonic_ns, active_app_bundle_id, raw_payload"
        ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";

    int prepareResult = sqlite3_prepare_v2(_database, insertSQL, -1, &_insertStatement, NULL);
    if (prepareResult != SQLITE_OK) {
        [self fillSQLiteError:error message:@"Could not prepare insert statement."];
        return NO;
    }

    return YES;
}

- (BOOL)recordCommand:(THCommandMapping *)mapping
            eventType:(NSString *)eventType
              keyCode:(NSInteger)keyCode
                flags:(CGEventFlags)flags
     activeAppBundleID:(NSString *)activeAppBundleID
                source:(NSString *)source
                 error:(NSError **)error {
    NSString *rawPayload = THJSONString(@{
        @"keyCode": @(keyCode),
        @"modifiers": @(flags),
        @"matchedModifiers": @(mapping.modifiers)
    });

    return [self recordEventWithSource:source
                            deviceName:_deviceName
                             commandID:mapping.commandID
                          commandLabel:mapping.label
                             eventType:eventType
                               keyCode:keyCode
                             modifiers:mapping.modifiers
                     activeAppBundleID:activeAppBundleID
                            rawPayload:rawPayload
                                 error:error];
}

- (BOOL)recordEventWithSource:(NSString *)source
                    deviceName:(NSString *)deviceName
                     commandID:(NSString *)commandID
                  commandLabel:(NSString *)commandLabel
                     eventType:(NSString *)eventType
                       keyCode:(NSInteger)keyCode
                     modifiers:(CGEventFlags)modifiers
             activeAppBundleID:(NSString *)activeAppBundleID
                    rawPayload:(NSString *)rawPayload
                         error:(NSError **)error {
    if (_insertStatement == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"ThumOSSQLite"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Database is not open."}];
        }
        return NO;
    }

    NSString *occurredAt = [_dateFormatter stringFromDate:[NSDate date]];
    uint64_t monotonic = THMonotonicNanoseconds();

    sqlite3_reset(_insertStatement);
    sqlite3_clear_bindings(_insertStatement);

    sqlite3_bind_text(_insertStatement, 1, [source UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_insertStatement, 2, [deviceName UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_insertStatement, 3, [commandID UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_insertStatement, 4, [commandLabel UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_insertStatement, 5, [eventType UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(_insertStatement, 6, (sqlite3_int64)keyCode);
    sqlite3_bind_int64(_insertStatement, 7, (sqlite3_int64)modifiers);
    sqlite3_bind_text(_insertStatement, 8, [occurredAt UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(_insertStatement, 9, (sqlite3_int64)monotonic);
    sqlite3_bind_text(_insertStatement, 10, [activeAppBundleID UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(_insertStatement, 11, [rawPayload UTF8String], -1, SQLITE_TRANSIENT);

    int stepResult = sqlite3_step(_insertStatement);
    if (stepResult != SQLITE_DONE) {
        [self fillSQLiteError:error message:@"Could not insert input event."];
        return NO;
    }

    return YES;
}

- (void)close {
    if (_insertStatement != NULL) {
        sqlite3_finalize(_insertStatement);
        _insertStatement = NULL;
    }
    if (_database != NULL) {
        sqlite3_close(_database);
        _database = NULL;
    }
}

- (void)dealloc {
    [self close];
}

- (void)fillSQLiteError:(NSError **)error message:(NSString *)fallback {
    if (error == NULL) {
        return;
    }

    const char *sqliteMessage = _database != NULL ? sqlite3_errmsg(_database) : NULL;
    NSString *message = sqliteMessage != NULL ? [NSString stringWithUTF8String:sqliteMessage] : fallback;
    *error = [NSError errorWithDomain:@"ThumOSSQLite"
                                 code:_database != NULL ? sqlite3_errcode(_database) : -1
                             userInfo:@{NSLocalizedDescriptionKey: message ?: fallback}];
}

@end

@interface THRecorder : NSObject
- (instancetype)initWithConfig:(THConfig *)config store:(THEventStore *)store printEvents:(BOOL)printEvents discoverKeys:(BOOL)discoverKeys;
- (void)handleEventType:(CGEventType)type event:(CGEventRef)event;
@end

@implementation THRecorder {
    THConfig *_config;
    THEventStore *_store;
    BOOL _printEvents;
    BOOL _discoverKeys;
    NSMutableDictionary<NSNumber *, THCommandMapping *> *_activeCommandsByKeyCode;
}

- (instancetype)initWithConfig:(THConfig *)config store:(THEventStore *)store printEvents:(BOOL)printEvents discoverKeys:(BOOL)discoverKeys {
    self = [super init];
    if (self != nil) {
        _config = config;
        _store = store;
        _printEvents = printEvents;
        _discoverKeys = discoverKeys;
        _activeCommandsByKeyCode = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)handleEventType:(CGEventType)type event:(CGEventRef)event {
    if (type != kCGEventKeyDown && type != kCGEventKeyUp) {
        return;
    }

    NSInteger keyCode = (NSInteger)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags flags = CGEventGetFlags(event);
    BOOL isAutoRepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;

    if (_discoverKeys && !isAutoRepeat) {
        NSString *eventName = type == kCGEventKeyDown ? @"down" : @"up";
        int64_t keyboardType = CGEventGetIntegerValueField(event, kCGKeyboardEventKeyboardType);
        int64_t sourcePID = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
        int64_t targetPID = CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID);
        int64_t sourceUID = CGEventGetIntegerValueField(event, kCGEventSourceUserID);
        THPrint([NSString stringWithFormat:@"discover %@ keyCode=%ld key=%@ modifiers=%@ flags=%llu keyboardType=%lld sourcePID=%lld targetPID=%lld sourceUID=%lld activeApp=%@",
                                           eventName,
                                           (long)keyCode,
                                           THKeyCodeName(keyCode),
                                           THModifierDescription(flags),
                                           (unsigned long long)(flags & THRelevantModifierMask()),
                                           keyboardType,
                                           sourcePID,
                                           targetPID,
                                           sourceUID,
                                           THActiveAppBundleID()]);
    }

    if (type == kCGEventKeyDown && _config.ignoreAutoRepeat) {
        if (isAutoRepeat) {
            return;
        }
    }

    THCommandMapping *mapping = nil;
    NSString *eventType = nil;

    if (type == kCGEventKeyDown) {
        mapping = [_config mappingForKeyCode:keyCode flags:flags];
        if (mapping == nil) {
            return;
        }

        _activeCommandsByKeyCode[@(keyCode)] = mapping;
        eventType = @"press";
    } else {
        if (!_config.captureReleases) {
            return;
        }

        mapping = _activeCommandsByKeyCode[@(keyCode)];
        if (mapping == nil) {
            return;
        }

        [_activeCommandsByKeyCode removeObjectForKey:@(keyCode)];
        eventType = @"release";
    }

    NSString *activeApp = THActiveAppBundleID();
    NSError *error = nil;
    BOOL inserted = [_store recordCommand:mapping
                                eventType:eventType
                                  keyCode:keyCode
                                    flags:flags
                         activeAppBundleID:activeApp
                                    source:@"shortcut"
                                     error:&error];
    if (!inserted) {
        THPrintError([NSString stringWithFormat:@"thumosd: %@", error.localizedDescription]);
        return;
    }

    if (_printEvents) {
        THPrint([NSString stringWithFormat:@"%@ %@ %@", eventType, mapping.commandID, activeApp]);
    }
}

@end

static CGEventRef THEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gEventTap != NULL) {
            CGEventTapEnable(gEventTap, true);
        }
        return event;
    }

    THRecorder *recorder = (__bridge THRecorder *)refcon;
    [recorder handleEventType:type event:event];
    return event;
}

@interface THHIDMonitor : NSObject
- (instancetype)initWithStore:(THEventStore *)store
              productContains:(NSString *)productContains
                   printEvents:(BOOL)printEvents
                  recordEvents:(BOOL)recordEvents;
- (BOOL)start:(NSError **)error;
- (void)handleValue:(IOHIDValueRef)value result:(IOReturn)result;
@end

static void THHIDValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)sender;
    THHIDMonitor *monitor = (__bridge THHIDMonitor *)context;
    [monitor handleValue:value result:result];
}

@implementation THHIDMonitor {
    THEventStore *_store;
    NSString *_productContains;
    BOOL _printEvents;
    BOOL _recordEvents;
    IOHIDManagerRef _manager;
}

- (instancetype)initWithStore:(THEventStore *)store
              productContains:(NSString *)productContains
                   printEvents:(BOOL)printEvents
                  recordEvents:(BOOL)recordEvents {
    self = [super init];
    if (self != nil) {
        _store = store;
        _productContains = [productContains copy];
        _printEvents = printEvents;
        _recordEvents = recordEvents;
    }
    return self;
  }

  - (BOOL)start:(NSError **)error {
      if (!THHIDListenAccessGranted(error)) {
          return NO;
      }

      _manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
      if (_manager == NULL) {
          if (error != NULL) {
            *error = [NSError errorWithDomain:@"ThumOSHID"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not create IOHIDManager."}];
        }
        return NO;
    }

    IOHIDManagerSetDeviceMatching(_manager, NULL);
    IOHIDManagerRegisterInputValueCallback(_manager, THHIDValueCallback, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_manager, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

    IOReturn openResult = IOHIDManagerOpen(_manager, kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"ThumOSHID"
                                         code:openResult
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open IOHIDManager: 0x%x", openResult]}];
        }
        return NO;
    }

    return YES;
}

- (void)handleValue:(IOHIDValueRef)value result:(IOReturn)result {
    if (result != kIOReturnSuccess || value == NULL) {
        return;
    }

    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (element == NULL) {
        return;
    }

    uint32_t usagePage = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    if (!THHIDShouldPrintUsage(usagePage, usage)) {
        return;
    }

    IOHIDDeviceRef device = IOHIDElementGetDevice(element);
    if (device == NULL || !THHIDDeviceMatchesProduct(device, _productContains)) {
        return;
    }

    CFIndex integerValue = IOHIDValueGetIntegerValue(value);
    NSString *eventType = integerValue == 0 ? @"release" : @"press";
    NSString *usageName = THHIDUsageName(usagePage, usage);
    NSString *deviceName = THHIDDeviceName(device);
    NSNumber *vendorID = THHIDNumberProperty(device, kIOHIDVendorIDKey) ?: @-1;
    NSNumber *productID = THHIDNumberProperty(device, kIOHIDProductIDKey) ?: @-1;
    NSNumber *locationID = THHIDNumberProperty(device, kIOHIDLocationIDKey) ?: @-1;
    NSString *transport = THHIDStringProperty(device, kIOHIDTransportKey);
    NSString *manufacturer = THHIDStringProperty(device, kIOHIDManufacturerKey);
    NSString *product = THHIDStringProperty(device, kIOHIDProductKey);
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
        @"hidTimestamp": @(IOHIDValueGetTimeStamp(value))
    });

    if (_printEvents && (!_recordEvents || integerValue != 0)) {
        THPrint([NSString stringWithFormat:@"hid %@ device=\"%@\" vendorID=%@ productID=%@ locationID=%@ usagePage=0x%02x usage=0x%02x name=%@ value=%ld",
                                           eventType,
                                           deviceName,
                                           vendorID,
                                           productID,
                                           locationID,
                                           usagePage,
                                           usage,
                                           usageName,
                                           (long)integerValue]);
    }

    if (!_recordEvents) {
        return;
    }

    if (integerValue == 0) {
        return;
    }

    NSError *error = nil;
    BOOL inserted = [_store recordEventWithSource:@"hid"
                                       deviceName:deviceName
                                        commandID:usageName
                                     commandLabel:usageName
                                        eventType:eventType
                                          keyCode:(NSInteger)usage
                                        modifiers:0
                                activeAppBundleID:THActiveAppBundleID()
                                       rawPayload:rawPayload
                                            error:&error];
    if (!inserted) {
        THPrintError([NSString stringWithFormat:@"thumosd: %@", error.localizedDescription]);
    }
}

- (void)dealloc {
    if (_manager != NULL) {
        IOHIDManagerUnscheduleFromRunLoop(_manager, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        IOHIDManagerClose(_manager, kIOHIDOptionsTypeNone);
        CFRelease(_manager);
        _manager = NULL;
    }
}

@end

static void THPrintUsage(void) {
    THPrint(@"usage: thumosd [--init] [--config PATH] [--database PATH] [--print-events] [--discover-keys] [--discover-hid] [--hid-record] [--hid-product TEXT] [--list-hid-devices] [--request-permission] [--record-sample]");
    THPrint(@"");
    THPrint(@"options:");
    THPrint(@"  --init                Create default config and database schema, then exit.");
    THPrint(@"  --config PATH         JSON command map. Defaults to ~/.config/thumos/creator-micro-2.json.");
    THPrint(@"  --database PATH       SQLite event log. Defaults to ~/Library/Application Support/ThumOS/events.sqlite3.");
    THPrint(@"  --print-events        Print matched events while recording.");
    THPrint(@"  --discover-keys       Print observed key codes/modifiers for mapping diagnostics.");
    THPrint(@"  --discover-hid        Print physical HID device input values without storing them.");
    THPrint(@"  --hid-record          Record physical HID input values. Requires --hid-product.");
    THPrint(@"  --hid-product TEXT    Restrict HID discovery/recording to devices whose product/manufacturer contains TEXT.");
    THPrint(@"  --list-hid-devices    Print connected HID device metadata and exit.");
    THPrint(@"  --request-permission  Ask macOS for Accessibility permission before recording.");
    THPrint(@"  --record-sample       Insert one sample press event and exit.");
}

static BOOL THAccessibilityTrusted(BOOL prompt) {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @(prompt)};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static int THFail(NSError *error) {
    THPrintError([NSString stringWithFormat:@"thumosd: %@", error.localizedDescription]);
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *configPath = THDefaultConfigPath();
        NSString *databasePath = THDefaultDatabasePath();
        BOOL initOnly = NO;
        BOOL printEvents = NO;
        BOOL discoverKeys = NO;
        BOOL discoverHID = NO;
        BOOL recordHID = NO;
        BOOL listHIDDevices = NO;
        BOOL requestPermission = NO;
        BOOL recordSample = NO;
        NSString *hidProductContains = @"";

        for (int index = 1; index < argc; index++) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if ([argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]) {
                THPrintUsage();
                return 0;
            } else if ([argument isEqualToString:@"--init"]) {
                initOnly = YES;
            } else if ([argument isEqualToString:@"--print-events"]) {
                printEvents = YES;
            } else if ([argument isEqualToString:@"--discover-keys"]) {
                discoverKeys = YES;
            } else if ([argument isEqualToString:@"--discover-hid"]) {
                discoverHID = YES;
                printEvents = YES;
            } else if ([argument isEqualToString:@"--hid-record"]) {
                recordHID = YES;
                printEvents = YES;
            } else if ([argument isEqualToString:@"--hid-product"]) {
                if (index + 1 >= argc) {
                    THPrintError(@"thumosd: --hid-product requires a text filter.");
                    return 64;
                }
                hidProductContains = [NSString stringWithUTF8String:argv[++index]];
            } else if ([argument isEqualToString:@"--list-hid-devices"]) {
                listHIDDevices = YES;
            } else if ([argument isEqualToString:@"--request-permission"]) {
                requestPermission = YES;
            } else if ([argument isEqualToString:@"--record-sample"]) {
                recordSample = YES;
            } else if ([argument isEqualToString:@"--config"]) {
                if (index + 1 >= argc) {
                    THPrintError(@"thumosd: --config requires a path.");
                    return 64;
                }
                configPath = THExpandTilde([NSString stringWithUTF8String:argv[++index]]);
            } else if ([argument isEqualToString:@"--database"]) {
                if (index + 1 >= argc) {
                    THPrintError(@"thumosd: --database requires a path.");
                    return 64;
                }
                databasePath = THExpandTilde([NSString stringWithUTF8String:argv[++index]]);
            } else {
                THPrintError([NSString stringWithFormat:@"thumosd: unknown option %@", argument]);
                THPrintUsage();
                return 64;
            }
        }

        if (listHIDDevices) {
            return THListHIDDevices();
        }

        NSError *error = nil;
        BOOL wroteConfig = [THConfig writeDefaultConfigAtPath:configPath overwrite:NO error:&error];
        if (!wroteConfig) {
            return THFail(error);
        }

        THConfig *config = [THConfig loadFromPath:configPath error:&error];
        if (config == nil) {
            return THFail(error);
        }

        if (config.commands.count == 0) {
            THPrintError(@"thumosd: config contains no valid commands.");
            return 1;
        }

        THEventStore *store = [[THEventStore alloc] initWithPath:databasePath deviceName:config.deviceName];
        if (![store open:&error]) {
            return THFail(error);
        }

        if (initOnly) {
            THPrint([NSString stringWithFormat:@"Config: %@", configPath]);
            THPrint([NSString stringWithFormat:@"Database: %@", databasePath]);
            THPrint([NSString stringWithFormat:@"Commands: %lu", (unsigned long)config.commands.count]);
            return 0;
        }

        if (recordSample) {
            THCommandMapping *mapping = config.commands.firstObject;
            BOOL inserted = [store recordCommand:mapping
                                       eventType:@"sample"
                                         keyCode:mapping.keyCode
                                           flags:mapping.modifiers
                                activeAppBundleID:THActiveAppBundleID()
                                          source:@"sample"
                                           error:&error];
            if (!inserted) {
                return THFail(error);
            }
            THPrint([NSString stringWithFormat:@"Inserted sample event for %@ into %@", mapping.commandID, databasePath]);
            return 0;
        }

        if (discoverHID || recordHID) {
            if (recordHID && hidProductContains.length == 0) {
                THPrintError(@"thumosd: --hid-record requires --hid-product so only the intended device is stored.");
                return 64;
            }

            if (discoverHID && hidProductContains.length == 0) {
                THPrint(@"thumosd HID discovery mode: printing keyboard/button/consumer-control HID events from all devices.");
            } else {
                THPrint([NSString stringWithFormat:@"thumosd HID mode: product/manufacturer filter contains \"%@\".", hidProductContains]);
            }

            THHIDMonitor *monitor = [[THHIDMonitor alloc] initWithStore:store
                                                        productContains:hidProductContains
                                                             printEvents:printEvents
                                                            recordEvents:recordHID];
            if (![monitor start:&error]) {
                return THFail(error);
            }

            CFRunLoopRun();
            (void)monitor;
            return 0;
        }

        if (!THAccessibilityTrusted(requestPermission)) {
            THPrintError(@"thumosd: Accessibility permission is required for global shortcut monitoring.");
            THPrintError(@"Run `build/thumosd --request-permission`, then enable thumosd in System Settings > Privacy & Security > Accessibility.");
            return 2;
        }

        if (discoverKeys) {
            THPrint(@"thumosd discovery mode: press Creator buttons only; observed key events will print but will not be stored unless they also match the config.");
        }

        THRecorder *recorder = [[THRecorder alloc] initWithConfig:config store:store printEvents:printEvents discoverKeys:discoverKeys];
        CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
        gEventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGHeadInsertEventTap,
                                     kCGEventTapOptionListenOnly,
                                     eventMask,
                                     THEventTapCallback,
                                     (__bridge void *)recorder);

        if (gEventTap == NULL) {
            THPrintError(@"thumosd: could not create event tap. Check Accessibility permission.");
            return 2;
        }

        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CGEventTapEnable(gEventTap, true);

        THPrint([NSString stringWithFormat:@"thumosd recording %@ commands to %@", config.deviceName, databasePath]);
        CFRunLoopRun();

        CFRelease(source);
        CFRelease(gEventTap);
        [store close];
    }

    return 0;
}
