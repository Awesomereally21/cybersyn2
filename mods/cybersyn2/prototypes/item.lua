local data_lib = require("lib.core.data-util")

---@type data.ItemPrototype
local combinator_item = data_lib.copy_prototype(
	data.raw["item"]["decider-combinator"],
	"cybersyn2-combinator"
)
combinator_item.icon = "__cybersyn2__/graphics/icons/combinator.png"
combinator_item.icon_size = 64
combinator_item.subgroup = data.raw["item"]["train-stop"].subgroup
combinator_item.order = data.raw["item"]["train-stop"].order .. "-b"
combinator_item.place_result = "cybersyn2-combinator"

if mods["nullius"] then
       combinator_item.localised_name = { "item-name.cybersyn2-combinator" }
       -- Enable item in Nullius and place next to the regular train stop
       combinator_item.order = "nullius-eca"
end

data:extend({ combinator_item })
