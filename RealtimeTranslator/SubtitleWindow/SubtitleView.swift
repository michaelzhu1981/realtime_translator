import SwiftUI

struct SubtitleView: View {
    let text: String
    let settings: AppSettings

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: settings.subtitleFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(settings.subtitleMaxLines)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.black.opacity(settings.subtitleOpacity))
            )
            .shadow(radius: 16)
            .padding()
    }
}
