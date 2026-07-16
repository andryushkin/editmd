import Foundation

enum FileTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank
    case note
    case meeting
    case project
    case research
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Пустой"
        case .note: "Заметка"
        case .meeting: "Встреча"
        case .project: "Проект"
        case .research: "Исследование"
        case .daily: "Ежедневная заметка"
        }
    }

    func rendered(title: String, date: String) -> String {
        source
            .replacingOccurrences(of: "{{yamlTitle}}", with: yamlSingleQuotedTemplateTitle(title))
            .replacingOccurrences(of: "{{date}}", with: date)
            .replacingOccurrences(of: "{{title}}", with: title)
    }

    private var source: String {
        switch self {
        case .blank:
            ""
        case .note:
            """
            ---
            title: {{yamlTitle}}
            date: {{date}}
            tags: []
            ---

            # {{title}}

            """
        case .meeting:
            """
            ---
            title: {{yamlTitle}}
            date: {{date}}
            type: meeting
            attendees: []
            tags: []
            ---

            # {{title}}

            ## Повестка

            ## Заметки

            ## Решения

            """
        case .project:
            """
            ---
            title: {{yamlTitle}}
            date: {{date}}
            type: project
            status: active
            tags: []
            ---

            # {{title}}

            ## Цель

            ## Задачи

            - [ ]

            ## Заметки

            """
        case .research:
            """
            ---
            title: {{yamlTitle}}
            date: {{date}}
            type: research
            status: active
            tags: []
            ---

            # {{title}}

            ## Вопрос

            ## Источники

            ## Выводы

            """
        case .daily:
            """
            ---
            title: '{{date}}'
            date: {{date}}
            type: daily
            tags: []
            ---

            # {{date}}

            ## Заметки

            ## Задачи

            - [ ]

            """
        }
    }
}

func fileTemplateDateString(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

func yamlSingleQuotedTemplateTitle(_ title: String) -> String {
    "'\(title.replacingOccurrences(of: "'", with: "''"))'"
}
