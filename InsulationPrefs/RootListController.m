#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>

static NSString *const CTLPrefsPath = @"/var/mobile/Library/Preferences/com.riboly.cputhermal-l.plist";
static NSString *const CTLStatusPath = @"/var/mobile/Library/Preferences/com.riboly.cputhermal-l.status.plist";
static const char *CTLSettingsChanged = "com.riboly.cputhermal-l/settingsChanged";

@interface CTLRootListController : PSListController
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
    return [self preferences][specifier.properties[@"key"]] ?: specifier.properties[@"default"];
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
