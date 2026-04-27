import SwiftUI

@MainActor
final class SubtitleContentModel: ObservableObject {
    @Published var text: String
    @Published var settings: AppSettings

    init(text: String, settings: AppSettings) {
        self.text = text
        self.settings = settings
    }

    func update(text: String, settings: AppSettings) {
        self.text = text
        self.settings = settings
    }
}

struct SubtitleView: View {
    @ObservedObject var model: SubtitleContentModel

    var body: some View {
        Text(model.text.isEmpty ? "字幕窗已显示" : model.text)
            .font(.system(size: model.settings.subtitleFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(model.settings.subtitleMaxLines)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.black.opacity(model.settings.subtitleOpacity))
            )
            .shadow(radius: 16)
            .padding()
    }
}
