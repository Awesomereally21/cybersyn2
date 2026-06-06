local data_lib = require("lib.core.data-util")

---@type data.RecipePrototype
local combinator_recipe = data_lib.copy_prototype(
	data.raw["recipe"]["decider-combinator"],
	"cybersyn2-combinator"
)
-- TODO: recipe enabled without research for testing, add tech for live
combinator_recipe.enabled = false
combinator_recipe.subgroup = data.raw["recipe"]["train-stop"].subgroup

local cybersyn_tech = data_lib.copy_prototype(
       data.raw["technology"]["automated-rail-transportation"],
       "cybersyn2-train-network"
)
cybersyn_tech.icon_size = 256

cybersyn_tech.icon = "__cybersyn2__/graphics/icons/combinator.png"

cybersyn_tech.effects = {
       {
               type = "unlock-recipe",
               recipe = "cybersyn2-combinator",
       },
}
cybersyn_tech.unit.ingredients = {
       { "automation-science-pack", 1 },
       { "logistic-science-pack", 1 },
}
cybersyn_tech.unit.count = 200
cybersyn_tech.order = "c-g-c"

--Credit to modo-lv for submitting the following code
if mods["nullius"] then
       -- Enable recipe and place it just after regular station
       combinator_recipe.order = "nullius-eca"
       -- In Nullius, most combinators are tiny crafts
       combinator_recipe.category = "tiny-crafting"
       combinator_recipe.always_show_made_in = true
       combinator_recipe.energy_required = 3
       combinator_recipe.ingredients = {
               { type = "item", name = "arithmetic-combinator", amount = 2 },
               { type = "item", name = "copper-cable", amount = 10 },
       }
       -- Enable technology
       cybersyn_tech.order = "nullius-" .. cybersyn_tech.order
       cybersyn_tech.unit = {
               count = 100,
               ingredients = {
                       { "nullius-geology-pack", 1 },
                       { "nullius-climatology-pack", 1 },
                       { "nullius-mechanical-pack", 1 },
                       { "nullius-electrical-pack", 1 },
               },
               time = 25,
       }
       cybersyn_tech.prerequisites = { "nullius-traffic-control" }
       cybersyn_tech.ignore_tech_tech_cost_multiplier = true
end

data:extend({ combinator_recipe, cybersyn_tech })
