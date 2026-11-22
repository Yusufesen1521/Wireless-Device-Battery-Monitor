// macOS Bluetooth battery levels: the levels macOS itself knows, read from two public sources.
//
//  1. The IORegistry "BatteryPercent" property. Apple's Magic Keyboard / Mouse / Trackpad and many
//     Bluetooth HID devices (keyboards, mice, controllers) publish it, together with
//     "BatteryStatusFlags" (charging).
//  2. `system_profiler SPBluetoothDataType -json`, which lists the connected Bluetooth devices with
//     the levels macOS shows in Control Centre: AirPods / Beats (left, right, case) and headsets that
//     report their battery over Hands-Free or the Apple accessory protocol.
//
// Neither needs the Bluetooth permission or a private API. Runs after the HID vendor drivers, like
// the Windows Bluetooth fallback, and skips devices a vendor driver already listed by name.

#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>

#include "../drivers/drivers.h"
#include "../hid.h"

#include <algorithm>
#include <cwctype>
#include <set>
#include <string>

namespace {

std::wstring W(NSString* s) { return s ? Utf8ToWide(s.UTF8String) : std::wstring(); }

std::wstring Lower(std::wstring s) {
    for (auto& c : s) c = (wchar_t)towlower((wint_t)c);
    return s;
}

// "AA:BB:CC:..." or "aa-bb-cc-..." -> "AABBCC...", so both sources agree on a device's key.
std::wstring NormAddress(NSString* a) {
    std::wstring out;
    for (wchar_t c : W(a))
        if (iswxdigit((wint_t)c)) out.push_back((wchar_t)towupper((wint_t)c));
    return out;
}

bool AlreadyListed(const PollContext& ctx, const std::wstring& key, const std::wstring& name) {
    std::wstring n = Lower(name);
    for (const auto& s : ctx.out)
        if (s.key == key || (!n.empty() && Lower(s.name) == n)) return true;
    return false;
}

DeviceKind KindFromMinorType(NSString* minor, const std::wstring& name) {
    NSString* m = minor.lowercaseString ?: @"";
    if ([m containsString:@"headset"] || [m containsString:@"headphone"] || [m containsString:@"earbud"] ||
        [m containsString:@"hands-free"])
        return DeviceKind::Headset;
    if ([m containsString:@"keyboard"]) return DeviceKind::Keyboard;
    if ([m containsString:@"mouse"] || [m containsString:@"trackpad"] || [m containsString:@"pointing"])
        return DeviceKind::Mouse;
    if ([m containsString:@"gamepad"] || [m containsString:@"joystick"] || [m containsString:@"game"])
        return DeviceKind::Gamepad;
    if ([m containsString:@"speaker"] || [m containsString:@"portable audio"]) return DeviceKind::Speaker;
    if ([m containsString:@"phone"]) return DeviceKind::Phone;
    if ([m containsString:@"microphone"]) return DeviceKind::Microphone;
    return GuessKind(name);
}

// "85%" / "85" / @85 -> 85; -1 when missing or out of range.
int Percent(id v) {
    if (!v) return -1;
    int p = -1;
    if ([v isKindOfClass:[NSNumber class]]) p = [v intValue];
    else if ([v isKindOfClass:[NSString class]] && [v length]) p = [v intValue];
    return p >= 0 && p <= 100 ? p : -1;
}

USHORT HexId(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return (USHORT)[v unsignedIntValue];
    if (![v isKindOfClass:[NSString class]]) return 0;
    unsigned x = 0;
    [[NSScanner scannerWithString:v] scanHexInt:&x];
    return (USHORT)x;
}

id RegProp(io_service_t s, CFStringRef key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0));
}

// ---- 1. IORegistry BatteryPercent --------------------------------------------------------------

void PollRegistry(PollContext& ctx) {
    std::set<uint64_t> seen;  // a device can match both classes below
    for (const char* cls : {"AppleDeviceManagementHIDEventService", "IOHIDDevice"}) {
        io_iterator_t it = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching(cls), &it) != KERN_SUCCESS) continue;
        for (io_service_t s; (s = IOIteratorNext(it)) != IO_OBJECT_NULL; IOObjectRelease(s)) {
            int pct = Percent(RegProp(s, CFSTR("BatteryPercent")));
            if (pct < 0) continue;
            NSString* product = RegProp(s, CFSTR("Product"));
            NSString* address = RegProp(s, CFSTR("DeviceAddress"));
            std::wstring name = W(product);
            if (name.empty()) continue;
            uint64_t entry = 0;
            IORegistryEntryGetRegistryEntryID(s, &entry);
            std::wstring addr = NormAddress(address);
            std::wstring key = L"bt:" + (addr.empty() ? Lower(name) : addr);
            if (seen.count(entry) || AlreadyListed(ctx, key, name)) continue;
            seen.insert(entry);

            DeviceStatus d;
            d.key = key;
            d.name = name;
            d.via = L"Bluetooth";
            d.percent = pct;
            // Apple devices set both low bits of BatteryStatusFlags while on the cable.
            id flags = RegProp(s, CFSTR("BatteryStatusFlags"));
            if ([flags isKindOfClass:[NSNumber class]]) d.charging = ([flags unsignedIntValue] & 0x3) == 0x3;
            d.full = d.charging && pct >= 100;
            USHORT vid = HexId(RegProp(s, CFSTR("VendorID")));
            USHORT pid = HexId(RegProp(s, CFSTR("ProductID")));
            NSNumber* usage = RegProp(s, CFSTR("PrimaryUsage"));
            NSNumber* page = RegProp(s, CFSTR("PrimaryUsagePage"));
            d.kind = GuessKind(name);
            if (page.intValue == 1 && usage.intValue == 6) d.kind = DeviceKind::Keyboard;
            else if (page.intValue == 1 && (usage.intValue == 2 || usage.intValue == 1)) d.kind = DeviceKind::Mouse;
            else if (page.intValue == 1 && (usage.intValue == 4 || usage.intValue == 5)) d.kind = DeviceKind::Gamepad;
            ctx.Add(d, vid, pid);
        }
        IOObjectRelease(it);
    }
}

// ---- 2. system_profiler -------------------------------------------------------------------------

NSDictionary* ParseProfile(NSData* data) {
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray* top = [json isKindOfClass:[NSDictionary class]] ? json[@"SPBluetoothDataType"] : nil;
    id first = [top isKindOfClass:[NSArray class]] ? top.firstObject : nil;
    return [first isKindOfClass:[NSDictionary class]] ? first : nil;
}

NSDictionary* BluetoothProfile() {
    // Tests and bug reports: parse a saved `system_profiler SPBluetoothDataType -json` instead.
    if (const char* saved = getenv("BATTERYHUB_BT_PROFILE"))
        return ParseProfile([NSData dataWithContentsOfFile:@(saved)]);
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/system_profiler"];
    task.arguments = @[@"SPBluetoothDataType", @"-json", @"-detailLevel", @"basic"];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;
    // Read until EOF first (a full pipe would block the child), then reap it. A stuck child is
    // killed after 10 seconds so a poll can never hang on it.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask*) { dispatch_semaphore_signal(done); };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
        if (task.running) [task terminate];
    });
    NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return ParseProfile(data);
}

void PollProfiler(PollContext& ctx) {
    NSDictionary* bt = BluetoothProfile();
    NSArray* connected = bt[@"device_connected"];
    if (![connected isKindOfClass:[NSArray class]]) return;
    for (NSDictionary* entry in connected) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        for (NSString* deviceName in entry) {
            NSDictionary* p = entry[deviceName];
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            int main = Percent(p[@"device_batteryLevelMain"] ?: p[@"device_batteryLevel"]);
            int left = Percent(p[@"device_batteryLevelLeft"]);
            int right = Percent(p[@"device_batteryLevelRight"]);
            int kase = Percent(p[@"device_batteryLevelCase"]);
            if (main < 0 && left < 0 && right < 0) continue;  // no level (or only the case)

            std::wstring name = W(deviceName);
            std::wstring addr = NormAddress(p[@"device_address"]);
            std::wstring key = L"bt:" + (addr.empty() ? Lower(name) : addr);
            if (AlreadyListed(ctx, key, name)) continue;

            DeviceStatus d;
            d.key = key;
            d.name = name;
            d.via = L"Bluetooth";
            d.kind = KindFromMinorType(p[@"device_minorType"], name);
            if (left >= 0 || right >= 0) {
                // Earbuds: the lower bud is what runs out first; the rest goes in the tooltip.
                d.percent = left < 0 ? right : (right < 0 ? left : std::min(left, right));
                std::wstring detail;
                if (left >= 0) detail += L"L " + std::to_wstring(left) + L"%";
                if (right >= 0) detail += (detail.empty() ? L"" : L", ") + std::wstring(L"R ") + std::to_wstring(right) + L"%";
                if (kase >= 0) detail += L", case " + std::to_wstring(kase) + L"%";
                d.detail = detail;
                if (d.kind == DeviceKind::Other) d.kind = DeviceKind::Headset;
            } else {
                d.percent = main;
            }
            ctx.Add(d, HexId(p[@"device_vendorID"]), HexId(p[@"device_productID"]));
        }
    }
}

}  // namespace

void PollMacBluetooth(PollContext& ctx) {
    @autoreleasepool {
        PollRegistry(ctx);
        PollProfiler(ctx);
    }
}
