import SwiftUI

/// Portrait, zero-UI vertical video feed. Port of the Android `FeedScreen`.
struct FeedScreen: View {
    @ObservedObject var viewModel: FeedViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: FeedStreamStore?
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let store {
                #if canImport(UIKit)
                VerticalPager(store: store, viewModel: viewModel)
                    .ignoresSafeArea()
                #endif
            }
            if viewModel.videos.isEmpty {
                statusOverlay
            }
            exitHotspot
            settingsButton
        }
        .task(id: viewModel.videos.isEmpty) {
            if store == nil && !viewModel.videos.isEmpty {
                store = FeedStreamStore(videos: viewModel.videos)
            }
        }
        .onChange(of: scenePhase) { phase in
            store?.sceneActive = (phase == .active)
        }
        .onChange(of: store?.keepAwake) { awake in
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = awake ?? false
            #endif
        }
        .onDisappear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
    }

    /// Empty/error state, mirroring the Android feed's retry surface.
    private var statusOverlay: some View {
        VStack(spacing: 16) {
            if viewModel.isLoading {
                ProgressView().tint(.white)
            } else {
                Text(viewModel.error ?? "未检测到局域网视频")
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    viewModel.loadFeed()
                } label: {
                    Text("重试")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(DuloCoral)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    /// Top-left 80pt hotspot: double-tap exits the app entirely, matching
    /// the Android `finishAndRemoveTask` behaviour.
    private var exitHotspot: some View {
        Color.clear
            .frame(width: 80, height: 80)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                #if canImport(UIKit)
                exit(0)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
