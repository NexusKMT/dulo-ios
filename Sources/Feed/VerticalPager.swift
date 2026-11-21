import SwiftUI

#if canImport(UIKit)
import UIKit

/// Vertical full-page pager (TikTok-style) backed by UIPageViewController in
/// scroll mode: full-size pages, midpoint activation on drag, one prepared
/// neighbour. SwiftUI has no vertical paging below iOS 17, and the scroll
/// snap behaviour is exactly what UIPageViewController provides.
struct VerticalPager: UIViewControllerRepresentable {
    @ObservedObject var store: FeedStreamStore
    @ObservedObject var viewModel: FeedViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, viewModel: viewModel)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .vertical,
            options: [.interPageSpacing: 0]
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black
        pager.setViewControllers(
            [context.coordinator.pageController(at: 0)],
            direction: .forward, animated: false
        )
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.pager = pager
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let store: FeedStreamStore
        let viewModel: FeedViewModel
        weak var pager: UIPageViewController?

        /// Strong refs to page hosts; evicted beyond a window of 3 so the
        /// infinite feed does not accumulate players.
        private var controllers: [Int64: UIHostingController<FeedVideoPage>] = [:]

        init(store: FeedStreamStore, viewModel: FeedViewModel) {
            self.store = store
            self.viewModel = viewModel
        }

        func pageController(at index: Int) -> UIViewController {
            let item = store.items[index]
            if let existing = controllers[item.streamId] { return existing }
            let host = UIHostingController(rootView: FeedVideoPage(
                streamId: item.streamId,
                video: item.video,
                store: store,
                viewModel: viewModel,
                onNextVideo: { [weak self] in
                    self?.skipForward(from: item.streamId)
                }
            ))
            host.view.backgroundColor = .black
            controllers[item.streamId] = host
            return host
        }

        private func index(of vc: UIViewController) -> Int? {
            guard let host = vc as? UIHostingController<FeedVideoPage> else { return nil }
            let streamId = host.rootView.streamId
            return store.items.firstIndex { $0.streamId == streamId }
        }

        // MARK: UIPageViewControllerDataSource

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let i = index(of: viewController), i > 0 else { return nil }
            return pageController(at: i - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let i = index(of: viewController) else { return nil }
            store.appendNextIfNeeded(near: i)
            guard i + 1 < store.items.count else { return nil }
            return pageController(at: i + 1)
        }

        // MARK: UIPageViewControllerDelegate

        /// Fires when the drag crosses the midpoint: the new page becomes
        /// active while the old one keeps playing until then.
        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            guard let i = pendingViewControllers.first.flatMap(index(of:)) else { return }
            store.activeStreamId = store.items[i].streamId
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard let current = pageViewController.viewControllers?.first,
                  let i = index(of: current) else { return }
            store.activeStreamId = store.items[i].streamId
            evictFarPages(keeping: i)
        }

        /// Pages beyond current ±1 hold players the feed will never reuse
        /// soon; release them so memory stays bounded.
        private func evictFarPages(keeping current: Int) {
            let keep = controllers.keys.filter { id in
                guard let i = store.items.firstIndex(where: { $0.streamId == id }) else { return false }
                return abs(i - current) <= 1
            }
            controllers = controllers.filter { keep.contains($0.key) }
        }

        // MARK: Skip

        func skipForward(from streamId: Int64) {
            guard let i = store.items.firstIndex(where: { $0.streamId == streamId }) else { return }
            store.appendNextIfNeeded(near: i)
            guard i + 1 < store.items.count else { return }
            let next = store.items[i + 1]
            pager?.setViewControllers(
                [pageController(at: i + 1)], direction: .forward, animated: true
            )
            store.activeStreamId = next.streamId
        }
    }
}
#endif
