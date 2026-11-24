import UIKit

@MainActor
final class ReaderContainerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private var pages: [MangaPage] = []
    private var groups: [PageGroup] = []
    private var chapter: Chapter?
    private var pipeline: ImagePipeline?
    private var preferences = ReaderPreferences()
    private var changed: ((Int) -> Void)?
    private var tapped: ((CGFloat) -> Void)?
    private var dimensions: ((Int, Double) -> Void)?
    private var pager: UIPageViewController?
    private var collection: UICollectionView?
    private var current = 0
    private var configurationKey = ""
    private var ratios: [Int: Double] = [:]
    private var turning = false
    private var rebuilding = false
    private var pendingUpdate: ((Int) -> Void)?
    private var lastViewport = CGSize.zero
    override func loadView() { view = UIView(); view.backgroundColor = .black }
    /// Guided view: the next or previous panel on the page showing now. False means turn the page.
    func stepPanel(forward: Bool) -> Bool {
        guard !turning, let displayed = pager?.viewControllers?.first as? PageCanvasController else { return false }
        return displayed.stepPanel(forward: forward)
    }
    func configure(pages: [MangaPage], groups: [PageGroup], chapter: Chapter, pipeline: ImagePipeline,
                   preferences: ReaderPreferences, page: Int, changed: @escaping (Int) -> Void,
                   tap: @escaping (CGFloat) -> Void, dimensions: @escaping (Int, Double) -> Void) {
        loadViewIfNeeded()
        self.changed = changed; tapped = tap; self.dimensions = dimensions
        let key = "\(chapter.id)|\(preferences.mode)|\(preferences.transition)|\(preferences.direction)|\(preferences.advanceOnLeftSwipe)|\(preferences.fit)|\(preferences.doubleTapZoom)|\(preferences.trimMargins ?? true)|\(preferences.quality?.rawValue ?? "auto")|\(preferences.verticalGap ?? false)|\(preferences.enhance ?? false)|\(preferences.guided ?? false)|\(groups.map(\.indices))"
        // Freeze the presented data source until UIKit completes the interactive turn.
        // A late image size or a resize can otherwise change group indices mid-gesture.
        if turning {
            let requestedPage = page != current || self.chapter?.id != chapter.id ? page : nil
            pendingUpdate = { [weak self] landed in
                guard let self else { return }
                let target = requestedPage ?? landed
                self.configure(pages: pages, groups: groups, chapter: chapter, pipeline: pipeline,
                               preferences: preferences, page: target, changed: changed, tap: tap, dimensions: dimensions)
                changed(target)
            }
            return
        }
        if self.chapter?.id != chapter.id { ratios.removeAll() }
        self.pages = pages; self.groups = groups; self.chapter = chapter; self.pipeline = pipeline; self.preferences = preferences
        let target = min(max(0, page), max(0, pages.count - 1))
        if configurationKey != key {
            configurationKey = key; current = target; rebuild()
        } else if current != target {
            current = target
            if let pager, let index = groups.firstIndex(where: { $0.indices.contains(target) }),
               let displayed = pager.viewControllers?.first as? PageCanvasController, displayed.groupIndex != index {
                let forward = index > displayed.groupIndex
                let dir: UIPageViewController.NavigationDirection = forward == preferences.advanceOnLeftSwipe ? .forward : .reverse
                // Taps on the page edges turn one page with the usual animation; longer jumps
                // (slider, chapter change) are instantaneous.
                let adjacent = abs(index - displayed.groupIndex) == 1 && !UIAccessibility.isReduceMotionEnabled
                if adjacent {
                    turning = true
                    pager.setViewControllers([canvas(index)], direction: dir, animated: true) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.turning = false
                            if let pending = self.pendingUpdate { self.pendingUpdate = nil; pending(self.current) }
                        }
                    }
                } else {
                    pager.setViewControllers([canvas(index)], direction: dir, animated: false)
                }
            }
            if let collection, !collection.isDragging, !collection.isDecelerating,
               collection.numberOfItems(inSection: 0) > target {
                collection.scrollToItem(at: IndexPath(item: target, section: 0), at: .top, animated: false)
            }
        }
    }
    private func rebuild() {
        stopAutoScroll(notify: true)
        rebuilding = true
        defer { rebuilding = false }
        if let pager {
            pager.willMove(toParent: nil); pager.view.removeFromSuperview(); pager.removeFromParent()
        }
        pager?.dataSource = nil
        pager?.delegate = nil
        pager = nil
        collection?.removeFromSuperview(); collection = nil
        guard !pages.isEmpty else { return }
        if preferences.mode == .vertical {
            let layout = UICollectionViewFlowLayout()
            // Webtoon strips are drawn as one continuous image: no gap unless asked for.
            layout.minimumLineSpacing = (preferences.verticalGap ?? false) ? 6 : 0; layout.minimumInteritemSpacing = 0
            layout.sectionInset = .zero
            let list = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
            list.backgroundColor = .black; list.dataSource = self; list.delegate = self
            list.contentInsetAdjustmentBehavior = .never
            list.register(VerticalPageCell.self, forCellWithReuseIdentifier: "page")
            list.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(list); collection = list
            list.reloadData(); list.layoutIfNeeded()
            list.scrollToItem(at: IndexPath(item: current, section: 0), at: .top, animated: false)
        } else {
            let style: UIPageViewController.TransitionStyle = preferences.transition == .curl && !UIAccessibility.isReduceMotionEnabled ? .pageCurl : .scroll
            let spine: UIPageViewController.SpineLocation = preferences.advanceOnLeftSwipe ? .min : .max
            let options: [UIPageViewController.OptionsKey: Any]? = style == .pageCurl
                ? [.spineLocation: NSNumber(value: spine.rawValue)] : nil
            let controller = UIPageViewController(transitionStyle: style, navigationOrientation: .horizontal, options: options)
            controller.view.semanticContentAttribute = .forceLeftToRight
            controller.isDoubleSided = false; controller.dataSource = self; controller.delegate = self
            // The first page goes in before the pager is on screen (a page curl with no pages throws).
            let index = groups.firstIndex(where: { $0.indices.contains(current) }) ?? 0
            controller.setViewControllers([canvas(index)], direction: .forward, animated: false)
            addChild(controller); controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view); controller.didMove(toParent: self); pager = controller
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size != lastViewport, size.width > 0, size.height > 0 else { return }
        lastViewport = size
        guard let collection, !pages.isEmpty else { return }
        collection.collectionViewLayout.invalidateLayout()
        collection.layoutIfNeeded()
        if !collection.isDragging && !collection.isDecelerating {
            collection.scrollToItem(at: IndexPath(item: current, section: 0), at: .top, animated: false)
        }
    }
    private func canvas(_ index: Int) -> PageCanvasController {
        let chapterID = chapter?.id
        return PageCanvasController(groupIndex: index, group: groups[index], pages: pages, chapter: chapter!, pipeline: pipeline!,
            preferences: preferences, tap: { [weak self] x in self?.tapped?(x) },
            dimensions: { [weak self] index, ratio in
                // Never mutate SwiftUI state synchronously during a representable update.
                Task { @MainActor [weak self] in
                    guard let self, self.chapter?.id == chapterID, self.pages.indices.contains(index) else { return }
                    self.dimensions?(index, ratio)
                }
            })
    }
    private func adjacent(_ viewController: UIViewController, swipeLeft: Bool) -> UIViewController? {
        guard let vc = viewController as? PageCanvasController,
              let next = ReadingOrder.destination(current: vc.groupIndex, count: groups.count,
                  swipeLeft: swipeLeft, advanceOnLeft: preferences.advanceOnLeftSwipe) else { return nil }
        return canvas(next)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        adjacent(viewController, swipeLeft: false)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        adjacent(viewController, swipeLeft: true)
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { turning = true }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === pager else { return }
        turning = false
        if completed, let visible = pageViewController.viewControllers?.first as? PageCanvasController {
            current = visible.group.id
        }
        if let update = pendingUpdate {
            pendingUpdate = nil
            update(current)
        } else if completed {
            changed?(current)
        }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { pages.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! VerticalPageCell
        var fit = preferences; fit.fit = .width // Cell has the page's aspect ratio; fill its width edge to edge.
        let index = indexPath.item
        cell.canvas.tapped = { [weak self] x in self?.tapped?(x) }
        cell.canvas.configure(page: pages[index], index: index, chapter: chapter!, pipeline: pipeline!, preferences: fit) { [weak self, weak collectionView] i, ratio in
            guard let self, collectionView === self.collection, pages.indices.contains(i) else { return }
            if ratios[i] != ratio {
                ratios[i] = ratio
                // Keep the current reading position anchored after correcting estimated heights.
                let anchor = current
                collectionView?.collectionViewLayout.invalidateLayout()
                if collectionView?.isDragging == false && collectionView?.isDecelerating == false {
                    collectionView?.layoutIfNeeded()
                    collectionView?.scrollToItem(at: IndexPath(item: anchor, section: 0), at: .top, animated: false)
                }
            }
            dimensions?(i, ratio)
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let index = indexPath.item
        let ratio = ratios[index] ?? {
            if let w = pages[index].width, let h = pages[index].height, h > 0 { return w / h }
            return 0.707
        }()
        let width = max(1, collectionView.bounds.width)
        // Round down to whole device pixels: the art then overfills by under a pixel (clipped)
        // instead of leaving a hairline of background between strips.
        let scale = max(1, collectionView.traitCollection.displayScale)
        return CGSize(width: width, height: max(1, ((width / max(0.05, ratio)) * scale).rounded(.down) / scale))
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? VerticalPageCell)?.canvas.cancel()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !rebuilding, let collection, scrollView === collection,
              scrollView.isDragging || scrollView.isDecelerating || autoLink != nil else { return }
        if collection.contentOffset.y + collection.bounds.height >= collection.contentSize.height - 1 {
            let last = max(0, pages.count - 1)
            if last != current { current = last; changed?(current) }
            return
        }
        let point = CGPoint(x: collection.bounds.midX, y: collection.contentOffset.y + 50)
        if let path = collection.indexPathForItem(at: point), path.item != current {
            current = path.item; changed?(current)
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A finger on the strip takes over from auto-scroll.
        if autoLink != nil { stopAutoScroll(notify: true) }
    }

    // MARK: Auto-scroll (vertical strips)

    private var autoLink: CADisplayLink?
    private var autoSpeed: CGFloat = 0
    private var lastTick: CFTimeInterval = 0
    /// Called when auto-scroll stops on its own (end of chapter, or the reader touched the strip).
    var autoScrollStopped: (() -> Void)?
    var isAutoScrolling: Bool { autoLink != nil }
    /// Scrolls the strip at `pointsPerSecond`; nil stops.
    func setAutoScroll(_ pointsPerSecond: Double?) {
        stopAutoScroll(notify: false)
        guard let pointsPerSecond, pointsPerSecond > 0, collection != nil else { return }
        autoSpeed = CGFloat(pointsPerSecond)
        lastTick = 0
        let link = CADisplayLink(target: self, selector: #selector(autoStep(_:)))
        link.add(to: .main, forMode: .common)
        autoLink = link
    }
    private func stopAutoScroll(notify: Bool) {
        guard autoLink != nil else { return }
        autoLink?.invalidate()
        autoLink = nil
        if notify { autoScrollStopped?() }
    }
    @objc private func autoStep(_ link: CADisplayLink) {
        guard let collection, collection.window != nil else { stopAutoScroll(notify: true); return }
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.1, now - lastTick)
        lastTick = now
        let end = max(0, collection.contentSize.height - collection.bounds.height)
        let next = min(end, collection.contentOffset.y + autoSpeed * CGFloat(dt))
        collection.contentOffset = CGPoint(x: collection.contentOffset.x, y: next)
        if next >= end - 0.5 { stopAutoScroll(notify: true) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopAutoScroll(notify: true)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Decoded images are owned only by active/reusable views, never a chapter array.
        collection?.visibleCells.forEach { ($0 as? VerticalPageCell)?.canvas.setNeedsLayout() }
        if let pager {
            for child in pager.children {
                if child !== pager.viewControllers?.first { (child as? PageCanvasController)?.releaseImages() }
            }
        }
    }
}

@MainActor
private final class VerticalPageCell: UICollectionViewCell {
    let canvas = ZoomPageView(frame: .zero)
    override init(frame: CGRect) {
        super.init(frame: frame); contentView.addSubview(canvas)
        clipsToBounds = true; contentView.clipsToBounds = true
        backgroundColor = .black; canvas.seamless = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); canvas.frame = contentView.bounds }
    override func prepareForReuse() { super.prepareForReuse(); canvas.cancel() }
}
