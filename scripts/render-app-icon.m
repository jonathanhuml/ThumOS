#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

static void DrawCrownIcon(CGFloat size) {
    [[NSColor whiteColor] setFill];
    NSRectFill(NSMakeRect(0.0, 0.0, size, size));

    NSColor *black = [NSColor blackColor];
    [black setFill];
    [black setStroke];

    NSBezierPath *crown = [NSBezierPath bezierPath];
    [crown moveToPoint:NSMakePoint(size * 0.14, size * 0.23)];
    [crown lineToPoint:NSMakePoint(size * 0.14, size * 0.78)];
    [crown lineToPoint:NSMakePoint(size * 0.36, size * 0.48)];
    [crown lineToPoint:NSMakePoint(size * 0.50, size * 0.83)];
    [crown lineToPoint:NSMakePoint(size * 0.64, size * 0.48)];
    [crown lineToPoint:NSMakePoint(size * 0.86, size * 0.78)];
    [crown lineToPoint:NSMakePoint(size * 0.86, size * 0.23)];
    [crown closePath];
    [crown fill];

    NSBezierPath *base = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(size * 0.12,
                                                                             size * 0.13,
                                                                             size * 0.76,
                                                                             size * 0.14)
                                                         xRadius:size * 0.035
                                                         yRadius:size * 0.035];
    [base fill];
}

static NSData *PNGDataForPixels(NSInteger pixels, NSError **error) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:pixels
                                                                    pixelsHigh:pixels
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:pixels * 4
                                                                  bitsPerPixel:0];
    if (rep == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileWriteUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not allocate icon bitmap."}];
        }
        return nil;
    }
    rep.size = NSMakeSize((CGFloat)pixels, (CGFloat)pixels);

    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    context.imageInterpolation = NSImageInterpolationHigh;
    [NSGraphicsContext setCurrentContext:context];
    DrawCrownIcon((CGFloat)pixels);
    [NSGraphicsContext restoreGraphicsState];

    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static BOOL WritePNG(NSString *path, NSInteger pixels, NSError **error) {
    NSData *data = PNGDataForPixels(pixels, error);
    return data != nil && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static void AppendBigEndianUInt32(NSMutableData *data, uint32_t value) {
    uint32_t bigEndianValue = CFSwapInt32HostToBig(value);
    [data appendBytes:&bigEndianValue length:sizeof(bigEndianValue)];
}

static BOOL AppendICNSEntry(NSMutableData *entries, NSString *type, NSInteger pixels, NSError **error) {
    NSData *pngData = PNGDataForPixels(pixels, error);
    if (pngData == nil) {
        return NO;
    }

    NSData *typeData = [type dataUsingEncoding:NSASCIIStringEncoding];
    if (typeData.length != 4 || pngData.length > UINT32_MAX - 8) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileWriteUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not build ICNS entry."}];
        }
        return NO;
    }

    [entries appendData:typeData];
    AppendBigEndianUInt32(entries, (uint32_t)(pngData.length + 8));
    [entries appendData:pngData];
    return YES;
}

static BOOL WriteICNS(NSString *path, NSError **error) {
    NSArray<NSDictionary *> *entriesToWrite = @[
        @{@"type": @"icp4", @"pixels": @16},
        @{@"type": @"icp5", @"pixels": @32},
        @{@"type": @"icp6", @"pixels": @64},
        @{@"type": @"ic07", @"pixels": @128},
        @{@"type": @"ic08", @"pixels": @256},
        @{@"type": @"ic09", @"pixels": @512},
        @{@"type": @"ic10", @"pixels": @1024}
    ];

    NSMutableData *entries = [NSMutableData data];
    for (NSDictionary *entry in entriesToWrite) {
        if (!AppendICNSEntry(entries, entry[@"type"], [entry[@"pixels"] integerValue], error)) {
            return NO;
        }
    }

    if (entries.length > UINT32_MAX - 8) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileWriteUnknownError
                                     userInfo:@{NSLocalizedDescriptionKey: @"ICNS file is too large."}];
        }
        return NO;
    }

    NSMutableData *icns = [NSMutableData data];
    [icns appendBytes:"icns" length:4];
    AppendBigEndianUInt32(icns, (uint32_t)(entries.length + 8));
    [icns appendData:entries];
    return [icns writeToFile:path options:NSDataWritingAtomic error:error];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) {
            fprintf(stderr, "usage: render-app-icon <iconset-directory> [icns-path]\n");
            return 64;
        }

        NSString *outputDirectory = [NSString stringWithUTF8String:argv[1]];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:outputDirectory
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        NSArray<NSDictionary *> *icons = @[
            @{@"name": @"icon_16x16.png", @"pixels": @16},
            @{@"name": @"icon_16x16@2x.png", @"pixels": @32},
            @{@"name": @"icon_32x32.png", @"pixels": @32},
            @{@"name": @"icon_32x32@2x.png", @"pixels": @64},
            @{@"name": @"icon_128x128.png", @"pixels": @128},
            @{@"name": @"icon_128x128@2x.png", @"pixels": @256},
            @{@"name": @"icon_256x256.png", @"pixels": @256},
            @{@"name": @"icon_256x256@2x.png", @"pixels": @512},
            @{@"name": @"icon_512x512.png", @"pixels": @512},
            @{@"name": @"icon_512x512@2x.png", @"pixels": @1024}
        ];

        for (NSDictionary *icon in icons) {
            NSString *path = [outputDirectory stringByAppendingPathComponent:icon[@"name"]];
            if (!WritePNG(path, [icon[@"pixels"] integerValue], &error)) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return 1;
            }
        }

        if (argc == 3) {
            NSString *icnsPath = [NSString stringWithUTF8String:argv[2]];
            if (!WriteICNS(icnsPath, &error)) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return 1;
            }
        }
    }
    return 0;
}
