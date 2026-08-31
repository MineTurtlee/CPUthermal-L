#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>
#import <string.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
typedef char io_name_t[128];
extern kern_return_t IORegistryEntryGetName(io_registry_entry_t entry, io_name_t name);

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.riboly.cputhermal-l.plist";
static NSString *const kStatusPath = @"/var/mobile/Library/Preferences/com.riboly.cputhermal-l.status.plist";

typedef struct {
    BOOL enabled;
    BOOL fullPower;
    BOOL preventDimming;
    BOOL suppressWarnings;
    BOOL emergencyFallback;
    NSInteger targetPercent;
    double emergencyTemperature;
} CTLConfig;

static CTLConfig gConfig;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static BOOL gEmergency = NO;
static double gTemperature = 0;
static NSInteger gHookCount = 0;
static __weak id gCommonProduct;
static __weak id gMitigationController;
static NSMutableDictionary<NSString *, NSNumber *> *gObservedMax;
static NSMutableDictionary<NSString *, NSNumber *> *gObservedDisplayMax;
static int gThermalNotifyTokens[64];
static int gThermalNotifyTokenCount = 0;
static dispatch_source_t gTimer;
static NSInteger gStatusTick = 0;

static BOOL IsThermalProcess(void) { return [[[NSProcessInfo processInfo] processName] isEqualToString:@"thermalmonitord"]; }
static BOOL IsSpringBoard(void) { return [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]; }

static NSDictionary *ReadDictionary(NSString *path) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

static void LoadConfig(void) {
    NSDictionary *p = ReadDictionary(kPrefsPath);
    if (!p.count) {
        p = ReadDictionary(@"/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist");
        if (!p.count) p = ReadDictionary(@"/var/mobile/Library/Preferences/com.be-huge.insulation-prefs.plist");
    }
    CTLConfig c;
    c.enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
    NSString *mode = [p[@"powerMode"] isKindOfClass:NSString.class] ? p[@"powerMode"] : @"fullPower";
    c.fullPower = ![mode isEqualToString:@"lowPower"];
    c.preventDimming = p[@"preventThermalDimming"] ? [p[@"preventThermalDimming"] boolValue] : (p[@"thermalPreventDimmingEnabled"] ? [p[@"thermalPreventDimmingEnabled"] boolValue] : YES);
    c.suppressWarnings = [p[@"suppressThermalWarnings"] boolValue] || [p[@"thermalBlockNotifPopup"] boolValue];
    c.emergencyFallback = p[@"emergencyFallbackEnabled"] ? [p[@"emergencyFallbackEnabled"] boolValue] : NO;
    c.targetPercent = p[@"fullPowerTargetPercent"] ? [p[@"fullPowerTargetPercent"] integerValue] : 100;
    if (c.targetPercent < 50 || c.targetPercent > 100) c.targetPercent = 100;
    c.emergencyTemperature = p[@"emergencyTemperatureC"] ? [p[@"emergencyTemperatureC"] doubleValue] : 78.0;
    if (c.emergencyTemperature < 65 || c.emergencyTemperature > 95) c.emergencyTemperature = 78.0;
    os_unfair_lock_lock(&gLock); gConfig = c; os_unfair_lock_unlock(&gLock);
}

static CTLConfig Config(void) { os_unfair_lock_lock(&gLock); CTLConfig c = gConfig; os_unfair_lock_unlock(&gLock); return c; }
static BOOL CanOverride(void) { CTLConfig c = Config(); return c.enabled && c.fullPower && !(c.emergencyFallback && gEmergency); }

static void WriteStatus(void) {
    CTLConfig c = Config();
    NSMutableDictionary *status = [[NSDictionary dictionaryWithContentsOfFile:kStatusPath] mutableCopy] ?: [NSMutableDictionary dictionary];
    status[@"mode"] = !c.enabled ? @"disabled" : (c.fullPower ? @"fullPower" : @"lowPower");
    status[@"targetPercent"] = @(c.targetPercent); status[@"updatedAt"] = [[NSDate date] description];
    if (IsThermalProcess()) {
        status[@"process"] = @"thermalmonitord"; status[@"thermalHookCount"] = @(gHookCount);
        status[@"temperatureC"] = @(gTemperature); status[@"emergency"] = @(gEmergency);
    } else if (IsSpringBoard()) status[@"springBoardHookCount"] = @(gHookCount);
    status[@"hookCount"] = @([status[@"thermalHookCount"] integerValue] + [status[@"springBoardHookCount"] integerValue]);
    [status writeToFile:kStatusPath atomically:YES];
}

static NSNumber *ClampedNumber(NSNumber *value, NSString *key) {
    if (![value isKindOfClass:NSNumber.class]) return value;
    @synchronized (gObservedMax) {
        double incoming = value.doubleValue;
        double baseline = [gObservedMax[key] doubleValue];
        if (incoming > baseline) { baseline = incoming; gObservedMax[key] = @(incoming); }
        if (!CanOverride() || baseline <= 0) return value;
        double desired = baseline * Config().targetPercent / 100.0;
        return @(MAX(incoming, desired));
    }
}

static NSNumber *ClampedDisplayNumber(NSNumber *value, NSString *key) {
    if (![value isKindOfClass:NSNumber.class]) return value;
    @synchronized (gObservedDisplayMax) {
        double incoming = value.doubleValue;
        double baseline = [gObservedDisplayMax[key] doubleValue];
        if (incoming > baseline) { baseline = incoming; gObservedDisplayMax[key] = @(incoming); }
        if (!CanOverride() || !Config().preventDimming || baseline <= 0) return value;
        return @(MAX(incoming, baseline));
    }
}

static BOOL KeyContains(NSString *key, NSArray<NSString *> *needles) {
    NSString *lower = key.lowercaseString;
    for (NSString *n in needles) if ([lower containsString:n]) return YES;
    return NO;
}

static id PatchObject(id object, NSString *contextKey) {
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *m = [object mutableCopy];
        for (id keyObj in [m.allKeys copy]) {
            NSString *key = [keyObj description]; id value = m[keyObj];
            if (CanOverride() && KeyContains(key, @[@"thermalthrottleenabled", @"expectscpmssupport"])) m[keyObj] = @NO;
            else if (CanOverride() && Config().preventDimming && KeyContains(key, @[@"backlightcomponentcontrol", @"backlightbrightness", @"backlightpower", @"displaybrightness", @"displaypower"])) {
                if ([value isKindOfClass:NSNumber.class]) m[keyObj] = ClampedDisplayNumber(value, key);
                else m[keyObj] = PatchObject(value, key);
            }
            else if (CanOverride() && KeyContains(key, @[@"cpumaxpower", @"cpupowerceiling", @"cpupowerfloor", @"cpupowerzone", @"thermalpowercap", @"maxthermalpower", @"minthermalpower"]) && [value isKindOfClass:NSNumber.class]) m[keyObj] = ClampedNumber(value, key);
            else m[keyObj] = PatchObject(value, key);
        }
        return m;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *a = [object mutableCopy];
        if (CanOverride() && Config().preventDimming && KeyContains(contextKey ?: @"", @[@"backlightcomponentcontrol", @"backlightbrightness", @"backlightpower", @"displaybrightness", @"displaypower"]) && a.count) {
            id nominal = a.firstObject; for (NSUInteger i = 1; i < a.count; i++) a[i] = nominal;
        } else for (NSUInteger i = 0; i < a.count; i++) a[i] = PatchObject(a[i], contextKey);
        return a;
    }
    if ([object isKindOfClass:NSNumber.class] && CanOverride() && Config().preventDimming && KeyContains(contextKey ?: @"", @[@"backlightcomponentcontrol", @"backlightbrightness", @"backlightpower", @"displaybrightness", @"displaypower"])) return ClampedDisplayNumber(object, contextKey);
    return object;
}

static BOOL HookInstance(const char *className, const char *selectorName, IMP replacement, IMP *original) {
    Class c = objc_getClass(className); SEL s = sel_registerName(selectorName);
    if (!c || !class_getInstanceMethod(c, s)) return NO;
    MSHookMessageEx(c, s, replacement, original); gHookCount++; return YES;
}

static BOOL HookClass(const char *className, const char *selectorName, IMP replacement, IMP *original) {
    Class c = objc_getClass(className); SEL s = sel_registerName(selectorName);
    if (!c || !class_getClassMethod(c, s)) return NO;
    MSHookMessageEx(object_getClass(c), s, replacement, original); gHookCount++; return YES;
}

// Foundation thermal configuration interception.
static id (*origDictionaryWithFile)(id, SEL, NSString *);
static id hookDictionaryWithFile(id self, SEL _cmd, NSString *path) {
    id result = origDictionaryWithFile(self, _cmd, path);
    if (IsThermalProcess() && [path containsString:@"ThermalMonitor"] && [result isKindOfClass:NSDictionary.class]) return PatchObject(result, path);
    return result;
}

// CommonProduct hooks.
static id (*origInitProduct)(id, SEL, id);
static id hookInitProduct(id self, SEL _cmd, id arg) {
    id result = origInitProduct(self, _cmd, arg); gCommonProduct = result ?: self; return result;
}
static void (*origTryTakeAction)(id, SEL);
static void hookTryTakeAction(id self, SEL _cmd) { if (!CanOverride()) origTryTakeAction(self, _cmd); }
static void (*origSimulateLight)(id, SEL);
static void hookSimulateLight(id self, SEL _cmd) { if (!CanOverride()) origSimulateLight(self, _cmd); }
static void (*origPuppet)(id, SEL, id);
static void hookPuppet(id self, SEL _cmd, id value) {
    CTLConfig c = Config();
    if (!c.enabled) origPuppet(self, _cmd, value);
    else origPuppet(self, _cmd, c.fullPower && !gEmergency ? @"nominal" : (c.fullPower ? value : @"light"));
}
static long long (*origPressure)(id, SEL);
static long long hookPressure(id self, SEL _cmd) { return CanOverride() ? 0 : origPressure(self, _cmd); }
static BOOL (*origForcedPressure)(id, SEL);
static BOOL hookForcedPressure(id self, SEL _cmd) { return CanOverride() ? NO : origForcedPressure(self, _cmd); }
static id (*origForcedLevel)(id, SEL, id);
static id hookForcedLevel(id self, SEL _cmd, id arg) { return CanOverride() ? @"nominal" : origForcedLevel(self, _cmd, arg); }
static void (*origSetThermalState)(id, SEL, int);
static void hookSetThermalState(id self, SEL _cmd, int state) { origSetThermalState(self, _cmd, CanOverride() ? 0 : state); }

// MitigationController hooks. Numeric targets are clamped against the highest nominal value observed since launch.
static id (*origMitigationInit)(id, SEL, BOOL, BOOL, id, id);
static id hookMitigationInit(id self, SEL _cmd, BOOL fast, BOOL noDisplay, id save, id zone) {
    id result = origMitigationInit(self, _cmd, fast, noDisplay, save, zone); gMitigationController = result ?: self; return result;
}
static void (*origPowerSave)(id, SEL, BOOL);
static void hookPowerSave(id self, SEL _cmd, BOOL active) { CTLConfig c = Config(); origPowerSave(self, _cmd, c.enabled ? (c.fullPower ? (gEmergency ? active : NO) : YES) : active); }
static void (*origMitigationsEnabled)(id, SEL, BOOL);
static void hookMitigationsEnabled(id self, SEL _cmd, BOOL enabled) { origMitigationsEnabled(self, _cmd, CanOverride() ? NO : enabled); }
static void (*origCPULevel)(id, SEL, int);
static void hookCPULevel(id self, SEL _cmd, int level) {
    CTLConfig c = Config(); int target = c.targetPercent >= 100 ? 0 : (c.targetPercent >= 90 ? 1 : 2);
    origCPULevel(self, _cmd, c.enabled ? (c.fullPower && !gEmergency ? MIN(level, target) : (c.fullPower ? level : MAX(level, 2))) : level);
}
static void (*origOneIntTarget)(id, SEL, int);
static void hookOneIntTarget(id self, SEL _cmd, int value) { origOneIntTarget(self, _cmd, [ClampedNumber(@(value), NSStringFromSelector(_cmd)) intValue]); }
static void (*origTwoIntTargetA)(id, SEL, int, int);
static void hookTwoIntTargetA(id self, SEL _cmd, int value, int source) { origTwoIntTargetA(self, _cmd, [ClampedNumber(@(value), NSStringFromSelector(_cmd)) intValue], source); }
static void (*origTwoIntTargetB)(id, SEL, int, int);
static void hookTwoIntTargetB(id self, SEL _cmd, int value, int source) { origTwoIntTargetB(self, _cmd, [ClampedNumber(@(value), NSStringFromSelector(_cmd)) intValue], source); }
static void (*origMaxTarget)(id, SEL, int, BOOL, id);
static void hookMaxTarget(id self, SEL _cmd, int value, BOOL legacy, id property) { origMaxTarget(self, _cmd, [ClampedNumber(@(value), NSStringFromSelector(_cmd)) intValue], legacy, property); }

// IOKit write interception catches iOS 18 paths that bypass Objective-C controller methods.
static kern_return_t (*origIOSetProperty)(io_registry_entry_t, CFStringRef, CFTypeRef);
static kern_return_t hookIOSetProperty(io_registry_entry_t entry, CFStringRef keyRef, CFTypeRef valueRef) {
    @autoreleasepool {
        NSString *key = (__bridge NSString *)keyRef; id value = (__bridge id)valueRef; io_name_t raw = {0}; IORegistryEntryGetName(entry, raw);
        NSString *service = [NSString stringWithUTF8String:raw] ?: @""; id patched = value;
        if (CanOverride() && [service.lowercaseString containsString:@"cpu"] && [value isKindOfClass:NSNumber.class]) patched = ClampedNumber(value, key);
        if (CanOverride() && KeyContains(key, @[@"thermalthrottleenabled"])) patched = @NO;
        NSString *displayContext = [NSString stringWithFormat:@"%@.%@", service, key ?: @""];
        if (CanOverride() && Config().preventDimming && KeyContains(displayContext, @[@"backlight", @"brightness", @"displaypower"])) {
            patched = [value isKindOfClass:NSNumber.class] ? ClampedDisplayNumber(value, displayContext) : PatchObject(value, displayContext);
        }
        return origIOSetProperty(entry, keyRef, (__bridge CFTypeRef)patched);
    }
}
static kern_return_t (*origIOSetProperties)(io_registry_entry_t, CFTypeRef);
static kern_return_t hookIOSetProperties(io_registry_entry_t entry, CFTypeRef properties) {
    @autoreleasepool { id p = PatchObject((__bridge id)properties, @"IORegistry"); return origIOSetProperties(entry, (__bridge CFTypeRef)p); }
}

static kern_return_t (*origIOServiceSetProperty)(io_registry_entry_t, CFStringRef, CFTypeRef);
static kern_return_t hookIOServiceSetProperty(io_registry_entry_t entry, CFStringRef keyRef, CFTypeRef valueRef) {
    @autoreleasepool {
        NSString *key = (__bridge NSString *)keyRef; id value = (__bridge id)valueRef; io_name_t raw = {0}; IORegistryEntryGetName(entry, raw);
        NSString *service = [NSString stringWithUTF8String:raw] ?: @"";
        NSString *context = [NSString stringWithFormat:@"%@.%@", service, key ?: @""];
        id patched = value;
        if (CanOverride() && KeyContains(context, @[@"cpu", @"ppm", @"processor"]) && [value isKindOfClass:NSNumber.class] && KeyContains(key, @[@"power", @"ceiling", @"target", @"limit", @"freq"])) patched = ClampedNumber(value, context);
        if (CanOverride() && Config().preventDimming && KeyContains(context, @[@"backlight", @"brightness", @"displaypower"])) patched = [value isKindOfClass:NSNumber.class] ? ClampedDisplayNumber(value, context) : PatchObject(value, context);
        return origIOServiceSetProperty(entry, keyRef, (__bridge CFTypeRef)patched);
    }
}

// Thermal notification state is normalized at the source while full-power override is active.
static uint32_t (*origNotifyRegisterCheck)(const char *, int *);
static uint32_t hookNotifyRegisterCheck(const char *name, int *token) {
    uint32_t r = origNotifyRegisterCheck(name, token);
    if (r == NOTIFY_STATUS_OK && name && strstr(name, "thermal") && gThermalNotifyTokenCount < 64) gThermalNotifyTokens[gThermalNotifyTokenCount++] = *token;
    return r;
}
static uint32_t (*origNotifySetState)(int, uint64_t);
static uint32_t hookNotifySetState(int token, uint64_t state) {
    if (CanOverride()) for (int i = 0; i < gThermalNotifyTokenCount; i++) if (gThermalNotifyTokens[i] == token) { state = 0; break; }
    return origNotifySetState(token, state);
}

// SpringBoard iOS 18 thermal UI hooks: block thermal dimming without freezing normal user brightness changes.
static BOOL BlockDimming(void) { CTLConfig c = Config(); return c.enabled && c.fullPower && c.preventDimming && !gEmergency; }
static BOOL (*origThermalBlocked)(id, SEL);
static BOOL hookThermalBlocked(id self, SEL _cmd) { return BlockDimming() ? NO : origThermalBlocked(self, _cmd); }
static BOOL (*origInternalBlocked)(id, SEL);
static BOOL hookInternalBlocked(id self, SEL _cmd) { return BlockDimming() ? NO : origInternalBlocked(self, _cmd); }
static BOOL (*origAlwaysOnBlocked)(id, SEL);
static BOOL hookAlwaysOnBlocked(id self, SEL _cmd) { return BlockDimming() ? NO : origAlwaysOnBlocked(self, _cmd); }
static long long (*origThermalLevel)(id, SEL);
static long long hookThermalLevel(id self, SEL _cmd) { return (Config().enabled && Config().fullPower && (Config().preventDimming || Config().suppressWarnings) && !gEmergency) ? 0 : origThermalLevel(self, _cmd); }
static void (*origSetBlocked)(id, SEL, BOOL);
static void hookSetBlocked(id self, SEL _cmd, BOOL blocked) { origSetBlocked(self, _cmd, BlockDimming() ? NO : blocked); }
static void (*origSetAlwaysOnBlocked)(id, SEL, BOOL);
static void hookSetAlwaysOnBlocked(id self, SEL _cmd, BOOL blocked) { origSetAlwaysOnBlocked(self, _cmd, BlockDimming() ? NO : blocked); }
static void (*origRespondThermal)(id, SEL);
static void hookRespondThermal(id self, SEL _cmd) { if (!(Config().enabled && Config().fullPower && Config().preventDimming && !gEmergency)) origRespondThermal(self, _cmd); }
static long long (*origStatusProvider)(id, SEL);
static long long hookStatusProvider(id self, SEL _cmd) { return (Config().enabled && Config().suppressWarnings && !gEmergency) ? 0 : origStatusProvider(self, _cmd); }
static void (*origUpdateAlwaysOnThermalState)(id, SEL);
static void hookUpdateAlwaysOnThermalState(id self, SEL _cmd) { if (!BlockDimming()) origUpdateAlwaysOnThermalState(self, _cmd); }

static double NormalizeTemperature(long long raw) {
    double v = llabs(raw); if (v > 10000) v /= 1000.0; else if (v > 1000) v /= 100.0; else if (v > 200) v /= 10.0; return v;
}

static void SampleTemperature(void) {
    id product = gCommonProduct; if (!product) return;
    NSArray *names = @[@"arcVirtualTemperature", @"arcModuleTemperature", @"gasGaugeBatteryTemperature", @"getFrontDisplayCenterTemperature"];
    double highest = 0;
    for (NSString *name in names) { SEL s = NSSelectorFromString(name); if ([product respondsToSelector:s]) highest = MAX(highest, NormalizeTemperature(((long long(*)(id,SEL))objc_msgSend)(product, s))); }
    if (highest > 0 && highest < 150) gTemperature = highest;
    CTLConfig c = Config(); if (c.emergencyFallback) { if (!gEmergency && gTemperature >= c.emergencyTemperature) gEmergency = YES; else if (gEmergency && gTemperature <= c.emergencyTemperature - 5.0) gEmergency = NO; } else gEmergency = NO;
}

static void ApplyMode(void) {
    CTLConfig c = Config(); id product = gCommonProduct; id controller = gMitigationController;
    if (product && [product respondsToSelector:@selector(putDeviceInThermalSimulationMode:)] && !gEmergency) ((void(*)(id,SEL,id))objc_msgSend)(product, @selector(putDeviceInThermalSimulationMode:), c.enabled ? (c.fullPower ? @"nominal" : @"light") : @"nominal");
    if (controller && [controller respondsToSelector:@selector(setPowerSaveActive:)]) ((void(*)(id,SEL,BOOL))objc_msgSend)(controller, @selector(setPowerSaveActive:), c.enabled && !c.fullPower);
    if (controller && [controller respondsToSelector:@selector(setCPULevel:)]) ((void(*)(id,SEL,int))objc_msgSend)(controller, @selector(setCPULevel:), c.fullPower ? 0 : 2);
    WriteStatus();
}

static void InstallThermalHooks(void) {
    if (!origDictionaryWithFile) HookClass("NSDictionary", "dictionaryWithContentsOfFile:", (IMP)hookDictionaryWithFile, (IMP *)&origDictionaryWithFile);
    if (!origInitProduct) HookInstance("CommonProduct", "initProduct:", (IMP)hookInitProduct, (IMP *)&origInitProduct);
    if (!origTryTakeAction) HookInstance("CommonProduct", "tryTakeAction", (IMP)hookTryTakeAction, (IMP *)&origTryTakeAction);
    if (!origSimulateLight) HookInstance("CommonProduct", "simulateLightThermalPressure", (IMP)hookSimulateLight, (IMP *)&origSimulateLight);
    if (!origPuppet) HookInstance("CommonProduct", "putDeviceInThermalSimulationMode:", (IMP)hookPuppet, (IMP *)&origPuppet);
    if (!origPressure) HookInstance("CommonProduct", "thermalPressureLevel", (IMP)hookPressure, (IMP *)&origPressure);
    if (!origForcedPressure) HookInstance("CommonProduct", "getPotentialForcedThermalPressureLevel", (IMP)hookForcedPressure, (IMP *)&origForcedPressure);
    if (!origForcedLevel) HookInstance("CommonProduct", "getPotentialForcedThermalLevel:", (IMP)hookForcedLevel, (IMP *)&origForcedLevel);
    if (!origSetThermalState) HookInstance("CommonProduct", "setThermalState:", (IMP)hookSetThermalState, (IMP *)&origSetThermalState);
    if (!origMitigationInit) HookInstance("MitigationController", "initForFastLoop:noDisplay:powerSaveParams:powerZoneParams:", (IMP)hookMitigationInit, (IMP *)&origMitigationInit);
    if (!origPowerSave) HookInstance("MitigationController", "setPowerSaveActive:", (IMP)hookPowerSave, (IMP *)&origPowerSave);
    if (!origMitigationsEnabled) HookInstance("MitigationController", "setCPMSMitigationsEnabled:", (IMP)hookMitigationsEnabled, (IMP *)&origMitigationsEnabled);
    if (!origCPULevel) HookInstance("MitigationController", "setCPULevel:", (IMP)hookCPULevel, (IMP *)&origCPULevel);
    if (!origOneIntTarget) HookInstance("MitigationController", "setCPUPowerZoneTarget:", (IMP)hookOneIntTarget, (IMP *)&origOneIntTarget);
    if (!origTwoIntTargetA) HookInstance("MitigationController", "setCPUPowerCeiling:fromDecisionSource:", (IMP)hookTwoIntTargetA, (IMP *)&origTwoIntTargetA);
    if (!origTwoIntTargetB) HookInstance("MitigationController", "setCPUPowerCeiling:forDVD1Contributor:", (IMP)hookTwoIntTargetB, (IMP *)&origTwoIntTargetB);
    if (!origMaxTarget) HookInstance("MitigationController", "setMaxCPUPowerTarget:useLegacyPath:setProperty:", (IMP)hookMaxTarget, (IMP *)&origMaxTarget);
    void *p = NULL;
    if (!origIOSetProperty && (p = dlsym(RTLD_DEFAULT, "IORegistryEntrySetCFProperty"))) { MSHookFunction(p, (void *)hookIOSetProperty, (void **)&origIOSetProperty); gHookCount++; }
    if (!origIOSetProperties && (p = dlsym(RTLD_DEFAULT, "IORegistryEntrySetCFProperties"))) { MSHookFunction(p, (void *)hookIOSetProperties, (void **)&origIOSetProperties); gHookCount++; }
    if (!origIOServiceSetProperty && (p = dlsym(RTLD_DEFAULT, "IOServiceSetProperty"))) { MSHookFunction(p, (void *)hookIOServiceSetProperty, (void **)&origIOServiceSetProperty); gHookCount++; }
    if (!origNotifyRegisterCheck && (p = dlsym(RTLD_DEFAULT, "notify_register_check"))) { MSHookFunction(p, (void *)hookNotifyRegisterCheck, (void **)&origNotifyRegisterCheck); gHookCount++; }
    if (!origNotifySetState && (p = dlsym(RTLD_DEFAULT, "notify_set_state"))) { MSHookFunction(p, (void *)hookNotifySetState, (void **)&origNotifySetState); gHookCount++; }
}

static void InstallSpringBoardHooks(void) {
    if (!origThermalBlocked) HookInstance("SBThermalController", "isThermalBlocked", (IMP)hookThermalBlocked, (IMP *)&origThermalBlocked);
    if (!origInternalBlocked) HookInstance("SBThermalController", "_isBlocked", (IMP)hookInternalBlocked, (IMP *)&origInternalBlocked);
    if (!origThermalLevel) HookInstance("SBThermalController", "level", (IMP)hookThermalLevel, (IMP *)&origThermalLevel);
    if (!origSetBlocked) HookInstance("SBThermalController", "_setBlocked:", (IMP)hookSetBlocked, (IMP *)&origSetBlocked);
    if (!origRespondThermal) HookInstance("SBThermalController", "_respondToCurrentThermalCondition", (IMP)hookRespondThermal, (IMP *)&origRespondThermal);
    if (!origAlwaysOnBlocked) HookInstance("SBThermalAlwaysOnPolicy", "_isThermallyBlocked", (IMP)hookAlwaysOnBlocked, (IMP *)&origAlwaysOnBlocked);
    if (!origSetAlwaysOnBlocked) HookInstance("SBThermalAlwaysOnPolicy", "_setThermallyBlocked:", (IMP)hookSetAlwaysOnBlocked, (IMP *)&origSetAlwaysOnBlocked);
    if (!origUpdateAlwaysOnThermalState) HookInstance("SBThermalAlwaysOnPolicy", "_updateThermalState", (IMP)hookUpdateAlwaysOnThermalState, (IMP *)&origUpdateAlwaysOnThermalState);
    if (!origStatusProvider) HookInstance("SBDashBoardThermalStatusProvider", "thermalStatus", (IMP)hookStatusProvider, (IMP *)&origStatusProvider);
}

static void SettingsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) { LoadConfig(); ApplyMode(); }

static void TimerTick(void) {
    if (IsThermalProcess()) {
        InstallThermalHooks();
        BOOL before = gEmergency; SampleTemperature(); ApplyMode();
        if (before != gEmergency || (++gStatusTick % 8) == 0) WriteStatus();
    } else if (IsSpringBoard()) {
        InstallSpringBoardHooks();
        NSDictionary *s = ReadDictionary(kStatusPath); gEmergency = [s[@"emergency"] boolValue]; gTemperature = [s[@"temperatureC"] doubleValue];
    }
}

__attribute__((constructor)) static void CPUthermalLInit(void) {
    @autoreleasepool {
        gObservedMax = [NSMutableDictionary dictionary]; gObservedDisplayMax = [NSMutableDictionary dictionary]; LoadConfig();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SettingsChanged, CFSTR("com.riboly.cputhermal-l/settingsChanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        if (IsThermalProcess()) {
            InstallThermalHooks();
        } else if (IsSpringBoard()) InstallSpringBoardHooks();
        if (IsThermalProcess() || IsSpringBoard()) {
            gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
            dispatch_source_set_event_handler(gTimer, ^{ TimerTick(); }); dispatch_resume(gTimer);
        }
        WriteStatus();
    }
}
