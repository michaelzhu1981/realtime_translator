import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    private let inputLanguageOptions = [
        LanguageOption(label: "Auto Detect", value: "auto"),
        LanguageOption(label: "English", value: "en"),
        LanguageOption(label: "Chinese", value: "zh"),
        LanguageOption(label: "Cantonese", value: "yue"),
        LanguageOption(label: "Japanese", value: "ja"),
        LanguageOption(label: "Korean", value: "ko"),
        LanguageOption(label: "French", value: "fr"),
        LanguageOption(label: "German", value: "de"),
        LanguageOption(label: "Spanish", value: "es"),
        LanguageOption(label: "Portuguese", value: "pt"),
        LanguageOption(label: "Russian", value: "ru")
    ]

    private let targetLanguageOptions = [
        LanguageOption(label: "Simplified Chinese", value: "Simplified Chinese"),
        LanguageOption(label: "Traditional Chinese", value: "Traditional Chinese"),
        LanguageOption(label: "English", value: "English"),
        LanguageOption(label: "Japanese", value: "Japanese"),
        LanguageOption(label: "Korean", value: "Korean"),
        LanguageOption(label: "French", value: "French"),
        LanguageOption(label: "German", value: "German"),
        LanguageOption(label: "Spanish", value: "Spanish")
    ]

    var body: some View {
        Form {
            Section("LM Studio") {
                TextField("Base URL", text: $appState.settings.lmStudioBaseURL)
                TextField("Model", text: $appState.settings.lmStudioModel)
            }

            Section("ASR") {
                TextField("Python", text: $appState.settings.asrPythonPath)
                TextField("Model", text: $appState.settings.asrModel)
                TextField("Model Cache", text: $appState.settings.asrModelCachePath)
                HStack {
                    Text("Input Language")
                    Spacer()
                    Picker("Input Language", selection: $appState.settings.inputLanguage) {
                        ForEach(options(inputLanguageOptions, including: appState.settings.inputLanguage)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
                HStack {
                    Text("Service Port")
                    TextField("Port", value: $appState.settings.asrPort, format: .number)
                        .frame(width: 90)
                }
            }

            Section("Translation") {
                HStack {
                    Text("Target Language")
                    Spacer()
                    Picker("Target Language", selection: $appState.settings.targetLanguage) {
                        ForEach(options(targetLanguageOptions, including: appState.settings.targetLanguage)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
                HStack {
                    Text("Timeout")
                    TextField("Seconds", value: $appState.settings.translationTimeoutSeconds, format: .number)
                        .frame(width: 90)
                    Text("s")
                }
            }

            Section("Audio") {
                HStack {
                    Text("Chunk")
                    TextField("Seconds", value: $appState.settings.chunkDurationSeconds, format: .number)
                        .frame(width: 90)
                    Text("s")
                }
                HStack {
                    Text("Context")
                    TextField("Seconds", value: $appState.settings.contextWindowSeconds, format: .number)
                        .frame(width: 90)
                    Text("s")
                }
            }

            Section("Subtitle") {
                Slider(value: $appState.settings.subtitleFontSize, in: 18...64) {
                    Text("Font Size")
                }
                Slider(value: $appState.settings.subtitleOpacity, in: 0.2...1.0) {
                    Text("Opacity")
                }
                Stepper("Max Lines: \(appState.settings.subtitleMaxLines)", value: $appState.settings.subtitleMaxLines, in: 1...4)
                Toggle("Mouse Passthrough", isOn: $appState.settings.subtitleMousePassthrough)
            }

            Button("Save Settings") {
                appState.saveSettings()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 520)
    }

    private func options(_ options: [LanguageOption], including currentValue: String) -> [LanguageOption] {
        guard !currentValue.isEmpty, !options.contains(where: { $0.value == currentValue }) else {
            return options
        }

        return [LanguageOption(label: "Custom: \(currentValue)", value: currentValue)] + options
    }
}

private struct LanguageOption: Identifiable {
    let label: String
    let value: String

    var id: String { value }
}
