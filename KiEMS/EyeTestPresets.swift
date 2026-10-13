import Foundation

/// The eye-mask presets offered by the Tests section (EyeTestSectionView), grouped by family into
/// its submenus. Each holds the numbers a simulation's eye test takes when that standard is picked;
/// the simulation keeps the numbers themselves (see kiems::EyeTestConfig), and
/// EMSSimulationBridge.eyeMaskStandard only records which preset they came from.
///
/// Masks sit on the eye's decision threshold, spanning the unit interval between the nominal
/// transitions at 0 and 1 UI: a keep-out hexagon through (x1, 0), (x2, ±y1), (1 - x2, ±y1),
/// (1 - x1, 0), and an outer limit of ±y2 (0 for none). A specification's eye height and width
/// become y1 = height / 2 and x1 = (1 - width) / 2. `signalLevel` is the ± level the PRBS is
/// launched at -- differential for a pair -- assuming a driver matched to the line, so a mask in
/// absolute volts lands on a correctly scaled eye.
///
/// Where a standard defines a receiver or compliance eye, the preset is that eye. Where it doesn't
/// (or the figures aren't public) the preset is built from what it does define -- input thresholds,
/// a jitter budget, a related standard's eye -- and is marked as an approximation to check against
/// the specification. Only NRZ signalling can be tested: the eye is a two-level PRBS, so multi-level
/// standards (PCI Express 6's PAM-4, Thunderbolt 5's PAM-3, BASE-T Ethernet's PAM-5/PAM-16) aren't
/// offered.
struct EyeTestPreset {
    let standard: EMSEyeMaskStandard
    /// The submenu the preset is listed in.
    let family: String
    /// Its item in that submenu.
    let menuTitle: String
    /// Its name on its own -- the popup's title, and in results.
    let title: String
    /// Nil for a standard spanning many speed grades (DDR), which leaves the bit rate alone.
    let bitRate: Double?
    let signalLevel: Double
    let x1: Double
    let x2: Double
    let y1: Double
    let y2: Double
    /// Begins a new group within its family's submenu, after a separator.
    var startsGroup = false

    static let families = ["USB", "DRAM", "PCI Express", "FireWire", "Thunderbolt", "HDMI", "DisplayPort", "Ethernet"]

    static let all: [EyeTestPreset] = [
        // MARK: USB

        // USB 2.0 §7.1.2.2, Template 1 (transmit eye at TP2/TP3): 0 V at 7.5% and 92.5% UI, ±300 mV
        // from 37.5% to 62.5% UI, levels within ±525 mV (the limit for the UI after a transition;
        // 475 mV elsewhere). 400 mV differential nominal drive.
        EyeTestPreset(standard: .usbHighSpeed, family: "USB", menuTitle: "High Speed (480 Mb/s)",
                      title: "USB High Speed", bitRate: 480e6, signalLevel: 0.4,
                      x1: 0.075, x2: 0.375, y1: 0.3, y2: 0.525),
        // Approximation -- no eye template: the differential receiver needs 200 mV and tolerates
        // crossings 18.5 ns (0.22 UI) from nominal. 3.3 V differential swing, launched at half by the
        // matched driver and doubled again by the unterminated receiver.
        EyeTestPreset(standard: .usbFullSpeed, family: "USB", menuTitle: "Full Speed (12 Mb/s)",
                      title: "USB Full Speed", bitRate: 12e6, signalLevel: 1.65,
                      x1: 0.22, x2: 0.22, y1: 0.2, y2: 0),
        // USB 3.2 Gen 1 normative transmitter eye at TP1: 100 mV eye height, 0.66 UI total jitter
        // (0.34 UI wide), 1200 mV p-p maximum swing. The specification measures after its reference
        // CTLE, which this eye doesn't apply, so the preset is conservative for lossy channels.
        EyeTestPreset(standard: .usb5Gbps, family: "USB", menuTitle: "5 Gb/s",
                      title: "USB 5 Gb/s", bitRate: 5e9, signalLevel: 0.5,
                      x1: 0.33, x2: 0.5, y1: 0.05, y2: 0.6),
        // USB 3.2 Gen 2 normative transmitter eye at TP1: 70 mV, 0.714 UI total jitter (0.286 UI wide).
        EyeTestPreset(standard: .usb10Gbps, family: "USB", menuTitle: "10 Gb/s",
                      title: "USB 10 Gb/s", bitRate: 10e9, signalLevel: 0.5,
                      x1: 0.357, x2: 0.5, y1: 0.035, y2: 0.6),
        // USB 3.2 Gen 2x2: two lanes of Gen 2 signalling, so the per-lane rate and eye are Gen 2's.
        EyeTestPreset(standard: .usb20Gbps, family: "USB", menuTitle: "20 Gb/s",
                      title: "USB 20 Gb/s", bitRate: 10e9, signalLevel: 0.5,
                      x1: 0.357, x2: 0.5, y1: 0.035, y2: 0.6),

        // MARK: DRAM

        // Data (DQ) receivers. Approximation: SSTL_2's VIH/VIL(ac) = VREF ± 310 mV, held over a
        // 0.3 UI window. ±VDDQ/4 from a matched driver.
        EyeTestPreset(standard: .DDR, family: "DRAM", menuTitle: "DDR", title: "DDR",
                      bitRate: nil, signalLevel: 0.625, x1: 0.35, x2: 0.35, y1: 0.31, y2: 0),
        // Approximation: SSTL_18's VIH/VIL(ac) = VREF ± 200 mV (DDR2-667/800).
        EyeTestPreset(standard: .DDR2, family: "DRAM", menuTitle: "DDR2", title: "DDR2",
                      bitRate: nil, signalLevel: 0.45, x1: 0.35, x2: 0.35, y1: 0.2, y2: 0),
        // Approximation: SSTL_15's VIH/VIL(ac) = VREF ± 150 mV (DDR3-1333/1600 AC150).
        EyeTestPreset(standard: .DDR3, family: "DRAM", menuTitle: "DDR3 Data", title: "DDR3 Data",
                      bitRate: nil, signalLevel: 0.375, x1: 0.35, x2: 0.35, y1: 0.15, y2: 0),
        // DDR4 DQ Rx mask: VdIVW 136 mV by TdIVW 0.2 UI, a rectangle on VREF. POD12 into ODT.
        EyeTestPreset(standard: .DDR4, family: "DRAM", menuTitle: "DDR4 Data", title: "DDR4 Data",
                      bitRate: nil, signalLevel: 0.3, x1: 0.4, x2: 0.4, y1: 0.068, y2: 0),
        // Approximation: DDR5 specifies its DQ receiver after the DRAM's own DFE, inside the device,
        // so there's no pin-level mask; this borrows DDR5's command/address mask (130 mV by 0.2 UI).
        EyeTestPreset(standard: .DDR5, family: "DRAM", menuTitle: "DDR5 Data", title: "DDR5 Data",
                      bitRate: nil, signalLevel: 0.275, x1: 0.4, x2: 0.4, y1: 0.065, y2: 0),

        // Command/address receivers, which run at the clock rate -- half the data rate -- into VTT
        // termination, and are judged against their own thresholds rather than DQ's. Approximation
        // for DDR3/DDR4: the AC thresholds held over a 0.3 UI window (setup/hold are specified
        // against the clock, not as a window).
        // DDR3: VIH/VIL.CA(ac) = VREF ± 175 mV (AC175, every speed grade).
        EyeTestPreset(standard: .ddr3CommandAddress, family: "DRAM", menuTitle: "DDR3 Address/Command",
                      title: "DDR3 Address/Command", bitRate: nil, signalLevel: 0.375,
                      x1: 0.35, x2: 0.35, y1: 0.175, y2: 0, startsGroup: true),
        // DDR4: VIH/VIL.CA(ac) = VREF ± 100 mV (AC100, DDR4-1600 to 2400; AC90 above). SSTL12 into
        // VTT, so ±VDD/4.
        EyeTestPreset(standard: .ddr4CommandAddress, family: "DRAM", menuTitle: "DDR4 Address/Command",
                      title: "DDR4 Address/Command", bitRate: nil, signalLevel: 0.3,
                      x1: 0.35, x2: 0.35, y1: 0.1, y2: 0),
        // DDR5-4800 CA Rx mask: VcIVW 130 mV by TcIVW 0.2 UI, a rectangle on Vcent_CA.
        EyeTestPreset(standard: .ddr5CommandAddress, family: "DRAM", menuTitle: "DDR5 Address/Command",
                      title: "DDR5 Address/Command", bitRate: nil, signalLevel: 0.275,
                      x1: 0.4, x2: 0.4, y1: 0.065, y2: 0),

        // LPDDR4 DQ Rx mask: VdIVW_total 140 mV by TdIVW_total 0.22 UI (to 3200 Mb/s). LVSTL drives
        // into ODT to VSSQ, swinging about half of VDDQ's 1.1 V.
        EyeTestPreset(standard: .LPDDR4, family: "DRAM", menuTitle: "LPDDR4", title: "LPDDR4",
                      bitRate: nil, signalLevel: 0.275, x1: 0.39, x2: 0.39, y1: 0.07, y2: 0, startsGroup: true),
        // LPDDR4X: the same 140 mV mask, 0.25 UI wide at 4266 Mb/s, from a 0.6 V VDDQ.
        EyeTestPreset(standard: .LPDDR4X, family: "DRAM", menuTitle: "LPDDR4X", title: "LPDDR4X",
                      bitRate: nil, signalLevel: 0.15, x1: 0.375, x2: 0.375, y1: 0.07, y2: 0),
        // LPDDR5 DQ Rx mask: vDIVW 70 mV, 0.35 UI wide at VREF (tDIVW1) and 0.18 UI at ±vDIVW/2
        // (tDIVW2), the same with or without the DRAM's DFE. 0.5 V VDDQ.
        EyeTestPreset(standard: .LPDDR5, family: "DRAM", menuTitle: "LPDDR5", title: "LPDDR5",
                      bitRate: nil, signalLevel: 0.15, x1: 0.325, x2: 0.41, y1: 0.035, y2: 0),

        // MARK: PCI Express

        // Receiver eyes. Gen 1 and 2 at the receiver's pins: 175 mV and 120 mV high, 0.4 UI wide,
        // at most 1200 mV p-p. Gen 3 onwards specify the eye after the reference receiver's CTLE and
        // DFE, which this eye doesn't apply -- on any real channel those presets will fail where the
        // link would work, so read them as "passes even unequalized". 800-1200 mV p-p drive.
        EyeTestPreset(standard: .pciExpress1, family: "PCI Express", menuTitle: "Gen 1 (2.5 GT/s)",
                      title: "PCI Express Gen 1", bitRate: 2.5e9, signalLevel: 0.5,
                      x1: 0.3, x2: 0.5, y1: 0.0875, y2: 0.6),
        EyeTestPreset(standard: .pciExpress2, family: "PCI Express", menuTitle: "Gen 2 (5 GT/s)",
                      title: "PCI Express Gen 2", bitRate: 5e9, signalLevel: 0.5,
                      x1: 0.3, x2: 0.5, y1: 0.06, y2: 0.6),
        // Gen 3: 25 mV by 0.3 UI after equalization.
        EyeTestPreset(standard: .pciExpress3, family: "PCI Express", menuTitle: "Gen 3 (8 GT/s)",
                      title: "PCI Express Gen 3", bitRate: 8e9, signalLevel: 0.5,
                      x1: 0.35, x2: 0.5, y1: 0.0125, y2: 0),
        // Gen 4 and 5: 15 mV by 0.3 UI after equalization.
        EyeTestPreset(standard: .pciExpress4, family: "PCI Express", menuTitle: "Gen 4 (16 GT/s)",
                      title: "PCI Express Gen 4", bitRate: 16e9, signalLevel: 0.5,
                      x1: 0.35, x2: 0.5, y1: 0.0075, y2: 0),
        EyeTestPreset(standard: .pciExpress5, family: "PCI Express", menuTitle: "Gen 5 (32 GT/s)",
                      title: "PCI Express Gen 5", bitRate: 32e9, signalLevel: 0.5,
                      x1: 0.35, x2: 0.5, y1: 0.0075, y2: 0),

        // MARK: FireWire

        // Approximation: IEEE 1394a drives 172-265 mV differential and detects S400 data down to
        // 118 mV; the 0.4 UI window is assumed.
        EyeTestPreset(standard: .fireWireS400, family: "FireWire", menuTitle: "S400 (IEEE 1394a)",
                      title: "FireWire S400", bitRate: 393.216e6, signalLevel: 0.22,
                      x1: 0.3, x2: 0.3, y1: 0.118, y2: 0),
        // Approximation: IEEE 1394b requires the eye at the receiver's connector (TP3) to be wider
        // than 0.3 UI; the 100 mV height is assumed. Transmitters drive at least 350 mV.
        EyeTestPreset(standard: .fireWireS800, family: "FireWire", menuTitle: "S800 (IEEE 1394b)",
                      title: "FireWire S800", bitRate: 983.04e6, signalLevel: 0.25,
                      x1: 0.35, x2: 0.5, y1: 0.05, y2: 0),
        // Approximation, as S800; transmitters drive at least 475 mV.
        EyeTestPreset(standard: .fireWireS1600, family: "FireWire", menuTitle: "S1600 (IEEE 1394b)",
                      title: "FireWire S1600", bitRate: 1966.08e6, signalLevel: 0.3,
                      x1: 0.35, x2: 0.5, y1: 0.05, y2: 0),

        // MARK: Thunderbolt

        // Approximation: Thunderbolt 1 and 2 run 10.3125 Gb/s lanes (2 bonds two of them); their
        // electrical specification isn't public, so this is USB 3.2 Gen 2's 10 Gb/s eye.
        EyeTestPreset(standard: .thunderbolt1, family: "Thunderbolt", menuTitle: "Thunderbolt 1 (10.3125 Gb/s)",
                      title: "Thunderbolt 1", bitRate: 10.3125e9, signalLevel: 0.5,
                      x1: 0.357, x2: 0.5, y1: 0.035, y2: 0),
        EyeTestPreset(standard: .thunderbolt2, family: "Thunderbolt", menuTitle: "Thunderbolt 2 (10.3125 Gb/s)",
                      title: "Thunderbolt 2", bitRate: 10.3125e9, signalLevel: 0.5,
                      x1: 0.357, x2: 0.5, y1: 0.035, y2: 0),
        // USB4 Gen 3 receiver eye at TP3: 49 mV after the reference equalizer (which this eye doesn't
        // apply, so it's conservative). Approximation: the 0.3 UI width is assumed.
        EyeTestPreset(standard: .thunderbolt3, family: "Thunderbolt", menuTitle: "Thunderbolt 3 (20.625 Gb/s)",
                      title: "Thunderbolt 3", bitRate: 20.625e9, signalLevel: 0.5,
                      x1: 0.35, x2: 0.5, y1: 0.0245, y2: 0),
        // Thunderbolt 4 is USB4 Gen 3, at 20 Gb/s lanes.
        EyeTestPreset(standard: .thunderbolt4, family: "Thunderbolt", menuTitle: "Thunderbolt 4 (20 Gb/s)",
                      title: "Thunderbolt 4", bitRate: 20e9, signalLevel: 0.5,
                      x1: 0.35, x2: 0.5, y1: 0.0245, y2: 0),

        // MARK: HDMI

        // TMDS sink eye at TP2: 150 mV high, 0.6 UI wide; height held over the central quarter UI as
        // DisplayPort's is. 400-600 mV swing.
        EyeTestPreset(standard: .HDMI10, family: "HDMI", menuTitle: "HDMI 1.0–1.2 (1.65 Gb/s)",
                      title: "HDMI 1.0–1.2", bitRate: 1.65e9, signalLevel: 0.5,
                      x1: 0.2, x2: 0.375, y1: 0.075, y2: 0),
        EyeTestPreset(standard: .HDMI14, family: "HDMI", menuTitle: "HDMI 1.3–1.4 (3.4 Gb/s)",
                      title: "HDMI 1.3–1.4", bitRate: 3.4e9, signalLevel: 0.5,
                      x1: 0.2, x2: 0.375, y1: 0.075, y2: 0),
        // HDMI 2.0 at 6 Gb/s, TP2_EQ: 150 mV, 0.4 UI after the reference equalizer -- conservative here.
        EyeTestPreset(standard: .HDMI20, family: "HDMI", menuTitle: "HDMI 2.0 (6 Gb/s)",
                      title: "HDMI 2.0", bitRate: 6e9, signalLevel: 0.5,
                      x1: 0.3, x2: 0.375, y1: 0.075, y2: 0),

        // MARK: DisplayPort

        // Receiver eyes at TP3 (RBR, HBR) and TP3_EQ (HBR2, HBR3 -- after the reference equalizer,
        // so conservative here): width at 0 mV, height anywhere in 0.375-0.625 UI. Swing level 1
        // (600 mV p-p).
        EyeTestPreset(standard: .displayPortRBR, family: "DisplayPort", menuTitle: "RBR (1.62 Gb/s)",
                      title: "DisplayPort RBR", bitRate: 1.62e9, signalLevel: 0.3,
                      x1: 0.375, x2: 0.375, y1: 0.023, y2: 0),
        EyeTestPreset(standard: .displayPortHBR, family: "DisplayPort", menuTitle: "HBR (2.7 Gb/s)",
                      title: "DisplayPort HBR", bitRate: 2.7e9, signalLevel: 0.3,
                      x1: 0.2455, x2: 0.375, y1: 0.075, y2: 0),
        EyeTestPreset(standard: .displayPortHBR2, family: "DisplayPort", menuTitle: "HBR2 (5.4 Gb/s)",
                      title: "DisplayPort HBR2", bitRate: 5.4e9, signalLevel: 0.3,
                      x1: 0.31, x2: 0.375, y1: 0.035, y2: 0),
        EyeTestPreset(standard: .displayPortHBR3, family: "DisplayPort", menuTitle: "HBR3 (8.1 Gb/s)",
                      title: "DisplayPort HBR3", bitRate: 8.1e9, signalLevel: 0.3,
                      x1: 0.325, x2: 0.375, y1: 0.0375, y2: 0),

        // MARK: Ethernet

        // Cisco SGMII receiver mask: X1 0.3 UI, Y1 50 mV, Y2 450 mV. 1000BASE-X SERDES alike.
        EyeTestPreset(standard: .ethernetSGMII, family: "Ethernet", menuTitle: "SGMII / 1000BASE-X (1.25 Gb/s)",
                      title: "Ethernet SGMII", bitRate: 1.25e9, signalLevel: 0.35,
                      x1: 0.3, x2: 0.5, y1: 0.05, y2: 0.45),
        // IEEE 802.3 clause 47 XAUI far-end template: X1 0.275 UI, X2 0.5 UI, A1 100 mV, A2 800 mV.
        EyeTestPreset(standard: .ethernetXAUI, family: "Ethernet", menuTitle: "XAUI (3.125 Gb/s)",
                      title: "Ethernet XAUI", bitRate: 3.125e9, signalLevel: 0.5,
                      x1: 0.275, x2: 0.5, y1: 0.1, y2: 0.8),
        // SFF-8431 host transmitter output at the SFP+ connector (B): X1 0.12, X2 0.33 UI, Y1 95 mV,
        // Y2 350 mV -- the end of the host board's own channel.
        EyeTestPreset(standard: .ethernetSFI, family: "Ethernet", menuTitle: "SFI / SFP+ (10.3125 Gb/s)",
                      title: "Ethernet SFI", bitRate: 10.3125e9, signalLevel: 0.3,
                      x1: 0.12, x2: 0.33, y1: 0.095, y2: 0.35),
    ]

    static func preset(for standard: EMSEyeMaskStandard) -> EyeTestPreset? {
        all.first { $0.standard == standard }
    }

    /// "Custom" or the preset's title.
    static func title(for standard: EMSEyeMaskStandard) -> String {
        preset(for: standard)?.title ?? "Custom"
    }

    func apply(to simulation: EMSSimulationBridge) {
        simulation.eyeMaskStandard = standard
        if let bitRate { simulation.eyeBitRate = bitRate }
        simulation.eyeSignalLevel = signalLevel
        simulation.eyeMaskX1 = x1
        simulation.eyeMaskX2 = x2
        simulation.eyeMaskY1 = y1
        simulation.eyeMaskY2 = y2
    }

    /// Whether `simulation`'s eye settings are still exactly this preset's.
    func matches(_ simulation: EMSSimulationBridge) -> Bool {
        let same = { (a: Double, b: Double) in abs(a - b) <= 1e-9 * max(abs(a), abs(b), 1e-3) }
        return (bitRate.map { same($0, simulation.eyeBitRate) } ?? true)
            && same(signalLevel, simulation.eyeSignalLevel)
            && same(x1, simulation.eyeMaskX1) && same(x2, simulation.eyeMaskX2)
            && same(y1, simulation.eyeMaskY1) && same(y2, simulation.eyeMaskY2)
    }
}
