-module(tpnode_consensus_router).
-behaviour(gen_server).
-include("include/tplog.hrl").

% API
-export([start_link/0]).
-export([notify_layer_change/2, submit_proposal/1, route_gossip_message/3, is_engine_primary/0]).
-export([submit_proposal_to_layer/2]).
-export([get_active_engine_details/0]). % For test utils

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    node_id :: binary() | undefined,
    current_layer :: atom() | undefined,
    active_engine_pid :: pid() | undefined,
    active_engine_module :: atom() | undefined % To know which engine API to call
}).

% API Implementations
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

notify_layer_change(NodeId, NewLayer) ->
    MyNodeId = nodekey:get_pub(),
    if NodeId == MyNodeId ->
        gen_server:cast(?SERVER, {notify_layer_change_internal, NewLayer});
       true ->
        ?LOG_INFO("Layer change notification for other node ~p to ~p. No action taken by self.", [NodeId, NewLayer])
    end,
    ok.

submit_proposal(Proposal) ->
    gen_server:call(?SERVER, {submit_proposal, Proposal}).

route_gossip_message(FromNode, LayerTag, Message) ->
    gen_server:cast(?SERVER, {route_gossip_message, FromNode, LayerTag, Message}).

is_engine_primary() ->
    gen_server:call(?SERVER, is_engine_primary).

submit_proposal_to_layer(TargetLayer, Proposal) when is_atom(TargetLayer), is_map(Proposal) ->
    % This is called directly, not via gen_server:call to this specific router instance.
    % It needs to interact with the router of the current node.
    % It can use ?SERVER to refer to the registered name of this gen_server.
    gen_server:call(?SERVER, {submit_proposal_to_layer, TargetLayer, Proposal}).

get_active_engine_details() -> % For test utils
    gen_server:call(?SERVER, get_active_engine_details).

% gen_server Callbacks
init([]) ->
    ?LOG_INFO("tpnode_consensus_router starting..."),
    MyNodeId = nodekey:get_pub(),
    InitialNodeMassData = tpnode_mass_manager:get_node_mass_data(MyNodeId),
    InitialLayer = case InitialNodeMassData of
        undefined -> local;
        #{<<"current_layer">> := Layer} -> Layer;
        _ -> local
    end,
    ?LOG_INFO("Self NodeId: ~p, Initial Layer: ~p", [MyNodeId, InitialLayer]),
    {EnginePid, EngineMod} = start_engine(InitialLayer, MyNodeId),
    {ok, #state{
        node_id = MyNodeId,
        current_layer = InitialLayer,
        active_engine_pid = EnginePid,
        active_engine_module = EngineMod
    }}.

handle_call({submit_proposal, Proposal}, _From, State = #state{current_layer = Layer, active_engine_pid = Pid, active_engine_module = Mod}) ->
    if Layer == local andalso is_pid(Pid) andalso Mod == local_consensus_engine ->
        % Delegate to the specific engine's API.
        % The engine itself will determine if it's primary.
        Reply = gen_server:call(Pid, {handle_proposal, Proposal}),
        {reply, Reply, State};
       is_pid(Pid) ->
        ?LOG_INFO("Forwarding submit_proposal to generic engine ~p for layer ~p", [Pid, Layer]),
        % Placeholder for other engines
        {reply, {ok, forwarded_to_generic_engine}, State};
       true ->
        ?LOG_WARNING("No active engine to submit proposal for layer ~p", [Layer]),
        {reply, {error, no_active_engine}, State}
    end;

handle_call(is_engine_primary, _From, State = #state{current_layer = Layer, active_engine_pid = Pid, active_engine_module = Mod}) ->
    if Layer == local andalso is_pid(Pid) andalso Mod == local_consensus_engine ->
        Reply = gen_server:call(Pid, is_primary),
        {reply, Reply, State};
       is_pid(Pid) ->
        ?LOG_INFO("Checking primary status for generic engine ~p for layer ~p", [Pid, Layer]),
         % Placeholder: Assume non-local engines are not primary or handle differently
        {reply, false, State};
       true ->
        ?LOG_WARNING("No active engine to check primary status for layer ~p", [Layer]),
        {reply, {error, no_active_engine}, State}
    end;

handle_call({submit_proposal_to_layer, TargetLayer, Proposal}, _From, State = #state{node_id = NodeId, current_layer = CurrentNodeLayer}) ->
    ?LOG_DEBUG("Router (~p) received submit_proposal_to_layer for TargetLayer: ~p, CurrentLayer: ~p", [NodeId, TargetLayer, CurrentNodeLayer]),
    if TargetLayer == CurrentNodeLayer ->
        ?LOG_INFO("TargetLayer (~p) is current layer. Routing proposal to self's active engine.", [TargetLayer]),
        % Call the existing internal logic for submit_proposal, which routes to the active engine.
        % This is a gen_server:call to self, which maps to handle_call({submit_proposal, Proposal}, ...)
        % Need to extract the existing logic or call it carefully.
        % The existing handle_call for submit_proposal expects _From, so we can call it directly.
        handle_call({submit_proposal, Proposal}, _From, State);
       true ->
        % Simplification: Log and do nothing if TargetLayer is different.
        % Future: Determine nodes in TargetLayer and send proposal via tpic2.
        ?LOG_INFO("TargetLayer (~p) is different from current layer (~p). Logging and dropping proposal for now.", [TargetLayer, CurrentNodeLayer]),
        {reply, {ok, logged_for_different_target_layer}, State}
    end;

handle_call(get_active_engine_details, _From, State = #state{active_engine_module = Mod, active_engine_pid = Pid}) ->
    {reply, {ok, #{module => Mod, pid => Pid}}, State};

handle_call(Msg, _From, State) ->
    ?LOG_WARNING("Unhandled call: ~p", [Msg]),
    {reply, {error, unhandled_call}, State}.

handle_cast({notify_layer_change_internal, NewLayer}, State = #state{current_layer = OldLayer, active_engine_pid = OldPid, node_id = MyNodeId}) ->
    if NewLayer /= OldLayer ->
        ?LOG_INFO("Node ~p internal layer change from ~p to ~p.", [MyNodeId, OldLayer, NewLayer]),
        stop_engine(OldPid, State#state.active_engine_module),
        {NewPid, NewMod} = start_engine(NewLayer, MyNodeId),
        {noreply, State#state{current_layer = NewLayer, active_engine_pid = NewPid, active_engine_module = NewMod}};
       true ->
        ?LOG_INFO("Node ~p already in layer ~p. No change.", [MyNodeId, NewLayer]),
        {noreply, State}
    end;

handle_cast({route_gossip_message, FromNode, LayerTag, Message}, State = #state{current_layer = SelfLayer, active_engine_pid = Pid, active_engine_module = Mod}) ->
    % Here, Message is assumed to be the actual PBFT message map, e.g. #{tag=>pre_prepare, ...}
    % The tpic2 layer would have unwrapped it from {pbft_local, ActualMessage}
    if LayerTag == SelfLayer andalso is_pid(Pid) ->
        if Mod == local_consensus_engine andalso LayerTag == local ->
            gen_server:cast(Pid, {handle_network_message, Message, FromNode});
           true ->
            % Placeholder for other engines or if Mod is undefined (should not happen if Pid exists)
            ?LOG_INFO("Routing gossip to generic engine ~p for layer ~p. Msg: ~p", [Pid, LayerTag, Message])
        end;
       LayerTag /= SelfLayer ->
        ?LOG_DEBUG("Ignoring gossip for layer ~p (self is ~p) from ~p.", [LayerTag, SelfLayer, FromNode]);
       not is_pid(Pid) ->
        ?LOG_WARNING("No active engine to route gossip message for layer ~p from ~p.", [LayerTag, FromNode])
    end,
    {noreply, State};

handle_cast({handle_finalized_block, EngineModule, BlockData, SeqNo}, State = #state{current_layer = Layer, node_id = NodeId}) ->
    ?LOG_INFO("Router received finalized block for S~p from ~p (Layer: ~p). Node ~p", [SeqNo, EngineModule, Layer, NodeId]),
    % Here, you could add checks: e.g., is EngineModule the active_engine_module for 'Layer'?
    % For now, directly pass to blockchain_updater
    blockchain_updater:new_block(BlockData), % new_block is a cast
    % Optionally, the engine could also tell chainsettings to update PBFT view if it changed
    % e.g., if a NEW-VIEW was part of this block's state changes.
    % For now, view changes are handled by the engine and router isn't directly involved in persisting view to chainsettings.
    {noreply, State};

handle_cast(Msg, State) ->
    ?LOG_WARNING("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_WARNING("Unhandled info: ~p", [Info]),
    {noreply, State}.

terminate(Reason, State = #state{active_engine_pid = Pid, active_engine_module = Mod}) ->
    ?LOG_INFO("tpnode_consensus_router terminating: ~p", [Reason]),
    stop_engine(Pid, Mod),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

% Internal functions
start_engine(Layer, NodeId) ->
    ?LOG_INFO("Attempting to start consensus engine for layer: ~p for Node: ~p", [Layer, NodeId]),
    EnginePid = undefined,
    EngineMod = undefined,
    try
        case Layer of
            local ->
                LocalCommittee = chainsettings:get_local_committee(), % Returns a list of NodeIds or #{}
                CurrentPbftView = chainsettings:get_current_pbft_view(),
                CommitteeList = if is_map(LocalCommittee) andalso maps:size(LocalCommittee) == 0 ->
                                    ?LOG_WARNING("Local committee is empty, using self as committee."),
                                    [NodeId]; % Fallback to self if committee is empty
                                 is_list(LocalCommittee) andalso length(LocalCommittee) > 0 ->
                                    LocalCommittee;
                                 true ->
                                     ?LOG_WARNING("Local committee not found or invalid, using self. Data: ~p", [LocalCommittee]),
                                     [NodeId] % Fallback
                                 end,

                {ok, Pid} = local_consensus_engine:start_link(NodeId, CurrentPbftView, CommitteeList),
                {Pid, local_consensus_engine};
            regional ->
                ?LOG_INFO("Placeholder: 'Started' regional_consensus_engine."),
                {make_ref(), regional_placeholder}; % Placeholder PID and Module
            global ->
                ?LOG_INFO("Placeholder: 'Started' global_consensus_engine."),
                {make_ref(), global_placeholder}; % Placeholder PID and Module
            _Other ->
                ?LOG_ERROR("Unknown layer ~p, cannot start engine.", [_Other]),
                {undefined, undefined}
        end
    catch
        Type:Reason:Stacktrace ->
            ?LOG_ERROR("Failed to start engine for layer ~p. Type: ~p, Reason: ~p, Stack: ~p", [Layer, Type, Reason, Stacktrace]),
            {undefined, undefined}
    end.

stop_engine(Pid, Module) when is_pid(Pid) ->
    ?LOG_INFO("Attempting to stop consensus engine ~p with PID: ~p", [Module, Pid]),
    % Use gen_server:stop for proper shutdown if it's a gen_server.
    % Specific engines might have their own stop functions.
    gen_server:stop(Pid), % Standard way to stop a gen_server
    ok;
stop_engine(undefined, _) ->
    ok;
stop_engine(Ref, Module) when is_reference(Ref) -> % Handling placeholder refs
    ?LOG_INFO("Placeholder: 'Stopped' engine ~p represented by ref ~p", [Module, Ref]),
    ok.
