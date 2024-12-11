--- @sync entry

local project_deps = "./deps/share/lua/5.2/?.lua;./deps/share/lua/5.2/?/init.lua"
local project_cdeps = "./deps/lib/lua/5.2/?.so"

package.path = project_deps .. ";" .. package.path
package.cpath = project_cdeps .. ";" .. package.cpath
local curses = require("curses")

local plugin_name = "udisk-menu"
local M = {}

local ERROR_MSG = {
	COMMAND_NOT_FOUND = plugin_name .. ": Failed to start `%s`, do you have `%s` installed?",
	READ_PARTTIONS_FAILED = plugin_name .. ": Failed to read partitions",
}

local STATES = {
	DISABLED = "DISABLED",
	DISKS = "DISKS",
	PARTITIONS = "PARTITIONS",
	SELECTED_PARTITION_NUM = "SELECTED_PARTITION_NUM",
	SELECTED_MOUNT_POINT = "SELECTED_MOUNT_POINT",
}

function table:deep_merge(tbl2)
	for key, value in pairs(tbl2) do
		if type(value) == "table" and type(self[key]) == "table" then
			-- Recursively merge nested tables
			self[key] = deep_merge(self[key], value)
		else
			-- Overwrite or add the value
			self[key] = value
		end
	end
	return self
end

local function error(s, ...)
	ya.notify({ title = plugin_name, content = string.format(s, ...), timeout = 3, level = "error" })
end

local function info(s, ...)
	ya.notify({ title = plugin_name, content = string.format(s, ...), timeout = 3, level = "info" })
end

local set_state = ya.sync(function(state, archive, key, value)
	if state[archive] then
		state[archive][key] = value
	else
		state[archive] = {}
		state[archive][key] = value
	end
end)

local get_state = ya.sync(function(state, archive, key)
	if state[archive] then
		return state[archive][key]
	else
		return nil
	end
end)

function M:command_exists(cmd)
	local handle = io.popen("command -v " .. cmd .. " >/dev/null 2>&1 && echo true || echo false")
	local result = handle:read("*a")
	handle:close()
	return result:match("true") ~= nil
end

function M:requirements_check()
	local list_cmd = {
		"lsblk",
		"udisksctl",
	}

	for _, cmd in ipairs(list_cmd) do
		if not self:command_exists("lsblk") then
			error(ERROR_MSG.COMMAND_NOT_FOUND, cmd, cmd)
			return false
		end
	end
	return true
end

---parse lsblk info into disks and partitions
---@param blk_block_devices_or_parts table
---@return table disks
---@return table partitions
local function read_blkinfo_children(blk_block_devices_or_parts)
	local disks = {}
	local partitions = {}
	if type(blk_block_devices_or_parts) ~= "table" or #blk_block_devices_or_parts == 0 then
		return disks, partitions
	end

	for _, block in ipairs(blk_block_devices_or_parts) do
		if block.type == "disk" then
			disks[block.id] = block:deep_merge({ children = nil })
		elseif not block.children or #block.children == 0 then
			partitions[block.id] = block:deep_merge({ children = nil })
		else
			partitions = partitions:deep_merge(read_blkinfo_children(block.children))
		end
	end
	return disks, partitions
end

function M:reset_selected_partn()
	local selected_partition_num = get_state("global", STATES.SELECTED_PARTITION_NUM)
	local number_of_partitions = #(get_state("global", STATES.PARTITIONS) or 0)
	set_state(
		"global",
		STATES.SELECTED_PARTITION_NUM,
		selected_partition_num > number_of_partitions and number_of_partitions or selected_partition_num
	)
end

function M:read_partitions()
	local res, _ = Command("lsblk"):args({ "--all", "--json", "-O" }):output()
	if res and res.status.success then
		local blkinfo = ya.json_decode(res.stdout:gsub("0B,", '"0B",'))

		if type(blkinfo) ~= "table" or type(blkinfo["blockdevices"]) ~= "table" or #blkinfo["blockdevices"] == 0 then
			error(ERROR_MSG.READ_PARTTIONS_FAILED)
			return
		end
		local disks, partitions = read_blkinfo_children(blkinfo["blockdevices"])
		self:reset_selected_partn()
		set_state("global", STATES.DISKS, disks)
		set_state("global", STATES.PARTITIONS, partitions)
		return disks, partitions
	end
end

-- TODO: if fstype == "crypto_LUKS" -> "udisksctl unlock - b /dev/sda1"
-- the device will be unlocked and a mapped device will be created (e.g., /dev/dm-0 or /dev/mapper/luks-<uuid>).
-- TODO: then mount: udisksctl mount -b /dev/dm-0
function M:get_parts_by_diskid(diskid)
	local partitions = get_state("global", STATES.PARTITIONS) or {}
	local parts = {}
	for _, part_value in pairs(partitions) do
		if part_value.ptuuid == diskid then
			table.insert(parts, part_value)
		end
	end
	return parts
end

local current_file = ya.sync(function()
	return cx.active.current.hovered
end)

local styles = {
	header = ui.Style():fg("green"),
	row_label = ui.Style():fg("reset"),
	row_value = ui.Style():fg("blue"),
	row_value_spot_hovered = ui.Style():fg("blue"):reverse(),
}

function M:render(disks, partitions, area)
	local render_rows = function(parts)
		local r = {}
		for _, p in ipairs(parts) do
			table.insert(r, {
				ui.Row({
					ui.Span(p.name),
					ui.Span(p.size),
					ui.Span(p.label),
					ui.Span(p.mountpoint == "null" and "Not mounted" or p.mountpoint),
				}),
			})
		end
		return r
	end

	local tables = {}
	for disk_id, disk_value in pairs(disks) do
		local parts = self:get_parts_by_diskid(disk_id)
		table.insert(tables, {
			ui.Table(render_rows(parts))
				:area(area)
				:header("~ " .. disk_value.name .. ' "' .. disk_value.model .. '" ' .. disk_value.size)
				:col_style(styles.row_value)
				:widths({
					ui.Constraint.Fill(1),
				})
				:spacing(4),
		})
	end
	return ya.list_merge({
		ui.Clear(area),
		ui.Border(ui.Border.ALL):area(area):type(ui.Border.ROUNDED):title("Mounting Disk"),
		ui.Text(
			ui.Line("Press 'm' to mount, 'u' to unmount, 'g' to refresh"),
			ui.Line("Press 'e' to unmount all, 'p' to poweroff drive, 'enter' to cd")
		)
			:area(area)
			:align(ui.Text.LEFT)
			:wrap(ui.Text.WRAP),
	}, tables)
end

function M:toggle_spotter()
	local disks, partitions = self:read_partitions()
	local area = ui.Pos({ "center", w = 80, h = 80 })
	ya.spot_widgets({
		file = current_file(),
		mime = "text/plain",
		skip = 0,
	}, self:render(disks, partitions, area))
end

function M:entry(args)
	if not self:requirements_check() then
		return
	end
	self:toggle_spotter()
end

return M
