import SwiftUI

#if canImport(UIKit)
import UIKit
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
                FeedDebugHUD(store: store)
            }
            if viewModel.videos.isEmpty && !viewModel.isLoading {
                statusOverlay
            }
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
}

/// Floating debug HUD displaying video identity (tap to copy), dislike feedback button, and title.
private struct FeedDebugHUD: View {
    @ObservedObject var store: FeedStreamStore
    @State private var copied = false
    @State private var dislikedIds: Set<String> = []

    var body: some View {
        if let video = store.items.first(where: { $0.streamId == store.activeStreamId })?.video {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // ID Row: tap to copy to clipboard
                    Button {
                        copyId(video.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(copied ? Color.green : Color.white.opacity(0.6))
                            Text(copied ? "已复制" : video.id)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(copied ? Color.green : Color.white.opacity(0.85))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(copied ? Color.green.opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    // Dislike Button: telemetry data collection
                    let isDisliked = dislikedIds.contains(video.id)
                    Button {
                        if !isDisliked {
                            recordDislike(video.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isDisliked ? "heart.slash.fill" : "hand.thumbsdown")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(isDisliked ? DuloCoral : Color.white.opacity(0.6))
                            Text(isDisliked ? "已记录" : "不喜欢")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isDisliked ? DuloCoral : Color.white.opacity(0.85))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isDisliked ? DuloCoral.opacity(0.2) : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisliked)
                }

                // Title Row: clean display without blocking gestures
                if !video.title.isEmpty {
                    Text(video.title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 16)
            .padding(.bottom, 36)
        }
    }

    private func copyId(_ id: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = id
        #endif
        withAnimation(.easeInOut(duration: 0.15)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.15)) {
                copied = false
            }
        }
    }

    private func recordDislike(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            dislikedIds.insert(id)
        }
        guard let url = URL(string: "\(AppSettings.serverBaseUrl)/dislike/\(id)") else { return }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        request.httpMethod = "POST"
        Task.detached {
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
