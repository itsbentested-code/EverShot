import SwiftUI

/// Draws semi-transparent crop guide overlays showing the 9:16 and 16:9
/// frame boundaries so the user can see what each output will look like.
struct CropGuideOverlay: View {
    let showPortraitGuide: Bool
    let showLandscapeGuide: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if showPortraitGuide {
                    portraitGuide(in: geo.size)
                }

                if showLandscapeGuide {
                    landscapeGuide(in: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Portrait Guide (9:16)

    /// In a portrait-oriented preview, the 9:16 frame is essentially the full
    /// screen width with slight top/bottom padding if the preview is taller than 16:9.
    private func portraitGuide(in size: CGSize) -> some View {
        let targetAspect: CGFloat = 9.0 / 16.0
        let previewAspect = size.width / size.height

        // Calculate the visible 9:16 region within the preview
        let guideWidth: CGFloat
        let guideHeight: CGFloat

        if previewAspect > targetAspect {
            // Preview is wider — portrait crop uses full height, narrower width
            guideHeight = size.height
            guideWidth = guideHeight * targetAspect
        } else {
            // Preview is taller — portrait crop uses full width, shorter height
            guideWidth = size.width
            guideHeight = guideWidth / targetAspect
        }

        return RoundedRectangle(cornerRadius: 4)
            .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
            .frame(width: guideWidth, height: guideHeight)
            .overlay(
                VStack {
                    HStack {
                        Text("9:16")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(6)
                        Spacer()
                    }
                    Spacer()
                }
                .frame(width: guideWidth, height: guideHeight)
            )
    }

    // MARK: - Landscape Guide (16:9)

    /// The 16:9 landscape region centered in the preview.
    private func landscapeGuide(in size: CGSize) -> some View {
        let targetAspect: CGFloat = 16.0 / 9.0
        let previewAspect = size.width / size.height

        let guideWidth: CGFloat
        let guideHeight: CGFloat

        if previewAspect > targetAspect {
            // Preview is wider — use full height
            guideHeight = size.height
            guideWidth = guideHeight * targetAspect
        } else {
            // Preview is taller — use full width
            guideWidth = size.width
            guideHeight = guideWidth / targetAspect
        }

        return RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow.opacity(0.6), lineWidth: 1.5)
            .frame(width: guideWidth, height: guideHeight)
            .overlay(
                VStack {
                    HStack {
                        Spacer()
                        Text("16:9")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.yellow.opacity(0.7))
                            .padding(6)
                    }
                    Spacer()
                }
                .frame(width: guideWidth, height: guideHeight)
            )
    }
}
