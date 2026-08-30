#if os(macOS)
import Foundation

// Host-side tree diagnostics. Deliberately NOT in SimWire.swift — that file is
// byte-synced with the in-simulator driver copy (SimWireSyncTests).

extension UITree {
    /// Element types that carry real semantic content. A tree with none of
    /// these AND no labels anywhere is opaque scaffolding, not a UI.
    private static let contentTypes: Set<String> = [
        "Button", "StaticText", "TextField", "SecureTextField", "TextView",
        "Cell", "Switch", "Slider", "SegmentedControl", "Picker", "PickerWheel",
        "NavigationBar", "TabBar", "SearchField", "Link", "Image", "Table",
        "CollectionView", "Alert", "Toggle",
    ]

    /// Non-nil when the snapshot matches the signature of a Flutter (or other
    /// canvas-rendered) app whose accessibility semantics are NOT enabled:
    /// nothing but unlabeled structural containers. Observed live (Saggel,
    /// 2026-08-30): the agent tap-looped for dozens of turns on
    /// `Application > Other > Other > Other` because no tool explained why the
    /// tree was meaningless. The diagnosis names the cause AND the fix so the
    /// agent repairs the app instead of tapping blindly.
    public var semanticsDiagnosis: String? {
        var nodes: [UINode] = []
        func walk(_ n: UINode) { nodes.append(n); n.children.forEach(walk) }
        walk(root)

        // A lone window/blank screen isn't diagnosable — require some structure.
        guard nodes.count >= 2 else { return nil }

        let hasText = nodes.contains { node in
            [node.label, node.identifier, node.value]
                .contains { !($0 ?? "").isEmpty }
        }
        let hasContentType = nodes.contains { Self.contentTypes.contains($0.type) }
        guard !hasText, !hasContentType else { return nil }

        return """

        ⚠ OPAQUE TREE — this looks like a Flutter (canvas-rendered) app with \
        accessibility semantics DISABLED: every element is an unlabeled container. \
        Do not tap blindly — taps and waits will keep failing. Fix the app instead:
        1. In lib/main.dart, before runApp(): `SemanticsBinding.instance.ensureSemantics();` \
        (import 'package:flutter/rendering.dart'; safe to ship — it only enables the \
        accessibility tree).
        2. Rebuild + relaunch (sim_build_install, sim_launch), then snapshot again — \
        buttons and text will appear with labels.
        3. If specific controls still lack labels, wrap them in Semantics(label:) widgets.
        """
    }
}
#endif
