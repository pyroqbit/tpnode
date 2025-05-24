-module(global_consensus_engine).
-behaviour(gen_server).
-include("include/tplog.hrl").

% API for tpnode_consensus_router
-export([start_link/3]). % (NodeId, Committee, RouterPid)

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Callback for NIF to send P2P messages out & record activity
-export([broadcast_p2p_message_from_nif/2, record_nif_activity/3]). % (NodeId, ActivityType, Data)

-define(SERVER, ?MODULE). % Assuming a single global engine process for now
% NIF_LIB_NAME should match the output name of the Rust NIF library (e.g., libnarwhal_tusk_nif.so or narwhal_tusk_nif.dll)
-define(NIF_LIB_NAME, "narwhal_tusk_nif").

-record(state, {
    node_id :: binary(),
    committee :: list(binary()),
    router_pid :: pid(),
    nif_resource :: reference() | undefined, % For NIF resource, if any specific resource is returned by init_consensus
    narwhal_config :: map() % Narwhal/Tusk specific configurations
}).

% API Implementations for gen_server
start_link(NodeId, Committee, RouterPid) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [NodeId, Committee, RouterPid], []).

init([NodeId, Committee, RouterPid]) ->
    T_init_start = erlang:monotonic_time(),
    ?LOG_INFO("Global Consensus Engine (Narwhal/Tusk NIF) starting for Node: ~p", [NodeId]),
    NarwhalConfig = chainsettings:get_narwhal_config_params(), % Fetch from chainsettings
    
    NifPath = filename:join([code:priv_dir(tpnode), ?NIF_LIB_NAME]),

    case erlang:load_nif(NifPath, 0) of
        ok ->
            ?LOG_INFO("Narwhal/Tusk NIF library loaded successfully from ~p.", [NifPath]);
        {error, {Reason, Desc}} ->
            ?LOG_ERROR("Failed to load Narwhal/Tusk NIF library from ~p: ~p - ~p", [NifPath, Reason, Desc]),
            erlang:error({nif_load_failed, Reason})
    end,

    % Initialize the Rust side of the consensus mechanism
    % The NIF function should return a term that indicates success/failure and possibly a resource
    case narwhal_tusk_nif:init_consensus(NodeId, Committee, NarwhalConfig) of
        {ok, NifResourceRef} -> % Assuming NIF init might return a resource or reference for future calls
            ?LOG_INFO("Narwhal/Tusk consensus initialized successfully via NIF."),
            % Register this Erlang PID with the NIF so it can send messages back
            ok = narwhal_tusk_nif:set_erlang_callback_pid(self()),
            % Register the Erlang P2P broadcast function with the NIF
            % The NIF will call Module:Function(Target, Message)
            ok = narwhal_tusk_nif:set_erlang_p2p_broadcast_fun(?MODULE, broadcast_p2p_message_from_nif),
            ok = narwhal_tusk_nif:set_erlang_activity_recorder_fun(?MODULE, record_nif_activity), % Register activity recorder

            T_init_end = erlang:monotonic_time(),
            ?LOG_INFO("Global engine ~p: Init successful in ~p ms", [NodeId, erlang:convert_time_unit(T_init_end - T_init_start, native, milliseconds)]),
            {ok, #state{
                node_id = NodeId,
                committee = Committee,
                router_pid = RouterPid,
                nif_resource = NifResourceRef, % Store if NIF returns a resource handle
                narwhal_config = NarwhalConfig
            }};
        {error, NifInitError} ->
            ?LOG_ERROR("Failed to initialize Narwhal/Tusk consensus via NIF: ~p", [NifInitError]),
            erlang:error({nif_init_failed, NifInitError})
    end.

% gen_server Callbacks
handle_call({handle_tx_submission, Transaction}, _From, State = #state{nif_resource = NifRes, node_id = NodeId}) ->
    T_tx_sub_start = erlang:monotonic_time(),
    % NifRes might be needed if NIF functions are tied to a resource instance
    Res = case narwhal_tusk_nif:submit_transaction(NifRes, Transaction) of
        ok -> ok;
        {error, Reason} -> {error, {tx_submission_failed, Reason}}
    end,
    T_tx_sub_end = erlang:monotonic_time(),
    ?LOG_DEBUG("Global engine ~p: handle_tx_submission took ~p ms, Result: ~p", [NodeId, erlang:convert_time_unit(T_tx_sub_end - T_tx_sub_start, native, milliseconds), Res]),
    {reply, Res, State};

handle_call({is_primary_for_round, Round}, _From, State = #state{nif_resource = NifRes}) ->
    case narwhal_tusk_nif:is_leader_for_round(NifRes, Round) of
        {ok, IsPrimary} -> {reply, IsPrimary, State}; % IsPrimary should be true | false
        {error, Reason} -> {reply, {error, {is_primary_check_failed, Reason}}, State} % Consider logging time here too if it can vary
    end;

handle_call(Msg, _From, State = #state{node_id = NodeId}) ->
    ?LOG_WARNING("Global engine (~p) unhandled call: ~p", [NodeId, Msg]),
    {reply, {error, unhandled_call}, State}.


handle_cast({handle_network_message, Message, FromNode}, State = #state{nif_resource = NifRes, node_id = NodeId}) ->
    T_net_msg_start = erlang:monotonic_time(),
    case narwhal_tusk_nif:process_p2p_message(NifRes, Message, FromNode) of
        ok ->
            T_net_msg_end = erlang:monotonic_time(),
            ?LOG_DEBUG("Global engine ~p: process_p2p_message for msg from ~p took ~p ms", [NodeId, FromNode, erlang:convert_time_unit(T_net_msg_end - T_net_msg_start, native, milliseconds)]),
            {noreply, State};
        {error, Reason} -> 
            T_net_msg_end_err = erlang:monotonic_time(),
            ?LOG_ERROR("Global engine ~p: Error processing P2P message from ~p (took ~p ms): ~p", [NodeId, FromNode, erlang:convert_time_unit(T_net_msg_end_err - T_net_msg_start, native, milliseconds), Reason]),
            {noreply, State} % Or handle error more explicitly
    end;

handle_cast(Msg, State = #state{node_id = NodeId}) ->
    ?LOG_WARNING("Global engine (~p) unhandled cast: ~p", [NodeId, Msg]),
    {noreply, State}.


% Internal Message Handling (Callbacks from NIF)
handle_info({nif_finalized_batch, OrderedBatchData, RoundInfo, NifProcessingTimeMs}, State = #state{router_pid = RouterPid, node_id = NodeId}) ->
    T_finalize_erl_start = erlang:monotonic_time(),
    ?LOG_INFO("Global engine ~p: Received finalized batch from NIF for round ~p. NIF processing time: ~p ms. Data: ~p", [NodeId, RoundInfo, NifProcessingTimeMs, OrderedBatchData]),
    % OrderedBatchData is expected to be a list of transactions or similar structure
    % that blockchain_updater:new_block can handle.
    % The router expects {handle_finalized_block, Module, BlockData, SeqOrRoundInfo}
    gen_server:cast(RouterPid, {handle_finalized_block, ?MODULE, OrderedBatchData, RoundInfo}),
    T_finalize_erl_end = erlang:monotonic_time(),
    ?LOG_DEBUG("Global engine ~p: Erlang side of finality for round ~p took ~p ms", [NodeId, RoundInfo, erlang:convert_time_unit(T_finalize_erl_end - T_finalize_erl_start, native, milliseconds)]),
    {noreply, State};

handle_info({nif_dag_update, DagViewOrMetric}, State = #state{node_id = NodeId}) ->
    ?LOG_DEBUG("Global engine (~p) received DAG update/metric from NIF: ~p", [NodeId, DagViewOrMetric]),
    % This could be used for advanced logging, metrics, or even triggering other processes.
    {noreply, State};

handle_info(Info, State = #state{node_id = NodeId}) ->
    ?LOG_WARNING("Global engine (~p) unhandled info: ~p", [NodeId, Info]),
    {noreply, State}.

terminate(Reason, State = #state{node_id = NodeId, nif_resource = NifRes}) ->
    ?LOG_INFO("Global Consensus Engine (~p) terminating. Reason: ~p", [NodeId, Reason]),
    % Shutdown the Rust side of the consensus mechanism
    ok = narwhal_tusk_nif:shutdown_consensus(NifRes), % Pass NifRes if required by NIF
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

% Callback for NIF to send P2P messages
% This function is called BY the NIF.
broadcast_p2p_message_from_nif(all, Message) ->
    MyNodeId = nodekey:get_pub(), % Get self NodeId to exclude from broadcast targets
    GlobalCommittee = chainsettings:get_global_committee(),
    Targets = GlobalCommittee -- [MyNodeId],
    ?LOG_DEBUG("Global engine broadcasting P2P message from NIF to all (~p targets): ~p", [length(Targets), Message]),
    lists:foreach(
        fun(PeerNodeId) ->
            tpic2:cast(PeerNodeId, {narwhal_tusk_msg, global, Message})
        end,
        Targets
    );

broadcast_p2p_message_from_nif(TargetNodes, Message) when is_list(TargetNodes) ->
    ?LOG_DEBUG("Global engine broadcasting P2P message from NIF to specific targets ~p: ~p", [TargetNodes, Message]),
    lists:foreach(
        fun(PeerNodeId) -> % Changed variable name for clarity
            tpic2:cast(PeerNodeId, {narwhal_tusk_msg, global, Message})
        end,
        TargetNodes
    ).

% Callback for NIF to record activity
% This function is called BY the NIF.
record_nif_activity(NodeId, ActivityType, Data) ->
    % This function will be called by the NIF, so it needs to be callable directly.
    % It then calls the mass manager.
    tpnode_mass_manager:record_activity(NodeId, ActivityType, Data).

% Conceptual NIF function definitions (as comments for clarity):
% narwhal_tusk_nif:init_consensus(SelfNodeId_binary, Committee_list_of_binaries, Config_map) -> {ok, NifResourceRef} | {error, Reason}.
% narwhal_tusk_nif:submit_transaction(NifResourceRef_opt, Tx_binary) -> ok | {error, Reason}.
% narwhal_tusk_nif:process_p2p_message(NifResourceRef_opt, Message_term, FromNode_binary) -> ok | {error, Reason}.
% narwhal_tusk_nif:is_leader_for_round(NifResourceRef_opt, Round_integer) -> {ok, boolean()} | {error, Reason}.
% narwhal_tusk_nif:set_erlang_callback_pid(Pid_erlang) -> ok.
% narwhal_tusk_nif:set_erlang_p2p_broadcast_fun(Module_atom, Function_atom) -> ok.
% narwhal_tusk_nif:shutdown_consensus(NifResourceRef_opt) -> ok.
end_of_module.The `global_consensus_engine.erl` has been updated with the detailed structure, NIF interaction points, and callbacks.
The NIF functions now include an optional `NifResourceRef` argument if the NIF design requires it for context (e.g., if `init_consensus` returns a handle to the Rust consensus state).
The `broadcast_p2p_message_from_nif/2` function now attempts to fetch the global committee from `chainsettings` to broadcast to all members, excluding self. This has performance implications (synchronous call from a NIF-called function) and might need refinement (e.g., NIF provides the list, or this function casts to self to handle asynchronously). The message is wrapped with `{narwhal_tusk_msg, global, Message}`.

**Step 2: Modify `chainsettings.erl`**
This involves ensuring `get_global_committee/0` and `set_global_committee/1` are robust (they should be from previous tasks) and adding `get_narwhal_config_params/0`.
