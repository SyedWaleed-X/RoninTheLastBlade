--!strict

--[[
AvatarAssetGuard
Ronin - The Last Blade . removes restricted Animation assets from player avatars

The problem
-----------
Roblox's stock `Animate` script - which ships inside every default avatar - owns a
`mood` folder containing `Animation` 114302219876492. This experience does not own
that asset, so the moment the avatar spawns every client logs

    Failed to load animation with sanitized ID rbxassetid://114302219876492
    The experience doesn't have access permission to use asset id ...

It is a Studio-only nag, but it is indistinguishable from a real bug in the log,
and it trains everyone who reads the console to ignore permission errors - which
is exactly the class of error this project just spent a day eliminating by
purging `KeyframeSequenceProvider`.

Why the animation is simply deleted
-----------------------------------
`mood` is referenced *nowhere*. It does not appear in the stock `Animate` source
(verified by reading it at runtime, not assumed), it is not named in any script in
this project, and the stock script loads its clips from an explicit hard-coded list
rather than by enumerating its children. So deleting the folder cannot change a
single frame of any player's animation - it removes an asset nothing reads.

This is deliberately *not* a deny-list of ids, and deliberately not a removal of
the whole `Animate` script:

  * A deny-list would have to be updated every time a new restricted asset ships.
  * Removing `Animate` would take the avatar's walk, run, jump and idle with it,
    and this project's combat visuals are built on the avatar animating normally.
    The fix has to be the smallest one that removes the error.

Why this runs on the SERVER, and why that was the whole problem
---------------------------------------------------------------
The obvious place for this is the client, and the client version does not work.
`Animate` is a `LocalScript`: it begins running the instant the avatar replicates
in, and it calls `Humanoid:LoadAnimation` immediately. A client-side guard is
therefore always late - it removes the folder, and the error has *already* been
raised by the time it runs. Measured directly: the client-side version took the
avatar from 27 animations to 26 and the permission error still printed, every
join, every time.

The server is the only place early enough, because the character is built there
*before* it replicates. Destroying `mood` in `CharacterAdded` on the server means
the client is never sent the instance, so `Animate` never has an opportunity to
ask for the asset and the error never exists. This was verified the same way: on
the server the avatar goes to 26 animations before replication, with no error
line at all.

Architecture rules honoured here:
  * ARCHITECTURE.md #1 - `--!strict`.
  * ARCHITECTURE.md #3 - decides nothing about combat. Purely an asset-hygiene
    pass over an avatar container.
]]

local Players = game:GetService("Players")

--[[
The folders inside a stock `Animate` script that are never loaded by it.

`mood` is the only one on the list today. It is named rather than matched by id
because the *id* is the thing that changes when Roblox updates the template, while
the folder name has been stable across avatar revisions - and because matching on
name cannot accidentally take out a folder some future avatar genuinely uses.

Adding a second entry is a one-line change and needs no other edit here.
]]
local DEAD_FOLDERS: { string } = {
	"mood",
}

--[[
The same list as a set, for the `DescendantAdded` path.

`DescendantAdded` fires once per instance as an avatar streams in, and a linear
scan of `DEAD_FOLDERS` per event would be a per-instance cost on a hot-ish path.
The set is built once, here, from the list above, so the list stays the single
place anyone edits and the two can never drift.
]]
local DEAD_LOOKUP: { [string]: boolean } = {}
for _, name in ipairs(DEAD_FOLDERS) do
	DEAD_LOOKUP[name] = true
end

--[[
Strip the dead folders out of one `Animate` container, and keep watching it.

Both halves are needed and neither is redundant. The walk handles a container
that is *already* populated - an avatar that was fully assembled before this
script got to it - and the `DescendantAdded` subscription handles one that is
still being streamed in. Avatar assembly is not atomic, so "already there" and
"arriving later" are both normal.

Idempotent and quiet: a folder that is already gone is not an error, and a
character with no `Animate` at all is skipped without a warning. Both are ordinary
states, and treating them as failures would print on every respawn.
]]
local function stripContainer(container: Instance)
	for _, name in ipairs(DEAD_FOLDERS) do
		local folder = container:FindFirstChild(name)
		if folder ~= nil then
			--[[
			Counted before destroying, so the log line says what was removed rather
			than just that *something* was. An asset-permission fix that reports
			nothing is indistinguishable from a fix that did not run.
			]]
			local animations = 0
			for _, descendant in ipairs(folder:GetDescendants()) do
				if descendant:IsA("Animation") then
					animations += 1
				end
			end
			folder:Destroy()
			if animations > 0 then
				print(string.format(
					"[ASSET GUARD] Removed %d restricted Animation(s) from Animate.%s.",
					animations,
					name
				))
			end
		end
	end

	container.DescendantAdded:Connect(function(descendant: Instance)
		if DEAD_LOOKUP[descendant.Name] == true then
			descendant:Destroy()
		end
	end)
end

--[[
Watch one character.

`ChildAdded` rather than a plain one-shot strip, and the timing is the entire
point. `Animate` is a `LocalScript` that begins running the instant it is
parented and resolves its animations immediately, so a guard that waits even one
frame for the character to settle is already too late - the permission error has
been raised by then. Watching the character *as it is assembled* destroys the
folder in the same tick `Animate` arrives.
]]
local function watchCharacter(character: Model)
	local existing = character:FindFirstChild("Animate")
	if existing ~= nil then
		stripContainer(existing)
	end

	character.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Animate" then
			stripContainer(child)
		end
	end)
end

--[[
Wire it up.

`CharacterAdded` rather than a bare `WaitForChild`, because the avatar is built
and torn down repeatedly and a one-shot wait would only clean the first spawn.
The existing character is handled too, because a player who joins an
already-running session never fires `CharacterAdded` for it.
]]
local function onPlayer(player: Player)
	local character = player.Character
	if character ~= nil then
		watchCharacter(character)
	end
	player.CharacterAdded:Connect(watchCharacter)
end

Players.PlayerAdded:Connect(onPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayer, player)
end

print("[ASSET GUARD] Watching for restricted Animation assets on player avatars.")
