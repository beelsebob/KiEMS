import Foundation

/// Expands a Simulation Set into one entry per primary matching net. Secondary patterns are
/// substituted using captures from that primary match; all matched nets are included and every pin
/// on a probe component that reaches one is probed.
enum SimulationSetExpansion {
    struct Probe {
        let probe: EMSSimulationSetProbeBridge
        let pins: [KicadFootprintPin]
    }

    struct Entry {
        let netName: String
        let sourcePin: KicadFootprintPin?
        let matchingNetNames: Set<String>
        let probes: [Probe]
    }

    static func regex(for pattern: String) -> Result<NSRegularExpression, Error> {
        Result { try NSRegularExpression(pattern: "^(?:\(pattern))$") }
    }

    static func entries(for set: EMSSimulationSetBridge, footprints: [KicadFootprintInfo]) -> [Entry] {
        let allNetNames = Set(footprints.flatMap(\.pins).map(\.netName).filter { !$0.isEmpty })
        let sourcePins = footprints.first { $0.reference == set.excitationFootprintReference }?.pins ?? []
        let primaryMatches: [(netName: String, match: NSTextCheckingResult?)]
        let primary: NSRegularExpression?
        switch set.netSelectionMode {
        case .list:
            primary = nil
            primaryMatches = Array(Set(set.netNames))
                .filter { allNetNames.contains($0) }
                .map { ($0, nil) }
        default:
            guard !set.netNamePattern.isEmpty, case let .success(expression) = regex(for: set.netNamePattern) else {
                return []
            }
            primary = expression
            primaryMatches = allNetNames.compactMap { netName in
                let range = NSRange(netName.startIndex..., in: netName)
                guard let match = expression.firstMatch(in: netName, range: range) else { return nil }
                return (netName, match)
            }
        }
        return primaryMatches.map { netName, match in
            var matching = Set([netName])
            for template in set.additionalNetPatterns {
                guard let primary, let match else { continue }
                let expanded = primary.replacementString(for: match, in: netName, offset: 0, template: template)
                guard case let .success(secondary) = regex(for: expanded) else { continue }
                matching.formUnion(allNetNames.filter { candidate in
                    secondary.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
                })
            }
            let probes = set.probes.map { probe in
                let pins = footprints.first { $0.reference == probe.footprintReference }?.pins ?? []
                return Probe(probe: probe, pins: pins.filter { !$0.netName.isEmpty && matching.contains($0.netName) })
            }
            return Entry(netName: netName, sourcePin: sourcePins.first { $0.netName == netName },
                         matchingNetNames: matching, probes: probes)
        }.sorted { $0.netName.localizedStandardCompare($1.netName) == .orderedAscending }
    }

    static func simulationNames(for entries: [Entry], setName: String) -> [String] {
        entries.map { "\(setName) \($0.netName)" }
    }
}
