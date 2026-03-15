-- dwight/auto/notify.lua
-- System notifications (OS-level, not vim.notify)

local M = {}

--- Detect OS and send a system notification.
--- Falls back silently if no notification tool is available.
function M._system_notify(title, body, urgency)
	urgency = urgency or "normal" -- "low", "normal", "critical"

	local uv = vim.loop or vim.uv
	local cmd, args

	if vim.fn.has("mac") == 1 then
		-- macOS: prefer terminal-notifier, fall back to osascript
		if vim.fn.executable("terminal-notifier") == 1 then
			cmd = "terminal-notifier"
			args = { "-title", title, "-message", body, "-sound", "default", "-group", "dwight-auto" }
		else
			cmd = "osascript"
			args = {
				"-e",
				string.format(
					'display notification "%s" with title "%s" sound name "Glass"',
					body:gsub('"', '\\"'),
					title:gsub('"', '\\"')
				),
			}
		end
	elseif vim.fn.executable("notify-send") == 1 then
		-- Linux: notify-send (libnotify)
		cmd = "notify-send"
		args = { "--urgency=" .. urgency, "--app-name=Dwight", title, body }
	elseif vim.fn.executable("powershell.exe") == 1 then
		-- Windows/WSL
		cmd = "powershell.exe"
		args = {
			"-Command",
			string.format(
				"[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); "
					.. "$n = New-Object System.Windows.Forms.NotifyIcon; "
					.. "$n.Icon = [System.Drawing.SystemIcons]::Information; "
					.. "$n.Visible = $true; "
					.. "$n.ShowBalloonTip(5000, '%s', '%s', 'Info')",
				title:gsub("'", "''"),
				body:gsub("'", "''")
			),
		}
	end

	if not cmd then
		return
	end -- no notification tool available

	-- Fire and forget — don't block Neovim
	local handle
	handle = uv.spawn(cmd, {
		args = args,
		stdio = { nil, nil, nil },
		detached = true,
	}, function()
		if handle then
			handle:close()
		end
	end)
end

--- Convenience wrappers.
function M._notify_progress(task_num, total, task_title)
	M._system_notify(string.format("Dwight [%d/%d]", task_num, total), string.format("Completed: %s", task_title))
end

function M._notify_failure(task_num, total, task_title, err)
	M._system_notify(
		string.format("Dwight [%d/%d] FAILED", task_num, total),
		string.format("%s\n%s", task_title, (err or ""):sub(1, 100)),
		"critical"
	)
end

function M._notify_done(request, duration, cost)
	local cost_str = cost and cost > 0 and string.format(" (~$%.2f)", cost) or ""
	M._system_notify(
		"Dwight: All Done!",
		string.format("%s\nCompleted in %ds%s", request:sub(1, 80), duration, cost_str)
	)
end

return M
