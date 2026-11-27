import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    private var usedBytes: Int64 { max(0, model.snapshot.diskTotal - model.snapshot.diskFree) }
    private var usedRatio: Double { model.snapshot.diskTotal > 0 ? Double(usedBytes) / Double(model.snapshot.diskTotal) : 0 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("空间账本")).font(.system(size: 32, weight: .medium))
                        Text(L("启动磁盘 / 本机存储")).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
                    }
                    Spacer()
                    if model.scanning || model.analyzing {
                        Button(L("停止扫描"), action: model.stopSmartScan).buttonStyle(SweepOutlineButton())
                    } else {
                        Button(L(model.scannedAt == nil ? "扫描常用位置" : "重新扫描")) {
                            if model.scannedAt == nil { model.quickScan() } else { model.rescan() }
                            model.section = .results
                        }.buttonStyle(SweepPrimaryButton()).disabled(model.busy)
                        Menu {
                            Button(L("扫描常用位置")) { model.quickScan(); model.section = .results }
                            Button(L("扫描空间与清理项"), action: model.smartScan)
                            Divider()
                            Button(L("查找大文件")) { model.personalScan(); model.section = .results }
                            Button(L("查找长期未用的大文件")) { model.unusedLargeFileScan(); model.section = .results }
                            Button(L("选择文件夹"), action: model.chooseFolder)
                        } label: { Text(L("范围")) }.disabled(model.busy)
                    }
                }
                HStack(alignment: .top, spacing: 20) {
                    diskLedger.frame(maxWidth: .infinity, alignment: .topLeading).padding(24).sweepCard()
                    storageLedger.frame(width: 240, alignment: .topLeading).padding(20).sweepCard()
                }
                cleanupLedger
                HStack(spacing: 24) {
                    Button { model.section = .memory } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "memorychip")
                            Text(L("内存")); Text(L(formatBytes(model.snapshot.memoryUsed))).monospacedDigit()
                            Text(L(model.snapshot.pressureLabel)).foregroundStyle(SweepStyle.secondary)
                            Image(systemName: "arrow.up.right").font(.system(size: 10))
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Button { model.section = .history } label: {
                        Label(L("清理记录 · \(model.recoverable.count) 项可恢复"), systemImage: "clock.arrow.circlepath")
                    }.buttonStyle(.plain)
                }.font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }.padding(32)
        }.foregroundStyle(SweepStyle.ink)
    }
    private var diskLedger: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("可用空间")).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
                    Text(L(formatBytes(model.snapshot.diskFree))).font(.system(size: 48, weight: .regular, design: .monospaced)).minimumScaleFactor(0.7).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text(L("总容量")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                    Text(L(formatBytes(model.snapshot.diskTotal))).font(.system(size: 16, design: .monospaced))
                }.padding(.bottom, 8)
            }
            CapacityRuler(used: usedRatio)
            HStack(spacing: 8) {
                Rectangle().fill(SweepStyle.ink).frame(width: 8, height: 8)
                Text(L("已使用 " + formatBytes(usedBytes)))
                Spacer()
                Text(L("\(Int(usedRatio * 100))% 已使用")).monospacedDigit()
            }.font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
        }.frame(minHeight: 260, alignment: .topLeading)
    }
    private var cleanupLedger: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("清理清单")).font(.system(size: 17, weight: .semibold))
                Spacer()
                if model.scanning || model.loadingReport { ProgressView().controlSize(.small) }
                else if let date = model.scannedAt { Text(L(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(InterfaceLanguage.current.locale)) + " 扫描")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
            }
            if model.scanning {
                Text(L("正在检查 \(model.progress.visited) 项")).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
            }
            HStack(spacing: 12) {
                ForEach(CleanupScope.allCases) { scope in
                    CleanupScopeCard(scope: scope,
                        capacity: model.loadingReport ? "读取中" : model.scannedAt == nil ? "待扫描" : formatBytes(model.allScopeItems(scope).reduce(0) { $0 + $1.bytes }),
                        count: model.scannedAt == nil ? nil : model.allScopeItems(scope).count) { model.openCleanup(scope) }
                        .disabled(model.scanning || model.loadingReport)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "folder").foregroundStyle(SweepStyle.secondary)
                Text(L(model.scannedAt == nil ? "下载、缓存和日志" : model.scanLabel + " · " + (model.result?.isPartial == true ? "部分结果" : "扫描完成")))
                Spacer()
                Button(L(model.result?.accessIssues?.isEmpty == false ? "处理访问问题" : "详情")) { model.showingIssues = true }.buttonStyle(.plain).disabled(model.result == nil)
            }.font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
        }
    }
    private var storageLedger: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("占用排行")).font(.system(size: 17, weight: .semibold))
            if model.analyzing {
                Text(L("正在分析空间 · \(model.storageProgress.visited) 项")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            } else if let info = model.storageInfo {
                Text(info.scannedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(InterfaceLanguage.current.locale)))
                    .font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }
            if model.appSummaries.isEmpty {
                Text(L(model.analyzing ? "正在读取应用数据" : "按应用查看空间去向")).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
            } else {
                ForEach(Array(model.appSummaries.filter { $0.hasReadData }.sorted { $0.bytes > $1.bytes }.prefix(4).enumerated()), id: \.element.id) { rank, app in
                    Button { model.section = .storage; model.browseStorage(nil, owner: app) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(L(String(format: "%02d", rank + 1))).font(.system(size: 12, design: .monospaced)).foregroundStyle(SweepStyle.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L(app.title)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(L(formatBytes(app.bytes) + (app.partial ? " · 部分" : ""))).font(.system(size: 12, design: .monospaced)).foregroundStyle(SweepStyle.secondary)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Button {
                model.section = .storage
                if model.storageInfo == nil && !model.analyzing { model.startStorageAnalysis() }
            } label: { Label(L("查看空间分析"), systemImage: "arrow.right") }.buttonStyle(SweepOutlineButton())
            
        }
    }
}
