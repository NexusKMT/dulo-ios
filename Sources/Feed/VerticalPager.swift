import SwiftUI

#if canImport(UIKit)
import UIKit
import AVFoundation

/// Vertical full-page pager (TikTok/Douyin architecture) backed by UICollectionView with paging.
/// Unifies Vertical Video Stream and Horizontal Live Photo / Image Gallery with 100% conceptual integrity:
/// 1. Pure UIKit without UIHostingController or Auto Layout on the scrolling hot-path (Hitch Ratio < 1.0 ms/s).
/// 2. Multi-Modal Decoders Hub (FeedPlayerPool): strictly $\le 2$ VideoToolbox hardware decoders at any instant.
/// 3. Orthogonal gesture arbitration via HorizontalPagingCollectionView (zero conflict between vertical & horizontal swipes).
/// 4. Live Photo 50ms momentum debounce + 0ms RAM L1 slide pinning + seamless BGM audio continuity.
@MainActor
struct VerticalPager: UIViewControllerRepresentable {
    @ObservedObject var store: FeedStreamStore
    @ObservedObject var viewModel: FeedViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, viewModel: viewModel)
    }

    func makeUIViewController(context: Context) -> FeedCollectionViewController {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let controller = FeedCollectionViewController(layout: layout, coordinator: context.coordinator)
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: FeedCollectionViewController, context: Context) {
        context.coordinator.store = store
        context.coordinator.viewModel = viewModel
        controller.update(itemCount: store.items.count)
        if !store.sceneActive {
            FeedPlayerPool.shared.pauseAll()
        }
    }

    // MARK: - Controller

    final class FeedCollectionViewController: UIViewController {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
        override var shouldAutorotate: Bool { false }

        let layout: UICollectionViewFlowLayout
        weak var coordinator: Coordinator?
        var collectionView: UICollectionView!
        private var lastReportedCount = 0

        init(layout: UICollectionViewFlowLayout, coordinator: Coordinator) {
            self.layout = layout
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
            collectionView.backgroundColor = .black
            collectionView.isPagingEnabled = true
            collectionView.showsVerticalScrollIndicator = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.bounces = true
            collectionView.dataSource = coordinator
            collectionView.delegate = coordinator
            collectionView.prefetchDataSource = coordinator
            collectionView.register(FeedVideoCell.self, forCellWithReuseIdentifier: FeedVideoCell.reuseId)
            collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            view.addSubview(collectionView)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if layout.itemSize != view.bounds.size {
                layout.itemSize = view.bounds.size
                layout.invalidateLayout()
            }
        }

        func update(itemCount: Int) {
            guard let collectionView else { return }
            if lastReportedCount == 0 {
                lastReportedCount = itemCount
                collectionView.reloadData()
                coordinator?.preloadAhead(from: 0)
            } else if itemCount > lastReportedCount {
                let start = lastReportedCount
                lastReportedCount = itemCount
                let newIndexPaths = (start..<itemCount).map { IndexPath(item: $0, section: 0) }
                collectionView.insertItems(at: newIndexPaths)
            }
        }

        func scrollTo(index: Int, animated: Bool) {
            guard index >= 0, index < (coordinator?.store.items.count ?? 0) else { return }
            let indexPath = IndexPath(item: index, section: 0)
            collectionView?.scrollToItem(at: indexPath, at: .top, animated: animated)
        }
    }

    // MARK: - Orthogonal Gesture Pager

    public final class HorizontalPagingCollectionView: UICollectionView {
        override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === self.panGestureRecognizer else {
                return super.gestureRecognizerShouldBegin(gestureRecognizer)
            }
            let velocity = self.panGestureRecognizer.velocity(in: self)
            // Mathematical Gesture Disambiguation:
            // Intercepts touch ONLY when horizontal velocity strictly exceeds vertical velocity.
            // Yields 100% to outer vertical feed when dragging vertically, with 0ms gesture delay.
            return abs(velocity.x) > abs(velocity.y)
        }
    }

    // MARK: - Gallery Slide Cell (Tier 0 Image + Tier 1 Live Photo Motion)

    final class GallerySlideCell: UICollectionViewCell {
        static let reuseId = "GallerySlideCell"

        let coverImageView = UIImageView()
        let motionContainerView = UIView()
        private var currentUrl: URL?
        private weak var attachedSlot: FeedPlayerPool.PlayerSlot?

        override init(frame: CGRect) {
            super.init(frame: frame)
            setupViews()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupViews()
        }

        private func setupViews() {
            backgroundColor = .black
            contentView.backgroundColor = .black
            isOpaque = true
            contentView.isOpaque = true

            coverImageView.backgroundColor = .black
            coverImageView.contentMode = .scaleAspectFit
            coverImageView.clipsToBounds = false
            contentView.addSubview(coverImageView)

            motionContainerView.backgroundColor = .clear
            motionContainerView.clipsToBounds = false
            motionContainerView.alpha = 0.0
            contentView.addSubview(motionContainerView)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            coverImageView.frame = contentView.bounds
            motionContainerView.frame = contentView.bounds
            if let slot = attachedSlot {
                slot.playerLayer.frame = motionContainerView.bounds
            }
            CATransaction.commit()
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            currentUrl = nil
            coverImageView.image = nil
            detachMotion()
        }

        func detachMotion() {
            if let slot = attachedSlot {
                if slot.playerLayer.superlayer == motionContainerView.layer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    slot.playerLayer.removeFromSuperlayer()
                    CATransaction.commit()
                }
                slot.onReadyForDisplay = nil
                attachedSlot = nil
            }
            motionContainerView.alpha = 0.0
        }

        func attachMotion(slot: FeedPlayerPool.PlayerSlot) {
            if attachedSlot === slot && slot.playerLayer.superlayer == motionContainerView.layer {
                if slot.isReadyForDisplay { motionContainerView.alpha = 1.0 }
                return
            }
            detachMotion()
            attachedSlot = slot

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            slot.playerLayer.frame = motionContainerView.bounds
            motionContainerView.layer.addSublayer(slot.playerLayer)
            CATransaction.commit()

            // Always start transparent to keep key photo visible until the live video frame decodes
            motionContainerView.alpha = 0.0
            slot.onReadyForDisplay = { [weak self] in
                guard let self else { return }
                UIView.animate(withDuration: 0.15, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                    self.motionContainerView.alpha = 1.0
                }
            }
        }

        func configure(slide: GallerySlide) {
            guard let url = URL(string: slide.imageUrl) else { return }
            currentUrl = url

            // Synchronous 0ms RAM probe
            if let cached = ImagePipeline.shared.cachedImage(for: url) {
                coverImageView.image = cached
                return
            }

            Task { @MainActor [weak self] in
                let img = await ImagePipeline.shared.loadImage(for: url)
                if self?.currentUrl == url {
                    self?.coverImageView.image = img
                }
            }
        }
    }

    // MARK: - Unified Multi-Modal Feed Cell

    final class FeedVideoCell: UICollectionViewCell, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
        static let reuseId = "FeedVideoCell"

        // Single video mode views
        let singleCoverImageView = UIImageView()
        let singlePlayerContainerView = UIView()

        // Gallery mode views
        private var horizontalLayout: UICollectionViewFlowLayout!
        private var horizontalCollectionView: HorizontalPagingCollectionView!

        // Data & State
        private(set) var currentItem: FeedStreamItem?
        private(set) var resolvedPlayUrl: String?
        private var currentTask: Task<Void, Never>?
        private var motionDebounceTask: Task<Void, Never>?
        private weak var attachedSlot: FeedPlayerPool.PlayerSlot?

        private var currentSlides: [GallerySlide] = []
        private var currentSlideUrls: [URL] = []
        private var currentSlideIndex: Int = 0
        private var isReconfiguring = false
        private var currentBgmUrl: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            setupCellHierarchy()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupCellHierarchy()
        }

        private func setupCellHierarchy() {
            isOpaque = true
            backgroundColor = .black
            contentView.isOpaque = true
            contentView.backgroundColor = .black
            layer.isOpaque = true
            layer.backgroundColor = UIColor.black.cgColor
            layer.masksToBounds = false
            clipsToBounds = false
            contentView.clipsToBounds = false

            // 1. Single video mode setup
            singleCoverImageView.backgroundColor = .black
            singleCoverImageView.contentMode = .scaleAspectFit
            singleCoverImageView.isOpaque = true
            singleCoverImageView.clipsToBounds = false
            contentView.addSubview(singleCoverImageView)

            singlePlayerContainerView.backgroundColor = .clear
            singlePlayerContainerView.isOpaque = false
            singlePlayerContainerView.clipsToBounds = false
            singlePlayerContainerView.layer.masksToBounds = false
            singlePlayerContainerView.alpha = 0.0
            contentView.addSubview(singlePlayerContainerView)

            // 2. Horizontal gallery setup
            horizontalLayout = UICollectionViewFlowLayout()
            horizontalLayout.scrollDirection = .horizontal
            horizontalLayout.minimumLineSpacing = 0
            horizontalLayout.minimumInteritemSpacing = 0

            horizontalCollectionView = HorizontalPagingCollectionView(frame: bounds, collectionViewLayout: horizontalLayout)
            horizontalCollectionView.backgroundColor = .black
            horizontalCollectionView.isPagingEnabled = true
            horizontalCollectionView.showsHorizontalScrollIndicator = false
            horizontalCollectionView.contentInsetAdjustmentBehavior = .never
            horizontalCollectionView.bounces = true
            horizontalCollectionView.delaysContentTouches = false
            horizontalCollectionView.canCancelContentTouches = true
            horizontalCollectionView.isDirectionalLockEnabled = true
            horizontalCollectionView.dataSource = self
            horizontalCollectionView.delegate = self
            horizontalCollectionView.prefetchDataSource = self
            horizontalCollectionView.register(GallerySlideCell.self, forCellWithReuseIdentifier: GallerySlideCell.reuseId)
            horizontalCollectionView.isHidden = true
            contentView.addSubview(horizontalCollectionView)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            singleCoverImageView.frame = contentView.bounds
            singlePlayerContainerView.frame = contentView.bounds
            horizontalCollectionView.frame = contentView.bounds
            if horizontalLayout.itemSize != contentView.bounds.size {
                horizontalLayout.itemSize = contentView.bounds.size
                horizontalLayout.invalidateLayout()
            }
            if let slot = attachedSlot {
                slot.playerLayer.frame = singlePlayerContainerView.bounds
            }
            CATransaction.commit()
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            currentTask?.cancel()
            currentTask = nil
            motionDebounceTask?.cancel()
            motionDebounceTask = nil

            if !currentSlideUrls.isEmpty {
                ImagePipeline.shared.unpin(urls: currentSlideUrls)
                currentSlideUrls.removeAll()
            }

            detachPlayer()
            singleCoverImageView.image = nil
            currentItem = nil
            resolvedPlayUrl = nil
            currentBgmUrl = nil
            singlePlayerContainerView.alpha = 0.0
            currentSlides.removeAll()

            // Safe sync offset reset without animation or layout thrashing
            isReconfiguring = true
            currentSlideIndex = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            horizontalCollectionView.reloadData()
            horizontalCollectionView.setContentOffset(.zero, animated: false)
            horizontalCollectionView.isHidden = true
            singleCoverImageView.isHidden = false
            singlePlayerContainerView.isHidden = false
            CATransaction.commit()
            isReconfiguring = false
        }

        func detachPlayer() {
            if let slot = attachedSlot {
                if slot.playerLayer.superlayer == singlePlayerContainerView.layer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    slot.playerLayer.removeFromSuperlayer()
                    CATransaction.commit()
                }
                slot.onReadyForDisplay = nil
                attachedSlot = nil
            }
            singlePlayerContainerView.alpha = 0.0
        }

        func attach(slot: FeedPlayerPool.PlayerSlot) {
            guard singlePlayerContainerView.isHidden == false else { return }
            if attachedSlot === slot && slot.playerLayer.superlayer == singlePlayerContainerView.layer {
                if slot.isReadyForDisplay { singlePlayerContainerView.alpha = 1.0 }
                return
            }
            detachPlayer()
            attachedSlot = slot

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            slot.playerLayer.frame = singlePlayerContainerView.bounds
            singlePlayerContainerView.layer.addSublayer(slot.playerLayer)
            CATransaction.commit()

            if slot.isReadyForDisplay {
                singlePlayerContainerView.alpha = 1.0
            } else {
                singlePlayerContainerView.alpha = 0.0
                slot.onReadyForDisplay = { [weak self] in
                    guard let self else { return }
                    UIView.animate(withDuration: 0.12, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                        self.singlePlayerContainerView.alpha = 1.0
                    }
                }
            }
        }

        func configure(
            item: FeedStreamItem,
            viewModel: FeedViewModel,
            store: FeedStreamStore
        ) {
            currentItem = item
            let streamId = item.streamId
            let video = item.video

            // Fast synchronous RAM probe for cover
            if let lease = viewModel.cachedLease(for: video.id),
               let coverStr = lease.value.coverImageUrl,
               let coverUrl = URL(string: coverStr),
               let cached = ImagePipeline.shared.cachedImage(for: coverUrl) {
                singleCoverImageView.image = cached
            }

            currentTask?.cancel()
            currentTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var lease = viewModel.cachedLease(for: video.id)
                if lease == nil || !lease!.isFresh(nowElapsedMs: monotonicNowMs()) {
                    let result = await viewModel.resolveMedia(id: video.id, force: false)
                    if case .ready(let fresh) = result {
                        lease = fresh
                    }
                }
                guard self.currentItem?.streamId == streamId, let lease else { return }

                switch lease.value {
                case .video(let playUrl, let coverStr, let w, let h):
                    self.horizontalCollectionView.isHidden = true
                    self.singleCoverImageView.isHidden = false
                    self.singlePlayerContainerView.isHidden = false
                    self.resolvedPlayUrl = playUrl
                    self.currentBgmUrl = nil

                    if let coverStr, let coverUrl = URL(string: coverStr), self.singleCoverImageView.image == nil {
                        if let cached = ImagePipeline.shared.cachedImage(for: coverUrl) {
                            self.singleCoverImageView.image = cached
                        } else {
                            self.singleCoverImageView.image = await ImagePipeline.shared.loadImage(for: coverUrl)
                        }
                    }

                    self.refreshPlayback(store: store, gravity: .resizeAspect)

                case .images(let urls, let music, let slides):
                    self.singleCoverImageView.isHidden = true
                    self.singlePlayerContainerView.isHidden = true
                    self.horizontalCollectionView.isHidden = false
                    self.resolvedPlayUrl = nil
                    self.currentBgmUrl = music

                    let effectiveSlides = slides.isEmpty ? urls.enumerated().map { GallerySlide(id: "\(video.id)_\($0)", imageUrl: $1) } : slides
                    self.currentSlides = effectiveSlides
                    self.currentSlideUrls = effectiveSlides.compactMap { URL(string: $0.imageUrl) }

                    // Pin sliding window [0, 1, 2] in RAM
                    ImagePipeline.shared.pin(urls: Array(self.currentSlideUrls.prefix(3)))

                    self.isReconfiguring = true
                    self.currentSlideIndex = 0
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.horizontalCollectionView.reloadData()
                    self.horizontalCollectionView.setContentOffset(.zero, animated: false)
                    self.horizontalCollectionView.layoutIfNeeded()
                    CATransaction.commit()
                    self.isReconfiguring = false

                    self.refreshPlayback(store: store)
                }
            }
        }

        func refreshPlayback(store: FeedStreamStore, gravity: AVLayerVideoGravity = .resizeAspect) {
            guard let item = currentItem else { return }
            let isActive = (store.activeStreamId == item.streamId)
            let isPrewarm = (store.prewarmStreamId == item.streamId)

            if !currentSlides.isEmpty {
                // Multi-Modal Gallery Post
                if isActive {
                    // Play independent BGM
                    if let bgm = currentBgmUrl {
                        FeedPlayerPool.shared.bgmPlayer.play(urlString: bgm)
                    } else {
                        FeedPlayerPool.shared.bgmPlayer.stop()
                    }
                    // Schedule active Live Photo on current slide
                    scheduleMotionPlay(at: currentSlideIndex)
                } else {
                    if isPrewarm {
                        // Prewarm gallery: warm up slide 0 in RAM
                        if let first = currentSlideUrls.first {
                            ImagePipeline.shared.prefetch(urls: [first])
                        }
                    } else {
                        motionDebounceTask?.cancel()
                        if let cell = horizontalCollectionView.cellForItem(at: IndexPath(item: currentSlideIndex, section: 0)) as? GallerySlideCell {
                            cell.detachMotion()
                        }
                    }
                }
            } else if let playUrl = resolvedPlayUrl {
                // Single Video Post
                if isActive || isPrewarm {
                    FeedPlayerPool.shared.bgmPlayer.stop()
                    let slot = FeedPlayerPool.shared.acquireSlot(
                        for: item.streamId,
                        visibleStreamIds: store.visibleStreamIds
                    )
                    attach(slot: slot)
                    slot.prepare(
                        streamId: item.streamId,
                        videoId: item.video.id,
                        playUrl: playUrl,
                        isMuted: !isActive,
                        autoplay: isActive ? store.sceneActive : true,
                        videoGravity: .resizeAspect
                    )
                } else {
                    detachPlayer()
                }
            }
        }

        // MARK: - Live Photo Momentum Debounce

        private func scheduleMotionPlay(at index: Int) {
            motionDebounceTask?.cancel()
            guard index >= 0, index < currentSlides.count else { return }
            let slide = currentSlides[index]
            guard let motionUrl = slide.motionVideoUrl else {
                // Slide is pure image: free hardware video decoder immediately!
                if let cell = horizontalCollectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? GallerySlideCell {
                    cell.detachMotion()
                }
                FeedPlayerPool.shared.activeSlot.clear()
                return
            }

            motionDebounceTask = Task { @MainActor [weak self] in
                // 50ms momentum debounce: prevent decoder thrashing during fast flicking
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled, self.currentSlideIndex == index else { return }
                guard index >= 0, index < self.currentSlides.count else { return }

                let indexPath = IndexPath(item: index, section: 0)
                guard let cell = self.horizontalCollectionView.cellForItem(at: indexPath) as? GallerySlideCell else { return }

                let slot = FeedPlayerPool.shared.acquireSlot(
                    for: self.currentItem?.streamId ?? 0,
                    visibleStreamIds: [self.currentItem?.streamId ?? 0]
                )
                let slideKey = "\(self.currentItem?.video.id ?? "feed")_\(slide.id)"
                cell.attachMotion(slot: slot)
                slot.prepare(
                    streamId: self.currentItem?.streamId ?? 0,
                    videoId: slideKey,
                    playUrl: motionUrl,
                    isMuted: true,
                    autoplay: true,
                    videoGravity: .resizeAspect
                )
            }
        }

        // MARK: - UICollectionViewDataSource & Delegate (Horizontal Gallery)

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            currentSlides.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: GallerySlideCell.reuseId, for: indexPath) as! GallerySlideCell
            guard indexPath.item >= 0 && indexPath.item < currentSlides.count else {
                return cell
            }
            cell.configure(slide: currentSlides[indexPath.item])
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let urls = indexPaths.compactMap { idx -> URL? in
                guard idx.item < currentSlideUrls.count else { return nil }
                return currentSlideUrls[idx.item]
            }
            ImagePipeline.shared.prefetch(urls: urls)
        }

        // MARK: - Horizontal Scroll & Sliding Window

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isReconfiguring else { return }
            let width = scrollView.bounds.width
            guard width > 0 else { return }
            let newIndex = Int((scrollView.contentOffset.x + width * 0.5) / width)

            if newIndex != currentSlideIndex && newIndex >= 0 && newIndex < currentSlides.count {
                currentSlideIndex = newIndex
                // Detach previous slide's motion
                FeedPlayerPool.shared.activeSlot.clear()

                // Update sliding memory window: [k-1, k, k+1]
                let start = max(0, newIndex - 1)
                let end = min(currentSlideUrls.count, newIndex + 2)
                if start < end && end <= currentSlideUrls.count {
                    ImagePipeline.shared.pin(urls: Array(currentSlideUrls[start..<end]))
                }

                // Prefetch next neighbour
                let next = newIndex + 1
                if next < currentSlideUrls.count {
                    ImagePipeline.shared.prefetch(urls: [currentSlideUrls[next]])
                }
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard !isReconfiguring else { return }
            scheduleMotionPlay(at: currentSlideIndex)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate && !isReconfiguring {
                scheduleMotionPlay(at: currentSlideIndex)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
        var store: FeedStreamStore
        var viewModel: FeedViewModel
        weak var controller: FeedCollectionViewController?

        init(store: FeedStreamStore, viewModel: FeedViewModel) {
            self.store = store
            self.viewModel = viewModel
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            store.items.count
        }

        func collectionView(_ collectionView: UICollectionView,
                            cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: FeedVideoCell.reuseId,
                for: indexPath
            ) as! FeedVideoCell

            guard indexPath.item >= 0 && indexPath.item < store.items.count else {
                return cell
            }

            let item = store.items[indexPath.item]
            cell.configure(
                item: item,
                viewModel: viewModel,
                store: store
            )
            return cell
        }

        func collectionView(_ collectionView: UICollectionView,
                            layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
        }

        // MARK: - UICollectionViewDataSourcePrefetching

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            for indexPath in indexPaths {
                let index = indexPath.item
                guard index >= 0, index < store.items.count else { continue }
                let videoId = store.items[index].video.id
                Task { [weak viewModel] in
                    let result = await viewModel?.resolveMedia(id: videoId, force: false)
                    if case .ready(let lease) = result {
                        if let coverStr = lease.value.coverImageUrl, let url = URL(string: coverStr) {
                            ImagePipeline.shared.prefetch(urls: [url])
                        }
                        if case .video(let playUrl, _, _, _) = lease.value, let url = URL(string: playUrl) {
                            MediaPreloadManager.shared.preload(url: url, key: videoId)
                        }
                    }
                }
            }
        }

        // MARK: - Scroll & Midpoint Activation (Play While Dragging)

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let pageHeight = scrollView.bounds.height
            guard pageHeight > 0 else { return }
            let offsetY = scrollView.contentOffset.y

            // 1. Precise Viewport Tracking
            let topIndex = max(0, Int(floor(offsetY / pageHeight)))
            let bottomIndex = min(store.items.count - 1, Int(floor((offsetY + pageHeight - 1.0) / pageHeight)))
            var visibleIds: Set<Int64> = []
            if topIndex <= bottomIndex && topIndex >= 0 && bottomIndex < store.items.count {
                for i in topIndex...bottomIndex {
                    visibleIds.insert(store.items[i].streamId)
                }
            }
            if store.visibleStreamIds != visibleIds {
                store.visibleStreamIds = visibleIds
            }

            // 2. Playback Focus Handoff at Midpoint (Play While Dragging)
            let targetIndex = max(0, min(store.items.count - 1, Int(round(offsetY / pageHeight))))
            let targetId = store.items[targetIndex].streamId
            if store.activeStreamId != targetId {
                store.activeStreamId = targetId
                let videoId = store.items[targetIndex].video.id
                let isCached = MediaCacheStorage.shared.metadata(for: "k_\(videoId)")?.cachedBytes ?? 0 > 0
                AVTelemetryTracker.shared.recordSwipeTrigger(
                    for: videoId,
                    cacheTier: isCached ? "L2_FLASH" : "WAN_CDN",
                    isCacheHit: isCached
                )
            }

            // 3. Symmetric 2-Decoder Allocation:
            // Primary cell closer to center gets the active decoder.
            // Secondary cell visible on screen during vertical drag gets the second decoder.
            // When only 1 cell is visible, the upcoming cell in scroll direction is prewarmed.
            var secondaryId: Int64? = nil
            if visibleIds.count > 1 {
                for i in topIndex...bottomIndex {
                    if i >= 0 && i < store.items.count {
                        let sid = store.items[i].streamId
                        if sid != targetId {
                            secondaryId = sid
                            break
                        }
                    }
                }
            } else {
                let nextIndex = targetIndex + 1
                if nextIndex < store.items.count {
                    secondaryId = store.items[nextIndex].streamId
                }
            }

            if store.prewarmStreamId != secondaryId {
                store.prewarmStreamId = secondaryId
            }

            refreshVisibleCells()

            let currentIndex = max(0, Int(offsetY / pageHeight))
            store.appendNextIfNeeded(near: currentIndex)
        }

        func refreshVisibleCells() {
            guard let collectionView = controller?.collectionView else { return }
            for cell in collectionView.visibleCells.compactMap({ $0 as? FeedVideoCell }) {
                cell.refreshPlayback(store: store)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            confirmSettledPage(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            confirmSettledPage(scrollView)
        }

        private func confirmSettledPage(_ scrollView: UIScrollView) {
            let pageHeight = scrollView.bounds.height
            guard pageHeight > 0 else { return }
            let index = Int(round(scrollView.contentOffset.y / pageHeight))
            if index >= 0 && index < store.items.count {
                let targetId = store.items[index].streamId
                if store.activeStreamId != targetId {
                    store.activeStreamId = targetId
                }
                store.visibleStreamIds = [targetId]
                let nextIndex = index + 1
                store.prewarmStreamId = (nextIndex < store.items.count) ? store.items[nextIndex].streamId : nil
                store.appendNextIfNeeded(near: index)
                refreshVisibleCells()
                preloadAhead(from: index)
            }
        }

        func preloadAhead(from index: Int) {
            for offset in 1...2 {
                let target = index + offset
                guard target >= 0 && target < store.items.count else { continue }
                let videoId = store.items[target].video.id
                Task { [weak viewModel] in
                    let result = await viewModel?.resolveMedia(id: videoId, force: false)
                    if case .ready(let lease) = result {
                        if let coverStr = lease.value.coverImageUrl, let url = URL(string: coverStr) {
                            ImagePipeline.shared.prefetch(urls: [url])
                        }
                        if case .video(let playUrl, _, _, _) = lease.value, let url = URL(string: playUrl) {
                            MediaPreloadManager.shared.preload(url: url, key: videoId)
                        }
                    }
                }
            }
        }
    }
}
#endif
