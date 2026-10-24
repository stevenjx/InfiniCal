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
                    Text("任务")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: "在指定时间自动执行充电、放电或校准操作。")
                    Spacer()
                }
                .frame(height: 34)

                Card(padding: 0) {
                    Group {
                        if state.tasks.isEmpty {
                            Text("点击 “+” 按钮添加新任务，或从现有模板中选择。")
                                .font(.system(size: 12))
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
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.innerControl))
                            .foregroundColor(theme.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("周末充满") {
                            var task = ScheduledTask()
                            task.kind = .topUp
                            task.hour = 9
                            task.weekdays = [6, 7]
                            state.addTask(task)
                        }
                        Button("周一早晨充满") {
                            var task = ScheduledTask()
                            task.kind = .topUp
                            task.hour = 7
                            task.weekdays = [1]
                            state.addTask(task)
                        }
                        Button("每月校准") {
                            var task = ScheduledTask()
                            task.kind = .calibrate
                            task.hour = 9
                            task.weekdays = [1]
                            state.addTask(task)
                        }
                        Button("每两周校准") {
                            var task = ScheduledTask()
                            task.kind = .calibrate
                            task.hour = 9
                            task.weekdays = [1, 3]
                            state.addTask(task)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.doc").font(.system(size: 11))
                            Text("模板").font(.system(size: 12, weight: .medium))
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
                          title: "自动补做未完成的任务",
                          help: "启用后，AIBattery 会自动运行 MacBook 处于睡眠或关机状态时未执行的任务。",
                          isOn: $state.startTasksAfterDue)

                HStack(spacing: 10) {
                    IconBadge(symbol: "list.bullet.rectangle")
                    Text("任务历史")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: "已执行的任务会记录在此处。")
                    Spacer()
                    if !state.taskHistory.isEmpty {
                        Button("清除") { state.clearTaskHistory() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .frame(height: 34)
                .padding(.top, 6)

                Card(padding: 0) {
                    Group {
                        if state.taskHistory.isEmpty {
                            Text("已执行的任务将显示在此处。")
                                .font(.system(size: 12))
                                .foregroundColor(theme.textSecondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(state.taskHistory) { entry in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.title).font(.system(size: 12))
                                                Text(entry.detail)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(theme.textSecondary)
                                            }
                                            Spacer()
                                            Text(Self.formatter.string(from: entry.date))
                                                .font(.system(size: 10))
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
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.kind.title).font(.system(size: 12))
                Text("\(task.timeText) · \(task.weekdayText)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.textSecondary)
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
                    .font(.system(size: 11))
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

    func reset() {
        kind = .topUp
        value = 80
        hour = 9
        minute = 0
        weekdays = Set(1...7)
    }

    var task: ScheduledTask {
        ScheduledTask(kind: kind, value: value, hour: hour, minute: minute, weekdays: weekdays)
    }
}

struct TaskEditor: View {
    private var theme: Theme { Theme.current }
    @ObservedObject var draft: TaskDraft
    var onSave: (ScheduledTask) -> Void
    var onCancel: () -> Void

    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建任务")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.textPrimary)

            Picker("操作", selection: $draft.kind) {
                ForEach(TaskKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if draft.kind == .setLimit || draft.kind == .startDischarge {
                HStack {
                    Text("目标电量").font(.system(size: 12))
                    Spacer()
                    ValueStepper(value: $draft.value, range: 10...100, step: 5)
                        .frame(width: 110)
                }
            }

            HStack {
                Text("时间").font(.system(size: 12))
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
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(draft.weekdays.contains(day) ? theme.accent : theme.innerControl))
                            .foregroundColor(draft.weekdays.contains(day) ? .white : theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.textSecondary)
                Button("保存") { onSave(draft.task) }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .padding(.leading, 14)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(20)
        .frame(width: 360)
    }
}

