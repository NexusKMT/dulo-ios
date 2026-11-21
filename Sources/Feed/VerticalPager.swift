import SwiftUI

#if canImport(UIKit)
import UIKit

/// Vertical full-page pager (TikTok-style) backed by UICollectionView with paging.
/// Delivers continuous playback while dragging (play while dragging): the active video
/// continues playing smoothly during the drag gesture until crossing the scroll threshold,
/// matching Android Compose VerticalPager and official TikTok/Shorts architecture.
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
            collectionView.isPrefetchingEnabled = false
            collectionView.showsVerticalScrollIndicator = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.bounces = true
            collectionView.dataSource = coordinator
            collectionView.delegate = coordinator
            collectionView.register(FeedVideoCell.self, forCellWithReuseIdentifier: FeedVideoCell.reuseId)
            collectionView.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(collectionView)
            NSLayoutConstraint.activate([
                collectionView.topAnchor.constraint(equalTo: view.topAnchor),
                collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
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

    // MARK: - Cell

    final class FeedVideoCell: UICollectionViewCell {
        static let reuseId = "FeedVideoCell"
        private var hostingController: UIHostingController<AnyView>?
        private var currentStreamId: Int64?
        private var currentVideoId: String?
        private weak var viewModel: FeedViewModel?

        override func prepareForReuse() {
            super.prepareForReuse()
            cleanupHosting()
        }

        private func cleanupHosting() {
            if let videoId = currentVideoId {
                viewModel?.cancelResolve(for: videoId)
            }
            if let host = hostingController {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                hostingController = nil
            }
            currentStreamId = nil
            currentVideoId = nil
            viewModel = nil
        }

        func configure(
            item: FeedStreamItem,
            store: FeedStreamStore,
            viewModel: FeedViewModel,
            parent: UIViewController
        ) {
            if currentStreamId == item.streamId && hostingController != nil {
                return
            }
            cleanupHosting()
            currentStreamId = item.streamId
            currentVideoId = item.video.id
            self.viewModel = viewModel

            let page = FeedVideoPage(
                streamId: item.streamId,
                video: item.video,
                store: store,
                viewModel: viewModel
            ).id(item.streamId)

            let host = UIHostingController(rootView: AnyView(page))
            host.view.backgroundColor = .black
            host.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
            parent.addChild(host)
            host.didMove(toParent: parent)
            self.hostingController = host
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
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

            guard let controller else { return cell }
            let item = store.items[indexPath.item]

            cell.configure(
                item: item,
                store: store,
                viewModel: viewModel,
                parent: controller
            )
            return cell
        }

        func collectionView(_ collectionView: UICollectionView,
                            layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            collectionView.bounds.size
        }

        // MARK: - Scroll & Midpoint Activation (Play While Dragging)

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let pageHeight = scrollView.bounds.height
            guard pageHeight > 0 else { return }
            let offsetY = scrollView.contentOffset.y

            // Smooth threshold handoff: video keeps playing during 0%~50% drag
            // When passing 50% midpoint, activeStreamId transitions seamlessly
            let targetIndex = Int((offsetY + pageHeight * 0.5) / pageHeight)
            if targetIndex >= 0 && targetIndex < store.items.count {
                let targetId = store.items[targetIndex].streamId
                if store.activeStreamId != targetId {
                    store.activeStreamId = targetId
                }
            }

            let currentIndex = max(0, Int(offsetY / pageHeight))
            store.appendNextIfNeeded(near: currentIndex)
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
                store.appendNextIfNeeded(near: index)
            }
        }
    }
}
#endif
