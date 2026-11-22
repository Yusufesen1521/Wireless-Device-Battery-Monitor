// BatteryHub for macOS (experimental): a menu-bar item showing the battery levels the shared
// vendor drivers report, e.g. "🎧 30%  🖱 93%", plus the same --list / --json / --dump flags as the
// Windows and Linux builds.
//
// Everything macOS-only lives in mac/ and src/mac/; the Windows and Linux builds never compile it.

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#include <IOKit/IOKitLib.h>

#include "../devices.h"
#include "../json_output.h"
#include "../platform_compat.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef APP_VERSION
#define APP_VERSION "0.0.0"
#endif

// From <IOKit/hid/IOHIDLib.h>, declared here because that header pulls in CFPlugInCOM.h, whose
// Windows-style typedefs clash with platform_compat.h. Available since macOS 10.15.
extern "C" int IOHIDCheckAccess(int requestType);    // 0 granted, 1 denied, 2 unknown
extern "C" bool IOHIDRequestAccess(int requestType);
static const int kIOHIDRequestTypeListenEventValue = 1;

namespace {

constexpr int kPollSeconds = 60;
constexpr int kLowBattery = 15;
NSString* const kQuitNotification = @"com.github.krisgfx9.BatteryHub.quit";
NSString* const kBundleId = @"com.github.krisgfx9.BatteryHub";
NSString* const kHiddenKey = @"HiddenDevices";
NSString* const kHideLastKnownKey = @"HideLastKnown";

// ---- presentation helpers ---------------------------------------------------------------------

NSString* NS(const std::wstring& s) { return [NSString stringWithUTF8String:WideToUtf8(s).c_str()]; }

std::wstring StatusText(const DeviceStatus& s) {
    if (!s.connected) return L"off / not connected";
    std::wstring t;
    if (!s.levelText.empty()) t = s.levelText;
    else if (s.percent >= 0) t = std::to_wstring(s.percent) + L"%";
    else t = s.note.empty() ? L"unknown" : s.note;
    if (!s.detail.empty() && s.percent >= 0) t += L" (" + s.detail + L")";
    if (s.full) t += L", full";
    else if (s.charging) t += L", charging";
    if (s.asleep) t += L", asleep";
    return t;
}

bool HasLevel(const DeviceStatus& s) { return s.percent >= 0 || !s.levelText.empty(); }

int KindOrder(DeviceKind k) {
    switch (k) {
        case DeviceKind::Headset: return 0;
        case DeviceKind::Mouse: return 1;
        case DeviceKind::Keyboard: return 2;
        case DeviceKind::Gamepad: return 3;
        case DeviceKind::Phone: return 4;
        default: return 5;
    }
}

// SF Symbol per device kind, with an emoji fallback for systems that lack the symbol.
void KindGlyph(DeviceKind k, NSString** symbol, NSString** emoji) {
    switch (k) {
        case DeviceKind::Headset: *symbol = @"headphones"; *emoji = @"🎧"; return;
        case DeviceKind::Mouse: *symbol = @"computermouse"; *emoji = @"🖱"; return;
        case DeviceKind::Keyboard: *symbol = @"keyboard"; *emoji = @"⌨️"; return;
        case DeviceKind::Gamepad: *symbol = @"gamecontroller"; *emoji = @"🎮"; return;
        case DeviceKind::Phone: *symbol = @"iphone"; *emoji = @"📱"; return;
        case DeviceKind::Microphone: *symbol = @"mic"; *emoji = @"🎙"; return;
        case DeviceKind::Speaker: *symbol = @"hifispeaker"; *emoji = @"🔈"; return;
        default: *symbol = @"battery.75"; *emoji = @"🔋"; return;
    }
}

NSAttributedString* SymbolString(NSString* symbol, NSString* fallback, NSColor* color, NSFont* font) {
    NSImage* img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    if (!img) return [[NSAttributedString alloc] initWithString:fallback attributes:@{NSFontAttributeName: font}];
    NSImageSymbolConfiguration* cfg = [NSImageSymbolConfiguration configurationWithPointSize:font.pointSize
                                                                                     weight:NSFontWeightRegular];
    img = [img imageWithSymbolConfiguration:cfg];
    NSTextAttachment* att = [[NSTextAttachment alloc] init];
    att.image = img;
    NSMutableAttributedString* s =
        [[NSAttributedString attributedStringWithAttachment:att] mutableCopy];
    [s addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, s.length)];
    [s addAttribute:NSBaselineOffsetAttributeName value:@(-1.5) range:NSMakeRange(0, s.length)];
    return s;
}

// ---- CLI --------------------------------------------------------------------------------------

void PutUtf8(const std::wstring& s) {
    std::string u = WideToUtf8(s);
    fwrite(u.data(), 1, u.size(), stdout);
}

int ListToConsole(bool dump) {
    if (dump) {
        PutUtf8(DumpHidCollections());
        return 0;
    }
    auto list = PollAllDevices();
    if (list.empty()) printf("No devices with battery info found.\n");
    for (const auto& s : list) {
        std::wstring line = s.name + L"  [" + s.via + L"]  " + StatusText(s);
        if (s.millivolts) line += L", " + std::to_wstring(s.millivolts) + L" mV";
        line += L"   (" + s.key + L")\n";
        PutUtf8(line);
    }
    return 0;
}

int ListJson() {
    std::string out = DevicesToJson(PollAllDevices());
    fwrite(out.data(), 1, out.size(), stdout);
    return 0;
}

int QuitRunning() {
    if (![NSRunningApplication runningApplicationsWithBundleIdentifier:kBundleId].count) {
        fprintf(stderr, "BatteryHub is not running.\n");
        return 1;
    }
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kQuitNotification
                                                                   object:nil
                                                                 userInfo:nil
                                                       deliverImmediately:YES];
    return 0;
}

// ---- background polling -----------------------------------------------------------------------

struct Poller {
    std::mutex mu;
    std::condition_variable cv;
    std::atomic<bool> stop{false};
    bool wake = false;
    std::thread thread;
};
Poller g_poller;
bool g_demo = false;

// --demo: sample devices instead of real ones (screenshots, checking colors), like the Windows build.
// Covers every display state: normal, low, charging, full, asleep.
std::vector<DeviceStatus> DemoDevices() {
    auto make = [](const wchar_t* key, const wchar_t* name, DeviceKind kind, int pct) {
        DeviceStatus s;
        s.key = key;
        s.name = name;
        s.kind = kind;
        s.percent = pct;
        s.via = L"demo";
        return s;
    };
    std::vector<DeviceStatus> v = {
        make(L"demo:headset", L"SteelSeries Arctis Nova 7", DeviceKind::Headset, 64),
        make(L"demo:mouse", L"Razer DeathAdder V3 Pro", DeviceKind::Mouse, 12),  // low
        make(L"demo:keyboard", L"Keychron K5 Max", DeviceKind::Keyboard, 47),
        make(L"demo:pad", L"DualSense Wireless Controller", DeviceKind::Gamepad, 100),
        make(L"demo:mouse2", L"Logitech G PRO X SUPERLIGHT 2", DeviceKind::Mouse, 81),
    };
    v[2].charging = true;
    v[3].charging = v[3].full = true;
    v[4].asleep = true;
    return v;
}

}  // namespace

// ---- app --------------------------------------------------------------------------------------

@interface BHAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem* item;
@property(strong) NSMutableSet<NSString*>* hidden;
@property BOOL hideLastKnown;
@property BOOL hasResults;
@end

@implementation BHAppDelegate {
    std::vector<DeviceStatus> _devices;
    IONotificationPortRef _notifyPort;
    io_iterator_t _addedIter;
}

- (void)applicationDidFinishLaunching:(NSNotification*)note {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    self.hidden = [NSMutableSet setWithArray:[d stringArrayForKey:kHiddenKey] ?: @[]];
    self.hideLastKnown = [d boolForKey:kHideLastKnownKey];

    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.toolTip = @"BatteryHub";
    self.item.menu = [[NSMenu alloc] init];
    self.item.menu.delegate = self;
    [self render];

    // Opening HID interfaces that also carry keyboard or mouse usages needs Input Monitoring.
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEventValue) == 2) IOHIDRequestAccess(kIOHIDRequestTypeListenEventValue);

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                        selector:@selector(quit:)
                                                            name:kQuitNotification
                                                          object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(refresh:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:nil];
    [self watchHidArrivals];

    g_poller.thread = std::thread([self] { [self pollLoop]; });
}

- (void)applicationWillTerminate:(NSNotification*)note {
    g_poller.stop = true;
    g_poller.cv.notify_all();
    if (g_poller.thread.joinable()) g_poller.thread.join();
    ShutdownDevices();
}

// Refresh soon after a HID device appears (receiver plugged in, Bluetooth device connected).
static void OnHidAdded(void* refcon, io_iterator_t it) {
    while (io_object_t o = IOIteratorNext(it)) IOObjectRelease(o);
    BHAppDelegate* me = (__bridge BHAppDelegate*)refcon;
    [NSObject cancelPreviousPerformRequestsWithTarget:me selector:@selector(refresh:) object:nil];
    [me performSelector:@selector(refresh:) withObject:nil afterDelay:2.0];
}

- (void)watchHidArrivals {
    _notifyPort = IONotificationPortCreate(MACH_PORT_NULL);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(_notifyPort), kCFRunLoopDefaultMode);
    if (IOServiceAddMatchingNotification(_notifyPort, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"),
                                         OnHidAdded, (__bridge void*)self, &_addedIter) == KERN_SUCCESS)
        while (io_object_t o = IOIteratorNext(_addedIter)) IOObjectRelease(o);  // arm the notification
}

- (void)pollLoop {
    while (!g_poller.stop) {
        std::vector<DeviceStatus> result = g_demo ? DemoDevices() : PollAllDevices();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_devices = result;
            self.hasResults = YES;
            [self render];
        });
        std::unique_lock<std::mutex> lock(g_poller.mu);
        g_poller.cv.wait_for(lock, std::chrono::seconds(kPollSeconds), [] { return g_poller.stop || g_poller.wake; });
        g_poller.wake = false;
    }
}

- (BOOL)isVisible:(const DeviceStatus&)s {
    if (!s.connected || s.unsupported || !HasLevel(s)) return NO;
    if ([self.hidden containsObject:NS(s.key)]) return NO;
    if (self.hideLastKnown && s.asleep) return NO;
    return YES;
}

- (std::vector<DeviceStatus>)sortedDevices {
    std::vector<DeviceStatus> v = _devices;
    std::stable_sort(v.begin(), v.end(), [](const DeviceStatus& a, const DeviceStatus& b) {
        return KindOrder(a.kind) < KindOrder(b.kind);
    });
    return v;
}

// Menu-bar title: one glyph + level per visible device.
- (void)render {
    NSFont* font = [NSFont monospacedDigitSystemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightRegular];
    NSMutableAttributedString* title = [[NSMutableAttributedString alloc] init];
    NSMutableArray<NSString*>* tips = [NSMutableArray array];
    for (const auto& s : [self sortedDevices]) {
        if (![self isVisible:s]) continue;
        bool low = s.percent >= 0 && s.percent <= kLowBattery && !s.charging;
        NSColor* color = s.asleep ? [NSColor secondaryLabelColor] : (low ? [NSColor systemRedColor] : [NSColor labelColor]);
        if (title.length)
            [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "
                                                                          attributes:@{NSFontAttributeName: font}]];
        NSString *symbol, *emoji;
        KindGlyph(s.kind, &symbol, &emoji);
        [title appendAttributedString:SymbolString(symbol, emoji, color, font)];
        NSString* level = s.percent >= 0 ? [NSString stringWithFormat:@" %d%%", s.percent]
                                         : [@" " stringByAppendingString:NS(s.levelText)];
        [title appendAttributedString:[[NSAttributedString alloc]
                                          initWithString:level
                                              attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
        if (s.full)
            [title appendAttributedString:SymbolString(@"checkmark", @"✓", [NSColor systemGreenColor], font)];
        else if (s.charging)
            [title appendAttributedString:SymbolString(@"bolt.fill", @"⚡", [NSColor systemBlueColor], font)];
        [tips addObject:NS(s.name + L": " + StatusText(s))];
    }
    if (!title.length)
        [title appendAttributedString:SymbolString(@"battery.0", @"🔋", [NSColor labelColor], font)];
    self.item.button.attributedTitle = title;
    self.item.button.toolTip = tips.count ? [tips componentsJoinedByString:@"\n"]
                                          : (self.hasResults ? @"BatteryHub: no devices found" : @"BatteryHub: checking…");
}

// The menu is rebuilt each time it opens, so it always shows the latest poll.
- (void)menuNeedsUpdate:(NSMenu*)menu {
    [menu removeAllItems];
    auto devices = [self sortedDevices];
    bool any = false;
    for (const auto& s : devices) {
        if (!s.connected) continue;
        any = true;
        NSString* label = NS(s.name + L" — " + StatusText(s) + (s.via.empty() ? L"" : L"  (" + s.via + L")"));
        NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:label action:@selector(toggleDevice:) keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = NS(s.key);
        mi.state = [self.hidden containsObject:NS(s.key)] ? NSControlStateValueOff : NSControlStateValueOn;
        if (s.unsupported || !HasLevel(s)) { mi.action = nil; mi.state = NSControlStateValueOff; }
        [menu addItem:mi];
    }
    if (!any) {
        NSMenuItem* none = [[NSMenuItem alloc] initWithTitle:self.hasResults ? @"No devices found" : @"Checking devices…"
                                                      action:nil
                                               keyEquivalent:@""];
        [menu addItem:none];
    }
    if (!g_demo && IOHIDCheckAccess(kIOHIDRequestTypeListenEventValue) == 1) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem* perm = [[NSMenuItem alloc] initWithTitle:@"Allow Input Monitoring…"
                                                      action:@selector(openPrivacy:)
                                               keyEquivalent:@""];
        perm.target = self;
        perm.toolTip = @"Some devices can only be read with the Input Monitoring permission.";
        [menu addItem:perm];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh Now" action:@selector(refresh:) keyEquivalent:@"r"];
    refresh.target = self;
    [menu addItem:refresh];
    NSMenuItem* hideLk = [[NSMenuItem alloc] initWithTitle:@"Hide Sleeping Devices"
                                                    action:@selector(toggleHideLastKnown:)
                                             keyEquivalent:@""];
    hideLk.target = self;
    hideLk.state = self.hideLastKnown ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:hideLk];
    NSMenuItem* login = [[NSMenuItem alloc] initWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = [self launchesAtLogin] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];
    NSMenuItem* dump = [[NSMenuItem alloc] initWithTitle:@"Copy Device Dump" action:@selector(copyDump:) keyEquivalent:@""];
    dump.target = self;
    dump.toolTip = @"Copies every HID collection (VID:PID, usage page) for a device support request.";
    [menu addItem:dump];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* about = [[NSMenuItem alloc]
        initWithTitle:strcmp(APP_VERSION, "0.0.0")
                          ? [NSString stringWithFormat:@"BatteryHub %s (experimental macOS build)", APP_VERSION]
                          : @"BatteryHub (experimental macOS build)"
               action:nil
        keyEquivalent:@""];
    [menu addItem:about];
    NSMenuItem* quit = [[NSMenuItem alloc] initWithTitle:@"Quit BatteryHub" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
}

- (void)toggleDevice:(NSMenuItem*)sender {
    NSString* key = sender.representedObject;
    if ([self.hidden containsObject:key]) [self.hidden removeObject:key];
    else [self.hidden addObject:key];
    [[NSUserDefaults standardUserDefaults] setObject:self.hidden.allObjects forKey:kHiddenKey];
    [self render];
}

- (void)toggleHideLastKnown:(id)sender {
    self.hideLastKnown = !self.hideLastKnown;
    [[NSUserDefaults standardUserDefaults] setBool:self.hideLastKnown forKey:kHideLastKnownKey];
    [self render];
}

- (void)refresh:(id)sender {
    {
        std::lock_guard<std::mutex> lock(g_poller.mu);
        g_poller.wake = true;
    }
    g_poller.cv.notify_all();
}

- (void)copyDump:(id)sender {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString* text = NS(DumpHidCollections());
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
        });
    });
}

- (void)openPrivacy:(id)sender {
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

// ---- open at login: SMAppService on macOS 13+, a LaunchAgent before that ----------------------

- (NSString*)launchAgentPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.github.krisgfx9.BatteryHub.plist"];
}

- (BOOL)launchesAtLogin {
    if (@available(macOS 13.0, *)) return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]];
}

- (void)toggleLogin:(id)sender {
    BOOL on = ![self launchesAtLogin];
    if (@available(macOS 13.0, *)) {
        NSError* err = nil;
        if (on) [SMAppService.mainAppService registerAndReturnError:&err];
        else [SMAppService.mainAppService unregisterAndReturnError:&err];
        if (err) NSLog(@"BatteryHub: open at login: %@", err);
        return;
    }
    NSString* path = [self launchAgentPath];
    if (!on) { [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; return; }
    NSDictionary* plist = @{
        @"Label": @"com.github.krisgfx9.BatteryHub",
        @"ProgramArguments": @[NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments[0]],
        @"RunAtLoad": @YES,
    };
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [plist writeToURL:[NSURL fileURLWithPath:path] error:nil];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end

int main(int argc, char** argv) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
                printf("Usage: batteryhub [option]\n"
                       "  (no option)  Run the menu-bar app\n"
                       "  --list       Print devices and battery levels, then exit\n"
                       "  --json       Print a JSON array of devices and battery levels, then exit\n"
                       "  --dump       Print all HID collections, then exit\n"
                       "  --quit       Ask a running instance to quit\n"
                       "  --demo       Run the menu-bar app with sample devices (screenshots, colors)\n"
                       "  -h, --help   Show this help\n");
                return 0;
            }
            if (!strcmp(argv[i], "--list")) return ListToConsole(false);
            if (!strcmp(argv[i], "--json")) return ListJson();
            if (!strcmp(argv[i], "--dump")) return ListToConsole(true);
            if (!strcmp(argv[i], "--quit")) return QuitRunning();
            if (!strcmp(argv[i], "--demo")) g_demo = true;
        }

        // One menu-bar item per user: hand over to an instance that is already running.
        NSString* myId = NSBundle.mainBundle.bundleIdentifier ?: kBundleId;
        for (NSRunningApplication* app in [NSRunningApplication runningApplicationsWithBundleIdentifier:myId])
            if (app.processIdentifier != getpid()) {
                fprintf(stderr, "BatteryHub is already running.\n");
                return 0;
            }

        NSApplication* app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;  // menu bar only, no Dock icon
        BHAppDelegate* delegate = [[BHAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
