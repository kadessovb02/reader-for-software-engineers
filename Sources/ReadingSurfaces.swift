import SwiftUI
import AppKit
import WebKit
import PDFKit

struct BookWebView: NSViewRepresentable {
    @ObservedObject var store: ReaderStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(context.coordinator, name: "reading")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = true
        context.coordinator.web = view
        bindReadingCallbacks(view, coordinator: context.coordinator)
        return view
    }
    private func bindReadingCallbacks(_ view: WKWebView, coordinator: Coordinator) {
        store.captureContext = { [weak coordinator] in await coordinator?.capture() }
        store.onSearch = { [weak view] query, backwards in
            let value = Self.json(query)
            view?.evaluateJavaScript("window.find(\(value),false,\(backwards),true,false,false,false)")
        }
        store.onScroll = { [weak view] progress in view?.evaluateJavaScript("window.readerRestore(\(progress))") }
        store.onReadingKey = { [weak view, weak store] action in
            guard let view, let store else { return }
            let bookID = store.selectedID
            let token = store.renderToken
            view.evaluateJavaScript("window.readerStep(\(action.direction),\(action.movesPage))") { result, _ in
                guard action.movesPage, result as? Bool == false else { return }
                Task { @MainActor in
                    guard store.selectedID == bookID, store.renderToken == token,
                          let book = store.book, let content = store.content else { return }
                    let chapter = book.chapter + action.direction
                    guard content.chapters.indices.contains(chapter) else { return }
                    store.goChapter(chapter)
                    store.readingProgress(action.direction < 0 ? 1 : 0)
                }
            }
        }
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        guard let chapter = store.chapter else { return }
        bindReadingCallbacks(view, coordinator: c)
        if c.token != store.renderToken {
            c.token = store.renderToken
            c.bookID = store.selectedID
            c.restoreProgress = store.book?.progress ?? 0
            c.style = style
            let base = chapter.basePath.map { "<base href=\"\(Self.attribute(URL(fileURLWithPath: $0, isDirectory: true).absoluteString))\">" } ?? ""
            let html = """
            <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; font-src file: data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'">
            \(base)<style id="reader-style">\(style)</style></head><body><main id="reading-content">\(chapter.html)</main></body></html>
            """
            let folder = store.folder(store.selectedID)
            let url = folder.appendingPathComponent("reader.html")
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
                view.loadFileURL(url, allowingReadAccessTo: folder)
            } catch { store.error = "Не удалось подготовить страницу: \(error.localizedDescription)" }
        } else if c.style != style {
            c.style = style
            view.evaluateJavaScript("(()=>{let p=window.readerProgress();document.getElementById('reader-style').textContent=\(Self.json(style));requestAnimationFrame(()=>window.readerRestore(p));})()")
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reading")
        view.navigationDelegate = nil
    }
    var style: String {
        """
        :root{color-scheme:\(store.theme == .dark ? "dark" : "light");--canvas:\(store.theme.cssBackground);--paper:\(store.theme.cssPage);--ink:\(store.theme.cssInk)}
        *{box-sizing:border-box}html{background:var(--canvas);color:var(--ink);scroll-behavior:auto}body{margin:0;background:var(--canvas)!important;color:var(--ink)!important}
        #reading-content{max-width:740px;margin:0 auto;padding:90px 54px 100px;font-family:\(store.serif ? "'Iowan Old Style','Palatino','Georgia',serif" : "-apple-system,BlinkMacSystemFont,sans-serif");font-size:\(store.fontSize)px;line-height:\(store.lineHeight);overflow-wrap:break-word;font-optical-sizing:auto}
        h1,h2,h3,h4{font-family:-apple-system,BlinkMacSystemFont,sans-serif;line-height:1.22;font-weight:550;color:var(--ink);text-align:left!important}h1{font-size:2.1em;letter-spacing:-.045em;margin:.35em 0 .65em}h2{font-size:1.25em;letter-spacing:-.025em;margin:2em 0 .75em}h3{font-size:1.07em;margin:1.6em 0 .6em}p{margin:0 0 1.05em}img,svg,video{max-width:100%;height:auto}table{font-size:.8em;border-collapse:collapse;max-width:100%;display:block;overflow:auto}td,th{padding:8px;border:1px solid #8885}a{color:#68866d;text-underline-offset:3px}pre{font:0.76em/1.65 ui-monospace,monospace;background:#8881;padding:20px;overflow:auto;border-radius:8px}code{font-size:.8em}blockquote{margin:1.5em 0;padding-left:1.2em;border-left:2px solid #79917b;color:var(--ink);opacity:.82}hr{border:0;border-top:1px solid #8884;margin:2.1em 0}.eyebrow{font:500 10px/1.5 -apple-system,sans-serif;letter-spacing:.18em;color:#7b8a76;margin-bottom:24px}.lead{font-size:1.15em;color:#7a8178;line-height:1.55;margin-bottom:1.8em}::selection{background:#aec5a780}
        @media(max-width:520px){#reading-content{padding:70px 27px 80px;font-size:\(max(15, store.fontSize - 2))px}h1{font-size:1.8em}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
        \(store.theme == .paper ? """
        #reading-content{max-width:min(740px,calc(100% - 48px));min-height:calc(100vh - 112px);margin:78px auto 34px;padding:52px 54px 66px;background:var(--paper);border:1px solid #c9bda980;box-shadow:0 2px 4px #453b2b0c,0 10px 28px #453b2b12}
        @media(max-width:520px){#reading-content{max-width:calc(100% - 28px);margin:74px auto 28px;padding:36px 27px 48px}}
        @media(prefers-contrast:more){#reading-content{border-color:#9f927d}}
        """ : "")
        """
    }
    static func json(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let result = String(data: data, encoding: .utf8) else { return "\"\"" }
        return result
    }
    static func attribute(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") }
    static let script = """
    (()=>{
      let timer;window.readerReady=false;
      window.readerProgress=()=>Math.max(0,Math.min(1,window.scrollY/Math.max(1,document.documentElement.scrollHeight-innerHeight)));
      window.readerRestore=p=>{scrollTo(0,p*Math.max(0,document.documentElement.scrollHeight-innerHeight));};
      window.readerStep=(direction,page)=>{
        const before=scrollY,max=Math.max(0,document.documentElement.scrollHeight-innerHeight);
        const step=page?Math.max(120,innerHeight-112):56;
        scrollTo(0,Math.max(0,Math.min(max,before+direction*step)));
        if(window.readerReady)window.webkit.messageHandlers.reading.postMessage(window.readerCapture());
        return Math.abs(scrollY-before)>.5;
      };
      window.readerCapture=()=>{
        const root=document.getElementById('reading-content');if(!root)return {};
        const parts=[];for(const el of root.querySelectorAll('p,h1,h2,h3,h4,pre,li,td,blockquote')){const r=el.getBoundingClientRect();if(r.bottom>15&&r.top<innerHeight-15){if(!el.querySelector('p,li,td'))parts.push(el.innerText)}}
        let heading='';for(const h of root.querySelectorAll('h1,h2,h3')){if(h.getBoundingClientRect().top<innerHeight*.48)heading=h.textContent.trim();}
        return {progress:window.readerProgress(),text:parts.join('\\n\\n').slice(0,18000),selection:getSelection()?.toString().slice(0,12000)||'',heading};
      };
      const send=()=>{if(window.readerReady)window.webkit.messageHandlers.reading.postMessage(window.readerCapture());};
      addEventListener('scroll',()=>{clearTimeout(timer);timer=setTimeout(send,160)},{passive:true});
      document.addEventListener('selectionchange',()=>{clearTimeout(timer);timer=setTimeout(send,120)});
      addEventListener('resize',()=>{clearTimeout(timer);timer=setTimeout(send,180)});
    })();
    """
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let store: ReaderStore; weak var web: WKWebView?
        var token: UUID?; var bookID = ""; var style = ""; var restoreProgress: Double = 0
        init(store: ReaderStore) { self.store = store }
        func accept(_ payload: Any) {
            guard bookID == store.selectedID, let data = payload as? [String: Any] else { return }
            if let p = data["progress"] as? Double { store.readingProgress(p) }
            store.visibleText = data["text"] as? String ?? ""
            store.selection = data["selection"] as? String ?? ""
            store.currentHeading = data["heading"] as? String ?? ""
        }
        func capture() async {
            guard let web, let data = try? await web.evaluateJavaScript("window.readerCapture()") else { return }
            accept(data)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { accept(message.body) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.readerRestore(\(restoreProgress));window.readerReady=true;window.webkit.messageHandlers.reading.postMessage(window.readerCapture());")
            if bookID == store.selectedID, let quote = store.pendingPracticeSearch { store.pendingPracticeSearch = nil; store.onSearch?(quote, false) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                else if let url = navigationAction.request.url, let fragment = url.fragment { webView.evaluateJavaScript("document.getElementById(\(BookWebView.json(fragment)))?.scrollIntoView()") }
                decisionHandler(.cancel); return
            }
            decisionHandler(navigationAction.request.url?.isFileURL == true || navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}

final class ResizingPDFView: PDFView {
    private var resizeWork: DispatchWorkItem?
    private var pendingDestination: PDFDestination?
    private var restoringDocument = true
    private let paperAppearance = PDFPaperAppearance()
    private(set) var readingTheme: PaperTheme?

    func applyReadingTheme(_ theme: PaperTheme) {
        backgroundColor = theme.nsBackground
        paperAppearance.apply(to: self, theme: theme)
        guard readingTheme != theme else { return }
        let paperLayoutChanged = (readingTheme == .paper) != (theme == .paper)
        readingTheme = theme
        guard paperLayoutChanged else { return }

        let destination = pendingDestination ?? currentDestination.flatMap { value in
            value.page.map { PDFDestination(page: $0, at: value.point) }
        }
        let previousScale = scaleFactor
        let wasRestoring = restoringDocument
        restoringDocument = true
        pageBreakMargins = theme == .paper
            ? NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
            : NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        if document != nil, !wasRestoring {
            layoutSubtreeIfNeeded()
            layoutDocumentView()
            scaleFactor = previousScale
            if let destination { go(to: destination) }
        }
        restoringDocument = wasRestoring
    }

    func navigateReading(_ action: ReaderKeyAction) {
        guard let document else { return }
        if action.movesPage {
            guard let page = currentDestination?.page ?? currentPage else { return }
            let index = document.index(for: page) + action.direction
            guard index >= 0, index < document.pageCount, let target = document.page(at: index) else { return }
            let bounds = target.bounds(for: .cropBox)
            go(to: PDFDestination(page: target, at: NSPoint(x: bounds.minX, y: bounds.maxY)))
        } else if let scroll = subviews.compactMap({ $0 as? NSScrollView }).first {
            let clip = scroll.contentView
            let direction = scroll.documentView?.isFlipped == false ? -action.direction : action.direction
            var target = clip.bounds
            target.origin.y += CGFloat(direction) * 56
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
    func beginDocumentRestore() {
        restoringDocument = true; resizeWork?.cancel(); pendingDestination = nil
    }
    func finishDocumentRestore(_ destination: PDFDestination) {
        autoScales = false
        layoutSubtreeIfNeeded(); layoutDocumentView()
        scaleFactor = scaleFactorForSizeToFit
        go(to: destination)
        restoringDocument = false
    }
    private func prepareResize(to size: NSSize) {
        if !restoringDocument && (abs(frame.width - size.width) > 1 || abs(frame.height - size.height) > 1) && pendingDestination == nil, let destination = currentDestination, let page = destination.page {
            pendingDestination = PDFDestination(page: page, at: destination.point)
        }
    }
    private func scheduleResize() {
        guard !restoringDocument, pendingDestination != nil, document != nil else { return }
        resizeWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layoutDocumentView()
            self.scaleFactor = self.scaleFactorForSizeToFit
            if let destination = self.pendingDestination { self.go(to: destination) }
            self.pendingDestination = nil
        }
        resizeWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }
    override var frame: NSRect {
        willSet { prepareResize(to: newValue.size) }
        didSet { scheduleResize() }
    }
    override func setFrameSize(_ newSize: NSSize) {
        prepareResize(to: newSize)
        super.setFrameSize(newSize)
        scheduleResize()
    }
}

struct BookPDFView: NSViewRepresentable {
    @ObservedObject var store: ReaderStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> PDFView {
        let view = ResizingPDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        context.coordinator.view = view
        context.coordinator.observe()
        bindReadingCallbacks(view, coordinator: context.coordinator)
        return view
    }
    private func bindReadingCallbacks(_ view: PDFView, coordinator: Coordinator) {
        store.captureContext = { [weak coordinator] in coordinator?.capture() }
        store.onSearch = { [weak coordinator] text, backwards in coordinator?.search(text, backwards: backwards) }
        store.onRevealPracticePDF = { [weak coordinator] page, phrase in coordinator?.revealPractice(page: page, phrase: phrase) }
        store.focusedPDFPage = { [weak view] in
            guard let view, let document = view.document, let page = view.page(for: NSPoint(x: view.bounds.midX, y: view.bounds.midY), nearest: true) ?? view.currentPage else { return nil }
            let index = document.index(for: page); return index == NSNotFound ? nil : index
        }
        store.onScroll = { [weak view] progress in
            guard let doc = view?.document, let page = doc.page(at: min(doc.pageCount - 1, max(0, Int((progress * Double(doc.pageCount)).rounded())))) else { return }; view?.go(to: page)
        }
        store.onReadingKey = { [weak view] action in (view as? ResizingPDFView)?.navigateReading(action) }
    }
    func updateNSView(_ view: PDFView, context: Context) {
        guard let doc = store.pdfDocument else { return }
        let coordinator = context.coordinator
        bindReadingCallbacks(view, coordinator: coordinator)
        if view.document !== doc {
            coordinator.restoring = true
            coordinator.headingCache.removeAll()
            (view as? ResizingPDFView)?.beginDocumentRestore()
            (view as? ResizingPDFView)?.applyReadingTheme(store.theme)
            view.document = doc
            if let page = doc.page(at: min(max(0, store.book?.page ?? 0), doc.pageCount - 1)) {
                let offset = store.book?.pageOffset ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard view.document === doc else { return }
                    let bounds = page.bounds(for: .cropBox)
                    let destination = PDFDestination(page: page, at: NSPoint(x: bounds.minX, y: bounds.maxY - offset))
                    if let resizing = view as? ResizingPDFView { resizing.finishDocumentRestore(destination) } else { view.go(to: destination) }
                    context.coordinator.restoring = false; context.coordinator.capture()
                    context.coordinator.observeScroll()
                }
            }
        } else if let resizing = view as? ResizingPDFView, resizing.readingTheme != store.theme {
            let wasRestoring = coordinator.restoring
            coordinator.restoring = true
            coordinator.work?.cancel()
            resizing.applyReadingTheme(store.theme)
            coordinator.restoring = wasRestoring
        }
    }
    @MainActor final class Coordinator: NSObject {
        let store: ReaderStore; weak var view: PDFView?
        var observers: [NSObjectProtocol] = []; var scrollObserver: NSObjectProtocol?
        var work: DispatchWorkItem?; var restoring = false; var lastSearch = ""; var searchSelection: PDFSelection?
        init(store: ReaderStore) { self.store = store }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }; work?.cancel() }
        func observe() {
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewSelectionChanged] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.queueCapture() }
                })
            }
        }
        func observeScroll() {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            guard let scroll = view?.subviews.compactMap({ $0 as? NSScrollView }).first else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queueCapture() }
            }
        }
        func queueCapture() {
            work?.cancel(); let item = DispatchWorkItem { [weak self] in self?.capture() }; work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }
        func capture() {
            guard !restoring, let view, let document = view.document, document === store.pdfDocument, let destination = view.currentDestination, let page = destination.page else { return }
            let point = destination.point
            let offset = max(0, page.bounds(for: .cropBox).maxY - point.y)
            let index = document.index(for: page)
            store.updateBook { $0.page = index; $0.pageOffset = offset }
            store.selection = view.currentSelection?.string ?? ""
            store.visibleText = view.visiblePages.prefix(4).compactMap { p in
                let rect = view.convert(view.bounds, to: p).intersection(p.bounds(for: .cropBox))
                return p.selection(for: rect)?.string
            }.joined(separator: "\n\n")
            store.currentHeading = outlineTitle(document.outlineRoot, pageIndex: index, document: document) ?? (store.book?.isSample == true && index >= 3 ? "Глава 1 · Надёжные, масштабируемые и удобные в сопровождении приложения" : detectedHeading(document, pageIndex: index) ?? "Страница \(index + 1)")
        }
        var headingCache: [Int: String] = [:]
        func detectedHeading(_ document: PDFDocument, pageIndex: Int) -> String? {
            if let cached = headingCache[pageIndex] { return cached.isEmpty ? nil : cached }
            for index in stride(from: pageIndex, through: max(0, pageIndex - 12), by: -1) {
                let lines = (document.page(at: index)?.string ?? "").components(separatedBy: .newlines).prefix(6)
                for line in lines {
                    if let range = line.range(of: "(?i)^(глава|chapter)\\s+[0-9IVXLC]+(?:\\s|[.:]|$)", options: .regularExpression) {
                        let value = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        headingCache[pageIndex] = value; return value
                    }
                }
            }
            headingCache[pageIndex] = ""; return nil
        }
        func outlineTitle(_ outline: PDFOutline?, pageIndex: Int, document: PDFDocument) -> String? {
            guard let outline else { return nil }; var best: String?
            for i in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: i), let page = child.destination?.page else { continue }
                if document.index(for: page) <= pageIndex { best = outlineTitle(child, pageIndex: pageIndex, document: document) ?? child.label }
            }
            return best
        }
        func search(_ text: String, backwards: Bool) {
            guard let view, let doc = view.document, !text.isEmpty else { return }
            if text != lastSearch { searchSelection = nil }; lastSearch = text
            var options: NSString.CompareOptions = [.caseInsensitive]; if backwards { options.insert(.backwards) }
            let result = doc.findString(text, fromSelection: searchSelection, withOptions: options) ?? doc.findString(text, fromSelection: nil, withOptions: options)
            searchSelection = result
            view.setCurrentSelection(result, animate: true); if let result { view.go(to: result) }
        }
        func revealPractice(page index: Int, phrase: String) {
            guard let view, let document = view.document, let page = document.page(at: index) else { return }
            view.go(to: page)
            if !phrase.isEmpty, let range = PracticeEvidence.selectionRange(for: phrase, in: page.string ?? ""), let match = page.selection(for: range) {
                view.setCurrentSelection(match, animate: true); view.go(to: match)
            }
            capture()
        }
    }
}
