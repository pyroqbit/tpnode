-module(tpnode_mass_manager).
-behaviour(gen_server).
-include("include/tplog.hrl").

% API
-export([start_link/0]).
-export([init_node_mass_data/2, update_stake/2, record_activity/3, record_performance/3]).
-export([recalculate_mass/1, assign_layer/1]).
-export([get_node_mass_data/1, get_all_nodes_mass_data/0, get_nodes_in_layer/1]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_LAYER, local). % Or fetch from config
-define(RECALCULATION_INTERVAL, 60 * 1000). % 60 seconds

-record(state, {
    nodes_mass_data = #{}, % node_id => node_mass_data_map
    layer_thresholds = #{}
}).

% API Implementations
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init_node_mass_data(NodeId, InitialStake) ->
    gen_server:call(?SERVER, {init_node_mass_data, NodeId, InitialStake}).

update_stake(NodeId, NewStakeAmount) ->
    gen_server:cast(?SERVER, {update_stake, NodeId, NewStakeAmount}).

record_activity(NodeId, ActivityType, Value) ->
    % For now, just log. In future, might queue or process immediately.
    ?LOG_INFO("Activity recorded for ~p: Type=~p, Value=~p", [NodeId, ActivityType, Value]),
    ok.

record_performance(NodeId, PerformanceMetric, Value) ->
    % For now, just log. In future, might queue or process immediately.
    ?LOG_INFO("Performance recorded for ~p: Metric=~p, Value=~p", [NodeId, PerformanceMetric, Value]),
    ok.

recalculate_mass(NodeId) ->
    gen_server:cast(?SERVER, {recalculate_mass, NodeId}).

assign_layer(NodeId) ->
    gen_server:cast(?SERVER, {assign_layer, NodeId}).

get_node_mass_data(NodeId) ->
    gen_server:call(?SERVER, {get_node_mass_data, NodeId}).

get_all_nodes_mass_data() ->
    gen_server:call(?SERVER, {get_all_nodes_mass_data}).

get_nodes_in_layer(Layer) ->
    gen_server:call(?SERVER, {get_nodes_in_layer, Layer}).

% gen_server Callbacks
init([]) ->
    ?LOG_INFO("tpnode_mass_manager starting..."),
    NodesMassDataList = chainsettings:get_nodes_mass_data(),
    NodesMassDataMap = maps:from_list([ {maps:get(<<"node_id">>, NMD), NMD} || NMD <- NodesMassDataList ]),
    LayerThresholds = chainsettings:get_layer_thresholds(),
    erlang:send_after(?RECALCULATION_INTERVAL, self(), recalculate_and_assign_all),
    {ok, #state{nodes_mass_data = NodesMassDataMap, layer_thresholds = LayerThresholds}}.

handle_call({init_node_mass_data, NodeId, InitialStake}, _From, State = #state{nodes_mass_data = CurrentData}) ->
    Timestamp = erlang:system_time(seconds),
    NewNodeData = #{
        <<"node_id">> => NodeId,
        <<"current_layer">> => ?DEFAULT_LAYER,
        <<"stake_amount">> => InitialStake,
        <<"activity_score">> => 0, % Default
        <<"performance_score">> => 0, % Default
        <<"calculated_mass">> => 0, % Initial
        <<"last_mass_update_timestamp">> => Timestamp
    },
    UpdatedData = maps:put(NodeId, NewNodeData, CurrentData),
    chainsettings:set_nodes_mass_data(maps:values(UpdatedData)), % Persist
    {reply, ok, State#state{nodes_mass_data = UpdatedData}};

handle_call({get_node_mass_data, NodeId}, _From, State = #state{nodes_mass_data = NodesData}) ->
    {reply, maps:get(NodeId, NodesData, undefined), State};

handle_call({get_all_nodes_mass_data}, _From, State = #state{nodes_mass_data = NodesData}) ->
    {reply, maps:values(NodesData), State};

handle_call({get_nodes_in_layer, Layer}, _From, State = #state{nodes_mass_data = NodesData}) ->
    NodesInLayer = lists:filtermap(
        fun(#{<<"node_id">> := NodeId, <<"current_layer">> := CurrentLayer}) ->
            CurrentLayer == Layer;
           (_) ->
            false
        end,
        fun(#{<<"node_id">> := NodeId, <<"current_layer">> := _}) ->
            {true, NodeId};
           (_) ->
            false
        end,
        maps:values(NodesData)),
    {reply, NodesInLayer, State};

handle_call(Msg, _From, State) ->
    ?LOG_WARNING("Unhandled call: ~p", [Msg]),
    {reply, {error, unhandled_call}, State}.

handle_cast({update_stake, NodeId, NewStakeAmount}, State = #state{nodes_mass_data = CurrentData}) ->
    case maps:get(NodeId, CurrentData, undefined) of
        undefined ->
            ?LOG_ERROR("Node ~p not found for stake update.", [NodeId]),
            {noreply, State};
        NodeData ->
            UpdatedNodeData = maps:put(<<"stake_amount">>, NewStakeAmount, NodeData),
            UpdatedData = maps:put(NodeId, UpdatedNodeData, CurrentData),
            chainsettings:set_nodes_mass_data(maps:values(UpdatedData)), % Persist
            {noreply, State#state{nodes_mass_data = UpdatedData}}
    end;

handle_cast({recalculate_mass, NodeId}, State = #state{nodes_mass_data = CurrentData}) ->
    % Placeholder: Direct stake to mass for now
    case maps:get(NodeId, CurrentData, undefined) of
        undefined ->
            ?LOG_ERROR("Node ~p not found for mass recalculation.", [NodeId]),
            {noreply, State};
        NodeData = #{<<"stake_amount">> := Stake} ->
            CalculatedMass = Stake, % Simple direct mapping for now
            Timestamp = erlang:system_time(seconds),
            UpdatedNodeData = maps:merge(NodeData, #{
                <<"calculated_mass">> => CalculatedMass,
                <<"last_mass_update_timestamp">> => Timestamp
            }),
            UpdatedData = maps:put(NodeId, UpdatedNodeData, CurrentData),
            chainsettings:set_nodes_mass_data(maps:values(UpdatedData)), % Persist
            ?LOG_INFO("Recalculated mass for ~p: ~p", [NodeId, CalculatedMass]),
            {noreply, State#state{nodes_mass_data = UpdatedData}}
    end;

handle_cast({assign_layer, NodeId}, State = #state{nodes_mass_data = CurrentData, layer_thresholds = Thresholds}) ->
    case maps:get(NodeId, CurrentData, undefined) of
        undefined ->
            ?LOG_ERROR("Node ~p not found for layer assignment.", [NodeId]),
            {noreply, State};
        NodeData = #{<<"calculated_mass">> := Mass, <<"current_layer">> := OldLayer} ->
            NewLayer = determine_layer(Mass, Thresholds),
            if NewLayer /= OldLayer ->
                UpdatedNodeData = maps:put(<<"current_layer">>, NewLayer, NodeData),
                UpdatedDataMap = maps:put(NodeId, UpdatedNodeData, CurrentData),
                chainsettings:set_nodes_mass_data(maps:values(UpdatedDataMap)), % Persist
                ?LOG_INFO("Node ~p changed layer from ~p to ~p (Mass: ~p)", [NodeId, OldLayer, NewLayer, Mass]),
                tpnode_consensus_router:notify_layer_change(NodeId, NewLayer),
                {noreply, State#state{nodes_mass_data = UpdatedDataMap}};
               true ->
                % No change, no action needed
                {noreply, State}
            end
    end;

handle_cast(force_recalculate, State = #state{nodes_mass_data = NodesData}) ->
    ?LOG_INFO("Forced recalculation and assignment triggered via cast."),
    AllNodeIds = maps:keys(NodesData),
    lists:foreach(
        fun(NodeId) ->
            recalculate_mass(NodeId), % These are casts to self
            assign_layer(NodeId)     % These are casts to self
        end,
        AllNodeIds
    ),
    % Unlike the timer, we don't reschedule here as it's a one-off trigger.
    {noreply, State};

handle_cast(Msg, State) ->
    ?LOG_WARNING("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info(recalculate_and_assign_all, State = #state{nodes_mass_data = NodesData}) ->
    T_recalc_all_start = erlang:monotonic_time(),
    ?LOG_INFO("Periodic recalculation and assignment triggered for ~p nodes.", [maps:size(NodesData)]),
    AllNodeIds = maps:keys(NodesData),
    lists:foreach(
        fun(NodeId) ->
            % These are casts to self, so they will be processed sequentially
            % after the current handle_info finishes, before any other external messages.
            recalculate_mass(NodeId),
            assign_layer(NodeId) % assign_layer will use the updated mass from the previous step
        end,
        AllNodeIds
    ),
    RecalcInterval = application:get_env(tpnode, mass_manager_recalc_interval_ms, 60000),
    erlang:send_after(RecalcInterval, self(), recalculate_and_assign_all),
    T_recalc_all_end = erlang:monotonic_time(),
    ?LOG_INFO("Finished dispatching recalculate_and_assign_all tasks in ~p ms.", 
              [erlang:convert_time_unit(T_recalc_all_end - T_recalc_all_start, native, milliseconds)]),
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_WARNING("Unhandled info: ~p", [Info]),
    {noreply, State}.

terminate(Reason, State = #state{}) ->
    ?LOG_INFO("tpnode_mass_manager terminating: ~p", [Reason]),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

% Internal functions
determine_layer(Mass, Thresholds) ->
    % Thresholds = #{<<"local">> => #{<<"min_mass">> => Val, <<"max_mass">> => Val}, ...}
    case maps:get(<<"global">>, Thresholds, undefined) of
        #{<<"min_mass">> := MinGlobal} when Mass >= MinGlobal -> global;
        _ ->
            case maps:get(<<"regional">>, Thresholds, undefined) of
                #{<<"min_mass">> := MinRegional} when Mass >= MinRegional -> regional;
                _ ->
                    local % Default or if local has specific min/max and it fits
            end
    end.
