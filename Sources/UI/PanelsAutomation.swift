//
//  PanelsAutomation.swift  (定时设置 / 捷径)
//

import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }
    @StateObject private var editor = ScheduleEditorModel()

    /// 44 pt: a title line and a time line, with room for the 20 pt switch. The
    /// rows used to stack three lines in 9 pt of padding, so two tasks already
    /// filled 100 pt of a card whose height was pinned at 330.
    private static let rowHeight: CGFloat = 44
    /// History rows are one line — what ran, what it was, when — because the
    /// detail is a time plus a reason, not prose.
    private static let historyRowHeight: CGFloat = 32

    var body: some View {
        PageScaffold(title: Panel.schedule.title,
                     symbol: Panel.schedule.symbol,
                     help: t("在指定时间自动执行充电、放电或校准操作。"),
                     // The empty state carries 新建任务 and 模板 itself, so a
                     // toolbar would be a second copy of the same two buttons
                     // 40 pt above them. It appears once there is a list to add to.
                     toolbar: { if !state.tasks.isEmpty { taskToolbar } }) {
            taskCard

            Card {
                ToggleRow(symbol: "arrow.triangle.2.circlepath",
                          title: t("自动补做未完成的任务"),
                          help: t("启用后，InfiniCal 会自动运行 MacBook 处于睡眠或关机状态时未执行的任务。"),
                          isOn: $state.startTasksAfterDue)
            }

            historyCard
        }
        .sheet(isPresented: $editor.isPresented) {
            TaskEditor(draft: editor.draft) { task in
                state.addTask(task)
                editor.isPresented = false
            } onCancel: {
                editor.isPresented = false
            }
        }
    }

    // MARK: - Task list

    /// The card sizes itself to its rows. A fixed 330 pt box meant one task sat
    /// in a 330 pt hole, and the scroll view inside it captured the wheel before
    /// the page could scroll.
    private var taskCard: some View {
        Card(kind: .list) {
            VStack(spacing: 0) {
                if state.tasks.isEmpty {
                    EmptyState(symbol: "calendar.badge.plus",
                               title: t("还没有定时任务"),
                               message: t("到点自动执行充电、放电或校准，无需手动操作。")) {
                        // No extra padding above the buttons: the block's own
                        // 10 pt rhythm already separates them, and 4 more put
                        // the card at 161 pt against a 160 pt target.
                        HStack(spacing: Spacing.s) {
                            newTaskButton
                            templateMenu
                        }
                    }
                } else {
                    cardHeader(t("定时任务"), symbol: "calendar")
                    Divider().background(theme.divider)
                    ForEach(Array(state.tasks.enumerated()), id: \.element.id) { index, task in
                        taskRow(task)
                        if index < state.tasks.count - 1 {
                            Divider().background(theme.divider)
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: task.kind.symbol)
                .font(Glyph.row)
                .foregroundColor(task.enabled ? theme.textSecondary : theme.textTertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.kind.title)
                    .font(Typography.body)
                    .foregroundColor(task.enabled ? theme.textPrimary : theme.textSecondary)
                Text(subtitle(task))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Toggle("", isOn: Binding(get: { task.enabled }, set: { value in
                if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                    state.tasks[index].enabled = value
                }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(theme.accent)
            .scaleEffect(0.72)
            .frame(width: 36, height: 20)
            Button {
                state.removeTask(task)
            } label: {
                Image(systemName: "trash")
                    .font(Glyph.row)
                    .foregroundColor(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CardPadding.regular)
        .frame(height: Self.rowHeight)
    }

    // MARK: - History

    private var historyCard: some View {
        Card(kind: .list) {
            VStack(spacing: 0) {
                if state.taskHistory.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath",
                               title: t("还没有执行记录"),
                               message: t("已执行的任务将显示在此处。"))
                } else {
                    cardHeader(t("任务历史"), symbol: "list.bullet.rectangle",
                               help: t("已执行的任务会记录在此处。")) {
                        Button(t("清除")) { state.clearTaskHistory() }
                            .buttonStyle(.plain)
                            .font(Typography.caption)
                            .foregroundColor(theme.textTertiary)
                    }
                    Divider().background(theme.divider)
                    ForEach(Array(state.taskHistory.enumerated()), id: \.element.id) { index, entry in
                        historyRow(entry)
                        if index < state.taskHistory.count - 1 {
                            Divider().background(theme.divider)
                        }
                    }
                }
            }
        }
    }

    /// `warning` rather than `chartOrange`: the series colour is the same value
    /// in both appearances, so 「已跳过」 sat at 2.2:1 on a white card. `warning`
    /// is in the contrast gate and carries a light-mode variant.
    private func historyRow(_ entry: TaskLogEntry) -> some View {
        HStack(spacing: Spacing.s) {
            Text(entry.title)
                .font(Typography.body)
                .foregroundColor(theme.textPrimary)
            if entry.outcome == .skipped {
                Text(t("已跳过"))
                    .font(Typography.micro)
                    .foregroundColor(theme.warning)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(theme.warning.opacity(0.14)))
            }
            Text(entry.detail)
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.s)
            Text(Self.formatter.string(from: entry.date))
                .font(Typography.caption.monospacedDigit())
                .foregroundColor(theme.textTertiary)
        }
        .padding(.horizontal, CardPadding.regular)
        .frame(height: Self.historyRowHeight)
    }

    // MARK: - Chrome

    /// A 34 pt header row inside a full-bleed card, so the section title belongs
    /// to the card it names. 「任务历史」 used to float on the window background
    /// above its card, 20 pt away from the rows it describes.
    private func cardHeader<Content: View>(_ title: String,
                                           symbol: String,
                                           help: String? = nil,
                                           @ViewBuilder trailing: () -> Content) -> some View {
        CardHeader(title: title, symbol: symbol, help: help) { trailing() }
            .padding(.horizontal, CardPadding.regular)
            .frame(height: 34)
    }

    private func cardHeader(_ title: String, symbol: String, help: String? = nil) -> some View {
        cardHeader(title, symbol: symbol, help: help) { EmptyView() }
    }

    private var newTaskButton: some View {
        Button {
            editor.draft.reset()
            editor.isPresented = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus").font(Glyph.row.weight(.semibold))
                Text(t("新建任务")).font(Typography.body.weight(.medium))
            }
            .padding(.horizontal, Spacing.m)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.accent))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    /// Add and template buttons: the page's toolbar, right of the title. They
    /// used to sit in a row of their own below the list, which put the primary
    /// action at the bottom of the page it acts on.
    private var taskToolbar: some View {
        HStack(spacing: Spacing.s) {
            Button {
                editor.draft.reset()
                editor.isPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(Glyph.row.weight(.semibold))
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.innerControl))
                    .foregroundColor(theme.textPrimary)
            }
            .buttonStyle(.plain)

            templateMenu
        }
    }

    /// One template menu for both places it appears. `fixedSize` because a
    /// borderless `Menu` in an `HStack` with a `Spacer` otherwise stretches to
    /// fill the row, which is what the old 90 pt frame was working around.
    private var templateMenu: some View {
        Menu {
            templateItems
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "doc.on.doc").font(Glyph.row)
                Text(t("模板")).font(Typography.body.weight(.medium))
            }
            .padding(.horizontal, Spacing.m)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.innerControl))
            .foregroundColor(theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var templateItems: some View {
        Button(t("周末充满")) { addTemplate(.topUp, hour: 9, weekdays: [6, 7]) }
        Button(t("周一早晨充满")) { addTemplate(.topUp, hour: 7, weekdays: [1]) }
        Button(t("每月校准")) { addTemplate(.calibrate, hour: 9, weekdays: [1]) }
        Button(t("每两周校准")) { addTemplate(.calibrate, hour: 9, weekdays: [1, 3]) }
    }

    private func addTemplate(_ kind: TaskKind, hour: Int, weekdays: Set<Int>) {
        var task = ScheduledTask()
        task.kind = kind
        task.hour = hour
        task.weekdays = weekdays
        state.addTask(task)
    }

    // MARK: - Text

    /// `en_US_POSIX`: with the system set to 12-hour time, ICU overrides the
    /// literal `HH` and this formatter returned 「11/05 凌晨 3:41」 instead of
    /// 「11/05 03:41」 — 30 pt wider than the column it sits in, and different in
    /// shape from row to row.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    /// Time, repeat, then conditions — on one line. The conditions used to get a
    /// third line of their own, which is what pushed the rows past 50 pt.
    private func subtitle(_ task: ScheduledTask) -> String {
        var parts = ["\(task.timeText) · \(task.weekdayText)"]
        if let conditions = Self.conditionText(task) { parts.append(conditions) }
        return parts.joined(separator: " · ")
    }

    /// Conditions only show when they are actually set, so the common case of a
    /// plain "every day at 09:00" task stays one line.
    static func conditionText(_ task: ScheduledTask) -> String? {
        guard let conditions = task.conditions else { return nil }
        var parts: [String] = []
        if conditions.onlyOnAdapter == true { parts.append(t("仅插电")) }
        if let value = conditions.onlyBelowPercentage { parts.append(tf("电量低于 {p}%", "\(value)")) }
        if let value = conditions.maxTemperature { parts.append(tf("温度低于 {p}°C", "\(value)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

final class ScheduleEditorModel: ObservableObject {
    @Published var isPresented = false
    @Published var draft = TaskDraft()
}

final class TaskDraft: ObservableObject {
    @Published var kind: TaskKind = .topUp
    @Published var value: Int = 80
    @Published var hour: Int = 9
    @Published var minute: Int = 0
    @Published var weekdays: Set<Int> = Set(1...7)
    @Published var onlyOnAdapter: Bool = false
    @Published var onlyBelow: Int?
    @Published var maxTemperature: Int?

    func reset() {
        kind = .topUp
        value = 80
        hour = 9
        minute = 0
        weekdays = Set(1...7)
        onlyOnAdapter = false
        onlyBelow = nil
        maxTemperature = nil
    }

    var conditions: TaskConditions? {
        guard onlyOnAdapter || onlyBelow != nil || maxTemperature != nil else { return nil }
        return TaskConditions(onlyBelowPercentage: onlyBelow,
                             onlyOnAdapter: onlyOnAdapter ? true : nil,
                             maxTemperature: maxTemperature)
    }

    var task: ScheduledTask {
        var task = ScheduledTask(kind: kind, value: value, hour: hour,
                                 minute: minute, weekdays: weekdays)
        task.conditions = conditions
        return task
    }
}

struct TaskEditor: View {
    private var theme: Theme { Theme.current }
    @EnvironmentObject private var state: AppState
    @ObservedObject var draft: TaskDraft
    var onSave: (ScheduledTask) -> Void
    var onCancel: () -> Void

    private let weekdays = [t("一"), t("二"), t("三"), t("四"), t("五"), t("六"), t("日")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("新建任务"))
                .font(Typography.headline)
                .foregroundColor(theme.textPrimary)

            Picker(t("操作"), selection: $draft.kind) {
                ForEach(TaskKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if draft.kind == .setLimit || draft.kind == .startDischarge {
                HStack {
                    Text(t("目标电量")).font(Typography.body)
                    Spacer()
                    ValueStepper(value: $draft.value, range: 10...100, step: 5)
                        .frame(width: 110)
                }
            }

            HStack {
                Text(t("时间")).font(Typography.body)
                Spacer()
                Picker("", selection: $draft.hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
                Picker("", selection: $draft.minute) {
                    ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
            }

            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    let day = index + 1
                    Button {
                        if draft.weekdays.contains(day) { draft.weekdays.remove(day) }
                        else { draft.weekdays.insert(day) }
                    } label: {
                        Text(weekdays[index])
                            .font(Typography.label)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(draft.weekdays.contains(day) ? theme.accent : theme.innerControl))
                            .foregroundColor(draft.weekdays.contains(day) ? .white : theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(theme.divider)

            Text(t("执行条件（可选）"))
                .font(Typography.label)
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 8) {
                Text(t("仅在连接充电器时")).font(Typography.body)
                Spacer()
                Toggle("", isOn: Binding(get: { draft.onlyOnAdapter },
                                         set: { draft.onlyOnAdapter = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accent)
                    .scaleEffect(0.7)
                    .frame(width: 38, height: 20)
            }

            HStack(spacing: 8) {
                Text(t("仅在电量低于")).font(Typography.body)
                Spacer()
                if let value = draft.onlyBelow {
                    ValueStepper(value: Binding(get: { value }, set: { draft.onlyBelow = $0 }),
                                 range: 5...95, step: 5)
                        .frame(width: 100)
                }
                Toggle("", isOn: Binding(get: { draft.onlyBelow != nil },
                                         set: { draft.onlyBelow = $0 ? 40 : nil }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accent)
                    .scaleEffect(0.7)
                    .frame(width: 38, height: 20)
            }

            HStack(spacing: 8) {
                Text(t("电池温度低于")).font(Typography.body)
                Spacer()
                if let value = draft.maxTemperature {
                    ValueStepper(value: Binding(get: { value }, set: { draft.maxTemperature = $0 }),
                                 range: 20...60, step: 1, suffix: "°C")
                        .frame(width: 106)
                }
                Toggle("", isOn: Binding(get: { draft.maxTemperature != nil },
                                         set: { draft.maxTemperature = $0 ? 40 : nil }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accent)
                    .scaleEffect(0.7)
                    .frame(width: 38, height: 20)
            }

            if let hint = conflictHint {
                Text(hint)
                    .font(Typography.caption)
                    .foregroundColor(theme.chartOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(t("取消")) { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.textSecondary)
                Button(t("保存")) { onSave(draft.task) }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .padding(.leading, 14)
            }
            .font(Typography.headline)
        }
        .padding(20)
        .frame(width: 360)
    }

    /// Two tasks due at the same time that write the same lever cannot both
    /// run. Say so while the task is being created, instead of letting the user
    /// find out from a 「已跳过」 row later.
    private var conflictHint: String? {
        let candidate = draft.task
        guard let rival = state.tasks.first(where: { other in
            other.enabled
                && TaskPolicy.lever(other.kind) == TaskPolicy.lever(candidate.kind)
                && other.hour == candidate.hour && other.minute == candidate.minute
                && !other.weekdays.isDisjoint(with: candidate.weekdays)
        }) else { return nil }
        let winner = TaskPolicy.rank(rival.kind) <= TaskPolicy.rank(candidate.kind) ? rival.kind : candidate.kind
        return tf("同一时间写同一项设置，只会执行一个：「{p}」优先。", winner.title)
    }
}

