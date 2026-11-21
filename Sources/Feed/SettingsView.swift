import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: FeedViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var baseUrl = AppSettings.serverBaseUrl

    var body: some View {
        NavigationStack {
            Form {
                Section("媒体服务器") {
                    TextField("http://192.168.2.3:8080", text: $baseUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("保存并重新加载") {
                        AppSettings.serverBaseUrl = baseUrl
                        viewModel.loadFeed()
                        dismiss()
                    }
                    .foregroundStyle(DuloCoral)
                }
            }
            .navigationTitle("Dulo 设置")
        }
        .preferredColorScheme(.dark)
    }
}
