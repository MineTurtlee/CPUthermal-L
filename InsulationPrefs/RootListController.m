#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
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
@property(nonatomic, assign, readonly, getter=isRunning) BOOL running;
- (void)start;
- (void)stop;
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
    BOOL _running;
}

- (instancetype)init {
    if ((self = [super init])) _displayText = @"正在建立 1 秒采样窗口…";
    return self;
}

- (BOOL)isRunning { return _running; }

- (void)start {
    if (_running) return;
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
        self.displayText = @"IOReport 接口缺失"; [self stop]; return;
    }
    _channels = (CFMutableDictionaryRef)copyChannels(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"), 0, 0, 0);
    if (!_channels) { self.displayText = @"CPU 性能通道不可用"; [self stop]; return; }
    _subscription = createSubscription(NULL, _channels, &_subscribedChannels, 0, NULL);
    if (!_subscription) { self.displayText = @"CPU 采样订阅失败"; [self stop]; return; }
    if (!_subscribedChannels) { _subscribedChannels = _channels; CFRetain(_subscribedChannels); }
    _previousSample = _createSamples(_subscription, _subscribedChannels, NULL);
    if (!_previousSample) { self.displayText = @"CPU 初始采样失败"; [self stop]; return; }
    [self loadDeviceFrequencyLimits];
    _running = YES;
}

- (void)stop {
    _running = NO;
    if (_previousSample) { CFRelease(_previousSample); _previousSample = NULL; }
    if (_subscribedChannels) { CFRelease(_subscribedChannels); _subscribedChannels = NULL; }
    if (_channels) { CFRelease(_channels); _channels = NULL; }
    if (_subscription) { CFRelease(_subscription); _subscription = NULL; }
    if (_handle) { dlclose(_handle); _handle = NULL; }
    _createSamples = NULL; _createDelta = NULL; _channelName = NULL;
    _stateCount = NULL; _stateResidency = NULL; _stateName = NULL;
}

- (void)loadDeviceFrequencyLimits {
    char machine[64] = {0}; size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *model = [NSString stringWithUTF8String:machine] ?: @"";
    if ([model hasPrefix:@"iPhone11,"]) { _performanceMaxMHz = 2490; _efficiencyMaxMHz = 1590; }
}

- (NSDictionary *)metricsForChannel:(CFDictionaryRef)channel maxMHz:(double)maxMHz {
    int count = _stateCount(channel); uint64_t total = 0, active = 0, dominantResidency = 0;
    double weightedMHz = 0, weightedPState = 0; int largestP = 0; NSString *dominantState = @"IDLE";
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
        NSInteger state = [[name substringFromIndex:p.location + 1] integerValue];
        active += residency; weightedPState += state * (double)residency;
        if (residency > dominantResidency) { dominantResidency = residency; dominantState = name; }
        if (maxMHz > 0 && largestP > 0) {
            double minimum = maxMHz * 0.25;
            double mhz = maxMHz - ((double)state / largestP) * (maxMHz - minimum);
            weightedMHz += mhz * residency;
        }
    }
    return @{ @"mhz": active && maxMHz > 0 ? @(weightedMHz / active) : @0,
              @"pstate": active ? @(weightedPState / active) : @(-1),
              @"state": active ? dominantState : @"IDLE",
              @"active": total ? @(100.0 * active / total) : @0 };
}

- (double)batteryTemperature {
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSmartBattery"));
    if (!service) return 0;
    CFTypeRef raw = IORegistryEntryCreateCFProperty(service, CFSTR("Temperature"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    double value = 0;
    if (raw && CFGetTypeID(raw) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)raw, kCFNumberDoubleType, &value);
    if (raw) CFRelease(raw);
    if (value > 1000) value /= 100.0; else if (value > 200) value /= 10.0;
    return value > 0 && value < 100 ? value : 0;
}

- (NSString *)thermalStateText {
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateFair: return @"轻度";
        case NSProcessInfoThermalStateSerious: return @"严重";
        case NSProcessInfoThermalStateCritical: return @"危急";
        default: return @"正常";
    }
}

- (void)sample {
    if (!_running) [self start];
    if (!_running || !_previousSample) return;
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
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:CTLStatusPath] ?: @{};
    double internalTemperature = [status[@"temperatureC"] doubleValue];
    double batteryTemperature = [self batteryTemperature];
    NSString *mode = [status[@"mode"] isEqualToString:@"lowPower"] ? @"低功耗" : ([status[@"mode"] isEqualToString:@"disabled"] ? @"已停用" : @"解除温控");
    NSString *fallback = [status[@"emergency"] boolValue] ? @"回退已触发" : @"回退未触发";
    NSString *pFrequency = [pMetrics[@"pstate"] doubleValue] < 0 ? @"休眠" : [NSString stringWithFormat:@"%.0f MHz", [pMetrics[@"mhz"] doubleValue]];
    NSString *eFrequency = [eMetrics[@"pstate"] doubleValue] < 0 ? @"休眠" : [NSString stringWithFormat:@"%.0f MHz", [eMetrics[@"mhz"] doubleValue]];
    NSString *temperature = internalTemperature > 0 ? [NSString stringWithFormat:@"内部 %.1f°C", internalTemperature] : @"内部 --";
    if (batteryTemperature > 0) temperature = [temperature stringByAppendingFormat:@"  ·  电池 %.1f°C", batteryTemperature];
    NSString *hookState = [NSString stringWithFormat:@"注入  thermalmonitord %@  ·  SpringBoard %@", status[@"thermalHookCount"] ?: @0, status[@"springBoardHookCount"] ?: @0];
    self.displayText = [NSString stringWithFormat:@"P 核  %@  ·  活跃 %.1f%%  ·  %@\nE 核  %@  ·  活跃 %.1f%%  ·  %@\n温度  %@  ·  系统热状态 %@\n控制  %@  ·  %@\n%@\n频率为 IOReport P-State 驻留估算；仅本页可见时采样。",
                        pFrequency, [pMetrics[@"active"] doubleValue], pMetrics[@"state"] ?: @"--",
                        eFrequency, [eMetrics[@"active"] doubleValue], eMetrics[@"state"] ?: @"--",
                        temperature, [self thermalStateText], mode, fallback, hookState];
}

- (void)dealloc { [self stop]; }
@end

@interface CTLMonitorCell : PSTableCell
@property(nonatomic, strong) UILabel *monitorTitleLabel;
@property(nonatomic, strong) UILabel *monitorDetailLabel;
@end

@implementation CTLMonitorCell
+ (CGFloat)preferredHeightForWidth:(CGFloat)width { return 190.0; }
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone; self.textLabel.hidden = YES;
        _monitorTitleLabel = [UILabel new]; _monitorTitleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; _monitorTitleLabel.text = @"实时性能监控";
        _monitorDetailLabel = [UILabel new]; _monitorDetailLabel.numberOfLines = 0; _monitorDetailLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular]; _monitorDetailLabel.textColor = UIColor.secondaryLabelColor;
        _monitorTitleLabel.translatesAutoresizingMaskIntoConstraints = NO; _monitorDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_monitorTitleLabel]; [self.contentView addSubview:_monitorDetailLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_monitorTitleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor], [_monitorTitleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor], [_monitorTitleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [_monitorDetailLabel.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor], [_monitorDetailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor], [_monitorDetailLabel.topAnchor constraintEqualToAnchor:_monitorTitleLabel.bottomAnchor constant:8], [_monitorDetailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10]
        ]];
    }
    return self;
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier { [super refreshCellContentsWithSpecifier:specifier]; self.monitorDetailLabel.text = specifier.properties[@"monitorText"] ?: @"正在建立 1 秒采样窗口…"; }
@end

@interface CTLRootListController : PSListController
@property(nonatomic, strong) CTLCPUFrequencySampler *frequencySampler;
@property(nonatomic, strong) NSTimer *frequencyTimer;
@property(nonatomic, assign) BOOL monitorPageVisible;
@end

@implementation CTLRootListController
- (NSMutableDictionary *)preferences { NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:CTLPrefsPath]; return prefs ?: [NSMutableDictionary dictionary]; }
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSArray *all = [self loadSpecifiersFromPlistName:@"Root" target:self]; NSString *mode = [self preferences][@"powerMode"] ?: @"fullPower"; NSMutableArray *visible = [NSMutableArray array];
    for (PSSpecifier *specifier in all) { NSString *required = specifier.properties[@"requiresMode"]; if (required.length && ![required isEqualToString:mode]) continue; [visible addObject:specifier]; }
    _specifiers = visible; return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier { return [self preferences][specifier.properties[@"key"]] ?: specifier.properties[@"default"]; }
- (void)viewDidLoad { [super viewDidLoad]; [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil]; [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil]; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; self.monitorPageVisible = YES; [self startLiveMonitor]; }
- (void)viewWillDisappear:(BOOL)animated { self.monitorPageVisible = NO; [self stopLiveMonitor]; [super viewWillDisappear:animated]; }
- (void)applicationDidEnterBackground { [self stopLiveMonitor]; }
- (void)applicationWillEnterForeground { if (self.monitorPageVisible) [self startLiveMonitor]; }
- (void)startLiveMonitor { if (self.frequencyTimer) return; self.frequencySampler = [CTLCPUFrequencySampler new]; [self.frequencySampler start]; [self updateMonitorText:self.frequencySampler.displayText]; self.frequencyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshCPUFrequency) userInfo:nil repeats:YES]; }
- (void)stopLiveMonitor { [self.frequencyTimer invalidate]; self.frequencyTimer = nil; [self.frequencySampler stop]; self.frequencySampler = nil; [self updateMonitorText:@"监控已暂停；再次打开本设置页后恢复。"] ; }
- (void)refreshCPUFrequency { if (!self.monitorPageVisible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { [self stopLiveMonitor]; return; } [self.frequencySampler sample]; [self updateMonitorText:self.frequencySampler.displayText]; }
- (void)updateMonitorText:(NSString *)text { PSSpecifier *specifier = [self specifierForID:@"cpuMonitor"]; if (!specifier) return; [specifier setProperty:text ?: @"--" forKey:@"monitorText"]; if (self.monitorPageVisible) [self reloadSpecifier:specifier]; }
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier { NSMutableDictionary *prefs = [self preferences]; NSString *key = specifier.properties[@"key"]; if (key && value) prefs[key] = value; [prefs writeToFile:CTLPrefsPath atomically:YES]; notify_post(CTLSettingsChanged); if ([key isEqualToString:@"powerMode"]) { _specifiers = nil; [self reloadSpecifiers]; } }
- (void)applySettings { notify_post(CTLSettingsChanged); [self showMessage:@"设置已发送到 thermalmonitord 与 SpringBoard。" title:@"CPUthermal-L"]; }
- (void)restartThermalDaemon { [self run:@"/usr/bin/killall" arguments:@[@"-TERM", @"thermalmonitord"]]; }
- (void)respring { [self run:@"/usr/bin/killall" arguments:@[@"-TERM", @"SpringBoard"]]; }
- (void)resetSettings { [[NSFileManager defaultManager] removeItemAtPath:CTLPrefsPath error:nil]; notify_post(CTLSettingsChanged); _specifiers = nil; [self reloadSpecifiers]; }
- (void)showDiagnostics {
    NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:CTLStatusPath] ?: @{};
    NSString *text = [NSString stringWithFormat:@"模式：%@\nthermalmonitord Hook：%@\nSpringBoard Hook：%@\n内部温度：%@ °C\n极端回退：%@\n最后应用：%@", s[@"mode"] ?: @"尚无状态", s[@"thermalHookCount"] ?: @0, s[@"springBoardHookCount"] ?: @0, s[@"temperatureC"] ?: @"--", [s[@"emergency"] boolValue] ? @"已触发" : @"未触发", s[@"updatedAt"] ?: @"--"];
    [self showMessage:text title:@"运行诊断"];
}
- (void)openSourceCode { [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/riboly/CPUthermal-L"] options:@{} completionHandler:nil]; }
- (void)run:(NSString *)path arguments:(NSArray<NSString *> *)arguments { NSMutableArray *all = [NSMutableArray arrayWithObject:path]; [all addObjectsFromArray:arguments]; char **argv = calloc(all.count + 1, sizeof(char *)); for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]); pid_t pid = 0; int rc = posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, NULL); for (NSUInteger i = 0; i < all.count; i++) free(argv[i]); free(argv); if (rc == 0) waitpid(pid, NULL, 0); }
- (void)showMessage:(NSString *)message title:(NSString *)title { UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [self stopLiveMonitor]; }
@end
