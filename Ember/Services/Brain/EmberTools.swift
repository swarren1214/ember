import Foundation
import FoundationModels

// The tools as Apple's on-device model sees them. Each hands its work to EmberToolbox on the
// main actor; the same toolbox answers Claude's tool calls on the cloud path, so both tiers
// read the same data the same way. Names match hearth-api's allowlist (src/ember/tools.ts).

nonisolated struct HouseholdPeopleTool: Tool {
    let name = "household_people"
    let description = "Lists who is in the household: names, roles (parent, adult, kid) and ages, and who is asking."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always true")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await toolbox.householdPeople()
    }
}

nonisolated struct MealsPlannedTool: Tool {
    let name = "meals_planned"
    let description = "Gets what BigTable has planned for breakfast, lunch or dinner on a day or a week, and who isn't eating."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Which days. Use \"today\" for tonight.", .anyOf(EmberDays.choices))
        var days: String
        @Guide(description: "The meal they asked about, or all", .anyOf(["breakfast", "lunch", "dinner", "all"]))
        var meal: String
    }

    func call(arguments: Arguments) async throws -> String {
        let days = arguments.days
        let meal = arguments.meal
        return await toolbox.mealsPlanned(days: days, meal: meal)
    }
}

nonisolated struct MealFitsTool: Tool {
    let name = "meal_fits_household"
    let description = "Checks whether a planned meal fits everyone's food allergies. Use before suggesting a planned meal."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The day", .anyOf(EmberDays.choices))
        var day: String
        @Guide(description: "The meal", .anyOf(["breakfast", "lunch", "dinner"]))
        var meal: String
    }

    func call(arguments: Arguments) async throws -> String {
        let day = arguments.day
        let meal = arguments.meal
        return await toolbox.mealFits(days: day, meal: meal)
    }
}

nonisolated struct MealTimesTool: Tool {
    let name = "meal_times"
    let description = "Gets when the family eats breakfast, lunch and dinner."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always true")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await toolbox.mealTimes()
    }
}

nonisolated struct GroceryStatusTool: Tool {
    let name = "grocery_status"
    let description = "Gets how many things are left on BigTable's grocery list and what the list should cost."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always true")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await toolbox.groceryStatus()
    }
}

nonisolated struct BudgetStatusTool: Tool {
    let name = "budget_status"
    let description = "Gets this month's grocery budget from Suffice: how much is left, spent and planned."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always true")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await toolbox.budgetStatus()
    }
}

nonisolated struct AllowanceTool: Tool {
    let name = "allowance_recent"
    let description = "Gets the allowance Caloma paid each kid in the last 30 days."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always true")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await toolbox.allowanceRecent()
    }
}

nonisolated struct StudyTodayTool: Tool {
    let name = "study_today"
    let description = "Gets today's scripture reading from Hearken and whether it's done."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always true")
        var all: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await toolbox.studyToday()
    }
}

nonisolated struct OpenAppTool: Tool {
    let name = "open_app"
    let description = "Adds a button that opens the right Hearth app to change something there: add groceries, change the plan, move money, chores, the calendar, the reading or the food log. Ember can't change those itself."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Where to go", .anyOf(["grocery_list", "meal_plan", "budget", "chores", "calendar", "reading", "food_log"]))
        var place: String
    }

    func call(arguments: Arguments) async throws -> String {
        let place = arguments.place
        return await toolbox.openApp(place)
    }
}

nonisolated struct MessageDraftTool: Tool {
    let name = "message_draft"
    let description = "Drafts a text message the person sends themselves from Messages, after picking who it goes to."
    let toolbox: EmberToolbox

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The message, in the person's own voice")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        let text = arguments.text
        return await toolbox.messageDraft(text)
    }
}

enum EmberTools {
    /// The on-device tools for this turn, matching `EmberToolbox.toolNames`.
    @MainActor
    static func onDevice(_ toolbox: EmberToolbox) -> [any Tool] {
        let all: [any Tool] = [
            HouseholdPeopleTool(toolbox: toolbox),
            MealsPlannedTool(toolbox: toolbox),
            MealFitsTool(toolbox: toolbox),
            MealTimesTool(toolbox: toolbox),
            GroceryStatusTool(toolbox: toolbox),
            BudgetStatusTool(toolbox: toolbox),
            AllowanceTool(toolbox: toolbox),
            StudyTodayTool(toolbox: toolbox),
            OpenAppTool(toolbox: toolbox),
            MessageDraftTool(toolbox: toolbox),
        ]
        let allowed = Set(toolbox.toolNames)
        return all.filter { allowed.contains($0.name) }
    }
}
