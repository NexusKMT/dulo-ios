import SwiftUI

#if canImport(UIKit)
import UIKit
import AVFoundation
import QuartzCore

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
    }

    // MARK: - Controller

    final class FeedCollectionViewController: UIViewController {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
        override var shouldAutorotate: Bool { false }

        let layout: UICollectionViewFlowLayout
        weak var coordinator: Coordinator?
        var collectionView: UICollectionView!
        var lastReportedCount = 0

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
            if lastReportedCount == 0 && itemCount > 0 {
                lastReportedCount = itemCount
                collectionView.reloadData()
                coordinator?.preloadAhead(from: 0)
            } else if itemCount > lastReportedCount {
                let startIndex = lastReportedCount
                lastReportedCount = itemCount
                let indexPaths = (startIndex..<itemCount).map { IndexPath(item: $0, section: 0) }
                collectionView.performBatchUpdates {
                    collectionView.insertItems(at: indexPaths)
                }
            } else if itemCount != lastReportedCount {
                lastReportedCount = itemCount
                collectionView.reloadData()
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
            // Intercepts touch ONLY when horizontal velocity strictly exceeds vertical velocity by 1.2x.
            // Yields 100% to outer vertical feed when dragging vertically, with 0ms gesture delay.
            return abs(velocity.x) > (abs(velocity.y) * 1.2)
        }
    }

    // MARK: - Gallery Slide Cell (Tier 0 Image + Tier 1 Live Photo Motion)

    final class GallerySlideCell: UICollectionViewCell {
        static let reuseId = "GallerySlideCell"

        let coverImageView = UIImageView()
        let motionPlayerView = PlayerLayerContainer()
        private var currentUrl: URL?
        private var imageLoadTask: Task<Void, Never>?
        /// Item the motion layer has confirmed rendered. Same identity rule as the
        /// single-video layer: the bare `isReadyForDisplay` flag is not item-scoped.
        private var motionReadyItem: AVPlayerItem?

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
            // Neutral `.fit` geometry only until `applyContentMode(_:)` runs: the
            // real mode comes from the owning item's `ar` and is applied before
            // any pixel of this slide is shown.
            coverImageView.contentMode = MediaContentMode.fit.imageContentMode
            coverImageView.clipsToBounds = MediaContentMode.fit.clipsContent
            contentView.addSubview(coverImageView)

            motionPlayerView.backgroundColor = .clear
            motionPlayerView.clipsToBounds = false
            motionPlayerView.alpha = 0.0
            contentView.addSubview(motionPlayerView)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            coverImageView.frame = contentView.bounds
            motionPlayerView.frame = contentView.bounds
            CATransaction.commit()
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            imageLoadTask?.cancel()
            imageLoadTask = nil
            currentUrl = nil
            coverImageView.image = nil
            // Drop the previous item's fill/fit state so nothing can be inherited
            // by the next slide that reuses this cell.
            coverImageView.contentMode = MediaContentMode.fit.imageContentMode
            coverImageView.clipsToBounds = MediaContentMode.fit.clipsContent
            detachMotion()
        }

        /// One mode for both surfaces of this slide: the still cover and the Live
        /// Photo motion layer. `GallerySlide` carries no `ar` of its own, so the
        /// owner passes the already resolved item mode (`.fit` when unusable).
        /// Must run before the cover image is assigned: the image then appears
        /// already fill/fit instead of re-laying out under the motion layer.
        func applyContentMode(_ mode: MediaContentMode) {
            let gravity = mode.videoGravity
            coverImageView.contentMode = mode.imageContentMode
            coverImageView.clipsToBounds = mode.clipsContent
            // `resizeAspectFill` paints past the layer bounds: clip exactly then.
            motionPlayerView.updateClipping(for: gravity)
            let layer = motionPlayerView.playerLayer
            guard layer.videoGravity != gravity else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.videoGravity = gravity
            CATransaction.commit()
        }

        func detachMotion() {
            motionPlayerView.playerLayer.player = nil
            motionPlayerView.alpha = 0.0
            motionPlayerView.onReadyForDisplay = nil
            // Detach path: readiness is item-bound, drop the token with the layer.
            motionReadyItem = nil
        }

        /// `true` only when the layer flag refers to the item we bound readiness
        /// to; right after a swap it can still be the previous item's `true`.
        private func isMotionReady(for player: AVPlayer) -> Bool {
            guard let motionReadyItem, player.currentItem === motionReadyItem else { return false }
            return motionPlayerView.playerLayer.isReadyForDisplay
        }

        func attachMotion(slot: FeedPlayerPool.PlayerSlot, mode: MediaContentMode) {
            // Re-assert geometry on every (re)attach: a sticky-prewarm slot can
            // take over a layer that still carries the previous item's gravity.
            applyContentMode(mode)
            let player = slot.player
            if motionPlayerView.playerLayer.player !== player {
                motionPlayerView.playerLayer.player = player
                // New player: whatever the flag says belongs to the old one.
                motionReadyItem = nil
            }
            if motionReadyItem !== player.currentItem {
                motionReadyItem = nil
            }
            if isMotionReady(for: player) {
                motionPlayerView.alpha = 1.0
                return
            }
            motionPlayerView.alpha = 0.0
            motionPlayerView.onReadyForDisplay = { [weak self] in
                self?.markMotionReadyFromLayerCallback()
            }
        }

        /// Binds the layer's ready event to the item the player holds right now,
        /// then fades the motion layer in. The cover underneath stays authoritative
        /// until this point, so a stale `true` can never expose the prior frame.
        private func markMotionReadyFromLayerCallback() {
            guard let player = motionPlayerView.playerLayer.player,
                  motionPlayerView.playerLayer.isReadyForDisplay,
                  let item = player.currentItem else { return }
            motionReadyItem = item
            UIView.animate(withDuration: 0.15, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                self.motionPlayerView.alpha = 1.0
            }
        }

        func configure(slide: GallerySlide, mode: MediaContentMode) {
            // Geometry first, pixels second: the cover must never be shown in the
            // previous slide's fill/fit state and then jump.
            applyContentMode(mode)
            guard let url = URL(string: slide.imageUrl) else { return }
            currentUrl = url

            // Synchronous 0ms RAM probe
            if let cached = ImagePipeline.shared.cachedImage(for: url) {
                coverImageView.image = cached
                return
            }

            imageLoadTask?.cancel()
            imageLoadTask = Task { @MainActor [weak self] in
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
        let singlePlayerView = PlayerLayerContainer()

        // Gallery mode views (lazily created on demand for image gallery posts)
        private var horizontalLayout: UICollectionViewFlowLayout?
        private var horizontalCollectionView: HorizontalPagingCollectionView?

        // Data & State
        private enum CellMode {
            case unconfigured
            case video(playUrl: String)
            case gallery(slides: [GallerySlide], bgmUrl: String?)
        }
        private var cellMode: CellMode = .unconfigured

        private(set) var currentItem: FeedStreamItem?
        private(set) var resolvedPlayUrl: String?
        private var currentTask: Task<Void, Never>?
        private var motionDebounceTask: Task<Void, Never>?
        private weak var attachedSlot: FeedPlayerPool.PlayerSlot?
        private var currentViewModel: FeedViewModel?
        private var currentStore: FeedStreamStore?
        private var leaseRenewalTask: Task<Void, Never>?
        private var itemStatusObservation: NSKeyValueObservation?
        private var itemFailureObserver: NSObjectProtocol?
        private weak var observedItem: AVPlayerItem?
        /// The item this layer has *confirmed* rendered. `isReadyForDisplay` is
        /// delivered asynchronously by KVO, so the bare flag can still be the
        /// replaced item's `true`; readiness is only trusted together with this
        /// identity token (see `isLayerReady(for:)`).
        private var readyItem: AVPlayerItem?
        /// KVO on the slot player's `currentItem`. The pool's foreground heal
        /// replaces the item without going through `attach`, which would otherwise
        /// leave `alpha == 1` over a blank layer (black flash).
        private var playerCurrentItemObservation: NSKeyValueObservation?
        /// Player the observation above is bound to, so a repeated `attach` of the
        /// same slot does not churn KVO registration.
        private weak var observedCurrentItemPlayer: AVPlayer?
        /// One-shot backstop for a ready event that never arrives (a layer that
        /// keeps `isReadyForDisplay == true` across an item swap produces no
        /// transition to observe). Invalidated by `clearReadyState()`.
        private var pendingRevealFallback: Task<Void, Never>?
        private var revealSequence: UInt64 = 0
        private var isRecoveringLease = false
        private(set) var appliedRole: CellRole?

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
            // Neutral `.fit` only: `applyVideoGravityForCurrentItem()` resolves the
            // item's `ar` and sets the real image mode before the cover is shown.
            singleCoverImageView.contentMode = MediaContentMode.fit.imageContentMode
            singleCoverImageView.isOpaque = true
            singleCoverImageView.clipsToBounds = MediaContentMode.fit.clipsContent
            contentView.addSubview(singleCoverImageView)

            singlePlayerView.backgroundColor = .clear
            singlePlayerView.alpha = 0.0
            singlePlayerView.clipsToBounds = false
            contentView.addSubview(singlePlayerView)
        }

        @discardableResult
        private func ensureGalleryViews() -> (UICollectionViewFlowLayout, HorizontalPagingCollectionView) {
            if let layout = horizontalLayout, let cv = horizontalCollectionView {
                return (layout, cv)
            }
            let layout = UICollectionViewFlowLayout()
            layout.scrollDirection = .horizontal
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            layout.itemSize = contentView.bounds.size

            let cv = HorizontalPagingCollectionView(frame: contentView.bounds, collectionViewLayout: layout)
            cv.backgroundColor = .black
            cv.isPagingEnabled = true
            cv.showsHorizontalScrollIndicator = false
            cv.contentInsetAdjustmentBehavior = .never
            cv.bounces = true
            cv.delaysContentTouches = false
            cv.canCancelContentTouches = true
            cv.isDirectionalLockEnabled = true
            cv.dataSource = self
            cv.delegate = self
            cv.prefetchDataSource = self
            cv.register(GallerySlideCell.self, forCellWithReuseIdentifier: GallerySlideCell.reuseId)
            cv.isHidden = true
            contentView.addSubview(cv)

            self.horizontalLayout = layout
            self.horizontalCollectionView = cv
            return (layout, cv)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            singleCoverImageView.frame = contentView.bounds
            singlePlayerView.frame = contentView.bounds
            if let cv = horizontalCollectionView, let layout = horizontalLayout {
                cv.frame = contentView.bounds
                if layout.itemSize != contentView.bounds.size {
                    layout.itemSize = contentView.bounds.size
                    layout.invalidateLayout()
                }
            }
            CATransaction.commit()
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            currentTask?.cancel()
            currentTask = nil
            motionDebounceTask?.cancel()
            motionDebounceTask = nil
            leaseRenewalTask?.cancel()
            leaseRenewalTask = nil
            clearItemObservers()
            currentViewModel = nil
            currentStore = nil
            isRecoveringLease = false
            appliedRole = nil

            if !currentSlideUrls.isEmpty {
                ImagePipeline.shared.unpin(urls: currentSlideUrls)
                currentSlideUrls.removeAll()
            }

            detachPlayer()
            singleCoverImageView.image = nil
            // Neutral geometry for the outgoing item; `configure` re-applies the
            // next item's mode before any of its pixels are shown.
            singleCoverImageView.contentMode = MediaContentMode.fit.imageContentMode
            singleCoverImageView.clipsToBounds = MediaContentMode.fit.clipsContent
            currentItem = nil
            resolvedPlayUrl = nil
            currentBgmUrl = nil
            cellMode = .unconfigured

            // CRITICAL: DO NOT call currentSlides.removeAll() or horizontalCollectionView.reloadData() here!
            // horizontalCollectionView is simply hidden. Its data count matches UIKit layout cache, preventing NSInternalInconsistencyException!
            isReconfiguring = true
            currentSlideIndex = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            horizontalCollectionView?.isHidden = true
            singleCoverImageView.isHidden = false
            singlePlayerView.isHidden = false
            CATransaction.commit()
            isReconfiguring = false
        }

        func detachPlayer() {
            let hadAttachment = attachedSlot != nil || singlePlayerView.playerLayer.player != nil
            attachedSlot = nil
            clearItemObservers()
            // Detach path: drop both readiness sources so a late KVO delivery can
            // never reveal a layer that is no longer ours.
            invalidatePlayerCurrentItemObservation()
            clearReadyState()
            if hadAttachment { FeedPlayerPool.noteLayerDetach() }
            singlePlayerView.resetDetachedPlayer()
            singlePlayerView.playerLayer.player = nil
            singlePlayerView.alpha = 0.0
            singlePlayerView.onReadyForDisplay = nil
            singleCoverImageView.isHidden = false
        }

        // MARK: - Item-bound readiness (single video layer)

        /// `true` only when the layer's own flag refers to the very item we bound
        /// readiness to. The flag alone is not item-scoped: right after a player or
        /// item swap it can still carry the previous item's `true`.
        private func isLayerReady(for player: AVPlayer) -> Bool {
            guard let readyItem, player.currentItem === readyItem else { return false }
            return singlePlayerView.playerLayer.isReadyForDisplay
        }

        /// Nulls the readiness token and retires any pending backstop. Called on
        /// every item identity change.
        private func clearReadyState() {
            readyItem = nil
            revealSequence &+= 1
            pendingRevealFallback?.cancel()
            pendingRevealFallback = nil
        }

        private func invalidatePlayerCurrentItemObservation() {
            playerCurrentItemObservation?.invalidate()
            playerCurrentItemObservation = nil
            observedCurrentItemPlayer = nil
        }

        /// Watches the slot player's current item: a foreground heal can swap it
        /// behind our back, and the cell must fall back to the cover instead of
        /// showing an already-empty layer. Re-attaching the same player is a no-op,
        /// so this stays cheap on role flips and page settles.
        private func observePlayerCurrentItem(_ player: AVPlayer) {
            if playerCurrentItemObservation != nil, observedCurrentItemPlayer === player { return }
            invalidatePlayerCurrentItemObservation()
            observedCurrentItemPlayer = player
            playerCurrentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.handlePlayerItemChanged()
                }
            }
        }

        /// Item swapped under us: readiness now belongs to the replaced item, so
        /// hide the video, re-show the cover and wait for the new item's frame 0.
        private func handlePlayerItemChanged() {
            guard let slot = attachedSlot,
                  singlePlayerView.playerLayer.player === slot.player else { return }
            clearReadyState()
            guard singlePlayerView.isHidden == false else { return }
            singlePlayerView.alpha = 0.0
            singleCoverImageView.isHidden = false
            // Rebind the failure watch to the new item, then wait for its frame.
            observeItemStatus(slot.player.currentItem, videoId: currentItem?.video.id)
            armReadyReveal()
        }

        /// Cover visible, video hidden, reveal armed for the *next* item-bound
        /// ready event. Idempotent: safe on every attach / role flip.
        private func armReadyReveal() {
            singlePlayerView.alpha = 0.0
            singleCoverImageView.isHidden = false
            singlePlayerView.onReadyForDisplay = { [weak self] in
                self?.markReadyFromLayerCallback()
            }
            scheduleRevealBackstop()
        }

        /// A layer that never flips `isReadyForDisplay` back to `false` on an item
        /// swap emits no transition, so the cover would stay up forever. By this
        /// point the new item's first frame has certainly been presented, so
        /// binding it and revealing is safe; the guard on the flag still applies.
        private func scheduleRevealBackstop() {
            revealSequence &+= 1
            let sequence = revealSequence
            pendingRevealFallback?.cancel()
            pendingRevealFallback = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled, let self, self.revealSequence == sequence else { return }
                self.pendingRevealFallback = nil
                self.markReadyFromLayerCallback()
            }
        }

        /// `PlayerLayerContainer.onReadyForDisplay` is driven by KVO on the layer
        /// flag, which is not item-scoped by itself. Attribute the event to the item
        /// the player holds *now*, then reveal.
        private func markReadyFromLayerCallback() {
            guard let slot = attachedSlot,
                  singlePlayerView.playerLayer.player === slot.player,
                  singlePlayerView.playerLayer.isReadyForDisplay,
                  let item = slot.player.currentItem else { return }
            let isFirstReveal = readyItem !== item
            readyItem = item
            if isFirstReveal, let vid = currentItem?.video.id {
                AVTelemetryTracker.shared.recordReadyForDisplay(for: vid)
            }
            revealReadyLayer()
        }

        /// Fade the layer in and retire the cover. Both steps re-check the bound
        /// item: an item swap can land between the reveal and the fade completion.
        private func revealReadyLayer() {
            guard let slot = attachedSlot, isLayerReady(for: slot.player) else { return }
            guard singlePlayerView.alpha != 1.0 else {
                singleCoverImageView.isHidden = true
                return
            }
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                self.singlePlayerView.alpha = 1.0
            } completion: { [weak self] _ in
                guard let self,
                      let slot = self.attachedSlot,
                      self.readyItem === slot.player.currentItem,
                      self.singlePlayerView.playerLayer.isReadyForDisplay else { return }
                self.singleCoverImageView.isHidden = true
            }
        }

        /// The one resolution point for this cell. Video layer, cover image,
        /// gallery slides and Live Photo layers all read *this* mode for the same
        /// item, so cover → first frame can never change scale.
        private var currentContentMode: MediaContentMode {
            VideoGravityPolicy.mode(forAspectRatio: currentItem?.video.aspectRatio)
        }

        /// The fill policy lives on the view, not in the player pool:
        /// `slot.prepare(videoGravity:)` never reached the layer, so gravity is
        /// applied here, where the current item (and its `ar`) is known.
        /// Applies the resolved mode to the single-video surfaces: the player
        /// layer (gravity + clipping) and the cover image underneath it.
        private func applyVideoGravityForCurrentItem() {
            let mode = currentContentMode
            let gravity = mode.videoGravity

            // Cover first: it must already occupy its final fill/fit box before
            // the layer fades in over it.
            singleCoverImageView.contentMode = mode.imageContentMode
            singleCoverImageView.clipsToBounds = mode.clipsContent

            // `resizeAspectFill` draws past the layer bounds: clip exactly when
            // the mode is fill, stay unclipped for fit.
            singlePlayerView.updateClipping(for: gravity)
            let layer = singlePlayerView.playerLayer
            guard layer.videoGravity != gravity else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.videoGravity = gravity
            CATransaction.commit()
        }

        /// Re-applies the current mode to every surface this cell owns. Safe to
        /// call on each item/slide/role/resolve transition: the writes are
        /// idempotent and never trigger a layout pass or Auto Layout.
        private func applyContentMode() {
            applyVideoGravityForCurrentItem()
            applyContentModeToGallerySlides(currentContentMode)
        }

        /// Gallery slides inherit the item's mode (a slide has no `ar` of its
        /// own). Newly dequeued cells get it in `cellForItemAt`; this covers the
        /// slides already realized on screen.
        private func applyContentModeToGallerySlides(_ mode: MediaContentMode) {
            guard let cv = horizontalCollectionView else { return }
            for case let cell as GallerySlideCell in cv.visibleCells {
                cell.applyContentMode(mode)
            }
        }

        func attach(slot: FeedPlayerPool.PlayerSlot) {
            guard singlePlayerView.isHidden == false else { return }
            // Single choke point for sticky-prewarm take-over and re-attach:
            // resolve this item's mode before any surface is presented, and never
            // inherit the mode of the page that occupied this cell before.
            applyContentMode()

            let player = slot.player
            let item = player.currentItem
            // Readiness belongs to an item identity. If the identity moved (reuse,
            // take-over, heal) the old `true` is void before anything is presented.
            if readyItem !== item { clearReadyState() }

            let alreadyAttached = attachedSlot === slot
                && singlePlayerView.playerLayer.player === player
                && observedItem === item
            if alreadyAttached, ExperimentVariant.stickyPrewarmEnabled {
                // Take-over fast path: reveal only on item-bound readiness, else
                // fall back to the cover and wait for this item's frame 0.
                if isLayerReady(for: player) {
                    revealReadyLayer()
                } else {
                    armReadyReveal()
                }
                return
            }
            attachedSlot = slot
            // Watch the player's item from now on: the foreground heal may replace
            // it without another attach, and that must not stay behind alpha 1.
            observePlayerCurrentItem(player)
            observeItemStatus(item, videoId: currentItem?.video.id)
            if singlePlayerView.playerLayer.player !== player {
                singlePlayerView.playerLayer.player = player
                FeedPlayerPool.noteLayerAttachChanged()
            }
            if isLayerReady(for: player) {
                revealReadyLayer()
            } else {
                armReadyReveal()
            }
        }

        func configure(
            item: FeedStreamItem,
            viewModel: FeedViewModel,
            store: FeedStreamStore
        ) {
            // Item switch: readiness is bound to the outgoing item's identity.
            if currentItem?.streamId != item.streamId {
                clearReadyState()
            }
            currentItem = item
            currentViewModel = viewModel
            currentStore = store
            // Item switch: resolve geometry synchronously, before the cover probe
            // below assigns an image. Deliberately only the single-video surfaces:
            // the gallery collection view may still hold the *previous* item's
            // slides, and the `.gallery` resolve branch re-modes them after its
            // own reload. Nothing is inherited either way.
            applyVideoGravityForCurrentItem()
            if ExperimentVariant.stickyPrewarmEnabled,
               let attached = attachedSlot,
               attached.currentStreamId != item.streamId {
                detachPlayer()
            }
            leaseRenewalTask?.cancel()
            leaseRenewalTask = nil
            clearItemObservers()
            isRecoveringLease = false
            appliedRole = nil
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
                if lease == nil || !lease!.isFresh() {
                    let result = await viewModel.resolveMedia(id: video.id, force: false)
                    if case .ready(let fresh) = result {
                        lease = fresh
                    }
                }
                guard self.currentItem?.streamId == streamId, let lease else { return }

                switch lease.value {
                case .video(let playUrl, let coverStr, _, _):
                    self.cellMode = .video(playUrl: playUrl)
                    self.currentSlides = []
                    self.currentSlideUrls = []
                    self.resolvedPlayUrl = playUrl
                    self.currentBgmUrl = nil

                    self.horizontalCollectionView?.isHidden = true
                    self.singleCoverImageView.isHidden = false
                    self.singlePlayerView.isHidden = false
                    self.horizontalCollectionView?.reloadData()
                    // Re-resolve landing after a reuse (or after `ar` arrived):
                    // re-assert the mode before the cover or the first frame shows.
                    self.applyVideoGravityForCurrentItem()

                    // Start playback first; the cover sits below the player layer and
                    // must never delay the first video frame on a slow image CDN.
                    self.refreshPlayback(store: store)
                    self.scheduleLeaseRenewal(videoId: video.id, lease: lease)

                    if let coverStr, let coverUrl = URL(string: coverStr), self.singleCoverImageView.image == nil {
                        if let cached = ImagePipeline.shared.cachedImage(for: coverUrl) {
                            self.singleCoverImageView.image = cached
                        } else {
                            Task { @MainActor [weak self] in
                                let image = await ImagePipeline.shared.loadImage(for: coverUrl)
                                guard let self, self.currentItem?.streamId == streamId else { return }
                                self.singleCoverImageView.image = image
                            }
                        }
                    }

                case .images(let urls, let music, let slides):
                    let effectiveSlides = slides.isEmpty ? urls.enumerated().map { GallerySlide(id: "\(video.id)_\($0)", imageUrl: $1) } : slides
                    self.cellMode = .gallery(slides: effectiveSlides, bgmUrl: music)
                    self.currentSlides = effectiveSlides
                    self.currentSlideUrls = effectiveSlides.compactMap { URL(string: $0.imageUrl) }
                    self.resolvedPlayUrl = nil
                    self.currentBgmUrl = music

                    let (_, galleryCv) = self.ensureGalleryViews()
                    self.singleCoverImageView.isHidden = true
                    self.singlePlayerView.isHidden = true
                    galleryCv.isHidden = false

                    // Pin sliding window [0, 1, 2] in RAM
                    ImagePipeline.shared.pin(urls: Array(self.currentSlideUrls.prefix(3)))

                    self.isReconfiguring = true
                    self.currentSlideIndex = 0
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    galleryCv.reloadData()
                    galleryCv.setContentOffset(.zero, animated: false)
                    galleryCv.layoutIfNeeded()
                    CATransaction.commit()
                    self.isReconfiguring = false

                    // Slides have no independent `ar`: they inherit this item's
                    // mode (`.fit` when unusable). Slide 0 is realized now, so
                    // push the mode onto it before the first image lands.
                    self.applyContentModeToGallerySlides(self.currentContentMode)

                    self.refreshPlayback(store: store)
                }
            }
        }

        private func scheduleLeaseRenewal(videoId: String, lease: Lease<ResolvedMedia>) {
            leaseRenewalTask?.cancel()
            let seconds = max(5, lease.expiresAt.timeIntervalSinceNow - Lease<ResolvedMedia>.defaultRenewalMargin)
            let nanos = UInt64(min(seconds, 3600) * 1_000_000_000)
            leaseRenewalTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled,
                      let self,
                      let viewModel = self.currentViewModel,
                      self.currentItem?.video.id == videoId else { return }

                // Refresh the view model's lease before the current signed URL
                // expires. Do not replace a healthy player item: that would reset
                // playback position. A failed item is handled separately below.
                let result = await viewModel.resolveMedia(id: videoId, force: true)
                guard !Task.isCancelled, self.currentItem?.video.id == videoId else { return }
                if case .ready(let renewed) = result {
                    self.scheduleLeaseRenewal(videoId: videoId, lease: renewed)
                }
            }
        }

        private func observeItemStatus(_ item: AVPlayerItem?, videoId: String?) {
            guard let item, let videoId else {
                clearItemObservers()
                return
            }
            if observedItem === item { return }
            clearItemObservers()
            observedItem = item
            itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    self?.handlePlaybackFailure(item: item, videoId: videoId)
                }
            }
            itemFailureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePlaybackFailure(item: item, videoId: videoId)
                }
            }
        }

        private func clearItemObservers() {
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil
            if let itemFailureObserver {
                NotificationCenter.default.removeObserver(itemFailureObserver)
                self.itemFailureObserver = nil
            }
            observedItem = nil
        }

        private func handlePlaybackFailure(item: AVPlayerItem, videoId: String) {
            guard !isRecoveringLease,
                  observedItem === item,
                  currentItem?.video.id == videoId,
                  let viewModel = currentViewModel,
                  let store = currentStore else { return }
            isRecoveringLease = true
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil

            Task { @MainActor [weak self] in
                defer { self?.isRecoveringLease = false }
                let result = await viewModel.resolveMedia(id: videoId, force: true)
                guard let self,
                      !Task.isCancelled,
                      self.currentItem?.video.id == videoId else { return }

                switch result {
                case .ready(let lease):
                    if case .video(let playUrl, _, _, _) = lease.value {
                        self.resolvedPlayUrl = playUrl
                        self.cellMode = .video(playUrl: playUrl)
                        self.refreshPlayback(store: store)
                        self.scheduleLeaseRenewal(videoId: videoId, lease: lease)
                    }
                case .notFound:
                    // Skip is owned by the pager; leave the cover visible rather
                    // than retrying the same dead URL forever. The cover must be
                    // un-hidden too, otherwise the page stays black.
                    self.clearReadyState()
                    self.singlePlayerView.alpha = 0.0
                    self.singleCoverImageView.isHidden = false
                default:
                    break
                }
            }
        }
        func refreshPlayback(
            store: FeedStreamStore,
            gravity gravityOverride: AVLayerVideoGravity? = nil
        ) {
            guard let item = currentItem else { return }
            // Every refresh is a transition (page change, role change, lease
            // recovery): re-derive this item's mode instead of trusting whatever
            // the previous page left on the surfaces.
            applyContentMode()
            let gravity = gravityOverride ?? currentContentMode.videoGravity
            if ExperimentVariant.stickyPrewarmEnabled {
                let role = CellRole.of(
                    streamId: item.streamId,
                    active: store.activeStreamId,
                    prewarm: store.prewarmStreamId
                )
                applyRole(role, store: store, gravity: gravity)
                return
            }
            let isActive = (store.activeStreamId == item.streamId)
            let isPrewarm = (store.prewarmStreamId == item.streamId)

            switch cellMode {
            case .video(let playUrl):
                if isActive {
                    let slot = FeedPlayerPool.shared.acquireSlot(
                        for: item.streamId,
                        visibleStreamIds: store.visibleStreamIds
                    )
                    slot.prepare(
                        streamId: item.streamId,
                        videoId: item.video.id,
                        playUrl: playUrl,
                        isMuted: false,
                        autoplay: false,
                        videoGravity: gravity
                    )
                    attach(slot: slot)
                    FeedPlayerPool.shared.play(slot: slot)
                } else if isPrewarm {
                    // Prewarm cell: attaches slot and prepares paused first frame to prevent black flash, but NEVER plays!
                    let slot = FeedPlayerPool.shared.acquireSlot(
                        for: item.streamId,
                        visibleStreamIds: store.visibleStreamIds
                    )
                    slot.prepare(
                        streamId: item.streamId,
                        videoId: item.video.id,
                        playUrl: playUrl,
                        isMuted: true,
                        autoplay: false,
                        videoGravity: gravity
                    )
                    attach(slot: slot)
                } else {
                    detachPlayer()
                }

            case .gallery:
                if isActive {
                    // The pool owns BGM focus. A nil URL explicitly stops any
                    // leftover track from the previous gallery page.
                    FeedPlayerPool.shared.activateGallery(
                        streamId: item.streamId,
                        bgmURL: currentBgmUrl.flatMap(URL.init(string:))
                    )
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
                        if let cv = horizontalCollectionView,
                           let cell = cv.cellForItem(at: IndexPath(item: currentSlideIndex, section: 0)) as? GallerySlideCell {
                            cell.detachMotion()
                        }
                    }
                }

            case .unconfigured:
                break
            }
        }

        /// Sticky arm: apply a role only when it actually changes. The control
        /// arm keeps the old `refreshPlayback` behaviour so the two runtime
        /// arms differ by one variable.
        func applyRole(
            _ role: CellRole,
            store: FeedStreamStore,
            gravity gravityOverride: AVLayerVideoGravity? = nil
        ) {
            guard let item = currentItem else { return }
            // Role flips are prewarm take-overs: the surfaces must carry *this*
            // item's mode, not the one the slot was prepared with earlier.
            applyContentMode()
            let gravity = gravityOverride ?? currentContentMode.videoGravity

            switch cellMode {
            case .video(let playUrl):
                switch role {
                case .active:
                    let slot = FeedPlayerPool.shared.acquireSlot(
                        for: item.streamId,
                        visibleStreamIds: store.visibleStreamIds
                    )
                    if slot.isReusable(streamId: item.streamId, playUrl: playUrl) {
                        slot.setMuted(false)
                    } else {
                        slot.prepare(
                            streamId: item.streamId,
                            videoId: item.video.id,
                            playUrl: playUrl,
                            isMuted: false,
                            autoplay: false,
                            videoGravity: gravity
                        )
                    }
                    attach(slot: slot)
                    // Same identity rule as the reveal path: a bare flag here can
                    // still be the replaced item's readiness.
                    if isLayerReady(for: slot.player) {
                        AVTelemetryTracker.shared.recordReadyForDisplay(for: item.video.id)
                    }
                    FeedPlayerPool.shared.ensurePlaying(slot: slot, streamId: item.streamId)

                case .prewarm:
                    let slot = FeedPlayerPool.shared.acquireSlot(
                        for: item.streamId,
                        visibleStreamIds: store.visibleStreamIds
                    )
                    if slot.isReusable(streamId: item.streamId, playUrl: playUrl) {
                        slot.setMuted(true)
                        slot.pause()
                    } else {
                        slot.prepare(
                            streamId: item.streamId,
                            videoId: item.video.id,
                            playUrl: playUrl,
                            isMuted: true,
                            autoplay: false,
                            videoGravity: gravity
                        )
                    }
                    attach(slot: slot)

                case .none:
                    if attachedSlot != nil || singlePlayerView.playerLayer.player != nil {
                        detachPlayer()
                    }
                }

            case .gallery:
                switch role {
                case .active:
                    FeedPlayerPool.shared.activateGallery(
                        streamId: item.streamId,
                        bgmURL: currentBgmUrl.flatMap(URL.init(string:))
                    )
                    scheduleMotionPlay(at: currentSlideIndex)
                case .prewarm:
                    if let first = currentSlideUrls.first {
                        ImagePipeline.shared.prefetch(urls: [first])
                    }
                case .none:
                    motionDebounceTask?.cancel()
                    if let cv = horizontalCollectionView,
                       let cell = cv.cellForItem(at: IndexPath(item: currentSlideIndex, section: 0)) as? GallerySlideCell {
                        cell.detachMotion()
                    }
                }

            case .unconfigured:
                break
            }

            appliedRole = role
        }

        // MARK: - Live Photo Momentum Debounce

        private func scheduleMotionPlay(at index: Int) {
            motionDebounceTask?.cancel()
            guard index >= 0, index < currentSlides.count else { return }
            let slide = currentSlides[index]
            guard let motionUrl = slide.motionVideoUrl else {
                // Slide is pure image: free hardware video decoder immediately!
                if let cv = horizontalCollectionView,
                   let cell = cv.cellForItem(at: IndexPath(item: index, section: 0)) as? GallerySlideCell {
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

                guard let cv = self.horizontalCollectionView else { return }
                let indexPath = IndexPath(item: index, section: 0)
                guard let cell = cv.cellForItem(at: indexPath) as? GallerySlideCell else { return }

                let slot = FeedPlayerPool.shared.acquireSlot(
                    for: self.currentItem?.streamId ?? 0,
                    visibleStreamIds: [self.currentItem?.streamId ?? 0]
                )
                let slideKey = "\(self.currentItem?.video.id ?? "feed")_\(slide.id)"
                // The motion layer renders the same post as its cover: same mode.
                let mode = self.currentContentMode
                slot.prepare(
                    streamId: self.currentItem?.streamId ?? 0,
                    videoId: slideKey,
                    playUrl: motionUrl,
                    isMuted: true,
                    autoplay: true,
                    videoGravity: mode.videoGravity,
                    disableAudioTracks: true
                )
                cell.attachMotion(slot: slot, mode: mode)
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
            // Dequeued cells are reused across items: hand over the resolved mode
            // so the cover renders in its final fill/fit box immediately.
            cell.configure(slide: currentSlides[indexPath.item], mode: currentContentMode)
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

            // Preload upcoming Live Photo motion video loops in horizontal gallery!
            for idx in indexPaths {
                let item = idx.item
                guard item < currentSlides.count else { continue }
                let slide = currentSlides[item]
                if let motionUrlStr = slide.motionVideoUrl, let url = URL(string: motionUrlStr) {
                    let slideKey = "\(currentItem?.video.id ?? "feed")_\(slide.id)"
                    MediaPreloadManager.shared.preload(
                        url: url,
                        key: slideKey,
                        targetSize: MediaPreloadManager.livePhotoPreloadSize
                    )
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for idx in indexPaths {
                let item = idx.item
                guard item < currentSlides.count else { continue }
                let slide = currentSlides[item]
                let slideKey = "\(currentItem?.video.id ?? "feed")_\(slide.id)"
                MediaPreloadManager.shared.cancel(key: slideKey)
            }
        }

        // MARK: - Horizontal Scroll & Sliding Window

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isReconfiguring else { return }
            let width = scrollView.bounds.width
            guard width > 0 else { return }
            let newIndex = Int((scrollView.contentOffset.x + width * 0.5) / width)

            if newIndex != currentSlideIndex && newIndex >= 0 && newIndex < currentSlides.count {
                currentSlideIndex = newIndex
                // Slide switch: the incoming slide must not inherit the outgoing
                // one's fill/fit state. Idempotent, no layout pass, and this
                // branch only runs when the index actually changes.
                applyContentModeToGallerySlides(currentContentMode)
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

        private var currentlyPinnedKeys: Set<String> = []

        /// Sticky arm anchor and hysteresis direction. Control never reads these.
        private var prewarmAnchorIndex = 0
        private var prewarmDirection: PrewarmDirection = .next

        private var dragStartTime: CFTimeInterval?
        private var dragStartOffsetPages: Double = 0
        private var dragEndOffsetPages: Double = 0
        private var dragMaxAbsDeltaPages: Double = 0
        private var dragDirectionReversals = 0
        private var dragLastSign = 0
        private var dragStartActiveStreamId: Int64 = 0
        private var dragPrewarmSwitches = 0
        private var dragRefreshCalls = 0
        private var dragApplyRoleCalls = 0
        private var dragPrefetchCalls = 0
        private var dragCancelPrefetchCalls = 0

        init(store: FeedStreamStore, viewModel: FeedViewModel) {
            self.store = store
            self.viewModel = viewModel
            super.init()
        }

        deinit {
            for k in currentlyPinnedKeys {
                MediaCacheStorage.shared.unpin(key: k)
            }
            currentlyPinnedKeys.removeAll()
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            controller?.lastReportedCount ?? store.items.count
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

        func collectionView(
            _ collectionView: UICollectionView,
            didEndDisplaying cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            guard let feedCell = cell as? FeedVideoCell else { return }
            if ExperimentVariant.stickyPrewarmEnabled,
               feedCell.currentItem?.streamId == store.prewarmStreamId {
                // Keep the prepared neighbour attached while it is just
                // outside the viewport; the next micro-drag must not re-bind.
                return
            }
            feedCell.detachPlayer()
        }

        // MARK: - UICollectionViewDataSourcePrefetching

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            dragPrefetchCalls += indexPaths.count
            for indexPath in indexPaths {
                let index = indexPath.item
                guard index >= 0, index < store.items.count else { continue }
                let videoId = store.items[index].video.id
                // Cache hit only: prefetch cover image if already resolved.
                // Do NOT fire uncached /resolve requests to protect the server's Dual-Tab priority queue.
                if let lease = viewModel.cachedLease(for: videoId) {
                    if let coverStr = lease.value.coverImageUrl, let url = URL(string: coverStr) {
                        ImagePipeline.shared.prefetch(urls: [url])
                    }
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            dragCancelPrefetchCalls += indexPaths.count
            for indexPath in indexPaths {
                let index = indexPath.item
                guard index >= 0, index < store.items.count else { continue }
                let videoId = store.items[index].video.id
                MediaPreloadManager.shared.cancel(key: videoId)
                viewModel.cancelResolve(for: videoId)
            }
        }

        // MARK: - Scroll & Single-Player Page Settling

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard !store.items.isEmpty else { return }
            finishDragWindow()

            let pageHeight = scrollView.bounds.height
            guard pageHeight > 0 else { return }
            let offsetY = scrollView.contentOffset.y
            if let activeIndex = store.items.firstIndex(where: { $0.streamId == store.activeStreamId }) {
                prewarmAnchorIndex = activeIndex
            } else {
                prewarmAnchorIndex = max(0, min(store.items.count - 1, Int(round(offsetY / pageHeight))))
            }
            prewarmDirection = .next

            dragStartTime = CACurrentMediaTime()
            dragStartOffsetPages = Double(offsetY / pageHeight)
            dragEndOffsetPages = dragStartOffsetPages
            dragMaxAbsDeltaPages = 0
            dragDirectionReversals = 0
            dragLastSign = 0
            dragStartActiveStreamId = store.activeStreamId
            dragPrewarmSwitches = 0
            dragRefreshCalls = 0
            dragApplyRoleCalls = 0
            dragPrefetchCalls = 0
            dragCancelPrefetchCalls = 0
            FeedPlayerPool.resetDragCounters()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !store.items.isEmpty else { return }
            let pageHeight = scrollView.bounds.height
            guard pageHeight > 0 else { return }
            let offsetY = scrollView.contentOffset.y

            let topIndex = max(0, Int(floor(offsetY / pageHeight)))
            let bottomIndex = min(store.items.count - 1, Int(floor((offsetY + pageHeight - 1.0) / pageHeight)))
            var visibleIds: Set<Int64> = []
            if topIndex <= bottomIndex && topIndex >= 0 && bottomIndex < store.items.count {
                for i in topIndex...bottomIndex {
                    visibleIds.insert(store.items[i].streamId)
                }
            }
            let visibleChanged = store.visibleStreamIds != visibleIds
            if visibleChanged {
                store.visibleStreamIds = visibleIds
            }
            updateDragMetrics(offsetY: offsetY, pageHeight: pageHeight)

            if ExperimentVariant.stickyPrewarmEnabled {
                updateStickyPrewarm(
                    offsetY: offsetY,
                    pageHeight: pageHeight,
                    velocityY: Double(scrollView.panGestureRecognizer.velocity(in: scrollView).y),
                    isDragging: scrollView.isDragging
                )
                return
            }
            var playbackStateChanged = visibleChanged

            // Control arm: preserve build 32's visible-set selection. A 1 pt
            // move changes the visible pair and therefore flips N-1/N+1.
            let currentIndex = max(0, min(store.items.count - 1, Int(round(offsetY / pageHeight))))
            var secondaryId: Int64? = nil
            if visibleIds.count > 1 {
                for i in topIndex...bottomIndex {
                    if i >= 0 && i < store.items.count {
                        let sid = store.items[i].streamId
                        if sid != store.activeStreamId {
                            secondaryId = sid
                            break
                        }
                    }
                }
            } else {
                let nextIndex = currentIndex + 1
                if nextIndex < store.items.count {
                    secondaryId = store.items[nextIndex].streamId
                }
            }

            if store.prewarmStreamId != secondaryId {
                notePrewarmSwitch(
                    from: store.prewarmStreamId,
                    to: secondaryId,
                    reason: "visible_change",
                    deltaPages: Double(offsetY / pageHeight) - Double(prewarmAnchorIndex),
                    velocityY: Double(scrollView.panGestureRecognizer.velocity(in: scrollView).y),
                    isDragging: scrollView.isDragging
                )
                store.prewarmStreamId = secondaryId
                playbackStateChanged = true
            }
            if playbackStateChanged {
                refreshVisibleCells()
            }
        }

        private func updateStickyPrewarm(
            offsetY: CGFloat,
            pageHeight: CGFloat,
            velocityY: Double,
            isDragging: Bool
        ) {
            let deltaPages = Double(offsetY / pageHeight) - Double(prewarmAnchorIndex)
            let newDirection = PrewarmPolicy.direction(
                current: prewarmDirection,
                deltaPages: deltaPages
            )
            let oldDirection = prewarmDirection
            prewarmDirection = newDirection

            let targetIndex = PrewarmPolicy.targetIndex(
                anchor: prewarmAnchorIndex,
                direction: newDirection,
                count: store.items.count
            )
            let newPrewarm = targetIndex.map { store.items[$0].streamId }
            if store.prewarmStreamId != newPrewarm {
                notePrewarmSwitch(
                    from: store.prewarmStreamId,
                    to: newPrewarm,
                    fromDirection: oldDirection,
                    toDirection: newDirection,
                    reason: "scroll_threshold",
                    deltaPages: deltaPages,
                    velocityY: velocityY,
                    isDragging: isDragging
                )
                store.prewarmStreamId = newPrewarm
            }
            applyRolesIfChanged()
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            guard !store.items.isEmpty else { return }
            let pageHeight = scrollView.bounds.height
            guard pageHeight > 0 else { return }
            let targetIndex = max(0, min(store.items.count - 1, Int(round(targetContentOffset.pointee.y / pageHeight))))
            guard targetIndex >= 0 && targetIndex < store.items.count else { return }

            let velocityY = abs(velocity.y)
            let targetItem = store.items[targetIndex]
            let videoId = targetItem.video.id
            let isCached = MediaCacheStorage.shared.metadata(for: "k_\(videoId)")?.cachedBytes ?? 0 > 0
            AVTelemetryTracker.shared.recordSwipeTrigger(
                for: videoId,
                cacheTier: isCached ? "L2_FLASH" : "WAN_CDN",
                isCacheHit: isCached
            )
            if ExperimentVariant.stickyPrewarmEnabled {
                let newDirection: PrewarmDirection = targetIndex < prewarmAnchorIndex ? .previous : .next
                let oldDirection = prewarmDirection
                prewarmDirection = newDirection
                let target = PrewarmPolicy.targetIndex(
                    anchor: prewarmAnchorIndex,
                    direction: newDirection,
                    count: store.items.count
                )
                let newPrewarm = target.map { store.items[$0].streamId }
                if store.prewarmStreamId != newPrewarm {
                    notePrewarmSwitch(
                        from: store.prewarmStreamId,
                        to: newPrewarm,
                        fromDirection: oldDirection,
                        toDirection: newDirection,
                        reason: "will_end_target",
                        deltaPages: Double(targetContentOffset.pointee.y / pageHeight) - Double(prewarmAnchorIndex),
                        velocityY: Double(velocity.y),
                        isDragging: false
                    )
                    store.prewarmStreamId = newPrewarm
                }
                applyRolesIfChanged()
            } else {
                let nextPrewarmIndex = velocity.y < 0 ? targetIndex - 1 : targetIndex + 1
                if nextPrewarmIndex >= 0 && nextPrewarmIndex < store.items.count {
                    let newPrewarm = store.items[nextPrewarmIndex].streamId
                    if store.prewarmStreamId != newPrewarm {
                        notePrewarmSwitch(
                            from: store.prewarmStreamId,
                            to: newPrewarm,
                            reason: "will_end_target",
                            deltaPages: Double(targetContentOffset.pointee.y / pageHeight) - Double(prewarmAnchorIndex),
                            velocityY: Double(velocity.y),
                            isDragging: false
                        )
                        store.prewarmStreamId = newPrewarm
                    }
                }
                refreshVisibleCells()
            }

            // Velocity Gating (Doom-Scrolling Protection):
            // If user is flicking rapidly past multiple videos, cancel stale preloads and do NOT waste video chunk bandwidth!
            if velocityY > 2.5 {
                let retained: Set<String> = [targetItem.video.id]
                MediaPreloadManager.shared.cancelAllExcept(retainedKeys: retained)
            } else {
                preloadAhead(from: targetIndex)
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                confirmSettledPage(scrollView)
                finishDragWindow()
            }
        }

        func refreshVisibleCells() {
            dragRefreshCalls += 1
            guard let collectionView = controller?.collectionView else { return }
            for cell in collectionView.visibleCells.compactMap({ $0 as? FeedVideoCell }) {
                cell.refreshPlayback(store: store)
            }
        }

        func applyRolesIfChanged() {
            guard let collectionView = controller?.collectionView else { return }
            for cell in collectionView.visibleCells.compactMap({ $0 as? FeedVideoCell }) {
                guard let item = cell.currentItem else { continue }
                let role = CellRole.of(
                    streamId: item.streamId,
                    active: store.activeStreamId,
                    prewarm: store.prewarmStreamId
                )
                guard cell.appliedRole != role else { continue }
                cell.applyRole(role, store: store)
                dragApplyRoleCalls += 1
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            confirmSettledPage(scrollView)
            finishDragWindow()
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            confirmSettledPage(scrollView)
            finishDragWindow()
        }

        private func confirmSettledPage(_ scrollView: UIScrollView) {
            guard !store.items.isEmpty else { return }
            let pageHeight = scrollView.bounds.height
            guard pageHeight > 0 else { return }
            let index = max(0, min(store.items.count - 1, Int(round(scrollView.contentOffset.y / pageHeight))))
            guard index >= 0, index < store.items.count else { return }

            let targetId = store.items[index].streamId
            if store.activeStreamId != targetId {
                store.activeStreamId = targetId
                // Revoke the old owner before the new cell resolves. This
                // closes the window where slow media resolution leaves stale
                // gallery BGM playing under the next page.
                FeedPlayerPool.shared.handlePageChanged()
                let videoId = store.items[index].video.id
                let isCached = MediaCacheStorage.shared.metadata(for: "k_\(videoId)")?.cachedBytes ?? 0 > 0
                AVTelemetryTracker.shared.recordPageSettled(
                    for: videoId,
                    cacheTier: isCached ? "L2_FLASH" : "WAN_CDN",
                    isCacheHit: isCached
                )
            }
            store.visibleStreamIds = [targetId]
            let nextIndex = index + 1
            let nextPrewarm = (nextIndex < store.items.count) ? store.items[nextIndex].streamId : nil
            if ExperimentVariant.stickyPrewarmEnabled {
                prewarmAnchorIndex = index
                prewarmDirection = .next
                if store.prewarmStreamId != nextPrewarm {
                    notePrewarmSwitch(
                        from: store.prewarmStreamId,
                        to: nextPrewarm,
                        reason: "settle",
                        deltaPages: 0,
                        velocityY: 0,
                        isDragging: false
                    )
                    store.prewarmStreamId = nextPrewarm
                }
            } else {
                if store.prewarmStreamId != nextPrewarm {
                    notePrewarmSwitch(
                        from: store.prewarmStreamId,
                        to: nextPrewarm,
                        reason: "settle",
                        deltaPages: 0,
                        velocityY: 0,
                        isDragging: false
                    )
                    store.prewarmStreamId = nextPrewarm
                }
            }

            // Cancel stale preloads outside immediate [index - 1 ... index + 2] window
            var retainedKeys = Set<String>()
            for i in max(0, index - 1)...min(store.items.count - 1, index + 2) {
                retainedKeys.insert(store.items[i].video.id)
            }
            MediaPreloadManager.shared.cancelAllExcept(retainedKeys: retainedKeys)

            // Pin active & prewarm items in disk storage (unpinning previous items to prevent cache pin leak)
            var newPinnedKeys: Set<String> = [MediaCacheKey.key(for: store.items[index].video.id)]
            if let prewarmId = store.prewarmStreamId,
               let prewarmItem = store.items.first(where: { $0.streamId == prewarmId }) {
                newPinnedKeys.insert(MediaCacheKey.key(for: prewarmItem.video.id))
            }
            let toUnpin = currentlyPinnedKeys.subtracting(newPinnedKeys)
            for k in toUnpin {
                MediaCacheStorage.shared.unpin(key: k)
            }
            for k in newPinnedKeys.subtracting(currentlyPinnedKeys) {
                MediaCacheStorage.shared.pin(key: k)
            }
            currentlyPinnedKeys = newPinnedKeys

            store.appendNextIfNeeded(near: index)
            if ExperimentVariant.stickyPrewarmEnabled {
                applyRolesIfChanged()
            } else {
                refreshVisibleCells()
            }
            preloadAhead(from: index)
        }

        private func updateDragMetrics(offsetY: CGFloat, pageHeight: CGFloat) {
            guard dragStartTime != nil else { return }
            let pages = Double(offsetY / pageHeight)
            dragEndOffsetPages = pages
            let delta = pages - dragStartOffsetPages
            dragMaxAbsDeltaPages = max(dragMaxAbsDeltaPages, abs(delta))

            let sign = delta > 0.01 ? 1 : (delta < -0.01 ? -1 : 0)
            guard sign != 0 else { return }
            if dragLastSign != 0 && sign != dragLastSign {
                dragDirectionReversals += 1
            }
            dragLastSign = sign
        }

        private func notePrewarmSwitch(
            from: Int64?,
            to: Int64?,
            fromDirection: PrewarmDirection? = nil,
            toDirection: PrewarmDirection? = nil,
            reason: String,
            deltaPages: Double,
            velocityY: Double,
            isDragging: Bool
        ) {
            guard from != to else { return }
            if dragStartTime != nil {
                dragPrewarmSwitches += 1
            }

            var event: [String: Any] = [
                "event_type": "prewarm_switch",
                "reason": reason,
                "delta_pages": deltaPages,
                "velocity_y": velocityY,
                "is_dragging": isDragging,
                "anchor_index": prewarmAnchorIndex
            ]
            if let from { event["from_sid"] = from }
            if let to { event["to_sid"] = to }
            if let fromDirection { event["from_direction"] = fromDirection.rawValue }
            if let toDirection { event["to_direction"] = toDirection.rawValue }
            RemoteTelemetryExporter.shared.submit(event: event)
        }

        private func finishDragWindow() {
            guard let start = dragStartTime else { return }
            dragStartTime = nil
            let counters = FeedPlayerPool.snapshotAndResetDragCounters()
            let durationMs = (CACurrentMediaTime() - start) * 1000.0
            RemoteTelemetryExporter.shared.submit(event: [
                "event_type": "drag_window",
                "duration_ms": durationMs,
                "start_pages": dragStartOffsetPages,
                "end_pages": dragEndOffsetPages,
                "max_abs_delta_pages": dragMaxAbsDeltaPages,
                "direction_reversals": dragDirectionReversals,
                "prewarm_switches": dragPrewarmSwitches,
                "refresh_calls": dragRefreshCalls,
                "apply_role_calls": dragApplyRoleCalls,
                "prefetch_calls": dragPrefetchCalls,
                "cancel_prefetch_calls": dragCancelPrefetchCalls,
                "prepare_new_item": counters.prepareNewItem,
                "prepare_reuse": counters.prepareReuse,
                "prepare_reuse_pause": counters.prepareReusePause,
                "slot_clears": counters.slotClears,
                "layer_attach_changed": counters.layerAttachChanged,
                "layer_detach": counters.layerDetach,
                "settled_page_changed": store.activeStreamId != dragStartActiveStreamId,
                "anchor_index": prewarmAnchorIndex
            ])
        }

        func preloadAhead(from index: Int) {
            // Strict N+1 Prewarm: only prewarm the immediate next item (target = index + 1)
            let target = index + 1
            guard target >= 0 && target < store.items.count else { return }
            let videoId = store.items[target].video.id

            Task { [weak viewModel] in
                // Priority 1 for speculative background prewarming
                let result = await viewModel?.resolveMedia(id: videoId, force: false, priority: 1)
                guard case .ready(let lease) = result else { return }

                // 1. Prefetch cover image
                if let coverStr = lease.value.coverImageUrl, let url = URL(string: coverStr) {
                    ImagePipeline.shared.prefetch(urls: [url])
                }

                // 2. Preload media based on post mode
                switch lease.value {
                case .video(let playUrl, _, _, _):
                    if let url = URL(string: playUrl) {
                        MediaPreloadManager.shared.preload(url: url, key: videoId, targetSize: MediaPreloadManager.videoPreloadSize)
                    }
                case .images(_, _, let slides):
                    // Multi-modal Live Photo preloading: strictly preload ONLY the first slide's motion video loop!
                    if let firstSlide = slides.first,
                       let motionUrlStr = firstSlide.motionVideoUrl,
                       let url = URL(string: motionUrlStr) {
                        let motionKey = "\(videoId)_\(firstSlide.id)"
                        MediaPreloadManager.shared.preload(
                            url: url,
                            key: motionKey,
                            targetSize: MediaPreloadManager.livePhotoPreloadSize
                        )
                    }
                }
            }
        }
    }
}
#endif
