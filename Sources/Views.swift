import SwiftUI
import AppKit
import QuickLook

// Type alias selects the property wrapper on SDKs that also export a State macro.
typealias SweepViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var model: AppModel
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject private var updates = UpdateChecker.shared
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(L("本机")).foregroundStyle(SweepStyle.secondary)
                    Text(L("/")).foregroundStyle(SweepStyle.secondary.opacity(0.5))
                    Text(L(model.section.rawValue))
                    Spacer()
                    if model.loadingStorageIndex { ProgressView().controlSize(.mini); Text(L("正在整理本机索引")).foregroundStyle(SweepStyle.secondary) }
                    else if model.scanning || model.analyzing {
                        ProgressView().controlSize(.mini)
                        Text(L("扫描中")).foregroundStyle(SweepStyle.secondary)
                    } else {
                        Text(L("文件留在本机")).foregroundStyle(SweepStyle.secondary)
                    }
                    Picker(L("语言"), selection: $language.choice) {
                        ForEach(InterfaceLanguage.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 124).disabled(model.mutating || model.workbench.busy || model.showingReview || model.workbench.showingManagedReview).accessibilityLabel(L("语言"))
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("刷新状态")).disabled(model.sampling)
                }.font(.system(size: 12)).padding(.horizontal, 28).frame(height: 44)
                Divider()
                if model.cleanupJournalFailure != nil && model.section != .history {
                    HStack{Label(L("文件操作已暂停"),systemImage:"exclamationmark.circle");Spacer();Button(L("查看并核对")){model.section = .history}}.font(.system(size:13)).foregroundStyle(SweepStyle.warning).padding(12).background(SweepStyle.surface)
                }
                Group {
                    switch model.section {
                    case .overview: OverviewView()
                    case .results: ResultsView()
                    case .storage: StorageView()
                    case .memory: MemoryView()
                    case .history: HistoryView()
                    case .tools: WorkbenchView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 1120, minHeight: 640).background(SweepStyle.background).tint(SweepStyle.accent).preferredColorScheme(.light)
        .id(language.choice)
        .onChange(of: language.choice) { model.workbench.refreshMemoryMenu(model.snapshot); model.scheduleStorageQuery() }
        .onAppear { let open=openWindow; model.workbench.openMainWindow={open(id:"main")}; updates.checkAutomaticallyIfDue() }
        .alert(L("检查更新"), isPresented: $updates.showingResult) {
            if updates.availableRelease != nil { Button(L("前往发布页")) { updates.openRelease() } }
            Button(L("完成"), role: .cancel) {}
        } message: { Text(L(updates.resultMessage)) }
        .quickLookPreview($model.previewURL)
        .sheet(isPresented: $model.showingReview) { ReviewView() }
        .sheet(item:$model.operationOutcome){OperationOutcomeView(outcome:$0)}
        .sheet(isPresented: $model.showingIssues) { IssueView() }
        .sheet(isPresented: $model.showingStorageIssues) { StorageIssuesView() }
        .sheet(isPresented: $model.showingIgnored) { IgnoredView() }
        .sheet(item: $model.inspecting) { EvidenceView(item: $0).quickLookPreview($model.previewURL) }
        .sheet(item: $model.storageItemDetail) { IndexedStorageDetailView(item: $0).quickLookPreview($model.previewURL) }
        .sheet(isPresented: $model.showingScanChooser) { ScanChooserView() }
        .alert(L("轻扫"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("完成"), role: .cancel) { model.message = nil }
        } message: { Text(Localization.error(model.message ?? "")) }
        .overlay {
            if model.mutating {
                ZStack {
                    Color.black.opacity(0.12)
                    VStack(spacing: 16) {
                        ProgressView(); Text(L(model.operationProgress)).font(.headline)
                        if model.canCancelCleanup { Button(L("停止清理"), action: model.cancelCleanup) }
                    }.padding(36).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .environment(\.locale, language.locale)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("轻扫")).font(.system(size: 26, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Text(L(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.7")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                UpdateStatusView()
            }.padding(.horizontal, 12).padding(.top, 20)
            Text(L("为重要的文件留空间")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 28)
            ForEach(AppSection.allCases, id: \.self) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon).font(.system(size: 16)).frame(width: 20)
                        Text(L(section.rawValue)).font(.system(size: 14, weight: model.section == section ? .medium : .regular))
                        Spacer(minLength: 0)
                        if (section == .results && model.scanning) || (section == .storage && model.analyzing) { ProgressView().controlSize(.mini) }
                        else if section == .results && !model.selectedItems.isEmpty {
                            Text(L("\(model.selectedItems.count)")).font(.system(size: 12, design: .monospaced))
                        }
                    }.padding(.horizontal, 12).frame(height: 36)
                        .foregroundStyle(model.section == section ? .white : .white.opacity(0.60))
                        .background(model.section == section ? .white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .leading) {
                            if model.section == section { Rectangle().fill(Color(red: 0.88, green: 0.53, blue: 0.35)).frame(width: 2, height: 16) }
                        }
                }.buttonStyle(.plain).padding(.bottom, 8)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(L("启动磁盘")); Spacer(); Text(L("可用")) }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.58))
                Text(L(formatBytes(model.snapshot.diskFree))).font(.system(size: 24, weight: .medium, design: .monospaced))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.12))
                        Rectangle().fill(.white.opacity(0.7)).frame(width: g.size.width * (model.snapshot.diskTotal > 0 ? min(1, Double(model.snapshot.diskFree) / Double(model.snapshot.diskTotal)) : 0))
                    }
                }.frame(height: 3)
            }.padding(12).padding(.bottom, 24)
            Button { model.showingIgnored = true } label: { Label(L("忽略列表"), systemImage: "eye.slash").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(12)
            Button(action: model.openTrash) {
                HStack {
                    Label(L("废纸篓"), systemImage: "trash")
                    Spacer(minLength: 0)
                    if let usage = model.trashUsage, usage.bytes > 0 { Text(L(formatBytes(usage.bytes))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.58)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(12).help(L(model.trashUsage?.summary ?? "打开废纸篓"))
        }.font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).padding(16).frame(width: 192).background(SweepStyle.rail)
    }
}

struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.showingManualConfirmation { ManualConfirmationView() }
        else { initialReview }
    }
    private var initialReview: some View {
        VStack(alignment:.leading,spacing:16){
            HStack{Text(L("检查所选文件")).font(.system(size:24,weight:.semibold));Spacer();Text(L(formatBytes(model.review.reduce(0){$0+$1.bytes}))).font(.system(size:24,weight:.medium,design:.monospaced))}
            Text(L(model.reviewScopeTitle)).font(.system(size:13)).foregroundStyle(SweepStyle.secondary)
            if let notice=model.reviewNotice{Text(L(notice)).font(.system(size:12)).foregroundStyle(SweepStyle.warning)}
            HStack(alignment:.top,spacing:12){
                ScrollView{CleanupImpactView(items:model.review)}.frame(width:230,height:340).sweepCard()
                ScrollView{LazyVStack(spacing:0){
                    ForEach(model.reviewGroups){group in
                        HStack{Text(L(group.title)).font(.system(size:14,weight:.semibold));Spacer();Text(L(formatBytes(group.bytes))).font(.system(size:12));Button(L("取消整组")){model.removeReviewGroup(group)}.buttonStyle(.plain).foregroundStyle(SweepStyle.accent)}.padding(14).background(SweepStyle.accent.opacity(0.05))
                        ForEach(Array(group.items.prefix(model.reviewDisplayLimit))){item in
                            HStack(alignment:.top,spacing:12){
                                Button{model.removeReviewedItem(item)}label:{Image(systemName:"minus.circle")}.buttonStyle(.plain).help(L("取消选择")).accessibilityLabel(L("取消选择"))
                                VStack(alignment:.leading,spacing:7){Text(item.url.lastPathComponent).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true);CleanupScopeLabel(scope:.forAssessment(item.assessment));DisclosureGroup(L("查看依据与路径")){Text(L(item.assessment.reason)+"\n"+item.url.path).font(.system(size:11)).foregroundStyle(SweepStyle.secondary).textSelection(.enabled)}.font(.system(size:11))}.frame(maxWidth:.infinity,alignment:.leading)
                                Text(L(formatBytes(item.bytes))).font(.system(size:12,design:.monospaced))
                            }.padding(14);Divider()
                        }
                        if group.items.count>model.reviewDisplayLimit{Button(L("加载更多文件")){model.reviewDisplayLimit+=100}.padding(10)}
                    }
                }}.frame(height:340).sweepCard()
            }
            if let error=model.reviewRetentionError{Text(Localization.error(error)).font(.system(size:12)).foregroundStyle(SweepStyle.warning)}
            Text(L("移到废纸篓后可恢复；相关应用未退出或文件仍被占用时跳过。")).font(.system(size:12)).foregroundStyle(SweepStyle.secondary)
            HStack{Button(L("返回")){model.showingReview=false}.keyboardShortcut(.cancelAction);Spacer();Text(L("\(model.review.count) 个文件")).font(.system(size:12)).foregroundStyle(SweepStyle.secondary);Button(L(model.manualReviewItems.isEmpty ? "移到废纸篓":"继续确认"),action:model.requestReviewedMove).buttonStyle(SweepPrimaryButton()).disabled(!model.canProceedWithReview)}
        }.padding(24).frame(width:900).background(SweepStyle.background)
    }
}

struct ManualConfirmationView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L("再次确认")).font(.system(size: 24, weight: .medium))
                Spacer(); CleanupScopeLabel(scope: .protected)
            }
            Text(L("本次共 \(model.review.count) 个文件，\(formatBytes(model.review.reduce(0) { $0 + $1.bytes }))；其中以下 \(model.manualReviewItems.count) 项需要你自行确认"))
                .font(.system(size: 13)).foregroundStyle(SweepStyle.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.manualReviewItems.prefix(model.reviewDisplayLimit))) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(item.url.lastPathComponent).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 16)
                                Text(L(formatBytes(item.bytes))).font(.system(size: 13, design: .monospaced))
                            }
                            Text(L(item.category.title)).font(.system(size: 12)).foregroundStyle(CleanupScope.protected.color)
                            Text(item.url.path).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.padding(16)
                        Divider()
                    }
                    if model.manualReviewItems.count>model.reviewDisplayLimit{Button(L("加载更多文件")){model.reviewDisplayLimit+=100}.padding(12)}
                }
            }.frame(height: 240).sweepCard()
            Text(L("确认后自动退出相关应用；如有未保存内容，会等待保存。未退出的应用所用文件会跳过。"))
                .font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
            Toggle(L("我已核实用途，确认删除这些文件"), isOn: $model.manualReviewAcknowledged)
                .toggleStyle(.checkbox).font(.system(size: 13))
            HStack {
                Button(L("返回复核"), action: model.returnToReview).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("确认移到废纸篓"), action: model.confirmManualCleanup).buttonStyle(SweepPrimaryButton())
                    .disabled(!model.manualReviewAcknowledged || !model.canProceedWithReview)
            }
        }.padding(28).frame(width: 680).background(SweepStyle.background)
    }
}

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text(L("内存状态")).font(.system(size: 28, weight: .medium)); Spacer(); Button(L("活动监视器"), action: model.openActivityMonitor) }
                HStack(spacing: 16) {
                    metric("内存压力", model.snapshot.pressureLabel)
                    metric("正在使用", formatBytes(model.snapshot.memoryUsed))
                    metric("压缩内存", formatBytes(model.snapshot.compressed))
                    metric("硬盘交换空间", formatBytes(model.snapshot.swap))
                }
                MemoryTrendView(tools:model.workbench,total:model.snapshot.memoryTotal)
                HStack { Text(L("应用占用")).font(.system(size: 17, weight: .medium)); Spacer(); Button(L("统计说明")) { model.showingMemoryDetails.toggle() }.buttonStyle(.plain).foregroundStyle(SweepStyle.secondary) }
                if model.showingMemoryDetails { Text(L("每 15 秒更新。按应用合计驻留内存，共享页可能重复统计；数值与活动监视器的统计口径不同。")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).fixedSize(horizontal: false, vertical: true) }
                VStack(spacing: 0) {
                    ForEach(model.snapshot.processes) { process in
                        HStack(spacing: 16) {
                            Image(systemName: "app").foregroundStyle(SweepStyle.secondary).frame(width: 24)
                            Text(process.name).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if let delta=model.workbench.memoryTrend.delta(for:process.id){Text(L((delta>=0 ? "+":"−")+formatBytes(abs(delta)))).font(.system(size:12,design:.monospaced)).foregroundStyle(SweepStyle.secondary)}
                            Text(L(formatBytes(process.bytes))).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        }.padding(16)
                        if process.id != model.snapshot.processes.last?.id { Divider().padding(.leading, 56) }
                    }
                }.sweepCard()
            }.padding(28)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 16) { Text(L(title)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary); Text(L(value)).font(.system(size: 23, weight: .medium, design: .monospaced)).foregroundStyle(SweepStyle.accent) }.padding(20).frame(maxWidth: .infinity, alignment: .leading).sweepCard()
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    private let color = CleanupScope.protected.color
    private var batches: [CleanupHistoryBatch] { model.historyBatches.filter { !model.historyOnlyRecoverable || !model.restorableRecords(in: $0).isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L("清理记录")).font(.system(size: 24, weight: .semibold)); Spacer(); Button(L("重新检查"), action: model.refresh).buttonStyle(SweepOutlineButton()).disabled(model.sampling) }
            if model.reconcilingCleanup { HStack { ProgressView().controlSize(.small);Text(L("正在核对上次文件操作")) }.padding(12).sweepCard() }
            if let issue=model.cleanupJournalFailure {
                HStack { Text(Localization.error(issue)).font(.system(size:13)).foregroundStyle(SweepStyle.warning);Spacer();Button(L("重新核对"),action:model.reconcileCleanupOperations).buttonStyle(SweepOutlineButton()).disabled(model.busy) }.padding(12).sweepCard()
            }
            if model.cleanupJournalIssues.contains(where: { $0.contains("完全磁盘访问") }) ||
                model.history.contains(where: { model.restoreStates[$0.id] == .permission }) {
                Button(L("前往系统设置"), action: model.openCleanupAccessSettings).buttonStyle(SweepOutlineButton())
            }
            if !model.cleanupJournalIssues.isEmpty { DisclosureGroup(L("待核对详情 · \(model.cleanupJournalIssues.count) 项")) { Text(Localization.error(model.cleanupJournalIssues.joined(separator:"\n"))).font(.system(size:12)).textSelection(.enabled) } }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    ModuleStat(title: "清理批次", value: "\(model.historyBatches.count) 次", color: color)
                    ModuleStat(title: "可恢复", value: formatBytes(model.recoverable.reduce(0) { $0 + $1.bytes }), color: CleanupScope.optional.color, detail: "\(model.recoverable.count) 个文件")
                    Button(L("恢复全部可恢复项")) { model.restoreBatch(model.recoverable) }.buttonStyle(SweepPrimaryButton(color: CleanupScope.optional.color)).disabled(model.busy || model.cleanupJournalFailure != nil || model.recoverable.isEmpty)
                    Spacer(minLength: 0)
                }.frame(width: 200)
                VStack(spacing: 0) {
                    HStack {
                        Text(L("按操作批次")).font(.system(size: 19, weight: .semibold)); Spacer()
                        Picker(L("记录范围"), selection: $model.historyOnlyRecoverable) { Text(L("全部")).tag(false); Text(L("可恢复")).tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 168)
                    }.padding(14)
                    Divider()
                    if batches.isEmpty { ContentUnavailableView(L("暂无清理批次"), systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else {
                        ScrollView { LazyVStack(spacing: 12) { ForEach(batches) { HistoryBatchView(batch: $0) } }.padding(12) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    HStack { Text(L("恢复到原位置 · 不覆盖已有文件")).foregroundStyle(SweepStyle.secondary); Spacer(); Button(L("打开废纸篓"), action: model.openTrash).buttonStyle(.plain) }.font(.system(size: 12)).padding(14)
                }.background(SweepStyle.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SweepStyle.line))
            }
        }.padding(16).foregroundStyle(SweepStyle.ink).tint(color)
    }
}
struct HistoryBatchView: View {
    @EnvironmentObject var model: AppModel
    let batch: CleanupHistoryBatch
    @SweepViewState private var expanded = false
    @SweepViewState private var limit = 100
    private var available: [TrashRecord] { model.restorableRecords(in: batch) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L(batch.title)).font(.system(size: 18, weight: .semibold))
                    Text(L(batch.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(InterfaceLanguage.current.locale)))).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                }
                Spacer()
                Button(L("恢复此批 · \(available.count) 项")) { model.restoreBatch(available) }.buttonStyle(SweepPrimaryButton(color: CleanupScope.optional.color)).disabled(model.busy || model.cleanupJournalFailure != nil || available.isEmpty)
            }
            if let receipt = batch.receipt {
                HStack(spacing: 18) {
                    Label(L("移入废纸篓 \(receipt.movedCount) 项 · " + formatBytes(receipt.movedBytes)), systemImage: "trash")
                    if receipt.retryFiles != nil || receipt.retryManaged != nil {
                        if receipt.retryCount>0{Text(L("未处理 \(receipt.retryCount) 项")).foregroundStyle(SweepStyle.warning)}
                        else if receipt.requestedCount>receipt.movedCount{Text(L("未处理项已在后续批次完成")).foregroundStyle(CleanupScope.optional.color)}
                    }else if !receipt.errors.isEmpty{Text(L("有未处理详情")).foregroundStyle(SweepStyle.warning)}
                    if receipt.interrupted == true { Text(L("中断后已核对")).foregroundStyle(SweepStyle.warning) }
                    else if receipt.cancelled { Text(L("已停止")).foregroundStyle(SweepStyle.warning) }
                    if receipt.retryCount>0{Button(L("重新检查未处理项")){model.retryCleanup(receipt)}.buttonStyle(SweepOutlineButton()).disabled(model.busy)}
                }.font(.system(size: 12))
                Text(L(receipt.interrupted == true ? "中断批次未记录操作后的可用空间" : "操作后可用空间变化：" + (receipt.observedFreeChange < 0 ? "−" : "+") + formatBytes(abs(receipt.observedFreeChange)) + " · 移入废纸篓不等于立即释放空间"))
                    .font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                if !receipt.errors.isEmpty { DisclosureGroup(L("未处理详情")) { Text(Localization.error(receipt.errors.joined(separator: "\n"))).font(.system(size: 12)).textSelection(.enabled) } }
            }
            if !batch.records.isEmpty {
                DisclosureGroup(L("查看文件 · 当前可恢复 \(available.count) 项"), isExpanded: $expanded) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(batch.records.prefix(limit))) { record in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.original.lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(2).help(record.original.path)
                                    Text(L(model.restoreStates[record.id]?.displayName ?? "正在检查")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(L(formatBytes(record.bytes))).font(.system(size: 13)).monospacedDigit()
                                Menu { Button(L("复制原路径")) { model.copyPath(record.original) }; Button(L("在访达中查看")) { model.reveal(record.trashed) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                                Button(L("恢复")) { model.restore(record) }.buttonStyle(SweepOutlineButton()).disabled(model.busy || model.cleanupJournalFailure != nil || model.restoreStates[record.id] != .available)
                            }.padding(.vertical, 12)
                            Divider()
                        }
                        if batch.records.count > limit { Button(L("加载更多文件")) { limit += 100 }.padding(8) }
                    }
                }
            } else if batch.receipt?.movedCount ?? 0 > 0 { Text(L("此批文件已恢复")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
        }.padding(16).sweepCard()
    }
}
struct IgnoredView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("忽略列表")).font(.system(size: 24, weight: .medium))
            Text(L("这些文件和文件夹不会出现在清理扫描中")).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
            if model.preferences.ignoredPaths.isEmpty { ContentUnavailableView(L("暂无忽略项目"), systemImage: "eye.slash").frame(height: 240) }
            else {
                ScrollView { VStack(spacing: 16) { ForEach(model.preferences.ignoredPaths, id: \.self) { path in
                    HStack(alignment: .top) { Text(path).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true); Spacer(); Button(L("取消忽略")) { model.unignore(path) }.disabled(model.busy) }
                    Divider()
                } } }.frame(height: 300)
            }
            HStack { Spacer(); Button(L("完成")) { model.showingIgnored = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 640)
    }
}
struct IssueView: View {
    @EnvironmentObject var model: AppModel
    private var shownResult: ScanResult? { model.section == .results ? model.cleanupResult : model.result }
    private var accessIssues: [StorageAccessIssue] { shownResult?.accessIssues ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(accessIssues.isEmpty ? "扫描详情" : "文件访问助手")).font(.system(size: 24, weight: .medium))
            if let result = shownResult {
                Text(L("已检查 \(result.visited) 项 · 用时 \(Int(result.elapsed)) 秒")).font(.system(size: 13))
                if result.cancelled { Text(L("扫描已停止，当前为部分结果")).foregroundStyle(SweepStyle.warning) }
                if result.limited { Text(L("结果达到上限，请选择更小的文件夹")).foregroundStyle(SweepStyle.warning) }
                if !accessIssues.isEmpty {
                    Text(L("尚未读取的位置未计入结果。允许访问后重新检查，会重新扫描当前范围。"))
                        .font(.system(size: 13)).foregroundStyle(SweepStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(L("选择文件夹")) { model.showingIssues = false; model.chooseFolder() }.buttonStyle(SweepOutlineButton())
                        if accessIssues.contains(where: { $0.kind == .permission }) {
                            Button(L("前往系统设置"), action: model.openCleanupScanAccessSettings).buttonStyle(SweepOutlineButton())
                        }
                        Button(L("重新检查"), action: model.recheckCleanupScanAccess).buttonStyle(SweepPrimaryButton()).disabled(model.busy)
                    }
                    if accessIssues.contains(where: { $0.kind == .permission }) {
                        HStack {
                            Text(L("系统设置 → 隐私与安全 → 完全磁盘访问")).foregroundStyle(SweepStyle.secondary)
                            Spacer()
                            Button(L("复制应用路径")) { model.copyPath(Bundle.main.bundleURL) }.buttonStyle(.plain)
                        }.font(.system(size: 12))
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(accessIssues) { issue in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(verbatim: issue.url.lastPathComponent).font(.system(size: 15, weight: .semibold))
                                        Spacer()
                                        Text(L("尚未读取")).foregroundStyle(SweepStyle.warning)
                                    }
                                    Text(L(issue.kind.title)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                                    DisclosureGroup(L("查看详情")) {
                                        Text(verbatim: issue.url.path).textSelection(.enabled)
                                        if !issue.detail.isEmpty { Text(Localization.error(issue.detail)).textSelection(.enabled) }
                                    }.font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                                }.padding(14).sweepCard()
                            }
                        }
                    }.frame(height: 240)
                    DisclosureGroup(L("扫描详情")) { scanDetails(result) }.font(.system(size: 12))
                } else {
                    scanDetails(result)
                    ScrollView { Text(Localization.error(result.issues.isEmpty ? "没有读取错误" : result.issues.joined(separator: "\n\n"))).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 240)
                    if !result.issues.isEmpty {
                        Button(L("重新检查"), action: model.recheckCleanupScanAccess).buttonStyle(SweepOutlineButton()).disabled(model.busy)
                    }
                }
            }
            HStack { Spacer(); Button(L("完成")) { model.showingIssues = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 720)
    }
    private func scanDetails(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("常用位置列出 1 MB 以上文件，缓存与日志保留最近 7 天；个人大文件从 100 MB 起。图库、数据库、应用、链接和云端文件会跳过。"))
            Text(L("常用位置还会检查 npm、Cargo、Gradle、iOS 模拟器以及 Slack、VS Code、Discord 的缓存；只读取这些缓存目录本身，不读取旁边的设置、凭据和数据。"))
        }.font(.system(size: 13)).foregroundStyle(SweepStyle.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Sidebar entry for the update check: a status line that opens a small menu.
struct UpdateStatusView: View {
    @ObservedObject private var updates = UpdateChecker.shared
    var body: some View {
        Menu {
            Button(L("检查更新")) { updates.check() }.disabled(updates.state == .checking)
            if updates.availableRelease != nil { Button(L("前往发布页"), action: updates.openRelease) }
            Divider()
            Toggle(L("每天自动检查更新"), isOn: $updates.automatic)
        } label: {
            Text(L(updates.statusTitle)).font(.system(size: 11))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(updates.availableRelease != nil ? Color(red: 0.88, green: 0.53, blue: 0.35) : .white.opacity(0.5))
            .help(L("只向 GitHub 查询公开的发布列表，不发送本机或文件信息；不会自动下载或安装。"))
    }
}
