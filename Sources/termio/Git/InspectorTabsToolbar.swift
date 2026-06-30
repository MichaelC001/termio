import SwiftUI

// MARK: - Tab switch

/// The inspector's pane switch flipping between Files and Changes. It sits at the *left*
/// edge of the inspector in the toolbar — pinned there by an inspector tracking separator
/// (see `MainToolbarDelegate`) — while the collapse button sits at the far right.
///
/// A native `Picker(.segmented)` renders borderless in this dark-toolbar `NSHostingView`
/// (macOS 26 drops the enclosing track and only the selected segment keeps a pill), which
/// reads as two unrelated floating icons. So we draw the switch by hand as a Liquid Glass
/// segmented control: a glass track holding both segments, with the selected segment lifted
/// on its own pill that fluidly morphs across as you switch panes.
///
/// The track is tinted lighter (whiter) so it never sits darker than the borderless system
/// collapse button at the inspector's other edge. Both glyphs keep the same neutral
/// `.secondary` tone — matching the neighbouring toolbar buttons — and selection is shown
/// purely by the brighter, raised pill, never by recolouring or tinting a glyph.
struct InspectorTabsToolbar: View {
    @EnvironmentObject var store: TermioStore
    @Namespace private var glassNamespace

    private let segments: [(tab: InspectorTab, icon: String, help: String)] = [
        (.files, "list.bullet.indent", "Project Files"),
        (.changes, "arrow.triangle.branch", "Changes"),
    ]

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                glassControl
            } else {
                legacyControl
            }
        }
        // Bound the hosting view to a fixed, standard toolbar height — an unconstrained
        // control can report a tall intrinsic height that grows the unified toolbar (and,
        // with `.fullSizeContentView`, nudges the window frame) when the item is inserted.
        .frame(height: 28)
        .fixedSize()
    }

    // MARK: Liquid Glass (macOS 26+)

    @available(macOS 26.0, *)
    private var glassControl: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(segments, id: \.tab) { seg in
                    let selected = store.inspectorTab == seg.tab
                    icon(seg)
                        .background {
                            // The lifted selected pill — the standard look: bright, raised
                            // clear glass (brighter than the track), never a dark fill. A
                            // shared `glassEffectID` makes it flow to the new segment on switch.
                            if selected {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                    .glassEffectID("selection", in: glassNamespace)
                            }
                        }
                        .contentShape(.capsule)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.3)) { store.inspectorTab = seg.tab }
                        }
                        .help(seg.help)
                }
            }
            .padding(3)
            // The shared track: a faint, slightly-whitened glass so it stays lighter than the
            // system collapse button and lets the brighter selected pill read as raised.
            .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: .capsule)
        }
    }

    // MARK: Fallback (macOS < 26)

    private var legacyControl: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.tab) { seg in
                let selected = store.inspectorTab == seg.tab
                Button { store.inspectorTab = seg.tab } label: {
                    icon(seg)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? Color(nsColor: .controlColor) : .clear)
                                .shadow(color: selected ? .black.opacity(0.18) : .clear, radius: 0.5, y: 0.5)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(seg.help)
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    /// The bare glyph. Both segments use the same neutral `.secondary` tone — selection is
    /// shown only by the bright glass pill behind the active segment, never by recolouring the
    /// glyph — so the switch reads as one calm pair that matches the neighbouring toolbar buttons.
    private func icon(_ seg: (tab: InspectorTab, icon: String, help: String)) -> some View {
        Image(systemName: seg.icon)
            // The branch glyph is intrinsically thin and narrow, so it reads smaller than the
            // neighbouring system toolbar buttons; a slightly larger, medium-weight size gives
            // it (and Files) comparable visual mass.
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 24)
    }
}
