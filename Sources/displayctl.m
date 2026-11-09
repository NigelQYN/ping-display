// Native display backend. No BetterDisplay dependency and no software-dimming fallback.
// Private macOS APIs are resolved at runtime: unsupported versions fail explicitly.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <mach-o/dyld.h>

typedef CFTypeRef (*AVCreate)(CFAllocatorRef, io_service_t);
typedef IOReturn (*AVTransfer)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef int (*GetBrightness)(CGDirectDisplayID, float *);
typedef int (*SetBrightness)(CGDirectDisplayID, float);
typedef CGError (*GetDisplayList)(uint32_t, CGDirectDisplayID *, uint32_t *);
typedef CGError (*SetEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef CFDictionaryRef (*DisplayInfo)(CGDirectDisplayID);
static AVCreate avCreate;
static AVTransfer avRead, avWrite;
static GetBrightness appleGet;
static SetBrightness appleSet;
static GetDisplayList allDisplays;
static SetEnabled setEnabled;
static DisplayInfo displayInfo;
static int lockFD = -1;
static NSString *serviceError;

static void fail(NSString *message) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
static void output(id value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:&error];
    if (!data) fail(error.localizedDescription);
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
}
static void loadAPIs(void) {
    dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_GLOBAL);
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_GLOBAL);
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL);
    avCreate = (AVCreate)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    avRead = (AVTransfer)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
    avWrite = (AVTransfer)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    appleGet = (GetBrightness)dlsym(RTLD_DEFAULT, "DisplayServicesGetBrightness");
    appleSet = (SetBrightness)dlsym(RTLD_DEFAULT, "DisplayServicesSetBrightness");
    allDisplays = (GetDisplayList)dlsym(RTLD_DEFAULT, "CGSGetDisplayList");
    setEnabled = (SetEnabled)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    displayInfo = (DisplayInfo)dlsym(RTLD_DEFAULT, "CoreDisplay_DisplayCreateInfoDictionary");
}
static void takeLock(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"displayctl-%u.lock", getuid()]];
    lockFD = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    struct stat st;
    if (lockFD < 0 || fstat(lockFD, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()) fail(@"Cannot acquire safe display-control lock");
    // Keep lock wait plus two bounded VCP exchanges within the bridge's 5s budget.
    for (int i = 0; i < 20; i++) { if (!flock(lockFD, LOCK_EX | LOCK_NB)) return; usleep(50000); }
    fail(@"Another display-control command is busy");
}
static NSString *uuidFor(CGDirectDisplayID d) {
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d);
    if (!u) return @"";
    NSString *s = CFBridgingRelease(CFUUIDCreateString(NULL, u)); CFRelease(u); return s;
}
static NSArray<NSMutableDictionary *> *displays(void) {
    CGDirectDisplayID ids[64] = {0}; uint32_t count = 0;
    CGError err = allDisplays ? allDisplays(64, ids, &count) : CGGetOnlineDisplayList(64, ids, &count);
    if (err || count > 64) fail(@"Could not enumerate displays");
    NSMutableArray *rows = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID d = ids[i]; if (!d) continue;
        if (!CGDisplayVendorNumber(d) && !uuidFor(d).length) continue;
        BOOL builtin = CGDisplayIsBuiltin(d), active = CGDisplayIsActive(d), online = CGDisplayIsOnline(d);
        NSDictionary *info = displayInfo ? CFBridgingRelease(displayInfo(d)) : nil;
        id product = info[@"DisplayProductName"] ?: info[@"ProductName"];
        NSString *name = [product isKindOfClass:NSString.class] ? product : nil;
        if ([product isKindOfClass:NSDictionary.class]) name = product[@"en_US"] ?: [[product allValues] firstObject];
        if (!name) name = builtin ? @"内建显示屏" : [NSString stringWithFormat:@"外接显示器 %u", d];
        NSMutableDictionary *row = [@{@"id":@(d), @"uuid":uuidFor(d), @"name":name, @"builtin":@(builtin), @"active":@(active), @"online":@(online), @"vendor":@(CGDisplayVendorNumber(d)), @"model":@(CGDisplayModelNumber(d)), @"serial":@(CGDisplaySerialNumber(d)), @"brightness":NSNull.null, @"backend":builtin ? @"DisplayServices" : @"DDC/CI"} mutableCopy];
        if (builtin && active && appleGet) { float b = 0; if (!appleGet(d, &b) && isfinite(b)) row[@"brightness"] = @(b); }
        [rows addObject:row];
    }
    return rows;
}
// Match EDID identity, and fail closed if identical displays cannot be distinguished.
static CFTypeRef serviceFor(NSDictionary *display, NSArray *rows) CF_RETURNS_RETAINED;
static CFTypeRef serviceFor(NSDictionary *display, NSArray *rows) {
    serviceError=nil;
    if (!avCreate || !avRead || !avWrite) { serviceError=@"IOAVService APIs unavailable"; return NULL; }
    NSUInteger identities = 0;
    for (NSDictionary *row in rows) if (![row[@"builtin"] boolValue] && [row[@"vendor"] isEqual:display[@"vendor"]] && [row[@"model"] isEqual:display[@"model"]] && [row[@"serial"] isEqual:display[@"serial"]]) identities++;
    if (identities != 1) { serviceError=@"Ambiguous external display identity; refusing to control the wrong screen"; return NULL; }
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)) { serviceError=@"Cannot enumerate DCP services"; return NULL; }
    CFTypeRef selected = NULL; int matches = 0; io_service_t entry;
    while ((entry = IOIteratorNext(it))) {
        CFTypeRef location = IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0);
        BOOL external = location && CFEqual(location, CFSTR("External"));
        if (location) CFRelease(location);
        CFTypeRef av = external ? avCreate(NULL, entry) : NULL; IOObjectRelease(entry);
        if (!av) continue;
        uint8_t edid[128] = {0};
        IOReturn result = avRead(av, 0x50, 0, edid, sizeof(edid));
        const uint8_t header[] = {0,255,255,255,255,255,255,0};
        if (!result && !memcmp(edid,header,8)) {
            unsigned vendor = (edid[8] << 8) | edid[9], model = edid[10] | (edid[11] << 8);
            uint32_t serial = edid[12] | (edid[13]<<8) | (edid[14]<<16) | ((uint32_t)edid[15]<<24);
            if (vendor == [display[@"vendor"] unsignedIntValue] && model == [display[@"model"] unsignedIntValue] && serial == [display[@"serial"] unsignedIntValue]) {
                matches++; if (selected) CFRelease(selected); selected = CFRetain(av);
            }
        }
        CFRelease(av);
    }
    IOObjectRelease(it);
    if (matches != 1) { if (selected) CFRelease(selected); serviceError=@"Cannot uniquely match the selected monitor to a DDC service (EDID mismatch or unavailable)"; return NULL; }
    return selected;
}
static BOOL getVCP(CFTypeRef av, uint8_t code, uint16_t *value, uint16_t *maximum) {
    // Display reconfiguration can temporarily delay DDC responses. Bound retries to
    // about two seconds so a just-disconnected built-in panel does not make the
    // remaining monitor appear uncontrollable. Never synthesize a successful read.
    for (int attempt=0; attempt<12; attempt++) {
        uint8_t request[] = {0x82,0x01,code,(uint8_t)(0x6e ^ 0x51 ^ 0x82 ^ 0x01 ^ code)};
        IOReturn err = avWrite(av,0x37,0x51,request,sizeof(request));
        usleep(attempt<2 ? 60000 : 100000);
        uint8_t reply[11] = {0};
        if (!err) err = avRead(av,0x37,0,reply,sizeof(reply));
        if (!err && reply[0] == 0x6e && (reply[1] & 0x7f) == 8 && reply[2] == 2 && reply[3] == 0 && reply[4] == code) {
            uint8_t checksum = 0x50; for (int i=0;i<11;i++) checksum ^= reply[i];
            if (!checksum) { *maximum = (reply[6]<<8)|reply[7]; *value=(reply[8]<<8)|reply[9]; return *maximum>0; }
        }
        if (getenv("DISPLAYCTL_DEBUG")) {
            fprintf(stderr,"DDC read attempt=%d status=0x%x reply=",attempt+1,err);
            for (int i=0;i<11;i++) fprintf(stderr,"%02x",reply[i]);
            fputc('\n',stderr);
        }
        usleep(50000);
    }
    return NO;
}
static BOOL setVCP(CFTypeRef av, uint8_t code, uint16_t value) {
    uint8_t p[] = {0x84,0x03,code,(uint8_t)(value>>8),(uint8_t)value,0};
    p[5] = 0x6e ^ 0x51; for (int i=0;i<5;i++) p[5] ^= p[i];
    for (int i=0;i<3;i++) { if (!avWrite(av,0x37,0x51,p,sizeof(p))) { usleep(50000); return YES; } usleep(50000); }
    return NO;
}
static void fillBrightness(NSMutableDictionary *row, NSArray *rows) {
    if ([row[@"builtin"] boolValue] || ![row[@"active"] boolValue]) return;
    CFTypeRef av = serviceFor(row,rows); uint16_t current=0, maximum=0;
    if (!av) { row[@"error"]=serviceError ?: @"DDC service unavailable"; return; }
    if (getVCP(av,0x10,&current,&maximum)) { row[@"brightness"]=@((double)current/maximum); row[@"ddcMaximum"]=@(maximum); }
    else row[@"error"]=@"Cannot read DDC brightness";
    CFRelease(av);
}
static void setBrightness(NSMutableDictionary *row, NSArray *rows, double brightness, uint16_t previewMaximum) {
    if (!isfinite(brightness) || brightness<0 || brightness>1) fail(@"Brightness must be in 0..1");
    if (![row[@"active"] boolValue]) fail(@"Selected display is inactive");
    if ([row[@"builtin"] boolValue]) {
        if (!appleSet || appleSet([row[@"id"] unsignedIntValue],brightness)) fail(@"Apple brightness write failed");
        usleep(80000); float actual=0;
        if (!appleGet || appleGet([row[@"id"] unsignedIntValue],&actual) || fabs(actual-brightness)>0.02) fail(@"Apple brightness readback did not confirm the requested value");
    } else {
        CFTypeRef av=serviceFor(row,rows); uint16_t current=0, maximum=previewMaximum;
        if (!av) fail(serviceError ?: @"DDC service unavailable");
        if (!previewMaximum && !getVCP(av,0x10,&current,&maximum)) {
            CFRelease(av); fail(@"Cannot read DDC brightness range; no write performed");
        }
        uint16_t wanted=(uint16_t)lround(brightness*maximum);
        if (previewMaximum || current!=wanted) {
            if (!setVCP(av,0x10,wanted)) { CFRelease(av); fail(@"DDC brightness write failed"); }
            uint16_t actual=0, readMax=0;
            if (!previewMaximum && (!getVCP(av,0x10,&actual,&readMax) || readMax!=maximum
                || abs((int)actual-(int)wanted)>1)) {
                CFRelease(av); fail(@"DDC brightness readback did not confirm the requested value");
            }
        }
        CFRelease(av);
    }
    output(@{@"ok":@YES,@"uuid":row[@"uuid"],@"brightness":@(brightness)});
}
static NSMutableDictionary *selectDisplay(NSArray *rows, NSString *selector, NSString *value) {
    NSMutableArray *matched=[NSMutableArray array];
    for (NSMutableDictionary *row in rows) {
        BOOL match=value ? ([[row[selector] description] caseInsensitiveCompare:value]==NSOrderedSame) : (![row[@"builtin"] boolValue] && [row[@"active"] boolValue]);
        if (match) [matched addObject:row];
    }
    if (matched.count!=1) fail([NSString stringWithFormat:@"Expected exactly one selected display, found %lu",(unsigned long)matched.count]);
    return matched.firstObject;
}
static NSString *argument(NSArray<NSString *> *args, NSString *key) {
    NSUInteger i=[args indexOfObject:key]; if(i!=NSNotFound && i+1<args.count) return args[i+1]; return nil;
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    NSMutableArray<NSString *> *args=[NSMutableArray array]; for(int i=1;i<argc;i++) [args addObject:@(argv[i])];
    if (!args.count || [args[0] isEqual:@"--help"] || [args[0] isEqual:@"help"]) {
        puts("displayctl list [--quick]\ndisplayctl brightness --uuid UUID --value 0..1\ndisplayctl builtin on|off\ndisplayctl cli set -brightness=N% [-UUID=UUID|-displayID=ID|-name=NAME]\nDefault CLI target: exactly one active external display. Apple Silicon only. Private macOS APIs may change."); return 0;
    }
    if (args.count>=2 && [args[0] isEqual:@"cli"] && [args[1] isEqual:@"set"]) {
        // Ask the running menu-bar app to apply combined hardware/software brightness.
        char executable[4096]; uint32_t length=sizeof(executable);
        if (_NSGetExecutablePath(executable,&length)) fail(@"Cannot locate Ping");
        NSString *folder=[@(executable) stringByDeletingLastPathComponent];
        NSString *app=[folder stringByAppendingPathComponent:@"Ping"];
        char **forward=calloc((size_t)argc+2,sizeof(char *));
        if (!forward) fail(@"Cannot allocate bridge arguments");
        forward[0]=(char *)app.fileSystemRepresentation;
        forward[1]="--command";
        for (int i=1;i<argc;i++) forward[i+1]=(char *)argv[i];
        execv(forward[0],forward);
        free(forward); fail(@"Cannot start Ping command");
    }
    loadAPIs(); takeLock(); NSArray *rows=displays();
    if ([args[0] isEqual:@"list"]) {
        if (![args containsObject:@"--quick"]) for(NSMutableDictionary *row in rows) fillBrightness(row,rows);
        output(rows); return 0;
    }
    if ([args[0] isEqual:@"builtin"] && args.count==2 && ([args[1] isEqual:@"on"] || [args[1] isEqual:@"off"])) {
        BOOL enabled=[args[1] isEqual:@"on"]; NSMutableArray *builtins=[NSMutableArray array]; BOOL hasExternal=NO;
        for (NSMutableDictionary *row in rows) {
            if ([row[@"builtin"] boolValue]) [builtins addObject:row];
            else if (!enabled && [row[@"active"] boolValue] && [row[@"online"] boolValue]) {
                // Require a matched physical DCP display, rather than trusting virtual display vendor IDs.
                CFTypeRef av=serviceFor(row,rows); if (av) { hasExternal=YES; CFRelease(av); }
            }
        }
        if(builtins.count!=1) fail(@"Cannot identify exactly one built-in display");
        CGDirectDisplayID builtinID=[builtins[0][@"id"] unsignedIntValue];
        if ([builtins[0][@"active"] boolValue]==enabled) { output(@{@"ok":@YES,@"enabled":@(enabled),@"changed":@NO}); return 0; }
        if(!enabled && !hasExternal) fail(@"Refusing to turn off the only active physical display");
        if(!setEnabled) fail(@"CGSConfigureDisplayEnabled unavailable");
        CGDisplayConfigRef config=NULL; CGError err=CGBeginDisplayConfiguration(&config);
        if(err) fail(@"Cannot begin display configuration");
        err=setEnabled(config,builtinID,enabled);
        if(err) { CGCancelDisplayConfiguration(config); fail([NSString stringWithFormat:@"Display configuration rejected (%d)",err]); }
        // Per-session configuration is intentionally used; reboot restores normal display access.
        err=CGCompleteDisplayConfiguration(config,kCGConfigureForSession);
        if(err) fail([NSString stringWithFormat:@"Display configuration commit failed (%d)",err]);
        BOOL verified=NO;
        for (int i=0;i<20;i++) { usleep(100000); if ((BOOL)CGDisplayIsActive(builtinID)==enabled) { verified=YES; break; } }
        if (!verified) fail(@"Display API returned success but the requested built-in display state was not observed");
        output(@{@"ok":@YES,@"enabled":@(enabled),@"changed":@YES}); return 0;
    }
    NSString *selector=@"uuid", *value=argument(args,@"--uuid"), *raw=argument(args,@"--value");
    BOOL cli=args.count>=2 && [args[0] isEqual:@"cli"] && [args[1] isEqual:@"set"];
    if(cli) for(NSString *arg in args) {
        if([arg hasPrefix:@"-brightness="]) raw=[arg substringFromIndex:12];
        if([arg hasPrefix:@"-UUID="]) { selector=@"uuid"; value=[arg substringFromIndex:6]; }
        if([arg hasPrefix:@"-displayID="]) { selector=@"id"; value=[arg substringFromIndex:11]; }
        if([arg hasPrefix:@"-name="]) { selector=@"name"; value=[arg substringFromIndex:6]; }
    }
    if(!cli && ![args[0] isEqual:@"brightness"]) fail(@"Unsupported command; use --help");
    if(!raw) fail(@"Missing brightness value");
    BOOL percent=[raw hasSuffix:@"%"]; NSString *numeric=percent ? [raw substringToIndex:raw.length-1] : raw;
    NSScanner *scan=[NSScanner scannerWithString:numeric]; double b=0;
    if(![scan scanDouble:&b] || !scan.isAtEnd) fail(@"Invalid brightness value");
    if(percent) b/=100.0;
    int previewMaximum=0;
    if ([args containsObject:@"--preview-max"]) {
        NSString *rawMaximum=argument(args,@"--preview-max");
        NSScanner *maximumScan=rawMaximum ? [NSScanner scannerWithString:rawMaximum] : nil;
        if (![maximumScan scanInt:&previewMaximum] || !maximumScan.isAtEnd
            || previewMaximum<1 || previewMaximum>UINT16_MAX) fail(@"Invalid DDC preview maximum");
    }
    setBrightness(selectDisplay(rows,selector,value),rows,b,(uint16_t)previewMaximum); return 0;
} }
