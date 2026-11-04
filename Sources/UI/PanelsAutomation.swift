//
//  PanelsAutomation.swift  (定时设置 / 捷径)
//

import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }
    @StateObject private var editor = ScheduleEditorModel()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "calendar.badge.clock")
                    Text(t("任务"))
                        .font(Typography.title)
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: t("在指定时间自动执行充电、放电或校准操作。"))
                    Spacer()
                }
                .frame(height: 34)

                Card(padding: 0) {
                    Group {
                        if state.tasks.isEmpty {
                            Text(t("点击 “+” 按钮添加新任务，或从现有模板中选择。"))
                                .font(Typography.body)
                                .foregroundColor(theme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(state.tasks) { task in
                                        taskRow(task)
                                        Divider().background(theme.divider)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 330)
                }

                HStack(spacing: 10) {
                    Button {
                        editor.draft.reset()
                        editor.isPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(Glyph.row.weight(.semibold))
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.innerControl))
                            .foregroundColor(theme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button(t("周末充满")) {
                            var task = ScheduledTask()
                            task.kind = .topUp
                            task.hour = 9
                            task.weekdays = [6, 7]
                            state.addTask(task)
                        }
                        Button(t("周一早晨充满")) {
                            var task = ScheduledTask()
                            task.kind = .topUp
                            task.hour = 7
                            task.weekdays = [1]
                            state.addTask(task)
                        }
                        Button(t("每月校准")) {
                            var task = ScheduledTask()
                            task.kind = .calibrate
                            task.hour = 9
                            task.weekdays = [1]
                            state.addTask(task)
                        }
                        Button(t("每两周校准")) {
                            var task = ScheduledTask()
                            task.kind = .calibrate
                            task.hour = 9
                            task.weekdays = [1, 3]
                            state.addTask(task)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.doc").font(Glyph.row)
                            Text(t("模板")).font(Typography.body.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.innerControl))
                        .foregroundColor(theme.textPrimary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 90)
                    Spacer()
                }

                ToggleRow(symbol: "arrow.triangle.2.circlepath",
                          title: t("自动补做未完成的任务"),
                          help: t("启用后，InfiniCal 会自动运行 MacBook 处于睡眠或关机状态时未执行的任务。"),
                          isOn: $state.startTasksAfterDue)

                HStack(spacing: 10) {
                    IconBadge(symbol: "list.bullet.rectangle")
                    Text(t("任务历史"))
                        .font(Typography.headline)
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: t("已执行的任务会记录在此处。"))
                    Spacer()
                    if !state.taskHistory.isEmpty {
                        Button(t("清除")) { state.clearTaskHistory() }
                            .buttonStyle(.plain)
                            .font(Typography.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .frame(height: 34)
                .padding(.top, 6)

                Card(padding: 0) {
                    Group {
                        if state.taskHistory.isEmpty {
                            Text(t("已执行的任务将显示在此处。"))
                                .font(Typography.body)
                                .foregroundColor(theme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(state.taskHistory) { entry in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 5) {
                                                    Text(entry.title).font(Typography.body)
                                                    if entry.outcome == .skipped {
                                                        Text(t("已跳过"))
                                                            .font(Typography.micro)
                                                            .foregroundColor(theme.chartOrange)
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 1)
                                                            .background(RoundedRectangle(cornerRadius: 3)
                                                                            .fill(theme.chartOrange.opacity(0.14)))
                                                    }
                                                }
                                                Text(entry.detail)
                                                    .font(Typography.caption)
                                                    .foregroundColor(theme.textSecondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer(minLength: 8)
                                            Text(Self.formatter.string(from: entry.date))
                                                .font(Typography.caption)
                                                .foregroundColor(theme.textSecondary)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        Divider().background(theme.divider)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 130)
                }
            }
            .padding(22)
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

    private func taskRow(_ task: ScheduledTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: task.kind.symbol)
                .font(Glyph.row)
                .foregroundColor(theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.kind.title).font(Typography.body)
                Text("\(task.timeText) · \(task.weekdayText)")
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                if let summary = Self.conditionText(task) {
                    Text(summary)
                        .font(Typography.caption)
                        .foregroundColor(theme.textTertiary)
                }
            }
            Spacer()
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

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

