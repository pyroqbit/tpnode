-module(tpnode_test_utils).
-include("include/tplog.hrl").

% API
-export([
    submit_dummy_transaction/2,
    get_node_layer/1,
    get_node_mass/1,
    force_mass_recalculation/1,
    simulate_activity/3,
    get_active_engine_module/1
]).

%% @doc Submits a dummy transaction to a target node.
submit_dummy_transaction(TargetNode, Payload) when is_atom(TargetNode), is_term(Payload) ->
    DummyTx = #{
        <<"type">> => <<"dummy_tx">>,
        <<"payload">> => Payload,
        <<"nonce">> => erlang:system_time(nanosecond) % More unique nonce
    },
    ?LOG_INFO("Submitting dummy tx to ~p: ~p", [TargetNode, DummyTx]),
    % The target router function needs to know which layer's proposal format to use.
    % For simplicity, assume submit_proposal on router can handle a generic format for dummy txns,
    % or we determine target layer and call a layer-specific proposal function.
    % Let's assume submit_proposal is generic enough or the router handles it.
    % If the target layer is global, it should be adapted to submit_transaction_global.
    % For now, we'll use a generic approach; the router might need to inspect the tx or have specific endpoints.

    % Simplified: Assume the router's `submit_proposal` can take this.
    % If different nodes run different layers, this needs to be smarter,
    % potentially querying the node's layer first.
    % For now, using a general submit_proposal which might be handled by the current layer of TargetNode.
    try rpc:call(TargetNode, tpnode_consensus_router, submit_proposal, [DummyTx]) of
        Result ->
            ?LOG_INFO("Dummy tx submission to ~p result: ~p", [TargetNode, Result]),
            case Result of
                {ok, _} -> ok;
                {badrpc, ReasonRpc} -> {error, {rpc_failed, ReasonRpc}};
                Other -> {error, Other} % Other error from the call itself
            end
    catch
        exit:{Reason, _Stack} ->
            ?LOG_ERROR("RPC call to ~p failed for submit_dummy_transaction: ~p", [TargetNode, Reason]),
            {error, {rpc_exit, Reason}}
    end.

%% @doc Gets the current layer of a target node.
get_node_layer(TargetNode) when is_atom(TargetNode) ->
    try rpc:call(TargetNode, tpnode_mass_manager, get_node_mass_data, [nodekey:get_pub_from_nodename(TargetNode)]) of
        % Assuming get_node_mass_data returns the full map, and it contains 'current_layer'
        #{<<"current_layer">> := Layer} -> {ok, Layer};
        undefined -> {error, node_not_initialized_in_mass_manager};
        {badrpc, ReasonRpc} -> {error, {rpc_failed, ReasonRpc}};
        Other -> {error, Other}
    catch
        exit:{Reason, _Stack} -> {error, {rpc_exit, Reason}}
    end.

%% @doc Gets the mass data map of a target node.
get_node_mass(TargetNode) when is_atom(TargetNode) ->
     try rpc:call(TargetNode, tpnode_mass_manager, get_node_mass_data, [nodekey:get_pub_from_nodename(TargetNode)]) of
        MassData when is_map(MassData) -> {ok, MassData};
        undefined -> {error, node_not_initialized_in_mass_manager};
        {badrpc, ReasonRpc} -> {error, {rpc_failed, ReasonRpc}};
        Other -> {error, Other}
    catch
        exit:{Reason, _Stack} -> {error, {rpc_exit, Reason}}
    end.

%% @doc Forces mass recalculation on a target node.
force_mass_recalculation(TargetNode) when is_atom(TargetNode) ->
    % The recalculate_and_assign_all is an internal info message.
    % We need a cast or call handler in tpnode_mass_manager for this.
    % Let's add a new cast handler to tpnode_mass_manager: handle_cast(force_recalculate, State) -> self() ! recalculate_and_assign_all.
    try rpc:cast(TargetNode, tpnode_mass_manager, force_recalculate, []) of
        true -> ok; % cast returns true
        {badrpc, ReasonRpc} -> {error, {rpc_failed, ReasonRpc}}
    catch
        exit:{Reason, _Stack} -> {error, {rpc_exit, Reason}}
    end.

%% @doc Simulates recording activity on a target node.
simulate_activity(TargetNode, ActivityType, Value) when is_atom(TargetNode), is_atom(ActivityType), is_term(Value) ->
    % Assuming nodekey:get_pub_from_nodename/1 exists to get the NodeId for whom to record activity.
    % For simplicity, let's assume we're recording activity for the TargetNode itself.
    % record_activity expects NodeId, ActivityType, Value.
    % This might need to be a call if an immediate reply is needed, but activity is often a cast.
    NodeId = nodekey:get_pub_from_nodename(TargetNode), % This function needs to exist
    try rpc:call(TargetNode, tpnode_mass_manager, record_activity, [NodeId, ActivityType, Value]) of
        % record_activity in mass_manager currently returns 'ok' (atom).
        ok -> ok;
        {badrpc, ReasonRpc} -> {error, {rpc_failed, ReasonRpc}};
        Other -> {error, Other}
    catch
        exit:{Reason, _Stack} -> {error, {rpc_exit, Reason}}
    end.

%% @doc Gets the active consensus engine module of a target node.
get_active_engine_module(TargetNode) when is_atom(TargetNode) ->
    % This requires a new function in tpnode_consensus_router.
    % Let's define it as get_state, then extract. Or a specific get_active_module.
    % Adding `get_active_module/0` to router.
    try rpc:call(TargetNode, tpnode_consensus_router, get_active_engine_details, []) of
        {ok, #{module := Module}} when is_atom(Module) -> {ok, Module};
        {ok, OtherMap} -> {error, {unexpected_router_details_format, OtherMap}};
        {badrpc, ReasonRpc} -> {error, {rpc_failed, ReasonRpc}};
        Error -> {error, Error}
    catch
        exit:{Reason, _Stack} -> {error, {rpc_exit, Reason}}
    end.

% Helper for nodekey:get_pub_from_nodename/1 - this is conceptual
% In a real setup, node public keys would be known to the test environment,
% perhaps through the launcher script's generated configs.
% For now, this is a placeholder. If node names are like 'tpnode_1@host',
% we might need a utility to map these to their configured pubkeys.
% nodekey:get_pub_from_nodename(TargetNodeAtom) ->
%    % Logic to derive/lookup pubkey from TargetNodeAtom.
%    % This might involve reading a shared config or specific node's config.
%    % Placeholder:
%    list_to_binary("pubkey_for_" ++ atom_to_list(TargetNodeAtom)).
end_of_module.
