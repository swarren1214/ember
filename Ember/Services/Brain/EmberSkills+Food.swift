import Foundation

// The food answer lives on the iPhone: Sated's log comes from the app group (HearthFoodLog),
// which the Watch doesn't have.

extension EmberSkills {
    // MARK: Food (Sated)

    static func food(_ log: HearthFoodLog, day spoken: String, now: Date = .now) -> EmberAnswer {
        let range = EmberDates.range(spoken, lean: .past, fallback: "today", now: now)
        if range.days > 1 {
            let days = log.days.filter { day in HearthDay.date(from: day.date).map(range.contains) ?? false }
            let logged = days.filter { !$0.entries.isEmpty }
            guard !logged.isEmpty else { return .missing("Nothing logged in Sated \(range.label()). Sated shares the last seven days.") }
            let average = logged.reduce(0) { $0 + $1.totals.calories } / Double(logged.count)
            let lines = logged.map { "\($0.date): \(Int($0.totals.calories)) calories, \(Int($0.totals.protein)) g protein" }
            return EmberAnswer(facts: "Logged \(logged.count) of \(days.count) days \(range.label()); average \(Int(average)) calories a day against a goal of \(Int(log.goals.calories)).\n" + lines.joined(separator: "\n"),
                               title: "Food log", value: "\(Int(average)) cal", subtitle: "average a day", rows: logged.map { EmberRow(title: $0.date, value: "\(Int($0.totals.calories)) cal") })
        }
        guard let day = log.day(range.start) else { return .missing("Sated hasn't shared \(range.label()) yet. It shares the last seven days when it's opened.") }
        let left = log.goals.calories - day.totals.calories
        var lines = ["\(range.label()): \(Int(day.totals.calories)) of \(Int(log.goals.calories)) calories (\(left >= 0 ? "\(Int(left)) left" : "\(Int(-left)) over")), \(Int(day.totals.protein)) of \(Int(log.goals.protein)) g protein, \(Int(day.totals.carbs)) g carbs, \(Int(day.totals.fat)) g fat."]
        let meals = Dictionary(grouping: day.entries, by: \.meal)
        for meal in ["breakfast", "lunch", "dinner", "snack"] {
            if let items = meals[meal] { lines.append("\(meal.capitalized): " + items.map { "\($0.name) (\(Int($0.calories)))" }.joined(separator: ", ")) }
        }
        if day.entries.isEmpty { lines.append("Nothing logged yet.") }
        return EmberAnswer(facts: lines.joined(separator: "\n"), title: "Calories", value: "\(Int(max(left, 0)))",
                           subtitle: left >= 0 ? "left of \(Int(log.goals.calories))" : "\(Int(-left)) over",
                           rows: day.entries.suffix(6).map { EmberRow(title: $0.name, value: "\(Int($0.calories))", detail: $0.meal.capitalized) },
                           fraction: log.goals.calories > 0 ? day.totals.calories / log.goals.calories : nil)
    }
}
