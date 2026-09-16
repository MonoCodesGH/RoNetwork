--!strict
--!native
--!optimize 2

--// The main intention of this is to easily scale connections, and to easily manage them on the server/client side
local Network: Network = {} :: Network;

-- Services
local RunService = game:GetService("RunService");
local ReplicatedStorage = game:GetService("ReplicatedStorage");
local HttpService = game:GetService("HttpService");

-- Libraries
local defer, wait = task.defer, task.wait;
local close = coroutine.close;
local pack, clear, insert = table.pack, table.clear, table.insert;
local Decode, Encode = HttpService.JSONDecode, HttpService.JSONEncode;
local bToString, bFromString = buffer.tostring, buffer.fromstring;
local Heartbeat = RunService.Heartbeat;

-- Constants
local IS_SERVER: boolean, IS_CLIENT: boolean, IS_STUDIO: boolean = RunService:IsServer(), RunService:IsClient(), RunService:IsStudio();
local DISPLAY_NAME: string = script:GetFullName();

-- The maximum timeout before a RemoteFunction is deemed unresponsive.
local RF_TIMEOUT: number = 15;

-- Classes
local Compression = require(script.lib.Compression);
local Validation = require(script.lib.Validation);
local Ratelimit = require(script.packages.Ratelimit);

-- Registry for more utilized connections.
local CONNECTION_REGISTRY: { [string]: number } = require(script.ConnectionRegistry) :: { [string]: number };

local ID_TO_CONNECTION: { [number]: string } = {};
for name: string, id: number in (CONNECTION_REGISTRY) do
	ID_TO_CONNECTION[id] = name;
end;

-- Variables
local RE: RemoteEvent?;
local RF: RemoteFunction?;
local URE: UnreliableRemoteEvent?;
local BE: BindableEvent?;
local BF: BindableFunction?;

local Connections: { [string]: Connection } = {};
local Signals: { [string]: RBXScriptConnection? } = {};

local function __displayWarn(message: string): ()
	assert(type(message) == "string", "bad message");

	if (not IS_STUDIO) then
		return;
	end;

	warn(`[{DISPLAY_NAME}]: {message}`);
end;

local function __encodeConnectionName(name: string): number | string
	local ID: number | string = CONNECTION_REGISTRY[name];
	if (ID) then
		return ID;
	end;
	
	return name;
end;

local function __decodeConnectionName(identifier: number | string): string?
	if (typeof(identifier) == "number") then
		local name: string = ID_TO_CONNECTION[identifier];
		if (name) then
			return name;
		end;
		
		__displayWarn(`[{script}/__decodeConnectionName]: Could not decode connection ID: {identifier}`);
		return nil;
	elseif (typeof(identifier) == "string") then
		return identifier;
	end;
	
	__displayWarn(`[{script}/__decodeConnectionName]: Invalid identifier type: {typeof(identifier)}`);
	return nil;
end;

local function __yieldUntilRFResponse(connectionName: string, callMethod: () -> any?): nil | any?
	local success: boolean, response: any = pcall(callMethod);
	if (success) then
		return response;
	else
		__displayWarn(`[{script}/__yieldUntilRFResponse]: Internal Server Error: {connectionName} :: {response}`);
		return nil;
	end;
end

local function onConnection(player: Player?, Type: RemoteConnection, connectionIdentifier: number | string, compressedArgs: buffer): any
	local connectionName: string? = __decodeConnectionName(connectionIdentifier)

	if (not connectionName) then
		__displayWarn(`[{script}/onConnection]: Failed to decode connection identifier: {connectionIdentifier}`)
		return;
	end;
	
	local connection: Connection? = Connections[connectionName];
	if (connection ~= nil) then
		if not (connection.Type == Type) then 
			return;
		end;
		
		if (IS_SERVER and player and connection.RateLimiter) then
			local consume: number = connection.RateLimitConfig and connection.RateLimitConfig.consume or 1;
			local result: Ratelimit.RateLimiterResult = connection.RateLimiter:Check(player, { consume = consume });

			if (result == "BAD") then
				__displayWarn(`[{connectionName}]: Rate limit exceeded for {player.Name}`);
				return;
			end;
		end;
		
		local arguments: any = Compression.Decompress(compressedArgs);
		if (connection.Schema and IS_SERVER and player) then
			local isValid: boolean, errorMessage: string? = Validation.ValidateArguments(
				connectionName,
				player.Name,
				arguments,
				connection.Schema
			);

			if (not isValid) then
				__displayWarn(errorMessage or "Validation failed");
				return;
			end;
		end;
		
		if (player) then
			return Connections[connectionName].Callback(player, unpack(arguments));
		else
			return Connections[connectionName].Callback(unpack(arguments))
		end
	end

	__displayWarn(`[{script}/onConnection]: Failed to find a callback method for: {connectionName}`);

	return;
end

local function getRE(): RemoteEvent
	local newRE: RemoteEvent?;
	if (IS_SERVER) then
		newRE = RE or Instance.new("RemoteEvent", script)
	else
		newRE = RE or script:WaitForChild("RemoteEvent", 15) :: RemoteEvent?;
	end
	return newRE :: RemoteEvent;
end

local function getRF(): RemoteFunction
	local newRF: RemoteFunction?;
	if (IS_SERVER) then
		newRF = RF or Instance.new("RemoteFunction", script)
	else
		newRF = RF or script:WaitForChild("RemoteFunction", 15) :: RemoteFunction?;
	end
	return newRF :: RemoteFunction;
end

local function getURE(): UnreliableRemoteEvent
	local newURE: UnreliableRemoteEvent?;
	if (IS_SERVER) then
		newURE = URE or Instance.new("UnreliableRemoteEvent", script)
	else
		newURE = URE or script:WaitForChild("UnreliableRemoteEvent", 15) :: UnreliableRemoteEvent?;
	end
	return newURE :: UnreliableRemoteEvent;
end

local function getBE(): BindableEvent
	local newBE: BindableEvent?;
	if (IS_SERVER) then
		newBE = BE or Instance.new("BindableEvent", script)
	else
		newBE = BE or script:WaitForChild("Event", 15) :: BindableEvent?;
	end
	return newBE :: BindableEvent;
end

local function getBF(): BindableFunction
	local newBF: BindableFunction?;
	if (IS_SERVER) then
		newBF = BF or Instance.new("BindableFunction", script)
	else
		newBF = BF or script:WaitForChild("Function", 15) :: BindableFunction?;
	end
	return newBF :: BindableFunction;
end

--[[
	Creates a new Network
]]

RE, RF, URE, BE, BF = 
	getRE() :: RemoteEvent, 
	getRF() :: RemoteFunction, 
	getURE() :: UnreliableRemoteEvent, 
	getBE() :: BindableEvent,
	getBF() :: BindableFunction;

-- Whether this is a server or client that is accessing the Network.
if (IS_SERVER) then
	Signals = {
		RemoteEvent = RE and RE.OnServerEvent:Connect(function(player, ...) onConnection(player, "REMOTE_EVENT", ...) end);
		UnreliableRemoteEvent = URE and URE.OnServerEvent:Connect(function(player, ...) onConnection(player, "UREMOTE_EVENT", ...) end);
		BindableEvent = BE and BE.Event:Connect(function(...) onConnection(nil, "BINDABLE_EVENT", ...) end);
	}
else
	Signals = {
		RemoteEvent = RE and RE.OnClientEvent:Connect(function(...) onConnection(nil, "REMOTE_EVENT", ...) end);
		UnreliableRemoteEvent = URE and URE.OnClientEvent:Connect(function(...) onConnection(nil, "UREMOTE_EVENT", ...) end);
		BindableEvent = BE and BE.Event:Connect(function(...) onConnection(nil, "BINDABLE_EVENT", ...) end);
	}
end

if (RF) then
	if (IS_SERVER) then
		RF.OnServerInvoke = function(player, ...) return onConnection(player, "REMOTE_FUNCTION", ...) end;
	else
		RF.OnClientInvoke = function(...) return onConnection(nil, "REMOTE_FUNCTION", ...) end;
	end
end

if (BF) then
	BF.OnInvoke = function(...)
		return onConnection(nil, "BINDABLE_FUNCTION", ...);
	end;
end

--[[
	Sets a new Connection appended to be listened to
	
	@param ConnectionName: string The name of the Connection that will be listened to.
	@param ConnectionType: RemoteConnection The type of connection that this is going to be (remote has to exist to work).
	@param Callback: ( Player, any ) -> () The callback that will be initiated once the listener is triggered.
	@param Schema: TypeSchema? Optional validation schema for arguments
	@param RateLimitConfig: RateLimitConfig? Optional rate limiting configuration

	@return Connection | nil
]]
function Network:SetConnection<T...>(
	ConnectionName:  string, 
	ConnectionType:  RemoteConnection, 
	Callback:        ( player: Player, T...) -> any?,
	Schema:          Validation.TypeSchema?,
	RateLimitConfig: RateLimitConfig?
)
	assert(ConnectionName, `need ConnectionName, must be string`);
	assert(ConnectionType, `need ConnectionType, must be RemoteConnection`);
	assert(Callback, `need ConnectionName, must be ( player: Player, ... any ) -> any?`);
	
	local rateLimiter: Ratelimit.RateLimiter? = nil;
	if (IS_SERVER and RateLimitConfig) then
		rateLimiter = Ratelimit.new("TOKEN", {
			maxTokens = RateLimitConfig.maxTokens or 10;
			fillRate = RateLimitConfig.fillRate or 2;
		});
	end;
	
	local NewConnection: Connection = {
		Name = ConnectionName;
		Type = ConnectionType;
		Callback = Callback;
		Schema = Schema;
		RateLimiter = rateLimiter;
		RateLimitConfig = RateLimitConfig;
	};

	Connections[ConnectionName] = NewConnection;
end

-- Creates a "Signal" which should only be used for simple communication between client and server
function Network:SetSignal(SignalName: string): { Wait: () -> any? }
	local signalFired: boolean = false
	local arguments: { any? } = {}

	Network:SetConnection(`Signal{SignalName}`, "REMOTE_EVENT", function(...: any) 
		signalFired = true;
		arguments = pack(...);
		Network:RemoveConnection(`Signal{SignalName}`, "REMOTE_EVENT");
		return;
	end);

	return {
		Wait = function()
			repeat
				Heartbeat:Wait();
			until signalFired;

			return arguments;
		end,
	}
end

function Network:FireSignal(SignalName: string, Player: Player?, ...)
	if (IS_CLIENT) then
		Network:FireServerConnection(`Signal{SignalName}`, "REMOTE_EVENT", ...)
	elseif (IS_SERVER and Player) then
		Network:FireClientConnection(Player, `Signal{SignalName}`, "REMOTE_EVENT", ...)
	end
end

--[[
	Fires the targetted name to the client

	@param plr: Player The player target to fire the connection towards.
	@param ConnectionName: string The name of the Connection that will be fired to.
	@param ...: any Any additional arguments to provide.
]]
function Network:FireClientConnection(plr: Player, ConnectionName: string, ConnectionType: RemoteConnection, ...: any): any?
	if (IS_CLIENT) then return end;
	if (not plr) or (not plr:IsA("Player")) then return end;

	local connectionIdentifier: number | string = __encodeConnectionName(ConnectionName);
	
	if (ConnectionType == "REMOTE_EVENT" and RE) then
		getRE():FireClient(plr, connectionIdentifier, Compression.Compress(pack(...)));
	elseif (ConnectionType == "UREMOTE_EVENT" and URE) then
		getURE():FireClient(plr, connectionIdentifier, Compression.Compress(pack(...)));
	elseif (ConnectionType == "REMOTE_FUNCTION" and RF) then
		local packedTable: { any? } = pack(...);
		return __yieldUntilRFResponse(ConnectionName, function()
			return getRF():InvokeClient(plr, connectionIdentifier, Compression.Compress(packedTable));
		end)
	end

	return;
end

function Network:FireAllClientConnection(ConnectionName: string, ConnectionType: RemoteConnection, ...: any): ()
	if (IS_CLIENT) or (ConnectionType == "REMOTE_FUNCTION") then return end;

	local connectionIdentifier: number | string = __encodeConnectionName(ConnectionName);

	if (ConnectionType == "REMOTE_EVENT") then
		getRE():FireAllClients(connectionIdentifier, Compression.Compress(pack(...)));
	elseif (ConnectionType == "UREMOTE_EVENT") then
		getURE():FireAllClients(connectionIdentifier, Compression.Compress(pack(...)));
	end
end

--[[
	Fires towards the server with the given paramaters.
	
	@param ConnectionName: string The connection that you are firing to
]]
function Network:FireServerConnection(ConnectionName: string, ConnectionType: RemoteConnection, ...: any): any?
	if IS_SERVER then return end

	local connectionIdentifier: number | string = __encodeConnectionName(ConnectionName);

	if (ConnectionType == "REMOTE_EVENT") then
		getRE():FireServer(connectionIdentifier, Compression.Compress(pack(...)));
	elseif (ConnectionType == "UREMOTE_EVENT") then
		getURE():FireServer(connectionIdentifier, Compression.Compress(pack(...)));
	elseif (ConnectionType == "REMOTE_FUNCTION") then
		local packedTable: { any? } = pack(...);
		return __yieldUntilRFResponse(ConnectionName, function()
			return getRF():InvokeServer(connectionIdentifier, Compression.Compress(packedTable));
		end)
	end

	return;
end

--[[
	Fires a signal to another part of a script of the same type that's firing to it (i.e: server-server & client-client communication)
	
	@param ConnectionName: string The connection that you are firing to
]]
function Network:FireConnection(ConnectionName: string, ConnectionType: RemoteConnection, ...: any): (any?)
	local connectionIdentifier: number | string = __encodeConnectionName(ConnectionName);
	local compressedArgs: buffer = Compression.Compress(pack(...)) :: buffer;
	
	if (ConnectionType == "BINDABLE_EVENT" and BE) then
		BE:Fire(connectionIdentifier, compressedArgs);
	
	elseif (ConnectionType == "BINDABLE_FUNCTION" and BF) then
		return getBF():Invoke(connectionIdentifier, compressedArgs);
	end
	
	return nil;
end

function Network:GetRemote(RemoteType: RemoteConnection): RemoteEvent? | RemoteFunction? | UnreliableRemoteEvent? | BindableEvent? | BindableFunction? | nil
	if (RemoteType == "REMOTE_EVENT") then
		return getRE();
	elseif (RemoteType == "UREMOTE_EVENT") then
		return getURE();
	elseif (RemoteType == "REMOTE_FUNCTION") then
		return getRF();
	elseif (RemoteType == "BINDABLE_EVENT") then
		return getBE();
	elseif (RemoteType == "BINDABLE_FUNCTION") then
		return getBF();
	end

	__displayWarn(`[{script}]: Could not locate the remote, maybe check the requested remote?`)
	return nil;
end

--[[
	Fires the targetted name to the client

	@param ConnectionName: string The name of the Connection that will be removed.
	@param ConnectionType: RemoteConnection Depending on what you are listening to, it might have a different connection type.

	@return Connection | nil
]]
function Network:RemoveConnection(ConnectionName: string, ConnectionType: RemoteConnection): Connection | nil
	local currentConnection: Connection = Connections[ConnectionName];

	if (currentConnection) then
		if not (currentConnection.Type == ConnectionType) then 
			return nil;
		end;
		
		if (currentConnection.RateLimiter) then
			currentConnection.RateLimiter:Destroy();
		end;
		
		Connections[ConnectionName] = nil;
		return currentConnection;
	end

	return nil;
end

export type TypeSchema = Validation.TypeSchema;
export type TypeConstraints = Validation.TypeConstraints;
export type SchemaEntry = Validation.SchemaEntry;

export type RateLimitConfig = {
	maxTokens: number?;
	fillRate: number?;
	consume: number?;
};

export type Connection = {
	Name: string;
	Type: RemoteConnection;
	Callback: ( player: Player, ... any ) -> any?;
	Schema: Validation.TypeSchema?;
	RateLimiter: any?;
	RateLimitConfig: RateLimitConfig?;
};

export type RemoteConnection = "REMOTE_EVENT" | "REMOTE_FUNCTION" | "UREMOTE_EVENT" | "BINDABLE_EVENT" | "BINDABLE_FUNCTION";

export type Network = {
	SetConnection: <T...>(
		self: Network, 
		ConnectionName: string, 
		ConnectionType: RemoteConnection, 
		Callback: (player: Player, T...) -> any? | nil, 
		Schema: Validation.TypeSchema?,
		RateLimitConfig: RateLimitConfig?
	) -> ();
	
	RemoveConnection: (self: Network, ConnectionName: string, ConnectionType: RemoteConnection) -> Connection | nil;
	FireConnection: (self: Network, ConnectionName: string, ConnectionType: RemoteConnection, ... any) -> ();

	SetSignal: (self: Network, SignalName: string) -> ({ Wait: () -> any? });
	FireSignal: (self: Network, SignalName: string, Player: Player?, ... any) -> ();

	FireClientConnection: (self: Network, plr: Player, ConnectionName: string, ConnectionType: RemoteConnection, ... any) -> any?;
	FireAllClientConnection: (self: Network, ConnectionName: string, ConnectionType: RemoteConnection, ... any) -> ();

	FireServerConnection: (self: Network, ConnectionName: string, ConnectionType: RemoteConnection, ... any) -> any?;

	GetRemote: (self: Network, RemoteType: RemoteConnection) -> RemoteEvent? | RemoteFunction? | UnreliableRemoteEvent? | BindableEvent? | BindableFunction? | nil;
}

return Network;
