import SwiftUI

#if canImport(UIKit)
import UIKit
import Darwin
#endif

/// Portrait, zero-UI vertical video feed. Port of the Android `FeedScreen`.
@MainActor
struct FeedScreen: View {
    @ObservedObject var viewModel: FeedViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: FeedStreamStore?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let store {
                #if canImport(UIKit)
                VerticalPager(store: store, viewModel: viewModel)
                    .ignoresSafeArea()
                #endif
            }
            if viewModel.videos.isEmpty && !viewModel.isLoading {
                statusOverlay
            }
            exitHotspot
        }
        .task(id: viewModel.videos.isEmpty) {
            if store == nil && !viewModel.videos.isEmpty {
                store = FeedStreamStore(videos: viewModel.videos)
            }
        }
        .onChange(of: scenePhase) { phase in
            store?.sceneActive = (phase == .active)
            updateIdleTimer(phase: phase)
        }
        .onChange(of: viewModel.videos.isEmpty) { _ in
            updateIdleTimer(phase: scenePhase)
        }
        .onAppear {
            updateIdleTimer(phase: scenePhase)
        }
        .onDisappear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
    }

    /// Manages the display idle timer for immersive full-screen browsing (Douyin/TikTok style).
    /// Keeps display awake while actively viewing feed content in foreground; immediately
    /// releases idle timer assertion upon backgrounding or leaving feed.
    private func updateIdleTimer(phase: ScenePhase) {
        #if canImport(UIKit)
        let shouldKeepAwake = (phase == .active) && !viewModel.videos.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != shouldKeepAwake {
            UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
        }
        #endif
    }

    /// Empty/error state, mirroring the Android feed's retry surface.
    private var statusOverlay: some View {
        VStack(spacing: 16) {
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
}
