// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import SwiftUI
import NXLauncher
import S2ArmAppleAdapter

/// The banner is independent of the square cover, including when the player has customized that cover.
struct HomeBackdrop: View {
    let game: GameSummary?
    @ObservedObject var covers: CoverCache
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LauncherPalette.background
                artwork(size: geometry.size)
                    .id(game?.id)
                    .transition(.opacity)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.65), location: 0),
                    .init(color: .black.opacity(0.28), location: 0.38),
                    .init(color: .clear, location: 0.75)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.35),
                    .init(color: .black.opacity(0.28), location: 0.6),
                    .init(color: .black.opacity(0.85), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: game?.id)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func artwork(size: CGSize) -> some View {
        // Try decoding each source independently: an unavailable banner must not hide a valid cover.
        if let image = covers.image(game?.banner) ?? covers.image(game?.cover) {
            CoverFill(image: image).frame(width: size.width, height: size.height)
        } else {
            LinearGradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.3), LauncherPalette.background],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        }
    }
}
