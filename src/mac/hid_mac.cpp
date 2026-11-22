// macOS HID backend for the shared vendor drivers.
//
// Uses IOKit's IOHIDDevice API directly, so no third-party HID library is required. The
// report-buffer conventions match the Windows backend (and hidapi), so every portable vendor
// driver in src/drivers/ compiles and runs unchanged:
//   * Write/SetFeature: data[0] is the report ID (0 for unnumbered), zero-padded to report length.
//   * Read: a leading zero report ID is stripped, so data[0] is the first payload byte for
//     unnumbered reports and the report ID for numbered ones.
//
// Report lengths follow Windows HIDP_CAPS: they always include one report-ID byte, even for
// devices that do not number their reports, because the drivers were written against those caps.
//
// macOS exposes one IOHIDDevice per USB interface, while Windows lists one entry per top-level
// collection. The report descriptor is split into application collections (as the Linux backend
// does) so the drivers' usage-page filters see the same collections they do on Windows.
//
// Opening HID devices that carry keyboard/mouse usages needs the "Input Monitoring" permission
// (System Settings -> Privacy & Security). Vendor-only collections usually open without it.

#ifndef __APPLE__
// Intentionally empty on other platforms.
#else

#include "../hid.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
// IOHIDManager.h is avoided on purpose: it pulls in CFPlugInCOM.h, whose ULONG typedef clashes
// with the Windows-style types in platform_compat.h. Devices are enumerated via IOService instead.

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cwctype>
#include <deque>
#include <map>

// Per-open-device state. Input reports arrive through a callback while the run loop of the
// thread that reads is running in a private mode; they are queued here until Read() takes them.
struct MacHid {
    IOHIDDeviceRef dev = nullptr;
    CFRunLoopRef loop = nullptr;  // run loop the device is scheduled on
    std::vector<uint8_t> buf;     // buffer IOKit fills for each input report
    std::deque<std::vector<BYTE>> queue;
};

namespace {

const CFStringRef kReadMode = CFSTR("com.github.krisgfx9.WirelessBattery.hidread");
constexpr size_t kMaxQueued = 64;

struct ReportInfo {
    int in = 0, out = 0, feat = 0;
    USHORT usagePage = 0, usage = 0;
};
using ReportBits = std::map<int, std::array<int, 3>>;  // report id -> {input, output, feature} bits

void FinalizeCollection(ReportInfo& r, const ReportBits& bits) {
    for (const auto& [id, arr] : bits) {
        (void)id;
        // Like HIDP_CAPS: one report-ID byte is always counted.
        if (arr[0] > 0) r.in = std::max(r.in, (arr[0] + 7) / 8 + 1);
        if (arr[1] > 0) r.out = std::max(r.out, (arr[1] + 7) / 8 + 1);
        if (arr[2] > 0) r.feat = std::max(r.feat, (arr[2] + 7) / 8 + 1);
    }
}

unsigned ItemData(const unsigned char* p, int n) {
    unsigned v = 0;
    for (int i = 0; i < n; i++) v |= ((unsigned)p[i]) << (8 * i);
    return v;
}

std::vector<ReportInfo> ParseReportDescriptor(const unsigned char* d, size_t n) {
    std::vector<ReportInfo> result;
    ReportInfo cur;
    ReportBits bits;
    int reportSize = 0, reportCount = 0, reportId = 0, depth = 0;
    USHORT usagePage = 0, usage = 0;
    std::vector<std::array<int, 4>> globalStack;  // Push / Pop of the globals we track
    size_t i = 0;
    auto flush = [&]() {
        FinalizeCollection(cur, bits);
        result.push_back(cur);
        cur = ReportInfo();
        bits.clear();
    };
    while (i < n) {
        unsigned char prefix = d[i++];
        if (prefix == 0xFE) {  // long item: skip it
            if (i + 1 >= n) break;
            i += 2 + d[i];
            continue;
        }
        int size = prefix & 3;
        if (size == 3) size = 4;
        if (i + (size_t)size > n) break;
        unsigned data = ItemData(d + i, size);
        i += (size_t)size;
        int type = (prefix >> 2) & 3;  // 0 main, 1 global, 2 local
        int tag = (prefix >> 4) & 0x0F;
        if (type == 1) {  // global
            if (tag == 0) usagePage = (USHORT)data;
            else if (tag == 7) reportSize = (int)data;
            else if (tag == 9) reportCount = (int)data;
            else if (tag == 8) reportId = (int)data;
            else if (tag == 10) globalStack.push_back({usagePage, reportSize, reportCount, reportId});
            else if (tag == 11 && !globalStack.empty()) {
                auto g = globalStack.back();
                globalStack.pop_back();
                usagePage = (USHORT)g[0], reportSize = g[1], reportCount = g[2], reportId = g[3];
            }
        } else if (type == 2) {  // local
            if (tag == 0 && !usage) usage = (USHORT)data;
        } else if (type == 0) {  // main
            if (tag == 0x0A) {  // Collection
                if (data == 1 && depth == 0 && !bits.empty()) flush();  // Application
                if (data == 1 && depth == 0) { cur.usagePage = usagePage; cur.usage = usage; }
                depth++;
                usage = 0;
            } else if (tag == 0x0C) {  // End Collection
                depth--;
                if (depth <= 0 && !bits.empty()) { flush(); depth = 0; }
                usage = 0;
            } else if (tag == 8 || tag == 9 || tag == 0x0B) {  // Input / Output / Feature
                int idx = tag == 8 ? 0 : (tag == 9 ? 1 : 2);
                bits[reportId][idx] += reportSize * reportCount;
                usage = 0;
            }
        }
    }
    if (!bits.empty()) flush();
    return result;
}

int32_t IntProp(IOHIDDeviceRef dev, CFStringRef key) {
    CFTypeRef ref = IOHIDDeviceGetProperty(dev, key);
    int32_t v = 0;
    if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)ref, kCFNumberSInt32Type, &v);
    return v;
}

std::wstring StringProp(IOHIDDeviceRef dev, CFStringRef key) {
    CFTypeRef ref = IOHIDDeviceGetProperty(dev, key);
    if (!ref || CFGetTypeID(ref) != CFStringGetTypeID()) return {};
    char buf[512];
    if (!CFStringGetCString((CFStringRef)ref, buf, sizeof(buf), kCFStringEncodingUTF8)) return {};
    std::wstring s = Utf8ToWide(buf);
    size_t a = 0, b = s.size();
    while (a < b && std::iswspace(s[a])) a++;
    while (b > a && std::iswspace(s[b - 1])) b--;
    return s.substr(a, b - a);
}

// USB interface number of the IOUSBHostInterface above this HID service, -1 when unknown
// (e.g. Bluetooth).
int InterfaceOf(io_service_t service) {
    CFTypeRef ref = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("bInterfaceNumber"),
                                                    kCFAllocatorDefault,
                                                    kIORegistryIterateRecursively | kIORegistryIterateParents);
    int v = -1;
    if (ref) {
        if (CFGetTypeID(ref) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)ref, kCFNumberIntType, &v);
        CFRelease(ref);
    }
    return v;
}

// Collections are addressed by their IORegistry entry id, which stays valid while the device is
// attached: "DevSrvsID:<id>" (the same form hidapi uses).
std::wstring PathOf(io_service_t service) {
    uint64_t id = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &id) != KERN_SUCCESS) return {};
    return L"DevSrvsID:" + std::to_wstring(id);
}

IOHIDDeviceRef DeviceFromPath(const std::wstring& path) {
    const std::wstring prefix = L"DevSrvsID:";
    if (path.compare(0, prefix.size(), prefix) != 0) return nullptr;
    uint64_t id = 0;
    try { id = std::stoull(path.substr(prefix.size())); } catch (...) { return nullptr; }
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IORegistryEntryIDMatching(id));
    if (!service) return nullptr;
    IOHIDDeviceRef dev = IOHIDDeviceCreate(kCFAllocatorDefault, service);
    IOObjectRelease(service);
    return dev;
}

void OnInputReport(void* context, IOReturn result, void*, IOHIDReportType, uint32_t reportId,
                   uint8_t* report, CFIndex length) {
    auto* m = (MacHid*)context;
    if (result != kIOReturnSuccess || !report || length <= 0) return;
    // IOKit hands over numbered reports with their ID byte first and unnumbered ones without one,
    // which is already the stripped form Read() promises.
    (void)reportId;
    m->queue.emplace_back(report, report + length);
    while (m->queue.size() > kMaxQueued) m->queue.pop_front();
}

// Make sure the device delivers its input reports to the calling thread's run loop.
void ScheduleOnCurrentThread(MacHid* m) {
    CFRunLoopRef cur = CFRunLoopGetCurrent();
    if (m->loop == cur) return;
    if (m->loop) IOHIDDeviceUnscheduleFromRunLoop(m->dev, m->loop, kReadMode);
    IOHIDDeviceScheduleWithRunLoop(m->dev, cur, kReadMode);
    m->loop = cur;
}

void Pump(MacHid* m, double seconds) {
    ScheduleOnCurrentThread(m);
    CFRunLoopRunInMode(kReadMode, seconds, true);
}

// hidapi convention: an unnumbered report goes out without its leading 0 byte.
IOReturn SendReport(IOHIDDeviceRef dev, IOHIDReportType type, const std::vector<BYTE>& buf) {
    if (buf.empty()) return kIOReturnBadArgument;
    BYTE id = buf[0];
    const uint8_t* p = buf.data();
    CFIndex len = (CFIndex)buf.size();
    if (id == 0) { p++; len--; }
    return IOHIDDeviceSetReport(dev, type, id, p, len);
}

// Reads a report into out (out[0] = report ID), sized to `len` bytes including that byte.
bool FetchReport(IOHIDDeviceRef dev, IOHIDReportType type, BYTE reportId, size_t len, std::vector<BYTE>& out) {
    if (len < 2) return false;
    out.assign(len, 0);
    out[0] = reportId;
    uint8_t* p = out.data();
    CFIndex got = (CFIndex)len;
    if (reportId == 0) { p++; got--; }
    if (IOHIDDeviceGetReport(dev, type, reportId, p, &got) != kIOReturnSuccess) return false;
    // Numbered replies include the report ID first; keep the buffer at its full report length
    // (zero padded) like HidD_GetFeature does on Windows.
    return true;
}

}  // namespace

std::vector<HidColl> EnumHid() {
    std::vector<HidColl> out;
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching(kIOHIDDeviceKey), &it) != KERN_SUCCESS)
        return out;
    for (io_service_t service; (service = IOIteratorNext(it)) != IO_OBJECT_NULL;) {
        IOHIDDeviceRef dev = IOHIDDeviceCreate(kCFAllocatorDefault, service);
        if (!dev) { IOObjectRelease(service); continue; }
        HidColl c;
        c.path = PathOf(service);
        if (c.path.empty()) { CFRelease(dev); IOObjectRelease(service); continue; }
        c.vid = (USHORT)IntProp(dev, CFSTR(kIOHIDVendorIDKey));
        c.pid = (USHORT)IntProp(dev, CFSTR(kIOHIDProductIDKey));
        c.version = (USHORT)IntProp(dev, CFSTR(kIOHIDVersionNumberKey));
        c.product = StringProp(dev, CFSTR(kIOHIDProductKey));
        c.iface = InterfaceOf(service);

        std::vector<ReportInfo> infos;
        CFTypeRef desc = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDReportDescriptorKey));
        if (desc && CFGetTypeID(desc) == CFDataGetTypeID())
            infos = ParseReportDescriptor(CFDataGetBytePtr((CFDataRef)desc), (size_t)CFDataGetLength((CFDataRef)desc));
        if (infos.empty()) {
            // No descriptor: fall back to the primary usage and the interface-wide maxima.
            ReportInfo r;
            r.usagePage = (USHORT)IntProp(dev, CFSTR(kIOHIDPrimaryUsagePageKey));
            r.usage = (USHORT)IntProp(dev, CFSTR(kIOHIDPrimaryUsageKey));
            int in = IntProp(dev, CFSTR(kIOHIDMaxInputReportSizeKey));
            int outLen = IntProp(dev, CFSTR(kIOHIDMaxOutputReportSizeKey));
            int feat = IntProp(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey));
            r.in = in ? in + 1 : 0;
            r.out = outLen ? outLen + 1 : 0;
            r.feat = feat ? feat + 1 : 0;
            infos.push_back(r);
        }
        for (const auto& info : infos) {
            HidColl col = c;
            col.caps.UsagePage = info.usagePage;
            col.caps.Usage = info.usage;
            col.caps.InputReportByteLength = (USHORT)info.in;
            col.caps.OutputReportByteLength = (USHORT)info.out;
            col.caps.FeatureReportByteLength = (USHORT)info.feat;
            out.push_back(std::move(col));
        }
        CFRelease(dev);
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    std::stable_sort(out.begin(), out.end(), [](const HidColl& a, const HidColl& b) {
        if (a.vid != b.vid) return a.vid < b.vid;
        if (a.pid != b.pid) return a.pid < b.pid;
        return a.iface < b.iface;
    });
    return out;
}

// ---- HidDev -----------------------------------------------------------------------------------

bool HidDev::Open(const HidColl& c) {
    Close();
    c_ = c;
    IOHIDDeviceRef dev = DeviceFromPath(c.path);
    if (!dev) return false;
    if (IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        CFRelease(dev);
        return false;
    }
    mac_ = new MacHid();
    mac_->dev = dev;
    int maxIn = IntProp(dev, CFSTR(kIOHIDMaxInputReportSizeKey));
    mac_->buf.assign((size_t)std::max<int>({maxIn, c.inLen(), 64}), 0);
    IOHIDDeviceRegisterInputReportCallback(dev, mac_->buf.data(), (CFIndex)mac_->buf.size(), OnInputReport, mac_);
    ScheduleOnCurrentThread(mac_);
    return true;
}

// macOS has no read-only or zero-access open; a shared (non-seizing) open covers all three uses.
bool HidDev::OpenReadOnly(const HidColl& c) { return Open(c); }
bool HidDev::OpenFeatureOnly(const HidColl& c) { return Open(c); }

void HidDev::Close() {
    if (!mac_) return;
    IOHIDDeviceRegisterInputReportCallback(mac_->dev, mac_->buf.data(), (CFIndex)mac_->buf.size(), nullptr, nullptr);
    if (mac_->loop) IOHIDDeviceUnscheduleFromRunLoop(mac_->dev, mac_->loop, kReadMode);
    IOHIDDeviceClose(mac_->dev, kIOHIDOptionsTypeNone);
    CFRelease(mac_->dev);
    delete mac_;
    mac_ = nullptr;
}

bool HidDev::Write(const std::vector<BYTE>& data, int timeoutMs) {
    (void)timeoutMs;
    if (!ok() || !c_.outLen() || data.empty()) return false;
    std::vector<BYTE> buf(c_.outLen(), 0);
    memcpy(buf.data(), data.data(), std::min(buf.size(), data.size()));
    return SendReport(mac_->dev, kIOHIDReportTypeOutput, buf) == kIOReturnSuccess;
}

int HidDev::Read(std::vector<BYTE>& buf, int timeoutMs) {
    if (!ok() || !c_.inLen()) return -1;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(std::max(timeoutMs, 0));
    for (;;) {
        if (!mac_->queue.empty()) {
            buf = std::move(mac_->queue.front());
            mac_->queue.pop_front();
            return (int)buf.size();
        }
        auto left = std::chrono::duration<double>(deadline - std::chrono::steady_clock::now()).count();
        if (left <= 0) {
            Pump(mac_, 0);  // pick up anything already delivered
            if (mac_->queue.empty()) return -1;
            continue;
        }
        Pump(mac_, left);
    }
}

int HidDev::WriteAndRead(const std::vector<BYTE>& data, std::vector<BYTE>& buf, int timeoutMs,
                         bool* writeSucceeded) {
    // Reports are queued from Open() on, so a reply that arrives during the write is not lost.
    bool wrote = Write(data, timeoutMs);
    if (writeSucceeded) *writeSucceeded = wrote;
    if (!wrote) return -1;
    return Read(buf, timeoutMs);
}

int HidDev::SetOutputAndRead(const std::vector<BYTE>& data, std::vector<BYTE>& buf, int timeoutMs) {
    if (!ok() || !c_.inLen() || !c_.outLen() || data.empty()) return -1;
    return Write(data, timeoutMs) ? Read(buf, timeoutMs) : -1;
}

void HidDev::Flush() {
    if (!ok()) return;
    Pump(mac_, 0);
    mac_->queue.clear();
}

bool HidDev::SetFeature(const std::vector<BYTE>& data) {
    if (!ok() || !c_.featLen() || data.empty()) return false;
    std::vector<BYTE> buf(c_.featLen(), 0);
    memcpy(buf.data(), data.data(), std::min(buf.size(), data.size()));
    return SendReport(mac_->dev, kIOHIDReportTypeFeature, buf) == kIOReturnSuccess;
}

bool HidDev::GetFeature(BYTE reportId, std::vector<BYTE>& out) {
    if (!ok() || !c_.featLen()) return false;
    return FetchReport(mac_->dev, kIOHIDReportTypeFeature, reportId, c_.featLen(), out);
}

bool HidDev::GetFeatureByte(BYTE reportId, BYTE& value) {
    if (!ok() || !reportId || c_.featLen() < 2) return false;
    std::vector<BYTE> report;
    if (!FetchReport(mac_->dev, kIOHIDReportTypeFeature, reportId, 2, report) || report[0] != reportId) return false;
    value = report[1];
    return true;
}

bool HidDev::GetInputReport(BYTE reportId, std::vector<BYTE>& out) {
    if (!ok() || !c_.inLen()) return false;
    return FetchReport(mac_->dev, kIOHIDReportTypeInput, reportId, c_.inLen(), out);
}

// ---- helpers (same behaviour as the Windows and Linux backends) -------------------------------

std::wstring HidProduct(const HidColl& c) { return c.product; }

std::wstring Hex4(USHORT v) {
    wchar_t b[8];
    swprintf(b, 8, L"%04X", v);
    return b;
}

int Clamp100(int v) { return v < 0 ? 0 : (v > 100 ? 100 : v); }

int MapTo100(int v, int lo, int hi) {
    if (hi <= lo) return Clamp100(v);
    return Clamp100((v - lo) * 100 / (hi - lo));
}

int Interpolate(int mv, const int* mvTable, const int* pctTable, int n) {
    if (mv >= mvTable[0]) return pctTable[0];
    for (int i = 1; i < n; i++) {
        if (mv >= mvTable[i]) {
            int span = mvTable[i - 1] - mvTable[i];
            return pctTable[i] + (pctTable[i - 1] - pctTable[i]) * (mv - mvTable[i]) / (span ? span : 1);
        }
    }
    return pctTable[n - 1];
}

static bool Contains(const std::wstring& hay, const wchar_t* needle) {
    return hay.find(needle) != std::wstring::npos;
}

DeviceKind GuessKind(const std::wstring& name) {
    std::wstring n;
    for (wchar_t ch : name) n.push_back((wchar_t)towlower((wint_t)ch));
    if (Contains(n, L"mouse") || Contains(n, L"mice") || Contains(n, L"trackball")) return DeviceKind::Mouse;
    if (Contains(n, L"keyboard") || Contains(n, L"keys")) return DeviceKind::Keyboard;
    if (Contains(n, L"controller") || Contains(n, L"gamepad") || Contains(n, L"xbox") ||
        Contains(n, L"dualsense") || Contains(n, L"dualshock") || Contains(n, L"joy-con"))
        return DeviceKind::Gamepad;
    if (Contains(n, L"head") || Contains(n, L"buds") || Contains(n, L"pods") || Contains(n, L"ear") ||
        Contains(n, L"wh-") || Contains(n, L"wf-") || Contains(n, L"audio") || Contains(n, L"speaker") ||
        Contains(n, L"arctis") || Contains(n, L"cloud") || Contains(n, L"void") || Contains(n, L"virtuoso"))
        return DeviceKind::Headset;
    return DeviceKind::Other;
}

DeviceKind KindFromCollections(const std::vector<HidColl>& all, USHORT vid, USHORT pid) {
    bool mouse = false, pad = false, kbd = false;
    for (const auto& c : all) {
        if (c.vid != vid || c.pid != pid || (c.caps.UsagePage && c.caps.UsagePage != 0x01)) continue;
        if (!c.caps.Usage) continue;
        mouse |= c.caps.Usage == 0x02;
        pad |= c.caps.Usage == 0x04 || c.caps.Usage == 0x05;
        kbd |= c.caps.Usage == 0x06;
    }
    if (mouse) return DeviceKind::Mouse;
    if (pad) return DeviceKind::Gamepad;
    if (kbd) return DeviceKind::Keyboard;
    return DeviceKind::Other;
}

#endif  // __APPLE__
