// macOS driver orchestration.
//
// Same order as src/devices.cpp (vendor drivers first, so each claims its own devices), minus the
// drivers that depend on Windows-only APIs: WinRT Bluetooth / BLE, XInput, SetupAPI, Winsock,
// Phone Link, the HeadsetControl helper and the generic Windows HID battery fallback. Kept separate
// from src/devices.cpp so the Windows build is untouched.
//
// Not included on macOS (Windows-only APIs):
//   PollAirPods, PollArmorX, PollAtkSerial, PollBluetooth, PollGalaxyBuds, PollGameSirBle, PollGenericHid, PollHeadsetControl, PollJblSpeaker, PollMarshall, PollNothingEar, PollNuphyHalo96, PollPhoneLink, PollSonyHeadphones, PollSonyInzone, PollSoundcore, PollUnsupported, PollXInput
#include "../devices.h"

#include <cstdio>
#include <cwchar>

#include "../drivers/drivers.h"
#include "../hid.h"

void PollMacBluetooth(PollContext& ctx);  // src/mac/bluetooth_mac.mm

std::vector<DeviceStatus> PollAllDevices() {
    PollContext ctx;
    ctx.colls = EnumHid();
    PollSinowealthReceiver(ctx);
    PollGlorious(ctx);
    PollAula(ctx);       // before Kysona (shares the 3554 vendor id) and SONiX (shares 05AC:024F)
    PollAulaMouse(ctx);
    PollAulaHeadset(ctx);
    PollEweadn(ctx);     // BeiYing mice: EWEADN S7 / S9 on 372E:103D / 1027, RK M3 on 1019 / 102A (AULA keeps 106C)
    PollDareu(ctx);
    PollPiao(ctx);       // IPI PIAO mouse on 372E:1014 receiver (and wired 1015/1028/1056)
    PollZenith(ctx);
    PollDarmoshark(ctx);
    PollDarmosharkNrf(ctx);
    PollAtkMercury(ctx); // before Kysona, which must not send mouse queries to the Mercury receiver
    PollAtkKeyboard(ctx);
    PollRedragonEvision(ctx);
    PollPulsar(ctx);     // before Kysona, which also scans the 3710 vendor id
    PollAtkBitmouse(ctx);  // before Kysona, which would probe the NK dongle with the wrong protocol
    PollChimera(ctx);      // Chimera V2 mouse (3554:F512), before Kysona which shares the 3554 vendor id
    PollKysona(ctx);
    PollKeychron(ctx);
    PollCherry(ctx);
    PollNuphy(ctx);
    PollWobkey(ctx);
    PollCrociris(ctx);
    PollArbiter(ctx);    // before Lamzu, which shares the 373E vendor id
    PollLamzu(ctx);
    PollEndgame(ctx);
    PollEndgameWe(ctx);
    PollVaxee(ctx);
    PollWlmouse(ctx);
    PollFinalmouse(ctx);
    PollScyrox(ctx);
    PollNinjutso(ctx);
    PollSprime(ctx);
    PollRawm(ctx);
    PollAkko(ctx);
    PollRongyuan(ctx);
    PollVgnClient(ctx);  // VGN: after the drivers that already claim VGN ids (320F ATK keyboards, 3554 Kysona/AULA, 3151 Rongyuan)
    PollSonix(ctx);
    PollViaDongle(ctx);
    PollSemico(ctx);
    PollAjazzAk992(ctx);
    PollPlayStationLink(ctx);
    PollFractal(ctx);
    PollJabra(ctx);
    PollJbl(ctx);
    PollRog(ctx);
    PollZowie(ctx);
    PollRoyalKludge(ctx);
    PollMchose(ctx);
    PollMchoseA5(ctx);
    PollRapoo(ctx);
    PollAreson(ctx);
    PollMchoseG3(ctx);
    PollMsi(ctx);
    PollMachenike(ctx);  // before Ajazz in PollMiscMice, which shares the L7's 248A vendor id
    PollNiceboy(ctx);    // exact 248A:FA02 match, also before the Ajazz / Delux pollers
    PollMchoseModern(ctx);
    PollMchoseHeadset(ctx);
    PollMchoseV9Pro(ctx);
    PollVgn(ctx);
    PollMchoseKeyboard(ctx);  // 3837:3033 receiver, before the generic fallbacks
    PollMiscMice(ctx);
    PollFantech(ctx);
    PollRaigor(ctx);
    PollRazerHeadsets(ctx);  // before the generic Razer driver, which shares the vendor id
    PollBarracudaPro(ctx);   // before the generic Razer driver as well
    PollHyperX(ctx);
    PollLogitechG435(ctx);  // before the HID++ driver, which shares the vendor id
    PollAstro(ctx);
    PollLogitech(ctx);
    PollRazer(ctx);
    PollSteelSeriesElite(ctx);
    PollSteelSeries(ctx);
    PollAudeze(ctx);
    PollEndorfy(ctx);
    PollTurtleBeach(ctx);
    PollAkg(ctx);
    PollNzxt(ctx);
    PollPlantronics(ctx);
    PollCorsair(ctx);
    PollCoolerMaster(ctx);
    PollPlayStation(ctx);
    PollSwitchPro(ctx);
    PollSteamController(ctx);
    PollGameSir(ctx);
    PollFlydigi(ctx);
    PollGameSirCyclone(ctx);
    PollGameSirSapjoy(ctx);  // Tarantula Pro / NovaPro: SAPJoy device info on FF A0 (Nova and Cyclone 2 above keep their ids)
    Poll8BitDo(ctx);
    PollBeitong(ctx);  // before the XInput fallback, which only sees the receiver as wired
    PollMoondrop(ctx);
    PollDarkrim(ctx);
    PollAlienware(ctx);
    PollMaono(ctx);  // MAONO PD200W receiver (352F:040E), experimental battery query
    PollPressPlayIcarus(ctx);
    PollMacBluetooth(ctx);  // levels macOS knows (Magic devices, AirPods, headsets); skips devices listed above
    return ctx.out;
}

std::wstring DumpHidCollections() {
    std::wstring out = L"VID:PID    IF  UsagePg:Usage  In  Out Feat  Product\n";
    for (const auto& c : EnumHid()) {
        wchar_t line[160];
        swprintf(line, 160, L"%04X:%04X  %2d  %04X:%04X    %3u %3u %3u   ", c.vid, c.pid, c.iface, c.page(), c.usage(),
                 c.inLen(), c.outLen(), c.featLen());
        out += line + HidProduct(c) + L"\n";
    }
    return out;
}

void ShutdownDevices() {}
