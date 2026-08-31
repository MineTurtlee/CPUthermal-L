#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/wait.h>

static NSString *const CTLPrefsPath = @"/var/mobile/Library/Preferences/com.riboly.cputhermal-l.plist";
static NSString *const CTLStatusPath = @"/var/mobile/Library/Preferences/com.riboly.cputhermal-l.status.plist";
static const char *CTLSettingsChanged = "com.riboly.cputhermal-l/settingsChanged";

typedef CFDictionaryRef (*IOReportCopyChannelsInGroupFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void *(*IOReportCreateSubscriptionFn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamplesFn)(void *, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamplesDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*IOReportChannelStringFn)(CFDictionaryRef);
typedef int (*IOReportStateCountFn)(CFDictionaryRef);
typedef uint64_t (*IOReportStateResidencyFn)(CFDictionaryRef, int);
typedef CFStringRef (*IOReportStateNameFn)(CFDictionaryRef, int);

@interface CTLCPUFrequencySampler : NSObject
@property(nonatomic, copy) NSString *displayText;
- (void)start;
- (void)sample;
@end

@implementation CTLCPUFrequencySampler {
    void *_handle;
    void *_subscription;
    CFMutableDictionaryRef _channels;
    CFMutableDictionaryRef _subscribedChannels;
    CFDictionaryRef _previousSample;
    IOReportCreateSamplesFn _createSamples;
    IOReportCreateSamplesDeltaFn _createDelta;
    IOReportChannelStringFn _channelName;
    IOReportStateCountFn _stateCount;
    IOReportStateResidencyFn _stateResidency;
    IOReportStateNameFn _stateName;
    double _performanceMaxMHz;
    double _efficiencyMaxMHz;
}

- (instancetype)init {
    if ((self = [super init])) _displayText = @"正在采样…";
    return self;
}

- (void)start {
    if (_subscription) return;
    _handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!_handle) { self.displayText = @"IOReport 不可用"; return; }
    IOReportCopyChannelsInGroupFn copyChannels = dlsym(_handle, "IOReportCopyChannelsInGroup");
    IOReportCreateSubscriptionFn createSubscription = dlsym(_handle, "IOReportCreateSubscription");
    _createSamples = dlsym(_handle, "IOReportCreateSamples");
    _createDelta = dlsym(_handle, "IOReportCreateSamplesDelta");
    _channelName = dlsym(_handle, "IOReportChannelGetChannelName");
    _stateCount = dlsym(_handle, "IOReportStateGetCount");
    _stateResidency = dlsym(_handle, "IOReportStateGetResidency");
    _stateName = dlsym(_handle, "IOReportStateGetNameForIndex");
    if (!copyChannels || !createSubscription || !_createSamples || !_createDelta || !_channelName || !_stateCount || !_stateResidency || !_stateName) {
        self.displayText = @"IOReport 接口缺失"; return;
    }
    _channels = (CFMutableDictionaryRef)copyChannels(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"), 0, 0, 0);
    if (!_channels) { self.displayText = @"CPU 性能通道不可用"; return; }
    _subscription = createSubscription(NULL, _channels, &_subscribedChannels, 0, NULL);
    if (!_subscription) { self.displayText = @"CPU 采样订阅失败"; return; }
    if (!_subscribedChannels) { _subscribedChannels = _channels; CFRetain(_subscribedChannels); }
    _previousSample = _createSamples(_subscription, _subscribedChannels, NULL);
    [self loadDeviceFrequencyLimits];
}

- (void)loadDeviceFrequencyLimits {
    char machine[64] = {0}; size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *model = [NSString stringWithUTF8String:machine] ?: @"";
    if ([model hasPrefix:@"iPhone11,"]) { _performanceMaxMHz = 2490; _efficiencyMaxMHz = 1590; }
}

- (NSDictionary *)metricsForChannel:(CFDictionaryRef)channel maxMHz:(double)maxMHz {
    int count = _stateCount(channel); uint64_t total = 0, active = 0; double weightedMHz = 0, weightedPState = 0;
    int largestP = 0;
    for (int i = 0; i < count; i++) {
        NSString *name = (__bridge NSString *)_stateName(channel, i);
        NSRange p = [name rangeOfString:@"P" options:NSBackwardsSearch];
        if (p.location != NSNotFound) largestP = MAX(largestP, [[name substringFromIndex:p.location + 1] intValue]);
    }
    for (int i = 0; i < count; i++) {
        uint64_t residency = _stateResidency(channel, i); total += residency;
        NSString *name = (__bridge NSString *)_stateName(channel, i);
        NSRange p = [name rangeOfString:@"P" options:NSBackwardsSearch];
        if (p.location == NSNotFound || residency == 0) continue;
        NSInteger state = [[name substringFromIndex:p.location + 1] integerValue]; active += residency; weightedPState += state * (double)residency;
        if (maxMHz > 0 && largestP > 0) {
            double minimum = maxMHz * 0.25;
            double mhz = maxMHz - ((double)state / largestP) * (maxMHz - minimum);
            weightedMHz += mhz * residency;
        }
    }
    return @{ @"mhz": active && maxMHz > 0 ? @(weightedMHz / active) : @0,
              @"pstate": active ? @(weightedPState / active) : @(-1),
              @"active": total ? @(100.0 * active / total) : @0 };
}

- (void)sample {
    [self start]; if (!_subscription || !_previousSample) return;
    CFDictionaryRef current = _createSamples(_subscription, _subscribedChannels, NULL);
    if (!current) return;
    CFDictionaryRef delta = _createDelta(_previousSample, current, NULL);
    CFRelease(_previousSample); _previousSample = current;
    if (!delta) return;
    NSDictionary *eMetrics = nil, *pMetrics = nil;
    NSArray *channels = [(__bridge NSDictionary *)delta objectForKey:@"IOReportChannels"];
    for (NSDictionary *channel in channels) {
        NSString *name = (__bridge NSString *)_channelName((__bridge CFDictionaryRef)channel);
        if ([name isEqualToString:@"ECPU"]) eMetrics = [self metricsForChannel:(__bridge CFDictionaryRef)channel maxMHz:_efficiencyMaxMHz];
        else if ([name isEqualToString:@"PCPU"]) pMetrics = [self metricsForChannel:(__bridge CFDictionaryRef)channel maxMHz:_performanceMaxMHz];
    }
    CFRelease(delta);
    if (_performanceMaxMHz > 0 && (pMetrics || eMetrics)) {
        NSString *p = [pMetrics[@"pstate"] doubleValue] < 0 ? @"休眠" : [NSString stringWithFormat:@"%.0f MHz", [pMetrics[@"mhz"] doubleValue]];
        NSString *e = [eMetrics[@"pstate"] doubleValue] < 0 ? @"休眠" : [NSString stringWithFormat:@"%.0f MHz", [eMetrics[@"mhz"] doubleValue]];
        self.displayText = [NSString stringWithFormat:@"P核 %@ · E核 %@", p, e];
    } else if (pMetrics || eMetrics) {
        self.displayText = [NSString stringWithFormat:@"P核 P%.1f · E核 P%.1f", [pMetrics[@"pstate"] doubleValue], [eMetrics[@"pstate"] doubleValue]];
    } else self.displayText = @"等待 CPU 活动…";
}

- (void)dealloc {
    if (_previousSample) CFRelease(_previousSample);
    if (_subscribedChannels) CFRelease(_subscribedChannels);
    if (_channels) CFRelease(_channels);
    if (_subscription) CFRelease(_subscription);
    if (_handle) dlclose(_handle);
}
@end

@interface CTLRootListController : PSListController
@property(nonatomic, strong) CTLCPUFrequencySampler *frequencySampler;
@property(nonatomic, strong) NSTimer *frequencyTimer;
@end

@implementation CTLRootListController

- (NSMutableDictionary *)preferences {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:CTLPrefsPath];
    return prefs ?: [NSMutableDictionary dictionary];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSArray *all = [self loadSpecifiersFromPlistName:@"Root" target:self];
    NSString *mode = [self preferences][@"powerMode"] ?: @"fullPower";
    NSMutableArray *visible = [NSMutableArray array];
    for (PSSpecifier *specifier in all) {
        NSString *required = specifier.properties[@"requiresMode"];
        if (required.length && ![required isEqualToString:mode]) continue;
        [visible addObject:specifier];
    }
    _specifiers = visible;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    if ([specifier.properties[@"key"] isEqualToString:@"liveCPUFrequency"]) return self.frequencySampler.displayText ?: @"正在采样…";
    return [self preferences][specifier.properties[@"key"]] ?: specifier.properties[@"default"];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.frequencySampler) self.frequencySampler = [CTLCPUFrequencySampler new];
    [self refreshCPUFrequency];
    self.frequencyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshCPUFrequency) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self.frequencyTimer invalidate]; self.frequencyTimer = nil;
    [super viewWillDisappear:animated];
}

- (void)refreshCPUFrequency {
    [self.frequencySampler sample];
    PSSpecifier *specifier = [self specifierForID:@"cpuFrequency"];
    if (specifier) [self reloadSpecifier:specifier];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = [self preferences];
    NSString *key = specifier.properties[@"key"];
    if (key && value) prefs[key] = value;
    [prefs writeToFile:CTLPrefsPath atomically:YES];
    notify_post(CTLSettingsChanged);
    if ([key isEqualToString:@"powerMode"]) {
        _specifiers = nil;
        [self reloadSpecifiers];
    }
}

- (void)applySettings {
    notify_post(CTLSettingsChanged);
    [self showMessage:@"设置已发送到 thermalmonitord 与 SpringBoard。" title:@"CPUthermal-L"];
}

- (void)restartThermalDaemon { [self run:@"/usr/bin/killall" arguments:@[@"-TERM", @"thermalmonitord"]]; }
- (void)respring { [self run:@"/usr/bin/killall" arguments:@[@"-TERM", @"SpringBoard"]]; }

- (void)resetSettings {
    [[NSFileManager defaultManager] removeItemAtPath:CTLPrefsPath error:nil];
    notify_post(CTLSettingsChanged);
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)showDiagnostics {
    NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:CTLStatusPath] ?: @{};
    NSString *text = [NSString stringWithFormat:@"模式：%@\n进程：%@\nHook 数量：%@\n检测温度：%@ °C\n极端回退：%@\n最后应用：%@",
                      s[@"mode"] ?: @"尚无状态", s[@"process"] ?: @"未报告", s[@"hookCount"] ?: @0,
                      s[@"temperatureC"] ?: @"--", [s[@"emergency"] boolValue] ? @"已触发" : @"未触发", s[@"updatedAt"] ?: @"--"];
    [self showMessage:text title:@"运行诊断"];
}

- (void)openSourceCode {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/riboly/CPUthermal-L"] options:@{} completionHandler:nil];
}

- (void)run:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    NSMutableArray *all = [NSMutableArray arrayWithObject:path]; [all addObjectsFromArray:arguments];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]);
    pid_t pid = 0; int rc = posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, NULL);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]); free(argv);
    if (rc == 0) waitpid(pid, NULL, 0);
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
