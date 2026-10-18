import SwiftUI
import PDFKit
import UniformTypeIdentifiers

let leafAccent = Color(red: 0.31, green: 0.42, blue: 0.33)
struct ToolButton: View {
    let icon: String; let title: String; var active = false; let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 14, weight: .regular)).frame(width: 30, height: 30).foregroundStyle(active ? leafAccent : .secondary).background(active ? leafAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct ReaderRootView: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var ai: CodexService
    @State var hoveringTop = false
    @State var hoveringBottom = false
    @State var appearanceVisible = false
    @State var dragTarget = false
    @State private var showingArchive = false
    @State private var pendingDeletion: BookRecord?
    @FocusState var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var controlsVisible: Bool { !store.focus || hoveringTop || store.libraryVisible }
    var body: some View {
        HStack(spacing: 0) {
            if store.libraryVisible { library.frame(width: store.compact ? 230 : 260).transition(.move(edge: .leading).combined(with: .opacity)) }
            ZStack {
                store.theme.background
                if store.isLoading {
                    VStack(spacing: 16) { ProgressView().controlSize(.small); Text("Открываем книгу…").font(.system(size: 12)).foregroundStyle(.secondary) }
                } else if store.pdfDocument != nil { BookPDFView(store: store).padding(.top, store.focus ? 0 : 58).padding(.bottom, store.focus ? 0 : 40) }
                else if store.chapter != nil { BookWebView(store: store) }
                else { welcome }
                VStack(spacing: 0) {
                    toolbar.opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible)
                    Color.clear.frame(height: 10).contentShape(Rectangle()).onHover { hoveringTop = $0 }
                    Spacer()
                    footer.opacity(!store.focus || hoveringBottom ? 1 : 0).allowsHitTesting(!store.focus || hoveringBottom)
                }
                VStack { Color.clear.frame(height: 58).contentShape(Rectangle()).onHover { hoveringTop = $0 }; Spacer(); Color.clear.frame(height: 42).contentShape(Rectangle()).onHover { hoveringBottom = $0 } }.allowsHitTesting(store.focus && !hoveringTop && !hoveringBottom)
                if store.searchVisible { VStack { searchBar.padding(.top, 56).padding(.horizontal, 18); Spacer() } }
                if dragTarget { RoundedRectangle(cornerRadius: 10).stroke(leafAccent, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(12).background(leafAccent.opacity(0.06)).allowsHitTesting(false) }
            }
        }
        .foregroundStyle(store.theme.ink)
        .tint(leafAccent)
        .preferredColorScheme(store.theme == .dark ? .dark : .light)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.libraryVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: controlsVisible)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dragTarget) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in guard let url else { return }; Task { @MainActor in await store.importBook(url) } }
            return true
        }
        .alert("Не получилось", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("Удалить книгу из библиотеки?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("Переместить в Корзину", role: .destructive) {
                if let book = pendingDeletion { store.deleteBook(book.id) }
                pendingDeletion = nil
            }
            Button("Отмена", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("«\(pendingDeletion?.title ?? "")»: копия книги и её данные из библиотеки будут перемещены в Корзину. Исходный файл останется на месте.")
        }
    }
    var toolbar: some View {
        HStack(spacing: store.compact ? 2 : 5) {
            ToolButton(icon: "books.vertical", title: "Библиотека · ⌘L", active: store.libraryVisible) { store.libraryVisible.toggle() }
            if !store.compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.book?.title ?? "Лист").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(store.book?.isSample == true ? "ОЗНАКОМИТЕЛЬНЫЙ ФРАГМЕНТ" : store.book?.author ?? "").font(.system(size: 9)).tracking(store.book?.isSample == true ? 0.7 : 0).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.leading, 6)
            }
            Spacer(minLength: 8)
            ToolButton(icon: "list.bullet", title: "Оглавление", active: store.contentsVisible) { store.contentsVisible.toggle() }
                .popover(isPresented: $store.contentsVisible, arrowEdge: .bottom) { contents.frame(width: 310) }
            Button { appearanceVisible.toggle() } label: { Text("Aa").font(.system(size: 16, design: .serif)).frame(width: 30, height: 30) }.buttonStyle(.plain).help("Вид страницы").accessibilityLabel("Вид страницы")
                .popover(isPresented: $appearanceVisible, arrowEdge: .bottom) { appearance.frame(width: 300).padding(22) }
            if store.pdfDocument != nil { ToolButton(icon: "rotate.right", title: "Развернуть схему · ⌘⇧R") { store.onInspectPage?() } }
            ToolButton(icon: "curlybraces", title: "Практика по прочитанному · ⌘⇧P") { store.onTogglePractice?() }
            if !store.compact { ToolButton(icon: "viewfinder", title: "Режим фокуса · ⌘⇧F", active: store.focus) { store.onToggleFocus?() } }
            ToolButton(icon: store.compact ? "arrow.up.left.and.arrow.down.right" : "pip", title: "Компактный режим · ⌘⇧M", active: store.compact) { store.onToggleCompact?() }
            ToolButton(icon: "bubble.left", title: "Спросить о странице · ⌘J") { store.onToggleChat?() }
        }
        .padding(.leading, store.compact ? 73 : 78).padding(.trailing, 18).frame(height: 58)
        .background(.regularMaterial).onHover { hoveringTop = $0 }
    }
    var footer: some View {
        HStack(spacing: 12) {
            if store.content != nil {
                ToolButton(icon: "chevron.left", title: "Предыдущая глава") { store.goChapter((store.book?.chapter ?? 0) - 1) }.disabled((store.book?.chapter ?? 0) == 0)
            }
            Text(store.chapterTitle.isEmpty ? "ЛИСТ · ПРОСТРАНСТВО ДЛЯ ЧТЕНИЯ" : store.chapterTitle).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if store.content != nil && (store.book?.progress ?? 0) > 0.96 {
                Button("Закрепить прочитанное") { store.onTogglePractice?() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(leafAccent)
            }
            if let book = store.book, book.format != "missing" {
                Text(store.pdfDocument != nil ? "\((store.book?.page ?? 0) + 1) / \(store.pdfDocument?.pageCount ?? 0)" : "\(Int(store.totalProgress * 100)) %").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if store.content != nil {
                ToolButton(icon: "chevron.right", title: "Следующая глава") { store.goChapter((store.book?.chapter ?? 0) + 1) }.disabled((store.book?.chapter ?? 0) >= (store.content?.chapters.count ?? 1) - 1)
            }
        }.padding(.horizontal, 22).frame(height: 40).background(.regularMaterial).onHover { hoveringBottom = $0 }
    }
    var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Библиотека").font(.system(size: 18, weight: .medium)); Spacer(); ToolButton(icon: "plus", title: "Добавить книгу · ⌘O") { store.openPanel() } }.padding(.top, 47).padding(.horizontal, 18).padding(.bottom, 14)
            if !store.archivedBooks.isEmpty || showingArchive {
                HStack {
                    Button {
                        showingArchive.toggle()
                    } label: {
                        Label(showingArchive ? "Книги" : "Архив · \(store.archivedBooks.count)", systemImage: showingArchive ? "books.vertical" : "archivebox")
                            .font(.system(size: 11))
                    }.buttonStyle(.plain).accessibilityLabel(showingArchive ? "Показать книги библиотеки" : "Показать архив, книг: \(store.archivedBooks.count)")
                    Spacer()
                    if showingArchive { Text("Архив").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(showingArchive ? store.archivedBooks : store.activeBooks) { book in libraryRow(book) }
                    if (showingArchive ? store.archivedBooks : store.activeBooks).isEmpty {
                        Text(showingArchive ? "В архиве пока нет книг." : store.books.isEmpty ? "Здесь появятся ваши книги." : "Все книги в архиве.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 10) {
                Button { store.openPanel() } label: { Label("Добавить книгу", systemImage: "plus").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                Text("PDF · EPUB · FB2 · TXT · MD\nHTML · RTF · DOCX").font(.system(size: 9)).foregroundStyle(.tertiary).lineSpacing(4)
                Divider().padding(.vertical, 3)
                Button { store.settingsVisible = true } label: { Label("Настройки", systemImage: "gearshape").font(.system(size: 12)) }.buttonStyle(.plain)
                Button { Task { await store.showGuide() } } label: { Label("Как пользоваться", systemImage: "questionmark.circle").font(.system(size: 12)) }.buttonStyle(.plain)
                Text("⌃⌥Пробел · показать или скрыть").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(20)
        }.background(store.theme == .dark ? Color.white.opacity(0.025) : Color.black.opacity(0.025))
        .sheet(isPresented: $store.settingsVisible) { SettingsView(store: store, ai: ai) }
    }
    func libraryRow(_ book: BookRecord) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Button { store.select(book.id) } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack { RoundedRectangle(cornerRadius: 3).fill(book.id == "guide" ? Color(red: 0.68, green: 0.56, blue: 0.39) : leafAccent); Image(systemName: "book.closed").font(.system(size: 18, weight: .light)).foregroundStyle(.white.opacity(0.7)) }.frame(width: 36, height: 49)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title).font(.system(size: 12, weight: .medium)).lineLimit(3).multilineTextAlignment(.leading)
                        Text(book.author).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Text(book.isSample ? "Фрагмент · PDF" : book.format == "missing" ? "Выберите файл" : book.format.uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                    }; Spacer(minLength: 0)
                }.padding(.vertical, 11).padding(.leading, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu { libraryActions(book) } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 26, height: 28).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.top, 5).padding(.trailing, 4)
                .help("Действия с книгой").accessibilityLabel("Действия с книгой «\(book.title)»")
        }
        .background(book.id == store.selectedID ? leafAccent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contextMenu { libraryActions(book) }
    }
    @ViewBuilder func libraryActions(_ book: BookRecord) -> some View {
        let section = book.isArchived ? store.archivedBooks : store.activeBooks
        Button { store.moveBook(book.id, by: -1) } label: { Label("Выше", systemImage: "arrow.up") }.disabled(section.first?.id == book.id)
        Button { store.moveBook(book.id, by: 1) } label: { Label("Ниже", systemImage: "arrow.down") }.disabled(section.last?.id == book.id)
        Divider()
        Button { store.setArchived(!book.isArchived, for: book.id) } label: { Label(book.isArchived ? "Вернуть из архива" : "В архив", systemImage: book.isArchived ? "arrow.uturn.backward" : "archivebox") }
        Button(role: .destructive) { pendingDeletion = book } label: { Label("Удалить…", systemImage: "trash") }
    }
    var welcome: some View {
        VStack(spacing: 24) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(leafAccent.gradient).shadow(color: .black.opacity(0.13), radius: 18, x: 6, y: 12)
                Rectangle().fill(.black.opacity(0.10)).frame(width: 8).padding(.leading, 6)
                VStack(alignment: .leading, spacing: 14) { Image(systemName: "leaf").font(.system(size: 24, weight: .ultraLight)); Spacer(); Text("ВАША\nБИБЛИОТЕКА").font(.system(size: 10, weight: .medium)).lineSpacing(4); Text("READER FOR ENGINEERS").font(.system(size: 7)).tracking(1) }.foregroundStyle(.white.opacity(0.85)).padding(22)
            }.frame(width: store.compact ? 122 : 154, height: store.compact ? 169 : 212)
            VStack(spacing: 10) { Text("Читайте в своём ритме.").font(.system(size: store.compact ? 22 : 28, weight: .regular, design: .serif)); Text("Добавьте книгу. Лист запомнит,\nгде вы остановились.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4) }
            Button("Выбрать файл книги") { store.openPanel(replacingDefault: store.book?.id == "kleppmann" && store.book?.format == "missing") }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("Попробовать на коротком руководстве") { Task { await store.showGuide() } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(25).padding(.top, 30)
    }
    var contents: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Оглавление").font(.system(size: 17, weight: .medium)).padding(.horizontal, 18).padding(.top, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let content = store.content {
                        ForEach(Array(content.chapters.enumerated()), id: \.offset) { index, chapter in
                            Button { store.goChapter(index) } label: { HStack { Text(chapter.title).font(.system(size: 12)).multilineTextAlignment(.leading); Spacer(); if store.book?.chapter == index { Image(systemName: "checkmark").font(.system(size: 10)) } }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(store.book?.chapter == index ? leafAccent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
                        }
                    } else if let pdf = store.pdfDocument {
                        if let outline = pdf.outlineRoot, outline.numberOfChildren > 0 {
                            ForEach(pdfEntries(outline, pdf: pdf), id: \.page) { entry in Button(entry.title) { store.onScroll?(Double(entry.page) / Double(pdf.pageCount)); store.contentsVisible = false }.buttonStyle(.plain).font(.system(size: 12)).padding(10) }
                        } else { Text("В этом PDF нет оглавления.\nПерейдите к нужной странице:").font(.system(size: 12)).foregroundStyle(.secondary).padding(10) }
                        HStack { Text("Страница"); TextField("", value: Binding(get: { (store.book?.page ?? 0) + 1 }, set: { value in store.onScroll?(Double(min(max(1, value), pdf.pageCount) - 1) / Double(pdf.pageCount)) }), formatter: NumberFormatter()).textFieldStyle(.roundedBorder).frame(width: 60); Text("из \(pdf.pageCount)").foregroundStyle(.secondary) }.font(.system(size: 12)).padding(10)
                    } else { Text("Оглавление появится после добавления книги.").font(.system(size: 12)).foregroundStyle(.secondary).padding(10) }
                }.padding(.horizontal, 8)
            }.frame(maxHeight: 420)
        }.padding(.bottom, 12)
    }
    struct PDFEntry { var title: String; var page: Int }
    func pdfEntries(_ node: PDFOutline, pdf: PDFDocument) -> [PDFEntry] {
        (0..<node.numberOfChildren).compactMap { index in guard let child = node.child(at: index), let page = child.destination?.page else { return nil }; return PDFEntry(title: child.label ?? "Раздел", page: pdf.index(for: page)) }
    }
    var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Вид страницы").font(.system(size: 17, weight: .medium))
            HStack(spacing: 12) {
                ForEach(PaperTheme.allCases, id: \.self) { theme in
                    Button { store.theme = theme } label: {
                        VStack(spacing: 8) {
                            ZStack(alignment: .top) {
                                theme.background
                                VStack(spacing: 7) {
                                    VStack(spacing: 5) {
                                        Text("Аа").font(.system(size: 18, design: .serif))
                                        RoundedRectangle(cornerRadius: 1).fill(theme.ink.opacity(0.28)).frame(width: 25, height: 2)
                                        RoundedRectangle(cornerRadius: 1).fill(theme.ink.opacity(0.2)).frame(width: 21, height: 2)
                                    }
                                    .foregroundStyle(theme.ink)
                                    .frame(width: 48, height: 55)
                                    .background(theme.pageColor, in: RoundedRectangle(cornerRadius: 2))
                                    .shadow(color: .black.opacity(theme == .dark ? 0.22 : 0.12), radius: 2, y: 1)
                                    RoundedRectangle(cornerRadius: 2).fill(theme.pageColor).frame(width: 48, height: 16)
                                }.padding(.top, 9)
                            }
                            .frame(height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.theme == theme ? leafAccent : .gray.opacity(0.2), lineWidth: store.theme == theme ? 2 : 1))
                            Text(theme.title).font(.system(size: 11, weight: store.theme == theme ? .medium : .regular)).foregroundStyle(store.theme == theme ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(theme.title)
                    .accessibilityValue(store.theme == theme ? "Выбрано" : "Не выбрано")
                    .accessibilityAddTraits(.isButton)
                }
            }
            Text("Бумажный режим смягчает белый фон PDF и подчёркивает границы страниц.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if store.pdfDocument == nil {
                HStack { Text("Размер текста"); Spacer(); Text("\(Int(store.fontSize))").monospacedDigit().foregroundStyle(.secondary) }.font(.system(size: 12))
                Slider(value: $store.fontSize, in: 15...32, step: 1)
                Picker("Шрифт", selection: $store.serif) { Text("Книжный").tag(true); Text("Системный").tag(false) }.pickerStyle(.segmented)
                HStack { Text("Интервал").font(.system(size: 12)); Slider(value: $store.lineHeight, in: 1.3...2.1, step: 0.1) }
            } else { Text("PDF сохраняет исходную вёрстку. Масштабируйте страницу жестом трекпада или клавишами ⌘+ и ⌘−.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Button { appearanceVisible = false; store.libraryVisible = true; store.settingsVisible = true } label: { Label("Все настройки", systemImage: "gearshape").font(.system(size: 12)) }.buttonStyle(.plain)
        }
    }
    var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(store.pdfDocument != nil ? "Найти в PDF" : "Найти в этой главе", text: $store.searchQuery).textFieldStyle(.plain).focused($searchFocused).onAppear { searchFocused = true }.onSubmit { store.onSearch?(store.searchQuery, false) }
            Button { store.onSearch?(store.searchQuery, true) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).help("Предыдущее совпадение")
            Button { store.onSearch?(store.searchQuery, false) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).help("Следующее совпадение")
            Button { store.searchVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть поиск")
        }.font(.system(size: 12)).padding(13).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11)).shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

struct SettingsView: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var ai: CodexService
    @StateObject private var practiceSetup = PracticeSetupStatus()
    @State private var copiedCommand = false
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Настройки").font(.system(size: 23, weight: .medium)); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ChatGPT").font(.system(size: 14, weight: .medium))
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(ai.isConnected ? leafAccent : .gray).frame(width: 6, height: 6).padding(.top, 5)
                            Text(ai.status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if ai.isChecking { ProgressView().controlSize(.mini) }
                        }
                        HStack {
                            Button("Войти через ChatGPT") { Task { await ai.login() } }
                                .buttonStyle(.borderedProminent).disabled(ai.isBusy || ai.isChecking || !ai.isCompatible || ai.isConnected)
                            Button("Проверить") { Task { await ai.refreshStatus() } }.disabled(ai.isBusy || ai.isChecking)
                            if ai.isBusy { Button("Отменить") { ai.cancel() } }
                        }
                        if !ai.isCompatible {
                            Text("1. Установите или обновите официальный Codex CLI.\n2. Нажмите «Проверить», затем войдите в свой аккаунт в браузере.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Text(CodexSetup.installCommand).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button(copiedCommand ? "Скопировано" : "Копировать") { CodexSetup.copyInstallCommand(); copiedCommand = true }.font(.system(size: 10))
                            }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                            Link("Инструкция по установке и альтернативы npm", destination: CodexSetup.installationURL).font(.system(size: 11))
                        }
                        DisclosureGroup("Codex CLI \(ai.cliVersion.isEmpty ? "" : "· " + ai.cliVersion)") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(ai.cliPath.isEmpty ? "Исполняемый файл пока не найден" : ai.cliPath)
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                                if !ai.setupDetail.isEmpty { Text(ai.setupDetail).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                                HStack {
                                    Button("Выбрать файл codex…") { Task { await ai.chooseCLI() } }.disabled(ai.isBusy || ai.isChecking)
                                    Button("Автопоиск") { Task { await ai.useAutomaticCLI() } }.disabled(ai.isBusy || ai.isChecking || ai.customCLIPath.isEmpty)
                                }.font(.system(size: 11))
                            }.padding(.top, 7)
                        }.font(.system(size: 11))
                        Text("Авторизация проходит через официальный Codex CLI. Используются доступ и лимиты вашего аккаунта; ключи и токены в «Лист» вводить не нужно.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Link("Подробнее об авторизации", destination: CodexSetup.authenticationURL).font(.system(size: 11))
                        Text("Помощник начинает с текущей страницы. По вопросу ищет во всей текущей главе, затем в книге до вашего места чтения. Нужные фрагменты передаются только вместе с вопросом.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Запуск кода · по желанию").font(.system(size: 14, weight: .medium))
                        Text("Docker Desktop нужен только для выполнения Python, JavaScript и SQLite в изолированной среде. Читать, задавать вопросы и разбирать текстовые решения с ИИ можно без него.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(practiceSetup.isReady ? leafAccent : .gray).frame(width: 6, height: 6).padding(.top, 4)
                            Text(practiceSetup.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Button("Открыть / установить Docker") { practiceSetup.openDocker() }
                            Button("Проверить среду") { Task { await practiceSetup.refresh() } }.disabled(practiceSetup.isChecking)
                            if practiceSetup.isChecking { ProgressView().controlSize(.mini) }
                        }.font(.system(size: 11))
                    }
                    if store.book != nil {
                        Divider()
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Контекст книги").font(.system(size: 14, weight: .medium))
                            Text(store.book?.title ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { store.book?.overview ?? "" }, set: { value in store.updateBook { $0.overview = String(value.prefix(4000)) } })).font(.system(size: 12)).frame(height: 85).padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
                            Text("Кратко: о чём книга, что вы изучаете. Это описание добавляется к каждому вопросу.").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                        shortcut("Показать / скрыть", "⌃⌥Пробел"); shortcut("Чат по странице", "⌘J"); shortcut("Практика", "⌘⇧P"); shortcut("Компактное окно", "⌘⇧M"); shortcut("Режим фокуса", "⌘⇧F"); shortcut("Полный экран", "⌃⌘F"); shortcut("Добавить книгу", "⌘O")
                    }.font(.system(size: 11))
                    Text("Место чтения и история чата сохраняются на этом Mac. Закрытие окна скрывает приложение; ⌘Q завершает его.").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.trailing, 6)
            }
        }.padding(28).frame(width: 540, height: 650).tint(leafAccent).task { await ai.refreshStatus() }
    }
    func shortcut(_ title: String, _ keys: String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(keys).font(.system(size: 11, design: .monospaced)) } }
}
