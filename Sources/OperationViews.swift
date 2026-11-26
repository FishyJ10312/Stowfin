import SwiftUI

struct CleanupImpactView: View {
  let items: [ScanItem]
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(L("清理影响")).font(.system(size: 17, weight: .semibold))
      Text(L("\(items.count) 项 · " + formatBytes(items.reduce(0) { $0 + $1.bytes }))).font(
        .system(size: 12, design: .monospaced)
      ).foregroundStyle(SweepStyle.secondary)
      ForEach(CleanupImpact.build(items)) { impact in
        VStack(alignment: .leading, spacing: 6) {
          Text(L(impact.title)).font(.system(size: 14, weight: .semibold))
          Text(L(impact.consequence)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(L("\(impact.count) 项 · " + formatBytes(impact.bytes))).font(
            .system(size: 11, design: .monospaced)
          ).foregroundStyle(CleanupScope.optional.color)
        }
        Divider()
      }
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct OperationOutcomeView: View {
  @EnvironmentObject var model: AppModel
  let outcome: OperationOutcome
  @SweepViewState private var limit = 100
  private var current: OperationOutcome {
    model.operationOutcome.flatMap { $0.id == outcome.id ? $0 : nil } ?? outcome
  }
  private var remaining: Int { current.receipt?.retryCount ?? current.restoreRemaining.count }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(L(current.title)).font(.system(size: 24, weight: .semibold))
        Spacer()
        Text(L(formatBytes(current.bytes))).font(
          .system(size: 22, weight: .medium, design: .monospaced))
      }
      HStack(spacing: 12) {
        if current.errors.contains(where:{$0.contains("完全磁盘访问")}) { Button(L("前往系统设置"),action:model.openCleanupAccessSettings).buttonStyle(SweepOutlineButton()) }
        ModuleStat(
          title: current.receipt == nil ? "已恢复" : "已移入废纸篓", value: "\(current.completed) 项",
          color: CleanupScope.optional.color)
        ModuleStat(
          title: "未处理", value: "\(remaining) 项",
          color: remaining > 0 ? CleanupScope.recommended.color : SweepStyle.secondary)
      }
      if current.receipt != nil && current.completed > 0 {
        Text(L("文件仍在废纸篓，可从清理记录恢复；清空废纸篓后才释放空间。")).font(.system(size: 12)).foregroundStyle(
          SweepStyle.secondary)
      }
      if current.completed > 0 {
        HStack(spacing: 12) {
          Image(systemName: "trash").foregroundStyle(SweepStyle.secondary)
          if let usage = current.trashUsage {
            Text(L(usage.summary)).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
          } else if current.trashMeasured {
            Text(L("无法读取废纸篓大小；可能需要在系统设置中允许完全磁盘访问。")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
          } else {
            ProgressView().controlSize(.small)
            Text(L("正在统计废纸篓占用…")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
          }
          Spacer(minLength: 0)
          Button(L("打开废纸篓"), action: model.openTrash).buttonStyle(SweepOutlineButton())
        }.padding(12).background(CleanupScope.optional.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
      }
      if !current.errors.isEmpty {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(current.errors.prefix(limit).enumerated()), id: \.offset) { _, error in
              Text(Localization.error(error)).font(.system(size: 12)).textSelection(.enabled).fixedSize(
                horizontal: false, vertical: true)
              Divider()
            }
            if current.errors.count > limit { Button(L("加载更多详情")) { limit += 100 } }
          }.padding(14)
        }.frame(height: min(230, max(80, CGFloat(current.errors.count) * 56))).sweepCard()
      }
      if let error = current.saveFailure {
        HStack(alignment: .top) {
          Text(L("记录尚未保存：" + error)).font(.system(size: 12)).foregroundStyle(SweepStyle.warning)
          Spacer()
          Button(L("重新保存记录"), action: model.retrySaveHistory)
        }
      }
      HStack(spacing: 12) {
        Button(L("查看清理记录")) {
          model.operationOutcome = nil
          model.section = .history
        }.buttonStyle(SweepOutlineButton())
        Spacer()
        if let receipt = current.receipt, receipt.retryCount > 0 {
          Button(L("重新检查未处理项")) { model.retryCleanup(receipt) }.buttonStyle(SweepOutlineButton())
            .disabled(model.busy)
        }
        if !current.restoreRemaining.isEmpty {
          Button(L("重试恢复")) { model.retryRestore(current) }.buttonStyle(SweepOutlineButton()).disabled(
            model.busy)
        }
        Button(L("完成")) { model.operationOutcome = nil }.buttonStyle(SweepPrimaryButton())
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 760).background(SweepStyle.background)
  }
}
struct ToolProgressView: View {
  @ObservedObject var tools: WorkbenchModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(L(tools.progressData.phase)).font(.system(size: 14, weight: .semibold))
        Text(L(tools.progressData.current)).font(.system(size: 12)).lineLimit(1).truncationMode(
          .middle
        ).foregroundStyle(SweepStyle.secondary)
        Spacer()
        if let date = tools.activeStarted {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(L(formatElapsed(context.date.timeIntervalSince(date)))).font(
              .system(size: 12, design: .monospaced)
            ).foregroundStyle(SweepStyle.secondary)
          }
        }
        Button(L("停止"), action: tools.stop).buttonStyle(SweepOutlineButton())
      }
      HStack(spacing: 12) {
        if let fraction = tools.progressData.fraction {
          ProgressView(value: fraction)
        } else {
          ProgressView().controlSize(.small)
        }
        if !tools.progressData.amount.isEmpty {
          Text(L(tools.progressData.amount)).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(SweepStyle.secondary)
        }
      }
    }.padding(12).background(
      CleanupScope.optional.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }
}
struct ToolTasksView: View {
  @ObservedObject var tools: WorkbenchModel
  @SweepViewState private var problemsOnly = false
  private var records: [ToolTaskRecord] {
    tools.tasks.filter {
      !problemsOnly || [.failed, .partial, .cancelled, .interrupted].contains($0.status)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(L("最近任务")).font(.system(size: 21, weight: .semibold))
        Spacer()
        Toggle(L("只看未完成"), isOn: $problemsOnly).toggleStyle(.checkbox).font(.system(size: 12))
      }
      if let issue = tools.taskLoadIssue {
        HStack {
          Text(Localization.error(issue)).font(.system(size: 12)).foregroundStyle(SweepStyle.warning)
          Spacer()
          Button(L("重建记录"), action: tools.rebuildTaskHistory).disabled(tools.busy)
        }
      }
      if records.isEmpty {
        ContentUnavailableView(
          L(problemsOnly ? "没有未完成任务" : "暂无任务"), systemImage: "list.bullet.rectangle",
          description: Text(L(problemsOnly ? "新的任务结果会保存在这里" : "扫描、查重或归档后，可在这里查看结果和重新检查"))
        ).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) { ForEach(records) { ToolTaskRow(record: $0, tools: tools) } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}
struct ToolTaskRow: View {
  let record: ToolTaskRecord
  @ObservedObject var tools: WorkbenchModel
  private var color: Color {
    switch record.status {
    case .completed, .running: return CleanupScope.optional.color
    case .partial, .failed: return CleanupScope.recommended.color
    case .cancelled, .interrupted: return CleanupScope.protected.color
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L(record.plan.kind.rawValue)).font(.system(size: 17, weight: .semibold))
        Text(L(record.status.rawValue)).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
          .padding(.horizontal, 8).padding(.vertical, 4).background(
            color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        Spacer()
        if record.status != .running {
          Button(L(record.plan.kind == .archive ? "重新设置" : record.plan.canRepeat ? "重新检查" : "查看工具")) {
            tools.repeatTask(record)
          }.buttonStyle(SweepOutlineButton()).disabled(tools.busy)
        }
      }
      HStack {
        Text(L(record.started.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(InterfaceLanguage.current.locale))))
        if record.status == .interrupted {
          Text(L("需重新检查，不会自动执行文件操作"))
        } else {
          Text(L("· " + formatElapsed(record.duration)))
        }
        Spacer()
        if record.status != .running {
          Text(L("结果 \(record.resultCount) 项"))
          if record.issueCount > 0 {
            Text(L("未读取或跳过 \(record.issueCount) 处")).foregroundStyle(SweepStyle.warning)
          }
        }
      }.font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
      DisclosureGroup(L("查看范围与详情")) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(record.plan.roots, id: \.path) {
            Text($0.path).font(.system(size: 11)).textSelection(.enabled)
          }
          if let target = record.plan.destination {
            Text(L("目标：" + target.path)).font(.system(size: 11)).textSelection(.enabled)
          }
          if !record.details.isEmpty {
            Text(L(record.details.joined(separator: "\n"))).font(.system(size: 12)).textSelection(
              .enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
      }.font(.system(size: 12))
    }.padding(14).sweepCard()
  }
}
