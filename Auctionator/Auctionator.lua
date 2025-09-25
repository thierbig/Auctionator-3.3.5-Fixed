
AuctionatorVersion = "???";		-- set from toc upon loading
AuctionatorAuthor  = "Zirco";

local AuctionatorLoaded = false;
local AuctionatorInited = false;

local addonName, addonTable = ...; 
local zc = addonTable.zc;

gAtrZC = addonTable.zc;		-- share with AuctionatorDev

-- Compatibility shims for FauxScrollFrame APIs so scrolling works even without a ScrollBar.
-- We wrap Blizzard functions when available and fall back to internal state when not.
local _atr_orig_FauxScrollFrame_Update = _G.FauxScrollFrame_Update
local _atr_orig_FauxScrollFrame_GetOffset = _G.FauxScrollFrame_GetOffset
local _atr_orig_FauxScrollFrame_SetOffset = _G.FauxScrollFrame_SetOffset

function FauxScrollFrame_Update(frame, numItems, numToDisplay, valueStep)
  -- Call Blizzard's original if present to keep other UI behavior intact
  if _atr_orig_FauxScrollFrame_Update then
    _atr_orig_FauxScrollFrame_Update(frame, numItems, numToDisplay, valueStep)
  end
  if not frame then return end
  frame._atr_valueStep = valueStep or frame._atr_valueStep or 16
  frame._atr_numItems = numItems or frame._atr_numItems or 0
  frame._atr_numToDisplay = numToDisplay or frame._atr_numToDisplay or 0
  frame._atr_maxOffsetRows = math.max(0, (frame._atr_numItems or 0) - (frame._atr_numToDisplay or 0))
  -- Determine current offset from either our state or Blizzard's
  local current = rawget(frame, "_atr_offsetRows")
  if current == nil and _atr_orig_FauxScrollFrame_GetOffset then
    current = _atr_orig_FauxScrollFrame_GetOffset(frame)
  end
  current = math.max(0, math.min(frame._atr_maxOffsetRows or 0, tonumber(current) or 0))
  frame._atr_offsetRows = current
end

function FauxScrollFrame_GetOffset(frame)
  if frame and frame.ScrollBar and frame.ScrollBar.GetValue and _atr_orig_FauxScrollFrame_GetOffset then
    return _atr_orig_FauxScrollFrame_GetOffset(frame)
  end
  return frame and frame._atr_offsetRows or 0
end

function FauxScrollFrame_SetOffset(frame, offsetRows)
  if not frame then return end
  local rows = math.max(0, math.floor(tonumber(offsetRows) or 0))
  local maxRows = frame._atr_maxOffsetRows or 0
  if maxRows then rows = math.min(rows, maxRows) end
  frame._atr_offsetRows = rows
  -- If a ScrollBar exists, sync it to pixel position
  if frame.ScrollBar and frame.ScrollBar.SetValue then
    local step = frame._atr_valueStep or 16
    frame.ScrollBar:SetValue(rows * step)
  end
end

-- Mouse wheel fallback: adjust row offset directly when Blizzard handler is missing
if not _G.FauxScrollFrame_OnMouseWheel then
  function FauxScrollFrame_OnMouseWheel(self, delta, lineHeight, updateFunc)
    if not self then return end
    local rowsDelta = (delta and delta > 0) and -1 or 1
    local current = (FauxScrollFrame_GetOffset(self) or 0)
    FauxScrollFrame_SetOffset(self, current + rowsDelta)
    if type(updateFunc) == "function" then
      updateFunc()
    end
  end
end

-- Vertical scroll fallback: convert pixel offset to row offset and update
if not _G.FauxScrollFrame_OnVerticalScroll then
  function FauxScrollFrame_OnVerticalScroll(self, offset, lineHeight, updateFunc)
    if not self then return end
    local step = lineHeight or self._atr_valueStep or 16
    local rows = math.floor(((offset or 0) + (step/2)) / step)
    FauxScrollFrame_SetOffset(self, rows)
    if type(updateFunc) == "function" then
      updateFunc()
    end
  end
end

-----------------------------------------

local recommendElements			= {};
local gOptionsPanelsInitialized = false;


AUCTIONATOR_ENABLE_ALT		= 1;
AUCTIONATOR_OPEN_ALL_BAGS	= 1;
AUCTIONATOR_SHOW_ST_PRICE	= 0;
AUCTIONATOR_SHOW_TIPS		= 1;
AUCTIONATOR_DEF_DURATION	= "N";		-- none
AUCTIONATOR_V_TIPS			= 1;
AUCTIONATOR_A_TIPS			= 1;
AUCTIONATOR_D_TIPS			= 1;
AUCTIONATOR_SHIFT_TIPS		= 1;
AUCTIONATOR_DE_DETAILS_TIPS	= 4;		-- off by default
AUCTIONATOR_DEFTAB			= 1;

AUCTIONATOR_OPEN_FIRST		= 0;	-- obsolete - just needed for migration
AUCTIONATOR_OPEN_BUY		= 0;	-- obsolete - just needed for migration

local SELL_TAB		= 1;
local MORE_TAB		= 2;
local BUY_TAB 		= 3;

local MODE_LIST_ACTIVE	= 1;
local MODE_LIST_ALL		= 2;


-- saved variables - amounts to undercut

local auctionator_savedvars_defaults =
	{
	["_5000000"]			= 10000;	-- amount to undercut buyouts over 500 gold
	["_1000000"]			= 2500;
	["_200000"]				= 1000;
	["_50000"]				= 500;
	["_10000"]				= 200;
	["_2000"]				= 100;
	["_500"]				= 5;
	["STARTING_DISCOUNT"]	= 5;	-- PERCENT
	};


-----------------------------------------

local auctionator_orig_AuctionFrameTab_OnClick;
local auctionator_orig_ContainerFrameItemButton_OnModifiedClick;
local auctionator_orig_AuctionFrameAuctions_Update;
local auctionator_orig_CanShowRightUIPanel;
local auctionator_orig_ChatEdit_InsertLink;
local auctionator_orig_ChatFrame_OnEvent;
local auctionator_orig_FriendsFrame_OnEvent;

local gForceMsgAreaUpdate = true;
local gAtr_ClickAuctionSell = false;

  -- Suspend non-essential processing while loading screens are active or transitioning zones
  local gAtr_SuspendForLoading = false;
  local gAtr_SuspendUntilTime = 0;   -- time()-based grace period after zoning
  local gAtr_PendingBagRebuild = false; -- request to rebuild SELL browser after suspension ends
  local gAtr_LastSBBuildAt = 0;         -- throttle SELL browser rebuilds

local gOpenAllBags  	= AUCTIONATOR_OPEN_ALL_BAGS;
local gTimeZero;
local gTimeTightZero;

local cslots = {};
local gEmptyBScached = nil;

local gAutoSingleton = 0;

local gJustPosted_ItemName = nil;		-- set to the last item posted, even after the posting so that message and icon can be displayed
local gJustPosted_ItemLink;
local gJustPosted_BuyoutPrice;
local gJustPosted_StackSize;
local gJustPosted_NumStacks;

local auctionator_pending_message = nil;

local kBagIDs = {};

local Atr_Confirm_Proc_Yes = nil;

local gStartingTime			= time();
local gHentryTryAgain		= nil;
local gCondensedThisSession = {};

local gAtr_Owner_Item_Indices = {};

local ITEM_HIST_NUM_LINES = 20;

local gActiveAuctions = {};

local gHlistNeedsUpdate = false;
local gAtr_SellTriggeredByAuctionator = false;

local gSellPane;
local gMorePane;
local gActivePane;
local gShopPane;

local gCurrentPane;

local gHistoryItemList = {};

-- SELL Browser (inventory) state
local gSB_Visible = false;        -- whether the inventory browser is visible on the SELL tab
local gSB_Inited  = false;        -- first-time initialization when SELL tab is shown
local gSB_Widgets = {};           -- dynamic frames created under Atr_SB_Content

-- SELL tab enlarged layout state
local gSellLayoutExpandedApplied = false;
local gHB_OrigPoint = nil;           -- Atr_HeadingsBar original anchor
local gSF_OrigPoint = nil;           -- AuctionatorScrollFrame original anchor

local ATR_CACT_NULL							= 0;
local ATR_CACT_READY						= 1;
local ATR_CACT_PROCESSING					= 2;
local ATR_CACT_WAITING_ON_CANCEL_CONFIRM	= 3;

local gItemPostingInProgress = false;
local gQuietWho = 0;
local gSendZoneMsgs = false;

gAtr_ptime = nil;		-- a more precise timer but may not be updated very frequently

gAtr_ScanDB			= nil;
gAtr_PriceHistDB	= nil;

-----------------------------------------

ATR_SK_GLYPHS		= "*_glyphs";
ATR_SK_GEMS_CUT		= "*_gemscut";
ATR_SK_GEMS_UNCUT	= "*_gemsuncut";
ATR_SK_ITEM_ENH		= "*_itemenh";
ATR_SK_POT_ELIX		= "*_potelix";
ATR_SK_FLASKS		= "*_flasks";
ATR_SK_HERBS		= "*_herbs";     

-----------------------------------------

local roundPriceDown, ToTightTime, FromTightTime, monthDay;

-----------------------------------------

function Atr_RegisterEvents(self)

	self:RegisterEvent("VARIABLES_LOADED");
	self:RegisterEvent("ADDON_LOADED");
	
	self:RegisterEvent("AUCTION_ITEM_LIST_UPDATE");
	self:RegisterEvent("AUCTION_OWNED_LIST_UPDATE");

	self:RegisterEvent("AUCTION_MULTISELL_START");
	self:RegisterEvent("AUCTION_MULTISELL_UPDATE");
	self:RegisterEvent("AUCTION_MULTISELL_FAILURE");

	self:RegisterEvent("AUCTION_HOUSE_SHOW");
	self:RegisterEvent("AUCTION_HOUSE_CLOSED");

	self:RegisterEvent("NEW_AUCTION_UPDATE");
	self:RegisterEvent("CHAT_MSG_ADDON");
	self:RegisterEvent("WHO_LIST_UPDATE");
	self:RegisterEvent("PLAYER_ENTERING_WORLD");
	self:RegisterEvent("PLAYER_LEAVING_WORLD");
	self:RegisterEvent("LOADING_SCREEN_ENABLED");
	self:RegisterEvent("LOADING_SCREEN_DISABLED");
    -- Also watch zone change events to add a short post-zone grace period
    self:RegisterEvent("ZONE_CHANGED");
    self:RegisterEvent("ZONE_CHANGED_INDOORS");
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA");
	self:RegisterEvent("BAG_UPDATE");
	self:RegisterEvent("BAG_UPDATE_DELAYED");
			
	end

-----------------------------------------

-- Bag Right-Click to sell removed. Alt+RightClick only remains.

-----------------------------------------

function Atr_EventHandler(self, event, ...)
    -- Toggle suspend flag around loading screens and zone transitions
    if (event == "LOADING_SCREEN_ENABLED" or event == "PLAYER_LEAVING_WORLD") then
        gAtr_SuspendForLoading = true;
        return;
    end
    if (event == "LOADING_SCREEN_DISABLED") then
        gAtr_SuspendForLoading = false;
        gAtr_SuspendUntilTime = time() + 2; -- small grace period after loading screen
        -- Schedule a safe, single SELL browser rebuild after grace period
        if (zc and zc.AddDeferredCall) then zc.AddDeferredCall(3, "Atr_SB_BagUpdate", nil, nil, "SB_REBUILD_AFTER_LOAD"); end
        return;
    end
    if (event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA") then
        gAtr_SuspendUntilTime = time() + 2; -- short grace period to avoid stutter immediately after zoning
        -- Schedule a safe, single SELL browser rebuild after grace period
        if (zc and zc.AddDeferredCall) then zc.AddDeferredCall(3, "Atr_SB_BagUpdate", nil, nil, "SB_REBUILD_AFTER_ZONE"); end
        return;
    end
    if (gAtr_SuspendForLoading or (gAtr_SuspendUntilTime and time() < gAtr_SuspendUntilTime) or GetPlayerMapPosition("player") == nil) then
        -- Allow critical events even during suspend/grace: opening/closing AH, core init
        if (event ~= "AUCTION_HOUSE_SHOW" and event ~= "AUCTION_HOUSE_CLOSED" and event ~= "VARIABLES_LOADED" and event ~= "ADDON_LOADED") then
            return; -- Skip during zone transitions
        end
    end
    -- zc.md (event, select("#", ...), select(1, ...), select(2, ...), select(3, ...));
    if (event == "VARIABLES_LOADED") then Atr_OnLoad(); end;
    if (event == "ADDON_LOADED") then Atr_OnAddonLoaded(...); end;
    if (event == "AUCTION_ITEM_LIST_UPDATE") then Atr_OnAuctionUpdate(...); end;
    if (event == "AUCTION_OWNED_LIST_UPDATE") then Atr_OnAuctionOwnedUpdate(); end;
    if (event == "AUCTION_MULTISELL_START") then Atr_OnAuctionMultiSellStart(); end;
    if (event == "AUCTION_MULTISELL_UPDATE") then Atr_OnAuctionMultiSellUpdate(...); end;
    if (event == "AUCTION_MULTISELL_FAILURE") then Atr_OnAuctionMultiSellFailure(); end;
    if (event == "AUCTION_HOUSE_SHOW") then Atr_OnAuctionHouseShow(); end;
    if (event == "AUCTION_HOUSE_CLOSED") then Atr_OnAuctionHouseClosed(); end;
    if (event == "NEW_AUCTION_UPDATE") then Atr_OnNewAuctionUpdate(); end;
    if (event == "CHAT_MSG_ADDON") then Atr_OnChatMsgAddon(...); end;
    if (event == "WHO_LIST_UPDATE") then Atr_OnWhoListUpdate(); end;
    if (event == "PLAYER_ENTERING_WORLD") then
        if (not gAtr_OptionsPanelsInitialized) then
            Atr_OnPlayerEnteringWorld();
        end
        if (self and self.UnregisterEvent) then
            self:UnregisterEvent("PLAYER_ENTERING_WORLD");
        end
        return;
    end;
    if (event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED") then
        if (Atr_SB_BagUpdate) then Atr_SB_BagUpdate(); end
    end
end

-----------------------------------------

function Atr_SetupHookFunctionsEarly ()

	auctionator_orig_FriendsFrame_OnEvent = FriendsFrame_OnEvent;
	FriendsFrame_OnEvent = Atr_FriendsFrame_OnEvent;

	Atr_Hook_OnTooltipAddMoney ();
	
end


-----------------------------------------

local auctionator_orig_GetAuctionItemInfo;

function Atr_SetupHookFunctions ()

	auctionator_orig_AuctionFrameTab_OnClick = AuctionFrameTab_OnClick;
	AuctionFrameTab_OnClick = Atr_AuctionFrameTab_OnClick;

	-- IMPORTANT: never override secure container click handlers (causes taint).
	-- Use a secure hook so Blizzard's handler remains intact.
	if (hooksecurefunc) then
		hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", Atr_ContainerFrameItemButton_OnModifiedClick);
	end

	auctionator_orig_AuctionFrameAuctions_Update = AuctionFrameAuctions_Update;
	AuctionFrameAuctions_Update = Atr_AuctionFrameAuctions_Update;

	auctionator_orig_CanShowRightUIPanel = CanShowRightUIPanel;
	CanShowRightUIPanel = auctionator_CanShowRightUIPanel;
	
	auctionator_orig_ChatEdit_InsertLink = ChatEdit_InsertLink;
	ChatEdit_InsertLink = auctionator_ChatEdit_InsertLink;
	
	auctionator_orig_ChatFrame_OnEvent = ChatFrame_OnEvent;
	ChatFrame_OnEvent = auctionator_ChatFrame_OnEvent;

	zc.md ("Hooks setup");

--[[
	if (Atr_IsDev) then
		auctionator_orig_GetAuctionItemInfo = GetAuctionItemInfo;
		GetAuctionItemInfo = auctionator_GetAuctionItemInfo;

		auctionator_orig_AuctionFrameBrowse_Update = AuctionFrameBrowse_Update;		-- for debugging
		AuctionFrameBrowse_Update = auctionator_AuctionFrameBrowse_Update;
	end
]]--
end

-----------------------------------------
--[[
local giiCount = 1;

function auctionator_GetAuctionItemInfo (...)
--	zc.md (giiCount, ...);
	
	giiCount = giiCount + 1;
	
	return auctionator_orig_GetAuctionItemInfo(...);
end

-----------------------------------------

function auctionator_AuctionFrameBrowse_Update (...)

	zc.printstack();
	
	return auctionator_orig_AuctionFrameBrowse_Update (...);

end
]]--

-----------------------------------------

local gItemLinkCache = {};
local gA2IC_prevName = "";

-----------------------------------------

function Atr_AddToItemLinkCache (itemName, itemLink)

	if (itemName == gA2IC_prevName) then		-- for performance reasons only
		return;
	end

	gA2IC_prevName = itemName;

	gItemLinkCache[string.lower(itemName)] = itemLink;
end

-----------------------------------------

function Atr_GetItemLink (itemName)
	if (itemName == nil or itemName == "") then
		return nil;
	end
	
	local itemLink = gItemLinkCache[string.lower(itemName)];
	
	if (itemLink == nil) then
		_, itemLink = GetItemInfo (itemName);
		if (itemLink) then
			Atr_AddToItemLinkCache (itemName, itemLink);
		end
	end
	
	return itemLink;

end

-----------------------------------------

local checkVerString		= nil;
local versionReminderCalled	= false;	-- make sure we don't bug user more than once

-----------------------------------------

local function CheckVersion (verString)
	
	if (checkVerString == nil) then
		checkVerString = AuctionatorVersion;
	end
	
	local a,b,c = strsplit (".", verString);

	if (tonumber(a) == nil or tonumber(b) == nil or tonumber(c) == nil) then
		return false;
	end
	
	if (verString > checkVerString) then
		checkVerString = verString;
		return true;	-- out of date
	end
	
	return false;
end

-----------------------------------------

function Atr_VersionReminder ()
	if (not versionReminderCalled) then
		versionReminderCalled = true;

		zc.msg_atr (ZT("There is a more recent version of Auctionator: VERSION").." "..checkVerString);
	end
end



-----------------------------------------

local VREQ_sent = 0;

-----------------------------------------

function Atr_SendAddon_VREQ (type, target)

	VREQ_sent = time();
	
	SendAddonMessage ("ATR", "VREQ_"..AuctionatorVersion, type, target);
	
end

-----------------------------------------

function Atr_OnChatMsgAddon (...)

	local	prefix, msg, distribution, sender = ...;
	
--	local s = string.format ("%s %s |cff88ffff %s |cffffffaa %s|r", prefix, distribution, sender, msg);
--	zc.md (s);

	if (prefix == "ATR") then
	
		if (zc.StringStartsWith (msg, "VREQ_")) then
			SendAddonMessage ("ATR", "V_"..AuctionatorVersion, "WHISPER", sender);
		end
		
		if (zc.StringStartsWith (msg, "V_") and time() - VREQ_sent < 5) then

			local herVerString = string.sub (msg, 3);
			zc.md ("version found:", herVerString, "   ", sender, "     delta", time() - VREQ_sent);
			local outOfDate = CheckVersion (herVerString);
			if (outOfDate) then
				zc.AddDeferredCall (3, "Atr_VersionReminder", nil, nil, "VR");
			end
		end
	end

	if (Atr_OnChatMsgAddon_Dev) then
		Atr_OnChatMsgAddon_Dev (prefix, msg, distribution, sender);
	end
	
end


-----------------------------------------

local function Atr_GetAuctionatorMemString(msg)

	UpdateAddOnMemoryUsage();
	
	local mem  = GetAddOnMemoryUsage("Auctionator");
	return string.format ("%6i KB", math.floor(mem));
end

-----------------------------------------

local function Atr_SlashCmdFunction(msg)

	local cmd, param1u, param2u, param3u = zc.words (msg);

	if (cmd == nil or type (cmd) ~= "string") then
		return;
	end
	
		  cmd    = cmd     and cmd:lower()    or nil;
	local param1 = param1u and param1u:lower() or nil;
	local param2 = param2u and param2u:lower() or nil;
	local param3 = param3u and param3u:lower() or nil;
	
	if (cmd == "mem") then

		UpdateAddOnMemoryUsage();
		
		for i = 1, GetNumAddOns() do
			local mem  = GetAddOnMemoryUsage(i);
			local name = GetAddOnInfo(i);
			if (mem > 0) then
				local s = string.format ("%6i KB   %s", math.floor(mem), name);
				zc.msg_yellow (s);
			end
		end
	
	elseif (cmd == "locale") then
		Atr_PickLocalizationTable (param1u);

	elseif (cmd == "clear") then
	
		zc.msg_atr ("memory usage: "..Atr_GetAuctionatorMemString());
		
		if (param1 == "fullscandb") then
			gAtr_ScanDB = nil;
			AUCTIONATOR_PRICE_DATABASE = nil;
            AUCTIONATOR_MEAN_PRICE_DATABASE = nil;
			Atr_InitScanDB();
			zc.msg_atr (ZT("full scan database cleared"));
			
		elseif (param1 == "posthistory") then
			AUCTIONATOR_PRICING_HISTORY = {};
			zc.msg_atr (ZT("pricing history cleared"));
		end
		
		collectgarbage  ("collect");
		
		zc.msg_atr ("memory usage: "..Atr_GetAuctionatorMemString());

	elseif (Atr_HandleDevCommands and Atr_HandleDevCommands (cmd, param1, param2)) then
		-- do nothing
	else
		zc.msg_atr (ZT("unrecognized command"));
	end
	
end


-----------------------------------------

function Atr_InitScanDB()

	local realm_Faction = GetRealmName().."_"..UnitFactionGroup ("player");

	if (AUCTIONATOR_PRICE_DATABASE and AUCTIONATOR_PRICE_DATABASE["__dbversion"] == nil) then	-- see if we need to migrate
	
		local temp = zc.CopyDeep (AUCTIONATOR_PRICE_DATABASE);
		
		AUCTIONATOR_PRICE_DATABASE = {};
		AUCTIONATOR_PRICE_DATABASE["__dbversion"] = 2;
	
		AUCTIONATOR_PRICE_DATABASE[realm_Faction] = zc.CopyDeep (temp);
		
		temp = {};
	end

	if (AUCTIONATOR_PRICE_DATABASE == nil) then
		AUCTIONATOR_PRICE_DATABASE = {};
		AUCTIONATOR_PRICE_DATABASE["__dbversion"] = 2;
	end
	
	if (AUCTIONATOR_PRICE_DATABASE[realm_Faction] == nil) then
		AUCTIONATOR_PRICE_DATABASE[realm_Faction] = {};
	end
    
    if AUCTIONATOR_MEAN_PRICE_DATABASE == nil then
        AUCTIONATOR_MEAN_PRICE_DATABASE = {};
    end
	if (AUCTIONATOR_MEAN_PRICE_DATABASE[realm_Faction] == nil) then
		AUCTIONATOR_MEAN_PRICE_DATABASE[realm_Faction] = {};
	end

	gAtr_ScanDB = AUCTIONATOR_PRICE_DATABASE[realm_Faction];
    gAtr_MeanDB = AUCTIONATOR_MEAN_PRICE_DATABASE[realm_Faction];

end


-----------------------------------------

function Atr_OnLoad()

	AuctionatorVersion = GetAddOnMetadata("Auctionator", "Version");

	gTimeZero		= time({year=2000, month=1, day=1, hour=0});
	gTimeTightZero	= time({year=2008, month=8, day=1, hour=0});

	local x;
	for x = 0, NUM_BAG_SLOTS do
		kBagIDs[x+1] = x;
	end
	
	kBagIDs[NUM_BAG_SLOTS+2] = KEYRING_CONTAINER;

	AuctionatorLoaded = true;

	SlashCmdList["Auctionator"] = Atr_SlashCmdFunction;
	
	SLASH_Auctionator1 = "/auctionator";
	SLASH_Auctionator2 = "/atr";

	Atr_InitScanDB ();
	
	if (AUCTIONATOR_PRICING_HISTORY == nil) then	-- the old history of postings
		AUCTIONATOR_PRICING_HISTORY = {};
	end
	
	if (AUCTIONATOR_TOONS == nil) then
		AUCTIONATOR_TOONS = {};
	end

	if (AUCTIONATOR_STACKING_PREFS == nil) then
		Atr_StackingPrefs_Init();
	end


	local playerName = UnitName("player");

	if (not AUCTIONATOR_TOONS[playerName]) then
		AUCTIONATOR_TOONS[playerName] = {};
		AUCTIONATOR_TOONS[playerName].firstSeen		= time();
		AUCTIONATOR_TOONS[playerName].firstVersion	= AuctionatorVersion;
	end

	AUCTIONATOR_TOONS[playerName].guid = UnitGUID ("player");

	if (AUCTIONATOR_SCAN_MINLEVEL == nil) then
		AUCTIONATOR_SCAN_MINLEVEL = 1;			-- poor (all) items
	end
	
	if (AUCTIONATOR_SHOW_TIPS == 0) then		-- migrate old option to new ones
		AUCTIONATOR_V_TIPS = 0;
		AUCTIONATOR_A_TIPS = 0;
		AUCTIONATOR_D_TIPS = 0;
		
		AUCTIONATOR_SHOW_TIPS = 2;
	end

	if (AUCTIONATOR_OPEN_FIRST < 2) then	-- set to 2 to indicate it's been migrated
		if		(AUCTIONATOR_OPEN_FIRST == 1)	then AUCTIONATOR_DEFTAB = 1;
		elseif	(AUCTIONATOR_OPEN_BUY == 1)		then AUCTIONATOR_DEFTAB = 2;
		else										 AUCTIONATOR_DEFTAB = 0; end;
	
		AUCTIONATOR_OPEN_FIRST = 2;
	end


	Atr_SetupHookFunctionsEarly();

	------------------


	CreateFrame( "GameTooltip", "AtrScanningTooltip" ); -- Tooltip name cannot be nil
	AtrScanningTooltip:SetOwner( WorldFrame, "ANCHOR_NONE" );
	-- Allow tooltip SetX() methods to dynamically add new lines based on these
	AtrScanningTooltip:AddFontStrings(
	AtrScanningTooltip:CreateFontString( "$parentTextLeft1", nil, "GameTooltipText" ),
	AtrScanningTooltip:CreateFontString( "$parentTextRight1", nil, "GameTooltipText" ) );

	------------------

	Atr_InitDETable();

	if ( IsAddOnLoaded("Blizzard_AuctionUI") ) then		-- need this for AH_QuickSearch since that mod forces Blizzard_AuctionUI to load at a startup
		Atr_Init();
	end

	

end

-----------------------------------------

local gPrevTime = 0;

function Atr_OnAddonLoaded(...)

	local addonName = select (1, ...);

	if (zc.StringSame (addonName, "blizzard_auctionui")) then
		Atr_Init();
	end

	if (zc.StringSame (addonName, "lilsparkysWorkshop")) then

		local LSW_version = GetAddOnMetadata("lilsparkysWorkshop", "Version");

		if (LSW_version and (LSW_version == "0.72" or LSW_version == "0.90" or LSW_version == "0.91")) then

			if (LSW_itemPrice) then
				zc.msg ("** |cff00ffff"..ZT("Auctionator provided an auction module to LilSparky's Workshop."), 0, 1, 0);
				zc.msg ("** |cff00ffff"..ZT("Ignore any ERROR message to the contrary below."), 0, 1, 0);
				LSW_itemPrice = Atr_LSW_itemPriceGetAuctionBuyout;
			end
		end
	end

	Atr_Check_For_Conflicts (addonName);

	local now = time();

--	zc.md (addonName.."   time: "..now - gStartingTime);

	gPrevTime = now;

end


-----------------------------------------

function Atr_OnPlayerEnteringWorld()

	Atr_InitOptionsPanels();
	gAtr_OptionsPanelsInitialized = true;
	if (not gOptionsPanelsInitialized) then
		Atr_InitOptionsPanels();
		gOptionsPanelsInitialized = true;
	end

--	Atr_MakeOptionsFrameOpaque();
end

-----------------------------------------

function Atr_LSW_itemPriceGetAuctionBuyout(link)

    sellPrice = Atr_GetAuctionBuyout(link)
    if sellPrice then
        return sellPrice, false
    else
        return 0, true
    end
 end
 
-----------------------------------------

function Atr_Init()

	if (AuctionatorInited) then
		return;
	end

	zc.msg("Auctionator Initialized");

	AuctionatorInited = true;

	if (AUCTIONATOR_SAVEDVARS == nil) then
		Atr_ResetSavedVars();
	end


	if (AUCTIONATOR_SHOPPING_LISTS == nil) then
		AUCTIONATOR_SHOPPING_LISTS = {};
		Atr_SList.create (ZT("Recent Searches"), true);

		if (zc.IsEnglishLocale()) then
			local slist = Atr_SList.create ("Sample Shopping List #1");
			slist:AddItem ("Greater Cosmic Essence");
			slist:AddItem ("Infinite Dust");
			slist:AddItem ("Dream Shard");
			slist:AddItem ("Abyss Crystal");
		end
	else
		Atr_ShoppingListsInit();
	end

	gShopPane	= Atr_AddSellTab (ZT("Buy"),			BUY_TAB);
	gSellPane	= Atr_AddSellTab (ZT("Sell"),			SELL_TAB);
	gMorePane	= Atr_AddSellTab (ZT("More").."...",	MORE_TAB);

	Atr_AddMainPanel ();

	Atr_SetupHookFunctions ();

	recommendElements[1] = _G["Atr_Recommend_Text"];
	recommendElements[2] = _G["Atr_RecommendPerItem_Text"];
	recommendElements[3] = _G["Atr_RecommendPerItem_Price"];
	recommendElements[4] = _G["Atr_RecommendPerStack_Text"];
	recommendElements[5] = _G["Atr_RecommendPerStack_Price"];
	recommendElements[6] = _G["Atr_Recommend_Basis_Text"];
	recommendElements[7] = _G["Atr_RecommendItem_Tex"];

	-- create the lines that appear in the item history scroll pane

	local line, n;

	for n = 1, ITEM_HIST_NUM_LINES do
		local y = -5 - ((n-1)*16);
		line = CreateFrame("BUTTON", "AuctionatorHEntry"..n, Atr_Hlist, "Atr_HEntryTemplate");
		line:SetPoint("TOPLEFT", 0, y);
	end

	Atr_ShowHide_StartingPrice();
	
	Atr_LocalizeFrames();

end

-----------------------------------------

function Atr_ShowHide_StartingPrice()

	if (AUCTIONATOR_SHOW_ST_PRICE == 1) then
		Atr_StartingPriceText:Show();
		Atr_StartingPrice:Show();
		Atr_StartingPriceDiscountText:Hide();
		Atr_Duration_Text:SetPoint ("TOPLEFT", 10, -307);
	else
		Atr_StartingPriceText:Hide();
		Atr_StartingPrice:Hide();
		Atr_StartingPriceDiscountText:Show();
		Atr_Duration_Text:SetPoint ("TOPLEFT", 10, -304);
	end
end


-----------------------------------------

function Atr_GetSellItemInfo ()

	local auctionItemName, auctionTexture, auctionCount = GetAuctionSellItemInfo();

	if (auctionItemName == nil) then
		auctionItemName = "";
		auctionCount	= 0;
	end

	local auctionItemLink = nil;

	-- only way to get sell itemlink that I can figure

	if (auctionItemName ~= "") then
		AtrScanningTooltip:SetAuctionSellItem();
		local name;
		name, auctionItemLink = AtrScanningTooltip:GetItem();

		if (auctionItemLink == nil) then
			return "",0,nil;
		else
			Atr_AddToItemLinkCache (auctionItemName, auctionItemLink);
		end

	end

	return auctionItemName, auctionCount, auctionItemLink;

end


-----------------------------------------

function Atr_ResetSavedVars ()
	AUCTIONATOR_SAVEDVARS = zc.CopyDeep (auctionator_savedvars_defaults);
end


--------------------------------------------------------------------------------
-- don't reference these directly; use the function below instead

local _AUCTIONATOR_SELL_TAB_INDEX = 0;
local _AUCTIONATOR_MORE_TAB_INDEX = 0;
local _AUCTIONATOR_BUY_TAB_INDEX = 0;

--------------------------------------------------------------------------------

function Atr_FindTabIndex (whichTab)

	if (_AUCTIONATOR_SELL_TAB_INDEX == 0) then

		local i = 4;
		while (true)  do
			local tab = _G['AuctionFrameTab'..i];
			if (tab == nil) then
				break;
			end

			if (tab.auctionatorTab) then
				if (tab.auctionatorTab == SELL_TAB)		then _AUCTIONATOR_SELL_TAB_INDEX = i; end;
				if (tab.auctionatorTab == MORE_TAB)		then _AUCTIONATOR_MORE_TAB_INDEX = i; end;
				if (tab.auctionatorTab == BUY_TAB)		then _AUCTIONATOR_BUY_TAB_INDEX = i; end;
			end

			i = i + 1;
		end
	end

	if (whichTab == SELL_TAB)	then return _AUCTIONATOR_SELL_TAB_INDEX ; end;
	if (whichTab == MORE_TAB)	then return _AUCTIONATOR_MORE_TAB_INDEX; end;
	if (whichTab == BUY_TAB)	then return _AUCTIONATOR_BUY_TAB_INDEX; end;

	return 0;
end


-----------------------------------------

local gOrig_ContainerFrameItemButton_OnClick = nil;

-----------------------------------------

local function Atr_SwitchTo_OurItemOnClick ()

    -- Disabled: do not override Blizzard bag click. We only support Alt+RightClick via the modified-click hook.
    return;

end

-----------------------------------------

local function Atr_SwitchTo_BlizzItemOnClick ()

    -- Restore Blizzard's bag button OnClick if we swapped it.
    if (gOrig_ContainerFrameItemButton_OnClick) then
        ContainerFrameItemButton_OnClick = gOrig_ContainerFrameItemButton_OnClick;
        gOrig_ContainerFrameItemButton_OnClick = nil;
    end
end

-----------------------------------------

function Atr_AuctionFrameTab_OnClick (self, index, down)

	if ( index == nil or type(index) == "string") then
		index = self:GetID();
	end

	_G["Atr_Main_Panel"]:Hide();

	gBuyState = ATR_BUY_NULL;			-- just in case
	gItemPostingInProgress = false;		-- just in case
	
	auctionator_orig_AuctionFrameTab_OnClick (self, index, down);



	if (not Atr_IsAuctionatorTab(index)) then
		gForceMsgAreaUpdate = true;
		Atr_HideAllDialogs();
		AuctionFrameMoneyFrame:Show();

		if (AP_Bid_MoneyFrame) then		-- for the addon 'Auction Profit'
			if (AP_ShowBid)	then	AP_ShowHide_Bid_Button(1);	end;
			if (AP_ShowBO)	then	AP_ShowHide_BO_Button(1);	end;
		end


	elseif (Atr_IsAuctionatorTab(index)) then
	
		AuctionFrameAuctions:Hide();
		AuctionFrameBrowse:Hide();
		AuctionFrameBid:Hide();
		PlaySound("igCharacterInfoTab");

		PanelTemplates_SetTab(AuctionFrame, index);

		AuctionFrameTopLeft:SetTexture	("Interface\\AddOns\\Auctionator\\Images\\Atr_topleft");
		AuctionFrameBotLeft:SetTexture	("Interface\\AddOns\\Auctionator\\Images\\Atr_botleft");
		AuctionFrameTop:SetTexture		("Interface\\AddOns\\Auctionator\\Images\\Atr_top");
		AuctionFrameTopRight:SetTexture	("Interface\\AddOns\\Auctionator\\Images\\Atr_topright");
		AuctionFrameBot:SetTexture		("Interface\\AddOns\\Auctionator\\Images\\Atr_bot");
		AuctionFrameBotRight:SetTexture	("Interface\\AddOns\\Auctionator\\Images\\Atr_botright");

		if (index == Atr_FindTabIndex(SELL_TAB))	then gCurrentPane = gSellPane; end;
		if (index == Atr_FindTabIndex(BUY_TAB))		then gCurrentPane = gShopPane; end;
		if (index == Atr_FindTabIndex(MORE_TAB))	then gCurrentPane = gMorePane; end;

		if (index == Atr_FindTabIndex(SELL_TAB))	then AuctionatorTitle:SetText ("Auctionator - "..ZT("Sell"));			end;
		if (index == Atr_FindTabIndex(BUY_TAB))		then AuctionatorTitle:SetText ("Auctionator - "..ZT("Buy"));			end;
		if (index == Atr_FindTabIndex(MORE_TAB))	then AuctionatorTitle:SetText ("Auctionator - "..ZT("More").."...");	end;

		Atr_ClearHlist();
		Atr_SellControls:Hide();
		Atr_Hlist:Hide();
		Atr_Hlist_ScrollFrame:Hide();
		Atr_Search_Box:Hide();
		Atr_Search_Button:Hide();
		Atr_Adv_Search_Button:Hide();
		Atr_AddToSListButton:Hide();
		Atr_RemFromSListButton:Hide();
		Atr_NewSListButton:Hide();
		Atr_DelSListButton:Hide();
		Atr_DropDown1:Hide();
		Atr_DropDownSL:Hide();
		Atr_CheckActiveButton:Hide();
		Atr_Back_Button:Hide()
		
		AuctionFrameMoneyFrame:Hide();
		
		if (index == Atr_FindTabIndex(SELL_TAB)) then
			-- Apply enlarged SELL layout and show both controls and inventory under the image
			if (Atr_ApplySellExpandedLayout) then Atr_ApplySellExpandedLayout(); end
			if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:Hide(); end
			if (Atr_SellControls) then Atr_SellControls:Show(); end
			if (Atr_SB_OnTabShown) then Atr_SB_OnTabShown(); end
            -- SELL: make the auctions list short
            if (AuctionatorScrollFrame) then
                AuctionatorScrollFrame:SetHeight(60);
            end
		else
			Atr_Hlist:Show();
			Atr_Hlist_ScrollFrame:Show();
			if (gJustPosted_ItemName) then
				gJustPosted_ItemName = nil;
				gSellPane:ClearSearch ();
			end
			-- Hide inventory UI when not on SELL tab and reset layout
			if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:Hide(); end
			if (Atr_SellBrowser) then Atr_SellBrowser:Hide(); end
			if (Atr_SellControls) then Atr_SellControls:Hide(); end
			if (Atr_ResetSellExpandedLayout) then Atr_ResetSellExpandedLayout(); end
		end


		if (index == Atr_FindTabIndex(MORE_TAB)) then
			FauxScrollFrame_SetOffset (Atr_Hlist_ScrollFrame, gCurrentPane.hlistScrollOffset);
			Atr_DisplayHlist();
			Atr_DropDown1:Show();
			
			if (UIDropDownMenu_GetSelectedValue(Atr_DropDown1) == MODE_LIST_ACTIVE) then
				Atr_CheckActiveButton:Show();
			end
		end
		
		
		if (index == Atr_FindTabIndex(BUY_TAB)) then
			Atr_Search_Box:Show();
			Atr_Search_Button:Show();
			Atr_Adv_Search_Button:Show();
			AuctionFrameMoneyFrame:Show();
			Atr_BuildGlobalHistoryList(true);
			Atr_AddToSListButton:Show();
			Atr_RemFromSListButton:Show();
			Atr_NewSListButton:Show();
			Atr_DelSListButton:Show();
			Atr_DropDownSL:Show();
			Atr_Hlist:SetHeight (252);
			Atr_Hlist_ScrollFrame:SetHeight (252);
            -- BUY: make the auctions list taller than SELL, but smaller than default
            if (AuctionatorScrollFrame) then
                AuctionatorScrollFrame:SetHeight(200);
            end
			-- Ensure Recent Searches list shows immediately on Buy, even before any search
			if (AUCTIONATOR_SHOPPING_LISTS and AUCTIONATOR_SHOPPING_LISTS[1]) then
				gCurrentSList = AUCTIONATOR_SHOPPING_LISTS[1];
			end
			if (Atr_Shop_UpdateUI) then Atr_Shop_UpdateUI(); end
		else
			Atr_Hlist:SetHeight (335);
			Atr_Hlist_ScrollFrame:SetHeight (335);
		end

		if (index == Atr_FindTabIndex(BUY_TAB) or index == Atr_FindTabIndex(SELL_TAB)) then
			Atr_Buy1_Button:Show();
			Atr_Buy1_Button:Disable();
		end

		Atr_HideElems (recommendElements);

		_G["Atr_Main_Panel"]:Show();

		gCurrentPane.UINeedsUpdate = true;

		if (gOpenAllBags == 1) then
			OpenAllBags(true);
			gOpenAllBags = 0;
		end

	end

end

-----------------------------------------

function Atr_StackSize ()
	return Atr_Batch_Stacksize:GetNumber();
end

-----------------------------------------

function Atr_SetStackSize (n)
	return Atr_Batch_Stacksize:SetText(n);
end

-----------------------------------------

function Atr_SelectPane (whichTab)

	local index = Atr_FindTabIndex(whichTab);
	local tab   = _G['AuctionFrameTab'..index];
	
	Atr_AuctionFrameTab_OnClick (tab, index);

end

-----------------------------------------

function Atr_IsModeCreateAuction ()
	return (Atr_IsTabSelected(SELL_TAB));
end


-----------------------------------------

function Atr_IsModeBuy ()
	return (Atr_IsTabSelected(BUY_TAB));
end

-----------------------------------------

function Atr_IsModeActiveAuctions ()
	return (Atr_IsTabSelected(MORE_TAB) and UIDropDownMenu_GetSelectedValue(Atr_DropDown1) == MODE_LIST_ACTIVE);
end

-----------------------------------------

function Atr_ClickAuctionSellItemButton (self, button)

	if (AuctionFrameAuctions.duration == nil) then		-- blizz attempts to calculate deposit below and in some cases, duration has yet to be set
		AuctionFrameAuctions.duration = 1;
	end

	gAtr_ClickAuctionSell = true;
	ClickAuctionSellItemButton(self, button);
end


-----------------------------------------

function Atr_OnDropItem (self, button)

	if (GetCursorInfo() ~= "item") then
		return;
	end

	if (not Atr_IsTabSelected(SELL_TAB)) then
		Atr_SelectPane (SELL_TAB);		-- then fall through
	end

	Atr_ClickAuctionSellItemButton (self, button);
	ClearCursor();
end

-----------------------------------------

function Atr_SellItemButton_OnClick (self, button, ...)

	Atr_ClickAuctionSellItemButton (self, button);
end

-----------------------------------------

function Atr_SellItemButton_OnEvent (self, event, ...)

	if ( event == "NEW_AUCTION_UPDATE") then
		local name, texture, count, quality, canUse, price = GetAuctionSellItemInfo();
		Atr_SellControls_Tex:SetNormalTexture(texture);
	end
	
end

-----------------------------------------

local function Atr_LoadContainerItemToSellPane(slot)

	local bagID  = slot:GetParent():GetID();
	local slotID = slot:GetID();

	if (not Atr_IsTabSelected(SELL_TAB)) then
		Atr_SelectPane (SELL_TAB);
	end

	if (IsControlKeyDown()) then
		gAutoSingleton = time();
	end

	PickupContainerItem(bagID, slotID);

	local infoType = GetCursorInfo()

	if (infoType == "item") then
		Atr_ClearAll();
		Atr_ClickAuctionSellItemButton ();
		ClearCursor();
	end

	-- After choosing via inventory, keep inventory visible and also show controls
	if (Atr_SellBrowser) then
		gSB_Visible = true;
		Atr_SellBrowser:Show();
	end
	if (Atr_SellControls) then
		Atr_SellControls:Show();
	end

	-- Update toggle label and force an immediate UI refresh so pricing fields appear
	if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:SetText("Back"); end
	if (gSellPane) then gSellPane.UINeedsUpdate = true; end
	Atr_UpdateUI();
end

-----------------------------------------

function Atr_ContainerFrameItemButton_OnClick (self, button, ...)

    -- Only allow right-click to load items when the Auction House is open AND the SELL tab is active
    if (AuctionFrame and AuctionFrame:IsShown() and zc.StringSame(button, "RightButton") and Atr_IsTabSelected(SELL_TAB)) then
        Atr_LoadContainerItemToSellPane(self);
        return;
    end

    -- Fallback to original behavior for all other interactions
    if (gOrig_ContainerFrameItemButton_OnClick) then
        gOrig_ContainerFrameItemButton_OnClick(self, button, ...);
    end

end

-----------------------------------------

function Atr_ContainerFrameItemButton_OnModifiedClick (self, button)

	-- Limit Auctionator's Alt-click to SELL tab only to avoid interfering elsewhere
	if (AUCTIONATOR_ENABLE_ALT ~= 0 and AuctionFrame:IsShown() and Atr_IsTabSelected(SELL_TAB) and IsAltKeyDown() and button == "RightButton") then
		Atr_LoadContainerItemToSellPane(self);
		return;
	end

	-- Let Blizzard's original handler (already executed before this secure hook) handle everything else
	-- Do not call or replace the original here to avoid taint/double-execution.
	return;
end




-- SELL BROWSER (Inventory) -----------------------------------------

local function Atr_SB_Clear()
    for _, w in ipairs(gSB_Widgets) do
        if (w and w.Hide) then w:Hide(); end
        if (w and w.SetParent) then w:SetParent(nil); end
    end
    gSB_Widgets = {};
    if (Atr_SB_Content) then Atr_SB_Content:SetHeight(10); end
end

local function Atr_SB_AddWidget(w)
    table.insert(gSB_Widgets, w);
    return w;
end

local itemSellableCache = {};
function Atr_IsItemSellableOnAH(bag, slot, link, quality)
    if (GetPlayerMapPosition("player") == nil) then
        return true; -- Assume sellable during zone transitions
    end
    if (not link) then return false; end
    if (itemSellableCache[link]) then return itemSellableCache[link]; end
    if (quality ~= nil and quality == 0) then
        itemSellableCache[link] = false;
        return false;
    end
    if (quality == nil) then
        local _, _, itemQuality = GetItemInfo(link);
        if (itemQuality ~= nil and itemQuality == 0) then
            itemSellableCache[link] = false;
            return false;
        end
        local prefix = link and string.sub(link, 1, 10) or nil;
        if (prefix and string.lower(prefix) == "|cff9d9d9d") then
            itemSellableCache[link] = false;
            return false;
        end
    end
    if (AtrScanningTooltip and AtrScanningTooltip.SetBagItem) then
        AtrScanningTooltip:ClearLines();
        AtrScanningTooltip:SetBagItem(bag, slot);
        local num = AtrScanningTooltip:NumLines() or 0;
        for i = 1, num do
            local fs = _G["AtrScanningTooltipTextLeft"..i];
            local t = fs and fs:GetText();
            if (t) then
                if ((ITEM_SOULBOUND and t:find(ITEM_SOULBOUND, 1, true)) or
                    (ITEM_BIND_ON_PICKUP and t:find(ITEM_BIND_ON_PICKUP, 1, true)) or
                    (ITEM_BIND_QUEST and t:find(ITEM_BIND_QUEST, 1, true))) then
                    itemSellableCache[link] = false;
                    return false;
                end
            end
        end
    end
    itemSellableCache[link] = true;
    return true;
end

local function Atr_LoadBagSlotToSellPane(bagID, slotID)
    if (not Atr_IsTabSelected(SELL_TAB)) then
        Atr_SelectPane (SELL_TAB);
    end

    if (IsControlKeyDown()) then
        gAutoSingleton = time();
    end

    PickupContainerItem(bagID, slotID);
    local infoType = GetCursorInfo();
    if (infoType == "item") then
        Atr_ClearAll();
        Atr_ClickAuctionSellItemButton ();
        ClearCursor();
    end

    -- After choosing via inventory, keep inventory visible and also show controls
    if (Atr_SellBrowser) then
        gSB_Visible = true;
        Atr_SellBrowser:Show();
    end
    if (Atr_SellControls) then
        Atr_SellControls:Show();
    end

    -- Update toggle label and force an immediate UI refresh so pricing fields appear
    if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:SetText("Back"); end
    if (gSellPane) then gSellPane.UINeedsUpdate = true; end
    Atr_UpdateUI();
end

local function Atr_SB_Item_OnEnter(self)
    if (self.bagID and self.slotID) then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:SetBagItem(self.bagID, self.slotID);
    end
end

local function Atr_SB_Item_OnLeave(self)
    GameTooltip:Hide();
end

local function Atr_SB_Item_OnClick(self, button)
    if (self.bagID and self.slotID) then
        -- Support both left and right click inside the SELL inventory browser only
        if (button == "LeftButton" or button == "RightButton") then
            Atr_LoadBagSlotToSellPane(self.bagID, self.slotID);
        end
    end
end

function Atr_SB_Build()
    if (not Atr_SB_Content) then return; end

    Atr_SB_Clear();

    local categories = {};

    for bag = 0, NUM_BAG_SLOTS do
        local numSlots = GetContainerNumSlots(bag) or 0;
        for slot = 1, numSlots do
            local texture, itemCount, locked, quality, readable, lootable, itemLink = GetContainerItemInfo(bag, slot);
            local link = itemLink or GetContainerItemLink(bag, slot);
            if (link and Atr_IsItemSellableOnAH(bag, slot, link, quality)) then
                local name, _, _, _, _, sType, sSubType, _, _, icon = GetItemInfo(link);
                local classIdx = sType and Atr_ItemType2AuctionClass(sType) or 0;
                if (classIdx) then
                    local cat = sType or ZT("Other");
                    if (not categories[cat]) then categories[cat] = { count = 0, items = {} }; end
                    table.insert(categories[cat].items, { bag=bag, slot=slot, icon=texture or icon, count=itemCount or 1 });
                    categories[cat].count = categories[cat].count + (itemCount or 1);
                end
            end
        end
    end

    local order = {};
    for k,_ in pairs(categories) do table.insert(order, k); end
    table.sort(order);

    local y = -4;
    local contentHeight = 10;

    local function addHeader(text)
        local f = Atr_SB_AddWidget(CreateFrame("Frame", nil, Atr_SB_Content));
        f:SetSize(160, 16);
        f:SetPoint("TOPLEFT", 6, y);
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal");
        fs:SetPoint("LEFT", 0, 0);
        fs:SetText(text);
        y = y - 18;
        contentHeight = contentHeight + 18;
        return f;
    end

    local TILE = 28;
    local GAP  = 4;
    local frameWidth = (Atr_SellBrowser and Atr_SellBrowser:GetWidth()) or 170;
    local usableWidth = math.max(40, frameWidth - 12); -- padding
    local COLS = math.max(3, math.floor((usableWidth + GAP) / (TILE + GAP)));

    for _, cat in ipairs(order) do
        local info = categories[cat];
        addHeader(string.format("%s (%d)", cat, info.count));

        local col = 0;
        local rowStartY = y;
        for _, it in ipairs(info.items) do
            if (col == 0) then rowStartY = y; end

            local btn = Atr_SB_AddWidget(CreateFrame("Button", nil, Atr_SB_Content));
            btn:SetSize(TILE, TILE);
            btn:SetPoint("TOPLEFT", 6 + col*(TILE+GAP), rowStartY);
            btn.bagID  = it.bag;
            btn.slotID = it.slot;
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp");
            btn:SetScript("OnClick", Atr_SB_Item_OnClick);
            btn:SetScript("OnEnter", Atr_SB_Item_OnEnter);
            btn:SetScript("OnLeave", Atr_SB_Item_OnLeave);

            local tex = btn:CreateTexture(nil, "BACKGROUND");
            tex:SetAllPoints(btn);
            tex:SetTexture(it.icon);

            local cnt = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal");
            cnt:SetPoint("BOTTOMRIGHT", -2, 2);
            if (it.count and it.count > 1) then cnt:SetText(it.count); else cnt:SetText(""); end

            col = col + 1;
            if (col >= COLS) then
                col = 0;
                y = y - (TILE + GAP);
                contentHeight = contentHeight + TILE + GAP;
            end
        end

        if (col > 0) then
            y = y - (TILE + GAP);
            contentHeight = contentHeight + TILE + GAP;
        end

        y = y - 4;
        contentHeight = contentHeight + 4;
    end

    Atr_SB_Content:SetHeight(math.max(10, contentHeight));
    if (Atr_SellBrowser and gSB_Visible) then Atr_SellBrowser:Show(); end
end

function Atr_SB_Toggle()
    gSB_Visible = not gSB_Visible;
    if (gSB_Visible) then
        if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:SetText("Back"); end
        if (Atr_SellControls) then Atr_SellControls:Hide(); end
        if (Atr_SellBrowser) then Atr_SellBrowser:Show(); end
        Atr_SB_Build();
    else
        if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:SetText("Inventory"); end
        if (Atr_SellBrowser) then Atr_SellBrowser:Hide(); end
        if (Atr_SellControls) then Atr_SellControls:Show(); end
    end
end

function Atr_SB_OnTabShown()
    if (not gSB_Inited) then
        gSB_Inited = true;
        gSB_Visible = true;
        if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:SetText("Back"); end
    end

    -- In expanded layout we show both controls and the inventory
    if (Atr_SellControls) then Atr_SellControls:Show(); end
    if (Atr_SellBrowser) then Atr_SellBrowser:Show(); end
    gSB_Visible = true;
    Atr_SB_Build();
end

function Atr_SB_BagUpdate()
    -- Skip or defer during combat/flight/loading screens or immediate post-zone period
    if (UnitAffectingCombat("player") or (UnitOnTaxi and UnitOnTaxi("player")) or GetPlayerMapPosition("player") == nil
        or gAtr_SuspendForLoading or (gAtr_SuspendUntilTime and time() < gAtr_SuspendUntilTime)) then
        gAtr_PendingBagRebuild = true;
        return;
    end
    -- Throttle to at most once per second to avoid BAG_UPDATE storms
    local now = time();
    if (gAtr_LastSBBuildAt and (now - gAtr_LastSBBuildAt) < 1) then
        gAtr_PendingBagRebuild = true;
        return;
    end
    gAtr_LastSBBuildAt = now;
    gAtr_PendingBagRebuild = false;
    if (gSB_Visible and Atr_SellBrowser and Atr_SellBrowser:IsShown()) then
        Atr_SB_Build();
    end
end

-----------------------------------------
-- Expanded SELL layout: scale AuctionFrame and insert inventory below image
-----------------------------------------

local function SavePoint(frame)
    if (not frame) then return nil; end
    local p1, rel, p2, x, y = frame:GetPoint(1);
    return {p1, rel, p2, x, y};
end

local function RestorePoint(frame, pt)
    if (not frame or not pt) then return; end
    frame:ClearAllPoints();
    frame:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5]);
end

function Atr_ApplySellExpandedLayout()
    if (gSellLayoutExpandedApplied) then return; end

    -- Re-anchor the inventory browser below the image in the center panel
    if (Atr_SellBrowser and Atr_RecommendItem_Tex) then
        Atr_SellBrowser:ClearAllPoints();
        Atr_SellBrowser:SetPoint("TOPLEFT", Atr_RecommendItem_Tex, "BOTTOMLEFT", -14, -10);
        -- Match width of the main listing area if available
        local targetWidth = (AuctionatorScrollFrame and AuctionatorScrollFrame:GetWidth()) or 588;
        Atr_SellBrowser:SetWidth(targetWidth);
        Atr_SellBrowser:SetHeight(200);
        if (Atr_SB_Content) then
            Atr_SB_Content:SetWidth(math.max(120, targetWidth - 24));
        end
        gSB_Visible = true;
        Atr_SellBrowser:Show();
        Atr_SB_Build();
    end

    -- Push headings bar and results scroll down to make room for inventory
    if (Atr_HeadingsBar) then
        gHB_OrigPoint = gHB_OrigPoint or SavePoint(Atr_HeadingsBar);
        local p1, rel, p2, x, y = Atr_HeadingsBar:GetPoint(1);
        Atr_HeadingsBar:ClearAllPoints();
        Atr_HeadingsBar:SetPoint(p1, rel, p2, x, y - 160);
    end
    if (AuctionatorScrollFrame) then
        gSF_OrigPoint = gSF_OrigPoint or SavePoint(AuctionatorScrollFrame);
        local p1, rel, p2, x, y = AuctionatorScrollFrame:GetPoint(1);
        AuctionatorScrollFrame:ClearAllPoints();
        AuctionatorScrollFrame:SetPoint(p1, rel, p2, x, y - 160);
    end

    gSellLayoutExpandedApplied = true;
end

function Atr_ResetSellExpandedLayout()
    if (not gSellLayoutExpandedApplied) then return; end

    -- Restore headings and scroll positions
    if (gHB_OrigPoint) then RestorePoint(Atr_HeadingsBar, gHB_OrigPoint); end
    if (gSF_OrigPoint) then RestorePoint(AuctionatorScrollFrame, gSF_OrigPoint); end

    -- Restore inventory browser default size/position
    if (Atr_SellBrowser) then
        Atr_SellBrowser:ClearAllPoints();
        -- Default as defined in XML: TOPLEFT offset -193, -75 relative to parent
        Atr_SellBrowser:SetPoint("TOPLEFT", Atr_SellBrowser:GetParent(), "TOPLEFT", -193, -75);
        Atr_SellBrowser:SetWidth(170);
        Atr_SellBrowser:SetHeight(335);
        if (Atr_SB_Content) then Atr_SB_Content:SetWidth(170); end
        Atr_SellBrowser:Hide();
    end

    gSellLayoutExpandedApplied = false;
end

------------------------------------------

function Atr_CreateAuction_OnClick ()

	gAtr_SellTriggeredByAuctionator = true;

	gJustPosted_ItemName			= gCurrentPane.activeScan.itemName;
	gJustPosted_ItemLink			= gCurrentPane.activeScan.itemLink;
	gJustPosted_BuyoutPrice			= MoneyInputFrame_GetCopper(Atr_StackPrice);
	gJustPosted_StackSize			= Atr_StackSize();
	gJustPosted_NumStacks			= Atr_Batch_NumAuctions:GetNumber();

	local duration				= UIDropDownMenu_GetSelectedValue(Atr_Duration);
	local stackStartingPrice	= MoneyInputFrame_GetCopper(Atr_StartingPrice);
	local stackBuyoutPrice		= MoneyInputFrame_GetCopper(Atr_StackPrice);

	if (gJustPosted_StackSize == 1 and gCurrentPane.fullStackSize > 1) then
	
		local scan = gCurrentPane.activeScan;
		
		if (scan and scan.numYourSingletons + gJustPosted_NumStacks > 40) then
			local s = ZT("You may have at most 40 single-stack (x1)\nauctions posted for this item.\n\nYou already have %d such auctions and\nyou are trying to post %d more.");
			Atr_Error_Display (string.format (s, scan.numYourSingletons, gJustPosted_NumStacks));
			return;
		end
	end
	
	Atr_Memorize_Stacking_If();

	StartAuction (stackStartingPrice, stackBuyoutPrice, duration, gJustPosted_StackSize, gJustPosted_NumStacks);

	-- After creating auction(s), return to the inventory browser section
	if (Atr_SellBrowser) then
		gSB_Visible = true;
		Atr_SellBrowser:Show();
		if (Atr_SB_Build) then Atr_SB_Build(); end
	end
	if (Atr_SellControls) then Atr_SellControls:Hide(); end
	if (Atr_SellBrowser_Toggle) then Atr_SellBrowser_Toggle:SetText("Back"); end
end


-----------------------------------------

local gMS_stacksPrev;

-----------------------------------------

function Atr_OnAuctionMultiSellStart()

	gMS_stacksPrev = 0;
end

-----------------------------------------

function Atr_OnAuctionMultiSellUpdate(...)
	
	if (not gAtr_SellTriggeredByAuctionator) then
		zc.md ("skipping.  gAtr_SellTriggeredByAuctionator is false");
		return;
	end

	local stacksSoFar, stacksTotal = ...;
		
	--zc.md ("stacksSoFar: ", stacksSoFar, "stacksTotal: ", stacksTotal);
	
	local delta = stacksSoFar - gMS_stacksPrev;

	gMS_stacksPrev = stacksSoFar;

	Atr_AddToScan (gJustPosted_ItemName, gJustPosted_StackSize, gJustPosted_BuyoutPrice, delta);
	
	if (stacksSoFar == stacksTotal) then
		Atr_LogMsg (gJustPosted_ItemLink, gJustPosted_StackSize, gJustPosted_BuyoutPrice, stacksTotal);
		Atr_AddHistoricalPrice (gJustPosted_ItemName, gJustPosted_BuyoutPrice / gJustPosted_StackSize, gJustPosted_StackSize, gJustPosted_ItemLink);
		gAtr_SellTriggeredByAuctionator = false;     -- reset
	end
	
end

-----------------------------------------

function Atr_OnAuctionMultiSellFailure()

	if (not gAtr_SellTriggeredByAuctionator) then
		zc.md ("skipping.  gAtr_SellTriggeredByAuctionator is false");
		return;
	end

	-- add one more.  no good reason other than it just seems to work
	Atr_AddToScan (gJustPosted_ItemName, gJustPosted_StackSize, gJustPosted_BuyoutPrice, 1);

	Atr_LogMsg (gJustPosted_ItemLink, gJustPosted_StackSize, gJustPosted_BuyoutPrice, gMS_stacksPrev + 1);
	Atr_AddHistoricalPrice (gJustPosted_ItemName, gJustPosted_BuyoutPrice / gJustPosted_StackSize, gJustPosted_StackSize, gJustPosted_ItemLink);

	gAtr_SellTriggeredByAuctionator = false;     -- reset
	
	if (gCurrentPane.activeScan) then
		gCurrentPane.activeScan.whenScanned = 0;
	end
end


-----------------------------------------

function Atr_AuctionFrameAuctions_Update()

	auctionator_orig_AuctionFrameAuctions_Update();

end


-----------------------------------------

function Atr_LogMsg (itemlink, itemcount, price, numstacks)

	local logmsg = string.format (ZT("Auction created for %s"), itemlink);
	
	if (numstacks > 1) then
		logmsg = string.format (ZT("%d auctions created for %s"), numstacks, itemlink);
	end
	
	
	if (itemcount > 1) then
		logmsg = logmsg.."|cff00ddddx"..itemcount.."|r";
	end

	logmsg = logmsg.."   "..zc.priceToString(price);

	if (numstacks > 1 and itemcount > 1) then
		logmsg = logmsg.."  per stack";
	end
	

	zc.msg_yellow (logmsg);

end

-----------------------------------------

function Atr_OnAuctionOwnedUpdate ()

	gItemPostingInProgress = false;
	
	if (Atr_IsModeActiveAuctions()) then
		gHlistNeedsUpdate = true;
	end

	if (not Atr_IsTabSelected()) then
		Atr_ClearScanCache();		-- if not our tab, we have no idea what happened so must flush all caches
		return;
	end;

	gActiveAuctions = {};		-- always flush this cache

	if (gAtr_SellTriggeredByAuctionator) then
	
		if (gJustPosted_ItemName) then

			if (gJustPosted_NumStacks == 1) then
				Atr_LogMsg (gJustPosted_ItemLink, gJustPosted_StackSize, gJustPosted_BuyoutPrice, 1);
				Atr_AddHistoricalPrice (gJustPosted_ItemName, gJustPosted_BuyoutPrice / gJustPosted_StackSize, gJustPosted_StackSize, gJustPosted_ItemLink);
				Atr_AddToScan (gJustPosted_ItemName, gJustPosted_StackSize, gJustPosted_BuyoutPrice, 1);
			
				gAtr_SellTriggeredByAuctionator = false;     -- reset
			end
		end
	end
	
end

-----------------------------------------

function Atr_ResetDuration()

	if (AUCTIONATOR_DEF_DURATION == "S") then UIDropDownMenu_SetSelectedValue(Atr_Duration, 1); end;
	if (AUCTIONATOR_DEF_DURATION == "M") then UIDropDownMenu_SetSelectedValue(Atr_Duration, 2); end;
	if (AUCTIONATOR_DEF_DURATION == "L") then UIDropDownMenu_SetSelectedValue(Atr_Duration, 3); end;

end

-----------------------------------------

function Atr_AddToScan (itemName, stackSize, buyoutPrice, numAuctions)

	local scan = Atr_FindScan (itemName);

	scan:AddScanItem (itemName, stackSize, buyoutPrice, UnitName("player"), numAuctions);

	scan:CondenseAndSort ();

	gCurrentPane.UINeedsUpdate = true;
end

-----------------------------------------

function AuctionatorSubtractFromScan (itemName, stackSize, buyoutPrice, howMany)

	if (howMany == nil) then
		howMany = 1;
	end
	
	local scan = Atr_FindScan (itemName);

	local x;
	for x = 1, howMany do
		scan:SubtractScanItem (itemName, stackSize, buyoutPrice);
	end
	
	scan:CondenseAndSort ();

	gCurrentPane.UINeedsUpdate = true;
end


-----------------------------------------

function auctionator_ChatEdit_InsertLink(text)

	if (AuctionFrame:IsShown() and IsShiftKeyDown() and Atr_IsTabSelected(BUY_TAB)) then	
		local item;
		if ( strfind(text, "item:", 1, true) ) then
			item = GetItemInfo(text);
		end
		if ( item ) then
			Atr_Search_Box:SetText (item);
			Atr_Search_Onclick ();
			return true;
		end
	end

	return auctionator_orig_ChatEdit_InsertLink(text);

end

-----------------------------------------

function auctionator_ChatFrame_OnEvent(self, event, ...)

	local msg = select (1, ...);

	if (event == "CHAT_MSG_SYSTEM") then
		if (msg == ERR_AUCTION_STARTED) then		-- absorb the Auction Created message
			return;
		end
		if (msg == ERR_AUCTION_REMOVED) then		-- absorb the Auction Cancelled message
			return;
		end
	end

	return auctionator_orig_ChatFrame_OnEvent (self, event, ...);

end




-----------------------------------------

function auctionator_CanShowRightUIPanel(frame)

	if (zc.StringSame (frame:GetName(), "TradeSkillFrame")) then
		return 1;
	end;

	return auctionator_orig_CanShowRightUIPanel(frame);

end

-----------------------------------------

function Atr_AddMainPanel ()

	local frame = CreateFrame("FRAME", "Atr_Main_Panel", AuctionFrame, "Atr_Sell_Template");
	frame:Hide();

	UIDropDownMenu_SetWidth (Atr_DropDownSL, 150);
	UIDropDownMenu_JustifyText (Atr_DropDownSL, "CENTER");
	
	UIDropDownMenu_SetWidth (Atr_Duration, 95);

end

-----------------------------------------

function Atr_AddSellTab (tabtext, whichTab)

	local n = AuctionFrame.numTabs+1;

	local framename = "AuctionFrameTab"..n;

	local frame = CreateFrame("Button", framename, AuctionFrame, "AuctionTabTemplate");

	frame:SetID(n);
	frame:SetText(tabtext);

	frame:SetNormalFontObject(_G["AtrFontOrange"]);

	frame.auctionatorTab = whichTab;

	frame:SetPoint("LEFT", _G["AuctionFrameTab"..n-1], "RIGHT", -8, 0);

	PanelTemplates_SetNumTabs (AuctionFrame, n);
	PanelTemplates_EnableTab  (AuctionFrame, n);
	
	return AtrPane.create (whichTab);
end

-----------------------------------------

function Atr_HideElems (tt)

	if (not tt) then
		return;
	end

	for i,x in ipairs(tt) do
		x:Hide();
	end
end

-----------------------------------------

function Atr_ShowElems (tt)

	for i,x in ipairs(tt) do
		x:Show();
	end
end




-----------------------------------------

function Atr_OnAuctionUpdate (...)


	if (gAtr_FullScanState == ATR_FS_STARTED) then
		Atr_FullScanAnalyze();
		return;
	end

	if (not Atr_IsTabSelected()) then
		local searchActive = (gCurrentPane and gCurrentPane.activeSearch and gCurrentPane.activeSearch.processing_state and gCurrentPane.activeSearch.processing_state ~= KM_NULL_STATE);
        if (not searchActive) then
            Atr_ClearScanCache();        -- if not our tab and no active search, flush caches and bail
            return;
        end
	end;

	if (Atr_Buy_OnAuctionUpdate()) then
		return;
	end

	if (gCurrentPane.activeSearch and gCurrentPane.activeSearch.processing_state == KM_POSTQUERY) then

		local isDup = gCurrentPane.activeSearch:CheckForDuplicatePage ();
		
		if (not isDup) then

			local done = gCurrentPane.activeSearch:AnalyzeResultsPage();

			if (done) then
				gCurrentPane.activeSearch:Finish();
				Atr_OnSearchComplete ();
			end
		end
	end

end

-----------------------------------------

function Atr_OnSearchComplete ()

	gCurrentPane.sortedHist = nil;

	Atr_Clear_Owner_Item_Indices();

	local count = gCurrentPane.activeSearch:NumScans();
	if (count == 1) then
		gCurrentPane.activeScan = gCurrentPane.activeSearch:GetFirstScan();
	end

	if (Atr_IsModeCreateAuction()) then
			
		gCurrentPane:SetToShowCurrent();

		if (#gCurrentPane.activeScan.scanData == 0) then
			gCurrentPane.hints = Atr_BuildHints (gCurrentPane.activeScan.itemName);
			if (#gCurrentPane.hints > 0) then
				gCurrentPane:SetToShowHints();	
				gCurrentPane.hintsIndex = 1;
			end

		end
		
		if (gCurrentPane:ShowCurrent()) then
			Atr_FindBestCurrentAuction ();
		end

		Atr_UpdateRecommendation(true);
	else
		if (Atr_IsModeActiveAuctions()) then
			Atr_DisplayHlist();
		end
		
		Atr_FindBestCurrentAuction ();
	end
	
    -- Refresh Buy tab UI when search completes. Use both the tab check and current pane
    -- identity to avoid missing the refresh if tab detection briefly fails.
    if (Atr_IsModeBuy() or (gCurrentPane == gShopPane)) then
        Atr_Shop_OnFinishScan ();
    end

	Atr_CheckingActive_OnSearchComplete();

    -- Ensure results list is scrolled to the top so new results are visible without user interaction
    if (AuctionatorScrollFrame and AuctionatorScrollFrameScrollBar and AuctionatorScrollFrameScrollBar.SetValue) then
        FauxScrollFrame_SetOffset(AuctionatorScrollFrame, 0);
        AuctionatorScrollFrameScrollBar:SetValue(0);
    end

    gCurrentPane.UINeedsUpdate = true;

end

-----------------------------------------

function Atr_ClearTop ()
	Atr_HideElems (recommendElements);

	if (AuctionatorMessageFrame) then
		AuctionatorMessageFrame:Hide();
		AuctionatorMessage2Frame:Hide();
	end
end

-----------------------------------------

function Atr_ClearList ()

	Atr_Col1_Heading:Hide();
	Atr_Col3_Heading:Hide();
	Atr_Col4_Heading:Hide();

	Atr_Col1_Heading_Button:Hide();
	Atr_Col3_Heading_Button:Hide();

	local line;							-- 1 through 12 of our window to scroll

	FauxScrollFrame_Update (AuctionatorScrollFrame, 0, 12, 16);

	for line = 1,12 do
		local lineEntry = _G["AuctionatorEntry"..line];
		lineEntry:Hide();
	end

end

-----------------------------------------

function Atr_ClearAll ()

	if (AuctionatorMessageFrame) then	-- just to make sure xml has been loaded

		Atr_ClearTop();
		Atr_ClearList();
	end
end

-----------------------------------------

function Atr_SetMessage (msg)
	Atr_HideElems (recommendElements);

	if (gCurrentPane.activeSearch.searchText) then
		
		Atr_ShowItemNameAndTexture (gCurrentPane.activeSearch.searchText);
		
		AuctionatorMessage2Frame:SetText (msg);
		AuctionatorMessage2Frame:Show();
		
	else
		AuctionatorMessageFrame:SetText (msg);
		AuctionatorMessageFrame:Show();
		AuctionatorMessage2Frame:Hide();
	end
end

-----------------------------------------

function Atr_ShowItemNameAndTexture(itemName)

	AuctionatorMessageFrame:Hide();
	AuctionatorMessage2Frame:Hide();

	local scn = gCurrentPane.activeScan;

	local color = "";
	if (scn and not scn:IsNil()) then
		color = "|cff"..zc.RGBtoHEX (scn.itemTextColor[1], scn.itemTextColor[2], scn.itemTextColor[3]);
		itemName = scn.itemName;
	end

	Atr_Recommend_Text:Show ();
	Atr_Recommend_Text:SetText (color..itemName);

	Atr_SetTextureButton ("Atr_RecommendItem_Tex", 1, gCurrentPane.activeScan.itemLink);
end



-----------------------------------------

function Atr_SortHistoryData (x, y)

	return x.when > y.when;

end

-----------------------------------------

function BuildHtag (type, y, m, d)

	local t = time({year=y, month=m, day=d, hour=0});

	return tostring (ToTightTime(t))..":"..type;
end

-----------------------------------------

function ParseHtag (tag)
	local when, type = strsplit(":", tag);

	if (type == nil) then
		type = "hx";
	end

	when = FromTightTime (tonumber (when));

	return when, type;
end

-----------------------------------------

function ParseHist (tag, hist)

	local when, type = ParseHtag(tag);

	local price, count	= strsplit(":", hist);

	price = tonumber (price);

	local stacksize, numauctions;

	if (type == "hx") then
		stacksize	= tonumber (count);
		numauctions	= 1;
	else
		stacksize = 0;
		numauctions	= tonumber (count);
	end

	return when, type, price, stacksize, numauctions;

end

-----------------------------------------

function CalcAbsTimes (when, whent)

	local absYear	= whent.year - 2000;
	local absMonth	= (absYear * 12) + whent.month;
	local absDay	= floor ((when - gTimeZero) / (60*60*24));

	return absYear, absMonth, absDay;

end

-----------------------------------------

function Atr_Condense_History (itemname)

	if (AUCTIONATOR_PRICING_HISTORY[itemname] == nil) then
		return;
	end

	local tempHistory = {};

	local now			= time();
	local nowt			= date("*t", now);

	local absNowYear, absNowMonth, absNowDay = CalcAbsTimes (now, nowt);

	local n = 1;
	local tag, hist, newtag, stacksize, numauctions;
	for tag, hist in pairs (AUCTIONATOR_PRICING_HISTORY[itemname]) do
		if (tag ~= "is") then

			local when, type, price, stacksize, numauctions = ParseHist (tag, hist);

			local whnt = date("*t", when);

			local absYear, absMonth, absDay	= CalcAbsTimes (when, whnt);

			if (absNowYear - absYear >= 3) then
				newtag = BuildHtag ("hy", whnt.year, 1, 1);
			elseif (absNowMonth - absMonth >= 2) then
				newtag = BuildHtag ("hm", whnt.year, whnt.month, 1);
			elseif (absNowDay - absDay >= 2) then
				newtag = BuildHtag ("hd", whnt.year, whnt.month, whnt.day);
			else
				newtag = tag;
			end

			tempHistory[n] = {};
			tempHistory[n].price		= price;
			tempHistory[n].numauctions	= numauctions;
			tempHistory[n].stacksize	= stacksize;
			tempHistory[n].when			= when;
			tempHistory[n].newtag		= newtag;
			n = n + 1;
		end
	end

	-- clear all the existing history

	local is = AUCTIONATOR_PRICING_HISTORY[itemname]["is"];

	AUCTIONATOR_PRICING_HISTORY[itemname] = {};
	AUCTIONATOR_PRICING_HISTORY[itemname]["is"] = is;

	-- repopulate the history

	local x;

	for x = 1,#tempHistory do

		local thist		= tempHistory[x];
		local newtag	= thist.newtag;

		if (AUCTIONATOR_PRICING_HISTORY[itemname][newtag] == nil) then

			local when, type = ParseHtag (newtag);

			local count = thist.numauctions;
			if (type == "hx") then
				count = thist.stacksize;
			end

			AUCTIONATOR_PRICING_HISTORY[itemname][newtag] = tostring(thist.price)..":"..tostring(count);

		else

			local hist = AUCTIONATOR_PRICING_HISTORY[itemname][newtag];

			local when, type, price, stacksize, numauctions = ParseHist (newtag, hist);

			local newNumAuctions = numauctions + thist.numauctions;
			local newPrice		 = ((price * numauctions) + (thist.price * thist.numauctions)) / newNumAuctions;

			AUCTIONATOR_PRICING_HISTORY[itemname][newtag] = tostring(newPrice)..":"..tostring(newNumAuctions);
		end
	end

end

-----------------------------------------

function Atr_Process_Historydata ()

	-- Condense the data if needed - only once per session for each item

	if (gCurrentPane:IsScanEmpty()) then
		return;
	end
	
	local itemName = gCurrentPane.activeScan.itemName;

	if (gCondensedThisSession[itemName] == nil) then

		gCondensedThisSession[itemName] = true;

		Atr_Condense_History(itemName);
	end

	-- build the sorted history list

	gCurrentPane.sortedHist = {};

	if (AUCTIONATOR_PRICING_HISTORY[itemName]) then
		local n = 1;
		local tag, hist;
		for tag, hist in pairs (AUCTIONATOR_PRICING_HISTORY[itemName]) do
			if (tag ~= "is") then
				local when, type, price, stacksize, numauctions = ParseHist (tag, hist);

				if (stacksize == 0) then
					stacksize = numauctions;
				end
				
				gCurrentPane.sortedHist[n]				= {};
				gCurrentPane.sortedHist[n].itemPrice	= price;
				gCurrentPane.sortedHist[n].buyoutPrice	= price * stacksize;
				gCurrentPane.sortedHist[n].stackSize	= stacksize;
				gCurrentPane.sortedHist[n].when			= when;
				gCurrentPane.sortedHist[n].yours		= true;
				gCurrentPane.sortedHist[n].type			= type;

				n = n + 1;
			end
		end
	end

	table.sort (gCurrentPane.sortedHist, Atr_SortHistoryData);

	if (#gCurrentPane.sortedHist > 0) then
		return gCurrentPane.sortedHist[1].itemPrice;
	end

end

-----------------------------------------

function Atr_GetMostRecentSale (itemName)

	local recentPrice;
	local recentWhen = 0;
	
	if (AUCTIONATOR_PRICING_HISTORY and AUCTIONATOR_PRICING_HISTORY[itemName]) then
		local n = 1;
		local tag, hist;
		for tag, hist in pairs (AUCTIONATOR_PRICING_HISTORY[itemName]) do
			if (tag ~= "is") then
				local when, type, price = ParseHist (tag, hist);

				if (when > recentWhen) then
					recentPrice = price;
					recentWhen  = when;
				end
			end
		end
	end

	return recentPrice;

end


-----------------------------------------

function Atr_ShowingSearchSummary ()

	if (gCurrentPane.activeSearch and gCurrentPane.activeSearch.searchText ~= "" and gCurrentPane:IsScanEmpty() and gCurrentPane.activeSearch:NumScans() > 0) then
		return true;
	end
	
	return false;
end

-----------------------------------------

function Atr_ShowingCurrentAuctions ()
	if (gCurrentPane) then
		return gCurrentPane:ShowCurrent();
	end
	
	return true;
end

-----------------------------------------

function Atr_ShowingHistory ()
	if (gCurrentPane) then
		return gCurrentPane:ShowHistory();
	end
	
	return false;
end

-----------------------------------------

function Atr_ShowingHints ()
	if (gCurrentPane) then
		return gCurrentPane:ShowHints();
	end
	
	return false;
end



-----------------------------------------

function Atr_UpdateRecommendation (updatePrices)

	if (gCurrentPane == gSellPane and gJustPosted_ItemLink and GetAuctionSellItemInfo() == nil) then
		return;
	end

	local basedata;

	if (Atr_ShowingSearchSummary()) then
	
	elseif (Atr_ShowingCurrentAuctions()) then

		if (gCurrentPane:GetProcessingState() ~= KM_NULL_STATE) then
			return;
		end

		if (#gCurrentPane.activeScan.sortedData == 0) then
			Atr_SetMessage (ZT("No current auctions found"));
			return;
		end

		if (not gCurrentPane.currIndex) then
			if (gCurrentPane.activeScan.numMatches == 0) then
				Atr_SetMessage (ZT("No current auctions found\n\n(related auctions shown)"));
			elseif (gCurrentPane.activeScan.numMatchesWithBuyout == 0) then
				Atr_SetMessage (ZT("No current auctions with buyouts found"));
			else
				Atr_SetMessage ("");
			end
			return;
		end

		basedata = gCurrentPane.activeScan.sortedData[gCurrentPane.currIndex];
		
	elseif (Atr_ShowingHistory()) then
	
		basedata = zc.GetArrayElemOrFirst (gCurrentPane.sortedHist, gCurrentPane.histIndex);
		
		if (basedata == nil) then
			Atr_SetMessage (ZT("Auctionator has yet to record any auctions for this item"));
			return;
		end
	
	else	-- hints
		
		local data = zc.GetArrayElemOrFirst (gCurrentPane.hints, gCurrentPane.hintsIndex);
		
		if (data) then		
			basedata = {};
			basedata.itemPrice		= data.price;
			basedata.buyoutPrice	= data.price;
			basedata.stackSize		= 1;
			basedata.sourceText		= data.text;
			basedata.yours			= true;		-- so no discounting
		end
	end

	if (Atr_StackSize() == 0) then
		return;
	end

	local new_Item_BuyoutPrice;
	
	if (gItemPostingInProgress and gCurrentPane.itemLink == gJustPosted_ItemLink) then	-- handle the unusual case where server is still in the process of creating the last auction

		new_Item_BuyoutPrice = gJustPosted_BuyoutPrice / gJustPosted_StackSize;
		
	elseif (basedata) then			-- the normal case
	
		new_Item_BuyoutPrice = basedata.itemPrice;

		if (not basedata.yours and not basedata.altname) then
			new_Item_BuyoutPrice = Atr_CalcUndercutPrice (new_Item_BuyoutPrice);
		end
	end

	if (new_Item_BuyoutPrice == nil) then
		return;
	end
	
	local new_Item_StartPrice = Atr_CalcStartPrice (new_Item_BuyoutPrice);

	Atr_ShowElems (recommendElements);
	AuctionatorMessageFrame:Hide();
	AuctionatorMessage2Frame:Hide();

	Atr_Recommend_Text:SetText (ZT("Recommended Buyout Price"));
	Atr_RecommendPerStack_Text:SetText (string.format (ZT("for your stack of %d"), Atr_StackSize()));

	Atr_SetTextureButton ("Atr_RecommendItem_Tex", Atr_StackSize(), gCurrentPane.activeScan.itemLink);

	MoneyFrame_Update ("Atr_RecommendPerItem_Price",  zc.round(new_Item_BuyoutPrice));
	MoneyFrame_Update ("Atr_RecommendPerStack_Price", zc.round(new_Item_BuyoutPrice * Atr_StackSize()));

	if (updatePrices) then
		MoneyInputFrame_SetCopper (Atr_StackPrice,		new_Item_BuyoutPrice * Atr_StackSize());
		MoneyInputFrame_SetCopper (Atr_StartingPrice, 	new_Item_StartPrice * Atr_StackSize());
		MoneyInputFrame_SetCopper (Atr_ItemPrice,		new_Item_BuyoutPrice);
	end
	
	local cheapestStack = gCurrentPane.activeScan.bestPrices[Atr_StackSize()];

	Atr_Recommend_Basis_Text:SetTextColor (1,1,1);

	if (Atr_ShowingHints()) then
		Atr_Recommend_Basis_Text:SetTextColor (.8,.8,1);
		Atr_Recommend_Basis_Text:SetText ("("..ZT("based on").." "..basedata.sourceText..")");
	elseif (gCurrentPane.activeScan.absoluteBest and basedata.stackSize == gCurrentPane.activeScan.absoluteBest.stackSize and basedata.buyoutPrice == gCurrentPane.activeScan.absoluteBest.buyoutPrice) then
		Atr_Recommend_Basis_Text:SetText ("("..ZT("based on cheapest current auction")..")");
	elseif (cheapestStack and basedata.stackSize == cheapestStack.stackSize and basedata.buyoutPrice == cheapestStack.buyoutPrice) then
		Atr_Recommend_Basis_Text:SetText ("("..ZT("based on cheapest stack of the same size")..")");
	else
		Atr_Recommend_Basis_Text:SetText ("("..ZT("based on selected auction")..")");
	end

end


-----------------------------------------

function Atr_StackPriceChangedFunc ()

	local new_Stack_BuyoutPrice = MoneyInputFrame_GetCopper (Atr_StackPrice);
	local new_Item_BuyoutPrice  = math.floor (new_Stack_BuyoutPrice / Atr_StackSize());
	local new_Item_StartPrice   = Atr_CalcStartPrice (new_Item_BuyoutPrice);

	local calculatedStackPrice = MoneyInputFrame_GetCopper(Atr_ItemPrice) * Atr_StackSize();

	-- check to prevent looping
	
	if (calculatedStackPrice ~= new_Stack_BuyoutPrice) then
		MoneyInputFrame_SetCopper (Atr_ItemPrice,		new_Item_BuyoutPrice);
		MoneyInputFrame_SetCopper (Atr_StartingPrice,	new_Item_StartPrice * Atr_StackSize());
	end
	
end

-----------------------------------------

function Atr_ItemPriceChangedFunc ()

	local new_Item_BuyoutPrice = MoneyInputFrame_GetCopper (Atr_ItemPrice);
	local new_Item_StartPrice  = Atr_CalcStartPrice (new_Item_BuyoutPrice);
	
	local calculatedItemPrice = math.floor (MoneyInputFrame_GetCopper (Atr_StackPrice) / Atr_StackSize());

	-- check to prevent looping
	
	if (calculatedItemPrice ~= new_Item_BuyoutPrice) then
		MoneyInputFrame_SetCopper (Atr_StackPrice, 		new_Item_BuyoutPrice * Atr_StackSize());
		MoneyInputFrame_SetCopper (Atr_StartingPrice,	new_Item_StartPrice  * Atr_StackSize());
	end

end

-----------------------------------------

function Atr_StackSizeChangedFunc ()

	local item_BuyoutPrice		= MoneyInputFrame_GetCopper (Atr_ItemPrice);
	local new_Item_StartPrice   = Atr_CalcStartPrice (item_BuyoutPrice);
	
	MoneyInputFrame_SetCopper (Atr_StackPrice, 		item_BuyoutPrice * Atr_StackSize());
	MoneyInputFrame_SetCopper (Atr_StartingPrice,	new_Item_StartPrice  * Atr_StackSize());

--	Atr_MemorizeButton:Show();

	gSellPane.UINeedsUpdate = true;

end

-----------------------------------------

function Atr_NumAuctionsChangedFunc (x)

--	Atr_MemorizeButton:Show();

	gSellPane.UINeedsUpdate = true;
end


-----------------------------------------

function Atr_SetTextureButton (elementName, count, itemlink)

	local texture = GetItemIcon (itemlink);

	local textureElement = _G[elementName];

	if (texture) then
		textureElement:Show();
		textureElement:SetNormalTexture (texture);
		Atr_SetTextureButtonCount (elementName, count);
	else
		Atr_SetTextureButtonCount (elementName, 0);
	end

end

-----------------------------------------

function Atr_SetTextureButtonCount (elementName, count)

	local countElement   = _G[elementName.."Count"];

	if (count > 1) then
		countElement:SetText (count);
		countElement:Show();
	else
		countElement:Hide();
	end

end

-----------------------------------------

function Atr_ShowRecTooltip ()
	
	local link = gCurrentPane.activeScan.itemLink;
	local num  = Atr_StackSize();
	
	if (not link) then
		link = gJustPosted_ItemLink;
		num  = gJustPosted_StackSize;
	end
	
	if (link) then
		if (num < 1) then num = 1; end;
		
		GameTooltip:SetOwner(Atr_RecommendItem_Tex, "ANCHOR_RIGHT");
		GameTooltip:SetHyperlink (link, num);
		gCurrentPane.tooltipvisible = true;
	end

end

-----------------------------------------

function Atr_HideRecTooltip ()
	
	gCurrentPane.tooltipvisible = nil;
	GameTooltip:Hide();

end


-----------------------------------------

function Atr_OnAuctionHouseShow()

    -- Ensure we are not suspended while AH is open
    gAtr_SuspendForLoading = false;
    gAtr_SuspendUntilTime = 0;

    gOpenAllBags = AUCTIONATOR_OPEN_ALL_BAGS;

	    -- Safety: if for any reason Blizzard_AuctionUI loaded but our init did not run yet,
    -- initialize now so hooks, panes, and UI are ready immediately.
    if (not AuctionatorInited) then
        Atr_Init();
    end

    -- Ensure our main panel exists and has been attached
    if (not Atr_Main_Panel or not Atr_Main_Panel.GetName) then
        pcall(function() Atr_AddMainPanel(); end)
    end

	if (AUCTIONATOR_DEFTAB == 1) then		Atr_SelectPane (SELL_TAB);	end
	if (AUCTIONATOR_DEFTAB == 2) then		Atr_SelectPane (BUY_TAB);	end
	if (AUCTIONATOR_DEFTAB == 3) then		Atr_SelectPane (MORE_TAB);	end

	Atr_ResetDuration();

	gJustPosted_ItemName = nil;
	gSellPane:ClearSearch();

	    if (gCurrentPane) then
        gCurrentPane.UINeedsUpdate = true;
    end
end
-----------------------------------------

function Atr_OnAuctionHouseClosed()

    Atr_SwitchTo_BlizzItemOnClick();
    
    Atr_HideAllDialogs();
    
    Atr_CheckingActive_Finish ();

    -- removed leftover call to Atr_BagIC_Enable
    -- Atr_BagIC_Enable(false);
	Atr_ClearScanCache();

	gSellPane:ClearSearch();
	gShopPane:ClearSearch();
	gMorePane:ClearSearch();

end

-----------------------------------------

function Atr_HideAllDialogs()

	Atr_CheckActives_Frame:Hide();
	Atr_Error_Frame:Hide();
	Atr_Buy_Confirm_Frame:Hide();
	Atr_FullScanFrame:Hide();
	Atr_Adv_Search_Dialog:Hide();
	Atr_Mask:Hide();

end



-----------------------------------------

function Atr_BasicOptionsUpdate(self, elapsed)

	self.TimeSinceLastUpdate = self.TimeSinceLastUpdate + elapsed;

	if (self.TimeSinceLastUpdate > 0.25) then

		self.TimeSinceLastUpdate = 0;

		if (AuctionatorOption_Def_Duration_CB:GetChecked()) then
			AuctionatorOption_Durations:Show();
		else
			AuctionatorOption_Durations:Hide();
		end

	end
end


-----------------------------------------

function Atr_OnWhoListUpdate()

	if (gSendZoneMsgs) then
		gSendZoneMsgs = false;
		
		local numWhos, totalCount = GetNumWhoResults();
		local i;
		
		zc.md (numWhos.." out of "..totalCount.." users found");

		for i = 1,numWhos do
			local name, guildname, level = GetWhoInfo(i);
			Atr_SendAddon_VREQ ("WHISPER", name);
			if (Atr_Guildinfo) then
				Atr_Guildinfo[name] = guildname;
			end
			if (Atr_Levelinfo) then
				Atr_Levelinfo[name] = level;
			end
			
		end
	end
end

-----------------------------------------
function Atr_OnUpdate(self, elapsed)
    -- Fast bail-outs to prevent stutter during loading screens and flight paths
    local ahVisible = (AuctionFrame and AuctionFrame:IsShown())
    if (gAtr_SuspendForLoading and not ahVisible) then
        return;
    end
    if ((gAtr_SuspendUntilTime and time() < gAtr_SuspendUntilTime) and not ahVisible) then
        return;
    end
    local searchActive = (gCurrentPane and gCurrentPane.activeSearch and gCurrentPane.activeSearch.processing_state and gCurrentPane.activeSearch.processing_state ~= KM_NULL_STATE);
    if (GetPlayerMapPosition("player") == nil and not ahVisible) then
        return; -- Skip during loading/zone transitions
    end
    if (not searchActive) then
        if ((UnitOnTaxi and UnitOnTaxi("player")) or (not AuctionFrame or not AuctionFrame:IsShown())) then
            return; -- Skip when on taxi or when AH UI not visible and no active work
        end
    end

    gAtr_ptime = gAtr_ptime and gAtr_ptime + elapsed or 0;

    -- Only tick background tasks when the AH UI is visible or a search is active
    if ((AuctionFrame and AuctionFrame:IsShown()) or searchActive) then
        if (zc.periodic(self, "dcq_lastUpdate", 0.1, elapsed)) then -- Increased from 0.05 to 0.1
            zc.CheckDeferredCall();
        end
        -- Avoid tooltip cache warmup while on taxi to prevent hitches
        if (gAtr_dustCacheIndex > 0 and (not (UnitOnTaxi and UnitOnTaxi("player"))) and zc.periodic(self, "dust_lastUpdate", 0.2, elapsed)) then -- Increased from 0.1 to 0.2
            Atr_GetNextDustIntoCache();
        end
        if (zc.periodic(self, "idle_lastUpdate", 0.4, elapsed)) then -- Increased from 0.2 to 0.4
            Atr_Idle(self, elapsed);
        end
    end
end

-----------------------------------------
local verCheckMsgState = 0;
-----------------------------------------

function Atr_Idle(self, elapsed)


	if (gCurrentPane and gCurrentPane.tooltipvisible) then
		Atr_ShowRecTooltip();
	end


	if (gAtr_FullScanState ~= ATR_FS_NULL) then
		Atr_FullScanFrameIdle();
	end
	
	if (verCheckMsgState == 0) then
		verCheckMsgState = time();
	end
	
	if (verCheckMsgState > 1 and time() - verCheckMsgState > 5) then	-- wait 5 seconds
		verCheckMsgState = 1;
		
		local guildname = GetGuildInfo ("player");
		if (guildname) then
			Atr_SendAddon_VREQ ("GUILD");
		end
	end

    -- Always allow idle to run if a search is active, even if tab selection detection fails
    -- or the main panel frames haven't been created yet. This prevents stalls where
    -- nothing progresses until the user reloads or interacts.
    local searchActive = (gCurrentPane and gCurrentPane.activeSearch and gCurrentPane.activeSearch.processing_state and gCurrentPane.activeSearch.processing_state ~= KM_NULL_STATE);
    if (AuctionatorMessageFrame == nil and not searchActive) then
        return;
    end
    if (not Atr_IsTabSelected()) then
        if (not searchActive) then
            return;
        end
    end

	if (gHentryTryAgain) then	
		Atr_HEntryOnClick();
		return;
	end

	if (gCurrentPane.activeSearch and gCurrentPane.activeSearch.processing_state == KM_PREQUERY) then		------- check whether to send a new auction query to get the next page -------
		gCurrentPane.activeSearch:Continue();
	end

    -- Watchdog for active searches (BUY/SELL): if stalled >10s, finalize with current results
    if (gCurrentPane and gCurrentPane.activeSearch and gAtr_ptime) then
        local s = gCurrentPane.activeSearch;
        local now = gAtr_ptime or 0;
        -- If waiting for results of a page query too long, try to analyze what we have before finishing
        if (s.processing_state == KM_POSTQUERY and s.query_sent_when and (now - s.query_sent_when) > 3) then
            if (zc and zc.msg_atr) then zc.msg_atr("[Auctionator] Buy watchdog: POSTQUERY stalled for ", string.format("%.1f", now - s.query_sent_when), "s on page ", s.current_page); end
            if (s.query and s.query.CheckForDuplicatePage) then
                local _ = s.query:CheckForDuplicatePage(s.current_page);
            end
            if (s.AnalyzeResultsPage) then
                pcall(function() s:AnalyzeResultsPage(); end);
            end
            if (s.Finish and s.processing_state ~= KM_NULL_STATE) then
                s:Finish();
                Atr_OnSearchComplete ();
                if (gCurrentPane) then gCurrentPane.UINeedsUpdate = true; end
                Atr_UpdateUI();
            end
        end
        -- If waiting to be able to send the first/next query too long (PREQUERY), measure from prequery_when
        if (s.processing_state == KM_PREQUERY) then
            local since = s.prequery_when or s.started_when or now;
            if ((now - since) > 10) then
                if (zc and zc.msg_atr) then zc.msg_atr("[Auctionator] Buy watchdog: PREQUERY stalled for ", string.format("%.1f", now - since), "s; finishing early. current_page=", s.current_page or -1); end
                if (s.Finish and s.processing_state ~= KM_NULL_STATE) then
                    s:Finish();
                    Atr_OnSearchComplete ();
                    if (gCurrentPane) then gCurrentPane.UINeedsUpdate = true; end
                    Atr_UpdateUI();
                end
            end
        end
    end

	Atr_UpdateUI ();

	Atr_CheckingActiveIdle();
	
	Atr_Buy_Idle();
	
	if (gHideAPFrameCheck == nil) then	-- for the addon 'Auction Profit' (flags for efficiency so we only check one time)
		gHideAPFrameCheck = true;
		if (AP_Bid_MoneyFrame) then	
			AP_Bid_MoneyFrame:Hide();
			AP_Buy_MoneyFrame:Hide();
		end
	end
end

-----------------------------------------

local gPrevSellItemLink;

-----------------------------------------

function Atr_OnNewAuctionUpdate()
	
	if (not gAtr_ClickAuctionSell) then
		gPrevSellItemLink = nil;
		return;
	end
	
--	zc.md ("gAtr_ClickAuctionSell:", gAtr_ClickAuctionSell);
	
	gAtr_ClickAuctionSell = false;

	local auctionItemName, auctionCount, auctionLink = Atr_GetSellItemInfo();

	if (gPrevSellItemLink ~= auctionLink) then

		gPrevSellItemLink = auctionLink;
		
		if (auctionLink) then
			gJustPosted_ItemName = nil;
			Atr_AddToItemLinkCache (auctionItemName, auctionLink);
			Atr_ClearList();		-- better UE
			gSellPane:SetToShowCurrent();
		end
		
		MoneyInputFrame_SetCopper (Atr_StackPrice, 0);
		MoneyInputFrame_SetCopper (Atr_StartingPrice,  0);
		Atr_ResetDuration();
		
		if (gJustPosted_ItemName == nil) then
			local cacheHit = gSellPane:DoSearch (auctionItemName, true, 20);
			
			gSellPane.totalItems	= Atr_GetNumItemInBags (auctionItemName);
			gSellPane.fullStackSize = auctionLink and (select (8, GetItemInfo (auctionLink))) or 0;

			local prefNumStacks, prefStackSize = Atr_GetSellStacking (auctionLink, auctionCount, gSellPane.totalItems);
			
			if (time() - gAutoSingleton < 5) then
				Atr_SetInitialStacking (1, 1);
			else
				Atr_SetInitialStacking (prefNumStacks, prefStackSize);
			end
			
			if (cacheHit) then
				Atr_OnSearchComplete ();
			end
			
			Atr_SetTextureButton ("Atr_SellControls_Tex", Atr_StackSize(), auctionLink);
			Atr_SellControls_TexName:SetText (auctionItemName);
		else
			Atr_SetTextureButton ("Atr_SellControls_Tex", 0, nil);
			Atr_SellControls_TexName:SetText ("");
		end
		
	elseif (Atr_StackSize() ~= auctionCount) then
	
		local prefNumStacks, prefStackSize = Atr_GetSellStacking (auctionLink, auctionCount, gSellPane.totalItems);

		Atr_SetInitialStacking (prefNumStacks, prefStackSize);

		Atr_SetTextureButton ("Atr_SellControls_Tex", Atr_StackSize(), auctionLink);

		Atr_FindBestCurrentAuction();
		Atr_ResetDuration();
	end
		
	gSellPane.UINeedsUpdate = true;
	
end

---------------------------------------------------------

function Atr_UpdateUI ()

	local needsUpdate = gCurrentPane.UINeedsUpdate;
	
	if (gCurrentPane.UINeedsUpdate) then

		gCurrentPane.UINeedsUpdate = false;

		if (Atr_ShowingSearchSummary()) then
			Atr_ShowSearchSummary();
		elseif (gCurrentPane:ShowCurrent()) then
			PanelTemplates_SetTab(Atr_ListTabs, 1);
			Atr_ShowCurrentAuctions();
		elseif (gCurrentPane:ShowHistory()) then
			PanelTemplates_SetTab(Atr_ListTabs, 2);
			Atr_ShowHistory();
		else
			PanelTemplates_SetTab(Atr_ListTabs, 3);
			Atr_ShowHints();
		end
		
		if (gCurrentPane:IsScanEmpty()) then
			Atr_ListTabs:Hide();
		else
			Atr_ListTabs:Show();
		end

		Atr_SetMessage ("");
		local scn = gCurrentPane.activeScan;
		
		if (Atr_IsModeCreateAuction()) then
		
			Atr_UpdateRecommendation (false);
		else
			Atr_HideElems (recommendElements);
		
			if (scn:IsNil()) then
				Atr_ShowItemNameAndTexture (gCurrentPane.activeSearch.searchText);
			else
				Atr_ShowItemNameAndTexture (gCurrentPane.activeScan.itemName);
			end

			if (Atr_IsModeBuy()) then

				if (gCurrentPane.activeSearch.searchText == "") then
					Atr_SetMessage (ZT("Select an item from the list on the left\n or type a search term above to start a scan."));
				end
			end
		
		end
		
		
		if (Atr_IsTabSelected(BUY_TAB) or (gCurrentPane == gShopPane)) then
            Atr_Shop_UpdateUI();
        end
		
	end
	
	-- update the hlist if needed

	if (gHlistNeedsUpdate and Atr_IsModeActiveAuctions()) then
		gHlistNeedsUpdate = false;
		Atr_DisplayHlist();
	end
	
	if (Atr_IsTabSelected(SELL_TAB)) then
		Atr_UpdateUI_SellPane (needsUpdate);
	end

end

---------------------------------------------------------

function Atr_UpdateUI_SellPane (needsUpdate)

	local auctionItemName = GetAuctionSellItemInfo();

	if (needsUpdate) then

		if (gCurrentPane.activeSearch and gCurrentPane.activeSearch.processing_state ~= KM_NULL_STATE) then
			Atr_CreateAuctionButton:Disable();
			Atr_FullScanButton:Disable();
			Auctionator1Button:Disable();		
			MoneyInputFrame_SetCopper (Atr_StartingPrice,  0);
			return;
		else
			Atr_FullScanButton:Enable();
			Auctionator1Button:Enable();		


			if (Atr_Batch_Stacksize.oldStackSize ~= Atr_StackSize()) then
				Atr_Batch_Stacksize.oldStackSize = Atr_StackSize();
				local itemPrice = MoneyInputFrame_GetCopper(Atr_ItemPrice);
				MoneyInputFrame_SetCopper (Atr_StackPrice,  itemPrice * Atr_StackSize());
			end

			Atr_StartingPriceDiscountText:SetText (ZT("Starting Price Discount")..":  "..AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT.."%");
			
			if (Atr_Batch_NumAuctions:GetNumber() < 2) then
				Atr_Batch_Stacksize_Text:SetText (ZT("stack of"));
				Atr_CreateAuctionButton:SetText (ZT("Create Auction"));
			else
				Atr_Batch_Stacksize_Text:SetText (ZT("stacks of"));
				Atr_CreateAuctionButton:SetText (string.format (ZT("Create %d Auctions"), Atr_Batch_NumAuctions:GetNumber()));
			end

			if (Atr_StackSize() > 1) then
				Atr_StackPriceText:SetText (ZT("Buyout Price").." |cff55ddffx"..Atr_StackSize().."|r");
				Atr_ItemPriceText:SetText (ZT("Per Item"));
				Atr_ItemPriceText:Show();
				Atr_ItemPrice:Show();
			else
				Atr_StackPriceText:SetText (ZT("Buyout Price"));
				Atr_ItemPriceText:Hide();
				Atr_ItemPrice:Hide();
			end

			Atr_SetTextureButton ("Atr_SellControls_Tex", Atr_StackSize(), Atr_GetItemLink(auctionItemName));

			
			local maxAuctions = 0;
			if (Atr_StackSize() > 0) then
				maxAuctions = math.floor (gCurrentPane.totalItems / Atr_StackSize());
			end
			
			Atr_Batch_MaxAuctions_Text:SetText (ZT("max")..": "..maxAuctions);
			Atr_Batch_MaxStacksize_Text:SetText (ZT("max")..": "..gCurrentPane.fullStackSize);
			
			Atr_SetDepositText();			
		end

		if (gJustPosted_ItemName ~= nil) then

			Atr_Recommend_Text:SetText (string.format (ZT("Auction created for %s"), gJustPosted_ItemName));
			MoneyFrame_Update ("Atr_RecommendPerStack_Price", gJustPosted_BuyoutPrice);
			Atr_SetTextureButton ("Atr_RecommendItem_Tex", gJustPosted_StackSize, gJustPosted_ItemLink);

			gCurrentPane.currIndex = gCurrentPane.activeScan:FindInSortedData (gJustPosted_StackSize, gJustPosted_BuyoutPrice);

			if (gCurrentPane:ShowCurrent()) then
				Atr_HighlightEntry (gCurrentPane.currIndex);		-- highlight the newly created auction(s)
			else
				Atr_HighlightEntry (gCurrentPane.histIndex);
			end
		
		elseif (gCurrentPane:IsScanEmpty()) then
			Atr_SetMessage (ZT("Drag an item you want to sell to this area."));
		end
	end

	-- stuff we should do every time (not just when needsUpdate is true)
	
	local start		= MoneyInputFrame_GetCopper(Atr_StartingPrice);
	local buyout	= MoneyInputFrame_GetCopper(Atr_StackPrice);

	local pricesOK	= (start > 0 and (start <= buyout or buyout == 0) and (auctionItemName ~= nil));
	
	local numToSell = Atr_Batch_NumAuctions:GetNumber() * Atr_Batch_Stacksize:GetNumber();

	zc.EnableDisable (Atr_CreateAuctionButton,	pricesOK and (numToSell <= gCurrentPane.totalItems));
	
end

-----------------------------------------

function Atr_SetDepositText()
			
	_, auctionCount = Atr_GetSellItemInfo();
	
	if (auctionCount > 0) then
		local duration = UIDropDownMenu_GetSelectedValue(Atr_Duration);
	
		local deposit1 = CalculateAuctionDeposit (duration) / auctionCount;
		local numAuctionString = "";
		if (Atr_Batch_NumAuctions:GetNumber() > 1) then
			numAuctionString = "  |cffff55ff x"..Atr_Batch_NumAuctions:GetNumber();
		end
		
		Atr_Deposit_Text:SetText (ZT("Deposit")..":    "..zc.priceToMoneyString(deposit1 * Atr_StackSize(), true)..numAuctionString);
	else
		Atr_Deposit_Text:SetText ("");
	end
end


-----------------------------------------

function Atr_BuildActiveAuctions ()

	gActiveAuctions = {};
	
	local i = 1;
	while (true) do
		local name, _, count = GetAuctionItemInfo ("owner", i);
		if (name == nil) then
			break;
		end

		if (count > 0) then		-- count is 0 for sold items
			if (gActiveAuctions[name] == nil) then
				gActiveAuctions[name] = 1;
			else
				gActiveAuctions[name] = gActiveAuctions[name] + 1;
			end
		end
		
		i = i + 1;
	end
end

-----------------------------------------

function Atr_GetUCIcon (itemName)

	local icon = "|TInterface\\BUTTONS\\\UI-PassiveHighlight:18:18:0:0|t "

	local undercutFound = false;
	
	local scan = Atr_FindScan (itemName);
	if (scan and scan.absoluteBest and scan.whenScanned ~= 0 and scan.yourBestPrice and scan.yourWorstPrice) then
		
		local absBestPrice = scan.absoluteBest.itemPrice;
			
		if (scan.yourBestPrice <= absBestPrice and scan.yourWorstPrice > absBestPrice) then
			icon = "|TInterface\\AddOns\\Auctionator\\Images\\CrossAndCheck:18:18:0:0|t "
			undercutFound = true;
		elseif (scan.yourBestPrice <= absBestPrice) then
			icon = "|TInterface\\RAIDFRAME\\\ReadyCheck-Ready:18:18:0:0|t "
		else
			icon = "|TInterface\\RAIDFRAME\\\ReadyCheck-NotReady:18:18:0:0|t "
			undercutFound = true;
		end
	end

	if (gAtr_CheckingActive_State ~= ATR_CACT_NULL and undercutFound) then
		gAtr_CheckingActive_NumUndercuts = gAtr_CheckingActive_NumUndercuts + 1;
	end

	return icon;

end

-----------------------------------------

function Atr_DisplayHlist ()

	if (Atr_IsTabSelected (BUY_TAB)) then		-- done this way because OnScrollFrame always calls Atr_DisplayHlist
		Atr_DisplaySlist();
		return;
	end

	local doFull = (UIDropDownMenu_GetSelectedValue(Atr_DropDown1) == MODE_LIST_ALL);

	Atr_BuildGlobalHistoryList (doFull);
	
	local numrows = #gHistoryItemList;

	local line;							-- 1 through NN of our window to scroll
	local dataOffset;					-- an index into our data calculated from the scroll offset

	FauxScrollFrame_Update (Atr_Hlist_ScrollFrame, numrows, ITEM_HIST_NUM_LINES, 16);

	for line = 1,ITEM_HIST_NUM_LINES do

		gCurrentPane.hlistScrollOffset = (FauxScrollFrame_GetOffset(Atr_Hlist_ScrollFrame) or 0);
		
		dataOffset = line + gCurrentPane.hlistScrollOffset;

		local lineEntry = _G["AuctionatorHEntry"..line];

		lineEntry:SetID(dataOffset);

		if (dataOffset <= numrows and gHistoryItemList[dataOffset]) then

			local lineEntry_text = _G["AuctionatorHEntry"..line.."_EntryText"];

			local iName = gHistoryItemList[dataOffset];

			local icon = "";
			
			if (not doFull) then
				icon = Atr_GetUCIcon (iName);
			end

			lineEntry_text:SetText	(icon..Atr_AbbrevItemName (iName));


			if (iName == gCurrentPane.activeSearch.searchText) then
				lineEntry:SetButtonState ("PUSHED", true);
			else
				lineEntry:SetButtonState ("NORMAL", false);
			end

			lineEntry:Show();
		else
			lineEntry:Hide();
		end
	end


end

-----------------------------------------

function Atr_ClearHlist ()
	local line;
	for line = 1,ITEM_HIST_NUM_LINES do
		local lineEntry = _G["AuctionatorHEntry"..line];
		lineEntry:Hide();
		
		local lineEntry_text = _G["AuctionatorHEntry"..line.."_EntryText"];
		lineEntry_text:SetText		("");
		lineEntry_text:SetTextColor	(.7,.7,.7);
	end

end

-----------------------------------------

function Atr_HEntryOnClick(self)

	if (gCurrentPane == gShopPane) then
		Atr_SEntryOnClick(self);
		return;
	end

	local line = self;

	if (gHentryTryAgain) then
		line = gHentryTryAgain;
		gHentryTryAgain = nil;
	end

	local _, itemLink;
	local entryIndex = line:GetID();
	
	itemName = gHistoryItemList[entryIndex];

	if (IsAltKeyDown() and Atr_IsModeActiveAuctions()) then
		Atr_Cancel_Undercuts_OnClick (itemName)
		return;
	end
	
	if (AUCTIONATOR_PRICING_HISTORY[itemName]) then
		local itemId, suffixId, uniqueId = strsplit(":", AUCTIONATOR_PRICING_HISTORY[itemName]["is"])

		local itemId	= tonumber(itemId);

		if (suffixId == nil) then	suffixId = 0;
		else		 				suffixId = tonumber(suffixId);
		end

		if (uniqueId == nil) then	uniqueId = 0;
		else		 				uniqueId = tonumber(suffixId);
		end

		local itemString = "item:"..itemId..":0:0:0:0:0:"..suffixId..":"..uniqueId;

		_, itemLink = GetItemInfo(itemString);

		if (itemLink == nil) then		-- pull it into the cache and go back to the idle loop to wait for it to appear
			AtrScanningTooltip:SetHyperlink(itemString);
			gHentryTryAgain = line;
			zc.md ("pulling "..itemName.." into the local cache");
			return;
		end
	end
	
	gCurrentPane.UINeedsUpdate = true;
	
	Atr_ClearAll();
	
	local cacheHit = gCurrentPane:DoSearch (itemName, true, 20);

	Atr_Process_Historydata ();
	Atr_FindBestHistoricalAuction ();

	Atr_DisplayHlist();	 -- for the highlight

	if (cacheHit) then
		Atr_OnSearchComplete();
	end

	PlaySound ("igMainMenuOptionCheckBoxOn");
end

-----------------------------------------

function Atr_ShowWhichRB (id)

	if (gCurrentPane.activeSearch.processing_state ~= KM_NULL_STATE) then		-- if we're scanning auctions don't respond
		return;
	end

	PlaySound("igMainMenuOptionCheckBoxOn");

	if (id == 1) then
		gCurrentPane:SetToShowCurrent();
	elseif (id == 2) then
		gCurrentPane:SetToShowHistory();
	else
		gCurrentPane:SetToShowHints();
	end
	
	gCurrentPane.UINeedsUpdate = true;

end


-----------------------------------------

function Atr_RedisplayAuctions ()

	if (Atr_ShowingSearchSummary()) then
		Atr_ShowSearchSummary();
	elseif (Atr_ShowingCurrentAuctions()) then
		Atr_ShowCurrentAuctions();
	elseif Atr_ShowingHistory() then
		Atr_ShowHistory();
	else
		Atr_ShowHints();
	end
end

-----------------------------------------

function Atr_BuildHistItemText(data)

	local stacktext = "";
--	if (data.stackSize > 1) then
--		stacktext = " (stack of "..data.stackSize..")";
--	end

	local now		= time();
	local nowtime	= date ("*t");

	local when		= data.when;
	local whentime	= date ("*t", when);

	local numauctions = data.stackSize;

	local datestr = "";

	if (data.type == "hy") then
		return ZT("average of your auctions for").." "..whentime.year;
	elseif (data.type == "hm") then
		if (nowtime.year == whentime.year) then
			return ZT("average of your auctions for").." "..date("%B", when);
		else
			return ZT("average of your auctions for").." "..date("%B %Y", when);
		end
	elseif (data.type == "hd") then
		return ZT("average of your auctions for").." "..monthDay(whentime);
	else
		return ZT("your auction on").." "..monthDay(whentime)..date(" at %I:%M %p", when);
	end
end

-----------------------------------------

function monthDay (when)

	local t = time(when);

	local s = date("%b ", t);

	return s..when.day;

end

-----------------------------------------

function Atr_ShowLineTooltip (self)

	local itemLink = self.itemLink;
		
	if (itemLink) then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT", -280);
		GameTooltip:SetHyperlink (itemLink, 1);
	end
end

-----------------------------------------

function Atr_HideLineTooltip (self)
	GameTooltip:Hide();
end


-----------------------------------------

function Atr_Onclick_Back ()

	gCurrentPane.activeScan = Atr_FindScan (nil);
	gCurrentPane.UINeedsUpdate = true;

end

-----------------------------------------

function Atr_Onclick_Col1 ()

	if (gCurrentPane.activeSearch) then
		gCurrentPane.activeSearch:ClickPriceCol();
		gCurrentPane.UINeedsUpdate = true;
	end

end

-----------------------------------------

function Atr_Onclick_Col3 ()

	if (gCurrentPane.activeSearch) then
		gCurrentPane.activeSearch:ClickNameCol();
		gCurrentPane.UINeedsUpdate = true;
	end

end

-----------------------------------------

function Atr_ShowSearchSummary()

	Atr_Col1_Heading:Hide();
	Atr_Col3_Heading:Hide();
	Atr_Col1_Heading_Button:Show();
	Atr_Col3_Heading_Button:Show();
	Atr_Col4_Heading:Show();

	gCurrentPane.activeSearch:UpdateArrows ();

	local numrows = gCurrentPane.activeSearch:NumScans();

	if (gCurrentPane.activeScan.hasStack) then
		Atr_Col4_Heading:SetText (ZT("Total Price"));
	else
		Atr_Col4_Heading:SetText ("");
	end

	local highIndex  = 0;
	local line       = 0;                                                            -- 1 through N of our window to scroll
	local dataOffset = (FauxScrollFrame_GetOffset(AuctionatorScrollFrame) or 0);           -- an index into our data calculated from the scroll offset

    local visibleLines = 12;
    if (Atr_IsTabSelected and (Atr_IsTabSelected(SELL_TAB) or Atr_IsTabSelected(BUY_TAB)) and AuctionatorScrollFrame and AuctionatorScrollFrame.GetHeight) then
        local h = AuctionatorScrollFrame:GetHeight() or 196;
        visibleLines = math.max(1, math.min(12, math.floor(h / 16)));
    end

	FauxScrollFrame_Update (AuctionatorScrollFrame, numrows, visibleLines, 16);

	while (line < visibleLines) do

		dataOffset	= dataOffset + 1;
		line		= line + 1;

		local lineEntry = _G["AuctionatorEntry"..line];

		lineEntry:SetID(dataOffset);

		local scn;
		
		if (gCurrentPane.activeSearch and gCurrentPane.activeSearch:NumSortedScans() > 0) then
			scn = gCurrentPane.activeSearch.sortedScans[dataOffset];
		end
		
		if (dataOffset > numrows or not scn) then

			lineEntry:Hide();

		else
			local data = scn.absoluteBest;

			local lineEntry_item_tag = "AuctionatorEntry"..line.."_PerItem_Price";

			local lineEntry_item		= _G[lineEntry_item_tag];
			local lineEntry_itemtext	= _G["AuctionatorEntry"..line.."_PerItem_Text"];
			local lineEntry_text		= _G["AuctionatorEntry"..line.."_EntryText"];
			local lineEntry_stack		= _G["AuctionatorEntry"..line.."_StackPrice"];

			lineEntry_itemtext:SetText	("");
			lineEntry_text:SetText	("");
			lineEntry_stack:SetText	("");

			lineEntry_text:GetParent():SetPoint ("LEFT", 157, 0);
			
			Atr_SetMFcolor (lineEntry_item_tag);
			
			lineEntry:Show();

			lineEntry.itemLink = scn.itemLink;
			
			local r = scn.itemTextColor[1];
			local g = scn.itemTextColor[2];
			local b = scn.itemTextColor[3];
			
			lineEntry_text:SetTextColor (r, g, b);
			lineEntry_stack:SetTextColor (1, 1, 1);
			
			local icon = Atr_GetUCIcon (scn.itemName);
			
			lineEntry_text:SetText (icon.."  "..scn.itemName);
			lineEntry_stack:SetText (scn:GetNumAvailable().." "..ZT("available"));
			
			if (data == nil or data.buyoutPrice == 0) then
				lineEntry_item:Hide();
				lineEntry_itemtext:Show();
				lineEntry_itemtext:SetText (ZT("no buyout price"));
			else
				lineEntry_item:Show();
				lineEntry_itemtext:Hide();
				MoneyFrame_Update (lineEntry_item_tag, zc.round(data.buyoutPrice/data.stackSize) );
			end
			
			if (zc.StringSame (scn.itemName , gCurrentPane.SS_hilite_itemName)) then
				highIndex = dataOffset;
			end


		end
	end
	
    -- Hide any extra rows beyond visibleLines on SELL/BUY so they don't bleed outside
    if (Atr_IsTabSelected and (Atr_IsTabSelected(SELL_TAB) or Atr_IsTabSelected(BUY_TAB))) then
        for i = visibleLines + 1, 15 do
            local extra = _G["AuctionatorEntry"..i];
            if (extra) then extra:Hide(); end
        end
    end

	Atr_HighlightEntry (highIndex);		-- need this for when called from onVerticalScroll
end

-----------------------------------------

function Atr_ShowCurrentAuctions()

	Atr_Col1_Heading:Hide();
	Atr_Col3_Heading:Hide();
	Atr_Col4_Heading:Hide();
	Atr_Col1_Heading_Button:Hide();
	Atr_Col3_Heading_Button:Hide();


	local numrows = #gCurrentPane.activeScan.sortedData;

	if (numrows > 0) then
		Atr_Col1_Heading:Show();
		Atr_Col3_Heading:Show();
		Atr_Col4_Heading:Show();
	end

	Atr_Col1_Heading:SetText (ZT("Item Price"));
	Atr_Col3_Heading:SetText (ZT("Current Auctions"));

	if (gCurrentPane.activeScan.hasStack) then
		Atr_Col4_Heading:SetText (ZT("Stack Price"));
	else
		Atr_Col4_Heading:SetText ("");
	end

	local line		 = 0;															-- 1 through N of our window to scroll
	local dataOffset = (FauxScrollFrame_GetOffset(AuctionatorScrollFrame) or 0);			-- an index into our data calculated from the scroll offset

    local visibleLines = 12;
    if (Atr_IsTabSelected and (Atr_IsTabSelected(SELL_TAB) or Atr_IsTabSelected(BUY_TAB)) and AuctionatorScrollFrame and AuctionatorScrollFrame.GetHeight) then
        local h = AuctionatorScrollFrame:GetHeight() or 196;
        visibleLines = math.max(1, math.min(12, math.floor(h / 16)));
    end

	FauxScrollFrame_Update (AuctionatorScrollFrame, numrows, visibleLines, 16);

	while (line < visibleLines) do

		dataOffset	= dataOffset + 1;
		line		= line + 1;

		local lineEntry = _G["AuctionatorEntry"..line];

		lineEntry:SetID(dataOffset);

		lineEntry.itemLink = nil;

		if (dataOffset > numrows or not gCurrentPane.activeScan.sortedData[dataOffset]) then

			lineEntry:Hide();

		else
			local data = gCurrentPane.activeScan.sortedData[dataOffset];

			local lineEntry_item_tag = "AuctionatorEntry"..line.."_PerItem_Price";

			local lineEntry_item		= _G[lineEntry_item_tag];
			local lineEntry_itemtext	= _G["AuctionatorEntry"..line.."_PerItem_Text"];
			local lineEntry_text		= _G["AuctionatorEntry"..line.."_EntryText"];
			local lineEntry_stack		= _G["AuctionatorEntry"..line.."_StackPrice"];

			lineEntry_itemtext:SetText	("");
			lineEntry_text:SetText	("");
			lineEntry_stack:SetText	("");

			lineEntry_text:GetParent():SetPoint ("LEFT", 172, 0);

			Atr_SetMFcolor (lineEntry_item_tag);
			
			local entrytext = "";

			if (data.type == "n") then

				lineEntry:Show();

				if (data.count == 1) then
					entrytext = string.format ("%i %s %i", data.count, ZT ("stack of"), data.stackSize);
				else
					entrytext = string.format ("%i %s %i", data.count, ZT ("stacks of"), data.stackSize);
				end
				
				lineEntry_text:SetTextColor (0.6, 0.6, 0.6);
				
				if ( data.stackSize == Atr_StackSize() or Atr_StackSize() == 0 or gCurrentPane ~= gSellPane) then
					lineEntry_text:SetTextColor (1.0, 1.0, 1.0);
				end

				if (data.yours) then
					 entrytext = entrytext.." ("..ZT("yours")..")";
				elseif (data.altname) then
					 entrytext = entrytext.." ("..data.altname..")";
				end

				lineEntry_text:SetText (entrytext);

				if (data.buyoutPrice == 0) then
					lineEntry_item:Hide();
					lineEntry_itemtext:Show();
					lineEntry_itemtext:SetText (ZT("no buyout price"));
				else
					lineEntry_item:Show();
					lineEntry_itemtext:Hide();
					MoneyFrame_Update (lineEntry_item_tag, zc.round(data.buyoutPrice/data.stackSize) );

					if (data.stackSize > 1) then
						lineEntry_stack:SetText (zc.priceToString(data.buyoutPrice));
						lineEntry_stack:SetTextColor (0.6, 0.6, 0.6);
					end
				end
			
			else
				zc.msg_red ("Unknown datatype:");
				zc.msg_red (data.type);
			end
		end
	end
	
    -- Hide any extra rows beyond visibleLines on SELL/BUY so they don't bleed outside
    if (Atr_IsTabSelected and (Atr_IsTabSelected(SELL_TAB) or Atr_IsTabSelected(BUY_TAB))) then
        for i = visibleLines + 1, 15 do
            local extra = _G["AuctionatorEntry"..i];
            if (extra) then extra:Hide(); end
        end
    end

	Atr_HighlightEntry (gCurrentPane.currIndex);		-- need this for when called from onVerticalScroll
end

-----------------------------------------

function Atr_ShowHistory ()

	if (gCurrentPane.sortedHist == nil) then
		Atr_Process_Historydata ();
		Atr_FindBestHistoricalAuction ();
	end
		
	Atr_Col1_Heading:Hide();
	Atr_Col3_Heading:Hide();
	Atr_Col4_Heading:Hide();

	Atr_Col3_Heading:SetText (ZT("History"));

	local numrows = gCurrentPane.sortedHist and #gCurrentPane.sortedHist or 0;

--zc.msg ("gCurrentPane.sortedHist: "..numrows,1,0,0);

	if (numrows > 0) then
		Atr_Col1_Heading:Show();
		Atr_Col3_Heading:Show();
	end

	local line;							-- 1 through 12 of our window to scroll
	local dataOffset;					-- an index into our data calculated from the scroll offset

	FauxScrollFrame_Update (AuctionatorScrollFrame, numrows, 12, 16);

	for line = 1,12 do

		dataOffset = line + (FauxScrollFrame_GetOffset(AuctionatorScrollFrame) or 0);

		local lineEntry = _G["AuctionatorEntry"..line];

		lineEntry:SetID(dataOffset);

		if (dataOffset <= numrows and gCurrentPane.sortedHist[dataOffset]) then

			local data = gCurrentPane.sortedHist[dataOffset];

			local lineEntry_item_tag = "AuctionatorEntry"..line.."_PerItem_Price";

			local lineEntry_item		= _G[lineEntry_item_tag];
			local lineEntry_itemtext	= _G["AuctionatorEntry"..line.."_PerItem_Text"];
			local lineEntry_text		= _G["AuctionatorEntry"..line.."_EntryText"];
			local lineEntry_stack		= _G["AuctionatorEntry"..line.."_StackPrice"];

			lineEntry_item:Show();
			lineEntry_itemtext:Hide();
			lineEntry_stack:SetText	("");

			Atr_SetMFcolor (lineEntry_item_tag);

			MoneyFrame_Update (lineEntry_item_tag, zc.round(data.itemPrice) );

			lineEntry_text:SetText (Atr_BuildHistItemText (data));
			lineEntry_text:SetTextColor (0.8, 0.8, 1.0);

			lineEntry:Show();
		else
			lineEntry:Hide();
		end
	end

	if (Atr_IsTabSelected (SELL_TAB)) then
		Atr_HighlightEntry (gCurrentPane.histIndex);		-- need this for when called from onVerticalScroll
	else
		Atr_HighlightEntry (-1);
	end
end


-----------------------------------------

function Atr_FindBestCurrentAuction()

	local scan = gCurrentPane.activeScan;
	
	if		(Atr_IsModeCreateAuction()) then	gCurrentPane.currIndex = scan:FindCheapest ();
	elseif	(Atr_IsModeBuy()) then				gCurrentPane.currIndex = scan:FindCheapest ();
	else										gCurrentPane.currIndex = scan:FindMatchByYours ();
	end

end

-----------------------------------------

function Atr_FindBestHistoricalAuction()

	gCurrentPane.histIndex = nil;

	if (gCurrentPane.sortedHist and #gCurrentPane.sortedHist > 0) then
		gCurrentPane.histIndex = 1;
	end
end

-----------------------------------------

function Atr_HighlightEntry(entryIndex)

	local line;				-- 1 through 12 of our window to scroll

	for line = 1,12 do

		local lineEntry = _G["AuctionatorEntry"..line];

		if (lineEntry:GetID() == entryIndex) then
			lineEntry:SetButtonState ("PUSHED", true);
		else
			lineEntry:SetButtonState ("NORMAL", false);
		end
	end

	local doEnableCancel = false;
	local doEnableBuy = false;
	local data;
	
	if (Atr_ShowingCurrentAuctions() and entryIndex ~= nil and entryIndex > 0 and entryIndex <= #gCurrentPane.activeScan.sortedData) then
		data = gCurrentPane.activeScan.sortedData[entryIndex];
		if (data.yours) then
			doEnableCancel = true;
		end
		
		if (not data.yours and not data.altname and data.buyoutPrice > 0) then
			doEnableBuy = true;
		end
	end

	Atr_Buy1_Button:Disable();
	Atr_CancelSelectionButton:Disable();
	
	if (doEnableCancel) then
		Atr_CancelSelectionButton:Enable();

		if (data.count == 1) then
			Atr_CancelSelectionButton:SetText (CANCEL_AUCTION);
		else
			Atr_CancelSelectionButton:SetText (ZT("Cancel Auctions"));
		end
	end

	if (doEnableBuy) then
		Atr_Buy1_Button:Enable();
	end
	
end

-----------------------------------------

function Atr_EntryOnClick(entry)

	Atr_Clear_Owner_Item_Indices();

	local entryIndex = entry:GetID();

	if     (Atr_ShowingSearchSummary()) 	then	
	elseif (Atr_ShowingCurrentAuctions())	then		gCurrentPane.currIndex = entryIndex;
	elseif (Atr_ShowingHistory())			then		gCurrentPane.histIndex = entryIndex;
	else												gCurrentPane.hintsIndex = entryIndex;
	end

	if (Atr_ShowingSearchSummary()) then
		local scn = gCurrentPane.activeSearch.sortedScans[entryIndex];

		FauxScrollFrame_SetOffset (AuctionatorScrollFrame, 0);
		gCurrentPane.activeScan = scn;
		gCurrentPane.currIndex = scn:FindMatchByYours ();
		if (gCurrentPane.currIndex == nil) then
			gCurrentPane.currIndex = scn:FindCheapest();
		end

		gCurrentPane.SS_hilite_itemName = scn.itemName;
		gCurrentPane.UINeedsUpdate = true;
	else
		Atr_HighlightEntry (entryIndex);
		Atr_UpdateRecommendation(true);
	end

	PlaySound ("igMainMenuOptionCheckBoxOn");
end

-----------------------------------------

function AuctionatorMoneyFrame_OnLoad(self)

	self.small = 1;
	MoneyFrame_SetType(self, "AUCTION");
end


-----------------------------------------

function Atr_GetNumItemInBags (theItemName)

	local numItems = 0;
	local b, bagID, slotID, numslots;
	
	for b = 1, #kBagIDs do
		bagID = kBagIDs[b];
		
		numslots = GetContainerNumSlots (bagID);
		for slotID = 1,numslots do
			local itemLink = GetContainerItemLink(bagID, slotID);
			if (itemLink) then
				local itemName				= GetItemInfo(itemLink);
				local texture, itemCount	= GetContainerItemInfo(bagID, slotID);

				if (itemName == theItemName) then
					numItems = numItems + itemCount;
				end
			end
		end
	end

	return numItems;

end

-----------------------------------------

function Atr_DoesAuctionMatch (list, i, name, buyout, stacksize)

	local aname, _, astacksize, _, _, _, _, _, abuyout, _, _, _ = GetAuctionItemInfo (list, i);

	if (aname and aname == name and abuyout == buyout and astacksize == stacksize) then
		return true;
	end
	
	return false;

end

-----------------------------------------

function Atr_CancelAuction(x)

	CancelAuction(x);

end

-----------------------------------------

function Atr_Clear_Owner_Item_Indices()

	gAtr_Owner_Item_Indices = {};

end


	

-----------------------------------------

function Atr_LogCancelAuction(numCancelled, itemLink, stackSize)
	
	local SSstring = "";
	if (stackSize and stackSize > 1) then
		SSstring = "|cff00ddddx"..stackSize;
	end

	if (numCancelled > 1) then
		zc.msg_yellow (numCancelled..ZT(" auctions cancelled for ")..itemLink..SSstring);
	elseif (numCancelled == 1) then
		zc.msg_yellow (ZT("Auction cancelled for ")..itemLink..SSstring);
	end
	
end

-----------------------------------------

function Atr_CancelSelection_OnClick()

	if (not Atr_ShowingCurrentAuctions()) then
		return;
	end
	
	Atr_CancelAuction_ByIndex (gCurrentPane.currIndex);
end

-----------------------------------------

function Atr_CancelAuction_ByIndex(index)

	local data = gCurrentPane.activeScan.sortedData[index];

	if (not data.yours) then
		return;
	end

	local numCancelled	= 0;
	local itemLink		= gCurrentPane.activeScan.itemLink;
	local itemName		= gCurrentPane.activeScan.itemName;
	
	-- build a list of indices if we don't currently have one

	if (#gAtr_Owner_Item_Indices == 0) then

		local numInList = GetNumAuctionItems ("owner");
		local i;
		local x = 1;
		
		for i = 1,numInList do

			if (Atr_DoesAuctionMatch ("owner", i, itemName, data.buyoutPrice, data.stackSize)) then
				gAtr_Owner_Item_Indices[x] = i;
				x = x + 1;
			end
		end
	end
	
	-- cancel the last item in the list and remove it

	local numInMatchList = #gAtr_Owner_Item_Indices;

	for x = numInMatchList,1,-1 do
	
		i = gAtr_Owner_Item_Indices[x];
		
		table.remove (gAtr_Owner_Item_Indices);
		
		if (Atr_DoesAuctionMatch ("owner", i, itemName, data.buyoutPrice, data.stackSize)) then
			Atr_CancelAuction (i);
			numCancelled = numCancelled + 1;
			AuctionatorSubtractFromScan (itemName, data.stackSize, data.buyoutPrice);
			gJustPosted_ItemName = nil;
			Atr_LogCancelAuction (numCancelled, itemLink, data.stackSize);
			break;
		end
	end
end

-----------------------------------------

function Atr_StackingPrefs_Init ()

	AUCTIONATOR_STACKING_PREFS = {};                
end

-----------------------------------------

function Atr_Has_StackingPrefs (key)

	local lkey = key:lower();

	return (AUCTIONATOR_STACKING_PREFS[lkey] ~= nil);            
end

-----------------------------------------

function Atr_Clear_StackingPrefs (key)

	local lkey = key:lower();

	AUCTIONATOR_STACKING_PREFS[lkey] = nil;            
end

-----------------------------------------

function Atr_Get_StackingPrefs (key)

	local lkey = key:lower();

	if (Atr_Has_StackingPrefs(lkey)) then
		return AUCTIONATOR_STACKING_PREFS[lkey].numstacks, AUCTIONATOR_STACKING_PREFS[lkey].stacksize;            
	end

	return nil, nil;

end

-----------------------------------------

function Atr_Set_StackingPrefs_numstacks (key, numstacks)

	local lkey = key:lower();

	if (not Atr_Has_StackingPrefs(lkey)) then
		AUCTIONATOR_STACKING_PREFS[lkey] = { stacksize = 0 };
	end

	AUCTIONATOR_STACKING_PREFS[lkey].numstacks = zc.Val (numstacks, 1);            
end

-----------------------------------------

function Atr_Set_StackingPrefs_stacksize (key, stacksize)

	local lkey = key:lower();

	if (not Atr_Has_StackingPrefs(lkey)) then
		AUCTIONATOR_STACKING_PREFS[lkey] = { numstacks = 0};
	end

	AUCTIONATOR_STACKING_PREFS[lkey].stacksize = zc.Val (stacksize, 1);            
end

-----------------------------------------

function Atr_GetStackingPrefs_ByItem (itemLink)

	if (itemLink) then
	
		local itemName = GetItemInfo (itemLink);
		local text, spinfo;
		
		for text, spinfo in pairs (AUCTIONATOR_STACKING_PREFS) do

			if (zc.StringContains (itemName, text)) then
				return spinfo.numstacks, spinfo.stacksize;
			end
		end
		
		if		(Atr_IsGlyph (itemLink))								then		return Atr_Special_SP (ATR_SK_GLYPHS, 0, 1);
		elseif	(Atr_IsCutGem (itemLink))								then		return Atr_Special_SP (ATR_SK_GEMS_CUT, 0, 1);
		elseif	(Atr_IsGem (itemLink))									then		return Atr_Special_SP (ATR_SK_GEMS_UNCUT, 1, 0);
		elseif	(Atr_IsItemEnhancement (itemLink))						then		return Atr_Special_SP (ATR_SK_ITEM_ENH, 0, 1);
		elseif	(Atr_IsPotion (itemLink) or Atr_IsElixir (itemLink))	then		return Atr_Special_SP (ATR_SK_POT_ELIX, 1, 0);
		elseif	(Atr_IsFlask (itemLink))								then		return Atr_Special_SP (ATR_SK_FLASKS, 1, 0);
		elseif	(Atr_IsHerb (itemLink))									then		return Atr_Special_SP (ATR_SK_HERBS, 1, 0);
		end
	end
	
	return nil, nil;
end

-----------------------------------------

function Atr_Special_SP (key, numstack, stacksize)

	if (Atr_Has_StackingPrefs (key)) then
		return Atr_Get_StackingPrefs(key);
	end
	
	return numstack, stacksize;
end

-----------------------------------------

function Atr_GetSellStacking (itemLink, numDragged, numTotal)

	local prefNumStacks, prefStackSize = Atr_GetStackingPrefs_ByItem (itemLink);
	
	if (prefNumStacks == nil) then
		return 1, numDragged;
	end
	
	if (prefNumStacks <= 0 and prefStackSize <= 0) then		-- shouldn't happen but just in case
		prefStackSize = 1;
	end

--zc.msg (prefNumStacks, prefStackSize);

	local numStacks = prefNumStacks;
	local stackSize = prefStackSize;
	local numToSell = numDragged;
	
	if (numStacks == -1) then		-- max number of stacks
		numToSell = numTotal;

	elseif (stackSize == 0) then		-- auto stacksize
		stackSize = math.floor (numDragged / numStacks);
	
	elseif (numStacks > 0) then
		numToSell = math.min (numStacks * stackSize, numTotal);
	end

	numStacks = math.floor (numToSell / stackSize);

--zc.msg_pink (numStacks, stackSize);
	
	if (numStacks == 0) then
		numStacks = 1;
		stackSize = numToSell;
--zc.msg_red (numStacks, stackSize);
	end
	
	return numStacks, stackSize;

end



-----------------------------------------

local gInitial_NumStacks;
local gInitial_StackSize;

-----------------------------------------

function Atr_SetInitialStacking (numStacks, stackSize)

	gInitial_NumStacks = numStacks;
	gInitial_StackSize = stackSize;

	Atr_Batch_NumAuctions:SetText (numStacks);
	Atr_SetStackSize (stackSize);
end

-----------------------------------------

function Atr_Memorize_Stacking_If ()

	local newNumStacks = Atr_Batch_NumAuctions:GetNumber();
	local newStackSize = Atr_StackSize();
	
	local numStacksChanged = (tonumber (gInitial_NumStacks) ~= newNumStacks);
	local stackSizeChanged = (tonumber (gInitial_StackSize) ~= newStackSize);

	if (stackSizeChanged) then
	
		local itemName = string.lower(gCurrentPane.activeScan.itemName);

		if (itemName) then

			-- see if user is trying to set it back to default
			
			if (newNumStacks == 1) then
				local _, _, auctionCount = GetAuctionSellItemInfo();
				if (auctionCount == newStackSize) then
					Atr_Clear_StackingPrefs (itemName);
					return;
				end
			end
			
			-- else remember the new stack size
			
			Atr_Set_StackingPrefs_stacksize (itemName, Atr_StackSize());
		end
	end
end




-----------------------------------------

function Atr_Duration_OnLoad(self)
	UIDropDownMenu_Initialize (self, Atr_Duration_Initialize);
	UIDropDownMenu_SetSelectedValue (Atr_Duration, 1);
end

-----------------------------------------

function Atr_Duration_OnShow(self)
	UIDropDownMenu_Initialize (self, Atr_Duration_Initialize);
end

-----------------------------------------

function Atr_Duration_Initialize()

	local info = UIDropDownMenu_CreateInfo();

	info.text = AUCTION_DURATION_ONE;
	info.value = 1;
	info.checked = nil;
	info.func = Atr_Duration_OnClick;
	UIDropDownMenu_AddButton(info);

	info.text = AUCTION_DURATION_TWO;
	info.value = 2;
	info.checked = nil;
	info.func = Atr_Duration_OnClick;
	UIDropDownMenu_AddButton(info);

	info.text = AUCTION_DURATION_THREE;
	info.value = 3;
	info.checked = nil;
	info.func = Atr_Duration_OnClick;
	UIDropDownMenu_AddButton(info);

end

-----------------------------------------

function Atr_Duration_OnClick(self)

	UIDropDownMenu_SetSelectedValue(Atr_Duration, self.value);
	Atr_SetDepositText();
end

-----------------------------------------

function Atr_DropDown1_OnLoad (self)
	UIDropDownMenu_Initialize(self, Atr_DropDown1_Initialize);
	UIDropDownMenu_SetSelectedValue(Atr_DropDown1, MODE_LIST_ACTIVE);
	Atr_DropDown1:Show();
end

-----------------------------------------

function Atr_DropDown1_Initialize(self)
	local info = UIDropDownMenu_CreateInfo();
	
	info.text = ZT("Active Items");
	info.value = MODE_LIST_ACTIVE;
	info.func = Atr_DropDown1_OnClick;
	info.owner = self;
	info.checked = nil;
	UIDropDownMenu_AddButton(info);

	info.text = ZT("All Items");
	info.value = MODE_LIST_ALL;
	info.func = Atr_DropDown1_OnClick;
	info.owner = self;
	info.checked = nil;
	UIDropDownMenu_AddButton(info);

end

-----------------------------------------

function Atr_DropDown1_OnClick(self)
	
	UIDropDownMenu_SetSelectedValue(self.owner, self.value);
	
	local mode = self.value;
	
	if (mode == MODE_LIST_ALL) then
		Atr_DisplayHlist();
	end
	
	if (mode == MODE_LIST_ACTIVE) then
		Atr_DisplayHlist();
	end
	
end



-----------------------------------------

function Atr_AddMenuPick (self, info, text, value, func)

	info.text			= text;
	info.value			= value;
	info.func			= func;
	info.checked		= nil;
	info.owner			= self;
	
	UIDropDownMenu_AddButton(info);

end

-----------------------------------------

function Atr_Dropdown_AddPick (frame, text, value, func)

	local info = UIDropDownMenu_CreateInfo();

	info.owner			= frame;
	info.text			= text;
	info.value			= value;
	info.checked		= nil;

	if (func) then
		info.func = func;
	else
		info.func = Atr_Dropdown_OnClick;
	end
	
	UIDropDownMenu_AddButton(info);
end

-----------------------------------------

function Atr_Dropdown_OnClick (info)

	UIDropDownMenu_SetSelectedValue (info.owner, info.value);

end

-----------------------------------------

function Atr_IsTabSelected(whichTab)

	if (not AuctionFrame or not AuctionFrame:IsShown()) then
		return false;
	end

	if (not whichTab) then
		return (Atr_IsTabSelected(SELL_TAB) or Atr_IsTabSelected(MORE_TAB) or Atr_IsTabSelected(BUY_TAB));
	end

	return (PanelTemplates_GetSelectedTab (AuctionFrame) == Atr_FindTabIndex(whichTab));
end

-----------------------------------------

function Atr_IsAuctionatorTab (tabIndex)

	if (tabIndex == Atr_FindTabIndex(SELL_TAB) or tabIndex == Atr_FindTabIndex(MORE_TAB) or tabIndex == Atr_FindTabIndex(BUY_TAB) ) then

		return true;

	end

	return false;
end

-----------------------------------------

function Atr_Confirm_Yes()

	if (Atr_Confirm_Proc_Yes) then
		Atr_Confirm_Proc_Yes();
		Atr_Confirm_Proc_Yes = nil;
	end

	Atr_Confirm_Frame:Hide();

end


-----------------------------------------

function Atr_Confirm_No()

	Atr_Confirm_Frame:Hide();

end


-----------------------------------------

function Atr_AddHistoricalPrice (itemName, price, stacksize, itemLink, testwhen)

	if (not AUCTIONATOR_PRICING_HISTORY[itemName] ) then
		AUCTIONATOR_PRICING_HISTORY[itemName] = {};
	end

	local itemId, suffixId, uniqueId = zc.ItemIDfromLink (itemLink);

	local is = itemId;

	if (suffixId ~= 0) then
		is = is..":"..suffixId;
		if (tonumber(suffixId) < 0) then
			is = is..":"..uniqueId;
		end
	end

	AUCTIONATOR_PRICING_HISTORY[itemName]["is"]  = is;

	local hist = tostring (zc.round (price))..":"..stacksize;

	local roundtime = floor (time() / 60) * 60;		-- so multiple auctions close together don't generate too many entries

	local tag = tostring(ToTightTime(roundtime));

	if (testwhen) then
		tag = tostring(ToTightTime(testwhen));
	end

	AUCTIONATOR_PRICING_HISTORY[itemName][tag] = hist;

	gCurrentPane.sortedHist = nil;

end

-----------------------------------------

function Atr_HasHistoricalData (itemName)

	if (AUCTIONATOR_PRICING_HISTORY[itemName] ) then
		return true;
	end

	return false;
end


-----------------------------------------

function Atr_BuildGlobalHistoryList(full)

	gHistoryItemList	= {};
	
	local n = 1;

	if (full) then
		for name,hist in pairs (AUCTIONATOR_PRICING_HISTORY) do
			gHistoryItemList[n] = name;
			n = n + 1;
		end
	else
		if (zc.tableIsEmpty (gActiveAuctions)) then
			Atr_BuildActiveAuctions();
		end

		local name;
		for name, count in pairs (gActiveAuctions) do
			if (name and count ~= 0) then
				gHistoryItemList[n] = name;
				n = n + 1;
			end
		end
	end
	
	table.sort (gHistoryItemList);
end



-----------------------------------------

function Atr_FindHListIndexByName (itemName)

	local x;
	
	for x = 1, #gHistoryItemList do
		if (itemName == gHistoryItemList[x]) then
			return x;
		end
	end

	return 0;
	
end

-----------------------------------------

local gAtr_CheckingActive_State			= ATR_CACT_NULL;
local gAtr_CheckingActive_Index;
local gAtr_CheckingActive_NextItemName;
local gAtr_CheckingActive_AndCancel		= false;

gAtr_CheckingActive_NumUndercuts	= 0;


-----------------------------------------

function Atr_CheckActive_OnClick (andCancel)

	if (gAtr_CheckingActive_State == ATR_CACT_NULL) then
	
		Atr_CheckActiveList (andCancel);

	else		-- stop checking
		Atr_CheckingActive_Finish ();
		gCurrentPane.activeSearch:Abort();
		gCurrentPane:ClearSearch();
		Atr_SetMessage(ZT("Checking stopped"));
	end
	
end


-----------------------------------------

function Atr_CheckActiveList (andCancel)

	gAtr_CheckingActive_State			= ATR_CACT_READY;
	gAtr_CheckingActive_NextItemName	= gHistoryItemList[1];
	gAtr_CheckingActive_AndCancel		= andCancel;
	gAtr_CheckingActive_NumUndercuts	= 0;
	
	gCurrentPane:SetToShowCurrent();

	Atr_CheckingActiveIdle ();
	
end

-----------------------------------------

function Atr_CheckingActive_Finish()

	gAtr_CheckingActive_State = ATR_CACT_NULL;		-- done
	
	Atr_CheckActiveButton:SetText(ZT("Check for Undercuts"));

end



-----------------------------------------

function Atr_CheckingActiveIdle()

	if (gAtr_CheckingActive_State == ATR_CACT_READY) then
	
		if (gAtr_CheckingActive_NextItemName == nil) then
		
			Atr_CheckingActive_Finish ();

			if (gAtr_CheckingActive_NumUndercuts > 0) then
				Atr_ResetMassCancel();
				Atr_CheckActives_Frame:Show();
			end
			
		else
			gAtr_CheckingActive_State = ATR_CACT_PROCESSING;

			Atr_CheckActiveButton:SetText(ZT("Stop Checking"));

			local itemName = gAtr_CheckingActive_NextItemName;

			local x = Atr_FindHListIndexByName (itemName);
			gAtr_CheckingActive_NextItemName = (x > 0 and #gHistoryItemList >= x+1) and gHistoryItemList[x+1] or nil;

--			local cacheHit = gCurrentPane:DoSearch (itemName, true, 15);
			gCurrentPane:DoSearch (itemName, true);
			
			Atr_Hilight_Hentry (itemName);
			
--			if (cacheHit) then
--				Atr_CheckingActive_OnSearchComplete();
--			end
		end
	end
end


-----------------------------------------

function Atr_CheckActive_IsBusy()

	return (gAtr_CheckingActive_State ~= ATR_CACT_NULL);
	
end

-----------------------------------------

function Atr_CheckingActive_OnSearchComplete()

	if (gAtr_CheckingActive_State == ATR_CACT_PROCESSING) then
		
		if (gAtr_CheckingActive_AndCancel) then
			zc.AddDeferredCall (0.1, "Atr_CheckingActive_CheckCancel");		-- need to defer so UI can update and show auctions about to be canceled
		else
			zc.AddDeferredCall (0.1, "Atr_CheckingActive_Next");			-- need to defer so UI can update
		end
	end
end

-----------------------------------------

function Atr_CheckingActive_CheckCancel()

	if (gAtr_CheckingActive_State == ATR_CACT_PROCESSING) then

		Atr_CancelUndercuts_CurrentScan(false);

		if (gAtr_CheckingActive_State ~= ATR_CACT_WAITING_ON_CANCEL_CONFIRM) then
			zc.AddDeferredCall (0.1, "Atr_CheckingActive_Next");		-- need to defer so UI can update
		end
	end
	
end

-----------------------------------------

function Atr_CheckingActive_Next ()

	if (gAtr_CheckingActive_State == ATR_CACT_PROCESSING) then
		gAtr_CheckingActive_State = ATR_CACT_READY;
	end
end


-----------------------------------------

function Atr_CancelUndercut_Confirm (yesCancel)
	gAtr_CheckingActive_State = ATR_CACT_PROCESSING;
	Atr_CancelAuction_Confirm_Frame:Hide();
	if (yesCancel) then
		Atr_CancelUndercuts_CurrentScan(true);
	end
	zc.AddDeferredCall (0.1, "Atr_CheckingActive_Next");
end

-----------------------------------------

function Atr_CancelUndercuts_CurrentScan(confirmed)

	local scan = gCurrentPane.activeScan;

	for x = #scan.sortedData,1,-1 do
	
		local data = scan.sortedData[x];
		
		if (data.yours and data.itemPrice > scan.absoluteBest.itemPrice) then
			
			if (not confirmed) then
				gAtr_CheckingActive_State = ATR_CACT_WAITING_ON_CANCEL_CONFIRM;
				Atr_CancelAuction_Confirm_Frame_text:SetText (string.format (ZT("Your auction has been undercut:\n%s%s"), "|cffffffff", scan.itemName));
				Atr_CancelAuction_Confirm_Frame:Show ();
				return;
			end
			
			Atr_CancelAuction_ByIndex (x);
		end
	end

end

-----------------------------------------

local gAtr_MassCancelList = {};

-----------------------------------------

function Atr_ResetMassCancel ()

	gAtr_MassCancelList = {};
	
	local i;
	local num = GetNumAuctionItems ("owner");
	local x = 1;
	
	-- build the list of items to cancel
	
	for i = 1, num do
		local name, _, stackSize, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo ("owner", i);

		if (name) then
			local scan = Atr_FindScan (name);
			if (scan and scan.absoluteBest and scan.whenScanned ~= 0 and scan.yourBestPrice and scan.yourWorstPrice) then
				
				local absBestPrice = scan.absoluteBest.itemPrice;
				
				if (stackSize > 0) then
					local itemPrice = math.floor (buyoutPrice / stackSize);
		
					zc.md (i, name, "itemPrice: ", itemPrice, "absBestPrice: ", absBestPrice);

					if (itemPrice > absBestPrice) then

						gAtr_MassCancelList[x] = {};
						gAtr_MassCancelList[x].index		= i;
						gAtr_MassCancelList[x].name			= name;
						gAtr_MassCancelList[x].buyout		= buyoutPrice;
						gAtr_MassCancelList[x].stackSize	= stackSize;
						gAtr_MassCancelList[x].itemPrice	= itemPrice;
						gAtr_MassCancelList[x].absBestPrice	= absBestPrice;
						x = x + 1;
						
					end
				end
			end
		end
	end

	Atr_CheckActives_Text:SetText (string.format (ZT("%d of your auctions are not the lowest priced.\n\nWould you like to cancel them?"), #gAtr_MassCancelList));

	Atr_CheckActives_Yes_Button:Enable();
	Atr_CheckActives_Yes_Button:SetText (ZT("Start canceling"));
	Atr_CheckActives_No_Button:SetText (ZT("No, leave them"));
end

-----------------------------------------

function Atr_Cancel_Undercuts_OnClick ()

	if (#gAtr_MassCancelList == 0) then
		return;
	end
	
	Atr_Cancel_One_Undercuts_OnClick ()

	Atr_CheckActives_Text:SetText (string.format (ZT("%d of your auctions are not the lowest priced.\n\nWould you like to cancel them?"), #gAtr_MassCancelList));

	if (#gAtr_MassCancelList == 0) then
		Atr_CheckActives_Yes_Button:Disable();
		PlaySound ("AuctionWindowClose");
	else
		Atr_CheckActives_Yes_Button:Enable();
	end
	
	Atr_CheckActives_Yes_Button:SetText (ZT("Keep going"));
	Atr_CheckActives_No_Button:SetText (ZT("Done"));
	
end
	
-----------------------------------------

function Atr_Cancel_One_Undercuts_OnClick ()

	local x = #gAtr_MassCancelList;
	
	local i				= gAtr_MassCancelList[x].index;
	local name			= gAtr_MassCancelList[x].name;
	local buyout		= gAtr_MassCancelList[x].buyout;
	local stackSize		= gAtr_MassCancelList[x].stackSize;
	local itemPrice		= gAtr_MassCancelList[x].itemPrice;
	local absBestPrice	= gAtr_MassCancelList[x].absBestPrice;
	
	table.remove ( gAtr_MassCancelList);
	
	Atr_CancelAuction (i);
				
--	if (scan.yourBestPrice > absBestPrice) then
--		gActiveAuctions[name] = nil;
--	end

	zc.md (" index:", i, "  ", name, " price:", itemPrice, "  best price:", absBestPrice);

	AuctionatorSubtractFromScan (name, stackSize, buyout);
	Atr_LogCancelAuction (1, Atr_GetItemLink(name), stackSize);
	gJustPosted_ItemName = nil;

	Atr_DisplayHlist();

end

-----------------------------------------

function Atr_Hilight_Hentry(itemName)

	for line = 1,ITEM_HIST_NUM_LINES do

		dataOffset = line + (FauxScrollFrame_GetOffset(Atr_Hlist_ScrollFrame) or 0);

		local lineEntry = _G["AuctionatorHEntry"..line];

		if (dataOffset <= #gHistoryItemList and gHistoryItemList[dataOffset]) then

			if (gHistoryItemList[dataOffset] == itemName) then
				lineEntry:SetButtonState ("PUSHED", true);
			else
				lineEntry:SetButtonState ("NORMAL", false);
			end
		end
	end
end

-----------------------------------------

function Atr_Item_Autocomplete(self)

	local text = self:GetText();
	local textlen = strlen(text);
	local name;

	-- first search shopping lists

	local numLists = #AUCTIONATOR_SHOPPING_LISTS;
	local n;
	
	for n = 1,numLists do
		local slist = AUCTIONATOR_SHOPPING_LISTS[n];

		local numItems = #slist.items;

		if ( numItems > 0 ) then
			for i=1, numItems do
				name = slist.items[i];
				if ( name and text and (strfind(strupper(name), strupper(text), 1, 1) == 1) ) then
					self:SetText(name);
					if ( self:IsInIMECompositionMode() ) then
						self:HighlightText(textlen - strlen(arg1), -1);
					else
						self:HighlightText(textlen, -1);
					end
					return;
				end
			end
		end
	end
	

	-- next search history list

	numItems = #gHistoryItemList;

	if ( numItems > 0 ) then
		for i=1, numItems do
			name = gHistoryItemList[i];
			if ( name and text and (strfind(strupper(name), strupper(text), 1, 1) == 1) ) then
				self:SetText(name);
				if ( self:IsInIMECompositionMode() ) then
					self:HighlightText(textlen - strlen(arg1), -1);
				else
					self:HighlightText(textlen, -1);
				end
				return;
			end
		end
	end
end

-----------------------------------------

function Atr_GetCurrentPane ()			-- so other modules can use gCurrentPane
	return gCurrentPane;
end

-----------------------------------------

function Atr_SetUINeedsUpdate ()			-- so other modules can easily set
	gCurrentPane.UINeedsUpdate = true;
end


-----------------------------------------

function Atr_CalcUndercutPrice (price)

	if	(price > 5000000)	then return roundPriceDown (price, AUCTIONATOR_SAVEDVARS._5000000);	end;
	if	(price > 1000000)	then return roundPriceDown (price, AUCTIONATOR_SAVEDVARS._1000000);	end;
	if	(price >  200000)	then return roundPriceDown (price, AUCTIONATOR_SAVEDVARS._200000);	end;
	if	(price >   50000)	then return roundPriceDown (price, AUCTIONATOR_SAVEDVARS._50000);	end;
	if	(price >   10000)	then return roundPriceDown (price, AUCTIONATOR_SAVEDVARS._10000);	end;
	if	(price >    2000)	then return roundPriceDown (price, AUCTIONATOR_SAVEDVARS._2000);	end;
	if	(price >     500)	then return roundPriceDown (price, AUCTIONATOR_SAVEDVARS._500);		end;
	if	(price >       0)	then return math.floor (price - 1);	end;

	return 0;
end

-----------------------------------------

function Atr_CalcStartPrice (buyoutPrice)

	local discount = 1.00 - (AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT / 100);

	local newStartPrice = Atr_CalcUndercutPrice(math.floor(buyoutPrice * discount));
	
	if (AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT == 0) then		-- zero means zero
		newStartPrice = buyoutPrice;
	end
	
	return newStartPrice;

end

-----------------------------------------

function Atr_AbbrevItemName (itemName)

	return string.gsub (itemName, "Scroll of Enchant", "SoE");

end

-----------------------------------------

function Atr_IsMyToon (name)

	if (name and (AUCTIONATOR_TOONS[name] or AUCTIONATOR_TOONS[string.lower(name)])) then
		return true;
	end
	
	return false;
end

-----------------------------------------

function Atr_Error_Display (errmsg)
	if (errmsg) then
		Atr_Error_Text:SetText (errmsg);
		Atr_Error_Frame:Show ();
		return;
	end
end

-----------------------------------------

function Atr_PollWho(s)

	gSendZoneMsgs = true;
	gQuietWho = time();

	SetWhoToUI(1);
	
	zc.md (s);
	
	SendWho (s);
end

-----------------------------------------

function Atr_FriendsFrame_OnEvent(self, event, ...)

	if (event == "WHO_LIST_UPDATE" and gQuietWho > 0 and time() - gQuietWho < 10) then
		return;
	end

	if (gQuietWho > 0) then
		SetWhoToUI(0);
	end
	
	gQuietWho = 0;
	
	return auctionator_orig_FriendsFrame_OnEvent (self, event, ...);

end



-----------------------------------------
-- roundPriceDown - rounds a price down to the next lowest multiple of a.
--				  - if the result is not at least a/2 lower, rounds down by a/2.
--
--	examples:  	(128790, 500)  ->  128500
--				(128700, 500)  ->  128000
--				(128400, 500)  ->  128000
-----------------------------------------

function roundPriceDown (price, a)

	if (a == 0) then
		return price;
	end

	local newprice = math.floor((price-1) / a) * a;

	if ((price - newprice) < a/2) then
		newprice = newprice - (a/2);
	end

	if (newprice == price) then
		newprice = newprice - 1;
	end

	return newprice;

end

-----------------------------------------

function ToTightHour(t)

	return floor((t - gTimeTightZero)/3600);

end

-----------------------------------------

function FromTightHour(tt)

	return (tt*3600) + gTimeTightZero;

end


-----------------------------------------

function ToTightTime(t)

	return floor((t - gTimeTightZero)/60);

end

-----------------------------------------

function FromTightTime(tt)

	return (tt*60) + gTimeTightZero;

end


--[[

- right click item in bag
- reset to 12 hours when switching tabs
- off by one when cancelling multisell
- cosmetic issue with the background
- collapsed multiple cancel messages

]]--




