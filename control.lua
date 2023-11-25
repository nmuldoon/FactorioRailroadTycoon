require("util")
local blueprints = require("tycoon-blueprints")

function print_table(t, indent)
    indent = indent or ''
    for key, value in pairs(t) do
        if type(value) == 'table' then
            log(indent .. tostring(key) .. ':')
            -- game.print(indent .. tostring(key) .. ':')
            print_table(value, indent .. '  ')
        else
            log(indent .. tostring(key) .. ': ' .. tostring(value))
            -- game.print(indent .. tostring(key) .. ': ' .. tostring(value))
        end
    end
end

function shuffle(tbl)
    for i = #tbl, 2, -1 do
        local j = math.random(i)
        tbl[i], tbl[j] = tbl[j], tbl[i]
    end
    return tbl
end


-- resource names
IRON_ORE = "iron-ore"
COPPER_ORE = "copper-ore"
STONE = "stone"
COAL = "coal"
URANIUM_ORE = "uranium-ore"
CRUDE_OIL = "crude-oil"

-- global state
IN_MIDDLE_OF_ORE_PATCH_GEN = false; 
BUILT_AREAS = {}; -- {{min_x, max_x, min_y, max_y},...}
BUILT_POINTS = {} -- {{x,y},...}
BUILDING_INDEX = 1;
local BUILDINGS = {
    {blueprints.powerplant_1, blueprints.powerplant_2, blueprints.powerplant_3},
    -- smelters
    {blueprints.smelter_small_1, blueprints.smelter_small_2, blueprints.smelter_small_3, blueprints.smelter_small_4},
    {blueprints.smelter_small_1, blueprints.smelter_small_2, blueprints.smelter_small_3, blueprints.smelter_small_4},

    {blueprints.red_science_1, blueprints.red_science_2, blueprints.red_science_3, blueprints.red_science_4},
    {blueprints.green_science_1, blueprints.green_science_2, blueprints.green_science_3, blueprints.green_science_4},
    {blueprints.black_science_1, blueprints.black_science_2, blueprints.black_science_3, blueprints.black_science_4},
    
    {blueprints.research_lab_small, blueprints.research_lab_med},
    {blueprints.smelter_big_1, blueprints.smelter_big_2, blueprints.smelter_big_3, blueprints.smelter_big_4},
    {blueprints.research_lab_big_1, blueprints.research_lab_big_2},
}


function _get_offset_entities_from_blueprint(bp_string, surface, offset)
    -- Helper function for working with blueprints

    -- load the blueprint via an item
    local bp_entity = surface.create_entity{name='item-on-ground', position={x=0, y=0}, stack='blueprint'}
    log(bp_string)
    bp_entity.stack.import_stack(bp_string)
    log(bp_entity)
    print_table(bp_entity)
    local bp_entities = bp_entity.stack.get_blueprint_entities()
    bp_entity.destroy()

    -- calculate average position of entities, so we can place from the center of the blueprint
    -- if there are ANY mines in the blueprint, ONLY use them for calculating the center offset
    -- so mines can be placed directly on the center of ore patches.
    local position_sum = {x = 0, y = 0}
    local mine_sum = {x = 0, y = 0}
    local mine_count = 0;
    local entity_count = #bp_entities
    for _, entity in pairs(bp_entities) do
        position_sum.x = position_sum.x + entity.position.x
        position_sum.y = position_sum.y + entity.position.y

        if entity.name == "electric-mining-drill" or entity.name == "burner-mining-drill" then
            mine_count = mine_count + 1
            mine_sum.x = mine_sum.x + entity.position.x
            mine_sum.y = mine_sum.y + entity.position.y
        end
    end

    -- add to offset
    local adjusted_offset;
    if mine_count > 0 then
        adjusted_offset = {x = offset.x - mine_sum.x / mine_count, y = offset.y - mine_sum.y / mine_count}
    else
        adjusted_offset = {x = offset.x - position_sum.x / entity_count, y = offset.y - position_sum.y / entity_count}
    end
    
    -- train tracks are on a 2x2 grid, not 1x1, so any blueprints with trains get fucked up if you try to offset them by a non even number
    -- floor to even number
    adjusted_offset.x = math.floor(adjusted_offset.x / 2) * 2
    adjusted_offset.y = math.floor(adjusted_offset.y / 2) * 2
    for _,entity in pairs(bp_entities) do
        entity.position = {x = entity.position.x + adjusted_offset.x, y = entity.position.y + adjusted_offset.y}
    end

    return bp_entities
end

function _do_areas_intersect(area1, area2)
    -- Check if area1 is to the left of area2 or to the right of area2
    if area1.max_x < area2.min_x or area1.min_x > area2.max_x then
        return false
    end

    -- Check if area1 is above area2 or below area2
    if area1.max_y < area2.min_y or area1.min_y > area2.max_y then
        return false
    end

    -- If none of the above conditions are met, the areas intersect
    return true
end

function _get_bounding_box_for_blueprint(bp_string, surface, offset)
    -- Returns: {min_x, max_x, min_y, max_y} of built stuff
    -- NOTE: this only includes the origin positions of each object, not bounding boxes.

    local bp_entities = _get_offset_entities_from_blueprint(bp_string, surface, offset)

    local result = {min_x = math.huge, max_x = -math.huge, min_y = math.huge, max_y = -math.huge}
    for _, entity in pairs(bp_entities) do
        result.min_x = math.min(result.min_x, entity.position.x)
        result.min_y = math.min(result.min_y, entity.position.y)
        result.max_x = math.max(result.max_x, entity.position.x)
        result.max_y = math.max(result.max_y, entity.position.y)
    end

    return result;
end



function build_blueprint_from_string(bp_string, surface, offset)
    -- Builds the blueprint at the given offset location, deleting all obstacles and filling in water with concrete

    local bp_entities = _get_offset_entities_from_blueprint(bp_string, surface, offset)

    -- clear obstacles on the ground
    for _,entity in pairs(bp_entities) do

        -- delete everything except for resources
        local blockers = surface.find_entities_filtered{position=entity.position, radius=3.0, type="resource", invert=true}
        for _,blocker in pairs(blockers) do
            if blocker and blocker.valid then
                blocker.destroy{do_cliff_correction=true}
            end
        end
    end

    -- now create the new thing and fill in water
    for _,entity in pairs(bp_entities) do

        -- create the new entity from blueprint
        entity.force = 'player'
        entity = surface.create_entity(entity)  -- prototype and collision box are not inflated until the entity is actually created

        -- Get top-left and bottom-right points of the collision box to fill in water
        local collision_box = entity.prototype.collision_box
        local top_left = {x = entity.position.x + collision_box.left_top.x, y = entity.position.y + collision_box.left_top.y}
        local bottom_right = {x = entity.position.x + collision_box.right_bottom.x, y = entity.position.y + collision_box.right_bottom.y}
        
        -- Create an empty table to hold the tiles we're going to change
        local tiles_to_change = {}

        -- Iterate through each tile within the bounding box
        for x = math.floor(top_left.x), math.ceil(bottom_right.x) do
            for y = math.floor(top_left.y), math.ceil(bottom_right.y) do

                -- only change water tiles
                local tile = surface.get_tile(x, y)
                if tile.valid and (tile.name == "water" or tile.name == "deepwater") then
                    table.insert(tiles_to_change, {name = "refined-concrete", position = {x, y}})
                end
            end
        end
        
        entity.surface.set_tiles(tiles_to_change)
    end
end


function try_and_track_build_blueprint(bp_string, surface, offset)
    local new_area = _get_bounding_box_for_blueprint(bp_string, surface, offset)

    for _, area in pairs(BUILT_AREAS) do
        if _do_areas_intersect(new_area, area) then
            log("blocked area!")
            return false;
        end
    end

    log("original offset: ")
    print_table(offset, "  ")

    build_blueprint_from_string(bp_string, surface, offset);
    table.insert(BUILT_AREAS, new_area);
    table.insert(BUILT_POINTS, offset)
    return true;

end


function research_train_tech(player)
    if player and player.force then
        -- List of technologies to be researched
        local technologies = {
            "automation",
            "logistics",
            "electronics",
            "automation-2",
            "logistic-science-pack",
            "stack-inserter",
            "fast-inserter",
            "engine",
            "logistics-2",
            "automobilism",
            "railway",
            "automated-rail-transportation",
            "rail-signals",
            "fluid-handling",
            "fluid-wagon",
        }

        for _, tech in pairs(technologies) do
            if player.force.technologies[tech] then
                player.force.technologies[tech].researched = true
            else
                log("Technology '" .. tech .. "' does not exist.")
            end
        end
    end
end


function build_starter_base(surface)
    try_and_track_build_blueprint(blueprints.home, surface, {x=0, y=-25})

    -- fill the warehouse with stuff
    local warehouse = surface.find_entities_filtered{name="warehouse-basic"}[1]
    warehouse.insert{name="iron-plate", count=3000}
    warehouse.insert{name="copper-plate", count=3000}
    warehouse.insert{name="steel-plate", count=3000}
    warehouse.insert{name="coal", count=3000}
    warehouse.insert{name="stone", count=3000}

    -- start the boilers with coal to avoid cold start problem
    local boilers = surface.find_entities_filtered{name="boiler"}
    for _, boiler in pairs(boilers) do
        boiler.insert{name="coal", count=50}
    end

    -- start the storehouse with some pre-built stuff
    local storehouse = surface.find_entities_filtered{name="storehouse-basic"}[1]
    storehouse.insert{name="big-electric-pole", count=200}
    storehouse.insert{name="medium-electric-pole", count=50}
    storehouse.insert{name="rail", count=1000}
    storehouse.insert{name="rail-signal", count=100}
    storehouse.insert{name="rail-chain-signal", count=100}
    storehouse.insert{name="train-stop", count=20}
    storehouse.insert{name="fluid-wagon", count=10}
    storehouse.insert{name="cargo-wagon", count=10}
    storehouse.insert{name="locomotive", count=20}
    storehouse.insert{name="car", count=2}
    storehouse.insert{name="submachine-gun", count=2}
    storehouse.insert{name="uranium-rounds-magazine", count=300}
    storehouse.insert{name="cliff-explosives", count=30}
    storehouse.insert{name="transport-belt", count=500}
    storehouse.insert{name="fast-inserter", count=100}
    storehouse.insert{name="stack-filter-inserter", count=50}
    storehouse.insert{name="landfill", count=500}
end


function build_cities_in_chunk_generation(event)
    --- Called from on_chunk_generated
    local surface = event.surface
    local position = {x = event.position.x * 32 + 16, y = event.position.y * 32 + 16}  -- convert from chunk coords to world coords

    -- sparsity: min distance to other locations
    local min_dist = 150
    for _, pt in pairs(BUILT_POINTS) do
        if (position.x - pt.x)^2 + (position.y - pt.y)^2 < min_dist^2 then
            return
        end
    end
    
    -- don't build if center of tile is water
    local tile = surface.get_tile(position.x, position.y)
    if tile.valid and (tile.name == "water" or tile.name == "deepwater") then
        return
    end

    -- build through the rotation of buildings
    local which_variant_index = math.random(#BUILDINGS[BUILDING_INDEX])
    local success = try_and_track_build_blueprint(BUILDINGS[BUILDING_INDEX][which_variant_index], surface, position);

    if success then -- rotate to the next building
        BUILDING_INDEX = BUILDING_INDEX + 1
        if BUILDING_INDEX > #BUILDINGS then  -- damn zero indexing makes mod not work directly
            BUILDING_INDEX = 1
        end
    end

end


function build_mines_in_chunk_generation(event)
    --- Called from on_chunk_generated
    local surface = event.surface
    local area = event.area
    local this_chunk_ores = surface.find_entities_filtered({area = area, type = "resource"})

    if #this_chunk_ores == 0 then
        return;
    end

    local ore_name = this_chunk_ores[1].name;
    if ore_name == CRUDE_OIL or ore_name == URANIUM_ORE then
        return;
    end

    -- error checking done
    IN_MIDDLE_OF_ORE_PATCH_GEN = true;  -- used to prevent multiple threads

    local ore_position = this_chunk_ores[1].position
    surface.request_to_generate_chunks(ore_position, 2);
    surface.force_generate_chunk_requests();

    -- surrounding area is generated now. Find all of the ore nearby.
    local all_nearby_ores = surface.find_entities_filtered{position=ore_position, radius=60, type="resource", name=ore_name};

    -- find bounds of the ore patch
    local ore_bounds = {min_x = math.huge, max_x = -math.huge, min_y = math.huge, max_y = -math.huge}
    for _, entity in pairs(all_nearby_ores) do
        ore_bounds.min_x = math.min(ore_bounds.min_x, entity.position.x)
        ore_bounds.min_y = math.min(ore_bounds.min_y, entity.position.y)
        ore_bounds.max_x = math.max(ore_bounds.max_x, entity.position.x)
        ore_bounds.max_y = math.max(ore_bounds.max_y, entity.position.y)
    end
    local ore_center = {
        x = (ore_bounds.min_x + ore_bounds.max_x) / 2,
        y = (ore_bounds.min_y + ore_bounds.max_y) / 2
    }
    local ore_width = ore_bounds.max_x - ore_bounds.min_x;

     -- [up, down, left, right]
    local possible_mines = {
        micro = {blueprints.micro_mine_up, blueprints.micro_mine_down, blueprints.micro_mine_left, blueprints.micro_mine_right},
        small = {blueprints.small_mine_up, blueprints.small_mine_down, blueprints.small_mine_left, blueprints.small_mine_right},
        big = {blueprints.big_mine_up, blueprints.big_mine_down, blueprints.big_mine_left, blueprints.big_mine_right},
    }

    local mine_size;
    if ore_width < 16 then
        mine_size = "micro"
    elseif ore_width < 36 then
        mine_size = "small"
    else
        mine_size = "big"
    end

    local direction = math.random(4)  -- [up, down, left, right]
    try_and_track_build_blueprint(possible_mines[mine_size][direction], surface, ore_center);

    IN_MIDDLE_OF_ORE_PATCH_GEN = false;  -- let other threads resume
end


script.on_event(defines.events.on_chunk_generated, function(event) 
    if IN_MIDDLE_OF_ORE_PATCH_GEN then
        return;
    end

    build_mines_in_chunk_generation(event);
    build_cities_in_chunk_generation(event);

end)


script.on_event(defines.events.on_player_created, function(event)
    -- NOTE on coordinates:
    -- blueprints are from where you select, not just the parts in it
    -- positive X and Y are down and to the rights
    local player = game.players[event.player_index]
    local surface = player.surface

    -- start with basic stuff researched
    research_train_tech(player)
    build_starter_base(surface)
end)

